import Foundation
import CoreFoundation
import TerminalMacCore

public protocol RelaySocket: Sendable {
    func sendText(_ data: Data) async throws
    func sendBinary(_ data: Data) async throws
    func receiveText() async throws -> Data
    func close()
    var closeCode: Int { get }
}

private final class NoRelayRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
    private let session: URLSession, task: URLSessionWebSocketTask
    public init(authentication: RelayAuthentication, deviceToken: String?) throws {
        var request = URLRequest(url: authentication.origin.deviceURL)
        request.setValue(try authentication.cookieHeader(for: request.url!), forHTTPHeaderField: "Cookie")
        request.setValue("terminal-mac/remote-observer-v1", forHTTPHeaderField: "User-Agent")
        if let deviceToken {
            guard deviceToken.utf8.count == 43, RelayOrigin.validScanToken(deviceToken) else { throw RelayFailure("protocol_error") }
            request.setValue("Bearer " + deviceToken, forHTTPHeaderField: "Authorization")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: NoRelayRedirect(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = ObserverLimits.maxControlBytes
        task.resume()
    }
    public func sendText(_ data: Data) async throws {
        guard data.count <= ObserverLimits.maxControlBytes, let text = String(data: data, encoding: .utf8) else {
            throw RelayFailure("message_too_large")
        }
        try await task.send(.string(text))
    }
    public func sendBinary(_ data: Data) async throws {
        guard data.count <= ObserverLimits.maxMessageBytes else { throw RelayFailure("message_too_large") }
        try await task.send(.data(data))
    }
    public func receiveText() async throws -> Data {
        switch try await task.receive() {
        case .string(let text):
            guard text.utf8.count <= ObserverLimits.maxControlBytes else { throw RelayFailure("message_too_large") }
            return Data(text.utf8)
        case .data: throw RelayFailure("protocol_error")
        @unknown default: throw RelayFailure("protocol_error")
        }
    }
    public var closeCode: Int { task.closeCode.rawValue }
    public func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { close() }
}

public enum RelayEvent: Sendable {
    case binding(pairingId: UUID, url: URL, expiresAt: Double)
    case online(deviceId: UUID)
}

public actor ObserverRelay {
    private var state: RelayDeviceState?, connection: UUID?
    private var deviceId: UUID?
    private var pairing: (id: UUID, path: String, expires: Double)?
    private var lastPing = ProcessInfo.processInfo.systemUptime
    private var failure: RelayFailure?
    private var controls = 0, window = ProcessInfo.processInfo.systemUptime
    private let hub: ObserverHub?
    private var watch: UUID?, watchDeadline: Double?, subscribed = false
    private var lifecycleControls: [Double] = []
    private var handshakeTimeout = 5.0, heartbeatTimeout = 45.0
    public init(source: (any ObserverSource)? = nil) {
        hub = source.map { ObserverHub(source: $0, configuration: .low, lowBandwidth: true) }
    }
    init(hub: ObserverHub, handshakeTimeout: Double = 5, heartbeatTimeout: Double = 45) {
        self.hub = hub; self.handshakeTimeout = handshakeTimeout; self.heartbeatTimeout = heartbeatTimeout
    }

    public func run(socket: any RelaySocket, origin: RelayOrigin, observerId: UUID, name: String, deviceToken: String,
                    recovering: Bool, interactive: Bool, lifetime: RelayConnectionLifetime = RelayConnectionLifetime(),
                    onEvent: @Sendable (RelayEvent) async throws -> Void) async throws {
        guard connection == nil, (1...60).contains(name.count), !name.contains(where: { $0.isNewline }),
              deviceToken.utf8.count == 43, RelayOrigin.validScanToken(deviceToken) else {
            socket.close(); throw RelayFailure("protocol_error")
        }
        let writer = RelayControlWriter(socket: socket, lifetime: lifetime)
        let began = ProcessInfo.processInfo.systemUptime
        var readyDeadline = began + handshakeTimeout
        lastPing = began
        let timer = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                if expired(began: began, readyDeadline: readyDeadline) { lifetime.invalidate(); socket.close(); return }
                if let watch, let watchDeadline, !subscribed, ProcessInfo.processInfo.systemUptime >= watchDeadline {
                    writer.endWatch(watch, code: "session_timeout")
                    self.watchDeadline = nil
                    await hub?.remove(watch)
                }
            }
        }
        do {
            try await withTaskCancellationHandler(operation: {
                while true {
                    try Task.checkCancellation()
                    let data = try await socket.receiveText()
                    try Task.checkCancellation()
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - window >= 1 { window = now; controls = 0 }
                    controls += 1
                    guard controls <= 64 else { throw RelayFailure("protocol_error") }
                    switch try RelayDeviceMessage.parse(data) {
                    case .hello(let id, let next, let device):
                        if let connection {
                            guard connection == id else { throw RelayFailure("protocol_error") }
                            if state == next && deviceId == device { continue }
                            guard state == .binding, next == .online else { throw RelayFailure("protocol_error") }
                        } else {
                            guard recovering ? next != .unbound : next == .unbound else { throw RelayFailure("protocol_error") }
                            connection = id
                        }
                        state = next; deviceId = device
                        if next == .unbound {
                            guard interactive else { throw RelayFailure("binding_required") }
                            try writer.enqueue(["type": "device.bind.begin", "observerId": observerId.uuidString,
                                "name": name, "deviceToken": deviceToken])
                            readyDeadline = now + handshakeTimeout
                        } else if next == .binding {
                            readyDeadline = now + handshakeTimeout
                        } else if next == .online, let device {
                            pairing = nil
                            lifetime.markOnline()
                            try await onEvent(.online(deviceId: device))
                        }
                    case .binding(let id, let path, let expires):
                        guard state == .unbound || state == .binding else { throw RelayFailure("protocol_error") }
                        guard interactive else { throw RelayFailure("binding_required") }
                        let url = try origin.bindingURL(path)
                        guard expires > Date().timeIntervalSince1970 else { throw RelayFailure("pairing_expired") }
                        if let pairing {
                            guard pairing.id == id, pairing.path == path, pairing.expires == expires else { throw RelayFailure("protocol_error") }
                        }
                        pairing = (id, path, expires); state = .binding
                        try await onEvent(.binding(pairingId: id, url: url, expiresAt: expires))
                    case .ping(let nonce):
                        guard state != nil else { throw RelayFailure("protocol_error") }
                        lastPing = now
                        try writer.enqueue(["type": "relay.pong", "nonce": nonce])
                    case .error(let error): throw error
                    case .watch(let id):
                        guard state == .online, let hub else { throw RelayFailure("protocol_error") }
                        if watch == id { continue }
                        if let watch { writer.endWatch(watch); await hub.remove(watch) }
                        watch = id; subscribed = false; watchDeadline = now + handshakeTimeout
                        try writer.beginWatch(id)
                        try await hub.add(id, transport: writer.transport(id))
                    case .close(let id, _):
                        guard state == .online else { throw RelayFailure("protocol_error") }
                        if watch == id { writer.endWatch(id); await hub?.remove(id); watchDeadline = nil }
                    case .observer(let id, let data):
                        guard state == .online else { throw RelayFailure("protocol_error") }
                        guard watch == id, writer.isCurrent(id) else { continue }
                        guard writer.isCurrent(id, ready: true) else { throw RelayFailure("protocol_error") }
                        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                        let kind = message["type"] as! String
                        if ["subscribe", "resync", "mode"].contains(kind) {
                            lifecycleControls.removeAll { $0 <= now - 1 }
                            guard lifecycleControls.count < 4 else { throw RelayFailure("protocol_error") }
                            lifecycleControls.append(now)
                        }
                        if kind == "subscribe" { subscribed = true; watchDeadline = nil }
                        else if !subscribed { throw RelayFailure("protocol_error") }
                        await hub?.control(id, data: data)
                    }
                }
            }, onCancel: { lifetime.invalidate(); socket.close() })
        } catch {
            lifetime.invalidate()
            if let watch { writer.endWatch(watch) }
            timer.cancel(); await timer.value
            let writerFailure = writer.failure
            let reason = Task.isCancelled ? CancellationError() : (failure ?? writerFailure ?? Self.closed(socket.closeCode) ?? error)
            await writer.stop()
            await hub?.stop()
            throw reason
        }
    }
    private func expired(began: Double, readyDeadline: Double) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if (state == nil || state == .unbound || (state == .binding && pairing == nil)), now > readyDeadline {
            failure = RelayFailure("session_timeout", retryable: true)
        }
        else if let pairing, Date().timeIntervalSince1970 >= pairing.expires { failure = RelayFailure("pairing_expired") }
        else if now - lastPing > heartbeatTimeout { failure = RelayFailure("heartbeat_timeout", retryable: true) }
        return failure != nil
    }
    private static func closed(_ code: Int) -> RelayFailure? {
        let codes: [Int: String] = [4001: "binding_invalid", 4003: "auth_required", 4004: "authorization_expired", 4005: "pairing_expired",
            4006: "binding_in_progress", 4008: "session_timeout", 4009: "viewer_busy", 4010: "device_busy", 4011: "device_offline",
            4012: "protocol_unsupported", 1008: "protocol_error", 1009: "message_too_large", 1013: "capacity_exceeded"]
        guard let name = codes[code] else { return nil }
        return RelayFailure(name, retryable: [4008, 4010, 1013].contains(code))
    }
}

