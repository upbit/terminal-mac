import Foundation
import CoreFoundation
import TerminalMacCore

public struct RelayOrigin: Equatable, Codable, Sendable {
    public static let defaultServer = "https://remote-mac-nqnifo3z.devnet-app.with.woa.com"
    public let value: String
    public init(_ input: String) throws {
        guard input.utf8.count <= 2048, !input.isEmpty,
              !input.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
              var parts = URLComponents(string: input), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, !host.hasSuffix("."),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path), parts.percentEncodedHost?.contains("%") != true,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw RelayFailure("invalid_server")
        }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let value = parts.string, parts.url != nil else { throw RelayFailure("invalid_server") }
        self.value = value
    }
    public func url(path: String) -> URL {
        precondition(path.hasPrefix("/") && !path.hasPrefix("//"))
        return URL(string: value + path)!
    }
    public var deviceURL: URL {
        var parts = URLComponents(url: url(path: "/ws/observer/device"), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"; return parts.url!
    }
    public func bindingURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/pair#token="), Self.validScanToken(String(path.dropFirst(12))) else {
            throw RelayFailure("protocol_error")
        }
        return url(path: path)
    }
    static func validScanToken(_ token: String) -> Bool {
        guard token.utf8.count == 43, token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return false }
        let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              bytes.count >= 32 else { return false }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == token
    }
}

public struct RelayFailure: LocalizedError, Sendable {
    public let code: String
    public let retryable: Bool
    public init(_ code: String, retryable: Bool = false) { self.code = code; self.retryable = retryable }
    public var errorDescription: String? {
        switch code {
        case "invalid_server": return "Use an HTTPS origin without credentials, path, query or fragment."
        case "login_required", "auth_required", "gateway_identity_required": return "SSO login is required. Run connect in an interactive terminal."
        case "binding_required": return "First device binding requires an interactive terminal."
        case "binding_invalid": return "The server has invalidated this device binding."
        case "identity_mismatch": return "SSO identity does not match the device binding."
        case "keychain_failed": return "Device Keychain access failed; no new binding was submitted."
        case "helper_dependencies": return "Authentication requires Chrome, Python 3.11+ and the pinned packages in Auth/requirements.txt. See docs/REMOTE_OBSERVER_SETUP.md."
        case "helper_missing": return "Authentication helper is missing. Rebuild or reinstall terminal-mac."
        case "helper_protocol": return "Authentication helper returned an invalid or oversized result."
        case "auth_timeout": return "SSO login timed out."
        case "server_unavailable": return "The observer service is unavailable; cached credentials were preserved."
        case "server_protocol": return "The server does not provide the remote observer v1 identity/session API."
        case "network_error": return "Network or TLS request failed; cached credentials were preserved."
        case "pairing_expired": return "Binding expired. Run connect again to start a new request."
        case "binding_in_progress": return "Another binding request is pending; it was not replaced."
        case "cancellation_unsupported": return "The server has not implemented pending cancellation; the saved candidate was preserved."
        case "worker_stopped": return "The background observer stopped before connection handoff completed."
        case "disconnect_timeout": return "The observer did not stop within the cleanup timeout."
        default: return "Remote observer stopped (\(code))."
        }
    }
    static func server(_ code: String, retryable: Bool) throws -> RelayFailure {
        let allowed: Set<String> = ["binding_invalid", "auth_required", "gateway_identity_required", "identity_mismatch",
            "authorization_expired", "pairing_expired", "binding_in_progress", "session_timeout", "viewer_busy",
            "device_busy", "device_offline", "protocol_unsupported", "protocol_error", "message_too_large",
            "capacity_exceeded", "slow_consumer", "origin_rejected", "rate_limited", "invalid_request", "device_unavailable", "pairing_invalid"]
        guard allowed.contains(code) else { throw RelayFailure("protocol_error") }
        return RelayFailure(code, retryable: retryable)
    }
}

public struct RelayCookie: Codable, Sendable {
    public let name: String, value: String, domain: String, path: String
    public let secure: Bool
    public let expires: Double
    public init(name: String, value: String, domain: String, path: String, secure: Bool, expires: Double) {
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.secure = secure; self.expires = expires
    }
    public func applies(to url: URL, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let host = url.host?.lowercased(), expires == -1 || expires > now,
              !secure || ["https", "wss"].contains(url.scheme) else { return false }
        let domain = domain.lowercased(), bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare)) else { return false }
        let target = url.path.isEmpty ? "/" : url.path
        return target == path || (target.hasPrefix(path) && (path.hasSuffix("/") || target.dropFirst(path.count).first == "/"))
    }
    public func validate() throws {
        let separators = "()<>@,;:\\\"/[]?={} \t"
        guard !name.isEmpty, name.utf8.count <= 256,
              name.utf8.allSatisfy({ (33...126).contains($0) }), !name.contains(where: { separators.contains($0) }),
              value.utf8.count <= 8192, value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 34 && $0 != 44 && $0 != 59 && $0 != 92 }),
              !domain.isEmpty, domain.utf8.count <= 255, domain.utf8.allSatisfy({ (33...126).contains($0) }),
              path.hasPrefix("/"), path.utf8.count <= 2048, !path.contains(where: { $0.isNewline }),
              expires.isFinite, expires == -1 || expires > 0 else { throw RelayFailure("helper_protocol") }
    }
}

