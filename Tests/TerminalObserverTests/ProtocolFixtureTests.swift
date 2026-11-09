import CryptoKit
import Foundation
import XCTest
import TerminalMacCore
@testable import TerminalObserver

final class ProtocolFixtureTests: XCTestCase {
    static func pixels(updated: Bool) -> Data {
        var result = Data()
        for y in 0..<66 { for x in 0..<130 {
            var color: [UInt8] = x < 64 ? [26, 105, 87, 255] : x < 128 ? [39, 122, 180, 255] : [205, 66, 73, 255]
            if updated && ((x < 64 && y < 64) || (x >= 128 && y >= 64)) { color = [235, 184, 52, 255] }
            result.append(contentsOf: color)
        } }
        return result
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func testSharedManifestAndSwiftEncoding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let output = ProcessInfo.processInfo.environment["OBSERVER_FIXTURE_OUTPUT"] {
            try generate(at: URL(fileURLWithPath: output), root: root)
            return
        }
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "protocol-v1", withExtension: nil, subdirectory: "Fixtures"))
        for directory in [fixtures, fixtures.appendingPathComponent("swift")] {
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any])
            XCTAssertEqual(manifest["relayVersion"] as? Int, 1); XCTAssertEqual(manifest["tmobVersion"] as? Int, 1)
            let files = try XCTUnwrap(manifest["files"] as? [String: String])
            for (name, expected) in files { XCTAssertEqual(Self.digest(try Data(contentsOf: directory.appendingPathComponent(name))), expected, name) }
            if let sources = manifest["producerSources"] as? [String: String] {
                for (name, expected) in sources { XCTAssertEqual(Self.digest(try Data(contentsOf: root.appendingPathComponent(name))), expected, name) }
            }
        }
    }
    private func generate(at directory: URL, root: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let grid = try ObserverGrid(width: 130, height: 66, tileSize: 64)
        let before = try ObserverPixels(grid: grid, rgba: Self.pixels(updated: false), previous: nil, candidates: nil)
        let after = try ObserverPixels(grid: grid, rgba: Self.pixels(updated: true), previous: before, candidates: [0, 5])
        var client = ObserverClient(), oracleClient = ObserverClient()
        let first = try XCTUnwrap(client.reserve(before))
        let full = try ObserverPNG.batch(first)
        try client.acknowledge(epoch: first.epoch, seq: first.seq)
        let delta = try ObserverPNG.batch(XCTUnwrap(client.reserve(after)), policy: .threshold(100))
        let oracle = try ObserverPNG.batch(XCTUnwrap(oracleClient.reserve(after)))
        var corrupt = full; corrupt[corrupt.count - 1] ^= 1
        let controls: [String: Any] = ["welcome": ["type": "welcome", "v": 1, "epoch": first.epoch,
            "width": 130, "height": 66, "tileSize": 64, "codec": "png", "maxFps": 10, "bytesPerSecond": 180000]]
        let files = ["full.tmob": full, "delta.tmob": delta, "oracle.tmob": oracle, "corrupt.tmob": corrupt,
                     "controls.json": try JSONSerialization.data(withJSONObject: controls, options: [.prettyPrinted, .sortedKeys])]
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        let sources = ["Sources/TerminalObserver/ObserverPNG.swift", "Sources/TerminalMacCore/Observer.swift",
                       "Tests/TerminalObserverTests/ProtocolFixtureTests.swift"]
        let hashes = try Dictionary(uniqueKeysWithValues: sources.map { ($0, Self.digest(try Data(contentsOf: root.appendingPathComponent($0)))) })
        let manifest: [String: Any] = ["relayVersion": 1, "tmobVersion": 1, "producer": "terminal-mac/ObserverPNG",
            "producerSources": hashes, "files": files.mapValues(Self.digest)]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
    }
}