public enum RelaySessionState: String, Sendable { case bound, binding }
public struct RelaySessionRecord: Sendable {
    public let state: RelaySessionState
    public let id: UUID
    public init(state: RelaySessionState, id: UUID) { self.state = state; self.id = id }
}
public enum RelaySessionDiagnosis {
    public static func check(authentication: RelayAuthentication, deviceToken: String) async throws -> RelaySessionState {
        try await inspect(authentication: authentication, deviceToken: deviceToken).state
    }
    public static func inspect(authentication: RelayAuthentication, deviceToken: String) async throws -> RelaySessionRecord {
        let (data, status, mime) = try await request(authentication: authentication, deviceToken: deviceToken,
            path: "/api/observer/device-session")
        return try decodeRecord(data, status: status, mime: mime)
    }
    static func request(authentication: RelayAuthentication, deviceToken: String, path: String,
                        body: Data? = nil) async throws -> (Data, Int, String) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRelayRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: authentication.origin.url(path: path))
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try authentication.cookieHeader(for: request.url!), forHTTPHeaderField: "Cookie")
        request.setValue("Bearer " + deviceToken, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw RelayFailure("server_protocol") }
            var data = Data()
            for try await byte in stream {
                guard data.count < ObserverLimits.maxControlBytes else { throw RelayFailure("server_protocol") }
                data.append(byte)
            }
            return (data, response.statusCode, response.value(forHTTPHeaderField: "Content-Type") ?? "")
        } catch let failure as RelayFailure { throw failure }
        catch {
            try Task.checkCancellation()
            throw RelayFailure("network_error", retryable: true)
        }
    }
    static func decode(_ data: Data, status: Int, mime: String) throws -> RelaySessionState {
        try decodeRecord(data, status: status, mime: mime).state
    }
    static func decodeRecord(_ data: Data, status: Int, mime: String) throws -> RelaySessionRecord {
        if status >= 500 || status == 429 { throw RelayFailure("server_unavailable", retryable: true) }
        if (300..<400).contains(status) { throw RelayFailure("auth_required") }
        let json = mime.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
        if !json && (status == 401 || mime.lowercased().hasPrefix("text/html")) { throw RelayFailure("auth_required") }
        guard data.count <= ObserverLimits.maxControlBytes, json, !data.contains(0), String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RelayFailure("server_protocol") }
        if status != 200 {
            guard Set(object.keys) == ["error"], let error = object["error"] as? [String: Any], Set(error.keys) == ["code", "retryable"],
                  let code = error["code"] as? String, let flag = error["retryable"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID(), (code != "binding_invalid" || status == 410) else {
                throw RelayFailure("server_protocol")
            }
            throw try RelayFailure.server(code, retryable: flag.boolValue)
        }
        guard let raw = object["state"] as? String, let state = RelaySessionState(rawValue: raw),
              let version = object["relayVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else {
            throw RelayFailure("server_protocol")
        }
        let field = state == .bound ? "deviceId" : "pairingId"
        guard Set(object.keys) == ["state", field, "relayVersion"], let raw = object[field] as? String, UUID(uuidString: raw) != nil else {
            throw RelayFailure("server_protocol")
        }
        return RelaySessionRecord(state: state, id: UUID(uuidString: raw)!)
    }
}

