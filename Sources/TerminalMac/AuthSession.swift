import Foundation
import Darwin
import CoreFoundation
import TerminalObserver

final class AuthSession: @unchecked Sendable {
    private let python: URL, helper: URL
    init(python: URL? = nil, helper: URL? = nil) throws {
        if let python { self.python = python }
        else if let override = ProcessInfo.processInfo.environment["TERMINAL_MAC_PYTHON"] {
            guard override.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: override) else {
                throw RelayFailure("helper_dependencies")
            }
            self.python = URL(fileURLWithPath: override)
        } else {
            let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            guard let path = paths.map({ String($0) + "/python3" }).first(where: {
                $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
            }) else { throw RelayFailure("helper_dependencies") }
            self.python = URL(fileURLWithPath: path)
        }
        if let helper { self.helper = helper }
        else {
            let resources = appBundle.resourceURL?.appendingPathComponent("terminal-mac_TerminalMac.bundle")
            let bundle = resources.flatMap { Bundle(url: $0) } ?? Bundle.module
            guard let url = bundle.url(forResource: "auth_session", withExtension: "py", subdirectory: "Auth") else {
                throw RelayFailure("helper_missing")
            }
            self.helper = url
        }
    }
    func authenticate(origin: RelayOrigin, interactive: Bool, forceLogin: Bool = false, checkOnly: Bool = false) async throws -> RelayAuthentication {
        let input = try JSONSerialization.data(withJSONObject: ["version": 1, "origin": origin.value,
            "interactive": interactive, "forceLogin": forceLogin, "mode": checkOnly ? "check" : "authenticate"])
        let python = self.python, helper = self.helper
        let reader = Task.detached {
            try Self.invoke(python: python, helper: helper, input: input)
        }
        let data = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
        try Task.checkCancellation()
        return try Self.decode(data, origin: origin)
    }

    private static func invoke(python: URL, helper: URL, input: Data) throws -> Data {
        try Task.checkCancellation()
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = python; process.arguments = ["-B", helper.path]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        defer {
            try? stdin.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        }
        do { try process.run() } catch { throw RelayFailure("helper_dependencies") }
        let fd = stdout.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var failure: Error?, stoppingAt: Double?, output = Data()
        do { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
        catch { failure = RelayFailure("helper_protocol") }
        try? stdout.fileHandleForWriting.close()
        let began = ProcessInfo.processInfo.systemUptime
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if Task.isCancelled { failure = CancellationError() }
            if failure == nil && now - began > 330 { failure = RelayFailure("auth_timeout") }
            if failure != nil, process.isRunning {
                if stoppingAt == nil { stoppingAt = now; process.terminate() }
                else if now - stoppingAt! >= 5 {
                    // The helper owns a session; terminate its browser children only on failed cleanup.
                    if getpgid(process.processIdentifier) == process.processIdentifier { _ = kill(-process.processIdentifier, SIGKILL) }
                    else { _ = kill(process.processIdentifier, SIGKILL) }
                }
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if output.count + count <= 128 * 1024 { output.append(contentsOf: buffer.prefix(count)) }
                else { failure = RelayFailure("helper_protocol") }
            } else if count < 0 && errno != EAGAIN && errno != EINTR {
                failure = RelayFailure("helper_protocol")
            }
            if !process.isRunning && count <= 0 { break }
            usleep(20_000)
        }
        process.waitUntilExit()
        if let failure { throw failure }
        guard process.terminationStatus == 0 else { throw RelayFailure("helper_protocol") }
        return output
    }

    static func decode(_ data: Data, origin: RelayOrigin) throws -> RelayAuthentication {
        guard data.count <= 128 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let ok = object["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else {
            throw RelayFailure("helper_protocol")
        }
        if !ok.boolValue {
            guard Set(object.keys) == ["version", "ok", "error"], let error = object["error"] as? [String: Any],
                  Set(error.keys) == ["code", "retryable"], let code = error["code"] as? String,
                  let retryable = error["retryable"] as? NSNumber, CFGetTypeID(retryable) == CFBooleanGetTypeID(),
                  ["invalid_server", "login_required", "keychain_failed", "helper_dependencies", "helper_protocol", "auth_timeout",
                   "server_unavailable", "server_protocol", "network_error", "cancelled"].contains(code) else {
                throw RelayFailure("helper_protocol")
            }
            if code == "cancelled" { throw CancellationError() }
            throw RelayFailure(code, retryable: retryable.boolValue)
        }
        guard Set(object.keys) == ["version", "ok", "origin", "username", "relayVersion", "cookies"],
              object["origin"] as? String == origin.value, let username = object["username"] as? String,
              let relayVersion = object["relayVersion"] as? NSNumber, CFGetTypeID(relayVersion) != CFBooleanGetTypeID(), relayVersion == 1,
              let raw = object["cookies"] as? [[String: Any]], raw.count <= 128,
              raw.allSatisfy({ Set($0.keys) == ["name", "value", "domain", "path", "secure", "expires"] }),
              let cookies = try? JSONDecoder().decode([RelayCookie].self, from: JSONSerialization.data(withJSONObject: raw)) else {
            throw RelayFailure("helper_protocol")
        }
        return try RelayAuthentication(origin: origin, username: username, cookies: cookies)
    }
}
