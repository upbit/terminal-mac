import AppKit
import Darwin
import TerminalMacCore
import TerminalUI

@MainActor
final class TerminalViewer {
    static var supportsCurrentTerminal: Bool {
        let env = ProcessInfo.processInfo.environment
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && env["TMUX"] == nil &&
            (env["TERM_PROGRAM"] == "iTerm.app" || env["TERM_PROGRAM"] == "ghostty" || env["KITTY_WINDOW_ID"] != nil || env["TERM"]?.contains("kitty") == true)
    }
    /// `login`: nobody reads the mailbox, so the guest has no logged-in session (or no helper) yet.
    /// `permissions`: the helper runs but macOS has not allowed it to capture the screen yet.
    private enum Link: Equatable { case connecting, live, snapshots, login, permissions, waiting(String) }
    private struct Layout: Equatable {
        let desktop: DesktopPlacement
        let border: Bool
        let columns: Int, rows: Int
    }
    private struct Activity { let at: Date; let text: String; let ok: Bool; let milliseconds: Double? }
    private struct Shortcut { let key: Character; let label: String; let chord: String; let glyph: String }
    /// Mac shortcuts the terminal cannot send itself, because it keeps ⌘ for its own menus.
    private static let shortcuts: [Shortcut] = [
        Shortcut(key: "s", label: "Spotlight", chord: "cmd+space", glyph: "⌘␣"), Shortcut(key: "t", label: "Previous app", chord: "cmd+tab", glyph: "⌘⇥"),
        Shortcut(key: "m", label: "Mission Control", chord: "ctrl+up", glyph: "⌃↑"), Shortcut(key: "d", label: "Show desktop", chord: "f11", glyph: "F11"),
        Shortcut(key: "n", label: "New window", chord: "cmd+n", glyph: "⌘N"), Shortcut(key: "w", label: "Close window", chord: "cmd+w", glyph: "⌘W"),
        Shortcut(key: "q", label: "Quit app", chord: "cmd+q", glyph: "⌘Q"), Shortcut(key: "f", label: "Find", chord: "cmd+f", glyph: "⌘F"),
        Shortcut(key: "c", label: "Copy", chord: "cmd+c", glyph: "⌘C"), Shortcut(key: "v", label: "Paste", chord: "cmd+v", glyph: "⌘V"),
        Shortcut(key: "x", label: "Cut", chord: "cmd+x", glyph: "⌘X"), Shortcut(key: "a", label: "Select all", chord: "cmd+a", glyph: "⌘A"),
        Shortcut(key: "z", label: "Undo", chord: "cmd+z", glyph: "⌘Z"), Shortcut(key: ",", label: "Settings", chord: "cmd+,", glyph: "⌘,")
    ]

    let mailbox: Mailbox
    /// Lifecycle control for the VM process, used to show its native window for logging in.
    let host: Mailbox
    let directory: URL
    let machine: Machine
    let graphics: String
    let readOnly: Bool
    private let writer = TerminalWriter()
    private let renderer: DesktopRenderer
    private var metrics = TerminalMetricFilter()
    private var layout: Layout?
    private var hit: ImageLayout?
    /// The guest display in points: input coordinates, and the aspect ratio to lay out.
    private var points: (width: Int, height: Int)
    private var failure: Error?
    private var quit = false, link = Link.connecting, palette = false
    private var queue: [Request] = [], labels: [UUID: String] = [:], inFlight = false
    private var anchor: (x: Int, y: Int, at: Date)?, lastClick: (x: Int, y: Int, at: Date, count: Int)?
    private var wheel = (dx: 0, dy: 0, x: 0, y: 0, at: Date.distantPast)
    private var activity: [Activity] = []
    private var previousChrome = ""
    private var fps = 0.0, fpsSample = (frames: 0, at: Date())
    /// The native window was opened from the viewer; it is hidden again once the guest connects.
    private var loginWindow = false
    /// The helper's privacy permissions, from its status reply. Input needs Accessibility even while frames flow.
    private var grants: (screen: Bool, input: Bool)?
    private var grantsCheckedAt = Date.distantPast
    private var inputBlocked: Bool { grants?.input == false }
    private var firstFrameShown = false

