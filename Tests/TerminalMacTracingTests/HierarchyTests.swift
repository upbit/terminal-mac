import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterCommon
import TerminalMacCore
@testable import TerminalMacTracing
@testable import TerminalMac

private final class HierarchyExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SpanData] = []
    var succeeds = true
    var spans: [SpanData] { lock.lock(); defer { lock.unlock() }; return records }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        lock.lock(); defer { lock.unlock() }
        if succeeds { records += spans }
        return succeeds ? .success : .failure
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

final class HierarchyTests: XCTestCase {
    private let env = ["LANGFUSE_BASE_URL": "https://example.com", "LANGFUSE_PUBLIC_KEY": "pk-test",
                       "LANGFUSE_SECRET_KEY": "sk-test", "LANGFUSE_CONTENT_MODE": "content"]

    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor func testSeparateInstancesReconstructOneHierarchyAndIdempotentClosure() async throws {
        let directory = try temporary()
        let exporter = HierarchyExporter()
        let config = try LangfuseConfiguration.load(env)
        let first = LangfuseTracing(configuration: config, version: "test", exporter: exporter, storeDirectory: directory)
        let task = try first.begin(goal: "Open browser", sessionID: "conversation")
        let taskContext = try XCTUnwrap(task["context"] as? String)
        await first.shutdown()

        let second = LangfuseTracing(configuration: config, version: "test", exporter: exporter, storeDirectory: directory)
        let chain = try second.begin(goal: "Launch Safari", parent: taskContext, reason: "Inspect official documentation")
        let chainContext = try XCTUnwrap(chain["context"] as? String)
        XCTAssertThrowsError(try second.end(context: taskContext, chain: false, outcome: "success", summary: "Not yet"))
        await second.shutdown()

        let third = LangfuseTracing(configuration: config, version: "test", exporter: exporter, storeDirectory: directory)
        _ = await third.observeTool("type", arguments: ["text": "Safari"], channel: "cli", contextHandle: chainContext,
                                   reason: "Enter the application name", output: third.actionOutput) {
            await third.observeGuest(Request(action: "type", arguments: ["text": "Safari"])) {
                Reply(id: UUID(), values: ["result": "typed"])
            }.values
        }
        _ = try third.end(context: chainContext, chain: true, outcome: "success", summary: "Browser opened")
        _ = try third.end(context: taskContext, chain: false, outcome: "success", summary: "Verified by caller")
        let repeated = try third.end(context: taskContext, chain: false, outcome: "failed", summary: "Must not overwrite")
        XCTAssertEqual(repeated["status"] as? String, "success")
        await third.shutdown()

        XCTAssertEqual(exporter.spans.count, 4)
        let root = try XCTUnwrap(exporter.spans.first { $0.name == "run-desktop-task" })
        let step = try XCTUnwrap(exporter.spans.first { $0.name == "execute-desktop-chain" })
        let tool = try XCTUnwrap(exporter.spans.first { $0.name == "execute-type-tool" })
        let guest = try XCTUnwrap(exporter.spans.first { $0.name == "send-guest-type" })
        XCTAssertEqual(root.spanId.hexString, task["observation_id"] as? String)
        XCTAssertEqual(step.spanId.hexString, chain["observation_id"] as? String)
        XCTAssertNil(root.parentSpanId)
        XCTAssertEqual(step.parentSpanId, root.spanId)
        XCTAssertEqual(tool.parentSpanId, step.spanId)
        XCTAssertEqual(guest.parentSpanId, tool.spanId)
        for span in exporter.spans {
            XCTAssertEqual(span.traceId, root.traceId)
            XCTAssertEqual(span.attributes["langfuse.session.id"], .string("conversation"))
            XCTAssertGreaterThanOrEqual(span.endTime, span.startTime)
            let proto = SpanAdapter.toProtoSpan(spanData: span)
            XCTAssertEqual(proto.name, span.name)
            XCTAssertEqual(proto.droppedAttributesCount, 0)
        }
        XCTAssertTrue(String(describing: tool.attributes).contains("Safari"))
        XCTAssertEqual(step.attributes["langfuse.observation.metadata.reason"], .string("Inspect official documentation"))
    }

