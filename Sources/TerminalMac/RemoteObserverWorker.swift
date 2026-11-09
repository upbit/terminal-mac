import Foundation
import Darwin
import TerminalMacCore
import TerminalObserver

@MainActor
final class RemoteObserverWorker {
    private let workerId = UUID()
    private let directory: URL, name: String, ipc: ObserverIPC
    private var configuration: RemoteObserverConfiguration
    private var authentication: RelayAuthentication?
    private var credentialKey: DeviceCredentialKey?
    private var token: DeviceToken?
    private var pairingId: UUID?
    private var pairingExpiresAt: Double?
    private var connection: Task<Void, Error>?
    private var lifetime: RelayConnectionLifetime?
    private var hideCursor = false
    private var detached = false, closing = false, interactive = false
    private var explicitCancel = false
    private var state = "starting", failureCode: String?
    private let credentials: any DeviceCredentialStore
    private let socketFactory: @Sendable (RelayAuthentication, String?) throws -> any RelaySocket
    private let inspect: @Sendable (RelayAuthentication, String) async throws -> RelaySessionRecord
    private let cancelPairing: @Sendable (RelayAuthentication, String, UUID, UUID) async throws -> RelayPairingCancellation.Result

    init(directory: URL, name: String, ipc: ObserverIPC, credentials: any DeviceCredentialStore,
         socketFactory: @escaping @Sendable (RelayAuthentication, String?) throws -> any RelaySocket = {
             try URLSessionRelaySocket(authentication: $0, deviceToken: $1)
         }, inspect: @escaping @Sendable (RelayAuthentication, String) async throws -> RelaySessionRecord = {
             try await RelaySessionDiagnosis.inspect(authentication: $0, deviceToken: $1)
         }, cancelPairing: @escaping @Sendable (RelayAuthentication, String, UUID, UUID) async throws -> RelayPairingCancellation.Result = {
             try await RelayPairingCancellation.cancel(authentication: $0, deviceToken: $1, observerId: $2, pairingId: $3)
         }) throws {
        self.directory = directory; self.name = name; self.ipc = ipc; self.credentials = credentials
        self.socketFactory = socketFactory; self.inspect = inspect; self.cancelPairing = cancelPairing
        configuration = try RemoteObserverConfiguration.load(directory: directory)
    }
    func run() async throws {
        let mailbox = try Mailbox(directory.appendingPathComponent("remote-observer-control"), create: true)
        let controls = Task { @MainActor in
            while !Task.isCancelled {
                for request in (try? mailbox.requests()) ?? [] {
                    switch request.action {
                    case "status":
                        try? mailbox.respond(Reply(id: request.id, values: status))
                    case "disconnect":
                        guard request.arguments["workerId"] == workerId.uuidString else {
                            try? mailbox.respond(Reply(id: request.id, error: "Observer worker changed; repeat disconnect."))
                            continue
                        }
                        try? mailbox.respond(Reply(id: request.id, values: ["state": "stopping"]))
                        closing = true; connection?.cancel()
                        return
                    default: try? mailbox.respond(Reply(id: request.id, error: "Unknown observer operation"))
                    }
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        defer { controls.cancel() }
        do {
            try await ipc.send(ObserverIPCMessage(kind: .locked, observerId: configuration.observerId, previousServer: configuration.lastServer))
            guard let start = try await nextCommand(timeout: 360), start.kind == .start,
                  let supplied = start.authentication, let interactive = start.interactive else { throw RelayFailure("ipc_invalid") }
            let origin = try RelayOrigin(supplied.origin.value)
            authentication = try RelayAuthentication(origin: origin, username: supplied.username, cookies: supplied.cookies)
            self.interactive = interactive
            hideCursor = start.hideCursor ?? false
            configuration.lastServer = origin.value; try configuration.save(directory: directory)
            credentialKey = DeviceCredentialKey(origin: origin, username: supplied.username, observerId: configuration.observerId)
            token = try credentials.read(credentialKey!)
            if token != nil {
                let record = try await inspected()
                if record?.state == .binding {
                    guard interactive else { throw RelayFailure("binding_required") }
                }
            }
            if token == nil {
                guard interactive else { throw RelayFailure("binding_required") }
                try createToken()
                startConnection(recovering: false)
            } else { startConnection(recovering: true) }
            while !detached && !closing {
                guard let message = try await nextCommand() else { closing = true; break }
                switch message.kind {
                case .regenerate:
                    guard state == "expired" || state == "failed" ||
                          (state == "binding" && Date().timeIntervalSince1970 >= (pairingExpiresAt ?? .infinity)) else { continue }
                    state = "connecting"
                    do {
                        await stopConnection()
                        let confirmed = try await abandonPending()
                        if confirmed { startConnection(recovering: true) }
                        else { try createToken(); startConnection(recovering: false) }
                    } catch {
                        state = "failed"; failureCode = (error as? RelayFailure)?.code ?? "network_error"
                        try await ipc.send(ObserverIPCMessage(kind: .failed, code: failureCode))
                    }
                case .cancel: explicitCancel = true; closing = true
                case .detach:
                    guard state == "online", let lifetime, lifetime.isOnline,
                          message.generation == lifetime.generation, message.deviceId == configuration.deviceId else {
                        throw RelayFailure("device_offline")
                    }
                    detached = true
                    try await ipc.send(ObserverIPCMessage(kind: .detached, deviceId: configuration.deviceId, generation: lifetime.generation))
                default: throw RelayFailure("ipc_invalid")
                }
            }
            if detached && !closing {
                let current = connection
                try await withTaskCancellationHandler(operation: { try await current?.value }, onCancel: { current?.cancel() })
            }
        } catch {
            if !detached { try? await ipc.send(ObserverIPCMessage(kind: .failed, code: (error as? RelayFailure)?.code ?? "connection_failed")) }
            await stopConnection()
            if !detached && explicitCancel { await cancelOnExit() }
            writeFailure((error as? RelayFailure)?.code ?? "connection_failed", mailbox: mailbox)
            if error is CancellationError { return }
            throw error
        }
        await stopConnection()
        if !detached && explicitCancel { await cancelOnExit() }
        state = "stopped"
        try? mailbox.write(JSONEncoder().encode(status), named: "last-status.json")
    }
    private func nextCommand(timeout: Double? = nil) async throws -> ObserverIPCMessage? {
        let read = Task { try await ipc.receive(timeout: timeout) }
        let monitor = Task {
            while !Task.isCancelled {
                if closing { read.cancel(); return }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        defer { monitor.cancel() }
        do {
            return try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
        }
        catch is CancellationError { if closing { return nil }; throw CancellationError() }
    }
    private var status: [String: String] {
        let online = state == "online" && lifetime?.isOnline == true
        var values = ["state": state == "online" && !online ? "connecting" : state,
                      "observerId": configuration.observerId.uuidString, "workerId": workerId.uuidString]
        if let authentication { values["server"] = authentication.origin.value; values["username"] = authentication.username }
        if online, let id = configuration.deviceId, let lifetime {
            values["deviceId"] = id.uuidString; values["generation"] = lifetime.generation.uuidString
        }
        if let failureCode { values["code"] = failureCode }
        return values
    }
    private func writeFailure(_ code: String, mailbox: Mailbox) {
        failureCode = code; state = "stopped"
        try? mailbox.write(JSONEncoder().encode(status), named: "last-status.json")
    }
    private func createToken() throws {
        guard let credentialKey else { throw RelayFailure("ipc_invalid") }
        let candidate = try DeviceToken.generate()
        try credentials.save(candidate, for: credentialKey)
        token = candidate; pairingId = nil; pairingExpiresAt = nil
    }
    private func inspected() async throws -> RelaySessionRecord? {
        guard let authentication, let token else { return nil }
        do { return try await inspect(authentication, token.value) }
        catch let error as RelayFailure where error.code == "binding_invalid" {
            try discardToken(); return nil
        }
    }
    private func discardToken() throws {
        guard let credentialKey else { return }
        // Only remove the credential this worker actually holds, never a newer candidate.
        if try credentials.read(credentialKey) == token { try credentials.remove(credentialKey) }
        token = nil; pairingId = nil; pairingExpiresAt = nil; configuration.deviceId = nil
        try configuration.save(directory: directory)
    }
    private func abandonPending() async throws -> Bool {
        guard let authentication, let token else { return false }
        guard let record = try await inspected() else { return false }
        if record.state == .bound {
            configuration.deviceId = record.id; try configuration.save(directory: directory); return true
        }
        do {
            let result = try await cancelPairing(authentication, token.value, configuration.observerId, record.id)
            switch result {
            case .cancelled: try discardToken(); return false
            case .confirmed(let device):
                configuration.deviceId = device; try configuration.save(directory: directory); return true
            }
        } catch let error as RelayFailure where error.code == "binding_invalid" {
            try discardToken(); return false
        }
    }
    private func cancelOnExit() async {
        let cleanup = Task { @MainActor in
            do { _ = try await abandonPending() }
            catch { failureCode = (error as? RelayFailure)?.code ?? "cancel_unconfirmed" }
        }
        await cleanup.value
    }
    private func stopConnection() async {
        lifetime?.invalidate(); lifetime = nil
        let old = connection; connection = nil; old?.cancel(); _ = try? await old?.value
    }
    private func startConnection(recovering: Bool) {
        state = "connecting"; failureCode = nil
        connection = Task { @MainActor in
            do { try await connectionLoop(recovering: recovering) }
            catch is CancellationError { return }
            catch {
                state = (error as? RelayFailure)?.code == "pairing_expired" ? "expired" : "failed"
                failureCode = (error as? RelayFailure)?.code ?? "network_error"
                if !detached {
                    try? await ipc.send(ObserverIPCMessage(kind: state == "expired" ? .expired : .failed, code: failureCode))
                } else { throw error }
            }
        }
    }
    private func connectionLoop(recovering initial: Bool) async throws {
        guard var authentication, let token else { throw RelayFailure("ipc_invalid") }
        var recovering = initial, attempt = 0
        var repeated: [String: Int] = [:]
        while !closing {
            try Task.checkCancellation()
            let socket = try socketFactory(authentication, recovering ? token.value : nil)
            let current = RelayConnectionLifetime(); lifetime = current
            do {
                let source = GuestObserverSource(directory: directory, showsCursor: !hideCursor)
                try await ObserverRelay(source: source).run(socket: socket, origin: authentication.origin,
                    observerId: configuration.observerId, name: name, deviceToken: token.value,
                    recovering: recovering, interactive: interactive && !detached, lifetime: current) { [weak self] event in
                        try Task.checkCancellation()
                        guard let self else { throw CancellationError() }
                        try await self.event(event, lifetime: current)
                    }
            } catch {
                current.invalidate(); socket.close()
                if state == "online" { attempt = 0; repeated.removeAll() }
                state = "connecting"
                try Task.checkCancellation()
                var reason = (error as? RelayFailure) ?? RelayFailure("network_error", retryable: true)
                if ["network_error", "auth_required", "gateway_identity_required"].contains(reason.code) {
                    do { _ = try await inspect(authentication, token.value) }
                    catch let classified as RelayFailure { reason = classified }
                    if ["auth_required", "gateway_identity_required"].contains(reason.code) {
                        let checked = try await AuthSession().authenticate(origin: authentication.origin, interactive: false, checkOnly: true)
                        guard checked.username == authentication.username else { throw RelayFailure("identity_mismatch") }
                        authentication = checked; self.authentication = checked
                        reason = RelayFailure("network_error", retryable: true)
                    }
                }
                if reason.code == "binding_invalid" { try discardToken(); throw reason }
                guard CLI.retryObserverFailure(reason) else { throw reason }
                repeated[reason.code, default: 0] += 1
                if ["session_timeout", "capacity_exceeded", "slow_consumer"].contains(reason.code), repeated[reason.code]! >= 3 { throw reason }
                state = "connecting"
                let delay = CLI.observerReconnectDelay(attempt: attempt) + Double.random(in: 0...2)
                attempt += 1; recovering = true
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
    private func event(_ event: RelayEvent, lifetime: RelayConnectionLifetime) async throws {
        guard !closing, self.lifetime === lifetime else { throw CancellationError() }
        switch event {
        case .binding(let pairingId, let url, let expires):
            guard !detached else { throw RelayFailure("binding_required") }
            self.pairingId = pairingId; pairingExpiresAt = expires; state = "binding"
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            try await ipc.send(ObserverIPCMessage(kind: .binding, pairingId: pairingId,
                bindPath: parts.path + "#" + (parts.fragment ?? ""), expiresAt: expires))
        case .online(let device):
            guard lifetime.isOnline else { throw RelayFailure("device_offline") }
            configuration.deviceId = device; try configuration.save(directory: directory)
            pairingId = nil; pairingExpiresAt = nil; state = "online"
            if !detached { try await ipc.send(ObserverIPCMessage(kind: .online, deviceId: device, generation: lifetime.generation)) }
        }
    }
}

@MainActor
extension CLI {
    func observerWorker(_ input: [String]) async throws {
        let args = try Arguments(input), name = try args.machineName()
        _ = try store.load(name)
        let directory = try store.directory(name)
        let lock = try FileLock(directory.appendingPathComponent("observer.lock"))
        let worker = try RemoteObserverWorker(directory: directory, name: name,
            ipc: ObserverIPC(input: .standardInput, output: .standardOutput), credentials: KeychainDeviceCredentialStore(interactive: false))
        let task = Task { try await worker.run() }
        let signals = [SIGINT, SIGTERM]
        let old = signals.map { Darwin.signal($0, SIG_IGN) }
        let sources = signals.map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { task.cancel() }; source.resume(); return source
        }
        defer {
            withExtendedLifetime(lock) {}
            for (index, source) in sources.enumerated() { source.cancel(); Darwin.signal(signals[index], old[index]) }
        }
        try await task.value
    }
}
