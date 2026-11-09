import Foundation
import CoreFoundation
import TerminalMacCore

actor ObserverHub {
    struct Peer {
        let transport: ObserverTransport
        var client = ObserverClient()
        var active = false
        var started: Double?
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
    private var encodingWork: Task<Data, Error>?
    private let encode: @Sendable (ObserverBatch, ObserverPNGPolicy) async throws -> Data
    private let clock: @Sendable () -> Double
    private let ackTimeout: Double
    init(source: any ObserverSource, configuration: ObserverConfiguration = .standard, lowBandwidth: Bool = false,
         ackTimeout: Double = 10, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         encode: @escaping @Sendable (ObserverBatch, ObserverPNGPolicy) async throws -> Data = { try ObserverPNG.batch($0, policy: $1) }) {
        self.source = source; self.lowBandwidth = lowBandwidth
        self.encode = encode; self.clock = clock; self.ackTimeout = ackTimeout
        standardConfiguration = lowBandwidth ? .standard : configuration
        lowConfiguration = lowBandwidth ? configuration : .low
    }

    func add(_ id: UUID, transport: ObserverTransport) throws {
        guard peers.isEmpty, !stopped else { throw RelayFailure("protocol_error") }
        peers[id] = Peer(transport: transport, pacer: ObserverPacer(maxFPS: configuration.maxFPS, bytesPerSecond: configuration.bytesPerSecond))
        if timer == nil {
            timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { break }
                    tick()
                }
            }
        }
    }
    func remove(_ id: UUID) {
        let peer = peers.removeValue(forKey: id)
        peer?.encoding?.cancel(); peer?.wake?.cancel()
        peer?.transport.discard()
        if !peers.values.contains(where: { $0.active }) { captureTask?.cancel(); latest = nil; captureEpoch = "" }
        if peers.isEmpty { timer?.cancel(); timer = nil }
    }
    func stop() async {
        stopped = true; timer?.cancel(); captureTask?.cancel()
        for peer in peers.values { peer.encoding?.cancel(); peer.wake?.cancel(); peer.transport.discard() }
        peers.removeAll()
        await captureTask?.value
        _ = try? await encodingWork?.value
        await source.close()
    }
    func control(_ id: UUID, data: Data) {
        guard var peer = peers[id] else { return }
        do {
            guard data.count <= ObserverLimits.maxControlBytes, !data.contains(0), String(data: data, encoding: .utf8) != nil,
                  let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = message["type"] as? String else { throw Failure("Invalid control JSON") }
            let fields: Set<String>
            switch type {
            case "subscribe": fields = ["type", "v"]
            case "ack": fields = ["type", "epoch", "seq"]
            case "resync": fields = ["type"]
            case "mode": fields = ["type", "lowBandwidth"]
            default: throw Failure("Unknown observer control: \(type)")
            }
            guard Set(message.keys) == fields else { throw Failure("Unexpected observer control fields") }
            switch type {
            case "mode":
                guard peer.active, let value = message["lowBandwidth"] as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure("Invalid observer mode") }
                setMode(value.boolValue)
                if let current = peers[id] { try sendMode(current.transport) }
                return
            case "subscribe":
                guard !peer.active, let version = message["v"] as? NSNumber,
                      CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else { throw Failure("Invalid subscription") }
                peer.active = true
                try sendMode(peer.transport)
            case "ack":
                guard peer.active, let epoch = message["epoch"] as? String, let seq = message["seq"] as? String,
                      UUID(uuidString: epoch) != nil, !seq.isEmpty, seq.first != "0", seq.count <= 20,
                      seq.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt64(seq) else {
                    throw Failure("Invalid observer ACK")
                }
                let normalizedEpoch = UUID(uuidString: epoch)!.uuidString
                if normalizedEpoch == peer.client.epoch && number != peer.client.lastAck && peer.sentSeq != number {
                    throw Failure("ACK arrived before the image was sent")
                }
                try peer.client.acknowledge(epoch: normalizedEpoch, seq: number)
                if peer.client.inFlight == nil { peer.started = nil; peer.sentSeq = nil }
            case "resync":
                guard peer.active else { throw Failure("Observer is not subscribed") }
                peer.client.reset(); peer.started = nil; peer.sentSeq = nil; peer.encoding?.cancel(); peer.transport.discard()
            default: break
            }
            peers[id] = peer
            if peers.values.contains(where: { $0.active }) { startCapture() }
            else { captureTask?.cancel() }
            if let error, peer.active { try sendJSON(peer.transport, ["type": "error", "code": error, "retryable": true]) }
            schedule(id)
        } catch { fail(id, "protocol_error") }
    }
    private func startCapture() {
        guard captureTask == nil, !stopped else { return }
        captureTask = Task { await captureLoop() }
    }
    private func sendMode(_ transport: ObserverTransport) throws {
        try sendJSON(transport, ["type": "mode", "lowBandwidth": lowBandwidth, "maxFps": configuration.maxFPS])
    }
    private func setMode(_ low: Bool) {
        guard low != lowBandwidth else { return }
        lowBandwidth = low
        latest = nil; error = nil
        captureTask?.cancel()
        for id in Array(peers.keys) {
            reset(id)
            peers[id]?.pacer.configure(maxFPS: configuration.maxFPS, bytesPerSecond: configuration.bytesPerSecond)
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
                        for peer in peers.values { try sendJSON(peer.transport, ["type": "state", "state": "syncing"]) }
                    }
                    for id in Array(peers.keys) { schedule(id) }
                }
            } catch {
                if Task.isCancelled { break }
                latest = nil; captureEpoch = ""
                for id in Array(peers.keys) { reset(id) }
                let code = (error as? ObserverSourceFailure)?.code ?? "capture_failed"
                if self.error != code {
                    self.error = code
                    for (id, peer) in peers {
                        do { try sendJSON(peer.transport, ["type": "error", "code": code, "retryable": true]) }
                        catch { fail(id, "slow_consumer") }
                    }
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
        peer.transport.discard()
        peer.wake?.cancel(); peer.wake = nil
        peers[id] = peer
    }
    private func schedule(_ id: UUID) {
        guard var peer = peers[id], peer.active, peer.encoding == nil, encodingWork == nil,
              peer.client.inFlight == nil, let snapshot = latest else { return }
        let delay = peer.pacer.delay(at: clock())
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
            if batch.full {
                try sendMode(peer.transport)
                peer.controlBytes += try sendJSON(peer.transport, ["type": "welcome", "v": 1, "epoch": batch.epoch,
                                         "width": snapshot.grid.width, "height": snapshot.grid.height,
                                         "tileSize": snapshot.grid.tileSize, "codec": "png", "maxFps": configuration.maxFPS,
                                         "bytesPerSecond": configuration.bytesPerSecond ?? 0])
            }
            let policy = configuration.pngPolicy, encode = self.encode
            let task = Task.detached { try await encode(batch, policy) }, job = UUID()
            encodingWork = task
            peer.encoding = task; peer.encodingID = job; peers[id] = peer
            Task {
                do { let data = try await task.value; encoded(id, job: job, epoch: batch.epoch, data: data) }
                catch { encodingFailed(id, job: job, epoch: batch.epoch, error: error) }
            }
        } catch { fail(id, (error as? RelayFailure)?.code == "slow_consumer" ? "slow_consumer" : "protocol_error") }
    }
    private func wake(_ id: UUID) {
        guard var peer = peers[id] else { return }
        peer.wake = nil; peers[id] = peer; schedule(id)
    }
    private func encoded(_ id: UUID, job: UUID, epoch: String, data: Data) {
        encodingWork = nil
        guard var peer = peers[id], peer.encodingID == job else {
            for id in Array(peers.keys) { schedule(id) }; return
        }
        peer.encoding = nil; peer.encodingID = nil
        if peer.client.epoch == epoch { peer.sentSeq = peer.client.inFlight?.seq }
        peers[id] = peer
        guard peer.client.epoch == epoch, peer.active else { schedule(id); return }
        peer.started = clock(); peers[id] = peer
        do {
            guard try peer.transport.send(data, true) else { remove(id); return }
            peer.pacer.sent(bytes: data.count + peer.controlBytes, at: clock())
            peer.controlBytes = 0; peers[id] = peer
        } catch { fail(id, (error as? RelayFailure)?.code == "slow_consumer" ? "slow_consumer" : "protocol_error") }
    }
    private func encodingFailed(_ id: UUID, job: UUID, epoch: String, error: Error) {
        encodingWork = nil
        guard var peer = peers[id], peer.encodingID == job else {
            for id in Array(peers.keys) { schedule(id) }; return
        }
        peer.encoding = nil; peer.encodingID = nil; peers[id] = peer
        if peer.client.epoch != epoch || error is CancellationError { schedule(id) }
        else { fail(id, "protocol_error") }
    }
    private func tick() {
        for (id, peer) in peers {
            if let started = peer.started, clock() - started > ackTimeout { fail(id, "session_timeout"); continue }
            schedule(id)
        }
    }
    private func fail(_ id: UUID, _ code: String) {
        guard let peer = peers[id] else { return }
        peer.transport.close(code); remove(id)
    }
    @discardableResult private func sendJSON(_ transport: ObserverTransport, _ object: [String: Any]) throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try transport.send(data, false) ? data.count : 0
    }
}
