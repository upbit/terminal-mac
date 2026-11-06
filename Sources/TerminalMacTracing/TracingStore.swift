import Darwin
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import TerminalMacCore

struct TracingNode: Codable {
    let handle: String
    let parent: String?
    var span: SpanData
    let expires: Date
    var outcome: String?
    var activeCalls: [String: Date] = [:]

    var context: SpanContext {
        .createFromRemoteParent(traceId: span.traceId, spanId: span.spanId,
                                traceFlags: span.traceFlags, traceState: span.traceState)
    }
    var response: [String: Any] {
        ["enabled": true, "context": handle, "trace_id": span.traceId.hexString,
         "observation_id": span.spanId.hexString, "status": outcome ?? "open"]
    }
}

struct QueuedObservation: Codable {
    let id: String
    let span: SpanData
    let created: Date
    var attempts = 0
    var nextAttempt: Date
}

private struct TracingState: Codable {
    var schema = 1
    var nodes: [String: TracingNode] = [:]
    var outbox: [QueuedObservation] = []
    var dropped = 0
    var failed = 0
}

/// A host-private, bounded store. The pinned mailbox API provides safe atomic file IO.
final class TracingStore: @unchecked Sendable {
    static let lifetime: TimeInterval = 24 * 3600
    static let retention: TimeInterval = 7 * 24 * 3600
    static let maxNodes = 256
    static let maxQueued = 512
    static let maxRecordBytes = 65_536
    static let maxOutboxBytes = 8 * 1024 * 1024
    private let mailbox: Mailbox
    private let fd: Int32
    private let threadLock = NSLock()

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw Failure("Tracing store must be a private directory owned by the current user.")
        }
        mailbox = try Mailbox(directory)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure("Cannot open tracing directory.") }
        defer { close(directoryFD) }
        fd = openat(directoryFD, "store.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open tracing store lock.") }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw Failure("Invalid tracing store lock.")
        }
        do { _ = try transaction { _ in () } }
        catch { close(fd); throw error }
    }
    deinit { close(fd) }

    private func transaction<T>(_ body: (inout TracingState) throws -> T) throws -> T {
        guard threadLock.try() else { throw Failure("Tracing store is busy.") }
        defer { threadLock.unlock() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Tracing store is busy.") }
        defer { flock(fd, LOCK_UN) }
        let data = try mailbox.read("state.json", limit: 16 * 1024 * 1024)
        var state = try data.map { try JSONDecoder().decode(TracingState.self, from: $0) } ?? TracingState()
        guard state.schema == 1 else { throw Failure("Unsupported tracing store schema; tracing is disabled.") }
        let value = try body(&state)
        let encoded = try JSONEncoder().encode(state)
        guard encoded.count <= 16 * 1024 * 1024 else { throw Failure("Tracing store reached its size limit.") }
        try mailbox.write(encoded, named: "state.json")
        return value
    }

    func insert(_ node: TracingNode) throws {
        try transaction { state in
            if let parent = node.parent {
                guard let existing = state.nodes[parent], existing.outcome == nil, existing.expires > Date() else {
                    throw Failure("Tracing parent is missing, expired, or closed.")
                }
            }
            if state.nodes.count >= Self.maxNodes,
               let oldest = state.nodes.values.filter({ $0.outcome != nil })
                .min(by: { $0.span.endTime < $1.span.endTime }) {
                state.nodes.removeValue(forKey: oldest.handle)
            }
            guard state.nodes.count < Self.maxNodes else { throw Failure("Tracing context capacity reached; finish an open task or chain first.") }
            state.nodes[node.handle] = node
        }
    }

    func acquire(_ handle: String, invocation: String? = nil) throws -> TracingNode {
        guard UUID(uuidString: handle) != nil else { throw Failure("Invalid tracing context.") }
        return try transaction { state in
            guard var node = state.nodes[handle], node.outcome == nil, node.expires > Date() else {
                throw Failure("Tracing context is missing, expired, or closed.")
            }
            if let invocation {
                guard node.activeCalls.count < 64 else { throw Failure("Tracing active call capacity reached.") }
                node.activeCalls[invocation] = Date().addingTimeInterval(180)
                state.nodes[handle] = node
            }
            return node
        }
    }

    func release(_ handle: String, invocation: String) throws {
        _ = try transaction { state in state.nodes[handle]?.activeCalls.removeValue(forKey: invocation) }
    }

    func renew(_ handle: String, invocation: String, now: Date = Date()) throws {
        try transaction { state in
            guard var node = state.nodes[handle], node.outcome == nil, node.expires > now,
                  node.activeCalls[invocation] != nil else { throw Failure("Tracing call lease is no longer active.") }
            node.activeCalls[invocation] = now.addingTimeInterval(180)
            state.nodes[handle] = node
        }
    }

    func finish(_ handle: String, type: String, outcome: String, output: String) throws -> TracingNode {
        guard ["success", "failed", "cancelled"].contains(outcome), UUID(uuidString: handle) != nil else {
            throw Failure("Invalid tracing context or outcome (success, failed, cancelled).")
        }
        return try transaction { state in
            guard var node = state.nodes[handle], node.span.attributes["langfuse.observation.type"] == .string(type) else {
                throw Failure("Tracing context is missing or has the wrong type.")
            }
            if node.outcome != nil { return node }
            guard node.expires > Date() else { throw Failure("Tracing context has expired.") }
            guard !state.nodes.values.contains(where: { $0.parent == handle && $0.outcome == nil }),
                  node.activeCalls.isEmpty else { throw Failure("Finish child chains and active calls before ending this context.") }
            node.outcome = outcome
            var attributes = node.span.attributes
            attributes["langfuse.observation.output"] = .string(output)
            attributes["langfuse.observation.metadata.outcome"] = .string(outcome)
            attributes["langfuse.observation.metadata.result_source"] = .string("caller")
            if outcome != "success" {
                attributes["langfuse.observation.level"] = .string("ERROR")
                attributes["langfuse.observation.status_message"] = .string(outcome)
            }
            node.span.settingAttributes(attributes)
            node.span.settingTotalAttributeCount(attributes.count)
            node.span.settingEndTime(Date())
            node.span.settingHasEnded(true)
            node.span.settingStatus(outcome == "success" ? .ok : .error(description: outcome))
            state.nodes[handle] = node
            Self.enqueue(node.span, into: &state)
            return node
        }
    }

    func enqueue(_ spans: [SpanData]) throws {
        try transaction { state in for span in spans { Self.enqueue(span, into: &state) } }
    }

    private static func enqueue(_ span: SpanData, into state: inout TracingState) {
        guard span.traceFlags.sampled else { return }
        let id = span.traceId.hexString + ":" + span.spanId.hexString
        guard !state.outbox.contains(where: { $0.id == id }) else { return }
        let record = QueuedObservation(id: id, span: span, created: Date(), nextAttempt: Date())
        let encoder = JSONEncoder()
        let bytes = (try? encoder.encode(record).count) ?? (maxRecordBytes + 1)
        let queuedBytes = state.outbox.reduce(0) { $0 + ((try? encoder.encode($1).count) ?? 0) }
        if state.outbox.count >= maxQueued || bytes > maxRecordBytes || queuedBytes + bytes > maxOutboxBytes {
            state.dropped += 1; return
        }
        state.outbox.append(record)
    }

    func recover(now: Date = Date()) throws {
        try transaction { state in
            for handle in Array(state.nodes.keys) {
                guard var node = state.nodes[handle] else { continue }
                if now > node.expires.addingTimeInterval(Self.retention) { state.nodes.removeValue(forKey: handle); continue }
                node.activeCalls = node.activeCalls.filter { $0.value > now }
                if node.outcome == nil && node.expires <= now {
                    node.outcome = "interrupted"
                    var attributes = node.span.attributes
                    attributes["langfuse.observation.level"] = .string("WARNING")
                    attributes["langfuse.observation.status_message"] = .string("interrupted")
                    attributes["langfuse.observation.metadata.end_time_source"] = .string("expiry-boundary")
                    node.span.settingAttributes(attributes)
                    node.span.settingTotalAttributeCount(attributes.count)
                    node.span.settingEndTime(node.expires)
                    node.span.settingHasEnded(true)
                    node.span.settingStatus(.error(description: "interrupted"))
                    Self.enqueue(node.span, into: &state)
                }
                state.nodes[handle] = node
            }
            let count = state.outbox.count
            state.outbox.removeAll { now.timeIntervalSince($0.created) > Self.retention }
            state.dropped += count - state.outbox.count
        }
    }

    func claim(now: Date = Date()) throws -> [QueuedObservation] {
        try transaction { state in
            let indices = state.outbox.indices.filter { state.outbox[$0].nextAttempt <= now }.prefix(64)
            var batch: [QueuedObservation] = []
            for index in indices {
                state.outbox[index].attempts += 1
                // Lease prevents concurrent processes from sending the same batch immediately.
                state.outbox[index].nextAttempt = now.addingTimeInterval(30)
                batch.append(state.outbox[index])
            }
            return batch
        }
    }

    func acknowledge(_ batch: [QueuedObservation], success: Bool, permanentFailure: Bool = false) throws {
        try transaction { state in
            let ids = Set(batch.map(\.id))
            if success { state.outbox.removeAll { ids.contains($0.id) } }
            else {
                state.failed += batch.count
                for index in state.outbox.indices where ids.contains(state.outbox[index].id) {
                    state.outbox[index].nextAttempt = Date().addingTimeInterval(permanentFailure ? 3600 : min(3600, pow(2, Double(min(12, state.outbox[index].attempts)))))
                }
            }
        }
    }

    func diagnostics() throws -> [String: Any] {
        try transaction { state in
            ["pending": state.outbox.count, "failed": state.failed, "dropped": state.dropped,
             "open_contexts": state.nodes.values.filter { $0.outcome == nil }.count]
        }
    }
}

final class StoreExporter: SpanExporter {
    private let store: TracingStore
    init(_ store: TracingStore) { self.store = store }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        // Runs on the SDK export worker, never waits for file locks on the Viewer actor.
        for attempt in 0..<5 {
            do { try store.enqueue(spans); return .success }
            catch {
                if attempt < 4 { Thread.sleep(forTimeInterval: 0.01 * Double(attempt + 1)) }
            }
        }
        tracingWarning("Cannot persist telemetry; desktop execution is unaffected.")
        return .failure
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}
