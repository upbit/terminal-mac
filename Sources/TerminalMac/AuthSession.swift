import Foundation
import Darwin
import CoreFoundation
import TerminalObserver

final class AuthSession: @unchecked Sendable {
    private let python: URL, helper: URL
    private let verbose: Bool
    init(python: URL? = nil, helper: URL? = nil, verbose: Bool = false) throws {
        self.verbose = verbose
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
        observerDebug("auth python=\(self.python.path) helper=\(self.helper.path)", verbose: verbose)
    }
    func authenticate(origin: RelayOrigin, interactive: Bool, forceLogin: Bool = false, checkOnly: Bool = false) async throws -> RelayAuthentication {
        let input = try JSONSerialization.data(withJSONObject: ["version": 1, "origin": origin.value,
            "interactive": interactive, "forceLogin": forceLogin, "mode": checkOnly ? "check" : "authenticate"])
        let python = self.python, helper = self.helper, verbose = self.verbose
        observerDebug("auth start interactive=\(interactive) force_login=\(forceLogin) check_only=\(checkOnly)", verbose: verbose)
        let reader = Task.detached {
            try Self.invoke(python: python, helper: helper, input: input, verbose: verbose)
        }
        let data = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
        try Task.checkCancellation()
        let auth = try Self.decode(data, origin: origin, verbose: verbose)
        observerDebug("auth identity validated relay_version=1 cookie_count=\(auth.cookies.count)", verbose: verbose)
        return auth
    }

    private static func invoke(python: URL, helper: URL, input: Data, verbose: Bool) throws -> Data {
        try Task.checkCancellation()
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = python; process.arguments = ["-B", helper.path]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        environment["TERMINAL_MAC_AUTH_VERBOSE"] = verbose ? "1" : "0"
        process.environment = environment
        defer {
            try? stdin.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        }
        do { try process.run() } catch {
            observerDebug("auth helper launch failed os_code=\((error as NSError).code)", verbose: verbose)
            throw RelayFailure("helper_dependencies")
        }
        observerDebug("auth helper started pid=\(process.processIdentifier) pgid=\(getpgid(process.processIdentifier))", verbose: verbose)
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
                    // The helper owns a process group; terminate browser children only on failed cleanup.
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
        observerDebug("auth helper exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) bytes=\(output.count) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))", verbose: verbose)
        if let failure { throw failure }
        guard process.terminationStatus == 0 else { throw RelayFailure("helper_protocol") }
        return output
    }

    static func decode(_ data: Data, origin: RelayOrigin, verbose: Bool = false) throws -> RelayAuthentication {
        guard data.count <= 128 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let ok = object["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else {
            throw RelayFailure("helper_protocol")
        }
        if !ok.boolValue {
            let fields: Set<String> = object["diagnostic"] == nil ? ["version", "ok", "error"] : ["version", "ok", "error", "diagnostic"]
            guard Set(object.keys) == fields, let error = object["error"] as? [String: Any],
                  Set(error.keys) == ["code", "retryable"], let code = error["code"] as? String,
                  let retryable = error["retryable"] as? NSNumber, CFGetTypeID(retryable) == CFBooleanGetTypeID(),
                  ["invalid_server", "login_required", "keychain_failed", "helper_dependencies", "helper_protocol", "auth_timeout",
                   "server_unavailable", "server_protocol", "network_error", "cancelled"].contains(code) else {
                throw RelayFailure("helper_protocol")
            }
            if let raw = object["diagnostic"] {
                guard let detail = raw as? [String: Any],
                      Set(detail.keys) == ["stage", "function", "line", "exceptionType", "errno"],
                      let stage = detail["stage"] as? String, let function = detail["function"] as? String,
                      let type = detail["exceptionType"] as? String,
                      [stage, function, type].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 &&
                          $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 } }),
                      let line = detail["line"] as? NSNumber, CFGetTypeID(line) != CFBooleanGetTypeID(),
                      line.doubleValue == Double(line.intValue), (1...100_000).contains(line.intValue),
                      detail["errno"] is NSNull || (detail["errno"] as? NSNumber).map({
                          CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == Double($0.intValue) && (0...Double(Int32.max)).contains($0.doubleValue)
                      }) == true else { throw RelayFailure("helper_protocol") }
                let errno = (detail["errno"] as? NSNumber)?.stringValue ?? "none"
                observerDebug("auth diagnostic stage=\(stage) function=\(function) line=\(line.intValue) exception=\(type) errno=\(errno)", verbose: verbose)
            }
            observerDebug("auth failed code=\(code) retryable=\(retryable.boolValue)", verbose: verbose)
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

func observerDebug(_ message: String, verbose: Bool) {
    guard verbose else { return }
    stderr("[connect] \(message.prefix(4096))")
}
