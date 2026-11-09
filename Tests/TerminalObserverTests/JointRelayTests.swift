import Foundation
import XCTest
import TerminalMacCore
@testable import TerminalObserver

// Test-only plaintext loopback transport. Production origins and TLS validation are unchanged.
private final class JointSocket: RelaySocket, @unchecked Sendable {
    let session = URLSession(configuration: .ephemeral)
    let task: URLSessionWebSocketTask
    init(port: Int, owner: String, key: String) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws/observer/device")!)
        request.setValue(owner, forHTTPHeaderField: "x-username")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request); task.maximumMessageSize = 8192; task.resume()
    }
    func sendText(_ data: Data) async throws { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
    func sendBinary(_ data: Data) async throws { try await task.send(.data(data)) }
    func receiveText() async throws -> Data {
        guard case .string(let text) = try await task.receive() else { throw RelayFailure("protocol_error") }
        return Data(text.utf8)
    }
    var closeCode: Int { task.closeCode.rawValue }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

private actor JointSource: ObserverSource {
    var low = true, version = 0, calls = 0, closes = 0
    var epoch = UUID().uuidString
    func configure(lowBandwidth: Bool, maxFPS: Int) {
        low = lowBandwidth; version = 0; calls = 0; epoch = UUID().uuidString
    }
    func next() async throws -> ObserverCaptureResult? {
        try await Task.sleep(nanoseconds: 30_000_000)
        calls += 1
        guard calls == 1 || calls == 6 else { return nil }
        version = calls == 1 ? 0 : 1
        let width = low ? 480 : 640, height = low ? 300 : 400
        let grid = try ObserverGrid(width: width, height: height)
        var pixels = Data(repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            pixels[index] = version == 1 && x < 16 && y < 16 ? 10 : 40
            pixels[index + 1] = 120; pixels[index + 2] = 180
        } }
        return ObserverCaptureResult(epoch: epoch, pixels: pixels, grid: grid, tiles: version == 0 ? nil : [0])
    }
    func close() { closes += 1 }
}

final class JointRelayTests: XCTestCase {
    func testLocalSyntheticRelay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["OBSERVER_TEST_PORT"], let port = Int(raw), (1...65535).contains(port),
              let owner = env["OBSERVER_TEST_OWNER"], let key = env["OBSERVER_TEST_KEY"] else {
            throw XCTSkip("Run the server's opt-in local synthetic joint test; no Guest or SSO is used")
        }
        let source = JointSource(), socket = JointSocket(port: port, owner: owner, key: key)
        let work = Task {
            try await ObserverRelay(source: source).run(socket: socket, origin: RelayOrigin("https://joint.invalid"),
                observerId: UUID(), name: "Joint synthetic", deviceToken: key, recovering: true, interactive: false) { _ in }
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); if !Task.isCancelled { work.cancel() } }
        defer { timeout.cancel(); socket.close() }
        do { try await work.value; XCTFail("Expected explicit test revocation") }
        catch { XCTAssertEqual((error as? RelayFailure)?.code, "binding_invalid") }
        let closes = await source.closes
        XCTAssertGreaterThanOrEqual(closes, 3, "Hidden/mode change/revocation must release capture")
    }
}
