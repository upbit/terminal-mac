import AppKit
import Foundation
import XCTest
import TerminalObserver
import TerminalMacCore
@testable import TerminalMac

final class WorkerFixtureSocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var reader: CheckedContinuation<Data, Error>?
    private var stopped = false
    var closeCode: Int { 0 }
    private(set) var writes: [Data] = []
    func push(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            if let reader { self.reader = nil; return reader }
            queue.append(data); return nil
        }
        continuation?.resume(returning: data)
    }
    func sendText(_ data: Data) async throws {
        try lock.withLock {
            if stopped { throw RelayFailure("network_error") }
            writes.append(data)
        }
    }
    func sendBinary(_ data: Data) async throws { try await sendText(data) }
    func receiveText() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if stopped { continuation.resume(throwing: RelayFailure("network_error")) }
                else if !queue.isEmpty { continuation.resume(returning: queue.removeFirst()) }
                else { reader = continuation }
            }
        }
    }
    func close() {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            stopped = true; let previous = reader; reader = nil; return previous
        }
        continuation?.resume(throwing: RelayFailure("network_error"))
    }
    var isClosed: Bool { lock.withLock { stopped } }
}

final class WorkerSocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [WorkerFixtureSocket]
    init(_ sockets: [WorkerFixtureSocket]) { self.sockets = sockets }
    func next() throws -> WorkerFixtureSocket {
        try lock.withLock {
            guard !sockets.isEmpty else { throw RelayFailure("fixture_exhausted") }
            return sockets.removeFirst()
        }
    }
}

actor WorkerDiagnosis {
    private(set) var calls = 0
    let device = UUID()
    func inspect() async throws -> RelaySessionRecord {
        calls += 1
        if calls > 1 { try await Task.sleep(nanoseconds: 500_000_000) }
        return RelaySessionRecord(state: .bound, id: device)
    }
}

