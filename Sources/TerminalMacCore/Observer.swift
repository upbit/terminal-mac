import Foundation

public enum ObserverLimits {
    public static let tileSize = 128
    public static let maxPixels = 2_073_600
    public static let maxMessageBytes = 12 * 1024 * 1024
    public static let maxControlBytes = 8192
    public static let maxConnections = 8
}

public struct ObserverRect: Codable, Equatable {
    public let x: Int, y: Int, w: Int, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct ObserverGrid: Equatable {
    public let width: Int, height: Int
    public var columns: Int { (width + 127) / 128 }
    public var rows: Int { (height + 127) / 128 }
    public var count: Int { columns * rows }
    public var all: Set<Int> { Set(0..<count) }
    public init(width: Int, height: Int) throws {
        guard (2...1920).contains(width), (2...2160).contains(height),
              width * height <= ObserverLimits.maxPixels else { throw Failure("Invalid observer image dimensions") }
        self.width = width; self.height = height
    }
    public func rect(_ index: Int) -> ObserverRect {
        let x = (index % columns) * 128, y = (index / columns) * 128
        return ObserverRect(x: x, y: y, w: min(128, width - x), h: min(128, height - y))
    }
    public func tiles(intersecting rect: ObserverRect) throws -> Set<Int> {
        guard rect.x >= 0, rect.y >= 0, rect.w > 0, rect.h > 0,
              rect.x < width, rect.y < height, rect.w <= width - rect.x, rect.h <= height - rect.y else {
            throw Failure("Invalid observer dirty rectangle")
        }
        var result = Set<Int>()
        for row in (rect.y / 128)...((rect.y + rect.h - 1) / 128) {
            for column in (rect.x / 128)...((rect.x + rect.w - 1) / 128) { result.insert(row * columns + column) }
        }
        return result
    }
}

/// Metadata only: frames may be discarded, but their dirty coverage must survive until polled.
public struct ObserverDirtyHistory {
    private struct Entry { let seq: UInt64; let tiles: Set<Int>? }
    private var entries: [Entry] = []
    public init() {}
    public mutating func append(seq: UInt64, tiles: Set<Int>?) {
        entries.append(Entry(seq: seq, tiles: tiles))
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
    }
    public func coverage(after: UInt64, through: UInt64) -> Set<Int>? {
        guard after <= through, through < UInt64.max else { return nil }
        if after == through { return [] }
        guard let first = entries.first, first.seq > 0, after >= first.seq - 1,
              entries.last?.seq == through else { return nil }
        var result = Set<Int>(), expected = after + 1
        for entry in entries where entry.seq > after && entry.seq <= through {
            guard entry.seq == expected, let tiles = entry.tiles else { return nil }
            result.formUnion(tiles); expected += 1
        }
        return expected == through + 1 ? result : nil
    }
}

public struct ObserverPixels {
    public let grid: ObserverGrid
    public let rgba: Data
    public let revisions: [UInt64]
    public init(grid: ObserverGrid, rgba: Data, previous: ObserverPixels?, candidates: Set<Int>?) throws {
        guard rgba.count == grid.width * grid.height * 4,
              candidates?.allSatisfy({ (0..<grid.count).contains($0) }) != false else {
            throw Failure("Invalid observer pixels or tiles")
        }
        self.grid = grid; self.rgba = rgba
        guard let previous, previous.grid == grid else {
            revisions = Array(repeating: 1, count: grid.count); return
        }
        var revisions = previous.revisions
        try rgba.withUnsafeBytes { current in
            try previous.rgba.withUnsafeBytes { old in
                for index in candidates ?? grid.all {
                    let rect = grid.rect(index)
                    let changed = (rect.y..<(rect.y + rect.h)).contains { row in
                        let start = (row * grid.width + rect.x) * 4
                        return memcmp(current.baseAddress!.advanced(by: start), old.baseAddress!.advanced(by: start), rect.w * 4) != 0
                    }
                    if changed {
                        guard revisions[index] < UInt64.max else { throw Failure("Observer revision overflow; restart capture") }
                        revisions[index] += 1
                    }
                }
            }
        }
        self.revisions = revisions
    }
    public func crop(_ rect: ObserverRect) -> Data {
        var data = Data(capacity: rect.w * rect.h * 4)
        for y in rect.y..<(rect.y + rect.h) {
            let offset = (y * grid.width + rect.x) * 4
            data.append(rgba[offset..<(offset + rect.w * 4)])
        }
        return data
    }
}

public struct ObserverBatch {
    public let epoch: String, seq: UInt64, baseSeq: UInt64?
    public let snapshot: ObserverPixels
    public let tiles: [Int]
    public var full: Bool { baseSeq == nil }
}

/// One reserved/encoding/sent batch per connection. ACK merges only that batch's revisions.
public struct ObserverClient {
    public private(set) var epoch = UUID().uuidString
    public private(set) var lastAck: UInt64 = 0
    public private(set) var inFlight: ObserverBatch?
    private var acked: [UInt64] = []
    public init() {}
    public mutating func reset() { self = ObserverClient() }
    public mutating func reserve(_ snapshot: ObserverPixels) throws -> ObserverBatch? {
        guard inFlight == nil else { return nil }
        guard lastAck < UInt64.max else { throw Failure("Observer sequence overflow") }
        let full = lastAck == 0 || acked.count != snapshot.grid.count
        let tiles = full ? Array(0..<snapshot.grid.count) : snapshot.revisions.indices.filter { snapshot.revisions[$0] != acked[$0] }
        guard !tiles.isEmpty else { return nil }
        let batch = ObserverBatch(epoch: epoch, seq: lastAck + 1, baseSeq: full ? nil : lastAck, snapshot: snapshot, tiles: tiles)
        inFlight = batch; return batch
    }
    public mutating func acknowledge(epoch: String, seq: UInt64) throws {
        guard epoch == self.epoch else { return }
        if seq == lastAck && lastAck > 0 { return }
        guard let batch = inFlight, batch.seq == seq else { throw Failure("ACK does not match the in-flight batch") }
        if batch.full { acked = batch.snapshot.revisions }
        else { for tile in batch.tiles { acked[tile] = batch.snapshot.revisions[tile] } }
        lastAck = seq; inFlight = nil
    }
}

public struct ObserverBlock: Codable {
    public let x: Int, y: Int, w: Int, h: Int, offset: Int, length: Int
    public init(rect: ObserverRect, offset: Int, length: Int) {
        x = rect.x; y = rect.y; w = rect.w; h = rect.h; self.offset = offset; self.length = length
    }
}

public struct ObserverHeader: Encodable {
    public let type: String, epoch: String, seq: String
    public let baseSeq: String?
    public let width: Int, height: Int
    public let codec = "png"
    public let blocks: [ObserverBlock]
    public init(batch: ObserverBatch, full: Bool, blocks: [ObserverBlock]) {
        type = full ? "full" : "delta"; epoch = batch.epoch; seq = String(batch.seq)
        baseSeq = full ? nil : batch.baseSeq.map(String.init)
        width = batch.snapshot.grid.width; height = batch.snapshot.grid.height; self.blocks = blocks
    }
    public func encode(payload: Data) throws -> Data {
        let header = try JSONEncoder().encode(self)
        guard header.count <= 65536, header.count + payload.count + 12 <= ObserverLimits.maxMessageBytes else {
            throw Failure("Observer batch exceeds message limit")
        }
        var data = Data([0x54, 0x4d, 0x4f, 0x42, 0, 1, 0, 0])
        var length = UInt32(header.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(header); data.append(payload); return data
    }
}