public struct RelayAuthentication: Codable, Sendable {
    public let origin: RelayOrigin, username: String, cookies: [RelayCookie]
    public init(origin: RelayOrigin, username: String, cookies: [RelayCookie]) throws {
        guard !username.isEmpty, username.utf8.count <= 256, !username.contains(where: { $0.isWhitespace || $0.isNewline }),
              username.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), cookies.count <= 128 else {
            throw RelayFailure("helper_protocol")
        }
        for cookie in cookies { try cookie.validate() }
        self.origin = origin; self.username = username; self.cookies = cookies
    }
    public func cookieHeader(for url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host else {
            throw RelayFailure("invalid_server")
        }
        let scheme = parts.scheme == "wss" ? "https" : parts.scheme
        let port = parts.port.map { ":\($0)" } ?? ""
        guard try RelayOrigin("\(scheme ?? "")://\(host)\(port)") == origin else { throw RelayFailure("invalid_server") }
        let header = cookies.filter { $0.applies(to: url) }.sorted { $0.path.count > $1.path.count }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard header.utf8.count <= 16384 else { throw RelayFailure("helper_protocol") }
        return header
    }
}

enum RelayDeviceState: String { case unbound, binding, online }
enum RelayDeviceMessage {
    case hello(connection: UUID, state: RelayDeviceState, device: UUID?)
    case binding(pairing: UUID, path: String, expires: Double)
    case ping(String)
    case error(RelayFailure)
    case watch(UUID)
    case close(UUID, String)
    case observer(UUID, Data)

    static func parse(_ data: Data) throws -> RelayDeviceMessage {
        guard data.count <= ObserverLimits.maxControlBytes, !data.contains(0), String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw RelayFailure("protocol_error") }
        func fields(_ expected: Set<String>) throws {
            guard Set(object.keys) == expected.union(["type"]) else { throw RelayFailure("protocol_error") }
        }
        switch type {
        case "relay.hello":
            try fields(["relayVersion", "connectionId", "state", "deviceId"])
            guard let version = object["relayVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                  let raw = object["connectionId"] as? String, let connection = UUID(uuidString: raw),
                  let value = object["state"] as? String, let state = RelayDeviceState(rawValue: value) else {
                throw RelayFailure("protocol_error")
            }
            var device: UUID?
            if state == .online {
                guard let raw = object["deviceId"] as? String, let id = UUID(uuidString: raw) else { throw RelayFailure("protocol_error") }
                device = id
            } else if !(object["deviceId"] is NSNull) { throw RelayFailure("protocol_error") }
            return .hello(connection: connection, state: state, device: device)
        case "device.bind.ready":
            try fields(["pairingId", "bindPath", "expiresAt"])
            guard let raw = object["pairingId"] as? String, let pairing = UUID(uuidString: raw), let path = object["bindPath"] as? String,
                  let number = object["expiresAt"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0,
                  number.doubleValue.rounded() == number.doubleValue else { throw RelayFailure("protocol_error") }
            return .binding(pairing: pairing, path: path, expires: number.doubleValue)
        case "relay.ping":
            try fields(["nonce"])
            guard let nonce = object["nonce"] as? String, (1...64).contains(nonce.count) else { throw RelayFailure("protocol_error") }
            return .ping(nonce)
        case "relay.error":
            try fields(["code", "retryable"])
            guard let code = object["code"] as? String, let flag = object["retryable"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw RelayFailure("protocol_error") }
            return .error(try RelayFailure.server(code, retryable: flag.boolValue))
        case "relay.watch.open":
            try fields(["sessionId"])
            guard let raw = object["sessionId"] as? String, let id = UUID(uuidString: raw) else { throw RelayFailure("protocol_error") }
            return .watch(id)
        case "relay.watch.close":
            try fields(["sessionId", "code"])
            guard let raw = object["sessionId"] as? String, let id = UUID(uuidString: raw),
                  let code = object["code"] as? String,
                  ["viewer_closed", "device_offline", "session_timeout", "slow_consumer", "protocol_error", "authorization_expired", "revoked"].contains(code) else {
                throw RelayFailure("protocol_error")
            }
            return .close(id, code)
        case "observer":
            try fields(["sessionId", "message"])
            guard let raw = object["sessionId"] as? String, let id = UUID(uuidString: raw),
                  let inner = object["message"] as? [String: Any], let kind = inner["type"] as? String,
                  ["subscribe", "ack", "resync", "mode"].contains(kind) else { throw RelayFailure("protocol_error") }
            return .observer(id, try JSONSerialization.data(withJSONObject: inner))
        default: throw RelayFailure("protocol_error")
        }
    }
}