@MainActor
final class ObserverWorkerTests: XCTestCase {
    let origin = try! RelayOrigin("https://fixture.example")
    func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("observer-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func channels() -> (ObserverIPC, ObserverIPC, Pipe, Pipe) {
        let input = Pipe(), output = Pipe()
        return (ObserverIPC(input: input.fileHandleForReading, output: output.fileHandleForWriting),
            ObserverIPC(input: output.fileHandleForReading, output: input.fileHandleForWriting), input, output)
    }
    func hello(_ state: String, id: UUID, device: UUID? = nil) -> [String: Any] {
        ["type": "relay.hello", "relayVersion": 1, "connectionId": id.uuidString, "state": state,
         "deviceId": device.map { $0.uuidString as Any } ?? NSNull()]
    }
    func disconnect(_ mailbox: Mailbox) async throws {
        let status = try await mailbox.call(Request(action: "status", timeout: 2))
        let id = try XCTUnwrap(status.values["workerId"])
        _ = try await mailbox.call(Request(action: "disconnect", arguments: ["workerId": id], timeout: 2))
    }
    func testSameSocketSurvivesDetachAndDisconnectPreservesBoundKey() async throws {
        let directory = try temporary(), config = try RemoteObserverConfiguration.load(directory: directory)
        let credentials = MemoryDeviceCredentials(), token = try DeviceToken.generate(), device = UUID()
        let key = DeviceCredentialKey(origin: origin, username: "fixture", observerId: config.observerId)
        try credentials.save(token, for: key)
        let (workerIPC, frontIPC, input, output) = channels(), socket = WorkerFixtureSocket()
        try socket.push(hello("online", id: UUID(), device: device))
        let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
            socketFactory: { _, supplied in XCTAssertEqual(supplied, token.value); return socket },
            inspect: { _, _ in RelaySessionRecord(state: .bound, id: device) })
        let task = Task { try await worker.run() }
        defer { task.cancel(); socket.close(); withExtendedLifetime((input, output)) {} }
        let locked = try await frontIPC.receive(timeout: 2); XCTAssertEqual(locked?.kind, .locked)
        try await frontIPC.send(ObserverIPCMessage(kind: .start,
            authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: false))
        let online = try await frontIPC.receive(timeout: 2); XCTAssertEqual(online?.deviceId, device)
        try await frontIPC.send(ObserverIPCMessage(kind: .detach, deviceId: online?.deviceId, generation: online?.generation))
        let ack = try await frontIPC.receive(timeout: 2); XCTAssertEqual(ack?.kind, .detached)
        try input.fileHandleForWriting.close(); try output.fileHandleForReading.close()
        XCTAssertFalse(socket.isClosed)
        let mailbox = try Mailbox(directory.appendingPathComponent("remote-observer-control"))
        let status = try await mailbox.call(Request(action: "status", timeout: 2))
        XCTAssertEqual(status.values["state"], "online")
        do {
            _ = try await mailbox.call(Request(action: "disconnect", arguments: ["workerId": UUID().uuidString], timeout: 2))
            XCTFail("Stale disconnect stopped a new worker")
        } catch { XCTAssertTrue(error.localizedDescription.contains("worker changed")) }
        XCTAssertFalse(socket.isClosed)
        try await disconnect(mailbox)
        try await task.value
        XCTAssertTrue(socket.isClosed); XCTAssertEqual(credentials.entries[key], token)
    }
    func testNormalStartupResumesPendingWithoutCancellingOrReplacingKey() async throws {
        let directory = try temporary(), config = try RemoteObserverConfiguration.load(directory: directory)
        let credentials = MemoryDeviceCredentials(), token = try DeviceToken.generate(), pairing = UUID()
        let key = DeviceCredentialKey(origin: origin, username: "fixture", observerId: config.observerId)
        try credentials.save(token, for: key)
        let (workerIPC, frontIPC, input, output) = channels(), socket = WorkerFixtureSocket()
        try socket.push(hello("binding", id: UUID()))
        try socket.push(["type": "device.bind.ready", "pairingId": pairing.uuidString,
            "bindPath": "/pair#token=" + String(repeating: "A", count: 43), "expiresAt": Int(Date().timeIntervalSince1970) + 300])
        let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
            socketFactory: { _, supplied in XCTAssertEqual(supplied, token.value); return socket },
            inspect: { _, _ in RelaySessionRecord(state: .binding, id: pairing) },
            cancelPairing: { _, _, _, _ in XCTFail("Normal recovery cancelled pending"); return .cancelled })
        let task = Task { try await worker.run() }
        defer { task.cancel(); socket.close(); withExtendedLifetime((input, output)) {} }
        _ = try await frontIPC.receive(timeout: 2)
        try await frontIPC.send(ObserverIPCMessage(kind: .start,
            authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: true))
        let ready = try await frontIPC.receive(timeout: 2)
        XCTAssertEqual(ready?.pairingId, pairing); XCTAssertEqual(credentials.entries[key], token)
        XCTAssertEqual(credentials.saves, 1)
        try input.fileHandleForWriting.close()
        try await task.value
        XCTAssertEqual(credentials.entries[key], token, "Transport EOF must preserve the candidate")
    }
    func testNoninteractivePendingAndDiagnosisFailureDoNotCancel() async throws {
        for networkFailure in [false, true] {
            let directory = try temporary(), config = try RemoteObserverConfiguration.load(directory: directory)
            let credentials = MemoryDeviceCredentials(), token = try DeviceToken.generate(), pairing = UUID()
            let key = DeviceCredentialKey(origin: origin, username: "fixture", observerId: config.observerId)
            try credentials.save(token, for: key)
            let (workerIPC, frontIPC, input, output) = channels()
            let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
                socketFactory: { _, _ in XCTFail("Must fail before WSS"); throw RelayFailure("fixture") },
                inspect: { _, _ in
                    if networkFailure { throw RelayFailure("server_unavailable", retryable: true) }
                    return RelaySessionRecord(state: .binding, id: pairing)
                }, cancelPairing: { _, _, _, _ in XCTFail("Failure cleanup cancelled pending"); return .cancelled })
            let task = Task { try await worker.run() }
            _ = try await frontIPC.receive(timeout: 2)
            try await frontIPC.send(ObserverIPCMessage(kind: .start,
                authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: false))
            do { try await task.value; XCTFail("Invalid startup succeeded") } catch {}
            XCTAssertEqual(credentials.entries[key], token)
            withExtendedLifetime((input, output)) {}
        }
    }
    func testDisconnectedGenerationCannotDetachOrReportOnlineDuringDiagnosis() async throws {
        let directory = try temporary(), config = try RemoteObserverConfiguration.load(directory: directory)
        let credentials = MemoryDeviceCredentials(), token = try DeviceToken.generate(), diagnosis = WorkerDiagnosis()
        let device = diagnosis.device
        let key = DeviceCredentialKey(origin: origin, username: "fixture", observerId: config.observerId)
        try credentials.save(token, for: key)
        let (workerIPC, frontIPC, input, output) = channels(), socket = WorkerFixtureSocket()
        try socket.push(hello("online", id: UUID(), device: device))
        let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
            socketFactory: { _, _ in socket }, inspect: { _, _ in try await diagnosis.inspect() },
            cancelPairing: { _, _, _, _ in XCTFail("Failed detach cancelled a credential"); return .cancelled })
        let task = Task { try await worker.run() }
        defer { task.cancel(); socket.close(); withExtendedLifetime((input, output)) {} }
        _ = try await frontIPC.receive(timeout: 2)
        try await frontIPC.send(ObserverIPCMessage(kind: .start,
            authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: false))
        let online = try await frontIPC.receive(timeout: 2)
        XCTAssertNotNil(online?.generation)
        socket.close()
        for _ in 0..<100 {
            if await diagnosis.calls > 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let mailbox = try Mailbox(directory.appendingPathComponent("remote-observer-control"))
        let status = try await mailbox.call(Request(action: "status", timeout: 1))
        XCTAssertNotEqual(status.values["state"], "online"); XCTAssertNil(status.values["generation"])
        try await frontIPC.send(ObserverIPCMessage(kind: .detach, deviceId: device, generation: online?.generation))
        let failed = try await frontIPC.receive(timeout: 2)
        XCTAssertEqual(failed?.kind, .failed)
        do { try await task.value; XCTFail("Stale detach succeeded") }
        catch { XCTAssertEqual((error as? RelayFailure)?.code, "device_offline") }
        XCTAssertEqual(credentials.entries[key], token)
    }
    func testCancelledPendingClearsCandidateOnlyAfterServerAcknowledgement() async throws {
        let directory = try temporary(), (workerIPC, frontIPC, input, output) = channels()
        let credentials = MemoryDeviceCredentials(), socket = WorkerFixtureSocket(), pairing = UUID()
        let id = UUID()
        try socket.push(hello("unbound", id: id))
        try socket.push(["type": "device.bind.ready", "pairingId": pairing.uuidString,
            "bindPath": "/pair#token=" + String(repeating: "A", count: 43), "expiresAt": Int(Date().timeIntervalSince1970) + 300])
        let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
            socketFactory: { _, token in XCTAssertNil(token); return socket },
            inspect: { _, _ in RelaySessionRecord(state: .binding, id: pairing) },
            cancelPairing: { _, _, _, id in XCTAssertEqual(id, pairing); return .cancelled })
        let task = Task { try await worker.run() }
        defer { task.cancel(); socket.close(); withExtendedLifetime((input, output)) {} }
        _ = try await frontIPC.receive(timeout: 2)
        try await frontIPC.send(ObserverIPCMessage(kind: .start,
            authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: true))
        let ready = try await frontIPC.receive(timeout: 2); XCTAssertEqual(ready?.pairingId, pairing)
        XCTAssertEqual(credentials.entries.count, 1)
        try await frontIPC.send(ObserverIPCMessage(kind: .cancel))
        try await task.value
        XCTAssertTrue(credentials.entries.isEmpty); XCTAssertTrue(socket.isClosed)
    }
    func testCancelLosingToConfirmAndUnsupportedCancelPreserveCredential() async throws {
        for supported in [true, false] {
            let directory = try temporary(), (workerIPC, frontIPC, input, output) = channels()
            let credentials = MemoryDeviceCredentials(), socket = WorkerFixtureSocket(), pairing = UUID(), device = UUID()
            try socket.push(hello("unbound", id: UUID()))
            try socket.push(["type": "device.bind.ready", "pairingId": pairing.uuidString,
                "bindPath": "/pair#token=" + String(repeating: "A", count: 43), "expiresAt": Int(Date().timeIntervalSince1970) + 300])
            let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
                socketFactory: { _, _ in socket }, inspect: { _, _ in RelaySessionRecord(state: .binding, id: pairing) },
                cancelPairing: { _, _, _, _ in
                    if !supported { throw RelayFailure("cancellation_unsupported") }
                    return .confirmed(device)
                })
            let task = Task { try await worker.run() }
            _ = try await frontIPC.receive(timeout: 2)
            try await frontIPC.send(ObserverIPCMessage(kind: .start,
                authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: true))
            _ = try await frontIPC.receive(timeout: 2)
            let candidate = credentials.entries.values.first
            try await frontIPC.send(ObserverIPCMessage(kind: .cancel)); try await task.value
            XCTAssertEqual(credentials.entries.values.first, candidate)
            let config = try RemoteObserverConfiguration.load(directory: directory)
            XCTAssertEqual(config.deviceId, supported ? device : nil)
            withExtendedLifetime((input, output)) {}
        }
    }
    func testIPCCancellationAndSizeLimits() async throws {
        let (worker, front, input, output) = channels()
        try await front.send(ObserverIPCMessage(kind: .failed, code: "fixture"))
        let event = try await worker.receive(timeout: 1); XCTAssertEqual(event?.code, "fixture")
        let read = Task { try await front.receive() }
        read.cancel()
        do { _ = try await read.value; XCTFail("IPC read did not cancel") } catch { XCTAssertTrue(error is CancellationError) }
        do { try await front.send(ObserverIPCMessage(kind: .failed, code: String(repeating: "x", count: 128 * 1024)))
            XCTFail("Oversized IPC accepted") } catch { XCTAssertEqual((error as? RelayFailure)?.code, "ipc_invalid") }
        withExtendedLifetime((input, output)) {}
    }
    func testExpiredRegenerationWaitsForCancellationBeforeReplacingKey() async throws {
        let directory = try temporary(), config = try RemoteObserverConfiguration.load(directory: directory)
        let (workerIPC, frontIPC, input, output) = channels(), credentials = MemoryDeviceCredentials()
        let first = WorkerFixtureSocket(), second = WorkerFixtureSocket(), pairing = UUID(), device = UUID()
        let sequence = WorkerSocketSequence([first, second])
        try first.push(hello("unbound", id: UUID()))
        try first.push(["type": "device.bind.ready", "pairingId": pairing.uuidString,
            "bindPath": "/pair#token=" + String(repeating: "A", count: 43), "expiresAt": Int(Date().timeIntervalSince1970) + 1])
        try first.push(["type": "relay.error", "code": "pairing_expired", "retryable": false])
        let connection = UUID()
        try second.push(hello("unbound", id: connection))
        try second.push(["type": "device.bind.ready", "pairingId": UUID().uuidString,
            "bindPath": "/pair#token=" + String(repeating: "A", count: 43), "expiresAt": Int(Date().timeIntervalSince1970) + 300])
        try second.push(hello("online", id: connection, device: device))
        let key = DeviceCredentialKey(origin: origin, username: "fixture", observerId: config.observerId)
        let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
            socketFactory: { _, _ in try sequence.next() },
            inspect: { _, _ in RelaySessionRecord(state: .binding, id: pairing) },
            cancelPairing: { _, _, _, id in XCTAssertEqual(id, pairing); return .cancelled })
        let task = Task { try await worker.run() }
        defer { task.cancel(); first.close(); second.close(); withExtendedLifetime((input, output)) {} }
        _ = try await frontIPC.receive(timeout: 2)
        try await frontIPC.send(ObserverIPCMessage(kind: .start,
            authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: true))
        _ = try await frontIPC.receive(timeout: 2)
        let expired = try await frontIPC.receive(timeout: 2); XCTAssertEqual(expired?.kind, .expired)
        let old = credentials.entries[key]
        try await frontIPC.send(ObserverIPCMessage(kind: .regenerate))
        _ = try await frontIPC.receive(timeout: 2)
        let online = try await frontIPC.receive(timeout: 2); XCTAssertEqual(online?.deviceId, device)
        XCTAssertNotEqual(credentials.entries[key], old); XCTAssertEqual(credentials.saves, 2)
        try await frontIPC.send(ObserverIPCMessage(kind: .detach, deviceId: online?.deviceId, generation: online?.generation))
        _ = try await frontIPC.receive(timeout: 2)
        let mailbox = try Mailbox(directory.appendingPathComponent("remote-observer-control"))
        try await disconnect(mailbox); try await task.value
    }
    func testFrontendEOFBeforeDetachPreservesAlreadyConfirmedKey() async throws {
        let directory = try temporary(), config = try RemoteObserverConfiguration.load(directory: directory)
        let (workerIPC, frontIPC, input, output) = channels(), credentials = MemoryDeviceCredentials()
        let socket = WorkerFixtureSocket(), device = UUID(), token = try DeviceToken.generate()
        let key = DeviceCredentialKey(origin: origin, username: "fixture", observerId: config.observerId)
        try credentials.save(token, for: key)
        try socket.push(hello("online", id: UUID(), device: device))
        let worker = try RemoteObserverWorker(directory: directory, name: "fixture", ipc: workerIPC, credentials: credentials,
            socketFactory: { _, _ in socket }, inspect: { _, _ in RelaySessionRecord(state: .bound, id: device) })
        let task = Task { try await worker.run() }
        defer { task.cancel(); socket.close(); withExtendedLifetime((input, output)) {} }
        _ = try await frontIPC.receive(timeout: 2)
        try await frontIPC.send(ObserverIPCMessage(kind: .start,
            authentication: RelayAuthentication(origin: origin, username: "fixture", cookies: []), interactive: false))
        _ = try await frontIPC.receive(timeout: 2)
        try input.fileHandleForWriting.close()
        try await task.value
        XCTAssertTrue(socket.isClosed); XCTAssertEqual(credentials.entries[key], token)
    }
    func testNativeWindowStatesRenderWithoutLayoutShift() throws {
        _ = NSApplication.shared
        let view = ObserverBindingWindow(name: "default", origin: origin)
        let url = try origin.bindingURL("/pair#token=" + String(repeating: "A", count: 43))
        try view.ready(pairingId: UUID(), url: url, expiresAt: Date().timeIntervalSince1970 + 300, show: false)
        let content = try XCTUnwrap(view.window.contentView)
        let frame = content.frame
        content.layoutSubtreeIfNeeded()
        view.expired(); content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.frame, frame); XCTAssertEqual(view.presentation.phase, .expired)
        if let destination = ProcessInfo.processInfo.environment["OBSERVER_WINDOW_SCREENSHOTS"] {
            view.window.appearance = NSAppearance(named: .aqua)
            content.wantsLayer = true
            view.window.appearance?.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let root = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for expired in [false, true] {
                try view.ready(pairingId: UUID(), url: url, expiresAt: Date().timeIntervalSince1970 + 300, show: false)
                if expired { view.expired() }
                content.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(expired ? "expired.png" : "waiting.png"))
            }
        }
        var refreshes = 0, cancellations = 0
        view.onRegenerate = { refreshes += 1 }; view.onCancel = { cancellations += 1 }
        func buttons(_ root: NSView) -> [NSButton] {
            root.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) }
        }
        view.expired()
        let button = try XCTUnwrap(buttons(content).first { $0.title == "重新生成" })
        button.performClick(nil); button.performClick(nil)
        XCTAssertEqual(refreshes, 1); XCTAssertEqual(view.presentation.phase, .generating)
        view.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: view.window))
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(view.presentation.phase, .closed)
        view.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: view.window))
        XCTAssertEqual(cancellations, 1)
    }
}
