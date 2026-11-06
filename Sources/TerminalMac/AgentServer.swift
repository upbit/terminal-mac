import CoreGraphics
import Foundation
import ImageIO
import TerminalMacCore
import UniformTypeIdentifiers

/// A Model Context Protocol server over stdio, so agents get computer-use tools for the guest
/// desktop without shelling out: `claude mcp add terminal-mac -- /path/to/terminal-mac mcp`.
/// It only talks to the guest helper's mailbox; it never touches the host desktop.
@MainActor
final class AgentServer {
    let store: Store
    let name: String
    init(store: Store, name: String) { self.store = store; self.name = name }

    static let instructions = """
    Controls a separate virtual Mac, not the user's own desktop. Call `screenshot` first; every \
    x/y is a pixel in that screenshot (top-left origin), which equals guest screen points. \
    Take another screenshot after actions to check the result. If the guest is at its login \
    screen or a macOS permission prompt appears, ask the user to handle it.
    """

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let point: [String: Any] = ["type": "integer", "minimum": 0]
    private static let after: [String: Any] = ["type": "boolean", "description": "Also return a screenshot taken shortly after the action."]
    static let tools: [[String: Any]] = [
        ["name": "screenshot", "description": "Capture the virtual Mac's screen. Coordinates for other tools are pixels in this image.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]],
        ["name": "click", "description": "Click at a point. clicks: 2 double-clicks, 3 triple-clicks.",
         "inputSchema": schema(["x": point, "y": point, "button": ["type": "string", "enum": ["left", "right"]],
                                "clicks": ["type": "integer", "minimum": 1, "maximum": 3], "screenshot": after], required: ["x", "y"])],
        ["name": "move", "description": "Move the pointer, for example to reveal a hover menu or tooltip.",
         "inputSchema": schema(["x": point, "y": point, "screenshot": after], required: ["x", "y"])],
        ["name": "drag", "description": "Press the left button at (x, y), drag to (toX, toY) and release. Selects text, moves windows and items.",
         "inputSchema": schema(["x": point, "y": point, "toX": point, "toY": point, "screenshot": after], required: ["x", "y", "toX", "toY"])],
        ["name": "scroll", "description": "Scroll at a point. Negative dy scrolls content down (like swiping up), positive dy scrolls up. Pixels, -1000…1000.",
         "inputSchema": schema(["x": point, "y": point, "dy": ["type": "integer"], "dx": ["type": "integer"], "screenshot": after], required: ["x", "y", "dy"])],
        ["name": "type", "description": "Type literal text into the focused field. Use `key` for return, tab and shortcuts.",
         "inputSchema": schema(["text": ["type": "string"], "screenshot": after], required: ["text"])],
        ["name": "key", "description": "Press a key or chord: return, tab, escape, backspace, up, cmd+space, cmd+tab, cmd+c, cmd+shift+... Modifiers: cmd, ctrl, alt, shift.",
         "inputSchema": schema(["key": ["type": "string"], "screenshot": after], required: ["key"])],
        ["name": "status", "description": "Report whether the VM is running and the guest helper has its privacy permissions.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]]
    ]

    func run() async throws {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            // Notifications have no id and get no reply.
            guard let id = message["id"] else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "terminal-mac", "version": appVersion],
                    "instructions": Self.instructions]])
            case "ping": send(["jsonrpc": "2.0", "id": id, "result": [:]])
            case "tools/list": send(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.tools]])
            case "tools/call":
                let tool = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do { send(["jsonrpc": "2.0", "id": id, "result": ["content": try await call(tool, arguments)]]) }
                catch { send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": explain(error)]], "isError": true]]) }
            default: send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
    }

    private func call(_ tool: String, _ a: [String: Any]) async throws -> [[String: Any]] {
        func int(_ key: String) throws -> String {
            guard let value = a[key] as? Int ?? (a[key] as? Double).map({ Int($0) }) else { throw Failure("Missing integer '\(key)'") }
            return String(value)
        }
        func string(_ key: String) throws -> String {
            guard let value = a[key] as? String, !value.isEmpty else { throw Failure("Missing '\(key)'") }
            return value
        }
        var requests: [Request] = []
        switch tool {
        case "screenshot": return try await screenshot()
        case "status":
            let reply = try await guest(Request(action: "status", timeout: 5))
            let summary = reply.values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return [["type": "text", "text": "VM '\(name)' is running.\n" + summary]]
        case "click":
            var base = ["x": try int("x"), "y": try int("y")]
            if a["button"] as? String == "right" { base["button"] = "right" }
            let clicks = max(1, min(3, a["clicks"] as? Int ?? 1))
            // Each extra click continues the sequence, which macOS reads as a double or triple click.
            for count in 1...clicks { requests.append(Request(action: "click", arguments: count == 1 ? base : base.merging(["count": String(count)]) { $1 }, timeout: 10)) }
        case "move": requests = [Request(action: "move", arguments: ["x": try int("x"), "y": try int("y")], timeout: 10)]
        case "drag": requests = [Request(action: "drag", arguments: ["x": try int("x"), "y": try int("y"), "x2": try int("toX"), "y2": try int("toY")], timeout: 15)]
        case "scroll":
            var arguments = ["x": try int("x"), "y": try int("y"), "dy": try int("dy")]
            if a["dx"] != nil { arguments["dx"] = try int("dx") }
            requests = [Request(action: "scroll", arguments: arguments, timeout: 10)]
        case "type": requests = [Request(action: "type", arguments: ["text": try string("text")], timeout: 30)]
        case "key": requests = [Request(action: "key", arguments: ["key": try string("key")], timeout: 10)]
        default: throw Failure("Unknown tool: \(tool)")
        }
        for request in requests { _ = try await guest(request) }
        var content: [[String: Any]] = [["type": "text", "text": "Done: \(tool)."]]
        if a["screenshot"] as? Bool == true {
            // Give animations and redraws a moment before looking.
            try await Task.sleep(nanoseconds: 400_000_000)
            content += try await screenshot()
        }
        return content
    }

    /// A point-sized screenshot, so image pixels are the coordinates the other tools take.
    /// JPEG keeps the message small; the model sees the same detail at this size.
    private func screenshot() async throws -> [[String: Any]] {
        try requireRunning()
        let mailbox = try exchange()
        let request = Request(action: "screenshot", timeout: 15)
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        let reply = try await guest(request, mailbox: mailbox)
        guard reply.values["image"] == imageName, let png = try mailbox.read(imageName, limit: 64 * 1024 * 1024),
              let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("The guest helper returned an invalid screenshot")
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure("Cannot encode screenshot") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot encode screenshot") }
        return [["type": "image", "data": (jpeg as Data).base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": "Screen: \(image.width)×\(image.height). Use these pixel coordinates."]]
    }

    private func exchange() throws -> Mailbox { try Mailbox(store.directory(name).appendingPathComponent("exchange")) }
    private func guest(_ request: Request, mailbox: Mailbox? = nil) async throws -> Reply {
        try requireRunning()
        return try await (mailbox ?? exchange()).call(request)
    }
    /// Checked per call, so the server starts (and lists its tools) before any VM exists.
    private func requireRunning() throws {
        guard (try? store.load(name)) != nil else {
            throw Failure("No virtual Mac named '\(name)' exists yet. Ask the user to run `terminal-mac up\(name == "default" ? "" : " " + name)`; it downloads macOS and needs them for first-time setup.")
        }
        let directory = try store.directory(name)
        guard CLI.isRunning(directory) else { throw Failure("VM '\(name)' is stopped. Ask the user to run: terminal-mac start \(name)") }
    }
    private func explain(_ error: Error) -> String {
        if let timeout = error as? MailboxTimeout, !timeout.pickedUp {
            return "The virtual Mac has no logged-in session (it is probably at its login screen) or its guest helper is not running. Ask the user to sign in to the VM, for example with `terminal-mac view \(name)` and Ctrl+O."
        }
        return error.localizedDescription
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
