import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import TerminalMacCore

/// A separate stream instance for the web observer. Never resizes the terminal's DesktopStream.
final class ObserverCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame { let buffer: CVPixelBuffer; let sequence: UInt64; let tiles: Set<Int>? }
    let epoch = UUID().uuidString
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "terminal-mac.observe.capture")
    private var latest: CVPixelBuffer?
    private var sequence: UInt64 = 0
    private var history = ObserverDirtyHistory()
    private var failure: Error?
    private var grid: ObserverGrid?
    @MainActor private var stream: SCStream?

    @MainActor func start(width: Int) async throws {
        try GuestGuard.requireVirtualMac()
        guard CGPreflightScreenCaptureAccess() else { throw Failure("Screen Recording is not allowed inside the VM") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw Failure("No Guest display is available")
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let nativeWidth = mode?.pixelWidth ?? display.width, nativeHeight = mode?.pixelHeight ?? display.height
        guard (2...16384).contains(nativeWidth), (2...16384).contains(nativeHeight) else { throw Failure("Invalid Guest display dimensions") }
        let wantedWidth = min(width, nativeWidth) & ~1
        let wantedHeight = max(2, Int(Double(nativeHeight) * Double(wantedWidth) / Double(nativeWidth)) & ~1)
        let grid = try ObserverGrid(width: wantedWidth, height: wantedHeight)
        lock.withLock { self.grid = grid }
        let config = SCStreamConfiguration()
        config.width = grid.width; config.height = grid.height
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true; config.queueDepth = 4
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }
    @MainActor func stop() async {
        let stream = self.stream; self.stream = nil
        lock.withLock { latest = nil; failure = Failure("Observer capture stopped") }
        try? await stream?.stopCapture()
    }
    func current(after: UInt64, epoch: String) throws -> Frame? {
        try lock.withLock {
            if let failure { throw failure }
            guard let buffer = latest, sequence != after || epoch != self.epoch else { return nil }
            return Frame(buffer: buffer, sequence: sequence,
                         tiles: epoch == self.epoch ? history.coverage(after: after, through: sequence) : nil)
        }
    }
    @MainActor func frame(after: UInt64, epoch: String, wait: Double) async throws -> Frame? {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            try Task.checkCancellation()
            if let frame = try current(after: after, epoch: epoch) { return frame }
            if Date() >= deadline { return nil }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle || status == .started { return }
        guard status == .complete, let buffer = sample.imageBuffer else {
            lock.withLock { latest = nil; failure = Failure("Guest capture status: \(status.rawValue)") }; return
        }
        lock.withLock {
            guard failure == nil, let grid, sequence < UInt64.max,
                  CVPixelBufferGetWidth(buffer) == grid.width, CVPixelBufferGetHeight(buffer) == grid.height else { return }
            let tiles = Self.dirtyTiles(info[.dirtyRects], grid: grid)
            sequence += 1; latest = buffer
            history.append(seq: sequence, tiles: sequence == 1 ? nil : tiles)
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.withLock { failure = error; latest = nil } }

    private static func dirtyTiles(_ value: Any?, grid: ObserverGrid) -> Set<Int>? {
        guard let values = value as? [Any], values.count <= 256 else { return nil }
        var tiles = Set<Int>()
        for value in values {
            let rect: CGRect
            if let value = value as? NSValue { rect = value.rectValue }
            else if let value = value as? CGRect { rect = value }
            else if let value = value as? NSDictionary, let decoded = CGRect(dictionaryRepresentation: value) { rect = decoded }
            else { return nil }
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.width >= 0, rect.height >= 0,
                  rect.minX >= 0, rect.minY >= 0, rect.maxX <= Double(grid.width), rect.maxY <= Double(grid.height) else { return nil }
            if rect.isEmpty { continue }
            let x = Int(floor(rect.minX)), y = Int(floor(rect.minY))
            let r = ObserverRect(x: x, y: y, w: min(grid.width, Int(ceil(rect.maxX))) - x,
                                 h: min(grid.height, Int(ceil(rect.maxY))) - y)
            guard let covered = try? grid.tiles(intersecting: r) else { return nil }
            tiles.formUnion(covered)
        }
        return tiles
    }
}
