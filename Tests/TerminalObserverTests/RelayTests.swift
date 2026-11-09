import XCTest
import Foundation
@testable import TerminalObserver

final class FakeRelaySocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [Data] = [], sent: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var senders: [CheckedContinuation<Void, Error>] = []
    private var closed = false
    private var blocksSend: Bool
    var closeCode: Int { 0 }
    init(blocksSend: Bool = false) { self.blocksSend = blocksSend }
    func push(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            if let waiter = receiver { receiver = nil; return waiter }
            incoming.append(data); return nil
        }
        waiter?.resume(returning: data)
    }
    func receiveText() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if closed { continuation.resume(throwing: RelayFailure("network_error")) }
                else if !incoming.isEmpty { continuation.resume(returning: incoming.removeFirst()) }
                else { receiver = continuation }
            }
        }
    }
    func sendText(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                if closed { continuation.resume(throwing: RelayFailure("network_error")); return }
                sent.append(data)
                if blocksSend { senders.append(continuation) }
                else { continuation.resume() }
            }
        }
    }
    func sendBinary(_ data: Data) async throws { try await sendText(data) }
    func close() {
        let waiters = lock.withLock { () -> (CheckedContinuation<Data, Error>?, [CheckedContinuation<Void, Error>]) in
            closed = true
            let waiters = (receiver, senders); receiver = nil; senders.removeAll(); return waiters
        }
        waiters.0?.resume(throwing: RelayFailure("network_error"))
        for waiter in waiters.1 { waiter.resume(throwing: RelayFailure("network_error")) }
    }
    func releaseSends() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            blocksSend = false; let result = senders; senders.removeAll(); return result
        }
        for waiter in waiters { waiter.resume() }
    }
    func blockSends() { lock.withLock { blocksSend = true } }
    var frames: [Data] { lock.withLock { sent } }
    var isClosed: Bool { lock.withLock { closed } }
    var output: [[String: Any]] { lock.withLock { sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } } }
}

actor RelayEvents {
    var values: [RelayEvent] = []
    func add(_ event: RelayEvent) { values.append(event) }
}