    /// Set once a guest helper has answered, so later runs of `up` can skip the native setup window.
    static func readyMarker(_ directory: URL) -> URL { directory.appendingPathComponent("guest-ready") }

    init(directory: URL, machine: Machine, graphics: String?, readOnly: Bool) throws {
        mailbox = try Mailbox(directory.appendingPathComponent("exchange"))
        host = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
        self.directory = directory; self.machine = machine; self.readOnly = readOnly
        points = (machine.width, machine.height)
        let env = ProcessInfo.processInfo.environment
        let detected = env["TERM_PROGRAM"] == "iTerm.app" ? "iterm" :
            (env["KITTY_WINDOW_ID"] != nil || env["TERM"]?.contains("kitty") == true || env["TERM_PROGRAM"] == "ghostty") ? "kitty" : nil
        guard let selected = graphics ?? detected, ["kitty", "iterm"].contains(selected) else {
            throw Failure("Use Ghostty, Kitty or iTerm2 for inline graphics, or choose --protocol kitty|iterm. Use 'show' for a native window in other terminals. tmux passthrough is not implemented.")
        }
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { throw Failure("view needs an interactive terminal") }
        if env["TMUX"] != nil { throw Failure("Run view outside tmux for now; graphics passthrough is not implemented") }
        self.graphics = selected
        // Kitty-protocol terminals start on PNG until they confirm shared memory support.
        renderer = DesktopRenderer(writer: writer, transport: selected == "iterm" ? .iterm : .kittyDirect)
    }

