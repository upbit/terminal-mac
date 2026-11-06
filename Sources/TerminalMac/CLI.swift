import AppKit
import Virtualization
import TerminalMacCore
import TerminalMacTracing
import Darwin

@MainActor
final class CLI {
    let store: Store
    lazy var tracing = LangfuseTracing(version: appVersion)
    private var tracingUsed = false
    var commandContext: String?
    var runtime: MachineRuntime?
    var guest: GuestRuntime?
    init(store: Store = Store(), tracing: LangfuseTracing? = nil) {
        self.store = store
        if let tracing { self.tracing = tracing }
    }
    var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.resolvingSymlinksInPath()
    }
    var toolsURL: URL {
        executableURL
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/guest-tools")
    }
    func run(_ input: [String], quietStartup: Bool = false) async throws {
        let command = input.first ?? (Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" ? "guest" : (isatty(STDIN_FILENO) == 1 ? "up" : "help"))
        if ["guest", "__run", "mcp", "trace", "chain", "action"].contains(command) {
            if !["guest", "__run"].contains(command) { tracingUsed = true }
            try await performRun(input, quietStartup: quietStartup)
            return
        }
        tracingUsed = true
        let options = Self.tracingOptions(Array(input.dropFirst()))
        let output = CommandOutput()
        let safeCommand = Self.commandName(command)
        try await tracing.observeTool("unknown", arguments: [:], channel: "cli", contextHandle: options.context,
            reason: options.reason, actor: options.actor, operationName: "execute-\(safeCommand)-command",
            errorOutput: { [self] error in
                tracing.recordMetadata(["exit_code": "1"])
                return ["ok": false, "exit_code": 1, "error": error.localizedDescription]
            }, output: { _ in ["ok": true, "exit_code": 0, "returned": output.entries] }) {
                try await CommandOutput.$current.withValue(output) {
                    let previousContext = commandContext
                    commandContext = options.context
                    defer { commandContext = previousContext }
                    tracing.recordInput(["command": safeCommand, "argument_count": options.remaining.count])
                    try await performRun([command] + options.remaining, quietStartup: quietStartup)
                    tracing.recordMetadata(["exit_code": "0"])
                }
            }
    }

    func shutdownTracing() async {
        if tracingUsed { await tracing.shutdown() }
    }

    func arguments(_ input: [String], flags: Set<String> = [], options: Set<String> = []) throws -> Arguments {
        let args = try Arguments(input, flags: flags, options: options)
        tracing.recordInput(["positionals": args.positionals, "options": args.options, "flags": args.flags.sorted()])
        return args
    }

    static func commandName(_ value: String) -> String {
        let aliases = ["--help": "help", "-h": "help", "--version": "version", "list": "ls", "setup": "up"]
        let name = aliases[value] ?? value
        return ["help", "version", "up", "doctor", "image", "create", "ls", "start", "status", "show", "hide", "pause", "resume", "stop", "display", "skills", "view"].contains(name) ? name : "unknown"
    }

    static func tracingOptions(_ input: [String]) -> (remaining: [String], context: String?, reason: String?, actor: String) {
        var remaining: [String] = [], values: [String: String] = [:], index = 0
        while index < input.count {
            if input[index] == "--" { remaining += input[index...]; break }
            if ["--context", "--reason", "--actor"].contains(input[index]), index + 1 < input.count,
               !input[index + 1].hasPrefix("--"), values[input[index]] == nil {
                values[input[index]] = input[index + 1]; index += 2
            } else { remaining.append(input[index]); index += 1 }
        }
        return (remaining, values["--context"], values["--reason"], values["--actor"] ?? "unknown")
    }

    private func performRun(_ input: [String], quietStartup: Bool = false) async throws {
        let command = input.first ?? (Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" ? "guest" : (isatty(STDIN_FILENO) == 1 ? "up" : "help"))
        let tail = Array(input.dropFirst())
        switch command {
        case "help", "--help", "-h": cliPrint(Self.help)
        case "--version", "version": cliPrint("terminal-mac \(appVersion)")
        case "up", "setup": try await up(tail)
        case "doctor":
            _ = try arguments(tail)
            try printJSON(["architecture": "arm64", "virtualizationSupported": String(VZVirtualMachine.isSupported),
                           "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "dataDirectory": store.root.path,
                           "guestToolsBundled": String(FileManager.default.fileExists(atPath: toolsURL.appendingPathComponent("TerminalMacGuest.app").path))])
        case "image":
            let args = try arguments(tail, options: ["output"])
            guard args.positionals.isEmpty else { throw Failure("Usage: terminal-mac image [--output /path/to/restore.ipsw]") }
            let image = try await VZMacOSRestoreImage.latestSupported
            guard let output = args.options["output"] else {
                try printJSON(["url": image.url.absoluteString, "build": image.buildVersion, "version": "\(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion)"])
                return
            }
            let destination = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure("Output already exists; it will not be overwritten") }
            stderr("Downloading macOS from Apple. Restore images are several gigabytes; this may take a while…")
            let (temporary, response) = try await URLSession.shared.download(from: image.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("Apple restore-image download failed") }
            try FileManager.default.moveItem(at: temporary, to: destination)
            cliPrint(destination.path)
        case "create":
            let args = try arguments(tail, flags: ["offline", "standard"], options: ["ipsw", "cpus", "memory", "disk", "width", "height"])
            try await VirtualMachines.create(args, store: store)
        case "ls", "list":
            _ = try arguments(tail)
            let directory = store.root.appendingPathComponent("machines")
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let machines = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { try? store.load($0.lastPathComponent) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            cliPrint(String(decoding: try encoder.encode(machines), as: UTF8.self))
        case "start":
            let args = try arguments(tail, flags: ["window"])
            let name = try args.machineName()
            let machine = try store.load(name)
            guard machine.installed else { throw Failure("Installation did not complete. See the VM directory and README recovery instructions.") }
            let directory = try store.directory(name)
            if runtimeIsLocked(directory) {
                if args.flags.contains("window") { _ = try await host(name, action: "show") }
                if !quietStartup { try printJSON(["name": name, "state": "already-running"]) }; return
            }
            guard FileManager.default.fileExists(atPath: toolsURL.appendingPathComponent("TerminalMacGuest.app").path) else { throw Failure("Guest tools are missing. Run scripts/build.sh and use dist/terminal-mac.") }
            let log = directory.appendingPathComponent("runtime.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let logHandle = try FileHandle(forWritingTo: log)
            try logHandle.seekToEnd()
            defer { try? logHandle.close() }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["__run", name] + (args.flags.contains("window") ? ["--window"] : [])
            var environment = ProcessInfo.processInfo.environment; environment["TERMINAL_MAC_HOME"] = store.root.path
            process.environment = environment
            process.standardOutput = logHandle; process.standardError = logHandle; process.standardInput = FileHandle.nullDevice
            try process.run()
            // A host mailbox responds only after VZ has booted successfully.
            _ = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
            do {
                let reply = try await host(name, action: "status", timeout: 30)
                if !quietStartup { try printJSON(reply.values) }
            } catch {
                throw Failure("VM did not become ready: \(error.localizedDescription). Details: \(log.path)")
            }
        case "__run":
            let args = try Arguments(tail, flags: ["window"])
            let name = try args.machineName()
            let machine = try store.load(name)
            guard machine.installed else { throw Failure("VM installation is incomplete") }
            runtime = try MachineRuntime(machine: machine, directory: store.directory(name), tools: toolsURL)
            try await runtime!.start(show: args.flags.contains("window"))
            // Keep the app event loop and runtime alive until guest shutdown.
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        case "status", "show", "hide", "pause", "resume", "stop":
            let args = try arguments(tail, flags: command == "stop" ? ["force"] : [])
            let name = try args.machineName()
            _ = try store.load(name)
            if command == "status", !runtimeIsLocked(try store.directory(name)) {
                try printJSON(["name": name, "state": "stopped"]); return
            }
            let reply = try await host(name, action: command, arguments: ["force": String(args.flags.contains("force"))])
            try printJSON(reply.values)
        case "display":
            let args = try arguments(tail, flags: ["hidpi", "standard"])
            let name = try args.machineName()
            var machine = try store.load(name)
            guard args.flags.count == 1 else { throw Failure("Usage: terminal-mac display [NAME] --hidpi|--standard") }
            guard !runtimeIsLocked(try store.directory(name)) else { throw Failure("Stop the VM first: terminal-mac stop \(name). The display mode applies at the next boot.") }
            machine.scale = args.flags.contains("hidpi") ? 2 : 1
            try store.save(machine)
            try printJSON(["name": name, "display": "\(machine.width)×\(machine.height) points at \(machine.displayScale)x"])
        case "action": try await action(tail)
        case "trace", "chain":
            let args = try Arguments(tail, options: ["goal", "context", "reason", "session", "outcome", "summary"])
            guard args.positionals.count == 1 else { throw Failure("Usage: terminal-mac trace|chain begin|end|status [options]") }
            let result: [String: Any]
            switch args.positionals[0] {
            case "begin":
                if command == "chain", args.options["context"] == nil { throw Failure("chain begin requires --context") }
                result = try tracing.begin(goal: args.options["goal"] ?? "", parent: command == "chain" ? args.options["context"] : nil,
                    reason: args.options["reason"], sessionID: args.options["session"])
            case "end": result = try tracing.end(context: args.options["context"] ?? "", chain: command == "chain",
                outcome: args.options["outcome"] ?? "", summary: args.options["summary"] ?? "")
            case "status": result = try tracing.diagnostics()
            default: throw Failure("Expected begin, end, or status")
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            cliPrint(String(decoding: data, as: UTF8.self))
        case "mcp":
            let args = try Arguments(tail, flags: ["config"])
            let name = try args.machineName()
            if args.flags.contains("config") {
                // Point clients at the launcher, not the versioned bundle, so upgrades keep working.
                let server: [String: Any] = ["command": launcherPath, "args": name == "default" ? ["mcp"] : ["mcp", name]]
                let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["terminal-mac": server]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                cliPrint(String(decoding: data, as: UTF8.self)); return
            }
            try await AgentServer(store: store, name: name, tracing: tracing).run()
        case "skills":
            let args = try arguments(tail, options: ["dir"])
            guard let skill = bundledSkill else { throw Failure("This build has no bundled skill. Reinstall terminal-mac.") }
            switch args.positionals {
            case ["get"], []: cliPrint(try String(contentsOf: skill, encoding: .utf8), terminator: "")
            case ["path"]: cliPrint(skill.path)
            case ["install"]:
                let root = args.options["dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
                let destination = root.appendingPathComponent("terminal-mac/SKILL.md")
                if let existing = try? String(contentsOf: destination, encoding: .utf8), !existing.contains("\nname: terminal-mac\n") {
                    throw Failure("Refusing to replace a different skill at \(destination.path)")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: skill).write(to: destination, options: .atomic)
                try printJSON(["installed": destination.path])
            default: throw Failure("Usage: terminal-mac skills [get|path|install [--dir ~/.claude/skills]]")
            }
        case "view":
            let args = try arguments(tail, flags: ["read-only", "trace-manual"], options: ["protocol"])
            let name = try args.machineName()
            let machine = try store.load(name)
            guard runtimeIsLocked(try store.directory(name)) else { throw Failure("VM '\(name)' is stopped. Start it with: terminal-mac start \(name)") }
            let viewer = try TerminalViewer(directory: store.directory(name), machine: machine, graphics: args.options["protocol"], readOnly: args.flags.contains("read-only"),
                tracing: tracing, traceManual: args.flags.contains("trace-manual"), traceContext: commandContext)
            try await viewer.run()
        case "guest":
            let args = try Arguments(tail, flags: ["check"], options: ["exchange"])
            guard args.positionals.isEmpty else { throw Failure("Usage: terminal-mac guest [--check] [--exchange PATH]") }
            try GuestGuard.requireVirtualMac()
            if args.flags.contains("check") { print("virtual-mac"); return }
            if try await GuestBootstrap.installAndRelaunchIfNeeded() { return }
            let exchange = URL(fileURLWithPath: args.options["exchange"] ?? "/Volumes/My Shared Files/control")
            guest = try GuestRuntime(exchange: exchange)
            guest!.start()
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        default: throw Failure("Unknown command: \(command). Run terminal-mac help.")
        }
    }
    func host(_ name: String, action: String, arguments: [String: String] = [:], timeout: Double = 5) async throws -> Reply {
        try await Mailbox(store.directory(name).appendingPathComponent("host-control")).call(Request(action: action, arguments: arguments, timeout: timeout))
    }
    func action(_ input: [String]) async throws {
        let options = Self.tracingOptions(input)
        let actions: Set<String> = ["status", "screenshot", "snapshot", "click", "move", "drag", "scroll", "type", "key"]
        let verb = options.remaining.prefix(2).first { actions.contains($0) } ?? "unknown"
        var correlation: [String: Any] = [:]
        _ = try await tracing.observeTool(verb, arguments: [:], channel: "cli", contextHandle: options.context,
            reason: options.reason, actor: options.actor,
            errorOutput: { [self] error in
                tracing.recordMetadata(["exit_code": "1"])
                return ["ok": false, "exit_code": 1, "error": "tool-failed", "message": error.localizedDescription]
            }, correlation: { correlation = $0 }, output: tracing.actionOutput) {
                let (values, envelope) = try await actionResult(options.remaining)
                if envelope {
                    let data = try JSONSerialization.data(withJSONObject: ["result": values, "tracing": correlation], options: [.prettyPrinted, .sortedKeys])
                    cliPrint(String(decoding: data, as: UTF8.self))
                } else { try printJSON(values) }
                tracing.recordMetadata(["exit_code": "0"])
                return values
            }
    }

    private func actionResult(_ input: [String]) async throws -> ([String: String], Bool) {
        let args = try Arguments(input, flags: ["double", "trace-envelope"], options: ["x", "y", "x2", "y2", "dx", "dy", "text", "key", "button", "count", "output", "timeout"])
        let actions: Set<String> = ["status", "screenshot", "snapshot", "click", "move", "drag", "scroll", "type", "key"]
        var positions = args.positionals
        let name: String
        if let first = positions.first, actions.contains(first) { name = "default" }
        else { guard !positions.isEmpty else { throw Failure("Usage: terminal-mac action [NAME] screenshot|click|type|key|scroll|status") }; name = positions.removeFirst() }
        try validateName(name)
        guard !positions.isEmpty, actions.contains(positions[0]) else { throw Failure("Unknown or missing guest action") }
        let verb = positions.removeFirst()
        var parameters = args.options
        parameters.removeValue(forKey: "output"); parameters.removeValue(forKey: "timeout")
        if verb == "type", !positions.isEmpty { parameters["text"] = positions.joined(separator: " "); positions.removeAll() }
        if verb == "key", positions.count == 1 { parameters["key"] = positions.removeFirst() }
        if ["click", "move"].contains(verb), positions.count == 2 { parameters["x"] = positions.removeFirst(); parameters["y"] = positions.removeFirst() }
        if verb == "drag", positions.count == 4 {
            for key in ["x", "y", "x2", "y2"] { parameters[key] = positions.removeFirst() }
        }
        guard positions.isEmpty else { throw Failure("Unexpected action arguments") }
        if args.flags.contains("double") { parameters["double"] = "true" }
        let timeout = try args.integer("timeout", default: 15, range: 1...120)
        tracing.recordInput(["tool": verb == "snapshot" ? "screenshot" : verb, "arguments": parameters])
        let result = try await performAction(name, verb: verb, parameters: parameters, timeout: timeout, output: args.options["output"])
        return (result, args.flags.contains("trace-envelope"))
    }

    private func performAction(_ name: String, verb: String, parameters: [String: String], timeout: Int,
                               output: String?) async throws -> [String: String] {
        _ = try store.load(name)
        let mailbox = try Mailbox(store.directory(name).appendingPathComponent("exchange"))
        let request = Request(action: verb, arguments: parameters, timeout: Double(timeout))
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        let reply = try await tracing.observeGuest(request) { try await mailbox.call(request) }
        var values = reply.values
        if verb == "screenshot" || verb == "snapshot" {
            guard values["image"] == imageName, let png = try mailbox.read(imageName, limit: 32 * 1024 * 1024) else { throw Failure("Invalid guest image response") }
            let output = URL(fileURLWithPath: ((output ?? "terminal-mac-\(name).png") as NSString).expandingTildeInPath)
            try png.write(to: output, options: .atomic)
            values["image"] = output.path
            await tracing.recordScreenshotMedia(png, mimeType: "image/png")
        }
        return values
    }
    /// The agent skill shipped inside the app bundle, so its instructions match this version.
    /// Development builds outside a bundle fall back to the repository copy.
    var bundledSkill: URL? {
        let bundled = executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills/terminal-mac/SKILL.md")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        var directory = executableURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("skills/terminal-mac/SKILL.md")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
    /// How the user invoked us, before symlinks: the installer's stable launcher.
    var launcherPath: String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(invoked)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return executableURL.path
    }
    func runtimeIsLocked(_ directory: URL) -> Bool { Self.isRunning(directory) }
    static func isRunning(_ directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }
    static let help = """
    terminal-mac — a separate macOS desktop for computer-use agents

    up [NAME]                   Download, install, boot and open your virtual Mac
      [--ipsw PATH]             Optional existing image; otherwise downloaded from Apple
      [--no-view | --detach]    Wait for readiness without viewing, or just boot
      [--plan] [--timeout 1800] Preview steps without changes; setup wait in seconds
    setup [NAME]                Same guided flow as up
    terminal-mac                Runs up in an interactive terminal

    image [--output PATH]         Find or download Apple's latest supported IPSW
    create [NAME] --ipsw PATH     Install a new virtual Mac (default name: default)
      [--cpus 4 --memory 4 --disk 64 --width 1280 --height 800 --offline]
      [--standard]                1x display; new VMs default to sharp 2x HiDPI
    display [NAME] --hidpi|--standard  Switch a stopped VM between 2x and 1x
    start [NAME] [--window]       Boot in the background; show setup window if requested
    view [NAME] [--read-only]     Live terminal desktop (Ghostty, Kitty, iTerm2)
      [--protocol kitty|iterm]    Ctrl+G opens Mac shortcuts; Ctrl+] exits
      [--trace-manual --context HANDLE] Optional manual timeline; Ctrl+P pauses capture
                                 Ctrl+T detaches/reattaches the explicit context
    show|hide [NAME]             Show or hide the native VM window
    status|pause|resume [NAME]   Manage the VM
    stop [NAME] [--force]        Request guest shutdown (or immediately power off)
    ls                          List installed VMs as JSON
    doctor                      Check host support and bundled guest tools

    action [NAME] status
    action [NAME] screenshot [--output PATH]
    action [NAME] click X Y [--button right] [--double]
    action [NAME] move X Y
    action [NAME] drag X Y X2 Y2
    action [NAME] type 'text'
    action [NAME] key cmd+space
    action [NAME] scroll --dy -300 [--dx 0 --x 640 --y 400]
      [--context HANDLE --reason TEXT --trace-envelope] Optional tracing context

    trace begin --goal TEXT [--session ID]  Begin a task and return its context
    chain begin --context HANDLE --goal TEXT [--reason TEXT]
    chain|trace end --context HANDLE --outcome success|failed|cancelled [--summary TEXT]
    trace status                Tracing availability and queue counters
    Public commands accept optional --context HANDLE --reason TEXT --actor ai|human

    mcp [NAME]                  MCP server (stdio) with computer-use tools for agents:
                                claude mcp add terminal-mac -- terminal-mac mcp
      [--config]                Print an mcpServers entry for Cursor, VS Code, Codex…
    skills get|path|install     The agent skill for this version; install copies it
      [--dir ~/.claude/skills]  into an agent's skills folder

    Actions require TerminalMacGuest.app running inside the logged-in guest.
    Screen Recording and Accessibility are granted inside the guest only.
    TERMINAL_MAC_HOME overrides the host data directory.
    """
}

/// The app bundle around the running executable. Bundle.main cannot find it when the CLI is
/// started through the installer's symlink, so versions would fall back to a guess.
let appBundle: Bundle = {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
    return Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? Bundle.main
}()
var appVersion: String { appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

@MainActor func printJSON(_ value: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    cliPrint(String(decoding: data, as: UTF8.self))
}

@MainActor final class CommandOutput {
    @TaskLocal static var current: CommandOutput?
    var entries: [Any] = []
    func append(_ text: String) {
        guard entries.count < 16 else { return }
        if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) { entries.append(value) }
        else { entries.append(String(text.prefix(16_384))) }
    }
}

@MainActor func cliPrint(_ text: String, terminator: String = "\n") {
    CommandOutput.current?.append(text)
    print(text, terminator: terminator)
}
