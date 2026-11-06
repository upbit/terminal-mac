import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import OpenTelemetryProtocolExporterCommon
import TerminalMacCore
@testable import TerminalMacTracing
@testable import TerminalMac

private final class RecordingExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SpanData] = []
    var spans: [SpanData] { lock.lock(); defer { lock.unlock() }; return stored }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        lock.lock(); defer { lock.unlock() }; stored += spans; return .success
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

private final class RecordingHTTPClient: HTTPClient {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        lock.lock(); stored.append(request); lock.unlock()
        completion(.success(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
    func send(request: URLRequest) async throws -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

final class TracingTests: XCTestCase {
    private let env = ["LANGFUSE_BASE_URL": "https://example.com/langfuse/",
                       "LANGFUSE_PUBLIC_KEY": "pk-test", "LANGFUSE_SECRET_KEY": "sk-test"]

    func testConfigurationIsOptInAndExplicitlyDisableable() throws {
        XCTAssertNil(try LangfuseConfiguration.load([:]))
        XCTAssertNil(try LangfuseConfiguration.load(env.merging(["LANGFUSE_TRACING_ENABLED": "false"]) { $1 }))
        XCTAssertThrowsError(try LangfuseConfiguration.load(["LANGFUSE_TRACING_ENABLED": "true"]))
        XCTAssertThrowsError(try LangfuseConfiguration.load(["LANGFUSE_PUBLIC_KEY": "pk-test"]))
    }

    func testEndpointRegionAuthenticationAndHostAlias() throws {
        let config = try XCTUnwrap(LangfuseConfiguration.load(env))
        XCTAssertEqual(config.endpoint.absoluteString, "https://example.com/langfuse/api/public/otel/v1/traces")
        XCTAssertEqual(config.authorization, "Basic " + Data("pk-test:sk-test".utf8).base64EncodedString())
        XCTAssertEqual(config.environment, "development")
        var alias = env; alias.removeValue(forKey: "LANGFUSE_BASE_URL"); alias["LANGFUSE_HOST"] = "https://us.cloud.langfuse.com"
        XCTAssertEqual(try LangfuseConfiguration.load(alias)?.endpoint.host, "us.cloud.langfuse.com")
    }

    func testRejectsInsecureOrAmbiguousConfigurationWithoutEchoingSecrets() {
        for url in ["http://example.com", "https://user:password@example.com", "https://example.com?token=secret", "https://example.com#secret", "not-a-url"] {
            XCTAssertThrowsError(try LangfuseConfiguration.load(env.merging(["LANGFUSE_BASE_URL": url]) { $1 })) { error in
                XCTAssertFalse(error.localizedDescription.contains("password"))
                XCTAssertFalse(error.localizedDescription.contains("sk-test"))
            }
        }
        for rate in ["NaN", "inf", "-0.1", "1.1", "garbage"] {
            XCTAssertThrowsError(try LangfuseConfiguration.load(env.merging(["LANGFUSE_SAMPLE_RATE": rate]) { $1 }))
        }
        XCTAssertThrowsError(try LangfuseConfiguration.load(env.merging(["LANGFUSE_TRACING_ENVIRONMENT": "Bad environment"]){ $1 }))
        XCTAssertNoThrow(try LangfuseConfiguration.load(env.merging(["LANGFUSE_BASE_URL": "http://127.0.0.1:3000"]) { $1 }))
    }

    @MainActor func testInputAndOutputAreAllowlisted() throws {
        let input = LangfuseTracing.safeInput("type", ["text": "private password", "key": "private chord", "x": 123,
            "secretKey": "sk-test", "output": "/private/path", "button": "private button", "unknown": "private"])
        let data = try JSONSerialization.data(withJSONObject: input)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private")); XCTAssertFalse(json.contains("sk-test"))
        XCTAssertEqual(input["text"] as? String, "[REDACTED]")
        XCTAssertEqual(input["text_bytes"] as? Int, 16)
        XCTAssertEqual(input["x"] as? Double, 123)
        let summary = LangfuseTracing.replySummary(Reply(id: UUID(), values: ["image": "/private/image.png", "width": "1280",
            "screenRecording": "true", "accessibility": "private", "arbitrary": "secret"]))
        XCTAssertEqual(summary["width"] as? Int, 1280)
        XCTAssertEqual(summary["screenRecording"] as? Bool, true)
        XCTAssertNil(summary["image"]); XCTAssertNil(summary["arbitrary"]); XCTAssertNil(summary["accessibility"])
        XCTAssertEqual(LangfuseTracing.toolName("untrusted-secret-name"), "unknown")
    }

    @MainActor func testNestedSpansPropagateContextAndDoNotLeakContent() async throws {
        let exporter = RecordingExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test-release", exporter: exporter)
        let result = try await tracing.observeTool("click", arguments: ["x": 2, "y": 3], channel: "mcp", sessionID: "test-session",
                                                   output: LangfuseTracing.replySummary) {
            var reply = Reply(id: UUID())
            for count in 1...3 {
                let request = Request(action: "click", arguments: ["x": "2", "y": "3", "count": String(count)])
                reply = try await tracing.observeGuest(request) {
                    try await Task.sleep(nanoseconds: 1_000_000)
                    return Reply(id: request.id, values: ["arbitrary": "secret"])
                }
            }
            return reply
        }
        XCTAssertTrue(result.ok)
        await tracing.shutdown()
        let spans = exporter.spans
        XCTAssertEqual(spans.count, 4)
        let root = try XCTUnwrap(spans.first { $0.name == "execute-click-tool" })
        XCTAssertEqual(root.attributes["langfuse.observation.type"], .string("tool"))
        for child in spans where child.name == "send-guest-click" {
            XCTAssertEqual(child.parentSpanId, root.spanId)
            XCTAssertEqual(child.traceId, root.traceId)
            XCTAssertEqual(child.attributes["langfuse.observation.type"], .string("span"))
            XCTAssertGreaterThanOrEqual(child.endTime, child.startTime)
        }
        for span in spans {
            XCTAssertEqual(span.attributes["langfuse.session.id"], .string("test-session"))
            XCTAssertEqual(span.attributes["langfuse.release"], .string("test-release"))
            XCTAssertEqual(span.attributes["langfuse.environment"], .string("development"))
            XCTAssertEqual(span.attributes["langfuse.trace.metadata.channel"], .string("mcp"))
            XCTAssertFalse(String(describing: span.attributes).contains("secret"))
        }
    }

    @MainActor func testErrorsAreRecordedRedactedAndRethrownUnchanged() async throws {
        let exporter = RecordingExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        do {
            let _: Reply = try await tracing.observeTool("type", arguments: ["text": "private"], channel: "cli", output: LangfuseTracing.replySummary) {
                try await tracing.observeGuest(Request(action: "type")) { throw Failure("private guest error") }
            }
            XCTFail("Expected original error")
        } catch { XCTAssertEqual(error.localizedDescription, "private guest error") }
        await tracing.shutdown()
        XCTAssertEqual(exporter.spans.count, 2)
        for span in exporter.spans {
            XCTAssertEqual(span.attributes["langfuse.observation.level"], .string("ERROR"))
            XCTAssertEqual(span.attributes["langfuse.observation.status_message"], .string("tool-failed"))
            XCTAssertFalse(String(describing: span.attributes).contains("private"))
        }
    }

    @MainActor func testDisabledTracingDoesNotInvokeOutputOrCreateSpans() async throws {
        let exporter = RecordingExporter()
        let tracing = LangfuseTracing(configuration: nil, version: "test", exporter: exporter)
        let result = await tracing.observeTool("status", arguments: [:], channel: "mcp", output: { (_: Int) in
            XCTFail("Disabled tracing must not serialize output"); return [:]
        }) { 42 }
        XCTAssertEqual(result, 42)
        await tracing.shutdown()
        XCTAssertTrue(exporter.spans.isEmpty)
    }

    @MainActor func testZeroSamplingDropsWholeTrace() async throws {
        let exporter = RecordingExporter()
        let config = try LangfuseConfiguration.load(env.merging(["LANGFUSE_SAMPLE_RATE": "0"]) { $1 })
        let tracing = LangfuseTracing(configuration: config, version: "test", exporter: exporter)
        _ = await tracing.observeTool("status", arguments: [:], channel: "mcp", output: LangfuseTracing.replySummary) {
            await tracing.observeGuest(Request(action: "status")) { Reply(id: UUID()) }
        }
        await tracing.shutdown()
        XCTAssertTrue(exporter.spans.isEmpty)
    }

    @MainActor func testMCPErrorPathCreatesSeparateTracesInOneSession() async throws {
        let exporter = RecordingExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        let server = AgentServer(store: Store(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                                 name: "default", tracing: tracing)
        for _ in 1...2 {
            do { _ = try await server.call("status", [:]); XCTFail("Expected missing VM") } catch {}
        }
        await tracing.shutdown()
        let roots = exporter.spans.filter { $0.name == "execute-status-tool" }
        XCTAssertEqual(roots.count, 2)
        XCTAssertNotEqual(roots.first?.traceId, roots.last?.traceId)
        XCTAssertEqual(roots.first?.attributes["langfuse.session.id"], roots.last?.attributes["langfuse.session.id"])
        XCTAssertEqual(exporter.spans.count, 4)
    }

    @MainActor func testOfficialExporterSendsAuthenticatedOTLPWithV4Header() async throws {
        let config = try XCTUnwrap(LangfuseConfiguration.load(env))
        let client = RecordingHTTPClient()
        let exporter = LangfuseTracing.makeExporter(config, httpClient: client)
        let tracing = LangfuseTracing(configuration: config, version: "test", exporter: exporter)
        _ = await tracing.observeTool("type", arguments: ["text": "secret text"], channel: "cli", output: LangfuseTracing.contentSummary) {
            [["type": "image", "data": "secret pixels"], ["type": "text", "text": "secret response"]]
        }
        await tracing.shutdown()
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url, config.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), config.authorization)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-langfuse-ingestion-version"), "4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: body)
        let span = try XCTUnwrap(decoded.resourceSpans.first?.scopeSpans.first?.spans.first)
        XCTAssertEqual(span.name, "execute-type-tool")
        XCTAssertGreaterThan(span.startTimeUnixNano, 0)
        XCTAssertGreaterThanOrEqual(span.endTimeUnixNano, span.startTimeUnixNano)
        XCTAssertFalse(String(describing: decoded).contains("secret text"))
        XCTAssertFalse(String(describing: decoded).contains("secret pixels"))
        XCTAssertFalse(String(describing: decoded).contains("secret response"))
    }

    @MainActor func testConcurrentCallsKeepTheirOwnParentsAndSessions() async throws {
        let exporter = RecordingExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        @Sendable @MainActor func run(_ session: String) async throws {
            _ = try await tracing.observeTool("status", arguments: [:], channel: "mcp", sessionID: session, output: LangfuseTracing.replySummary) {
                try await Task.sleep(nanoseconds: 2_000_000)
                return await tracing.observeGuest(Request(action: "status")) { Reply(id: UUID()) }
            }
        }
        async let first: Void = run("first")
        async let second: Void = run("second")
        _ = try await (first, second)
        await tracing.shutdown()
        XCTAssertEqual(exporter.spans.count, 4)
        for child in exporter.spans where child.name == "send-guest-status" {
            let parent = try XCTUnwrap(exporter.spans.first { $0.spanId == child.parentSpanId })
            XCTAssertEqual(child.traceId, parent.traceId)
            XCTAssertEqual(child.attributes["langfuse.session.id"], parent.attributes["langfuse.session.id"])
        }
    }

    @MainActor func testOpaqueContextOverrideAndScreenshotMetadata() async throws {
        let exporter = RecordingExporter()
        let config = try LangfuseConfiguration.load(env.merging(["LANGFUSE_SESSION_ID": "conversation-id", "LANGFUSE_USER_ID": "opaque-user"]) { $1 })
        let tracing = LangfuseTracing(configuration: config, version: "test", exporter: exporter)
        _ = await tracing.observeTool("screenshot", arguments: [:], channel: "mcp", sessionID: "process-id", output: LangfuseTracing.contentSummary) {
            tracing.recordScreenshot(width: 1280, height: 800, bytes: 1024)
            return [["type": "image", "data": "private screen"], ["type": "text", "text": "private text"]]
        }
        await tracing.shutdown()
        let root = try XCTUnwrap(exporter.spans.first)
        XCTAssertEqual(root.attributes["langfuse.session.id"], .string("conversation-id"))
        XCTAssertEqual(root.attributes["langfuse.user.id"], .string("opaque-user"))
        XCTAssertEqual(root.attributes["langfuse.observation.metadata.screenshot_width"], .int(1280))
        XCTAssertEqual(root.attributes["langfuse.observation.metadata.screenshot_height"], .int(800))
        XCTAssertFalse(String(describing: root.attributes).contains("private"))
    }

    @MainActor func testCancellationIsRecordedAndDoesNotChangeErrorType() async throws {
        let exporter = RecordingExporter()
        let tracing = LangfuseTracing(configuration: try LangfuseConfiguration.load(env), version: "test", exporter: exporter)
        do {
            let _: Int = try await tracing.observeTool("status", arguments: [:], channel: "mcp", output: { _ in [:] }) {
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        await tracing.shutdown()
        XCTAssertEqual(exporter.spans.first?.attributes["langfuse.observation.status_message"], .string("cancelled"))
    }
}