    func run() async throws {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw Failure("Cannot read terminal settings") }
        var raw = original; cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { throw Failure("Cannot enter terminal input mode") }
        let signals = [SIGINT, SIGTERM, SIGHUP]
        let oldHandlers = signals.map { Darwin.signal($0, SIG_IGN) }
        let sources = signals.map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit = true }
            source.resume(); return source
        }
        writer.write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[2J" + (readOnly ? "" : "\u{1b}[?1002h\u{1b}[?1006h"))
        queryMetrics()
        var probe = graphics == "kitty" ? DesktopRenderer.sharedMemoryProbe() : nil
        if let probe { writer.write(probe.query) }
        var transportDecided = probe == nil
        defer {
            renderer.configure(placement: nil)
            probe?.cleanup()
            writer.write(renderer.clear() + "\u{1b}[0m\u{1b}[2J\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?25h\u{1b}[?1049l")
            writer.flush()
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            for (index, source) in sources.enumerated() { source.cancel(); Darwin.signal(signals[index], oldHandlers[index]) }
        }
        var frames: Task<Void, Never>?
        defer { frames?.cancel() }
        var parser = TerminalInput(), lastInput = Date(), previousSize = "", lastChrome = Date.distantPast
        let started = Date()
        while !quit {
            var size = winsize(); _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
            let key = "\(size.ws_col):\(size.ws_row):\(size.ws_xpixel):\(size.ws_ypixel)"
            if key != previousSize { previousSize = key; queryMetrics(); relayout(size) }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) > 0 {
                if descriptor.revents & Int16(POLLHUP | POLLERR) != 0 { break }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { break }
                if count > 0 {
                    lastInput = Date()
                    let before = (metrics.cellWidth, metrics.cellHeight, metrics.cellScale, metrics.background)
                    let filtered = metrics.feed(Array(bytes.prefix(count)))
                    if before != (metrics.cellWidth, metrics.cellHeight, metrics.cellScale, metrics.background) { relayout(size) }
                    handle(parser.feed(filtered))
                }
            } else if Date().timeIntervalSince(lastInput) > 0.1 {
                handle(parser.feed(metrics.feed([], flush: true), flushEscape: true))
            }
            // The probe reply arrives with the cell metrics, typically within a few milliseconds.
            if !transportDecided, metrics.graphicsReplies[31] != nil || Date().timeIntervalSince(started) > 0.4 {
                transportDecided = true
                if metrics.graphicsReplies[31] == "OK" { renderer.configure(placement: layout?.desktop, transport: .kittySharedMemory) }
                probe?.cleanup(); probe = nil
            }
            if transportDecided, frames == nil, metrics.cellHeight != nil || Date().timeIntervalSince(started) > 0.4 { frames = streamFrames() }
            if wheel.dx != 0 || wheel.dy != 0, Date().timeIntervalSince(wheel.at) >= 0.03 { flushWheel() }
            sendNextInput()
            if Date().timeIntervalSince(lastChrome) >= 0.08 { lastChrome = Date(); drawChrome() }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        // Let the current frame request finish so its reply and image are removed.
        quit = true
        await frames?.value
        if let failure { throw failure }
    }

    // MARK: Frames

    /// Long-polls the guest for changed frames at the size the terminal draws them.
    /// Older guest helpers answer with full PNG screenshots, which are polled instead.
    private func streamFrames() -> Task<Void, Never> {
        Task { @MainActor in
            var since = -1, failures = 0
            while !Task.isCancelled && !quit {
                let target = layout?.desktop
                // Check back quickly while waiting for a login, so the desktop appears right after it.
                let request = Request(action: "screenshot", arguments: ["format": "bgra-lz4", "since": String(since), "wait": "500",
                                                                      "maxWidth": String(target?.imageWidth ?? 1280), "maxHeight": String(target?.imageHeight ?? 800)],
                                      timeout: link == .login ? 2 : 6)
                defer { mailbox.remove("image-\(request.id.uuidString).bin"); mailbox.remove("image-\(request.id.uuidString).png") }
                do {
                    let reply = try await mailbox.call(request)
                    if quit { break }
                    failures = 0
                    if grants?.input != true, Date().timeIntervalSince(grantsCheckedAt) > 2 { await checkGrants() }
                    connected()
                    let v = reply.values
                    if let w = Int(v["pointWidth"] ?? v["width"] ?? ""), let h = Int(v["pointHeight"] ?? v["height"] ?? ""),
                       (1...16384).contains(w), (1...16384).contains(h), (w, h) != points {
                        points = (w, h); forceRelayout()
                    }
                    if v["unchanged"] == "true" { if link != .live { link = .live }; continue }
                    guard let name = v["image"], [".bin", ".png"].contains(where: { name == "image-\(request.id.uuidString)\($0)" }),
                          let data = try mailbox.read(name, limit: 64 * 1024 * 1024) else { throw Failure("Invalid frame from the guest helper") }
                    if v["format"] == "bgra-lz4" {
                        guard let width = Int(v["width"] ?? ""), let height = Int(v["height"] ?? ""), let stride = Int(v["bytesPerRow"] ?? ""),
                              (1...8192).contains(width), (1...8192).contains(height), (width * 4...width * 4 + 1024).contains(stride) else { throw Failure("Invalid frame size") }
                        since = Int(v["sequence"] ?? "") ?? -1
                        link = .live
                        renderer.submit(.pixels(data, width: width, height: height, bytesPerRow: stride))
                    } else {
                        link = .snapshots
                        renderer.submit(.encoded(data))
                        try await Task.sleep(nanoseconds: 120_000_000)
                    }
                } catch {
                    if Task.isCancelled { break }
                    failures += 1
                    if let timeout = error as? MailboxTimeout {
                        // An unread request means no helper is running; a read one means it is busy or stuck.
                        link = timeout.pickedUp ? .waiting("The guest helper is not responding. Reopen TerminalMacGuest in the VM") : .login
                    } else {
                        // The helper answered with an error: most often a missing macOS permission.
                        await checkGrants()
                        link = grants.map { !$0.screen || !$0.input } == true ? .permissions : .waiting(error.localizedDescription)
                    }
                    if link != .login && link != .permissions { try? await Task.sleep(nanoseconds: min(2_000_000_000, UInt64(failures) * 300_000_000)) }
                }
            }
        }
    }

    private func checkGrants() async {
        grantsCheckedAt = Date()
        guard let values = try? await mailbox.call(Request(action: "status", timeout: 3)).values,
              let screen = values["screenRecording"], let input = values["accessibility"] else { return }
        grants = (screen == "true", input == "true")
    }
    /// The guest answered: remember that, and put away a window the viewer opened once nothing is left to do in it.
    private func connected() {
        if !FileManager.default.fileExists(atPath: Self.readyMarker(directory).path) {
            FileManager.default.createFile(atPath: Self.readyMarker(directory).path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard loginWindow, !inputBlocked else { return }
        loginWindow = false
        record("Guest ready · back in the terminal", ok: true)
        Task { @MainActor in _ = try? await host.call(Request(action: "hide", timeout: 5)) }
    }
    private func openLoginWindow() {
        loginWindow = true
        record("Opened the VM window · it hides once the guest is ready", ok: true)
        Task { @MainActor in
            do { _ = try await host.call(Request(action: "show", timeout: 5)) }
            catch { loginWindow = false; record("Cannot open the VM window: \(error.localizedDescription)", ok: false) }
        }
    }

    // MARK: Layout

    private func queryMetrics() { writer.write("\u{1b}[16t\u{1b}[14t\u{1b}]1337;ReportCellSize\u{7}\u{1b}]11;?\u{7}") }
    private func forceRelayout() {
        layout = nil
        var size = winsize(); _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size); relayout(size)
    }
    private func relayout(_ size: winsize) {
        let cols = max(1, Int(size.ws_col)), rows = max(4, Int(size.ws_row))
        let cw = metrics.cellWidth ?? (size.ws_xpixel > 0 ? Double(size.ws_xpixel) / Double(cols) : 8)
        let ch = metrics.cellHeight ?? (size.ws_ypixel > 0 ? Double(size.ws_ypixel) / Double(rows) : 16)
        // Header and footer take a row each; the rounded frame takes one more cell on every side.
        let border = rows >= 12 && cols >= 24, pad = border ? 1 : 0
        let fit = ImageLayout(width: points.width, height: points.height, column: 1 + pad, row: 2 + pad,
                              columns: cols - 2 * pad, rows: rows - 2 - 2 * pad, cellWidth: cw, cellHeight: ch)
        let scale = metrics.cellScale
        let desktop = DesktopPlacement(column: fit.column, row: fit.row, columns: fit.columns, rows: fit.rows,
                                       canvasWidth: max(1, Int((Double(fit.columns) * cw * scale).rounded())),
                                       canvasHeight: max(1, Int((Double(fit.rows) * ch * scale).rounded())),
                                       imageWidth: max(1, Int((fit.pixelWidth * scale).rounded())),
                                       imageHeight: max(1, Int((fit.pixelHeight * scale).rounded())),
                                       background: graphics == "iterm" ? metrics.background ?? 0x1a1b26 : nil)
        hit = fit
        let next = Layout(desktop: desktop, border: border, columns: cols, rows: rows)
        guard next != layout else { return }
        layout = next
        writer.write("\u{1b}[0m\u{1b}[2J")
        previousChrome = ""
        renderer.configure(placement: desktop)
        drawChrome()
        renderer.redraw()
    }

    // MARK: Chrome

    /// "✕ Screen Recording   ✓ Accessibility", from the helper's last status reply.
    private var grantLine: [Span] {
        func mark(_ name: String, _ granted: Bool?) -> [Span] {
            [Span(granted == true ? "✓ " : "✕ ", granted == true ? Theme.green : Theme.red), Span(name, granted == true ? Theme.muted : Theme.text)]
        }
        return mark("Screen Recording", grants?.screen) + [Span("     ")] + mark("Accessibility", grants?.input)
    }
    private func drawChrome() {
        guard let layout else { return }
        let now = Date(), stats = renderer.currentStats
        if now.timeIntervalSince(fpsSample.at) >= 1 {
            fps = Double(stats.frames - fpsSample.frames) / now.timeIntervalSince(fpsSample.at)
            fpsSample = (stats.frames, now)
        }
        let spin = Theme.spinner[Int(now.timeIntervalSinceReferenceDate * 12) % Theme.spinner.count]
        let d = layout.desktop, cols = layout.columns
        var output = ""

        // Header: brand, machine, connection state.
        let state: [Span] = switch link {
        case .connecting: [Span("\(spin) connecting", Theme.yellow)]
        case .live where fps >= 0.5: [Span("● ", Theme.green), Span("live", Theme.bold + Theme.green), Span("  \(Int(fps.rounded())) fps", Theme.muted)]
        case .live: [Span("● ", Theme.green), Span("live", Theme.bold + Theme.green), Span("  idle", Theme.faint)]
        case .snapshots: [Span("◐ ", Theme.yellow), Span("snapshots", Theme.yellow), Span(" · old guest helper: open My Shared Files/tools/TerminalMacGuest in the VM", Theme.faint)]
        case .login: [Span("◌ ", Theme.yellow), Span("at login screen", Theme.yellow)]
        case .permissions: [Span("◌ ", Theme.yellow), Span("needs permissions", Theme.yellow)]
        case .waiting: [Span("\(spin) ", Theme.yellow), Span("waiting for guest", Theme.yellow)]
        }
        let latency = activity.last?.milliseconds.map { [Span("  \(Int($0.rounded())) ms", Theme.faint)] } ?? []
        let blocked = stats.frames > 0 && inputBlocked && !readOnly ? [Span("  ⚠ input needs Accessibility", Theme.yellow)] : []
        let right = (readOnly ? [Span("view only  ", Theme.faint)] : []) + state + blocked + latency + [Span(" ")]
        var left = [Span(" ◆ terminal-mac ", Theme.badge), Span("  "), Span(machine.name, Theme.bold + Theme.text)]
        let detail = [Span("  macOS", Theme.muted), Span(" · \(points.width)×\(points.height)", Theme.faint),
                      Span(stats.sourceWidth > 0 ? " · \(stats.sourceWidth)×\(stats.sourceHeight) px" : "", Theme.faint)]
        for count in stride(from: detail.count, through: 0, by: -1) where left.width + Array(detail.prefix(count)).width + right.width + 2 <= cols {
            left += detail.prefix(count); break
        }
        output += Box.line(column: 1, row: 1, width: cols, left + [Span(String(repeating: " ", count: max(1, cols - left.width - right.width)))] + right)

        // Display frame. It lights up while a drag is in progress or the palette is open.
        if layout.border {
            output += Box.frame(column: d.column - 1, row: d.row - 1, width: d.columns + 2, height: d.rows + 2,
                                color: anchor != nil || palette ? Theme.accent : Theme.border)
        }
        if stats.frames > 0 && !firstFrameShown {
            // Wipe the connecting message so it does not sit on top of the desktop.
            firstFrameShown = true
            for offset in 0..<8 { output += Box.line(column: d.column, row: d.row + d.rows / 2 - 2 + offset, width: d.columns, []) }
            renderer.redraw()
        }
        if stats.frames == 0 {
            let lines: [[Span]] = switch link {
            case .login where loginWindow: [[Span("◆", Theme.accent)], [],
                [Span(spin + " ", Theme.yellow), Span("Sign in to \(machine.name) in the VM window", Theme.text)],
                [Span("It hides and the desktop appears here as soon as you are in", Theme.muted)]]
            case .login: [[Span("◆", Theme.accent)], [],
                [Span("\(machine.name) is at its login screen", Theme.bold + Theme.text)],
                [Span("Press ", Theme.muted), Span(" ⌃O ", Theme.key), Span(" to sign in, then it continues here", Theme.muted)], [],
                [Span("Skip this every boot: in the VM, System Settings → Users & Groups", Theme.faint)],
                [Span("→ Automatically log in as your user (needs FileVault off)", Theme.faint)]]
            case .permissions:
                [[Span("◆", Theme.accent)], [],
                 [Span("The guest helper needs two macOS permissions inside the VM", Theme.bold + Theme.text)],
                 grantLine,
                 [],
                 loginWindow ? [Span(spin + " ", Theme.yellow), Span("In the VM window, click the helper's Allow buttons and switch TerminalMacGuest on", Theme.text)]
                     : [Span("Press ", Theme.muted), Span(" ⌃O ", Theme.key), Span(" and click the helper's Allow buttons; it continues here by itself", Theme.muted)],
                 [Span("Already on? Remove TerminalMacGuest with − and allow it again", Theme.faint)]]
            case .waiting(let text): [[Span("◆", Theme.accent)], [], [Span(spin + " ", Theme.yellow), Span(text, Theme.text)], [Span("Ctrl+] exits", Theme.faint)]]
            default: [[Span("◆", Theme.accent)], [], [Span(spin + " ", Theme.yellow), Span("Connecting to \(machine.name)", Theme.text)], [Span("Ctrl+] exits", Theme.faint)]]
            }
            // Always paint the same block of rows, so a shorter message clears a longer one.
            for (offset, line) in (lines + Array(repeating: [], count: max(0, 8 - lines.count))).prefix(8).enumerated() {
                let pad = max(0, (d.columns - line.width) / 2)
                output += Box.line(column: d.column, row: d.row + d.rows / 2 - 2 + offset, width: d.columns, [Span(String(repeating: " ", count: pad))] + line)
            }
        }
        if palette { output += drawPalette(d) }

        // Footer: key hints on the left, the latest action on the right.
        func hint(_ key: String, _ action: String) -> [Span] { [Span(" \(key) ", Theme.key), Span(" \(action)", Theme.muted), Span("  ")] }
        let quitHint = hint("⌃]", "quit")
        var footer: [Span] = [Span(" ")]
        if let last = activity.last, now.timeIntervalSince(last.at) < (last.ok ? 2.5 : 6) {
            let toast = [Span(last.ok ? "✓ " : "✕ ", last.ok ? Theme.green : Theme.red), Span(last.text, last.ok ? Theme.text : Theme.red)] +
                (last.milliseconds.map { [Span(" · \(Int($0.rounded())) ms", Theme.faint)] } ?? [])
            let fitted = toast.truncated(max(4, cols - quitHint.width - 3))
            footer += fitted + [Span(String(repeating: " ", count: max(1, cols - 1 - fitted.width - quitHint.width)))]
        } else {
            let hints = link == .login || link == .connecting || link == .permissions || stats.frames == 0 ? [("⌃O", "open VM window")] :
                readOnly ? [] : (inputBlocked ? [("⌃O", "allow Accessibility")] : []) + [("⌃G", "Mac shortcuts"), ("click", "click"), ("drag", "select"), ("wheel", "scroll"), ("type", "keyboard")]
            for (key, action) in hints {
                let item = hint(key, action)
                if footer.width + item.width + quitHint.width > cols { break }
                footer += item
            }
            footer += [Span(String(repeating: " ", count: max(0, cols - footer.width - quitHint.width)))]
        }
        footer += quitHint
        output += Box.line(column: 1, row: layout.rows, width: cols, footer)

        guard output != previousChrome else { return }
        previousChrome = output
        writer.write(output)
    }

    /// A centered card of Mac shortcuts. Every cell has a background, so it covers the desktop image.
    private func drawPalette(_ d: DesktopPlacement) -> String {
        let surface = Theme.bg(0x1f2335), half = (Self.shortcuts.count + 1) / 2
        let cell = 24, width = min(d.columns, cell * 2 + 6), height = min(d.rows, half + 5)
        let column = d.column + (d.columns - width) / 2, row = d.row + (d.rows - height) / 2
        guard width >= 30, height >= 8 else { return "" }
        func styled(_ spans: [Span]) -> [Span] { spans.map { Span($0.text, surface + $0.style) } }
        func line(_ offset: Int, _ spans: [Span]) -> String {
            let fitted = styled(spans).truncated(width - 4)
            return "\u{1b}[\(row + offset);\(column + 2)H" + fitted.rendered + [Span(String(repeating: " ", count: max(0, width - 4 - fitted.width)), surface)].rendered
        }
        var output = ""
        for offset in 1..<(height - 1) {
            output += "\u{1b}[\(row + offset);\(column + 1)H" + [Span(" ", surface)].rendered + "\u{1b}[\(row + offset);\(column + width - 2)H" + [Span(" ", surface)].rendered
        }
        output += Box.frame(column: column, row: row, width: width, height: height,
                            title: [Span("Mac shortcuts", Theme.bold + Theme.accent)], color: surface + Theme.accent)
        output += line(1, [])
        func item(_ s: Shortcut) -> [Span] {
            let label = [Span(" \(s.key) ", Theme.key), Span(" " + s.label, Theme.text)]
            let glyph = Span(s.glyph, Theme.faint)
            return label + [Span(String(repeating: " ", count: max(1, cell - label.width - glyph.text.count))), glyph]
        }
        for index in 0..<min(half, height - 4) {
            var spans = item(Self.shortcuts[index])
            if index + half < Self.shortcuts.count { spans += [Span("  ")] + item(Self.shortcuts[index + half]) }
            output += line(2 + index, spans)
        }
        let hint = "press a key · esc closes"
        output += line(height - 2, [Span(String(repeating: " ", count: max(0, (width - 4 - hint.count) / 2)) + hint, Theme.faint)])
        return output
    }
    private func setPalette(_ open: Bool) {
        guard palette != open, let layout else { return }
        palette = open
        if graphics == "iterm" { renderer.hold(open) }
        if !open {
            // Clear the card so the desktop shows through again.
            let d = layout.desktop
            for row in d.row..<(d.row + d.rows) { writer.write("\u{1b}[0m\u{1b}[\(row);\(d.column)H" + String(repeating: " ", count: d.columns)) }
            if graphics == "iterm" { renderer.redraw() }
        }
        previousChrome = ""; drawChrome()
    }

    private func record(_ text: String, ok: Bool, milliseconds: Double? = nil) {
        activity.append(Activity(at: Date(), text: text, ok: ok, milliseconds: milliseconds))
        if activity.count > 50 { activity.removeFirst(activity.count - 50) }
    }

    // MARK: Input

    /// Input runs one request at a time, in order, without ever blocking drawing or typing.
    private func enqueue(_ action: String, _ arguments: [String: String], label: String) {
        if action == "type", let last = queue.last, last.action == "type", let previous = last.arguments["text"],
           previous.utf8.count + (arguments["text"]?.utf8.count ?? 0) < 32768 {
            let text = previous + (arguments["text"] ?? "")
            let merged = Request(action: "type", arguments: ["text": text], timeout: 5)
            labels[last.id] = nil; labels[merged.id] = Self.typeLabel(text)
            queue[queue.count - 1] = merged; return
        }
        guard queue.count < 64 else { record("Input is busy; wait a moment", ok: false); return }
        let request = Request(action: action, arguments: arguments, timeout: 5)
        labels[request.id] = label
        queue.append(request)
    }
    private func sendNextInput() {
        guard !inFlight, !queue.isEmpty else { return }
        let request = queue.removeFirst(), label = labels.removeValue(forKey: request.id) ?? request.action
        inFlight = true
        Task { @MainActor in
            let started = Date()
            do {
                _ = try await mailbox.call(request)
                record(label, ok: true, milliseconds: Date().timeIntervalSince(started) * 1000)
            } catch {
                queue.removeAll(); labels.removeAll()
                record("\(label): \(error.localizedDescription)", ok: false)
            }
            inFlight = false
        }
    }
    private static func typeLabel(_ text: String) -> String {
        let visible = text.replacingOccurrences(of: "\n", with: "⏎")
        return "type “\(visible.count > 18 ? visible.prefix(17) + "…" : visible)”"
    }
    /// Terminal cell to guest point. Drags keep tracking outside the display.
    private func point(_ column: Int, _ row: Int, clamp: Bool = false) -> (Int, Int)? {
        hit?.point(column: column, row: row, clamp: clamp)
    }
    private func handle(_ events: [TerminalEvent]) {
        var text = ""
        func flush() { if !text.isEmpty { enqueue("type", ["text": text], label: Self.typeLabel(text)); text = "" } }
        for event in events {
            if case .quit = event { quit = true; return }
            if case .key("ctrl+o") = event, (link != .live && link != .snapshots) || inputBlocked { openLoginWindow(); continue }
            guard !readOnly else { continue }
            if palette {
                switch event {
                case .text(let value):
                    if let shortcut = Self.shortcuts.first(where: { String($0.key) == value.lowercased() }) {
                        enqueue("key", ["key": shortcut.chord], label: "\(shortcut.glyph) \(shortcut.label)")
                    }
                    setPalette(false)
                case .key, .mouse: setPalette(false)
                case .quit: break
                }
                continue
            }
            if case .text(let value) = event { text += value; continue }
            flush()
            switch event {
            case .key("ctrl+g"): setPalette(true)
            case .key(let key): enqueue("key", ["key": key], label: "key \(key)")
            case .mouse(let button, let column, let row, let released):
                if button & 64 != 0 {
                    guard let p = point(column, row) else { continue }
                    if wheel.dx == 0 && wheel.dy == 0 { wheel.at = Date() }
                    // 64/65 scroll vertically, 66/67 horizontally. Positive values scroll content up or left.
                    if button & 2 == 0 { wheel.dy = max(-1000, min(1000, wheel.dy + (button & 1 == 0 ? 60 : -60))) }
                    else { wheel.dx = max(-1000, min(1000, wheel.dx + (button & 1 == 0 ? 60 : -60))) }
                    wheel.x = p.0; wheel.y = p.1
                } else if button & 3 == 2 && button & 32 == 0 {
                    guard !released, let p = point(column, row) else { continue }
                    enqueue("click", ["x": String(p.0), "y": String(p.1), "button": "right"], label: "right click \(p.0),\(p.1)")
                } else if button & 32 != 0 {
                    continue // Motion while held: the drag is sent once, on release.
                } else if released {
                    guard let start = anchor, let p = point(column, row, clamp: true) else { anchor = nil; continue }
                    anchor = nil
                    if hypot(Double(p.0 - start.x), Double(p.1 - start.y)) >= 8 {
                        enqueue("drag", ["x": String(start.x), "y": String(start.y), "x2": String(p.0), "y2": String(p.1)], label: "drag \(start.x),\(start.y) → \(p.0),\(p.1)")
                    } else {
                        // A quick second click at the same spot continues a double (or triple) click.
                        var count = 1
                        if let last = lastClick, Date().timeIntervalSince(last.at) < 0.4, abs(last.x - start.x) <= 6, abs(last.y - start.y) <= 6 { count = min(3, last.count + 1) }
                        lastClick = (start.x, start.y, Date(), count)
                        var arguments = ["x": String(start.x), "y": String(start.y)]
                        if count > 1 { arguments["count"] = String(count) }
                        enqueue("click", arguments, label: (count == 2 ? "double click " : count == 3 ? "triple click " : "click ") + "\(start.x),\(start.y)")
                    }
                } else if button & 3 == 0, let p = point(column, row) {
                    anchor = (p.0, p.1, Date())
                }
            default: break
            }
        }
        flush()
    }
    private func flushWheel() {
        // Consecutive scrolls merge in the queue rather than piling up.
        if let last = queue.last, last.action == "scroll" {
            wheel.dy = max(-1000, min(1000, wheel.dy + (Int(last.arguments["dy"] ?? "") ?? 0)))
            wheel.dx = max(-1000, min(1000, wheel.dx + (Int(last.arguments["dx"] ?? "") ?? 0)))
            labels[last.id] = nil; queue.removeLast()
        }
        var arguments = ["x": String(wheel.x), "y": String(wheel.y), "dy": String(wheel.dy)]
        if wheel.dx != 0 { arguments["dx"] = String(wheel.dx) }
        let arrow = wheel.dy > 0 ? "↑" : wheel.dy < 0 ? "↓" : wheel.dx > 0 ? "←" : "→"
        enqueue("scroll", arguments, label: "scroll \(arrow)")
        wheel.dx = 0; wheel.dy = 0
    }
}