    @MainActor func testMCPTaskManagementAndInvalidContextFallback() async throws {
        let directory = try temporary()
        let exporter = HierarchyExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test",
                                      exporter: exporter, storeDirectory: directory)
        let server = AgentServer(store: Store(root: directory.appendingPathComponent("no-vm")), name: "default", tracing: tracing)
        let response = try await server.call("trace_begin", ["goal": "Check readiness"])
        let text = try XCTUnwrap(response.first?["text"] as? String)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let context = try XCTUnwrap(result["context"] as? String)
        do { _ = try await server.call("status", ["context": context]); XCTFail("Missing VM") } catch {}
        do { _ = try await server.call("status", ["context": "foreign"]); XCTFail("Missing VM") } catch {}
        _ = try await server.call("trace_end", ["context": context, "outcome": "failed", "summary": "VM missing"])
        await tracing.shutdown()
        let actions = exporter.spans.filter { $0.name == "execute-status-tool" }
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.filter { $0.parentSpanId != nil }.count, 1)
        XCTAssertEqual(actions.filter { $0.parentSpanId == nil }.count, 1)
        let toolNames = AgentServer.tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(toolNames.contains("chain_begin"))
        XCTAssertTrue(toolNames.contains("trace_status"))
    }

    @MainActor func testActiveCallPreventsClosingParent() async throws {
        let directory = try temporary()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test",
                                      exporter: HierarchyExporter(), storeDirectory: directory)
        let task = try tracing.begin(goal: "Work")
        let handle = try XCTUnwrap(task["context"] as? String)
        _ = try await tracing.observeTool("status", arguments: [:], channel: "mcp", contextHandle: handle, output: { _ in [:] }) {
            XCTAssertThrowsError(try tracing.end(context: handle, chain: false, outcome: "success", summary: "Premature"))
            return true
        }
        _ = try tracing.end(context: handle, chain: false, outcome: "success", summary: "Finished")
        await tracing.shutdown()
    }

    @MainActor func testRetryRetainsIdentitiesAndExpiredContextsRecover() async throws {
        let directory = try temporary()
        let exporter = HierarchyExporter()
        exporter.succeeds = false
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test",
                                      exporter: exporter, storeDirectory: directory)
        let task = try tracing.begin(goal: "Interrupted work")
        await tracing.shutdown()
        let store = try TracingStore(directory: directory)
        try store.recover(now: Date().addingTimeInterval(TracingStore.lifetime + 1))
        let batch = try store.claim()
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.span.spanId.hexString, task["observation_id"] as? String)
        XCTAssertEqual(batch.first?.span.attributes["langfuse.observation.status_message"], .string("interrupted"))
        try store.acknowledge(batch, success: false)
        XCTAssertTrue(try store.claim().isEmpty)
        let retry = try store.claim(now: Date().addingTimeInterval(60))
        XCTAssertEqual(retry.first?.id, batch.first?.id)
        try store.acknowledge(retry, success: true)
        XCTAssertEqual(try store.diagnostics()["pending"] as? Int, 0)
    }

    func testSanitizationBoundsAndSummaryPrivacy() throws {
        let policy = TracingContent(enabled: true, secrets: ["configured-private-value"])
        let json = policy.json(["text": "Safari configured-private-value token=hidden sk-lf-abc", "password": "hidden",
                                "image": "/private/screen.png", "data": "pixels"])
        XCTAssertTrue(json.contains("Safari"))
        for secret in ["configured-private-value", "hidden", "sk-lf-abc", "pixels", "/private/screen.png"] {
            XCTAssertFalse(json.contains(secret))
        }
        let summary = TracingContent(enabled: false, secrets: []).json(["goal": "private task", "reason": "private reason"])
        XCTAssertFalse(summary.contains("private"))
        XCTAssertTrue(summary.contains("goal"))
        let summaryOutput = TracingContent(enabled: false, secrets: []).json(["ok": true, "has_image": true, "image_blocks": 1, "text_blocks": 1])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summaryOutput.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["has_image"] as? Bool, true)
        XCTAssertEqual(decoded["image_blocks"] as? Int, 1)
        XCTAssertTrue(policy.text(String(repeating: "x", count: 5000)).contains("[TRUNCATED]"))
        let truncatedJSON = policy.json(["text": String(repeating: "x", count: 5000)])
        let capture = (try JSONSerialization.jsonObject(with: Data(truncatedJSON.utf8)) as? [String: Any])?["_capture"] as? [String: Any]
        XCTAssertEqual(capture?["truncated"] as? Bool, true)
        XCTAssertGreaterThan(capture?["original_bytes"] as? Int ?? 0, 4096)
        XCTAssertThrowsError(try LangfuseConfiguration.load(env.merging(["LANGFUSE_CONTENT_MODE": "invalid"]) { $1 }))
        XCTAssertEqual(try LangfuseConfiguration.load(env)?.projectScope,
                       try LangfuseConfiguration.load(env.merging(["LANGFUSE_BASE_URL": "https://example.com/"]) { $1 })?.projectScope)
    }

    @MainActor func testDisabledDoesNotCreateStoreAndZeroSampleCreatesNoOutbox() async throws {
        let directory = try temporary().appendingPathComponent("disabled")
        let disabled = LangfuseTracing(configuration: nil, version: "test", storeDirectory: directory)
        XCTAssertEqual(try disabled.begin(goal: "Work")["enabled"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let config = try LangfuseConfiguration.load(env.merging(["LANGFUSE_SAMPLE_RATE": "0"]) { $1 })
        let enabled = LangfuseTracing(configuration: config, version: "test", exporter: HierarchyExporter(), storeDirectory: directory)
        let task = try enabled.begin(goal: "Sampled out")
        let context = try XCTUnwrap(task["context"] as? String)
        _ = await enabled.observeTool("status", arguments: [:], channel: "mcp", contextHandle: context, output: { _ in [:] }) { true }
        _ = try enabled.end(context: context, chain: false, outcome: "success", summary: "Finished")
        await enabled.shutdown()
        XCTAssertEqual(try enabled.diagnostics()["pending"] as? Int, 0)
    }

    @MainActor func testCLIAndMCPProcessesSharePersistentContext() async throws {
        let root = try temporary()
        var environment = env
        environment["LANGFUSE_BASE_URL"] = "http://127.0.0.1:1"
        environment["TERMINAL_MAC_HOME"] = root.path
        let envFile = root.appendingPathComponent("config.env")
        try Data().write(to: envFile)
        environment["TERMINAL_MAC_ENV_FILE"] = envFile.path
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("terminal-mac")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Built CLI is unavailable") }

        func run(_ arguments: [String], input: Data? = nil) throws -> (Int32, Data) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errors = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertFalse(String(decoding: errors, as: UTF8.self).contains("sk-test"))
            XCTAssertEqual(process.terminationReason, .exit, String(decoding: errors, as: UTF8.self))
            return (process.terminationStatus, data)
        }
        func object(_ data: Data) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let (taskExit, taskData) = try run(["trace", "begin", "--goal", "Check VM", "--session", "shared-session"])
        XCTAssertEqual(taskExit, 0)
        let task = try object(taskData)
        let taskHandle = try XCTUnwrap(task["context"] as? String)
        let (chainExit, chainData) = try run(["chain", "begin", "--context", taskHandle, "--goal", "Readiness", "--reason", "Check permissions"])
        XCTAssertEqual(chainExit, 0)
        let chain = try object(chainData)
        let chainHandle = try XCTUnwrap(chain["context"] as? String)
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": "status-request", "method": "tools/call",
                                 "params": ["name": "status", "arguments": ["context": chainHandle]]]
        var input = try JSONSerialization.data(withJSONObject: rpc)
        input.append(10)
        let (mcpExit, mcpData) = try run(["mcp"], input: input)
        XCTAssertEqual(mcpExit, 0)
        let response = try XCTUnwrap(try object(mcpData)["result"] as? [String: Any])
        XCTAssertEqual(response["isError"] as? Bool, true)
        let metadata = try XCTUnwrap(response["_meta"] as? [String: Any])
        let correlation = try XCTUnwrap(metadata["terminal-mac/tracing"] as? [String: Any])
        XCTAssertEqual(correlation["trace_id"] as? String, task["trace_id"] as? String)
        let (actionExit, actionData) = try run(["action", "default", "status", "--context", chainHandle])
        XCTAssertEqual(actionExit, 1)
        XCTAssertTrue(actionData.isEmpty)
        XCTAssertEqual(try run(["chain", "end", "--context", chainHandle, "--outcome", "failed"] ).0, 0)
        XCTAssertEqual(try run(["trace", "end", "--context", taskHandle, "--outcome", "failed"] ).0, 0)

        let config = try XCTUnwrap(LangfuseConfiguration.load(environment))
        let store = try TracingStore(directory: root.appendingPathComponent("tracing/\(config.projectScope)"))
        let batch = try store.claim(now: Date().addingTimeInterval(3601))
        XCTAssertEqual(batch.count, 5)
        let span = try XCTUnwrap(batch.first { $0.span.spanId.hexString == correlation["observation_id"] as? String }?.span)
        XCTAssertEqual(span.parentSpanId?.hexString, chain["observation_id"] as? String)
        XCTAssertEqual(span.attributes["langfuse.observation.metadata.call_id"], .string("status-request"))
        for observation in batch { XCTAssertEqual(observation.span.traceId.hexString, task["trace_id"] as? String) }
    }

    @MainActor func testStoreBoundariesAndOversizedObservation() async throws {
        let root = try temporary()
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try TracingStore(directory: link))
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test",
                                      exporter: HierarchyExporter(), storeDirectory: root)
        let task = try tracing.begin(goal: "Bounded payload")
        let handle = try XCTUnwrap(task["context"] as? String)
        let store = try TracingStore(directory: root)
        var oversized = try store.acquire(handle).span
        oversized.settingAttributes(["oversized": .string(String(repeating: "x", count: TracingStore.maxRecordBytes))])
        try store.enqueue([oversized])
        XCTAssertEqual(try store.diagnostics()["dropped"] as? Int, 1)
        XCTAssertEqual(try store.diagnostics()["pending"] as? Int, 0)
        await tracing.shutdown()
    }

    @MainActor func testRenewedLeasePreventsPrematureLongTaskClosure() async throws {
        let directory = try temporary()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test",
                                      exporter: HierarchyExporter(), storeDirectory: directory)
        let task = try tracing.begin(goal: "Long-running installation")
        let handle = try XCTUnwrap(task["context"] as? String)
        let store = try TracingStore(directory: directory)
        _ = try store.acquire(handle, invocation: "live-call")
        try store.renew(handle, invocation: "live-call", now: Date().addingTimeInterval(120))
        try store.recover(now: Date().addingTimeInterval(181))
        XCTAssertThrowsError(try store.finish(handle, type: "span", outcome: "success", output: "{}"))
        try store.release(handle, invocation: "live-call")
        _ = try store.finish(handle, type: "span", outcome: "success", output: "{}")
        XCTAssertThrowsError(try store.renew(handle, invocation: "live-call"))
        await tracing.shutdown()
    }

    @MainActor func testFailedDeliveryStaysBoundedAndShutdownDoesNotRepeatOperation() async throws {
        let directory = try temporary()
        let exporter = HierarchyExporter()
        exporter.succeeds = false
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test",
                                      exporter: exporter, storeDirectory: directory)
        var executions = 0
        _ = await tracing.observeTool("status", arguments: [:], channel: "mcp", output: { _ in ["ok": true] }) {
            executions += 1; return true
        }
        await tracing.shutdown()
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(try tracing.diagnostics()["pending"] as? Int, 1)
        XCTAssertEqual(try tracing.diagnostics()["failed"] as? Int, 1)
        let restarted = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test",
                                       exporter: exporter, storeDirectory: directory)
        await restarted.shutdown()
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(try restarted.diagnostics()["pending"] as? Int, 1)
    }
}
