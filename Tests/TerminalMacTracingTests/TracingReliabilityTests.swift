import Darwin
import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterCommon
import TerminalMacCore
@testable import TerminalMacTracing

private final class FaultProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var code = 200
    nonisolated(unsafe) private static var stored: [URLRequest] = []
    static func reset(status: Int) { lock.lock(); code = status; stored = []; lock.unlock() }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock(); let status = Self.code; Self.stored.append(captured); Self.lock.unlock()
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DiscardExporter: SpanExporter {
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

final class TracingReliabilityTests: XCTestCase {
    private let env = ["LANGFUSE_BASE_URL": "https://example.com", "LANGFUSE_PUBLIC_KEY": "pk-test",
                       "LANGFUSE_SECRET_KEY": "sk-test", "LANGFUSE_CONTENT_MODE": "content"]

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func span() throws -> SpanData {
        let provider = TracerProviderBuilder().build()
        let live = provider.get(instrumentationName: "test").spanBuilder(spanName: "execute-test").startSpan()
        live.end()
        return try XCTUnwrap(live as? ReadableSpan).toSpanData()
    }

    @MainActor func testHTTPFaultsRetainSpansBackoffAndNeverRepeatActions() async throws {
        let configuration = try XCTUnwrap(LangfuseConfiguration.load(env))
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [FaultProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let client = DiagnosticHTTPClient(session: session)
        let exporter = LangfuseTracing.makeExporter(configuration, httpClient: client)
        for status in [0, 401, 403, 404, 302, 408, 429, 500, 503] {
            FaultProtocol.reset(status: status)
            let root = try directory()
            let tracing = LangfuseTracing(configuration: configuration, version: "test", exporter: exporter, storeDirectory: root)
            var executions = 0
            _ = await tracing.observeTool("status", arguments: [:], channel: "mcp", output: { _ in ["ok": true] }) {
                executions += 1; return true
            }
            await tracing.shutdown()
            XCTAssertEqual(executions, 1)
            XCTAssertEqual(FaultProtocol.requests.count, 1)
            XCTAssertEqual(try tracing.diagnostics()["pending"] as? Int, 1)
            let store = try TracingStore(directory: root)
            XCTAssertTrue(try store.claim().isEmpty)
            let early = try store.claim(now: Date().addingTimeInterval(10))
            if TracingHTTPFailure(status: status).permanent { XCTAssertTrue(early.isEmpty) }
            else { XCTAssertEqual(early.count, 1) }
            let retry = early.isEmpty ? try store.claim(now: Date().addingTimeInterval(3601)) : early
            let originalRequest = try XCTUnwrap(FaultProtocol.requests.first?.httpBody)
            let original = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: originalRequest)
            FaultProtocol.reset(status: 200)
            let result = await Task.detached { exporter.export(spans: retry.map(\.span), explicitTimeout: 2) }.value
            XCTAssertEqual(result, .success)
            try store.acknowledge(retry, success: true)
            XCTAssertEqual(executions, 1)
            XCTAssertEqual(try store.diagnostics()["pending"] as? Int, 0)
            let retried = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: XCTUnwrap(FaultProtocol.requests.first?.httpBody))
            XCTAssertEqual(original.resourceSpans.first?.scopeSpans.first?.spans.first?.spanID,
                           retried.resourceSpans.first?.scopeSpans.first?.spans.first?.spanID)
            XCTAssertFalse(String(describing: retried).contains("sk-test"))
        }
    }

    func testQueueOverflowLeasesDeduplicationAndRetention() throws {
        let store = try TracingStore(directory: directory())
        let base = try span()
        var spans: [SpanData] = []
        for _ in 0...TracingStore.maxQueued {
            var item = base; item.settingSpanId(.random()); spans.append(item)
        }
        try store.enqueue(spans)
        XCTAssertEqual(try store.diagnostics()["pending"] as? Int, TracingStore.maxQueued)
        XCTAssertEqual(try store.diagnostics()["dropped"] as? Int, 1)
        try store.enqueue([spans[0]])
        XCTAssertEqual(try store.diagnostics()["dropped"] as? Int, 1)
        let first = try store.claim()
        let second = try store.claim()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        try store.recover(now: Date().addingTimeInterval(TracingStore.retention + 1))
        XCTAssertEqual(try store.diagnostics()["pending"] as? Int, 0)
        XCTAssertEqual(try store.diagnostics()["dropped"] as? Int, TracingStore.maxQueued + 1)
    }

    func testCompletedContextsEvictedUnderPressureButOpenContextsKept() throws {
        let store = try TracingStore(directory: directory())
        var base = try span()
        base.settingAttributes(["langfuse.observation.type": .string("span")])
        base.settingTotalAttributeCount(1)
        let active = TracingNode(handle: UUID().uuidString, parent: nil, span: base, expires: Date().addingTimeInterval(3600))
        try store.insert(active)
        var handles: [String] = []
        for index in 1..<TracingStore.maxNodes {
            var item = base; item.settingEndTime(Date().addingTimeInterval(Double(index - TracingStore.maxNodes)))
            let node = TracingNode(handle: UUID().uuidString, parent: nil, span: item, expires: Date().addingTimeInterval(3600), outcome: "success")
            handles.append(node.handle); try store.insert(node)
        }
        let new = TracingNode(handle: UUID().uuidString, parent: active.handle, span: base, expires: active.expires)
        try store.insert(new)
        XCTAssertNoThrow(try store.acquire(active.handle))
        XCTAssertNoThrow(try store.acquire(new.handle))
        XCTAssertThrowsError(try store.finish(handles[0], type: "span", outcome: "success", output: "{}"))
        XCTAssertNoThrow(try store.finish(handles[1], type: "span", outcome: "success", output: "{}"))
        XCTAssertEqual(try store.diagnostics()["open_contexts"] as? Int, 2)
    }

    @MainActor func testCorruptFutureSchemaAndSymlinkStateDisableTracingWithoutControlFailure() async throws {
        for mode in ["corrupt", "future", "symlink"] {
            let root = try directory()
            let mailbox = try Mailbox(root)
            if mode == "symlink" {
                let target = root.appendingPathComponent("untouched")
                try Data("private-fixture".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("state.json"), withDestinationURL: target)
            } else {
                try mailbox.write(Data((mode == "corrupt" ? "invalid" : "{\"schema\":99,\"nodes\":{},\"outbox\":[],\"dropped\":0,\"failed\":0}").utf8), named: "state.json")
            }
            let before = try? mailbox.read("state.json")
            let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: DiscardExporter(), storeDirectory: root)
            XCTAssertFalse(tracing.isEnabled)
            let result = await tracing.observeTool("status", arguments: [:], channel: "mcp", output: { _ in XCTFail("Disabled serializer called"); return [:] }) { 42 }
            XCTAssertEqual(result, 42)
            XCTAssertEqual(try? mailbox.read("state.json"), before)
            if mode == "symlink" { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("untouched")), "private-fixture") }
            await tracing.shutdown()
        }
    }

    @MainActor func testStorageLockContentionFailsTelemetryNotAction() async throws {
        let root = try directory()
        let store = try TracingStore(directory: root)
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: DiscardExporter(), storeDirectory: root)
        let fd = open(root.appendingPathComponent("store.lock").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.enqueue([span()]))
        let value = await tracing.observeTool("status", arguments: [:], channel: "mcp", contextHandle: UUID().uuidString,
                                               output: { _ in ["ok": true] }) { 17 }
        XCTAssertEqual(value, 17)
        flock(fd, LOCK_UN)
        await tracing.shutdown()
    }

    @MainActor func testWriteFailureKeepsPreviousStateAndDoesNotFailAction() async throws {
        let parent = try directory(), root = parent.appendingPathComponent("store"), moved = parent.appendingPathComponent("moved")
        let store = try TracingStore(directory: root)
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: DiscardExporter(), storeDirectory: root)
        try FileManager.default.moveItem(at: root, to: moved)
        let before = try Data(contentsOf: moved.appendingPathComponent("state.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: moved.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: moved.path) }
        XCTAssertThrowsError(try store.enqueue([span()]))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("state.json")), before)
        let value = await tracing.observeTool("status", arguments: [:], channel: "cli", output: { _ in ["ok": true] }) { true }
        XCTAssertTrue(value)
        await tracing.shutdown()
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("state.json")), before)
    }

    @MainActor func testShutdownIsIdempotentAndFutureCallsAreUninstrumented() async throws {
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: DiscardExporter(), storeDirectory: try directory())
        await tracing.shutdown()
        await tracing.shutdown()
        XCTAssertFalse(tracing.isEnabled)
        XCTAssertEqual(try tracing.begin(goal: "After shutdown")["enabled"] as? Bool, false)
        let value = await tracing.observeTool("status", arguments: [:], channel: "cli", output: { _ in XCTFail("Serializer called after shutdown"); return [:] }) { 9 }
        XCTAssertEqual(value, 9)
    }

    @MainActor func testClientFacingErrorExplanationIsPreservedAlongsideErrorCategory() async throws {
        let root = try directory()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: DiscardExporter(), storeDirectory: root)
        do {
            _ = try await tracing.observeTool("status", arguments: [:], channel: "mcp",
                errorOutput: { _ in ["message": "Ask the user to sign into the guest", "isError": true,
                    "content": [["type": "text", "text": "Ask the user to sign into the guest"]]] }, output: { (_: Bool) in [:] }) {
                    throw Failure("Raw transport exception")
                }
            XCTFail("Original failure not propagated")
        } catch { XCTAssertEqual(error.localizedDescription, "Raw transport exception") }
        await tracing.checkpoint()
        let store = try TracingStore(directory: root)
        let batch = try store.claim()
        let observation = try XCTUnwrap(batch.first?.span)
        guard case .string(let serialized) = observation.attributes["langfuse.observation.output"] else { return XCTFail("Missing output") }
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any])
        XCTAssertEqual(output["message"] as? String, "Ask the user to sign into the guest")
        XCTAssertEqual(output["error"] as? String, "tool-failed")
        XCTAssertEqual(output["isError"] as? Bool, true)
        try store.acknowledge(batch, success: true)
        await tracing.shutdown()
    }
}
