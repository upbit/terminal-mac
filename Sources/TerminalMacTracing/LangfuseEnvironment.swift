import Foundation
import TerminalMacCore

enum LangfuseEnvironment {
    static let keys: Set<String> = [
        "LANGFUSE_BASE_URL", "LANGFUSE_HOST", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY",
        "LANGFUSE_TRACING_ENABLED", "LANGFUSE_TRACING_ENVIRONMENT", "LANGFUSE_SAMPLE_RATE",
        "LANGFUSE_SESSION_ID", "LANGFUSE_USER_ID", "LANGFUSE_ALLOW_INSECURE_HTTP", "LANGFUSE_CONTENT_MODE",
        "LANGFUSE_MEDIA_ENABLED", "LANGFUSE_MEDIA_UPLOAD_HOSTS"
    ]

    static func load(process: [String: String], directory: URL) throws -> [String: String] {
        let overrides = process.filter { keys.contains($0.key) }
        if overrides["LANGFUSE_TRACING_ENABLED"] == "false" { return overrides }
        let explicit = process["TERMINAL_MAC_ENV_FILE"]
        let file = explicit.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL }
            ?? directory.appendingPathComponent(".env")
        let data: Data?
        do {
            data = try Mailbox(file.deletingLastPathComponent()).read(file.lastPathComponent, limit: 65_536)
        } catch { throw Failure("Langfuse tracing disabled: cannot safely read the dotenv file (maximum 64 KiB; regular files only).") }
        guard let data else {
            if explicit != nil { throw Failure("Langfuse tracing disabled: TERMINAL_MAC_ENV_FILE does not exist.") }
            return overrides
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure("Langfuse tracing disabled: dotenv file must be UTF-8.")
        }
        var merged = try parse(text).merging(overrides) { _, processValue in processValue }
        if process["LANGFUSE_BASE_URL"] == nil, process["LANGFUSE_HOST"] != nil {
            merged.removeValue(forKey: "LANGFUSE_BASE_URL")
        }
        return merged
    }

    // A deliberately restricted dotenv grammar: no shell execution, expansion, or multiline values.
    static func parse(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        let text = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let prefix = line.range(of: "^export[ \\t]+", options: .regularExpression) { line.removeSubrange(prefix) }
            guard let equals = line.firstIndex(of: "=") else {
                if keys.contains(line) { throw invalidLine(offset) }
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            let rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[key] = try value(rawValue, line: offset)
        }
        return values
    }

    private static func value(_ raw: String, line: Int) throws -> String {
        guard let quote = raw.first, quote == "\"" || quote == "'" else {
            let comment = raw.range(of: "[ \\t]+#", options: .regularExpression)
            return String(raw[..<(comment?.lowerBound ?? raw.endIndex)]).trimmingCharacters(in: .whitespaces)
        }
        var index = raw.index(after: raw.startIndex)
        var result = ""
        while index < raw.endIndex {
            let character = raw[index]
            index = raw.index(after: index)
            if character == quote {
                let tail = raw[index...].trimmingCharacters(in: .whitespaces)
                guard tail.isEmpty || tail.hasPrefix("#") else { throw invalidLine(line) }
                return result
            }
            if character == "\\", quote == "\"", index < raw.endIndex {
                let escaped = raw[index]
                let escapes: [Character: String] = ["n": "\n", "r": "\r", "t": "\t", "\"": "\"", "\\": "\\", "$": "$"]
                if let replacement = escapes[escaped] {
                    result += replacement; index = raw.index(after: index); continue
                }
            }
            result.append(character)
        }
        throw invalidLine(line)
    }

    private static func invalidLine(_ index: Int) -> Failure {
        Failure("Langfuse tracing disabled: invalid dotenv syntax on line \(index + 1). Values were not logged.")
    }
}
