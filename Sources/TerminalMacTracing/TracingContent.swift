import Foundation

struct TracingContent {
    let enabled: Bool
    let secrets: [String]
    static let textLimit = 4096
    static let payloadLimit = 16_384

    func text(_ value: String) -> String {
        guard enabled else { return "[REDACTED]" }
        var result = value
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        for pattern in [
            "(?i)(?:sk-lf-|pk-lf-|sk-)[a-z0-9_-]+",
            "(?i)Bearer[ \\t]+[^\\s\\\"']+",
            "(?i)(?:password|secret|token|api[_-]?key)\\s*[:=]\\s*[^\\s,;]+"
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        if result.utf8.count > Self.textLimit {
            result = String(decoding: Array(result.utf8.prefix(Self.textLimit)), as: UTF8.self) + "[TRUNCATED]"
        }
        return result
    }

    func json(_ object: [String: Any]) -> String {
        var truncated = false, redacted = false
        var cleaned = clean(object, depth: 0, truncated: &truncated, redacted: &redacted) as? [String: Any] ?? [:]
        if truncated || redacted {
            cleaned["_capture"] = ["truncated": truncated, "redacted": redacted,
                "original_bytes": (try? JSONSerialization.data(withJSONObject: object).count) ?? 0]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]),
              data.count <= Self.payloadLimit else {
            return "{\"truncated\":true,\"limit_bytes\":16384}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func clean(_ value: Any, depth: Int, truncated: inout Bool, redacted: inout Bool) -> Any {
        guard depth < 8 else { truncated = true; return "[TRUNCATED]" }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            if object.count > 64 { truncated = true }
            for key in object.keys.sorted().prefix(64) {
                let lower = key.lowercased().replacingOccurrences(of: "_", with: "")
                let sensitive = ["authorization", "password", "secret", "token", "apikey", "cookie"].contains { lower.contains($0) }
                if sensitive || ["data", "image", "context"].contains(lower) {
                    redacted = true
                    result[enabled ? text(key) : key] = "[REDACTED]"
                } else { result[enabled ? text(key) : key] = clean(object[key]!, depth: depth + 1, truncated: &truncated, redacted: &redacted) }
            }
            return result
        }
        if let array = value as? [Any] {
            if array.count > 64 { truncated = true }
            return array.prefix(64).map { clean($0, depth: depth + 1, truncated: &truncated, redacted: &redacted) }
        }
        if let string = value as? String {
            let result = text(string)
            if result.contains("[TRUNCATED]") { truncated = true }
            if result != string { redacted = true }
            return result
        }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : NSNull() }
        return NSNull()
    }
}
