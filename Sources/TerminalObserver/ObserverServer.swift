import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import TerminalMacCore

private final class ConnectionLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var tcp = 0, ws = 0
    func acquire(websocket: Bool = false) -> Bool {
        lock.withLock {
            if websocket { guard ws < ObserverLimits.maxConnections else { return false }; ws += 1 }
            else { guard tcp < 24 else { return false }; tcp += 1 }
            return true
        }
    }
    func release(websocket: Bool = false) { lock.withLock { if websocket { ws -= 1 } else { tcp -= 1 } } }
}

public final class ObserverServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let hub: ObserverHub
    private let limit = ConnectionLimit()
    private var channel: Channel?
    public init(source: any ObserverSource, configuration: ObserverConfiguration = .standard, lowBandwidth: Bool = false) {
        hub = ObserverHub(source: source, configuration: configuration, lowBandwidth: lowBandwidth)
    }
    public func start(port: Int = 0) async throws -> Int {
        let hub = self.hub, limit = self.limit
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 32768, high: 65536))
            .childChannelInitializer { channel in
                guard limit.acquire() else { return channel.close() }
                channel.closeFuture.whenComplete { _ in limit.release() }
                let id = UUID(), http = ObserverHTTPHandler()
                let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: ObserverLimits.maxControlBytes,
                    shouldUpgrade: { channel, head in
                        guard head.method == .GET, head.uri == "/stream", Self.validHost(head, channel: channel),
                              head.headers["Origin"] == ["http://127.0.0.1:\(channel.localAddress!.port!)"],
                              limit.acquire(websocket: true) else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }
                        channel.closeFuture.whenComplete { _ in limit.release(websocket: true) }
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    }, upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 1, maxAccumulatedFrameCount: 32,
                                                           maxAccumulatedFrameSize: ObserverLimits.maxControlBytes))
                            try channel.pipeline.syncOperations.addHandler(ObserverSocketHandler(id: id, hub: hub))
                        }
                    })
                let config: NIOHTTPServerUpgradeConfiguration = (upgraders: [upgrader], completionHandler: { context in
                    context.pipeline.removeHandler(http, promise: nil)
                })
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                    channel.pipeline.addHandler(http)
                }
            }
        channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        return channel!.localAddress!.port!
    }
    public func stop() async {
        await hub.stop()
        try? await channel?.close().get()
        try? await group.shutdownGracefully()
    }
    static func validHost(_ head: HTTPRequestHead, channel: Channel) -> Bool {
        head.headers["Host"] == ["127.0.0.1:\(channel.localAddress!.port!)"]
    }
    static let webBundle: Bundle = {
        let name = "terminal-mac_TerminalObserver.bundle"
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.resolvingSymlinksInPath()
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        for root in [Bundle.main.resourceURL, resources].compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }()
}

private final class ObserverHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var timeout: Scheduled<Void>?
    func handlerAdded(context: ChannelHandlerContext) {
        timeout = context.eventLoop.scheduleTask(in: .seconds(5)) { context.close(promise: nil) }
    }
    func handlerRemoved(context: ChannelHandlerContext) { timeout?.cancel() }
    func channelInactive(context: ChannelHandlerContext) { timeout?.cancel(); context.fireChannelInactive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: context.close(promise: nil)
        case .end:
            guard let head, head.method == .GET, ObserverServer.validHost(head, channel: context.channel) else {
                respond(context, status: .forbidden, data: Data("Loopback GET only".utf8), mime: "text/plain"); return
            }
            let resource: (String, String)?
            switch head.uri {
            case "/": resource = ("index.html", "text/html; charset=utf-8")
            case "/observer.js": resource = ("observer.js", "text/javascript; charset=utf-8")
            case "/observer.css": resource = ("observer.css", "text/css; charset=utf-8")
            default: resource = nil
            }
            guard let resource, let url = ObserverServer.webBundle.url(forResource: resource.0, withExtension: nil, subdirectory: "Web"),
                  let data = try? Data(contentsOf: url) else {
                respond(context, status: .notFound, data: Data("Not found or invalid WebSocket upgrade".utf8), mime: "text/plain"); return
            }
            respond(context, status: .ok, data: data, mime: resource.1)
        }
    }
    private func respond(_ context: ChannelHandlerContext, status: HTTPResponseStatus, data: Data, mime: String) {
        let headers = HTTPHeaders([
            ("Content-Type", mime), ("Content-Length", String(data.count)), ("Connection", "close"),
            ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
            ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'")
        ])
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class ObserverSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let id: UUID, hub: ObserverHub
    private var tail: Task<Void, Never>?
    private var window = Date(), controls = 0, expensive = 0
    init(id: UUID, hub: ObserverHub) { self.id = id; self.hub = hub }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        tail = Task { await hub.add(id, channel: channel) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            if Date().timeIntervalSince(window) >= 1 { window = Date(); controls = 0; expensive = 0 }
            controls += 1
            let bytes = Data(frame.unmaskedData.readableBytesView)
            if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               ["subscribe", "resync", "resume", "pause", "mode"].contains(object["type"] as? String ?? "") { expensive += 1 }
            // A 30 FPS consumer sends 30 ACKs/second, plus heartbeat/lifecycle controls.
            guard controls <= 64, expensive <= 4, bytes.count <= ObserverLimits.maxControlBytes else {
                context.close(promise: nil); return
            }
            let previous = tail
            tail = Task { await previous?.value; await hub.control(id, data: bytes) }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .pong: break
        case .connectionClose:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)))
                .whenComplete { _ in context.close(promise: nil) }
        default: context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        let previous = tail
        tail = Task { await previous?.value; await hub.remove(id) }
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
