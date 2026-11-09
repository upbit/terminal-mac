import Compression
import Foundation
import Darwin
import TerminalMacCore

public struct ObserverCaptureResult {
    public let epoch: String
    public let pixels: Data
    public let grid: ObserverGrid
    public let tiles: Set<Int>?
    public init(epoch: String, pixels: Data, grid: ObserverGrid, tiles: Set<Int>?) {
        self.epoch = epoch; self.pixels = pixels; self.grid = grid; self.tiles = tiles
    }
}

public protocol ObserverSource: Sendable {
    func configure(lowBandwidth: Bool, maxFPS: Int) async throws
    func next() async throws -> ObserverCaptureResult?
    func close() async
}

struct ObserverSourceFailure: Error { let code: String }

public actor GuestObserverSource: ObserverSource {
    private let directory: URL
    private let standardWidth: Int
    private var width: Int
    private var maxFPS: Int
    private let showsCursor: Bool
    private var mailbox: Mailbox?
    private var lease: String?, epoch = "", sequence: UInt64 = 0
    private var statusChecked = Date.distantPast
    private var nextPoll: Double = 0
    public init(directory: URL, width: Int = 640, maxFPS: Int = 30, showsCursor: Bool = true) {
        precondition((1...30).contains(maxFPS))
        self.directory = directory; self.standardWidth = width; self.width = width
        self.maxFPS = maxFPS; self.showsCursor = showsCursor
    }

    public func configure(lowBandwidth: Bool, maxFPS: Int) async throws {
        guard lease == nil, (1...30).contains(maxFPS) else { throw Failure("Observer must close before reconfiguration") }
        width = lowBandwidth ? min(480, standardWidth) : standardWidth
        self.maxFPS = maxFPS; nextPoll = 0
    }

    public func next() async throws -> ObserverCaptureResult? {
        do { return try await capture() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ObserverSourceFailure { throw error }
        catch {
            let code = error.localizedDescription == "Screen Recording is not allowed inside the VM" ? "permission_required" : "guest_unavailable"
            throw ObserverSourceFailure(code: code)
        }
    }
    private func capture() async throws -> ObserverCaptureResult? {
        let delay = nextPoll - ProcessInfo.processInfo.systemUptime
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ObserverSourceFailure(code: "vm_stopped") }
        let locked = flock(fd, LOCK_EX | LOCK_NB) != 0
        if !locked { flock(fd, LOCK_UN) }
        Darwin.close(fd)
        guard locked else { throw ObserverSourceFailure(code: "vm_stopped") }
        if Date().timeIntervalSince(statusChecked) >= 2 {
            let status = try await Mailbox(directory.appendingPathComponent("host-control")).call(Request(action: "status", timeout: 2))
            guard ["running", "stopping"].contains(status.values["state"] ?? "") else {
                throw ObserverSourceFailure(code: "vm_stopped")
            }
            statusChecked = Date()
        }
        if mailbox == nil { mailbox = try Mailbox(directory.appendingPathComponent("exchange")) }
        let mailbox = mailbox!
        if lease == nil {
            let capabilities = try await mailbox.call(Request(action: "observe.capabilities", timeout: 2))
            guard capabilities.values["observeVersion"] == "1" else { throw Failure("Upgrade the Guest helper: observer protocol v1 is required") }
            var arguments = ["width": String(width)]
            if maxFPS != 30 || !showsCursor {
                guard capabilities.values["captureOptions"] == "1" else {
                    throw Failure("Upgrade the Guest helper: observer rate/cursor options are required")
                }
                arguments["maxFps"] = String(maxFPS); arguments["cursor"] = showsCursor ? "show" : "hide"
            }
            // Once open is submitted, receive its lease even if the viewer closes meanwhile.
            // This bounded operation lets close() release it instead of waiting for Guest expiry.
            let openArguments = arguments
            let reply = try await Task.detached {
                try await mailbox.call(Request(action: "observe.open", arguments: openArguments, timeout: 5))
            }.value
            guard let lease = reply.values["lease"], UUID(uuidString: lease) != nil,
                  let epoch = reply.values["epoch"], UUID(uuidString: epoch) != nil else { throw Failure("Invalid observer open reply") }
            self.lease = lease; self.epoch = epoch; sequence = 0
            try Task.checkCancellation()
        }
        let lease = self.lease!
        let request = Request(action: "observe.poll", arguments: ["lease": lease, "epoch": epoch, "after": String(sequence), "wait": "1000"], timeout: 3)
        nextPoll = ProcessInfo.processInfo.systemUptime + 1 / Double(maxFPS)
        let filename = "observe-\(lease)-\(request.id.uuidString).bin"
        defer { mailbox.remove(filename) }
        let reply = try await mailbox.call(request).values
        guard reply["epoch"] == epoch else { throw Failure("Observer capture epoch changed") }
        if reply["unchanged"] == "true" { return nil }
        guard reply["image"] == filename, let width = Int(reply["width"] ?? ""), let height = Int(reply["height"] ?? ""),
              let stride = Int(reply["bytesPerRow"] ?? ""), let seq = UInt64(reply["sequence"] ?? ""), seq > sequence else {
            throw Failure("Invalid observer frame reply")
        }
        let grid = try ObserverGrid(width: width, height: height)
        guard (width * 4...width * 4 + 1024).contains(stride) else { throw Failure("Invalid observer row stride") }
        let candidates: Set<Int>?
        if reply["fullDirty"] == "true" { candidates = nil }
        else {
            guard let raw = reply["tiles"], raw.utf8.count <= 8192,
                  let list = try? JSONDecoder().decode([Int].self, from: Data(raw.utf8)), list.count <= grid.count,
                  Set(list).count == list.count, list.allSatisfy({ (0..<grid.count).contains($0) }) else {
                throw Failure("Invalid observer dirty tiles")
            }
            candidates = Set(list)
        }
        guard let compressed = try mailbox.read(filename, limit: ObserverLimits.maxMessageBytes) else { throw Failure("Observer pixels are missing") }
        let rgba = try await Task.detached {
            try Self.decodeBGRA(compressed, grid: grid, stride: stride)
        }.value
        sequence = seq
        return ObserverCaptureResult(epoch: epoch, pixels: rgba, grid: grid, tiles: candidates)
    }
    public func close() async {
        let lease = self.lease; self.lease = nil; sequence = 0; epoch = ""; statusChecked = .distantPast; nextPoll = 0
        if let lease, let mailbox {
            // Cleanup must reach the Guest even when the polling task was cancelled.
            await Task.detached {
                _ = try? await mailbox.call(Request(action: "observe.close", arguments: ["lease": lease], timeout: 2))
            }.value
        }
    }

    static func decodeBGRA(_ compressed: Data, grid: ObserverGrid, stride: Int) throws -> Data {
        guard !compressed.isEmpty, (grid.width * 4...grid.width * 4 + 1024).contains(stride) else { throw Failure("Invalid observer stride or empty pixels") }
        let expected = stride * grid.height
        // One extra output byte detects a stream that expands beyond the declared dimensions.
        var decoded = Data(count: expected + 1)
        try decoded.withUnsafeMutableBytes { dst in
            try compressed.withUnsafeBytes { src in
                var stream = compression_stream(dst_ptr: dst.bindMemory(to: UInt8.self).baseAddress!, dst_size: 0,
                                                src_ptr: src.bindMemory(to: UInt8.self).baseAddress!, src_size: 0, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4) != COMPRESSION_STATUS_ERROR else {
                    throw Failure("Cannot initialize observer LZ4 decoder")
                }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!; stream.src_size = src.count
                stream.dst_ptr = dst.bindMemory(to: UInt8.self).baseAddress!; stream.dst_size = dst.count
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_END, stream.src_size == 0, stream.dst_size == 1 else {
                    throw Failure("Observer LZ4 data is corrupt or exceeds its dimensions")
                }
            }
        }
        var rgba = Data(count: grid.width * grid.height * 4)
        rgba.withUnsafeMutableBytes { target in
            decoded.withUnsafeBytes { source in
                let dst = target.bindMemory(to: UInt8.self), src = source.bindMemory(to: UInt8.self)
                for y in 0..<grid.height {
                    for x in 0..<grid.width {
                        let s = y * stride + x * 4, d = (y * grid.width + x) * 4
                        dst[d] = src[s + 2]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s]; dst[d + 3] = 255
                    }
                }
            }
        }
        return rgba
    }
}
