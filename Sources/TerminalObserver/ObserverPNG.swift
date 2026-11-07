import CoreGraphics
import Foundation
import ImageIO
import TerminalMacCore
import UniformTypeIdentifiers

enum ObserverPNG {
    static func encode(_ pixels: Data, width: Int, height: Int) throws -> Data {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure("Cannot construct observer PNG")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("Cannot initialize PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot encode observer PNG") }
        return data as Data
    }
    static func batch(_ batch: ObserverBatch, policy: ObserverPNGPolicy = .threshold(40)) throws -> Data {
        try Task.checkCancellation()
        let grid = batch.snapshot.grid
        let area = batch.tiles.reduce(0) { let r = grid.rect($1); return $0 + r.w * r.h }
        let fullRect = ObserverRect(x: 0, y: 0, w: grid.width, h: grid.height)
        if batch.full || batch.tiles.count == grid.count || batch.tiles.count > 256 {
            return try encodeBatch(batch, rects: [fullRect], full: true)
        }
        switch policy {
        case .threshold(let percent):
            let full = area * 100 >= grid.width * grid.height * percent || batch.tiles.count >= 64
            return try encodeBatch(batch, rects: full ? [fullRect] : batch.tiles.map(grid.rect), full: full)
        case .adaptive:
            // Below this crossover region, avoid a second (full image) encode.
            guard area * 100 >= grid.width * grid.height * 40 || batch.tiles.count >= 32 else {
                return try encodeBatch(batch, rects: batch.tiles.map(grid.rect), full: false)
            }
            let full = try encodeBatch(batch, rects: [fullRect], full: true)
            return try encodeBatch(batch, rects: batch.tiles.map(grid.rect), full: false, smallerThan: full)
        }
    }
    private static func encodeBatch(_ batch: ObserverBatch, rects: [ObserverRect], full: Bool,
                                    smallerThan alternative: Data? = nil) throws -> Data {
        var payload = Data(), blocks: [ObserverBlock] = []
        for rect in rects {
            try Task.checkCancellation()
            let png = try autoreleasepool { try encode(batch.snapshot.crop(rect), width: rect.w, height: rect.h) }
            blocks.append(ObserverBlock(rect: rect, offset: payload.count, length: png.count)); payload.append(png)
            if let alternative, payload.count >= alternative.count { return alternative }
        }
        let data = try ObserverHeader(batch: batch, full: full, blocks: blocks).encode(payload: payload)
        if let alternative, alternative.count <= data.count { return alternative }
        return data
    }
}
