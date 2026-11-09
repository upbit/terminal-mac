import Foundation
import Darwin
import TerminalObserver

struct ObserverIPCMessage: Codable, Sendable {
    enum Kind: String, Codable { case locked, start, binding, online, expired, failed, regenerate, cancel, detach, detached }
    let kind: Kind
    var authentication: RelayAuthentication?
    var observerId: UUID?
    var previousServer: String?
    var interactive: Bool?
    var pairingId: UUID?
    var bindPath: String?
    var expiresAt: Double?
    var deviceId: UUID?
    var generation: UUID?
    var hideCursor: Bool?
    var code: String?
}

/// One reader and serialized bounded writes over inherited anonymous pipes; no secret files.
final class ObserverIPC: @unchecked Sendable {
    private let input: FileHandle, output: FileHandle
    private let readLock = NSLock(), writeLock = NSLock()
    private var buffered = Data()
    static let maxBytes = 128 * 1024
    init(input: FileHandle, output: FileHandle) {
        self.input = input; self.output = output
        for fd in [input.fileDescriptor, output.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
    }
    func send(_ message: ObserverIPCMessage) async throws {
        let data = try JSONEncoder().encode(message) + Data([10])
        guard data.count <= Self.maxBytes else { throw RelayFailure("ipc_invalid") }
        try await Task.detached { [self] in
            try writeLock.withLock {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RelayFailure("ipc_timeout") }
                        let count = Darwin.write(output.fileDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
                        if count > 0 { offset += count }
                        else if count < 0 && [EINTR, EAGAIN].contains(errno) { usleep(10_000) }
                        else { throw RelayFailure("ipc_closed") }
                    }
                }
            }
        }.value
    }
    func receive(timeout: Double? = nil) async throws -> ObserverIPCMessage? {
        let task = Task.detached { [self] in
            try readLock.withLock { () -> ObserverIPCMessage? in
                let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    try Task.checkCancellation()
                    if let end = buffered.firstIndex(of: 10) {
                        let frame = buffered[..<end]; buffered.removeSubrange(...end)
                        guard let message = try? JSONDecoder().decode(ObserverIPCMessage.self, from: frame) else {
                            throw RelayFailure("ipc_invalid")
                        }
                        return message
                    }
                    if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw RelayFailure("ipc_timeout") }
                    let count = Darwin.read(input.fileDescriptor, &bytes, bytes.count)
                    if count > 0 {
                        guard buffered.count + count <= Self.maxBytes else { throw RelayFailure("ipc_invalid") }
                        buffered.append(contentsOf: bytes.prefix(count))
                    } else if count == 0 {
                        guard buffered.isEmpty else { throw RelayFailure("ipc_invalid") }
                        return nil
                    } else if [EINTR, EAGAIN].contains(errno) { usleep(10_000) }
                    else { throw RelayFailure("ipc_closed") }
                }
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
