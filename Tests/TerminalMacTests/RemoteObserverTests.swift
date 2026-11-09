import XCTest
import Foundation
import Vision
import TerminalObserver
import TerminalMacCore
@testable import TerminalMac

final class MemoryDeviceCredentials: DeviceCredentialStore {
    var entries: [DeviceCredentialKey: DeviceToken] = [:]
    var saves = 0
    var fails = false
    func read(_ key: DeviceCredentialKey) throws -> DeviceToken? { entries[key] }
    func save(_ token: DeviceToken, for key: DeviceCredentialKey) throws {
        saves += 1
        if fails { throw RelayFailure("keychain_failed") }
        entries[key] = token
    }
    func remove(_ key: DeviceCredentialKey) { entries.removeValue(forKey: key) }
}

@MainActor
final class RemoteObserverTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-observer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func helper() throws -> AuthSession {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let python = try XCTUnwrap(paths.map { String($0) + "/python3" }.first { FileManager.default.isExecutableFile(atPath: $0) })
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "auth_fixture", withExtension: "py", subdirectory: "Fixtures"))
        return try AuthSession(python: URL(fileURLWithPath: python), helper: fixture)
    }
    func testConfigurationPreservesMachineAndObserverIdentity() throws {
        let directory = try temporary(), machine = directory.appendingPathComponent("machine.json")
        let original = Data("{\"existing\":true}".utf8)
        try original.write(to: machine)
        var first = try RemoteObserverConfiguration.load(directory: directory)
        first.lastServer = "https://example.net"; first.deviceId = UUID()
        try first.save(directory: directory)
        let second = try RemoteObserverConfiguration.load(directory: directory)
        XCTAssertEqual(first.observerId, second.observerId)
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(try Data(contentsOf: machine), original)
        XCTAssertFalse(String(decoding: try Data(contentsOf: directory.appendingPathComponent("remote-observer.json")), as: UTF8.self).contains("Token"))
    }
    func testConfigurationRejectsCorruptionAndSymlink() throws {
        let directory = try temporary(), file = directory.appendingPathComponent("remote-observer.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try RemoteObserverConfiguration.load(directory: directory))
        let target = directory.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try RemoteObserverConfiguration.load(directory: directory))
    }
    func testCredentialsAreStoredFirstReusedAndIsolated() throws {
        let id = UUID(), origin = try RelayOrigin("https://EXAMPLE.net:443/")
        let key = DeviceCredentialKey(origin: origin, username: "alice", observerId: id), store = MemoryDeviceCredentials()
        let (first, recovered) = try prepareDeviceCredential(key: key, store: store, interactive: true)
        XCTAssertFalse(recovered); XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(first.value.count, 43)
        XCTAssertFalse(first.description.contains(first.value))
        let (second, existing) = try prepareDeviceCredential(key: key, store: store, interactive: false)
        XCTAssertEqual(first, second); XCTAssertTrue(existing); XCTAssertEqual(store.saves, 1)
        let keys = [DeviceCredentialKey(origin: origin, username: "bob", observerId: id),
            DeviceCredentialKey(origin: try RelayOrigin("https://other.net"), username: "alice", observerId: id),
            DeviceCredentialKey(origin: origin, username: "alice", observerId: UUID())]
        XCTAssertEqual(Set(([key] + keys).map(\.account)).count, 4)
        for key in keys { XCTAssertThrowsError(try prepareDeviceCredential(key: key, store: store, interactive: false)) }
        store.fails = true
        XCTAssertThrowsError(try prepareDeviceCredential(key: keys[0], store: store, interactive: true))
        XCTAssertNil(store.entries[keys[0]])
        XCTAssertEqual(store.saves, 2)
    }
    func testTokenRejectsNoncanonicalAndWrongLength() throws {
        let token = try DeviceToken.generate()
        XCTAssertEqual(try DeviceToken(token.value), token)
        for raw in [token.value + "=", "bad", String(repeating: "+", count: 43), String(repeating: "_", count: 43)] {
            XCTAssertThrowsError(try DeviceToken(raw))
        }
    }
    func testHelperIPCAndIdentityValidation() async throws {
        let origin = try RelayOrigin("https://fixture.example")
        let auth = try await helper().authenticate(origin: origin, interactive: false)
        XCTAssertEqual(auth.username, "fixture-user"); XCTAssertEqual(auth.origin, origin)
        let bad: [String: Any] = ["version": 1, "ok": true, "origin": "https://other.example", "username": "alice", "relayVersion": 1, "cookies": []]
        XCTAssertThrowsError(try AuthSession.decode(JSONSerialization.data(withJSONObject: bad), origin: origin))
        XCTAssertThrowsError(try AuthSession.decode(Data("{\"version\":true,\"ok\":true}".utf8), origin: origin))
        let error = Data("{\"version\":1,\"ok\":false,\"error\":{\"code\":\"network_error\",\"retryable\":true}}".utf8)
        XCTAssertThrowsError(try AuthSession.decode(error, origin: origin)) { error in
            XCTAssertEqual((error as? RelayFailure)?.code, "network_error")
        }
    }
    func testOversizedHelperOutputIsRejected() async throws {
        do {
            _ = try await helper().authenticate(origin: RelayOrigin("https://oversized.example"), interactive: false)
            XCTFail("Accepted oversized helper output")
        } catch { XCTAssertEqual((error as? RelayFailure)?.code, "helper_protocol") }
    }
    func testHelperCancellationReapsProcess() async throws {
        let helper = try helper(), origin = try RelayOrigin("https://slow.example")
        let work = Task { try await helper.authenticate(origin: origin, interactive: false) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let began = Date(); work.cancel()
        do { _ = try await work.value; XCTFail("Cancellation did not stop helper") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 6)
    }
    func testServerSelectionAndRetryPolicy() throws {
        XCTAssertEqual(try CLI.selectObserverOrigin(server: "https://example.net", previous: nil, interactive: false).value, "https://example.net")
        XCTAssertEqual(try CLI.selectObserverOrigin(server: nil, previous: "https://example.net", interactive: false).value, "https://example.net")
        XCTAssertThrowsError(try CLI.selectObserverOrigin(server: nil, previous: nil, interactive: false))
        XCTAssertEqual((0...5).map { CLI.observerReconnectDelay(attempt: $0) }, [1, 2, 4, 8, 15, 15])
        for code in ["network_error", "server_unavailable", "device_busy"] { XCTAssertTrue(CLI.retryObserverFailure(RelayFailure(code))) }
        for code in ["binding_invalid", "protocol_error", "identity_mismatch", "watch_not_implemented"] {
            XCTAssertFalse(CLI.retryObserverFailure(RelayFailure(code, retryable: true)))
        }
    }
    func testRemovedObserveAndPortDoNotEnterAuthentication() async throws {
        for args in [["observe", "--port", "0"], ["connect", "--port", "0"]] {
            do { try await CLI().run(args); XCTFail("Removed entry was accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains(args[0] == "observe" ? "observe was removed" : "--port was removed")) }
        }
    }
    func testNativeQRCodeCanBeDecodedWithQuietZone() throws {
        let url = URL(string: "https://example.net/pair#token=" + String(repeating: "A", count: 43))!
        let image = try ObserverQRCode.image(url: url)
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        XCTAssertEqual(request.results?.first?.payloadStringValue, url.absoluteString)
    }
    func testPresentationExpiresWithoutRenewalAndDebouncesRegenerate() throws {
        var view = ObserverBindingPresentation()
        let url = URL(string: "https://example.net/pair#token=" + String(repeating: "A", count: 43))!
        view.ready(id: UUID(), url: url, expiresAt: 1000, now: 700, uptime: 10)
        XCTAssertEqual(view.remaining(uptime: 20), 290)
        view.tick(uptime: 309); XCTAssertEqual(view.phase, .waiting)
        view.tick(uptime: 310); XCTAssertEqual(view.phase, .expired); XCTAssertFalse(view.canOpenURL)
        XCTAssertTrue(view.regenerate()); XCTAssertFalse(view.regenerate()); XCTAssertFalse(view.canOpenURL)
        view.close(); view.ready(id: UUID(), url: url, expiresAt: 2000, now: 1000, uptime: 400)
        XCTAssertEqual(view.phase, .closed); XCTAssertNil(view.url)
    }
}
