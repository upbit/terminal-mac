import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin
import TerminalMacCore
@testable import TerminalObserver

actor TestObserverSource: ObserverSource {
    var pending: ObserverCaptureResult?
    var calls = 0, closes = 0
    var lowBandwidth = false
    var maxFPS = 30
    func configure(lowBandwidth: Bool, maxFPS: Int) {
        if lowBandwidth != self.lowBandwidth { pending = nil }
        self.lowBandwidth = lowBandwidth; self.maxFPS = maxFPS
    }
    func set(_ frame: ObserverCaptureResult) { pending = frame }
    func next() async throws -> ObserverCaptureResult? {
        calls += 1
        try await Task.sleep(nanoseconds: 10_000_000)
        defer { pending = nil }
        return pending
    }
    func close() { closes += 1 }
}

final class ObserverTransportTests: XCTestCase {
    func testGuestModeReopensAt480AndRestores640() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("observer-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try FileLock(directory.appendingPathComponent("runtime.lock"))
        let host = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
        let guest = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        let transport = Task {
            var opens = 0, closes = 0, epoch = ""
            while !Task.isCancelled && closes < 3 {
                for request in try host.requests() { try host.respond(Reply(id: request.id, values: ["state": "running"])) }
                for request in try guest.requests() {
                    var values: [String: String] = [:]
                    switch request.action {
                    case "observe.capabilities": values = ["observeVersion": "1", "captureOptions": "1"]
                    case "observe.open":
                        XCTAssertEqual(opens, closes, "Previous lease must be closed before reopening")
                        XCTAssertEqual(request.arguments["width"], opens == 1 ? "480" : "640")
                        XCTAssertEqual(request.arguments["maxFps"], opens == 1 ? "10" : nil)
                        epoch = UUID().uuidString
                        values = ["lease": UUID().uuidString, "epoch": epoch]; opens += 1
                    case "observe.poll": values = ["epoch": epoch, "unchanged": "true"]
                    case "observe.close": closes += 1
                    default: XCTFail("Unexpected action")
                    }
                    try guest.respond(Reply(id: request.id, values: values))
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return opens
        }
        let source = GuestObserverSource(directory: directory)
        do {
            for low in [false, true, false] {
                try await source.configure(lowBandwidth: low, maxFPS: low ? 10 : 30)
                _ = try await source.next()
                do { try await source.configure(lowBandwidth: !low, maxFPS: 10); XCTFail("Changed a live lease") }
                catch {}
                await source.close()
            }
            let count = try await transport.value; XCTAssertEqual(count, 3)
        } catch { transport.cancel(); await source.close(); throw error }
        withExtendedLifetime(lock) {}
    }
    func testGuestMailboxSourceNegotiationPollingAndCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("observer-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtimeLock = try FileLock(directory.appendingPathComponent("runtime.lock"))
        let host = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
        let guest = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        let lease = UUID().uuidString, epoch = UUID().uuidString
        let transport = Task {
            var poll = 0, closed = false
            while !Task.isCancelled && !closed {
                for request in try host.requests() { try host.respond(Reply(id: request.id, values: ["state": "running"])) }
                for request in try guest.requests() {
                    var values: [String: String] = [:]
                    switch request.action {
                    case "observe.capabilities": values = ["observeVersion": "1", "captureOptions": "1"]
                    case "observe.open":
                        XCTAssertEqual(request.arguments["width"], "640")
                        XCTAssertEqual(request.arguments["maxFps"], "10")
                        XCTAssertEqual(request.arguments["cursor"], "hide")
                        values = ["lease": lease, "epoch": epoch]
                    case "observe.poll":
                        XCTAssertEqual(request.arguments["lease"], lease); XCTAssertEqual(request.arguments["epoch"], epoch)
                        XCTAssertEqual(request.arguments["after"], String(poll))
                        poll += 1
                        if poll == 3 { values = ["epoch": epoch, "unchanged": "true"]; break }
                        let name = "observe-\(lease)-\(request.id.uuidString).bin"
                        var pixels = Data(repeating: 127, count: 640 * 400 * 4)
                        pixels[2] = UInt8(poll)
                        try guest.write((pixels as NSData).compressed(using: .lz4) as Data, named: name)
                        values = ["image": name, "epoch": epoch, "sequence": String(poll), "width": "640", "height": "400", "bytesPerRow": "2560"]
                        if poll == 1 { values["fullDirty"] = "true" } else { values["tiles"] = "[0,19]" }
                    case "observe.close": XCTAssertEqual(request.arguments["lease"], lease); closed = true
                    default: XCTFail("Unexpected Guest action: \(request.action)")
                    }
                    try guest.respond(Reply(id: request.id, values: values))
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let source = GuestObserverSource(directory: directory, maxFPS: 10, showsCursor: false)
        do {
            let firstResult = try await source.next(), first = try XCTUnwrap(firstResult)
            XCTAssertNil(first.tiles); XCTAssertEqual(first.pixels[0], 1); XCTAssertEqual(first.pixels[3], 255)
            let secondResult = try await source.next(), second = try XCTUnwrap(secondResult)
            XCTAssertEqual(second.tiles, [0, 19]); XCTAssertEqual(second.pixels[0], 2)
            let unchanged = try await source.next()
            XCTAssertNil(unchanged)
            let cleanup = Task {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
                await source.close()
            }
            cleanup.cancel()
            await cleanup.value
            try await transport.value
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("exchange").path), [])
        } catch { transport.cancel(); await source.close(); throw error }
        withExtendedLifetime(runtimeLock) {}
    }
    func testLiveGuestDirtyCoverage() async throws {
        guard let path = ProcessInfo.processInfo.environment["OBSERVER_LIVE_DIRECTORY"] else {
            throw XCTSkip("Set OBSERVER_LIVE_DIRECTORY for the authorized real Guest test")
        }
        let directory = URL(fileURLWithPath: path)
        let observerLock = try FileLock(directory.appendingPathComponent("observer.lock"))
        let source = GuestObserverSource(directory: directory)
        let input = try Mailbox(directory.appendingPathComponent("exchange"))
        let motion = Task {
            for n in 0..<40 {
                // Move only the Guest cursor; no click, text, or VM lifecycle action.
                _ = try await input.call(Request(action: "move", arguments: ["x": String(20 + (n * 97) % 1240),
                                                                             "y": String(20 + (n * 53) % 760)], timeout: 2))
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        var previous: ObserverPixels?, frames = 0, native = 0, fallback = 0, changed = 0
        let began = Date()
        do {
            while Date().timeIntervalSince(began) < 8 {
                guard let capture = try await source.next() else { continue }
                let selective = try ObserverPixels(grid: capture.grid, rgba: capture.pixels, previous: previous, candidates: capture.tiles)
                let oracle = try ObserverPixels(grid: capture.grid, rgba: capture.pixels, previous: previous, candidates: nil)
                XCTAssertEqual(selective.revisions, oracle.revisions, "Native dirty coverage missed changed pixels")
                if let previous { changed += zip(previous.revisions, oracle.revisions).filter { $0 != $1 }.count }
                if capture.tiles == nil { fallback += 1 } else { native += 1 }
                previous = oracle; frames += 1
            }
            try await motion.value
            await source.close()
            XCTAssertGreaterThan(frames, 1); XCTAssertGreaterThan(native, 0); XCTAssertGreaterThan(changed, 0)
            print("LIVE DIRTY: \(frames) captures / \(native) native / \(fallback) full fallback / \(changed) changed tiles / \(Date().timeIntervalSince(began)) seconds")
        } catch { motion.cancel(); await source.close(); throw error }
        withExtendedLifetime(observerLock) {}
    }
    func testOldHelperRejectsLowModeBeforeOpeningLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("observer-old-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try FileLock(directory.appendingPathComponent("runtime.lock"))
        let host = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
        let guest = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        let transport = Task {
            while !Task.isCancelled {
                for request in try host.requests() { try host.respond(Reply(id: request.id, values: ["state": "running"])) }
                for request in try guest.requests() {
                    XCTAssertEqual(request.action, "observe.capabilities", "Must not silently open a 30 FPS cursor-enabled stream")
                    try guest.respond(Reply(id: request.id, values: ["observeVersion": "1"]))
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let source = GuestObserverSource(directory: directory, maxFPS: 10, showsCursor: false)
        do { _ = try await source.next(); XCTFail("Old helper accepted low mode") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Upgrade the Guest helper")) }
        transport.cancel(); _ = try await transport.value
        await source.close()
        withExtendedLifetime(lock) {}
    }
    func testInvalidOriginAndReadOnlyRouteDoNotCapture() async throws {
        let source = TestObserverSource(), server = ObserverServer(source: source)
        let port = try await server.start()
        do {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/stream")!)
            request.setValue("http://evil.invalid", forHTTPHeaderField: "Origin")
            let session = URLSession(configuration: .ephemeral), socket = session.webSocketTask(with: request)
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
            do { _ = try await socket.receive(); XCTFail("Invalid Origin was accepted") } catch {}
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/action/click")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            let calls = await source.calls
            XCTAssertEqual(calls, 0)
        } catch { await server.stop(); throw error }
        await server.stop()
    }
    func testBrowserPreviewHarness() async throws {
        guard let raw = ProcessInfo.processInfo.environment["OBSERVER_BROWSER_PORT"], let port = Int(raw) else {
            throw XCTSkip("Set OBSERVER_BROWSER_PORT to run the browser fixture server")
        }
        let small = ProcessInfo.processInfo.environment["OBSERVER_BROWSER_LOW"] == "1"
        let configuration = try ObserverConfiguration(maxFPS: small ? 10 : 30, bytesPerSecond: small ? 180_000 : nil,
                                                       tileSize: small ? 64 : 128, pngPolicy: small ? .adaptive : .threshold(40))
        let source = TestObserverSource(), server = ObserverServer(source: source, configuration: configuration, lowBandwidth: small)
        let actual = try await server.start(port: port)
        print("Browser fixture: http://127.0.0.1:\(actual)/")
        let epoch = UUID().uuidString
        let duration = Int(ProcessInfo.processInfo.environment["OBSERVER_BROWSER_SECONDS"] ?? "60") ?? 60
        do {
            for n in 0..<(duration * 2) {
                let low = await source.lowBandwidth
                let grid = try ObserverGrid(width: low ? 480 : 640, height: low ? 300 : 400)
                var pixels = Data(count: grid.width * grid.height * 4)
                for y in 0..<grid.height { for x in 0..<grid.width {
                    let d = (y * grid.width + x) * 4
                    let changed = (x < 32 && y < 32) || (x >= grid.width - 128 && y >= grid.height - 16)
                    pixels[d] = changed ? UInt8(n % 200) : 240
                    pixels[d + 1] = changed ? 32 : 245; pixels[d + 2] = changed ? 64 : 250; pixels[d + 3] = 255
                } }
                await source.set(ObserverCaptureResult(epoch: epoch, pixels: pixels, grid: grid, tiles: nil))
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch { await server.stop(); throw error }
        await server.stop()
    }
    func testBudgetWakeFlushesLastChangeAndResyncDoesNotResetDebt() async throws {
        let config = try ObserverConfiguration(maxFPS: 2, bytesPerSecond: 180_000, tileSize: 64, pngPolicy: .adaptive)
        let source = TestObserverSource(), server = ObserverServer(source: source, configuration: config)
        let port = try await server.start()
        do {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/stream")!)
            request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
            let session = URLSession(configuration: .ephemeral), socket = session.webSocketTask(with: request)
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
            let grid = try ObserverGrid(width: 640, height: 400), epoch = UUID().uuidString
            var pixels = Data(repeating: 255, count: 640 * 400 * 4)
            await source.set(ObserverCaptureResult(epoch: epoch, pixels: pixels, grid: grid, tiles: nil))
            try await socket.send(.string("{\"type\":\"subscribe\",\"v\":1}"))
            let (full, _) = try parse(await receiveImage(socket)), start = ProcessInfo.processInfo.systemUptime
            let ack = ["type": "ack", "epoch": full["epoch"] as! String, "seq": "1"]
            try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: ack), as: UTF8.self)))
            pixels[0] = 0
            await source.set(ObserverCaptureResult(epoch: epoch, pixels: pixels, grid: grid, tiles: [0]))
            let (delta, _) = try parse(await receiveImage(socket))
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.43)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.95, "Must wake before the 1s maintenance timer")
            XCTAssertEqual(delta["type"] as? String, "delta")
            XCTAssertEqual(delta["tileSize"] as? Int, 64)
            XCTAssertEqual((delta["blocks"] as? [[String: Any]])?.first?["w"] as? Int, 64)
            let beforeResync = ProcessInfo.processInfo.systemUptime
            try await socket.send(.string("{\"type\":\"resync\"}"))
            let (refresh, _) = try parse(await receiveImage(socket))
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - beforeResync, 0.43)
            XCTAssertEqual(refresh["type"] as? String, "full")
            XCTAssertNotEqual(refresh["epoch"] as? String, full["epoch"] as? String)
        } catch { await server.stop(); throw error }
        await server.stop()
    }
    func testAdaptivePNGChoosesSmallerEnvelopeAndCapsBlocks() throws {
        let grid = try ObserverGrid(width: 640, height: 400, tileSize: 64)
        var pixels = Data(repeating: 255, count: 640 * 400 * 4)
        let initial = try ObserverPixels(grid: grid, rgba: pixels, previous: nil, candidates: nil)
        var client = ObserverClient()
        let first = try XCTUnwrap(client.reserve(initial))
        try client.acknowledge(epoch: first.epoch, seq: first.seq)
        for y in 0..<192 { for x in 0..<640 { pixels[(y * 640 + x) * 4] = 0 } }
        let next = try ObserverPixels(grid: grid, rgba: pixels, previous: initial, candidates: nil)
        let batch = try XCTUnwrap(client.reserve(next))
        let adaptive = try ObserverPNG.batch(batch, policy: .adaptive)
        XCTAssertLessThanOrEqual(adaptive.count, try ObserverPNG.batch(batch, policy: .threshold(100)).count)
        XCTAssertLessThanOrEqual(adaptive.count, try ObserverPNG.batch(batch, policy: .threshold(1)).count)
        let largeGrid = try ObserverGrid(width: 1280, height: 960, tileSize: 64)
        var largePixels = Data(repeating: 255, count: 1280 * 960 * 4)
        let before = try ObserverPixels(grid: largeGrid, rgba: largePixels, previous: nil, candidates: nil)
        var largeClient = ObserverClient()
        let full = try XCTUnwrap(largeClient.reserve(before))
        try largeClient.acknowledge(epoch: full.epoch, seq: full.seq)
        for tile in 0..<257 { let rect = largeGrid.rect(tile); largePixels[(rect.y * 1280 + rect.x) * 4] = 0 }
        let after = try ObserverPixels(grid: largeGrid, rgba: largePixels, previous: before, candidates: nil)
        let many = try XCTUnwrap(largeClient.reserve(after))
        let (header, _) = try parse(ObserverPNG.batch(many, policy: .adaptive))
        XCTAssertEqual(header["type"] as? String, "full")
        XCTAssertEqual((header["blocks"] as? [Any])?.count, 1)
        XCTAssertThrowsError(try ObserverConfiguration(tileSize: 96))
        XCTAssertThrowsError(try ObserverConfiguration(pngPolicy: .threshold(0)))
    }
    func testBoundedLZ4DecodeAndStride() throws {
        let grid = try ObserverGrid(width: 2, height: 2)
        let bgra = Data([3, 2, 1, 0, 6, 5, 4, 0, 99, 99, 99, 99, 9, 8, 7, 0, 12, 11, 10, 0, 88, 88, 88, 88])
        let compressed = try (bgra as NSData).compressed(using: .lz4) as Data
        XCTAssertEqual(try GuestObserverSource.decodeBGRA(compressed, grid: grid, stride: 12),
                       Data([1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255]))
        let bomb = try (Data(repeating: 0, count: 1_000_000) as NSData).compressed(using: .lz4) as Data
        XCTAssertThrowsError(try GuestObserverSource.decodeBGRA(bomb, grid: grid, stride: 8))
        XCTAssertThrowsError(try GuestObserverSource.decodeBGRA(Data([0]), grid: grid, stride: 8))
    }
    func testPNGAndBinaryEnvelope() throws {
        let grid = try ObserverGrid(width: 260, height: 130)
        let pixels = Data(repeating: 255, count: grid.width * grid.height * 4)
        let snapshot = try ObserverPixels(grid: grid, rgba: pixels, previous: nil, candidates: nil)
        var client = ObserverClient()
        let batch = try XCTUnwrap(client.reserve(snapshot))
        let data = try ObserverPNG.batch(batch)
        XCTAssertEqual(data.prefix(8), Data([84, 77, 79, 66, 0, 1, 0, 0]))
        let (head, png) = try parse(data)
        XCTAssertEqual(head["type"] as? String, "full")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 260); XCTAssertEqual(image.height, 130)
    }
    func parse(_ data: Data) throws -> ([String: Any], Data) {
        let length = data[8..<12].reduce(0) { $0 * 256 + Int($1) }
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: data[12..<(12 + length)]) as? [String: Any])
        return (header, Data(data[(12 + length)...]))
    }
    func receiveImage(_ socket: URLSessionWebSocketTask) async throws -> Data {
        for _ in 0..<8 {
            let message = try await socket.receive()
            if case .data(let data) = message { return data }
            if case .string(let text) = message,
               let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], object["type"] as? String == "ping" {
                try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: ["type": "pong", "nonce": object["nonce"]!]), as: UTF8.self)))
            }
        }
        throw Failure("No image received")
    }
    func testRealHTTPWebSocketFullDeltaAndCleanup() async throws {
        let source = TestObserverSource(), server = ObserverServer(source: source)
        let port = try await server.start()
        do {
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            let (page, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("id=\"debug-title\">Debug"))
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            let initialCalls = await source.calls
            XCTAssertEqual(initialCalls, 0)
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/stream")!)
            request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
            let session = URLSession(configuration: .ephemeral), socket = session.webSocketTask(with: request)
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
            let grid = try ObserverGrid(width: 640, height: 400), epoch = UUID().uuidString
            var pixels = Data(repeating: 255, count: grid.width * grid.height * 4)
            await source.set(ObserverCaptureResult(epoch: epoch, pixels: pixels, grid: grid, tiles: nil))
            try await socket.send(.string("{\"type\":\"subscribe\",\"v\":1}"))
            let full = try await receiveImage(socket), (fullHead, _) = try parse(full)
            XCTAssertEqual(fullHead["type"] as? String, "full")
            pixels[0] = 0
            await source.set(ObserverCaptureResult(epoch: epoch, pixels: pixels, grid: grid, tiles: [0]))
            try await Task.sleep(nanoseconds: 100_000_000)
            let ack = ["type": "ack", "epoch": fullHead["epoch"] as! String, "seq": "1"]
            try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: ack), as: UTF8.self)))
            let delta = try await receiveImage(socket), (deltaHead, _) = try parse(delta)
            XCTAssertEqual(deltaHead["type"] as? String, "delta")
            XCTAssertEqual(deltaHead["baseSeq"] as? String, "1")
            XCTAssertEqual((deltaHead["blocks"] as? [[String: Any]])?.count, 1)
            var current = deltaHead
            for n in 0..<40 {
                pixels[0] = UInt8(n + 1)
                await source.set(ObserverCaptureResult(epoch: epoch, pixels: pixels, grid: grid, tiles: [0]))
                let ack = ["type": "ack", "epoch": current["epoch"] as! String, "seq": current["seq"] as! String]
                try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: ack), as: UTF8.self)))
                (current, _) = try parse(await receiveImage(socket))
                XCTAssertEqual(current["type"] as? String, "delta")
            }
            try await socket.send(.string("{\"type\":\"pause\"}"))
            try await Task.sleep(nanoseconds: 100_000_000)
        } catch { await server.stop(); throw error }
        await server.stop()
        let closes = await source.closes
        XCTAssertGreaterThan(closes, 0)
    }
}
