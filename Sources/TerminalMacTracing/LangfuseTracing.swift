import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import OpenTelemetryProtocolExporterCommon
import TerminalMacCore
import CryptoKit

struct LangfuseConfiguration {
    let endpoint: URL
    let authorization: String
    let environment: String
    let sessionID: String?
    let userID: String?
    let sampleRate: Double
    let content: TracingContent
    let projectScope: String
    let mediaEnabled: Bool
    let mediaUploadHosts: Set<String>

    static func load(_ env: [String: String]) throws -> Self? {
        if env["LANGFUSE_TRACING_ENABLED"] == "false" { return nil }
        let publicKey = env["LANGFUSE_PUBLIC_KEY"] ?? ""
        let secretKey = env["LANGFUSE_SECRET_KEY"] ?? ""
        if publicKey.isEmpty && secretKey.isEmpty && env["LANGFUSE_TRACING_ENABLED"] != "true" { return nil }
        guard !publicKey.isEmpty, !secretKey.isEmpty,
              let base = env["LANGFUSE_BASE_URL"] ?? env["LANGFUSE_HOST"],
              let parts = URLComponents(string: base), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" &&
                (["localhost", "127.0.0.1", "[::1]"].contains(host) || env["LANGFUSE_ALLOW_INSECURE_HTTP"] == "true")),
              let url = parts.url else {
            throw Failure("Langfuse tracing disabled: set both project API keys and a valid HTTPS LANGFUSE_BASE_URL. Non-loopback HTTP requires LANGFUSE_ALLOW_INSECURE_HTTP=true.")
        }
        let rate = Double(env["LANGFUSE_SAMPLE_RATE"] ?? "1") ?? -1
        guard rate.isFinite, (0...1).contains(rate) else {
            throw Failure("Langfuse tracing disabled: LANGFUSE_SAMPLE_RATE must be between 0 and 1.")
        }
        let environment = env["LANGFUSE_TRACING_ENVIRONMENT"] ?? "development"
        let contentMode = env["LANGFUSE_CONTENT_MODE"] ?? "summary"
        guard ["summary", "content"].contains(contentMode) else {
            throw Failure("LANGFUSE_CONTENT_MODE must be summary or content.")
        }
        guard environment.range(of: "^[a-z0-9][a-z0-9_-]{0,39}$", options: .regularExpression) != nil else {
            throw Failure("Langfuse tracing disabled: LANGFUSE_TRACING_ENVIRONMENT must be 1-40 lowercase letters, digits, underscores or hyphens.")
        }
        return Self(endpoint: url.appendingPathComponent("api/public/otel/v1/traces"),
                    authorization: "Basic " + Data("\(publicKey):\(secretKey)".utf8).base64EncodedString(),
                    environment: environment,
                    sessionID: env["LANGFUSE_SESSION_ID"].flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
                    userID: env["LANGFUSE_USER_ID"].flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
                    sampleRate: rate,
                    content: TracingContent(enabled: contentMode == "content", secrets: [publicKey, secretKey,
                        "Basic " + Data("\(publicKey):\(secretKey)".utf8).base64EncodedString()]),
                    projectScope: SHA256.hash(data: Data("\(url.appendingPathComponent("api/public/otel/v1/traces").absoluteString)|\(publicKey)|\(environment)".utf8))
                        .map { String(format: "%02x", $0) }.joined(),
                    mediaEnabled: env["LANGFUSE_MEDIA_ENABLED"] == "true",
                    mediaUploadHosts: Set((env["LANGFUSE_MEDIA_UPLOAD_HOSTS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }))
    }
}

private struct ObservationContext {
    let span: Span
    let attributes: [String: AttributeValue]
    let captureContent: Bool
    let captureGate: (() -> Bool)?
    var captureAllowed: Bool { captureContent && (captureGate?() ?? true) }
}

/// Host-only tracing. Content capture is opt-in; credentials never enter the store.
@MainActor
public final class LangfuseTracing {
    @TaskLocal private static var context: ObservationContext?
    private let configuration: LangfuseConfiguration?
    private let provider: TracerProviderSdk?
    private let tracer: Tracer?
    private let version: String
    private let store: TracingStore?
    private let destination: SpanExporter?
    private var deliveryTask: Task<Void, Never>?
    private var flushing = false
    private var sequence = 0
    private var stopped = false
    private let sourceID = UUID().uuidString

    public convenience init(version: String) {
        let configuration: LangfuseConfiguration?
        do {
            let env = try LangfuseEnvironment.load(process: ProcessInfo.processInfo.environment,
                directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            configuration = try LangfuseConfiguration.load(env)
            if let configuration, configuration.endpoint.scheme == "http",
               !["localhost", "127.0.0.1", "[::1]"].contains(configuration.endpoint.host ?? "") {
                tracingWarning("Langfuse HTTP is explicitly enabled. Project keys and telemetry are not encrypted in transit.")
            }
        }
        catch { tracingWarning(error.localizedDescription); configuration = nil }
        self.init(configuration: configuration, version: version,
                  storeDirectory: configuration.map { Store().root.appendingPathComponent("tracing/\($0.projectScope)") })
    }

    init(configuration: LangfuseConfiguration?, version: String, exporter: SpanExporter? = nil,
         storeDirectory: URL? = nil) {
        self.configuration = configuration
        self.version = version
        guard let configuration else { provider = nil; tracer = nil; store = nil; destination = nil; return }
        let store: TracingStore?
        do { store = try storeDirectory.map { try TracingStore(directory: $0) }; try store?.recover() }
        catch {
            tracingWarning("Cannot initialize private tracing storage; tracing is disabled.")
            provider = nil; tracer = nil; self.store = nil; destination = nil; return
        }
        self.store = store
        let destination = exporter ?? Self.makeExporter(configuration)
        self.destination = destination
        let processor = BatchSpanProcessor(spanExporter: store.map { StoreExporter($0) } ?? destination, scheduleDelay: 2,
                                           exportTimeout: 2, maxQueueSize: 256, maxExportBatchSize: 64)
        let provider = TracerProviderBuilder()
            .with(resource: Resource(attributes: ["service.name": .string("terminal-mac"), "service.version": .string(version)]))
            .with(sampler: Samplers.parentBased(root: Samplers.traceIdRatio(ratio: configuration.sampleRate)))
            .add(spanProcessor: processor).build()
        self.provider = provider
        tracer = provider.get(instrumentationName: "terminal-mac.tools", instrumentationVersion: version)
        if store != nil {
            deliveryTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    guard let self else { return }
                    await self.flushOutbox()
                }
            }
        }
    }

    static func makeExporter(_ configuration: LangfuseConfiguration, httpClient: HTTPClient? = nil) -> SpanExporter {
        // Generic OTEL headers must not override this project's credentials. Disable the
        // exporter's unbounded retry queue; the batch processor has a bounded queue instead.
        let client = httpClient ?? DiagnosticHTTPClient()
        return ReportingExporter(OtlpHttpTraceExporter(endpoint: configuration.endpoint,
            config: OtlpConfiguration(timeout: 2, compression: .none, headers: [
                ("Authorization", configuration.authorization), ("x-langfuse-ingestion-version", "4")
            ], exportAsJson: false), httpClient: client, envVarHeaders: nil, requeueOnFailure: false), diagnostics: client as? DiagnosticHTTPClient)
    }

    public func observeTool<T>(_ tool: String, arguments: [String: Any], channel: String,
                               sessionID: String? = nil, contextHandle: String? = nil, reason: String? = nil,
                               actor: String = "unknown", requestID: String? = nil,
                               captureContent: Bool = true, inheritActiveParent: Bool = true, operationName: String? = nil,
                               captureGate: (() -> Bool)? = nil,
                               errorOutput: ((Error) -> [String: Any])? = nil,
                               correlation: (([String: Any]) -> Void)? = nil, output: (T) -> [String: Any],
                               operation: () async throws -> T) async rethrows -> T {
        guard let tracer, let configuration, !stopped else { return try await operation() }
        let tool = Self.toolName(tool)
        let invocation = UUID().uuidString
        sequence += 1
        let started = ProcessInfo.processInfo.systemUptime
        var parent: TracingNode?
        if let contextHandle {
            do {
                guard let store else { throw Failure("Tracing context store is unavailable.") }
                parent = try store.acquire(contextHandle, invocation: invocation)
            }
            catch { tracingWarning("Invalid or unavailable context; recording an independent action.") }
        }
        let heartbeat: Task<Void, Never>? = parent.map { node in
            Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    do { try self?.store?.renew(node.handle, invocation: invocation) }
                    catch { tracingWarning("Tracing call lease renewal failed; task closure may require recovery.") }
                }
            }
        }
        defer {
            heartbeat?.cancel()
            if let parent { try? store?.release(parent.handle, invocation: invocation) }
        }
        var attributes: [String: AttributeValue] = [
            "langfuse.trace.name": .string(operationName ?? "execute-\(tool)-tool"),
            "langfuse.trace.tags": AttributeValue(["computer-use", channel]),
            "langfuse.trace.metadata.feature": .string("computer-use"),
            "langfuse.trace.metadata.channel": .string(channel),
            "langfuse.release": .string(version),
            "langfuse.environment": .string(configuration.environment)
        ]
        let identifiers = TracingContent(enabled: true, secrets: configuration.content.secrets)
        if let session = configuration.sessionID ?? sessionID { attributes["langfuse.session.id"] = .string(identifiers.text(String(session.prefix(200)))) }
        if let user = configuration.userID { attributes["langfuse.user.id"] = .string(identifiers.text(user)) }
        if let parent {
            for (key, value) in parent.span.attributes where Self.sharedAttribute(key) { attributes[key] = value }
        }
        attributes["langfuse.observation.metadata.invocation_id"] = .string(invocation)
        attributes["langfuse.observation.metadata.source"] = .string(channel)
        attributes["langfuse.observation.metadata.actor"] = .string(["human", "ai"].contains(actor) ? actor : "unknown")
        attributes["langfuse.observation.metadata.actor_source"] = .string(actor == "human" && channel == "viewer" ? "viewer-input" : actor == "unknown" ? "unspecified" : "caller")
        attributes["langfuse.observation.metadata.source_id"] = .string(sourceID)
        attributes["langfuse.observation.metadata.sequence"] = .int(sequence)
        attributes["langfuse.observation.metadata.reason_source"] = .string(reason == nil ? "missing" : "caller")
        if let reason { attributes["langfuse.observation.metadata.reason"] = .string(String(configuration.content.text(reason).prefix(1024))) }
        if let requestID { attributes["langfuse.observation.metadata.call_id"] = .string(identifiers.text(String(requestID.prefix(200)))) }
        let builder = tracer.spanBuilder(spanName: operationName ?? "execute-\(tool)-tool").setSpanKind(spanKind: .server)
        if let parent { builder.setParent(parent.context) }
        else if inheritActiveParent, contextHandle == nil, let active = Self.context {
            builder.setParent(active.span)
            for (key, value) in active.attributes where Self.sharedAttribute(key) { attributes[key] = value }
        } else { builder.setNoParent() }
        for (key, value) in attributes { builder.setAttribute(key: key, value: value) }
        builder.setAttribute(key: "langfuse.observation.type", value: "tool")
        builder.setAttribute(key: "langfuse.observation.input", value: input(tool, arguments, captureContent: captureContent))
        let span = builder.startSpan()
        correlation?(["trace_id": span.context.traceId.hexString, "observation_id": span.context.spanId.hexString,
                      "invocation_id": invocation, "sampled": span.context.traceFlags.sampled])
        span.addEvent(name: "received")
        defer {
            if !(captureGate?() ?? true) {
                span.setAttribute(key: "langfuse.observation.input", value: input(tool, arguments, captureContent: false))
                span.setAttribute(key: "langfuse.observation.metadata.capture_state", value: "paused")
            }
            span.setAttribute(key: "langfuse.observation.metadata.duration_ms", value: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            span.end()
        }
        return try await Self.$context.withValue(ObservationContext(span: span, attributes: attributes, captureContent: captureContent, captureGate: captureGate)) {
            do {
                let result = try await operation()
                span.setAttribute(key: "langfuse.observation.output", value: policy(captureContent: captureContent && (captureGate?() ?? true)).json(output(result)))
                span.addEvent(name: "response-constructed")
                span.status = .ok
                return result
            } catch {
                record(error, on: span, captureContent: captureContent && (captureGate?() ?? true), returned: errorOutput?(error))
                throw error
            }
        }
    }

    public func observeGuest(_ request: Request, operation: () async throws -> Reply) async rethrows -> Reply {
        guard let tracer, let parent = Self.context else { return try await operation() }
        let builder = tracer.spanBuilder(spanName: "send-guest-\(Self.toolName(request.action))")
            .setParent(parent.span).setSpanKind(spanKind: .client)
        for (key, value) in parent.attributes { builder.setAttribute(key: key, value: value) }
        builder.setAttribute(key: "langfuse.observation.type", value: "span")
        builder.setAttribute(key: "langfuse.observation.metadata.request_id", value: request.id.uuidString)
        builder.setAttribute(key: "langfuse.observation.input", value: input(request.action, request.arguments, captureContent: parent.captureContent))
        let span = builder.startSpan()
        defer {
            if !parent.captureAllowed {
                span.setAttribute(key: "langfuse.observation.input", value: input(request.action, request.arguments, captureContent: false))
            }
            span.end()
        }
        span.addEvent(name: "dispatch")
        do {
            let reply = try await operation()
            span.setAttribute(key: "langfuse.observation.output", value: replyOutput(reply, captureContent: parent.captureAllowed))
            span.addEvent(name: "guest-completed")
            span.status = .ok
            return reply
        } catch { record(error, on: span, captureContent: parent.captureAllowed); throw error }
    }

    private func policy(captureContent: Bool) -> TracingContent {
        TracingContent(enabled: captureContent && configuration?.content.enabled == true,
                       secrets: configuration?.content.secrets ?? [])
    }

    public func recordInput(_ arguments: [String: Any]) {
        guard let active = Self.context else { return }
        active.span.setAttribute(key: "langfuse.observation.input", value: policy(captureContent: active.captureAllowed).json(arguments))
        active.span.addEvent(name: "validated")
    }

    public func recordOutput(_ output: [String: Any]) {
        guard let active = Self.context else { return }
        active.span.setAttribute(key: "langfuse.observation.metadata.returned_content", value: policy(captureContent: active.captureAllowed).json(output))
        active.span.addEvent(name: "output-written")
    }

    public func recordMetadata(_ metadata: [String: String]) {
        guard let active = Self.context else { return }
        let safe = TracingContent(enabled: true, secrets: configuration?.content.secrets ?? [])
        for (key, value) in metadata where ["queue_state", "merge_count", "first_sequence", "last_sequence", "enqueued_at", "queue_ms", "exit_code", "capture_state"].contains(key) {
            active.span.setAttribute(key: "langfuse.observation.metadata.\(key)", value: safe.text(value))
        }
    }

    public func recordWarning(_ category: String) {
        guard let span = Self.context?.span else { return }
        span.setAttribute(key: "langfuse.observation.level", value: "WARNING")
        span.setAttribute(key: "langfuse.observation.status_message", value: category)
    }

    public func validateContext(_ handle: String) throws {
        guard let store, isEnabled else { throw Failure("Tracing is disabled.") }
        _ = try store.acquire(handle)
    }

    public func checkpoint() async {
        guard let provider else { return }
        await Task.detached { provider.forceFlush() }.value
    }

    public func recordScreenshot(width: Int, height: Int, bytes: Int) {
        guard let span = Self.context?.span else { return }
        for (key, value) in ["screenshot_width": width, "screenshot_height": height, "screenshot_bytes": bytes] {
            span.setAttribute(key: "langfuse.observation.metadata.\(key)", value: value)
        }
    }

    public func recordScreenshotMedia(_ data: Data, mimeType: String) async {
        guard let configuration, configuration.mediaEnabled, let active = Self.context,
              active.captureAllowed, active.span.context.traceFlags.sampled else { return }
        do {
            let token = try await TracingMedia(configuration: configuration).upload(data, mimeType: mimeType,
                traceID: active.span.context.traceId.hexString, observationID: active.span.context.spanId.hexString)
            active.span.setAttribute(key: "langfuse.observation.metadata.screenshot", value: token)
            active.span.setAttribute(key: "langfuse.observation.metadata.media_status", value: "uploaded")
        } catch {
            active.span.setAttribute(key: "langfuse.observation.metadata.media_status", value: "unavailable")
            tracingWarning("Screenshot telemetry upload unavailable; screenshot tool response is unaffected.")
        }
    }

    public func shutdown() async {
        guard let provider, !stopped else { return }
        stopped = true
        deliveryTask?.cancel()
        await deliveryTask?.value
        // SDK flush is blocking; keep URLSession callbacks and the app's main actor free to run.
        await Task.detached { provider.shutdown() }.value
        await flushOutbox()
        if let destination, store != nil { await Task.detached { destination.shutdown(explicitTimeout: 2) }.value }
    }

    public var isEnabled: Bool { tracer != nil && !stopped }

    public func begin(goal: String, parent handle: String? = nil, reason: String? = nil,
                      sessionID: String? = nil) throws -> [String: Any] {
        guard let configuration, let store, isEnabled else { return ["enabled": false] }
        guard !goal.isEmpty, goal.utf8.count <= 4096, (reason?.utf8.count ?? 0) <= 1024 else {
            throw Failure("Task goal must be 1-4096 bytes; reason must be at most 1024 bytes.")
        }
        let parent = try handle.map { try store.acquire($0) }
        // A processor-free provider makes a serializable identity without exporting an unfinished span.
        let identityProvider = TracerProviderBuilder().with(sampler: Samplers.alwaysOn).build()
        let builder = identityProvider.get(instrumentationName: "terminal-mac.tasks").spanBuilder(spanName: parent == nil ? "run-desktop-task" : "execute-desktop-chain")
        if let parent { builder.setParent(parent.context) } else { builder.setNoParent() }
        let live = builder.startSpan()
        guard let readable = live as? ReadableSpan else { throw Failure("Cannot create tracing identity.") }
        var span = readable.toSpanData()
        live.end()
        let sampled = parent?.span.traceFlags.sampled ?? (Double.random(in: 0..<1) < configuration.sampleRate)
        span.settingTraceFlags(span.traceFlags.settingIsSampled(sampled))
        var attributes: [String: AttributeValue] = [
            "langfuse.trace.name": .string("run-desktop-task"),
            "langfuse.trace.tags": AttributeValue(["computer-use"]),
            "langfuse.release": .string(version), "langfuse.environment": .string(configuration.environment),
            "langfuse.observation.type": .string(parent == nil ? "span" : "chain"),
            "langfuse.observation.input": .string(configuration.content.json(["goal": goal])),
            "langfuse.observation.metadata.reason_source": .string(reason == nil ? "missing" : "caller")
        ]
        let identifiers = TracingContent(enabled: true, secrets: configuration.content.secrets)
        if let session = configuration.sessionID ?? sessionID { attributes["langfuse.session.id"] = .string(identifiers.text(String(session.prefix(200)))) }
        if let user = configuration.userID { attributes["langfuse.user.id"] = .string(identifiers.text(user)) }
        if let parent {
            for (key, value) in parent.span.attributes where Self.sharedAttribute(key) { attributes[key] = value }
        }
        if let reason { attributes["langfuse.observation.metadata.reason"] = .string(String(configuration.content.text(reason).prefix(1024))) }
        span.settingAttributes(attributes)
        span.settingTotalAttributeCount(attributes.count)
        span.settingResource(Resource(attributes: ["service.name": .string("terminal-mac"), "service.version": .string(version)]))
        let node = TracingNode(handle: UUID().uuidString, parent: handle, span: span,
                               expires: parent?.expires ?? Date().addingTimeInterval(TracingStore.lifetime))
        try store.insert(node)
        return node.response
    }

    public func end(context: String, chain: Bool, outcome: String, summary: String) throws -> [String: Any] {
        guard let configuration, let store, isEnabled else { return ["enabled": false] }
        guard summary.utf8.count <= 4096 else { throw Failure("Tracing summary must be at most 4096 bytes.") }
        return try store.finish(context, type: chain ? "chain" : "span", outcome: outcome,
                                output: configuration.content.json(["outcome": outcome, "summary": summary])).response
    }

    public func diagnostics() throws -> [String: Any] {
        guard let store else { return ["enabled": false] }
        return try store.diagnostics().merging(["enabled": isEnabled, "protocol_version": 1]) { _, value in value }
    }

    private func flushOutbox() async {
        guard let store, let destination, !flushing else { return }
        flushing = true
        defer { flushing = false }
        await Task.detached {
            do {
                try store.recover()
                let batch = try store.claim()
                guard !batch.isEmpty else { return }
                let result = destination.export(spans: batch.map(\.span), explicitTimeout: 2)
                try store.acknowledge(batch, success: result == .success,
                    permanentFailure: (destination as? ReportingExporter)?.permanentFailure == true)
            } catch { tracingWarning("Cannot process telemetry outbox; retained data will be retried.") }
        }.value
    }

    private static func sharedAttribute(_ key: String) -> Bool {
        key.hasPrefix("langfuse.trace.") || ["langfuse.session.id", "langfuse.user.id", "langfuse.release", "langfuse.environment"].contains(key)
    }

    private func input(_ tool: String, _ arguments: [String: Any], captureContent: Bool = true) -> String {
        if captureContent, let configuration, configuration.content.enabled {
            return configuration.content.json(["tool": Self.toolName(tool), "arguments": arguments])
        }
        return Self.json(Self.safeInput(tool, arguments))
    }

    public func toolOutput(_ content: [[String: Any]]) -> [String: Any] {
        configuration?.content.enabled == true ? ["ok": true, "content": content] : Self.contentSummary(content)
    }

    public func actionOutput(_ values: [String: String]) -> [String: Any] {
        configuration?.content.enabled == true ? ["ok": true, "values": values] : Self.replySummary(Reply(id: UUID(), values: values))
    }

    private func replyOutput(_ reply: Reply, captureContent: Bool) -> String {
        captureContent && configuration?.content.enabled == true ? configuration!.content.json(["ok": reply.ok, "values": reply.values]) : Self.json(Self.replySummary(reply))
    }

    static func toolName(_ tool: String) -> String {
        if tool == "snapshot" { return "screenshot" }
        return ["screenshot", "status", "click", "move", "drag", "scroll", "type", "key"].contains(tool) ? tool : "unknown"
    }

    static func safeInput(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
        var result: [String: Any] = ["tool": toolName(tool)]
        for key in ["x", "y", "x2", "y2", "toX", "toY", "dx", "dy", "clicks", "count"] {
            let value = (arguments[key] as? NSNumber)?.doubleValue ?? (arguments[key] as? String).flatMap(Double.init)
            if let value, value.isFinite { result[key] = value }
        }
        if let text = arguments["text"] as? String { result["text"] = "[REDACTED]"; result["text_bytes"] = text.utf8.count }
        if arguments["key"] != nil { result["key"] = "[REDACTED]" }
        if let button = arguments["button"] as? String, ["left", "right"].contains(button) { result["button"] = button }
        if let screenshot = arguments["screenshot"] as? Bool { result["screenshot"] = screenshot }
        if let double = arguments["double"] as? String, ["true", "false"].contains(double) { result["double"] = double == "true" }
        return result
    }

    public static func replySummary(_ reply: Reply) -> [String: Any] {
        var result: [String: Any] = ["ok": reply.ok, "has_image": reply.values["image"] != nil]
        for key in ["screenRecording", "accessibility", "session"] {
            if let value = reply.values[key], ["true", "false"].contains(value) { result[key] = value == "true" }
        }
        for key in ["width", "height"] {
            if let value = reply.values[key].flatMap(Int.init) { result[key] = value }
        }
        return result
    }

    public static func contentSummary(_ content: [[String: Any]]) -> [String: Any] {
        ["ok": true, "text_blocks": content.filter { $0["type"] as? String == "text" }.count,
         "image_blocks": content.filter { $0["type"] as? String == "image" }.count]
    }

    private func record(_ error: Error, on span: Span, captureContent: Bool = true, returned: [String: Any]? = nil) {
        let category: String
        if let timeout = error as? MailboxTimeout { category = timeout.pickedUp ? "guest-timeout" : "guest-unavailable" }
        else if error is CancellationError { category = "cancelled" }
        else if error is Failure { category = "tool-failed" }
        else { category = "internal-error" }
        span.status = .error(description: category)
        span.setAttribute(key: "langfuse.observation.level", value: "ERROR")
        span.setAttribute(key: "langfuse.observation.status_message", value: category)
        var output = returned ?? [:]
        output["ok"] = false; output["error"] = category
        if captureContent && configuration?.content.enabled == true && output["message"] == nil { output["message"] = error.localizedDescription }
        span.setAttribute(key: "langfuse.observation.output", value: policy(captureContent: captureContent).json(output))
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

func tracingWarning(_ message: String) {
    FileHandle.standardError.write(Data(("terminal-mac: " + message + "\n").utf8))
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct TracingHTTPFailure: Error {
    let status: Int
    var permanent: Bool { (300..<500).contains(status) && status != 408 && status != 429 }
}

final class DiagnosticHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var lastPermanentFailure = false
    var permanentFailure: Bool { lock.lock(); defer { lock.unlock() }; return lastPermanentFailure }
    init(session: URLSession? = nil) {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        self.session = session ?? URLSession(configuration: settings, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        session.dataTask(with: request) { _, response, error in
            let failure = (response as? HTTPURLResponse).map { TracingHTTPFailure(status: $0.statusCode) }
            self.lock.lock(); self.lastPermanentFailure = failure?.permanent ?? false; self.lock.unlock()
            if let error { tracingWarning("Langfuse transport failed; pending records are retained."); completion(.failure(error)) }
            else if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) { completion(.success(response)) }
            else {
                tracingWarning("Langfuse HTTP \(failure?.status ?? 0); \(failure?.permanent == true ? "check endpoint/authentication before retry" : "will retry with backoff").")
                completion(.failure(failure ?? TracingHTTPFailure(status: 0)))
            }
        }.resume()
    }
    func send(request: URLRequest) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in send(request: request) { continuation.resume(with: $0) } }
    }
}

private final class ReportingExporter: SpanExporter {
    let exporter: SpanExporter
    let diagnostics: DiagnosticHTTPClient?
    var permanentFailure: Bool { diagnostics?.permanentFailure ?? false }
    init(_ exporter: SpanExporter, diagnostics: DiagnosticHTTPClient? = nil) { self.exporter = exporter; self.diagnostics = diagnostics }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        let result = exporter.export(spans: spans, explicitTimeout: explicitTimeout)
        if result != .success { tracingWarning("Langfuse export failed; the persistent outbox retries when available. Tool execution is unaffected.") }
        return result
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { exporter.flush(explicitTimeout: explicitTimeout) }
    func shutdown(explicitTimeout: TimeInterval?) { exporter.shutdown(explicitTimeout: explicitTimeout) }
}
