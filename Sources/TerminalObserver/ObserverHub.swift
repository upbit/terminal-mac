import Foundation
import NIOCore
import NIOWebSocket
import TerminalMacCore

actor ObserverHub {
    struct Peer {
        let channel: Channel
        var client = ObserverClient()
        var active = false
        var lastPong = Date(), lastPing = Date.distantPast
        var nonce = ""
        var started: Date?
        var sentSeq: UInt64?
        var encoding: Task<Data, Error>?
        var encodingID: UUID?
    }
    private let source: any ObserverSource
    private var peers: [UUID: Peer] = [:]
    private var latest: ObserverPixels?
    private var captureEpoch = "", error: String?
    private var captureTask: Task<Void, Never>?, timer: Task<Void, Never>?
    private var stopped = false
    init(source: any ObserverSource) { self.source = source }

    func add(_ id: UUID, channel: Channel) {
        peers[id] = Peer(channel: channel)
        if timer == nil {
            timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    tick()
                }
            }
        }
    }
    func remove(_ id: UUID) {
        peers.removeValue(forKey: id)?.encoding?.cancel()
        if !peers.values.contains(where: { $0.active }) { captureTask?.cancel() }
        if peers.isEmpty { timer?.cancel(); timer = nil }
    }
    func stop() async {
        stopped = true; timer?.cancel(); captureTask?.cancel()
        for peer in peers.values { peer.encoding?.cancel(); peer.channel.close(promise: nil) }
        peers.removeAll()
        await captureTask?.value
        await source.close()
    }
    func control(_ id: UUID, data: Data) {
        guard var peer = peers[id] else { return }
        do {
            guard data.count <= ObserverLimits.maxControlBytes,
                  let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = message["type"] as? String else { throw Failure("Invalid control JSON") }
            let fields: Set<String>
            switch type {
            case "subscribe": fields = ["type", "v"]
            case "ack": fields = ["type", "epoch", "seq"]
            case "resync", "pause", "resume": fields = ["type"]
            case "pong": fields = ["type", "nonce"]
            default: throw Failure("Unknown observer control: \(type)")
            }
            guard Set(message.keys) == fields else { throw Failure("Unexpected observer control fields") }
            switch type {
            case "subscribe":
                guard !peer.active, message["v"] as? Int == 1 else { throw Failure("Invalid subscription") }
                peer.active = true
            case "ack":
                guard peer.active, let epoch = message["epoch"] as? String, let seq = message["seq"] as? String,
                      !seq.isEmpty, seq.count <= 20, seq.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt64(seq) else {
                    throw Failure("Invalid observer ACK")
                }
                if epoch == peer.client.epoch && number != peer.client.lastAck && peer.sentSeq != number {
                    throw Failure("ACK arrived before the image was sent")
                }
                try peer.client.acknowledge(epoch: epoch, seq: number)
                if peer.client.inFlight == nil { peer.started = nil; peer.sentSeq = nil }
            case "pause": peer.active = false; peer.client.reset(); peer.started = nil; peer.sentSeq = nil; peer.encoding?.cancel()
            case "resume":
                guard !peer.active else { throw Failure("Observer is already active") }
                peer.active = true; peer.client.reset()
            case "resync": peer.client.reset(); peer.started = nil; peer.sentSeq = nil; peer.encoding?.cancel()
            case "pong":
                guard let nonce = message["nonce"] as? String, nonce == peer.nonce else { throw Failure("Invalid heartbeat") }
                peer.lastPong = Date()
            default: break
            }
            peers[id] = peer
            if peers.values.contains(where: { $0.active }) { startCapture() }
            else { captureTask?.cancel() }
            if let error, peer.active { sendJSON(peer.channel, ["type": "error", "message": error]) }
            schedule(id)
        } catch { fail(id, error.localizedDescription) }
    }
    private func startCapture() {
        guard captureTask == nil, !stopped else { return }
        captureTask = Task { await captureLoop() }
    }
    private func captureLoop() async {
        while !Task.isCancelled && !stopped && peers.values.contains(where: { $0.active }) {
            do {
                if let capture = try await source.next() {
                    try Task.checkCancellation()
                    let previous = capture.epoch == captureEpoch ? latest : nil
                    let snapshot = try await Task.detached {
                        try ObserverPixels(grid: capture.grid, rgba: capture.pixels, previous: previous, candidates: capture.tiles)
                    }.value
                    try Task.checkCancellation()
                    if capture.epoch != captureEpoch || latest?.grid != snapshot.grid {
                        for id in Array(peers.keys) { reset(id) }
                    }
                    captureEpoch = capture.epoch; latest = snapshot
                    if error != nil {
                        error = nil
                        for peer in peers.values { sendJSON(peer.channel, ["type": "state", "state": "connected"]) }
                    }
                    for id in Array(peers.keys) { schedule(id) }
                }
            } catch {
                if Task.isCancelled { break }
                latest = nil; captureEpoch = ""
                for id in Array(peers.keys) { reset(id) }
                if self.error != error.localizedDescription {
                    self.error = error.localizedDescription
                    for peer in peers.values { sendJSON(peer.channel, ["type": "error", "message": error.localizedDescription]) }
                }
                await source.close()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        await source.close()
        latest = nil; captureEpoch = ""; captureTask = nil
        if !stopped && peers.values.contains(where: { $0.active }) { startCapture() }
    }
    private func reset(_ id: UUID) {
        guard var peer = peers[id] else { return }
        peer.client.reset(); peer.started = nil; peer.sentSeq = nil; peer.encoding?.cancel()
        peers[id] = peer
    }
    private func schedule(_ id: UUID) {
        guard var peer = peers[id], peer.active, peer.encoding == nil, peer.channel.isActive,
              peer.channel.isWritable, let snapshot = latest else { return }
        do {
            guard let batch = try peer.client.reserve(snapshot) else { return }
            peer.started = Date()
            if batch.full {
                sendJSON(peer.channel, ["type": "welcome", "v": 1, "epoch": batch.epoch,
                                         "width": snapshot.grid.width, "height": snapshot.grid.height,
                                         "tileSize": 128, "codec": "png", "maxFps": 30])
            }
            let task = Task.detached { try ObserverPNG.batch(batch) }, job = UUID()
            peer.encoding = task; peer.encodingID = job; peers[id] = peer
            Task {
                do { let data = try await task.value; encoded(id, job: job, epoch: batch.epoch, data: data) }
                catch { encodingFailed(id, job: job, epoch: batch.epoch, error: error) }
            }
        } catch { fail(id, error.localizedDescription) }
    }
    private func encoded(_ id: UUID, job: UUID, epoch: String, data: Data) {
        guard var peer = peers[id], peer.encodingID == job else { return }
        peer.encoding = nil; peer.encodingID = nil
        if peer.client.epoch == epoch { peer.sentSeq = peer.client.inFlight?.seq }
        peers[id] = peer
        guard peer.client.epoch == epoch, peer.active else { schedule(id); return }
        guard peer.channel.isWritable else { fail(id, "Observer socket is not writable"); return }
        var buffer = peer.channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
        peer.channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer)).whenFailure { _ in
            peer.channel.close(promise: nil)
        }
    }
    private func encodingFailed(_ id: UUID, job: UUID, epoch: String, error: Error) {
        guard var peer = peers[id], peer.encodingID == job else { return }
        peer.encoding = nil; peer.encodingID = nil; peers[id] = peer
        if peer.client.epoch != epoch || error is CancellationError { schedule(id) }
        else { fail(id, error.localizedDescription) }
    }
    private func tick() {
        for (id, var peer) in peers {
            if Date().timeIntervalSince(peer.lastPong) > 45 { fail(id, "Observer heartbeat timed out"); continue }
            if let started = peer.started, Date().timeIntervalSince(started) > 10 { fail(id, "Observer ACK timed out"); continue }
            if Date().timeIntervalSince(peer.lastPing) >= 15 {
                peer.nonce = UUID().uuidString; peer.lastPing = Date(); peers[id] = peer
                sendJSON(peer.channel, ["type": "ping", "nonce": peer.nonce])
            }
            schedule(id)
        }
    }
    private func fail(_ id: UUID, _ message: String) {
        guard let peer = peers[id] else { return }
        sendJSON(peer.channel, ["type": "error", "message": message])
        peer.channel.close(promise: nil); remove(id)
    }
    private func sendJSON(_ channel: Channel, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
    }
}
