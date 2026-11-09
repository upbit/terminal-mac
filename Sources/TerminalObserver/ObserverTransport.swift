import Foundation
import TerminalMacCore

struct ObserverTransport: Sendable {
    let send: @Sendable (Data, Bool) throws -> Bool
    let discard: @Sendable () -> Void
    let close: @Sendable (String) -> Void
}

public final class RelayConnectionLifetime: @unchecked Sendable {
    public let generation = UUID()
    private let lock = NSLock()
    private var live = true, online = false
    public init() {}
    public var isOnline: Bool { lock.withLock { live && online } }
    func markOnline() { lock.withLock { if live { online = true } } }
    public func invalidate() { lock.withLock { live = false; online = false } }
}

// Synchronous bounded admission lets Hub register sent seq/ACK time without an actor hop.
// The one asynchronous writer owns socket sends; session replacement shares this same lock.
final class RelayControlWriter: @unchecked Sendable {
    private struct Entry {
        let data: Data, binary: Bool, session: UUID?, deadline: Double, ready: Bool
    }
    private let socket: any RelaySocket
    private let lifetime: RelayConnectionLifetime
    private let lock = NSLock()
    private let sendTimeout: Double
    private var queue: [Entry] = []
    private var bytes = 0, images = 0
    private var worker: Task<Void, Never>?
    private var stopped = false, readyStarted = false
    private var session: UUID?
    private var storedFailure: RelayFailure?
    init(socket: any RelaySocket, sendTimeout: UInt64 = 10_000_000_000,
         lifetime: RelayConnectionLifetime = RelayConnectionLifetime()) {
        self.socket = socket; self.sendTimeout = Double(sendTimeout) / 1_000_000_000; self.lifetime = lifetime
    }
    var failure: RelayFailure? { lock.withLock { storedFailure } }
    var bufferedBytes: Int { lock.withLock { bytes } }
    var bufferedImages: Int { lock.withLock { images } }
    func isCurrent(_ id: UUID, ready: Bool = false) -> Bool {
        lock.withLock { !stopped && session == id && (!ready || readyStarted) }
    }
    func enqueue(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        do { try lock.withLock { try append(data, binary: false, session: nil) } }
        catch { fail((error as? RelayFailure) ?? RelayFailure("protocol_error")); throw error }
    }
    func beginWatch(_ id: UUID) throws {
        let ready = try JSONSerialization.data(withJSONObject: ["type": "relay.watch.ready", "sessionId": id.uuidString])
        try lock.withLock {
            if let session { discardLocked(session) }
            session = id; readyStarted = false
            try append(ready, binary: false, session: id, ready: true)
        }
    }
    func endWatch(_ id: UUID, code: String? = nil) {
        do {
            try lock.withLock {
                guard session == id else { return }
                session = nil; readyStarted = false; discardLocked(id)
                if let code {
                    let data = try JSONSerialization.data(withJSONObject: ["type": "relay.watch.close", "sessionId": id.uuidString, "code": code])
                    try append(data, binary: false, session: nil)
                }
            }
        } catch { fail((error as? RelayFailure) ?? RelayFailure("protocol_error")) }
    }
    func transport(_ id: UUID) -> ObserverTransport {
        ObserverTransport(send: { [self] data, binary in
            let payload: Data
            if binary { payload = data }
            else {
                let message = try JSONSerialization.jsonObject(with: data)
                payload = try JSONSerialization.data(withJSONObject: ["type": "observer", "sessionId": id.uuidString, "message": message])
            }
            return try lock.withLock {
                guard session == id, !stopped else { return false }
                try append(payload, binary: binary, session: id)
                return true
            }
        }, discard: { [self] in lock.withLock { discardLocked(id) } },
        close: { [self] code in endWatch(id, code: code) })
    }
    private func append(_ data: Data, binary: Bool, session: UUID?, ready: Bool = false) throws {
        guard !stopped else { throw storedFailure ?? RelayFailure("network_error", retryable: true) }
        guard data.count <= (binary ? ObserverLimits.maxMessageBytes : ObserverLimits.maxControlBytes) else {
            throw RelayFailure("message_too_large")
        }
        guard binary ? images == 0 : bytes + data.count <= 65536 else { throw RelayFailure("slow_consumer", retryable: true) }
        if binary { images += 1 } else { bytes += data.count }
        queue.append(Entry(data: data, binary: binary, session: session,
                           deadline: ProcessInfo.processInfo.systemUptime + (ready ? min(5, sendTimeout) : sendTimeout), ready: ready))
        if worker == nil { worker = Task { await drain() } }
    }
    private func discardLocked(_ id: UUID?) {
        queue.removeAll { entry in
            guard id == nil || entry.session == id else { return false }
            if entry.binary { images -= 1 } else { bytes -= entry.data.count }
            return true
        }
    }
    private func take() -> Entry? {
        lock.withLock {
            guard !stopped, !queue.isEmpty else { worker = nil; return nil }
            let entry = queue.removeFirst()
            if entry.ready && session == entry.session { readyStarted = true }
            return entry
        }
    }
    private func drain() async {
        while let entry = take() {
            let remaining = entry.deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { fail(RelayFailure("send_timeout", retryable: true)) }
            else {
                let deadline = Task { [self] in
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
                    fail(RelayFailure("send_timeout", retryable: true))
                }
                do {
                    if entry.binary { try await socket.sendBinary(entry.data) }
                    else { try await socket.sendText(entry.data) }
                } catch { fail(RelayFailure("network_error", retryable: true)) }
                deadline.cancel(); await deadline.value
            }
            lock.withLock {
                if entry.binary { images -= 1 } else { bytes -= entry.data.count }
            }
        }
    }
    private func fail(_ error: RelayFailure) {
        lock.withLock { if storedFailure == nil { storedFailure = error }; stopped = true; discardLocked(nil) }
        lifetime.invalidate(); socket.close()
    }
    func stop() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            stopped = true; session = nil; discardLocked(nil); return worker
        }
        lifetime.invalidate(); socket.close()
        await task?.value
    }
}
