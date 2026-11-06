import CryptoKit
import Foundation
import XCTest
@testable import TerminalMacTracing

private final class MediaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: [URLRequest] = []
    static func reset() { lock.lock(); stored = []; lock.unlock() }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock(); Self.stored.append(captured); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "PATCH" ? 204 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod == "POST" {
            client?.urlProtocol(self, didLoad: Data("{\"mediaId\":\"test-media\",\"uploadUrl\":\"https://storage.example.com/image?signature=private\"}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TracingMediaTests: XCTestCase {
    private let env = ["LANGFUSE_BASE_URL": "https://example.com/prefix", "LANGFUSE_PUBLIC_KEY": "pk-test", "LANGFUSE_SECRET_KEY": "sk-test",
                       "LANGFUSE_MEDIA_ENABLED": "true", "LANGFUSE_MEDIA_UPLOAD_HOSTS": "storage.example.com"]

    func testMediaAPIAndStorageHeadersAreSeparated() async throws {
        MediaProtocol.reset()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MediaProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let config = try XCTUnwrap(LangfuseConfiguration.load(env))
        let pixels = Data([0, 1, 2, 3])
        let token = try await TracingMedia(configuration: config, session: session).upload(pixels, mimeType: "image/png", traceID: "trace", observationID: "observation")
        XCTAssertEqual(token, "@@@langfuseMedia:type=image/png|id=test-media|source=bytes@@@")
        let requests = MediaProtocol.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "PATCH"])
        XCTAssertEqual(requests[0].url?.path, "/prefix/api/public/media")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), config.authorization)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["sha256Hash"] as? String, Data(SHA256.hash(data: pixels)).base64EncodedString())
        XCTAssertEqual(body["observationId"] as? String, "observation")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "x-amz-checksum-sha256"), body["sha256Hash"] as? String)
        XCTAssertEqual(requests[2].url?.path, "/prefix/api/public/media/test-media")
    }

    func testMediaURLAllowlistRejectsRedirectDestinationsAndCredentials() throws {
        let config = try XCTUnwrap(LangfuseConfiguration.load(env))
        XCTAssertNoThrow(try TracingMedia.allowedUploadURL("https://storage.example.com/image?signature=value", configuration: config))
        for url in ["https://evil.example/image", "http://storage.example.com/image", "https://user:pass@storage.example.com/image", "file:///tmp/image", "https://storage.example.com/image#fragment"] {
            XCTAssertThrowsError(try TracingMedia.allowedUploadURL(url, configuration: config))
        }
        XCTAssertFalse(try XCTUnwrap(LangfuseConfiguration.load(env.merging(["LANGFUSE_MEDIA_ENABLED": "false"]) { $1 })).mediaEnabled)
    }

    func testOversizedMediaDoesNotSendARequest() async throws {
        MediaProtocol.reset()
        let config = try XCTUnwrap(LangfuseConfiguration.load(env))
        do {
            _ = try await TracingMedia(configuration: config).upload(Data(repeating: 0, count: TracingMedia.maxBytes + 1), mimeType: "image/png", traceID: "trace", observationID: "obs")
            XCTFail("Expected size rejection")
        } catch {}
        XCTAssertTrue(MediaProtocol.requests.isEmpty)
    }
}
