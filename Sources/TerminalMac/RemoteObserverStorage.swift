import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Darwin
import TerminalObserver

struct RemoteObserverConfiguration: Codable {
    let version: Int
    let observerId: UUID
    var lastServer: String?
    var deviceId: UUID?

    static func load(directory: URL) throws -> RemoteObserverConfiguration {
        let url = directory.appendingPathComponent("remote-observer.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT else { throw RelayFailure("configuration_invalid") }
            let config = RemoteObserverConfiguration(version: 1, observerId: UUID())
            try config.save(directory: directory); return config
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= 8192,
              let data = try handle.read(upToCount: 8193), data.count <= 8192,
              let config = try? JSONDecoder().decode(Self.self, from: data), config.version == 1 else {
            throw RelayFailure("configuration_invalid")
        }
        if let origin = config.lastServer { _ = try RelayOrigin(origin) }
        return config
    }
    func save(directory: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: directory.appendingPathComponent("remote-observer.json"), options: .atomic)
    }
}

struct DeviceCredentialKey: Hashable {
    let origin: String, username: String, observerId: UUID
    init(origin: RelayOrigin, username: String, observerId: UUID) {
        self.origin = origin.value; self.username = username; self.observerId = observerId
    }
    var account: String {
        SHA256.hash(data: Data("\(origin)\0\(username)\0\(observerId.uuidString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct DeviceToken: Equatable, CustomStringConvertible {
    let value: String
    var description: String { "<device credential>" }
    init(_ value: String) throws {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard value.utf8.count == 43, let data = Data(base64Encoded: base64 + "="), data.count == 32,
              Self.encode(data) == value else { throw RelayFailure("keychain_failed") }
        self.value = value
    }
    static func generate() throws -> DeviceToken {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RelayFailure("keychain_failed") }
        return try DeviceToken(encode(Data(bytes)))
    }
    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

protocol DeviceCredentialStore {
    func read(_ key: DeviceCredentialKey) throws -> DeviceToken?
    func save(_ token: DeviceToken, for key: DeviceCredentialKey) throws
    func remove(_ key: DeviceCredentialKey) throws
}

struct KeychainDeviceCredentialStore: DeviceCredentialStore {
    let interactive: Bool
    private func query(_ key: DeviceCredentialKey) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.terminal-mac.remote-observer.device.v1", kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: false]
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            result[kSecUseAuthenticationContext as String] = context
        }
        return result
    }
    func read(_ key: DeviceCredentialKey) throws -> DeviceToken? {
        var query = query(key); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw RelayFailure("keychain_failed")
        }
        return try DeviceToken(value)
    }
    func save(_ token: DeviceToken, for key: DeviceCredentialKey) throws {
        let query = query(key), values = [kSecValueData as String: Data(token.value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RelayFailure("keychain_failed") }
    }
    func remove(_ key: DeviceCredentialKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayFailure("keychain_failed") }
    }
}

func prepareDeviceCredential(key: DeviceCredentialKey, store: any DeviceCredentialStore, interactive: Bool) throws -> (DeviceToken, Bool) {
    if let token = try store.read(key) { return (token, true) }
    guard interactive else { throw RelayFailure("binding_required") }
    let token = try DeviceToken.generate()
    try store.save(token, for: key)
    return (token, false)
}
