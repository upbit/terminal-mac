import Foundation
import CoreFoundation
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
        var wake: Task<Void, Never>?
        var pacer: ObserverPacer
        var controlBytes = 0
    }
    private let source: any ObserverSource
    private let standardConfiguration: ObserverConfiguration
    private let lowConfiguration: ObserverConfiguration
    private var lowBandwidth: Bool
    private var configuration: ObserverConfiguration { lowBandwidth ? lowConfiguration : standardConfiguration }
    private var peers: [UUID: Peer] = [:]
    private var latest: ObserverPixels?
    private var captureEpoch = "", error: String?
    private var captureTask: Task<Void, Never>?, timer: Task<Void, Never>?
    private var stopped = false
    init(source: any ObserverSource, configuration: ObserverConfiguration = .standard, lowBandwidth: Bool = false) {
        self.source = source; self.lowBandwidth = lowBandwidth
        standardConfiguration = lowBandwidth ? .standard : configuration
        lowConfiguration = lowBandwidth ? configuration : .low
    }

    func add(_ id: UUID, channel: Channel) {
        peers[id] = Peer(channel: channel, pacer: ObserverPacer(maxFPS: configuration.maxFPS, bytesPerSecond: configuration.bytesPerSecond))
        sendMode(channel)
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
        let peer = peers.removeValue(forKey: id)
        peer?.encoding?.cancel(); peer?.wake?.cancel()
        if !peers.values.contains(where: { $0.active }) { captureTask?.cancel() }
        if peers.isEmpty { timer?.cancel(); timer = nil }
    }
    func stop() async {
        stopped = true; timer?.cancel(); captureTask?.cancel()
        for peer in peers.values { peer.encoding?.cancel(); peer.wake?.cancel(); peer.channel.close(promise: nil) }
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
            case "mode": fields = ["type", "lowBandwidth"]
            default: throw Failure("Unknown observer control: \(type)")
            }
            guard Set(message.keys) == fields else { throw Failure("Unexpected observer control fields") }
            switch type {
            case "mode":
                guard let value = message["lowBandwidth"] as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure("Invalid observer mode") }
                setMode(value.boolValue)
                sendMode(peer.channel)
                return
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
            case "pause":
                peer.active = false; peer.client.reset(); peer.started = nil; peer.sentSeq = nil; peer.encoding?.cancel()
                peer.wake?.cancel(); peer.wake = nil
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
    private func sendMode(_ channel: Channel) {
        sendJSON(channel, ["type": "mode", "lowBandwidth": lowBandwidth, "maxFps": configuration.maxFPS])
    }
    private func setMode(_ low: Bool) {
        guard low != lowBandwidth else { return }
        lowBandwidth = low
        latest = nil; error = nil
        captureTask?.cancel()
        for id in Array(peers.keys) {
            reset(id)
            peers[id]?.pacer.configure(maxFPS: configuration.maxFPS, bytesPerSecond: configuration.bytesPerSecond)
            if let peer = peers[id] { sendMode(peer.channel) }
        }
        if peers.values.contains(where: { $0.active }) { startCapture() }
    }
    private func captureLoop() async {
        let low = lowBandwidth, settings = configuration
        var configured = false
        while !Task.isCancelled && !stopped && peers.values.contains(where: { $0.active }) {
            do {
                if !configured {
                    try await source.configure(lowBandwidth: low, maxFPS: settings.maxFPS)
                    try Task.checkCancellation()
                    configured = true
                }
                if let capture = try await source.next() {
                    try Task.checkCancellation()
                    let previous = capture.epoch == captureEpoch ? latest : nil
                    let tileSize = settings.tileSize
                    let snapshot = try await Task.detached {
                        let grid = try ObserverGrid(width: capture.grid.width, height: capture.grid.height, tileSize: tileSize)
                        let candidates = try grid == capture.grid ? capture.tiles : capture.tiles.map { tiles in
                            try tiles.reduce(into: Set<Int>()) { result, tile in
                                result.formUnion(try grid.tiles(intersecting: capture.grid.rect(tile)))
                            }
                        }
                        return try ObserverPixels(grid: grid, rgba: capture.pixels, previous: previous, candidates: candidates)
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
        peer.wake?.cancel(); peer.wake = nil
        peers[id] = peer
    }
    private func schedule(_ id: UUID) {
        guard var peer = peers[id], peer.active, peer.encoding == nil, peer.channel.isActive,
              peer.client.inFlight == nil, peer.channel.isWritable, let snapshot = latest else { return }
        let delay = peer.pacer.delay(at: ProcessInfo.processInfo.systemUptime)
        if delay > 0 {
            if peer.wake == nil {
                peer.wake = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                    if Task.isCancelled { return }
                    wake(id)
                }
                peers[id] = peer
            }
            return
        }
        peer.wake?.cancel(); peer.wake = nil
        peers[id] = peer
        do {
            guard let batch = try peer.client.reserve(snapshot) else { return }
            peer.started = Date()
            if batch.full {
                peer.controlBytes += sendJSON(peer.channel, ["type": "welcome", "v": 1, "epoch": batch.epoch,
                                         "width": snapshot.grid.width, "height": snapshot.grid.height,
                                         "tileSize": snapshot.grid.tileSize, "codec": "png", "maxFps": configuration.maxFPS,
                                         "bytesPerSecond": configuration.bytesPerSecond ?? 0])
            }
            let policy = configuration.pngPolicy
            let task = Task.detached { try ObserverPNG.batch(batch, policy: policy) }, job = UUID()
            peer.encoding = task; peer.encodingID = job; peers[id] = peer
            Task {
                do { let data = try await task.value; encoded(id, job: job, epoch: batch.epoch, data: data) }
                catch { encodingFailed(id, job: job, epoch: batch.epoch, error: error) }
            }
        } catch { fail(id, error.localizedDescription) }
    }
    private func wake(_ id: UUID) {
        guard var peer = peers[id] else { return }
        peer.wake = nil; peers[id] = peer; schedule(id)
    }
    private func encoded(_ id: UUID, job: UUID, epoch: String, data: Data) {
        guard var peer = peers[id], peer.encodingID == job else { return }
        peer.encoding = nil; peer.encodingID = nil
        if peer.client.epoch == epoch { peer.sentSeq = peer.client.inFlight?.seq }
        peers[id] = peer
        guard peer.client.epoch == epoch, peer.active else { schedule(id); return }
        guard peer.channel.isWritable else { fail(id, "Observer socket is not writable"); return }
        peer.pacer.sent(bytes: data.count + peer.controlBytes, at: ProcessInfo.processInfo.systemUptime)
        peer.controlBytes = 0; peers[id] = peer
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
    @discardableResult private func sendJSON(_ channel: Channel, _ object: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return 0 }
        var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
        return data.count
    }
}
