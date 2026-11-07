import XCTest
import Foundation
@testable import TerminalMacCore

final class ObserverTests: XCTestCase {
    func image(_ grid: ObserverGrid, changes: [Int: UInt8] = [:], previous: ObserverPixels? = nil, candidates: Set<Int>? = nil) throws -> ObserverPixels {
        var pixels = Data(repeating: 255, count: grid.width * grid.height * 4)
        for (index, value) in changes {
            let rect = grid.rect(index)
            for y in rect.y..<(rect.y + rect.h) { for x in rect.x..<(rect.x + rect.w) { pixels[(y * grid.width + x) * 4] = value } }
        }
        return try ObserverPixels(grid: grid, rgba: pixels, previous: previous, candidates: candidates)
    }
    func testGridBoundsAndPartialTiles() throws {
        let grid = try ObserverGrid(width: 640, height: 400)
        XCTAssertEqual(grid.count, 20)
        XCTAssertEqual(grid.rect(19), ObserverRect(x: 512, y: 384, w: 128, h: 16))
        XCTAssertEqual(try grid.tiles(intersecting: ObserverRect(x: 127, y: 127, w: 2, h: 2)), [0, 1, 5, 6])
        XCTAssertThrowsError(try grid.tiles(intersecting: ObserverRect(x: Int.max, y: 0, w: 1, h: 1)))
        XCTAssertThrowsError(try ObserverGrid(width: Int.max, height: 2))
        XCTAssertThrowsError(try ObserverGrid(width: 1920, height: 2160))
    }
    func testSmallGridAndNativeTileRemapping() throws {
        let small = try ObserverGrid(width: 640, height: 400, tileSize: 64)
        XCTAssertEqual(small.count, 70)
        XCTAssertEqual(small.rect(69), ObserverRect(x: 576, y: 384, w: 64, h: 16))
        let native = try ObserverGrid(width: 640, height: 400)
        XCTAssertEqual(try small.tiles(intersecting: native.rect(0)), [0, 1, 10, 11])
        XCTAssertEqual(try small.tiles(intersecting: native.rect(19)), [68, 69])
        XCTAssertThrowsError(try ObserverGrid(width: 640, height: 400, tileSize: 96))
    }
    func testPacerUsesActualBytesAndDoesNotBankIdleCredit() {
        var pacer = ObserverPacer(maxFPS: 10, bytesPerSecond: 180_000)
        XCTAssertEqual(pacer.delay(at: 0), 0)
        pacer.sent(bytes: 360_000, at: 0)
        XCTAssertEqual(pacer.delay(at: 0.5), 1.5, accuracy: 0.0001)
        XCTAssertEqual(pacer.delay(at: 2), 0)
        pacer.sent(bytes: 1800, at: 100)
        XCTAssertEqual(pacer.delay(at: 100), 0.1, accuracy: 0.0001)
        pacer.sent(bytes: 90_000, at: 100.1)
        XCTAssertEqual(pacer.nextSend, 100.6, accuracy: 0.0001)
    }
    func testPacerLongRunBudgetIncludingLargeRefreshes() {
        var pacer = ObserverPacer(maxFPS: 10, bytesPerSecond: 180_000)
        var bytes = 0, now = 0.0
        for n in 0..<100 {
            now += pacer.delay(at: now)
            let size = n % 7 == 0 ? 360_000 : 15_000
            bytes += size; pacer.sent(bytes: size, at: now)
        }
        XCTAssertLessThanOrEqual(Double(bytes) / pacer.nextSend, 180_000.001)
    }
    func testChangingModePreservesPacerDebt() {
        var pacer = ObserverPacer(maxFPS: 10, bytesPerSecond: 180_000)
        pacer.sent(bytes: 360_000, at: 10)
        pacer.configure(maxFPS: 30, bytesPerSecond: nil)
        XCTAssertEqual(pacer.delay(at: 10), 2)
        pacer.configure(maxFPS: 10, bytesPerSecond: 180_000)
        XCTAssertEqual(pacer.delay(at: 11), 1)
    }
    func testDirtyHistoryAccumulatesSkippedFramesAndFallbacks() {
        var history = ObserverDirtyHistory()
        history.append(seq: 1, tiles: nil)
        history.append(seq: 2, tiles: [0]); history.append(seq: 3, tiles: [1]); history.append(seq: 4, tiles: [2])
        XCTAssertEqual(history.coverage(after: 1, through: 4), [0, 1, 2])
        XCTAssertNil(history.coverage(after: 0, through: 4))
        for seq in 5...140 { history.append(seq: UInt64(seq), tiles: []) }
        XCTAssertNil(history.coverage(after: 1, through: 140))
        XCTAssertEqual(history.coverage(after: 139, through: 140), [])
        history.append(seq: 142, tiles: [0])
        XCTAssertNil(history.coverage(after: 140, through: 142))
    }
    func testIdenticalCandidatePixelsDoNotChangeRevisions() throws {
        let grid = try ObserverGrid(width: 640, height: 400)
        let first = try image(grid)
        let second = try image(grid, previous: first, candidates: [0, 19])
        XCTAssertEqual(first.revisions, second.revisions)
        var client = ObserverClient()
        let full = try XCTUnwrap(client.reserve(first))
        try client.acknowledge(epoch: full.epoch, seq: full.seq)
        XCTAssertNil(try client.reserve(second))
    }
    func testAckDuringNewChangesAndIndependentClients() throws {
        let grid = try ObserverGrid(width: 640, height: 400)
        let a = try image(grid), b = try image(grid, changes: [0: 1], previous: a, candidates: [0])
        let c = try image(grid, changes: [0: 2, 19: 3], previous: b, candidates: [0, 19])
        var fast = ObserverClient(), slow = ObserverClient()
        let f = try XCTUnwrap(fast.reserve(a)), s = try XCTUnwrap(slow.reserve(a))
        try fast.acknowledge(epoch: f.epoch, seq: f.seq)
        let delta = try XCTUnwrap(fast.reserve(b))
        XCTAssertEqual(delta.tiles, [0]); XCTAssertNil(try fast.reserve(c))
        try fast.acknowledge(epoch: delta.epoch, seq: delta.seq)
        XCTAssertEqual(try fast.reserve(c)?.tiles, [0, 19])
        XCTAssertNil(try slow.reserve(c))
        try slow.acknowledge(epoch: s.epoch, seq: s.seq)
        XCTAssertEqual(try slow.reserve(c)?.tiles, [0, 19])
    }
    func testFutureDuplicateAndStaleAcks() throws {
        var client = ObserverClient()
        let full = try XCTUnwrap(client.reserve(image(ObserverGrid(width: 2, height: 2))))
        XCTAssertThrowsError(try client.acknowledge(epoch: full.epoch, seq: 2))
        try client.acknowledge(epoch: UUID().uuidString, seq: 1)
        XCTAssertNotNil(client.inFlight)
        try client.acknowledge(epoch: full.epoch, seq: 1)
        XCTAssertNoThrow(try client.acknowledge(epoch: full.epoch, seq: 1))
        client.reset()
        XCTAssertNotEqual(client.epoch, full.epoch)
        XCTAssertTrue(try XCTUnwrap(client.reserve(full.snapshot)).full)
    }
    func testReplayedDeltaOracleIncludingReturnToOriginal() throws {
        let grid = try ObserverGrid(width: 260, height: 130)
        var client = ObserverClient(), previous: ObserverPixels?, canvas = Data(count: grid.width * grid.height * 4)
        for n in 0..<100 {
            let changes: [Int: UInt8] = n % 3 == 0 ? [:] : [n % grid.count: UInt8(n)]
            let snapshot = try image(grid, changes: changes, previous: previous)
            if let batch = try client.reserve(snapshot) {
                for index in batch.tiles {
                    let rect = grid.rect(index)
                    for y in rect.y..<(rect.y + rect.h) {
                        let start = (y * grid.width + rect.x) * 4
                        canvas.replaceSubrange(start..<(start + rect.w * 4), with: snapshot.rgba[start..<(start + rect.w * 4)])
                    }
                }
                XCTAssertEqual(canvas, snapshot.rgba)
                try client.acknowledge(epoch: batch.epoch, seq: batch.seq)
            }
            previous = snapshot
        }
    }
}
