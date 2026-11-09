import AppKit
import Foundation
import Darwin
import TerminalMacCore
import TerminalObserver

@MainActor
extension CLI {
    func connect(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["force-login", "hide-cursor"], options: ["server", "port"])
        guard args.options["port"] == nil else { throw Failure("--port was removed. Use connect [NAME] --server https://HOST.") }
        let name = try args.machineName(); _ = try store.load(name)
        let directory = try store.directory(name)
        let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        do { let probe = try FileLock(directory.appendingPathComponent("observer.lock")); withExtendedLifetime(probe) {} }
        catch {
            guard let current = try? await observerStatus(directory: directory), current["state"] == "online",
                  let server = current["server"] else { throw error }
            let origin = try Self.selectObserverOrigin(server: args.options["server"], previous: server, interactive: interactive)
            guard origin.value == server else { throw Failure("An observer connection for another server already owns observer.lock.") }
            let auth = try await AuthSession().authenticate(origin: origin, interactive: interactive, forceLogin: args.flags.contains("force-login"))
            guard auth.username == current["username"] else { throw RelayFailure("identity_mismatch") }
            let latest = try await observerStatus(directory: directory)
            guard latest["state"] == "online", latest["server"] == server, latest["username"] == auth.username,
                  latest["observerId"] == current["observerId"], latest["workerId"] == current["workerId"],
                  latest["generation"] != nil, latest["generation"] == current["generation"] else { throw RelayFailure("device_offline") }
            print("Observer already connected: \(name)"); return
        }
        let frontend = Task { @MainActor in
            try await startObserverFrontend(name: name, directory: directory, server: args.options["server"],
                interactive: interactive, forceLogin: args.flags.contains("force-login"), hideCursor: args.flags.contains("hide-cursor"))
        }
        observerFrontendCancel = { frontend.cancel() }
        let signals = [SIGINT, SIGTERM, SIGHUP], old = signals.map { Darwin.signal($0, SIG_IGN) }
        let sources = signals.map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { frontend.cancel() }; source.resume(); return source
        }
        defer {
            observerFrontendCancel = nil
            for (index, source) in sources.enumerated() { source.cancel(); Darwin.signal(signals[index], old[index]) }
        }
        do { try await frontend.value } catch is CancellationError { return }
    }

    private func startObserverFrontend(name: String, directory: URL, server: String?, interactive: Bool, forceLogin: Bool, hideCursor: Bool) async throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executableURL; process.arguments = ["__observer", name]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment; environment["TERMINAL_MAC_HOME"] = store.root.path
        process.environment = environment
        try process.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        let ipc = ObserverIPC(input: output.fileHandleForReading, output: input.fileHandleForWriting)
        var window: ObserverBindingWindow?, detached = false
        defer {
            window?.finish()
            try? output.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
        }
        do {
            guard let locked = try await ipc.receive(timeout: 5), locked.kind == .locked, locked.observerId != nil else {
                throw Failure("Observer worker could not acquire observer.lock or initialize its configuration.")
            }
            let origin = try Self.selectObserverOrigin(server: server, previous: locked.previousServer, interactive: interactive)
            if interactive { stderr("Checking SSO cache. Chrome opens only if login is required; Ctrl+C cancels.") }
            let auth = try await AuthSession().authenticate(origin: origin, interactive: interactive, forceLogin: forceLogin)
            try Task.checkCancellation()
            try await ipc.send(ObserverIPCMessage(kind: .start, authentication: auth, interactive: interactive, hideCursor: hideCursor))
            while !detached {
                try Task.checkCancellation()
                guard let event = try await ipc.receive() else { throw RelayFailure("worker_stopped") }
                switch event.kind {
                case .binding:
                    guard interactive, let id = event.pairingId, let path = event.bindPath, let expiry = event.expiresAt else {
                        throw RelayFailure("ipc_invalid")
                    }
                    if window == nil {
                        let view = ObserverBindingWindow(name: name, origin: origin)
                        view.onCancel = { [weak self] in self?.observerFrontendCancel?() }
                        view.onRegenerate = { Task { try? await ipc.send(ObserverIPCMessage(kind: .regenerate)) } }
                        window = view
                    }
                    try window?.ready(pairingId: id, url: origin.bindingURL(path), expiresAt: expiry)
                case .expired: window?.expired()
                case .failed:
                    guard let code = event.code, code.utf8.count <= 64 else { throw RelayFailure("ipc_invalid") }
                    if let window { window.failed(code) }
                    else { throw RelayFailure(code) }
                case .online:
                    guard let device = event.deviceId, let generation = event.generation else { throw RelayFailure("ipc_invalid") }
                    try await ipc.send(ObserverIPCMessage(kind: .detach, deviceId: device, generation: generation))
                    guard let ack = try await ipc.receive(timeout: 5), ack.kind == .detached, ack.deviceId == device,
                          ack.generation == generation else {
                        throw RelayFailure("ipc_invalid")
                    }
                    detached = true; window?.finish()
                    print("Observer connected in background: \(name) (\(device.uuidString))")
                default: throw RelayFailure("ipc_invalid")
                }
            }
        } catch {
            if !detached {
                let cleanup = Task { @MainActor in
                    if error is CancellationError { try? await ipc.send(ObserverIPCMessage(kind: .cancel)) }
                    else { try? input.fileHandleForWriting.close() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 20
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if process.isRunning { process.terminate() }
                    let terminateDeadline = ProcessInfo.processInfo.systemUptime + 5
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < terminateDeadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }
                await cleanup.value
            }
            throw error
        }
    }

    func disconnect(_ input: [String]) async throws {
        let args = try Arguments(input), name = try args.machineName()
        _ = try store.load(name)
        let directory = try store.directory(name)
        guard let current = try? await observerStatus(directory: directory), let workerId = current["workerId"] else {
            do { let lock = try FileLock(directory.appendingPathComponent("observer.lock")); withExtendedLifetime(lock) {} }
            catch { throw Failure("observer.lock is held by an operation without a background control endpoint.") }
            print("Observer is not connected: \(name)"); return
        }
        let mailbox = try Mailbox(directory.appendingPathComponent("remote-observer-control"))
        _ = try await mailbox.call(Request(action: "disconnect", arguments: ["workerId": workerId], timeout: 3))
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let lock = try? FileLock(directory.appendingPathComponent("observer.lock")) {
                withExtendedLifetime(lock) {}; print("Observer disconnected: \(name)"); return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RelayFailure("disconnect_timeout")
    }
    private func observerStatus(directory: URL) async throws -> [String: String] {
        let mailbox = try Mailbox(directory.appendingPathComponent("remote-observer-control"))
        return try await mailbox.call(Request(action: "status", timeout: 1)).values
    }
    static func selectObserverOrigin(server: String?, previous: String?, interactive: Bool) throws -> RelayOrigin {
        if let server { return try RelayOrigin(server) }
        if !interactive {
            guard let previous else { throw Failure("Noninteractive connect requires --server or a previously authenticated server.") }
            return try RelayOrigin(previous)
        }
        print("Observer server:")
        print("  1. Default service (\(RelayOrigin.defaultServer))")
        print("  2. Other HTTPS origin")
        print("Server [\(previous ?? "1")]: ", terminator: ""); fflush(stdout)
        guard let choice = readLine() else { throw CancellationError() }
        switch choice.trimmingCharacters(in: .whitespaces) {
        case "": return try RelayOrigin(previous ?? RelayOrigin.defaultServer)
        case "1": return try RelayOrigin(RelayOrigin.defaultServer)
        case "2":
            print("HTTPS origin: ", terminator: ""); fflush(stdout)
            guard let server = readLine() else { throw CancellationError() }
            return try RelayOrigin(server.trimmingCharacters(in: .whitespaces))
        default: return try RelayOrigin(choice)
        }
    }
    static func retryObserverFailure(_ failure: RelayFailure) -> Bool {
        ["network_error", "server_unavailable", "heartbeat_timeout", "send_timeout", "session_timeout", "device_busy",
         "capacity_exceeded", "slow_consumer", "rate_limited"].contains(failure.code)
    }
    static func observerReconnectDelay(attempt: Int) -> Double { [1.0, 2, 4, 8, 15][min(max(0, attempt), 4)] }
}
