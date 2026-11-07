// Run from the repo root on macOS with a writable module cache and output directory.
// See PHONE_OBSERVER.md for the complete command.
// Synthetic fixtures only. No screen capture, network access, or private data.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum BenchmarkError: Error { case graphics, encoding }

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "/tmp/terminal-mac-codec-benchmark", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ width: Int, _ height: Int) throws -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue) else { throw BenchmarkError.graphics }
    return result
}

func color(_ rgb: UInt32) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [CGFloat((rgb >> 16) & 255) / 255,
        CGFloat((rgb >> 8) & 255) / 255, CGFloat(rgb & 255) / 255, 1])!
}

func fill(_ context: CGContext, _ rect: CGRect, _ rgb: UInt32) {
    context.setFillColor(color(rgb)); context.fill(rect)
}

func text(_ context: CGContext, _ value: String, _ x: CGFloat, _ y: CGFloat,
          size: CGFloat = 18, rgb: UInt32 = 0xd8dee9, mono: Bool = true) {
    let font = CTFontCreateWithName((mono ? "Menlo" : "Helvetica") as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(rgb)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}

func fixture(_ name: String) throws -> CGImage {
    let c = try context(1600, 1000)
    switch name {
    case "terminal":
        fill(c, CGRect(x: 0, y: 0, width: 1600, height: 1000), 0x191c20)
        fill(c, CGRect(x: 0, y: 948, width: 1600, height: 52), 0x30343a)
        text(c, "terminal-mac / synthetic build log", 24, 966, size: 20)
        let messages = [
            "compile Sources/Observer/FrameStore.swift",
            "test    delta preserves changes across skipped source frames",
            "test    reconnect requires a complete refresh before patches",
            "status  worker=ready pending=0 revisions=42",
            "build   debug executable complete; no failures"
        ]
        for row in 0..<32 {
            let prefix = String(format: "12:%02d:%02d", row / 2, row % 60)
            text(c, prefix, 24, CGFloat(915 - row * 27), rgb: 0x929aa5)
            text(c, messages[row % messages.count], 140, CGFloat(915 - row * 27),
                 rgb: row % 5 == 3 ? 0x77d49c : 0xd8dee9)
        }
        text(c, "$ waiting for changes _", 24, 30, rgb: 0x77d49c)
    case "dashboard":
        fill(c, CGRect(x: 0, y: 0, width: 1600, height: 1000), 0xf4f5f7)
        fill(c, CGRect(x: 0, y: 0, width: 230, height: 1000), 0x272b32)
        text(c, "Observer", 24, 944, size: 28, rgb: 0xffffff, mono: false)
        for (index, title) in ["Overview", "Machines", "Jobs", "History"].enumerated() {
            text(c, title, 24, CGFloat(860 - index * 58), size: 20, mono: false)
        }
        text(c, "Machine activity", 266, 943, size: 28, rgb: 0x242830, mono: false)
        for row in 0..<18 {
            let y = CGFloat(847 - row * 43)
            fill(c, CGRect(x: 260, y: y - 12, width: 1310, height: 42), row % 2 == 0 ? 0xffffff : 0xebeef2)
            text(c, String(format: "job-%04d", 1000 + row), 278, y, rgb: 0x343943)
            text(c, row % 3 == 0 ? "running" : "complete", 494, y, rgb: 0x147a56)
            text(c, "guest-default", 710, y, rgb: 0x343943)
            text(c, "capture / verify / publish", 1010, y, rgb: 0x343943)
        }
    default:
        // High-entropy image-like control, not a photograph or a desktop workload.
        let bytes = c.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 0x12345678
        for y in 0..<1000 {
            for x in 0..<1600 {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let noise = Int(seed & 63) - 32
                let offset = (y * 1600 + x) * 4
                bytes[offset] = UInt8(clamping: 40 + x * 170 / 1600 + noise)
                bytes[offset + 1] = UInt8(clamping: 50 + y * 150 / 1000 + noise)
                bytes[offset + 2] = UInt8(clamping: 100 + (x + y) * 90 / 2600 + noise)
                bytes[offset + 3] = 255
            }
        }
        fill(c, CGRect(x: 0, y: 948, width: 1600, height: 52), 0x30343a)
        text(c, "Synthetic high-entropy image control (not a photograph)", 24, 966)
    }
    guard let result = c.makeImage() else { throw BenchmarkError.graphics }
    return result
}

func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    if image.width == width && image.height == height { return image }
    let c = try context(width, height)
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = c.makeImage() else { throw BenchmarkError.graphics }
    return result
}

func encode(_ image: CGImage, jpegQuality: Double?) throws -> Data {
    let data = NSMutableData()
    let type = jpegQuality == nil ? UTType.png.identifier : UTType.jpeg.identifier
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
        else { throw BenchmarkError.encoding }
    let properties: CFDictionary? = jpegQuality.map {
        [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
    }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { throw BenchmarkError.encoding }
    return data as Data
}

print("fixture,resolution,region,png_bytes,jpeg_q75_bytes,jpeg_q90_bytes")
for name in ["terminal", "dashboard", "image-control"] {
    let source = try fixture(name)
    for (width, height) in [(640, 400), (1600, 1000)] {
        let image = try resized(source, width: width, height: height)
        let crop = CGRect(x: (width / 2 / 128) * 128, y: (height / 2 / 128) * 128,
                          width: 128, height: 128)
        guard let tile = image.cropping(to: crop) else { throw BenchmarkError.graphics }
        for (region, sample) in [("full", image), ("tile-128", tile)] {
            var sizes: [Int] = []
            for (codec, quality) in [("png", nil as Double?), ("jpeg-q75", 0.75), ("jpeg-q90", 0.9)] {
                let data = try encode(sample, jpegQuality: quality)
                sizes.append(data.count)
                let ext = quality == nil ? "png" : "jpg"
                try data.write(to: output.appendingPathComponent("\(name)-\(width)x\(height)-\(region)-\(codec).\(ext)"))
            }
            print("\(name),\(width)x\(height),\(region),\(sizes.map(String.init).joined(separator: ","))")
        }
    }
}