final class RelayTests: XCTestCase {
    let origin = try! RelayOrigin("https://example.net")
    let token = String(repeating: "A", count: 43)
    func hello(_ state: String, connection: UUID, device: UUID? = nil) -> [String: Any] {
        ["type": "relay.hello", "relayVersion": 1, "connectionId": connection.uuidString, "state": state,
         "deviceId": device.map { $0.uuidString as Any } ?? NSNull()]
    }
    func run(_ socket: FakeRelaySocket, recovering: Bool = false, events: RelayEvents = RelayEvents()) async throws {
        try await ObserverRelay().run(socket: socket, origin: origin, observerId: UUID(), name: "fixture", deviceToken: token,
            recovering: recovering, interactive: true) { await events.add($0) }
    }
    func testOriginAndBindingPathRejectCredentialLeaks() throws {
        XCTAssertEqual(try RelayOrigin("HTTPS://EXAMPLE.net:443/").value, origin.value)
        for value in ["http://example.net", "https://u:p@example.net", "https://example.net/path", "https://example.net?",
            "https://example.net#", "https://example.net:0", "https://example.net.", " https://example.net", "https://example.net/%2f"] {
            XCTAssertThrowsError(try RelayOrigin(value), value)
        }
        XCTAssertEqual(try origin.bindingURL("/pair#token=" + token).host, "example.net")
        for path in ["https://evil.net/pair#token=" + token, "//evil.net/pair", "/pair?token=" + token,
            "/pair#token=" + token + "&extra=x", "/watch/id", "/pair#token=short"] {
            XCTAssertThrowsError(try origin.bindingURL(path), path)
        }
    }
    func testCookieHeaderHonorsHostOnlyPathSecureAndExpiry() throws {
        let cookies = [
            RelayCookie(name: "root", value: "a", domain: "example.net", path: "/", secure: true, expires: -1),
            RelayCookie(name: "api", value: "b", domain: ".example.net", path: "/api", secure: true, expires: -1),
            RelayCookie(name: "dead", value: "c", domain: "example.net", path: "/", secure: true, expires: 1),
            RelayCookie(name: "passport", value: "d", domain: "passport.example.net", path: "/", secure: true, expires: -1)]
        let auth = try RelayAuthentication(origin: origin, username: "alice", cookies: cookies)
        XCTAssertEqual(try auth.cookieHeader(for: origin.deviceURL), "root=a")
        XCTAssertEqual(try auth.cookieHeader(for: origin.url(path: "/api/observer/identity")), "api=b; root=a")
        XCTAssertFalse(cookies[0].applies(to: URL(string: "https://sub.example.net/")!))
        XCTAssertFalse(cookies[0].applies(to: URL(string: "http://example.net/")!))
        XCTAssertFalse(cookies[1].applies(to: origin.url(path: "/apix")))
        XCTAssertThrowsError(try auth.cookieHeader(for: URL(string: "https://other.net/")!))
        XCTAssertThrowsError(try RelayAuthentication(origin: origin, username: "alice", cookies: [RelayCookie(
            name: "bad", value: "value\r\nInjected: secret", domain: "example.net", path: "/", secure: true, expires: -1)]))
    }
    func testBindingConfirmationAndHeartbeatHaveNoImageOrReady() async throws {
        let socket = FakeRelaySocket(), events = RelayEvents(), connection = UUID(), device = UUID()
        try socket.push(hello("unbound", connection: connection))
        try socket.push(["type": "device.bind.ready", "pairingId": UUID().uuidString, "bindPath": "/pair#token=" + token,
                         "expiresAt": Int(Date().timeIntervalSince1970) + 300])
        try socket.push(["type": "relay.ping", "nonce": "fixture-ping"])
        try socket.push(hello("online", connection: connection, device: device))
        let task = Task { try await run(socket, events: events) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let values = await events.values
        XCTAssertEqual(values.count, 2)
        if case .online(let id) = values.last { XCTAssertEqual(id, device) } else { XCTFail("Missing confirmed hello") }
        XCTAssertEqual(socket.output.compactMap { $0["type"] as? String }, ["device.bind.begin", "relay.pong"])
        XCTAssertEqual(socket.output.first?["deviceToken"] as? String, token)
        task.cancel()
        do { try await task.value; XCTFail("Did not cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testBoundAndPendingRecoveryDoNotSubmitAnotherBegin() async throws {
        for state in ["online", "binding"] {
            let socket = FakeRelaySocket(), events = RelayEvents()
            try socket.push(hello(state, connection: UUID(), device: state == "online" ? UUID() : nil))
            if state == "binding" {
                try socket.push(["type": "device.bind.ready", "pairingId": UUID().uuidString, "bindPath": "/pair#token=" + token,
                                 "expiresAt": Int(Date().timeIntervalSince1970) + 300])
            }
            let task = Task { try await run(socket, recovering: true, events: events) }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(socket.output.isEmpty)
            let count = await events.values.count; XCTAssertEqual(count, 1)
            task.cancel(); _ = try? await task.value
        }
    }
    func testWrongStateUnknownFieldsAndWatchAreRejected() async throws {
        let cases: [([String: Any], Bool, String)] = [
            (hello("online", connection: UUID(), device: UUID()), false, "protocol_error"),
            (hello("unbound", connection: UUID()), true, "protocol_error"),
            (["type": "relay.watch.open", "sessionId": UUID().uuidString], false, "protocol_error"),
            (["type": "device.bind.ready", "pairingId": UUID().uuidString, "bindPath": "/pair#token=" + token,
              "expiresAt": Int(Date().timeIntervalSince1970) + 300], false, "protocol_error"),
            (["type": "click", "x": 1, "y": 2], false, "protocol_error"),
            (["type": "relay.ping", "nonce": "x", "extra": true], false, "protocol_error")]
        for (message, recovering, code) in cases {
            let socket = FakeRelaySocket(); try socket.push(message)
            do { try await run(socket, recovering: recovering); XCTFail("Accepted illegal message") }
            catch { XCTAssertEqual((error as? RelayFailure)?.code, code) }
        }
        let socket = FakeRelaySocket()
        try socket.push(hello("online", connection: UUID(), device: UUID()))
        try socket.push(["type": "relay.watch.open", "sessionId": UUID().uuidString])
        do { try await run(socket, recovering: true); XCTFail("Pretended to support P2") }
        catch { XCTAssertEqual((error as? RelayFailure)?.code, "protocol_error") }
        XCTAssertTrue(socket.output.isEmpty)
    }
    func testControlQueueAndSendTimeoutAreBounded() async throws {
        let socket = FakeRelaySocket(blocksSend: true), writer = RelayControlWriter(socket: socket)
        do {
            for _ in 0..<20 { try writer.enqueue(["type": "fixture", "padding": String(repeating: "x", count: 6000)]) }
            XCTFail("Control queue was unbounded")
        } catch { XCTAssertEqual((error as? RelayFailure)?.code, "slow_consumer") }
        await writer.stop()
        let bytes = writer.bufferedBytes; XCTAssertEqual(bytes, 0)
        let timeoutSocket = FakeRelaySocket(blocksSend: true)
        let timedWriter = RelayControlWriter(socket: timeoutSocket, sendTimeout: 50_000_000)
        try timedWriter.enqueue(["type": "fixture"])
        try await Task.sleep(nanoseconds: 100_000_000)
        let failure = timedWriter.failure; XCTAssertEqual(failure?.code, "send_timeout")
        await timedWriter.stop()
    }
    func testOnlyAuthoritativeBindingInvalidIsClassifiedForDeletion() throws {
        let expired = Data("{\"error\":{\"code\":\"binding_invalid\",\"retryable\":false}}".utf8)
        XCTAssertThrowsError(try RelaySessionDiagnosis.decode(expired, status: 410, mime: "application/json")) {
            XCTAssertEqual(($0 as? RelayFailure)?.code, "binding_invalid")
        }
        for status in [403, 500] {
            XCTAssertThrowsError(try RelaySessionDiagnosis.decode(expired, status: status, mime: "application/json")) {
                XCTAssertNotEqual(($0 as? RelayFailure)?.code, "binding_invalid")
            }
        }
        let html = Data("<html>not an identity</html>".utf8)
        XCTAssertThrowsError(try RelaySessionDiagnosis.decode(html, status: 200, mime: "text/html")) {
            XCTAssertEqual(($0 as? RelayFailure)?.code, "auth_required")
        }
        let bound = try JSONSerialization.data(withJSONObject: ["state": "bound", "deviceId": UUID().uuidString, "relayVersion": 1])
        XCTAssertEqual(try RelaySessionDiagnosis.decode(bound, status: 200, mime: "application/json"), .bound)
    }
    func testCancellationResponseRequiresExactRequestAndPreservesConfirmed() throws {
        let id = UUID(), device = UUID()
        func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let cancelled = try body(["state": "cancelled", "pairingId": id.uuidString])
        XCTAssertEqual(try RelayPairingCancellation.decode(cancelled, status: 200, mime: "application/json", pairingId: id), .cancelled)
        let confirmed = try body(["state": "confirmed", "pairingId": id.uuidString, "deviceId": device.uuidString])
        XCTAssertEqual(try RelayPairingCancellation.decode(confirmed, status: 200, mime: "application/json", pairingId: id), .confirmed(device))
        XCTAssertThrowsError(try RelayPairingCancellation.decode(cancelled, status: 200, mime: "application/json", pairingId: UUID()))
        for mime in ["application/json-invalid", "application/jsonp", "text/html"] {
            XCTAssertThrowsError(try RelayPairingCancellation.decode(cancelled, status: 200, mime: mime, pairingId: id))
        }
        let utf16 = String(decoding: cancelled, as: UTF8.self).data(using: .utf16)!
        XCTAssertThrowsError(try RelayPairingCancellation.decode(utf16, status: 200, mime: "application/json", pairingId: id))
        XCTAssertThrowsError(try RelayPairingCancellation.decode(cancelled, status: 404, mime: "application/json", pairingId: id)) {
            XCTAssertEqual(($0 as? RelayFailure)?.code, "cancellation_unsupported")
        }
    }
    func testDuplicateOnlineHelloIsIdempotentAndChangedDeviceIsRejected() async throws {
        let socket = FakeRelaySocket(), events = RelayEvents(), connection = UUID(), device = UUID()
        try socket.push(hello("online", connection: connection, device: device))
        try socket.push(hello("online", connection: connection, device: device))
        try socket.push(hello("online", connection: connection, device: UUID()))
        do { try await run(socket, recovering: true, events: events); XCTFail("Changed device was accepted") }
        catch { XCTAssertEqual((error as? RelayFailure)?.code, "protocol_error") }
        let values = await events.values
        XCTAssertEqual(values.count, 1)
    }
}
