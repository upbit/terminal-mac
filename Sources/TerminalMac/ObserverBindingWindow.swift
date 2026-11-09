import AppKit
import CoreImage
import TerminalObserver

struct ObserverBindingPresentation {
    enum Phase: Equatable { case waiting, expired, generating, failed, closed }
    private(set) var phase: Phase = .generating
    private(set) var pairingId: UUID?
    private(set) var url: URL?
    private(set) var deadline: Double?
    mutating func ready(id: UUID, url: URL, expiresAt: Double, now: Double = Date().timeIntervalSince1970,
                        uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard phase != .closed else { return }
        pairingId = id; self.url = url
        deadline = uptime + min(300, max(0, expiresAt - now))
        phase = expiresAt > now ? .waiting : .expired
    }
    mutating func tick(uptime: Double = ProcessInfo.processInfo.systemUptime) {
        if phase == .waiting, let deadline, uptime >= deadline { phase = .expired }
    }
    mutating func expire() { if phase != .closed { phase = .expired } }
    mutating func regenerate() -> Bool {
        guard phase == .expired || phase == .failed else { return false }
        phase = .generating; return true
    }
    mutating func fail() { if phase != .closed { phase = .failed } }
    mutating func close() { phase = .closed; url = nil; pairingId = nil; deadline = nil }
    var canOpenURL: Bool { phase == .waiting }
    func remaining(uptime: Double = ProcessInfo.processInfo.systemUptime) -> Int {
        max(0, Int(ceil((deadline ?? uptime) - uptime)))
    }
}

enum ObserverQRCode {
    static func image(url: URL, scale: Int = 6) throws -> CGImage {
        guard (1...12).contains(scale), let filter = CIFilter(name: "CIQRCodeGenerator") else { throw RelayFailure("qr_failed") }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let source = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent) else {
            throw RelayFailure("qr_failed")
        }
        let side = (source.width + 8) * scale
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RelayFailure("qr_failed") }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: 4 * scale, y: 4 * scale, width: source.width * scale, height: source.height * scale))
        guard let image = context.makeImage() else { throw RelayFailure("qr_failed") }
        return image
    }
}

@MainActor
final class ObserverBindingWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let imageView = NSImageView(), overlay = NSView(), status = NSTextField(labelWithString: "")
    private let refresh = NSButton(), link = NSButton(), spinner = NSProgressIndicator()
    private var timer: Timer?
    private(set) var presentation = ObserverBindingPresentation()
    var onRegenerate: (() -> Void)?, onCancel: (() -> Void)?

    init(name: String, origin: RelayOrigin) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "terminal-mac"; window.isReleasedWhenClosed = false; window.delegate = self
        let content = NSView(); window.contentView = content
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle; title.toolTip = name
        let server = NSTextField(labelWithString: origin.value)
        server.font = .systemFont(ofSize: 12); server.textColor = .secondaryLabelColor
        server.alignment = .center; server.lineBreakMode = .byTruncatingMiddle; server.toolTip = origin.value
        let qrArea = NSView(); qrArea.wantsLayer = true; qrArea.layer?.backgroundColor = NSColor.white.cgColor
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityLabel("设备绑定二维码")
        overlay.wantsLayer = true; overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        refresh.title = "重新生成"; refresh.bezelStyle = .rounded
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageLeading; refresh.target = self; refresh.action = #selector(regenerate)
        spinner.style = .spinning; spinner.controlSize = .regular; spinner.isDisplayedWhenStopped = false
        status.alignment = .center; status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        status.maximumNumberOfLines = 2
        link.title = "在浏览器中确认"; link.isBordered = false; link.contentTintColor = .linkColor
        link.target = self; link.action = #selector(openConfirmation)
        for view in [title, server, qrArea, status, link] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [imageView, overlay] { qrArea.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [refresh, spinner] { overlay.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            server.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), server.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            server.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            qrArea.widthAnchor.constraint(equalToConstant: 306), qrArea.heightAnchor.constraint(equalToConstant: 306),
            qrArea.centerXAnchor.constraint(equalTo: content.centerXAnchor), qrArea.topAnchor.constraint(equalTo: server.bottomAnchor, constant: 18),
            imageView.leadingAnchor.constraint(equalTo: qrArea.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: qrArea.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: qrArea.topAnchor), imageView.bottomAnchor.constraint(equalTo: qrArea.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: qrArea.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: qrArea.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: qrArea.topAnchor), overlay.bottomAnchor.constraint(equalTo: qrArea.bottomAnchor),
            refresh.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), refresh.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            status.topAnchor.constraint(equalTo: qrArea.bottomAnchor, constant: 12), status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: title.trailingAnchor), status.heightAnchor.constraint(equalToConstant: 34),
            link.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6), link.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        ])
        render()
    }
    func ready(pairingId: UUID, url: URL, expiresAt: Double, show: Bool = true) throws {
        guard presentation.phase != .closed else { return }
        let raw = try ObserverQRCode.image(url: url, scale: 1)
        let scale = max(1, min(6, 306 / raw.width))
        let image = try ObserverQRCode.image(url: url, scale: scale)
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        presentation.ready(id: pairingId, url: url, expiresAt: expiresAt); render()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        if show { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    func tick() { presentation.tick(); render() }
    func expired() { presentation.expire(); render() }
    func failed(_ code: String) {
        presentation.fail(); render()
        status.stringValue = code == "cancellation_unsupported" ? "服务暂不支持取消旧请求" : "连接失败，请重试"
    }
    @objc private func regenerate() {
        guard presentation.regenerate() else { return }
        render(); onRegenerate?()
    }
    @objc private func openConfirmation() {
        guard presentation.canOpenURL, let url = presentation.url else { return }
        NSWorkspace.shared.open(url)
    }
    private func render() {
        let phase = presentation.phase
        overlay.isHidden = phase == .waiting || phase == .closed
        refresh.isHidden = phase != .expired && phase != .failed
        refresh.isEnabled = !refresh.isHidden
        link.isEnabled = presentation.canOpenURL
        link.contentTintColor = presentation.canOpenURL ? .linkColor : .disabledControlTextColor
        if phase == .generating { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        switch phase {
        case .waiting:
            let remaining = presentation.remaining()
            status.stringValue = String(format: "有效期剩余 %02d:%02d", remaining / 60, remaining % 60)
        case .expired: status.stringValue = "二维码已过期"
        case .generating: status.stringValue = "正在获取二维码"
        case .failed: status.stringValue = "连接失败，请重试"
        case .closed: status.stringValue = ""
        }
    }
    func finish() {
        presentation.close(); timer?.invalidate(); timer = nil
        imageView.image = nil; window.orderOut(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard presentation.phase != .closed else { return }
        finish(); onCancel?()
    }
}
