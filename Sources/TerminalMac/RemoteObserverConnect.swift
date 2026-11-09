import AppKit
import Foundation
import Darwin
import TerminalMacCore
import TerminalObserver

@MainActor
extension CLI {
    func connect(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["force-login", "hide-cursor", "verbose"], options: ["server", "port"])
        let verbose = args.flags.contains("verbose")
        observerDebug("begin version=\(appVersion)", verbose: verbose)
        guard args.options["port"] == nil else { throw Failure("--port was removed. Use connect [NAME] --server https://HOST.") }
        let name = try args.machineName(); _ = try store.load(name)
        let directory = try store.directory(name)
        let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        do { let probe = try FileLock(directory.appendingPathComponent("observer.lock")); withExtendedLifetime(probe) {} }
        catch {
            observerDebug("observer.lock busy; checking existing worker", verbose: verbose)
            guard let current = try? await observerStatus(directory: directory), current["state"] == "online",
                  let server = current["server"] else { throw error }
            let origin = try Self.selectObserverOrigin(server: args.options["server"], previous: server, interactive: interactive)
            guard origin.value == server else { throw Failure("An observer connection for another server already owns observer.lock.") }
            observerDebug("reuse server=\(origin.value)", verbose: verbose)
            let auth = try await AuthSession(verbose: verbose).authenticate(origin: origin, interactive: interactive, forceLogin: args.flags.contains("force-login"))
            guard auth.username == current["username"] else { throw RelayFailure("identity_mismatch") }
            let latest = try await observerStatus(directory: directory)
            guard latest["state"] == "online", latest["server"] == server, latest["username"] == auth.username,
                  latest["observerId"] == current["observerId"], latest["workerId"] == current["workerId"],
                  latest["generation"] != nil, latest["generation"] == current["generation"] else { throw RelayFailure("device_offline") }
            print("Observer already connected: \(name)"); return
        }
        let frontend = Task { @MainActor in
            try await startObserverFrontend(name: name, directory: directory, server: args.options["server"],
                interactive: interactive, forceLogin: args.flags.contains("force-login"), hideCursor: args.flags.contains("hide-cursor"), verbose: verbose)
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
        do { try await frontend.value } catch is CancellationError {
            observerDebug("cancelled", verbose: verbose); return
        } catch {
            observerDebug("failed code=\((error as? RelayFailure)?.code ?? "local_error")", verbose: verbose)
            throw error
        }
    }

    private func startObserverFrontend(name: String, directory: URL, server: String?, interactive: Bool, forceLogin: Bool, hideCursor: Bool, verbose: Bool) async throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executableURL; process.arguments = ["__observer", name]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment; environment["TERMINAL_MAC_HOME"] = store.root.path
        process.environment = environment
        try process.run()
        observerDebug("worker started pid=\(process.processIdentifier)", verbose: verbose)
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
            observerDebug("worker locked observer_id=\(locked.observerId!.uuidString)", verbose: verbose)
            let origin = try Self.selectObserverOrigin(server: server, previous: locked.previousServer, interactive: interactive)
            observerDebug("server=\(origin.value)", verbose: verbose)
            if interactive { stderr("Checking SSO cache. Chrome opens only if login is required; Ctrl+C cancels.") }
            let auth = try await AuthSession(verbose: verbose).authenticate(origin: origin, interactive: interactive, forceLogin: forceLogin)
            try Task.checkCancellation()
            try await ipc.send(ObserverIPCMessage(kind: .start, authentication: auth, interactive: interactive, hideCursor: hideCursor))
            observerDebug("worker authentication sent; awaiting binding or online", verbose: verbose)
            while !detached {
                try Task.checkCancellation()
                guard let event = try await ipc.receive() else { throw RelayFailure("worker_stopped") }
                observerDebug("worker event=\(event.kind.rawValue)", verbose: verbose)
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
                    let url = try origin.bindingURL(path)
                    observerDebug("binding pairing_id=\(id.uuidString) expires_at=\(expiry)", verbose: verbose)
                    observerDebug("binding URL contains a short-lived confirmation token; remove it before sharing logs: \(url.absoluteString)", verbose: verbose)
                    try window?.ready(pairingId: id, url: url, expiresAt: expiry)
                case .expired: window?.expired()
                case .failed:
                    guard let code = event.code, code.utf8.count <= 64 else { throw RelayFailure("ipc_invalid") }
                    observerDebug("worker failed code=\(code)", verbose: verbose)
                    if let window { window.failed(code) }
                    else { throw RelayFailure(code) }
                case .online:
                    guard let device = event.deviceId, let generation = event.generation else { throw RelayFailure("ipc_invalid") }
                    observerDebug("online device_id=\(device.uuidString) generation=\(generation.uuidString); requesting detach", verbose: verbose)
                    try await ipc.send(ObserverIPCMessage(kind: .detach, deviceId: device, generation: generation))
                    guard let ack = try await ipc.receive(timeout: 5), ack.kind == .detached, ack.deviceId == device,
                          ack.generation == generation else {
                        throw RelayFailure("ipc_invalid")
                    }
                    detached = true; window?.finish()
                    observerDebug("detach acknowledged; verbose logging ends", verbose: verbose)
                    print("Observer connected in background: \(name) (\(device.uuidString))")
                default: throw RelayFailure("ipc_invalid")
                }
            }
        } catch {
            if !detached {
                observerDebug("worker cleanup reason=\(error is CancellationError ? "cancelled" : (error as? RelayFailure)?.code ?? "local_error")", verbose: verbose)
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
                    observerDebug("worker exited status=\(process.terminationStatus)", verbose: verbose)
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
    static func selectObserverOrigin(server: String?, previous: String?, interactive: Bool,
                                     readInput: () -> String? = { readLine() }) throws -> RelayOrigin {
        if let server { return try RelayOrigin(server) }
        if !interactive {
            guard let previous else { throw Failure("Noninteractive connect requires --server or a previously authenticated server.") }
            return try RelayOrigin(previous)
        }
        let prompt = previous.map { "HTTPS server [\($0)]: " } ?? "HTTPS server: "
        print(prompt, terminator: ""); fflush(stdout)
        guard let input = readInput() else { throw CancellationError() }
        let value = input.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            guard let previous else { throw Failure("Enter an HTTPS server origin or pass --server https://HOST.") }
            return try RelayOrigin(previous)
        }
        return try RelayOrigin(value)
    }
    static func retryObserverFailure(_ failure: RelayFailure) -> Bool {
        ["network_error", "server_unavailable", "heartbeat_timeout", "send_timeout", "session_timeout", "device_busy",
         "capacity_exceeded", "slow_consumer", "rate_limited"].contains(failure.code)
    }
    static func observerReconnectDelay(attempt: Int) -> Double { [1.0, 2, 4, 8, 15][min(max(0, attempt), 4)] }
}