public enum RelayPairingCancellation {
    public enum Result: Equatable, Sendable { case cancelled, confirmed(UUID) }
    public static func cancel(authentication: RelayAuthentication, deviceToken: String,
                              observerId: UUID, pairingId: UUID) async throws -> Result {
        let body = try JSONEncoder().encode(["observerId": observerId.uuidString, "pairingId": pairingId.uuidString])
        let (data, status, mime) = try await RelaySessionDiagnosis.request(authentication: authentication,
            deviceToken: deviceToken, path: "/api/observer/pairings/cancel", body: body)
        return try decode(data, status: status, mime: mime, pairingId: pairingId)
    }
    static func decode(_ data: Data, status: Int, mime: String, pairingId: UUID) throws -> Result {
        if status != 200 {
            if status == 404 || status == 405 { throw RelayFailure("cancellation_unsupported") }
            _ = try RelaySessionDiagnosis.decode(data, status: status, mime: mime)
            throw RelayFailure("server_protocol")
        }
        guard data.count <= ObserverLimits.maxControlBytes, !data.contains(0), String(data: data, encoding: .utf8) != nil,
              mime.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["pairingId"] as? String, UUID(uuidString: raw) == pairingId,
              let state = object["state"] as? String else { throw RelayFailure("server_protocol") }
        if state == "cancelled", Set(object.keys) == ["state", "pairingId"] { return .cancelled }
        if state == "confirmed", Set(object.keys) == ["state", "pairingId", "deviceId"],
           let raw = object["deviceId"] as? String, let device = UUID(uuidString: raw) { return .confirmed(device) }
        throw RelayFailure("server_protocol")
    }
}
