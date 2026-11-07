import XCTest
import Foundation
import TerminalMacCore
@testable import TerminalObserver

/// Opt-in capture/replay. Raw Guest pixels and encoded messages stay in the chosen local directory.
final class ObserverBenchmarkTests: XCTestCase {
    struct Frame: Codable { let time: Double; let file: String }
    struct Recording: Codable { let width: Int; let height: Int; let duration: Double; let frames: [Frame] }
    struct Measurement: Codable {
        let file: String, type: String
        let time: Double, encodeMS: Double
        let bytes: Int, blocks: Int
    }
    struct Run: Codable {
        let name: String, tileSize: Int, maxFPS: Int, budget: Int
        let duration: Double, steadyKBps: Double, totalBytes: Int, firstBytes: Int
        let messages: [Measurement]
    }
    func testRecordGuest() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["OBSERVER_RECORD_OUTPUT"], let directory = env["OBSERVER_LIVE_DIRECTORY"] else {
            throw XCTSkip("Set OBSERVER_RECORD_OUTPUT and OBSERVER_LIVE_DIRECTORY for authorized Guest recording")
        }
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try FileLock(URL(fileURLWithPath: directory).appendingPathComponent("observer.lock"))
        let source = GuestObserverSource(directory: URL(fileURLWithPath: directory),
                                        maxFPS: Int(env["OBSERVER_CAPTURE_FPS"] ?? "30") ?? 30,
                                        showsCursor: env["OBSERVER_HIDE_CURSOR"] != "1")
        let duration = min(60, max(2, Double(env["OBSERVER_RECORD_SECONDS"] ?? "12") ?? 12))
        let start = ProcessInfo.processInfo.systemUptime
        var frames: [Frame] = [], grid: ObserverGrid?
        do {
            while ProcessInfo.processInfo.systemUptime - start < duration {
                guard let frame = try await source.next() else { continue }
                let time = ProcessInfo.processInfo.systemUptime - start, file = "frame-\(frames.count).rgba"
                if let grid { XCTAssertEqual(grid, frame.grid) }
                grid = frame.grid
                try frame.pixels.write(to: root.appendingPathComponent(file))
                frames.append(Frame(time: time, file: file))
            }
            await source.close()
        } catch { await source.close(); throw error }
        let size = try XCTUnwrap(grid)
        let recording = Recording(width: size.width, height: size.height,
                                  duration: ProcessInfo.processInfo.systemUptime - start, frames: frames)
        try JSONEncoder().encode(recording).write(to: root.appendingPathComponent("recording.json"))
        print("RECORDED \(frames.count) Guest frames / \(recording.duration)s: \(root.path)")
        withExtendedLifetime(lock) {}
    }
    func testReplayEncodingMatrix() throws {
        guard let path = ProcessInfo.processInfo.environment["OBSERVER_REPLAY_DIRECTORY"] else {
            throw XCTSkip("Set OBSERVER_REPLAY_DIRECTORY to benchmark a recorded Guest sequence")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: root.appendingPathComponent("recording.json")))
        let frames = try recording.frames.map { ($0.time, try Data(contentsOf: root.appendingPathComponent($0.file))) }
        guard let first = frames.first else { return XCTFail("Recording is empty") }
        let origin = first.0, duration = max(0.001, recording.duration - origin)
        let policies: [(String, ObserverPNGPolicy)] = [("t25", .threshold(25)), ("t40", .threshold(40)),
            ("t60", .threshold(60)), ("t80", .threshold(80)), ("adaptive", .adaptive)]
        var runs: [Run] = []
        for tileSize in [128, 64] {
            let grid = try ObserverGrid(width: recording.width, height: recording.height, tileSize: tileSize)
            // Scan the SAME full pixels once per grid; native dirty metadata is not an A/B variable.
            var snapshots: [(Double, ObserverPixels)] = [], previous: ObserverPixels?
            for (time, pixels) in frames {
                let snapshot = try ObserverPixels(grid: grid, rgba: pixels, previous: previous, candidates: nil)
                snapshots.append((time - origin, snapshot)); previous = snapshot
            }
            for (label, policy) in policies {
                for low in [false, true] {
                    let name = "\(tileSize)-\(label)-\(low ? "low" : "standard")"
                    let output = root.appendingPathComponent(name, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    var client = ObserverClient(), pacer = ObserverPacer(maxFPS: low ? 10 : 30, bytesPerSecond: low ? 180_000 : nil)
                    var measurements: [Measurement] = []
                    func send(_ snapshot: ObserverPixels, at time: Double) throws {
                        guard let batch = try client.reserve(snapshot) else { return }
                        let began = ProcessInfo.processInfo.systemUptime
                        let data = try ObserverPNG.batch(batch, policy: policy)
                        let ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
                        let headerSize = data[8..<12].reduce(0) { $0 * 256 + Int($1) }
                        let header = try JSONSerialization.jsonObject(with: data[12..<(12 + headerSize)]) as! [String: Any]
                        let file = "\(name)/\(measurements.count).tmob"
                        try data.write(to: root.appendingPathComponent(file))
                        measurements.append(Measurement(file: file, type: header["type"] as! String, time: time,
                                                        encodeMS: ms, bytes: data.count, blocks: (header["blocks"] as! [Any]).count))
                        pacer.sent(bytes: data.count, at: time)
                        try client.acknowledge(epoch: batch.epoch, seq: batch.seq)
                    }
                    // Timer events flush the latest available snapshot even without another capture.
                    var latest: ObserverPixels?
                    for (time, snapshot) in snapshots {
                        if let latest, pacer.nextSend < time, pacer.nextSend > 0 {
                            try send(latest, at: pacer.nextSend)
                        }
                        latest = snapshot
                        if pacer.delay(at: time) == 0 { try send(snapshot, at: time) }
                    }
                    if let latest { try send(latest, at: max(duration, pacer.nextSend)) }
                    let firstBytes = measurements.first?.bytes ?? 0, total = measurements.reduce(0) { $0 + $1.bytes }
                    let steady = measurements.dropFirst().filter { $0.time <= duration }.reduce(0) { $0 + $1.bytes }
                    runs.append(Run(name: name, tileSize: tileSize, maxFPS: low ? 10 : 30, budget: low ? 180_000 : 0,
                                    duration: duration, steadyKBps: Double(steady) / duration / 1000,
                                    totalBytes: total, firstBytes: firstBytes, messages: measurements))
                    print("REPLAY \(name): \(String(format: "%.1f", Double(steady) / duration / 1000)) KB/s, \(measurements.count) batches")
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runs).write(to: root.appendingPathComponent("encoding-results.json"))
    }
}
