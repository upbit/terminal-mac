import Foundation
import XCTest
import TerminalMacCore
@testable import TerminalObserver

actor EncodingGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0
    func waitOnce() async {
        calls += 1
        if calls == 1 && !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

final class RelayWatchTests: XCTestCase {
    let origin = try! RelayOrigin("https://fixture.example")
    func wait(_ predicate: () async -> Bool, timeout: Double = 3) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !(await predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure("Test condition timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func header(_ data: Data) throws -> [String: Any] {
        let length = data[8..<12].reduce(0) { $0 * 256 + Int($1) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data[12..<(12 + length)]) as? [String: Any])
    }
    func images(_ socket: FakeRelaySocket) -> [Data] { socket.frames.filter { $0.starts(with: Data("TMOB".utf8)) } }
    func send(_ socket: FakeRelaySocket, _ session: UUID, _ message: [String: Any]) throws {
        try socket.push(["type": "observer", "sessionId": session.uuidString, "message": message])
    }
    func start(_ socket: FakeRelaySocket, hub: ObserverHub, lifetime: RelayConnectionLifetime = RelayConnectionLifetime()) throws -> Task<Void, Error> {
        try socket.push(["type": "relay.hello", "relayVersion": 1, "connectionId": UUID().uuidString,
                         "state": "online", "deviceId": UUID().uuidString])
        return Task {
            try await ObserverRelay(hub: hub).run(socket: socket, origin: origin, observerId: UUID(), name: "Synthetic",
                deviceToken: String(repeating: "A", count: 43), recovering: true, interactive: false, lifetime: lifetime) { _ in }
        }
    }
    func open(_ socket: FakeRelaySocket, _ id: UUID) async throws {
        try socket.push(["type": "relay.watch.open", "sessionId": id.uuidString])
        try await wait { socket.output.contains { $0["type"] as? String == "relay.watch.ready" && $0["sessionId"] as? String == id.uuidString } }
    }
    func testFullDeltaACKAndCloseKeepDeviceOnline() async throws {
        let source = TestObserverSource(), socket = FakeRelaySocket(), lifetime = RelayConnectionLifetime()
        let task = try start(socket, hub: ObserverHub(source: source, configuration: .low, lowBandwidth: true), lifetime: lifetime)
        defer { task.cancel() }
        try await wait { lifetime.isOnline }
        let idleCalls = await source.calls; XCTAssertEqual(idleCalls, 0)
        let session = UUID(); try await open(socket, session)
        let preparedCalls = await source.calls; XCTAssertEqual(preparedCalls, 0)
        let grid = try ObserverGrid(width: 260, height: 130), captureEpoch = UUID().uuidString
        var pixels = Data(repeating: 255, count: grid.width * grid.height * 4)
        try send(socket, session, ["type": "subscribe", "v": 1])
        try await wait { await source.calls > 0 }
        await source.set(ObserverCaptureResult(epoch: captureEpoch, pixels: pixels, grid: grid, tiles: nil))
        try await wait { self.images(socket).count == 1 }
        let full = try header(images(socket)[0])
        XCTAssertEqual(full["type"] as? String, "full"); XCTAssertEqual(full["seq"] as? String, "1")
        pixels[0] = 1
        await source.set(ObserverCaptureResult(epoch: captureEpoch, pixels: pixels, grid: grid, tiles: [0]))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(images(socket).count, 1, "Capture must not advance the sent baseline before ACK")
        try send(socket, session, ["type": "ack", "epoch": full["epoch"]!, "seq": "1"])
        try await wait { self.images(socket).count == 2 }
        let delta = try header(images(socket)[1])
        XCTAssertEqual(delta["type"] as? String, "delta"); XCTAssertEqual(delta["baseSeq"] as? String, "1")
        try send(socket, session, ["type": "ack", "epoch": delta["epoch"]!, "seq": "2"])
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(images(socket).count, 2, "Static captures must not produce images")
        try socket.push(["type": "relay.watch.close", "sessionId": session.uuidString, "code": "viewer_closed"])
        try await wait { await source.closes > 0 }
        let calls = await source.calls
        try await Task.sleep(nanoseconds: 100_000_000)
        let stoppedCalls = await source.calls; XCTAssertEqual(calls, stoppedCalls)
        try socket.push(["type": "relay.ping", "nonce": "still-online"])
        try await wait { socket.output.contains { $0["type"] as? String == "relay.pong" } }
        XCTAssertTrue(lifetime.isOnline); XCTAssertFalse(socket.isClosed)
        XCTAssertFalse(socket.output.contains { ["ping", "error", "welcome"].contains($0["type"] as? String ?? "") })
        task.cancel(); _ = try? await task.value
        XCTAssertFalse(lifetime.isOnline)
    }
    func testACKDeadlineStartsAtWriterNotAtEncoding() async throws {
        let source = TestObserverSource(), socket = FakeRelaySocket(), gate = EncodingGate()
        let hub = ObserverHub(source: source, ackTimeout: 0.15, encode: { batch, policy in
            await gate.waitOnce(); return try ObserverPNG.batch(batch, policy: policy)
        })
        let task = try start(socket, hub: hub)
        let session = UUID(); try await open(socket, session)
        let grid = try ObserverGrid(width: 130, height: 66)
        await source.set(ObserverCaptureResult(epoch: UUID().uuidString, pixels: Data(repeating: 255, count: 130 * 66 * 4), grid: grid, tiles: nil))
        try send(socket, session, ["type": "subscribe", "v": 1])
        try await wait { await gate.calls == 1 }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(socket.output.contains { $0["type"] as? String == "relay.watch.close" })
        await gate.release()
        try await wait { self.images(socket).count == 1 }
        try await wait { socket.output.contains { $0["code"] as? String == "session_timeout" } }
        XCTAssertFalse(socket.isClosed)
        try await wait { await source.closes > 0 }
        task.cancel(); _ = try? await task.value
    }
    func testLateOldEncodingCannotCrossNewReadyBarrier() async throws {
        let source = TestObserverSource(), socket = FakeRelaySocket(), gate = EncodingGate()
        let hub = ObserverHub(source: source, encode: { batch, policy in
            await gate.waitOnce()
            // Deliberately ignore cancellation to model a late native encoder callback.
            return try await Task.detached { try ObserverPNG.batch(batch, policy: policy) }.value
        })
        let task = try start(socket, hub: hub), old = UUID(), new = UUID()
        let grid = try ObserverGrid(width: 130, height: 66)
        try await open(socket, old)
        await source.set(ObserverCaptureResult(epoch: UUID().uuidString, pixels: Data(repeating: 255, count: 130 * 66 * 4), grid: grid, tiles: nil))
        try send(socket, old, ["type": "subscribe", "v": 1]); try await wait { await gate.calls == 1 }
        let oldEpoch = socket.output.compactMap { ($0["message"] as? [String: Any])?["epoch"] as? String }.first
        try await open(socket, new)
        try await wait { await source.closes > 0 }
        await source.set(ObserverCaptureResult(epoch: UUID().uuidString, pixels: Data(repeating: 127, count: 130 * 66 * 4), grid: grid, tiles: nil))
        try send(socket, new, ["type": "subscribe", "v": 1])
        await gate.release()
        try await wait { self.images(socket).count == 1 }
        let full = try header(images(socket)[0])
        XCTAssertEqual(full["seq"] as? String, "1"); XCTAssertNotEqual(full["epoch"] as? String, oldEpoch)
        try socket.push(["type": "relay.watch.close", "sessionId": old.uuidString, "code": "viewer_closed"])
        try send(socket, old, ["type": "ack", "epoch": full["epoch"]!, "seq": "999"])
        try send(socket, new, ["type": "ack", "epoch": full["epoch"]!, "seq": "999"])
        try await wait { socket.output.contains { $0["type"] as? String == "relay.watch.close" && $0["sessionId"] as? String == new.uuidString } }
        XCTAssertFalse(socket.isClosed)
        task.cancel(); _ = try? await task.value
    }
    func testWriterOrdersReadyAfterInFlightImageAndRejectsLateOutput() async throws {
        let socket = FakeRelaySocket(), writer = RelayControlWriter(socket: socket), old = UUID(), new = UUID()
        try writer.beginWatch(old)
        try await wait { writer.isCurrent(old, ready: true) }
        let previous = writer.transport(old)
        let image = Data(repeating: 7, count: 1024)
        try await wait { writer.bufferedBytes == 0 }
        socket.blockSends()
        XCTAssertTrue(try previous.send(image, true))
        try await wait { socket.frames.contains(image) }
        try writer.beginWatch(new)
        XCTAssertFalse(try previous.send(image, true))
        XCTAssertFalse(socket.output.contains { $0["sessionId"] as? String == new.uuidString })
        XCTAssertEqual(writer.bufferedImages, 1, "In-flight image must remain in the budget")
        socket.releaseSends()
        try await wait { socket.output.contains { $0["sessionId"] as? String == new.uuidString } }
        let frames = socket.frames
        let newReady = try XCTUnwrap(frames.firstIndex { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["sessionId"] as? String == new.uuidString })
        XCTAssertFalse(frames.dropFirst(newReady + 1).contains(image))
        await writer.stop()
        let blocked = FakeRelaySocket(blocksSend: true), bounded = RelayControlWriter(socket: blocked)
        try bounded.beginWatch(old)
        try await wait { bounded.isCurrent(old, ready: true) }
        XCTAssertTrue(try bounded.transport(old).send(image, true))
        XCTAssertThrowsError(try bounded.transport(old).send(image, true))
        XCTAssertEqual(bounded.bufferedImages, 1)
        bounded.endWatch(old); XCTAssertEqual(bounded.bufferedImages, 0)
        blocked.releaseSends(); await bounded.stop()
    }
    func testModeResyncAndReadonlyControls() async throws {
        let source = TestObserverSource(), socket = FakeRelaySocket()
        let task = try start(socket, hub: ObserverHub(source: source, configuration: .low, lowBandwidth: true))
        let session = UUID(); try await open(socket, session)
        try send(socket, session, ["type": "subscribe", "v": 1])
        try await wait { await source.lowBandwidth }
        try send(socket, session, ["type": "mode", "lowBandwidth": false])
        try await wait { await source.maxFPS == 30 }
        try send(socket, session, ["type": "resync"])
        try send(socket, session, ["type": "pause"])
        do { try await task.value; XCTFail("Readonly violation accepted") }
        catch { XCTAssertEqual((error as? RelayFailure)?.code, "protocol_error") }
        XCTAssertTrue(socket.isClosed)
    }
    func testSubscribeTimeoutKeepsDeviceAndHeartbeatTimeoutStopsCapture() async throws {
        let source = TestObserverSource(), socket = FakeRelaySocket(), lifetime = RelayConnectionLifetime()
        try socket.push(["type": "relay.hello", "relayVersion": 1, "connectionId": UUID().uuidString,
                         "state": "online", "deviceId": UUID().uuidString])
        let relay = ObserverRelay(hub: ObserverHub(source: source), handshakeTimeout: 0.1, heartbeatTimeout: 0.7)
        let task = Task {
            try await relay.run(socket: socket, origin: origin, observerId: UUID(), name: "fixture",
                deviceToken: String(repeating: "A", count: 43), recovering: true, interactive: false, lifetime: lifetime) { _ in }
        }
        defer { task.cancel() }
        try await open(socket, UUID())
        try await wait { socket.output.contains { $0["code"] as? String == "session_timeout" } }
        XCTAssertTrue(lifetime.isOnline); XCTAssertFalse(socket.isClosed)
        let idle = await source.calls; XCTAssertEqual(idle, 0)
        let active = UUID(); try await open(socket, active)
        try send(socket, active, ["type": "subscribe", "v": 1])
        try await wait { await source.calls > 0 }
        do { try await task.value; XCTFail("Missing server heartbeat was ignored") }
        catch { XCTAssertEqual((error as? RelayFailure)?.code, "heartbeat_timeout") }
        XCTAssertFalse(lifetime.isOnline)
        let calls = await source.calls
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = await source.calls; XCTAssertEqual(after, calls)
    }
}
