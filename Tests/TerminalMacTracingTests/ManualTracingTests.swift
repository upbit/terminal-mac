import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
import TerminalMacCore
@testable import TerminalMacTracing
@testable import TerminalMac

private final class ManualExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SpanData] = []
    var spans: [SpanData] { lock.lock(); defer { lock.unlock() }; return records }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        lock.lock(); records += spans; lock.unlock(); return .success
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

final class ManualTracingTests: XCTestCase {
    private let env = ["LANGFUSE_BASE_URL": "https://example.com", "LANGFUSE_PUBLIC_KEY": "pk-test", "LANGFUSE_SECRET_KEY": "sk-test",
                       "LANGFUSE_CONTENT_MODE": "content"]
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    @MainActor func testManualAttachedThenIndependentAndPausedInput() async throws {
        let exporter = ManualExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter, storeDirectory: try directory())
        let task = try tracing.begin(goal: "Task")
        let handle = try XCTUnwrap(task["context"] as? String)
        let manual = ManualTracing(tracing: tracing)
        try manual.attach(handle)
        let request = Request(action: "type", arguments: ["text": "visible fixture"])
        let ticket = manual.ticket()
        _ = await manual.execute(request, ticket: ticket) { Reply(id: request.id, values: ["result": "typed fixture"]) }
        try manual.detach()
        let independent = Request(action: "key", arguments: ["key": "return"])
        _ = await manual.execute(independent, ticket: manual.ticket()) { Reply(id: independent.id) }
        let privateTicket = manual.ticket()
        manual.setPaused(true)
        XCTAssertFalse(manual.canMerge(privateTicket))
        let hidden = Request(action: "type", arguments: ["text": "password-fixture-do-not-export"])
        _ = await manual.execute(hidden, ticket: privateTicket) { Reply(id: hidden.id, values: ["result": "private-response-fixture"]) }
        _ = try tracing.end(context: handle, chain: false, outcome: "success", summary: "Finished")
        await tracing.shutdown()
        let manualBranch = try XCTUnwrap(exporter.spans.first { $0.name == "execute-desktop-chain" })
        XCTAssertEqual(manualBranch.parentSpanId?.hexString, task["observation_id"] as? String)
        let attached = try XCTUnwrap(exporter.spans.first { $0.name == "execute-type-tool" && $0.parentSpanId == manualBranch.spanId })
        XCTAssertTrue(String(describing: attached.attributes).contains("visible fixture"))
        let independentSpan = try XCTUnwrap(exporter.spans.first { $0.name == "execute-key-tool" })
        XCTAssertNil(independentSpan.parentSpanId)
        XCTAssertNotEqual(independentSpan.traceId, attached.traceId)
        for span in exporter.spans where span.name.hasSuffix("-tool") {
            XCTAssertEqual(span.attributes["langfuse.observation.metadata.actor"], .string("human"))
            XCTAssertEqual(span.attributes["langfuse.observation.metadata.source"], .string("viewer"))
        }
        let all = String(describing: exporter.spans.map(\.attributes))
        XCTAssertFalse(all.contains("password-fixture-do-not-export"))
        XCTAssertFalse(all.contains("private-response-fixture"))
        XCTAssertTrue(all.contains("paused"))
    }

    @MainActor func testMergedAndDroppedManualRequestsDoNotExecute() async throws {
        let exporter = ManualExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        let manual = ManualTracing(tracing: tracing)
        let first = manual.ticket(), merged = manual.ticket(merging: manual.ticket(merging: first))
        XCTAssertEqual(merged.firstSequence, 1)
        XCTAssertEqual(merged.lastSequence, 3)
        XCTAssertEqual(merged.merged, 3)
        await manual.dropped(Request(action: "type", arguments: ["text": "dropped-secret-fixture"]), ticket: merged, cause: "queue-full")
        await tracing.shutdown()
        XCTAssertEqual(exporter.spans.count, 1)
        let span = try XCTUnwrap(exporter.spans.first)
        XCTAssertEqual(span.attributes["langfuse.observation.metadata.queue_state"], .string("queue-full"))
        XCTAssertEqual(span.attributes["langfuse.observation.metadata.merge_count"], .string("3"))
        XCTAssertFalse(String(describing: span.attributes).contains("dropped-secret-fixture"))
    }

    @MainActor func testNestedProgrammaticStepInheritsButManualDoesNot() async throws {
        let exporter = ManualExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        let manual = ManualTracing(tracing: tracing)
        _ = await tracing.observeTool("unknown", arguments: [:], channel: "cli", operationName: "execute-up-command", output: { _ in [:] }) {
            _ = await tracing.observeTool("unknown", arguments: [:], channel: "cli", operationName: "install-guest-os", output: { _ in [:] }) { true }
            let request = Request(action: "click")
            return await manual.execute(request, ticket: manual.ticket()) { Reply(id: request.id) }
        }
        await tracing.shutdown()
        let parent = try XCTUnwrap(exporter.spans.first { $0.name == "execute-up-command" })
        let child = try XCTUnwrap(exporter.spans.first { $0.name == "install-guest-os" })
        XCTAssertEqual(child.parentSpanId, parent.spanId)
        XCTAssertNil(exporter.spans.first { $0.name == "execute-click-tool" }?.parentSpanId)
    }

    @MainActor func testMCPInvalidNumericInputFailsWithoutTrap() async throws {
        let tracing = LangfuseTracing(configuration: nil, version: "test")
        let server = AgentServer(store: Store(root: try directory()), name: "default", tracing: tracing)
        for value: Any in [Double.nan, Double.infinity, 1e50, true, 1.25] {
            do { _ = try await server.call("click", ["x": value, "y": 2]); XCTFail("Invalid value accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("invalid integer")) }
        }
    }

    @MainActor func testTracingOptionsRespectLiteralArgumentsAndDoNotInferActor() {
        let literal = CLI.tracingOptions(["type", "--", "--context", "literal-text"])
        XCTAssertNil(literal.context)
        XCTAssertEqual(literal.remaining, ["type", "--", "--context", "literal-text"])
        let options = CLI.tracingOptions(["click", "--context", "handle", "3", "4", "--reason", "audit purpose", "--actor", "ai"])
        XCTAssertEqual(options.remaining, ["click", "3", "4"])
        XCTAssertEqual(options.actor, "ai")
        XCTAssertEqual(CLI.tracingOptions(["status"]).actor, "unknown")
    }

    @MainActor func testPublicCommandAndActionValidationBoundariesAreTraced() async throws {
        let exporter = ManualExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        let cli = CLI(store: Store(root: try directory()), tracing: tracing)
        try await cli.run(["doctor"])
        try await cli.run(["up", "--plan"])
        for input in [["action", "default", "type", "--timeout", "not-a-number"], ["status", "--invalid"], ["private-invalid-command"]] {
            do { try await cli.run(input); XCTFail("Expected validation error") } catch {}
        }
        await cli.shutdownTracing()
        XCTAssertEqual(exporter.spans.count, 5)
        XCTAssertTrue(exporter.spans.contains { $0.name == "execute-type-tool" && $0.status.isError })
        let doctor = try XCTUnwrap(exporter.spans.first { $0.name == "execute-doctor-command" })
        XCTAssertTrue(String(describing: doctor.attributes).contains("virtualizationSupported"))
        let plan = try XCTUnwrap(exporter.spans.first { $0.name == "execute-up-command" })
        XCTAssertEqual(plan.attributes["langfuse.observation.metadata.exit_code"], .string("0"))
        let all = String(describing: exporter.spans.map(\.attributes))
        XCTAssertFalse(all.contains("not-a-number"))
        XCTAssertFalse(exporter.spans.map(\.name).contains("execute-private-invalid-command-command"))
    }

    func testHTTPFailureClassification() {
        for status in [401, 403, 404, 302] { XCTAssertTrue(TracingHTTPFailure(status: status).permanent) }
        for status in [0, 200, 204, 408, 429, 500, 503] { XCTAssertFalse(TracingHTTPFailure(status: status).permanent) }
    }

    @MainActor func testPauseDuringInflightCallSuppressesInputAndOutputEvenAfterResume() async throws {
        let exporter = ManualExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        let manual = ManualTracing(tracing: tracing)
        let request = Request(action: "type", arguments: ["text": "inflight-private-input"])
        _ = await manual.execute(request, ticket: manual.ticket()) {
            manual.setPaused(true)
            manual.setPaused(false)
            return Reply(id: request.id, values: ["result": "inflight-private-output"])
        }
        await tracing.shutdown()
        let all = String(describing: exporter.spans.map(\.attributes))
        XCTAssertFalse(all.contains("inflight-private-input"))
        XCTAssertFalse(all.contains("inflight-private-output"))
    }
}
