import CryptoKit
import Foundation
import TerminalMacCore

struct TracingMedia {
    static let maxBytes = 2 * 1024 * 1024
    let configuration: LangfuseConfiguration
    private let session: URLSession
    private let ownsSession: Bool

    init(configuration: LangfuseConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        ownsSession = session == nil
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        self.session = session ?? URLSession(configuration: settings, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func upload(_ data: Data, mimeType: String, traceID: String, observationID: String) async throws -> String {
        defer { if ownsSession { session.finishTasksAndInvalidate() } }
        guard !data.isEmpty, data.count <= Self.maxBytes, ["image/png", "image/jpeg"].contains(mimeType) else {
            throw Failure("Screenshot exceeds the tracing media limit or has an unsupported format.")
        }
        let hash = Data(SHA256.hash(data: data)).base64EncodedString()
        let endpoint = configuration.endpoint.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("media")
        let response = try await request(endpoint, method: "POST", object: ["traceId": traceID, "observationId": observationID,
            "contentType": mimeType, "contentLength": data.count, "sha256Hash": hash, "field": "metadata"])
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let mediaID = object["mediaId"] as? String,
              mediaID.range(of: "^[a-zA-Z0-9_-]{1,100}$", options: .regularExpression) != nil else {
            throw Failure("Invalid Langfuse media response.")
        }
        if let url = object["uploadUrl"] as? String {
            let uploadURL = try Self.allowedUploadURL(url, configuration: configuration)
            var upload = URLRequest(url: uploadURL, timeoutInterval: 2)
            upload.httpMethod = "PUT"
            upload.httpShouldHandleCookies = false
            upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            upload.setValue(hash, forHTTPHeaderField: "x-amz-checksum-sha256")
            // No project authorization or cookies are attached to the presigned storage request.
            let (_, uploaded) = try await session.upload(for: upload, from: data)
            guard let http = uploaded as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw Failure("Langfuse media storage upload failed.")
            }
            _ = try await request(endpoint.appendingPathComponent(mediaID), method: "PATCH",
                object: ["uploadedAt": ISO8601DateFormatter().string(from: Date()), "uploadHttpStatus": http.statusCode])
        }
        return "@@@langfuseMedia:type=\(mimeType)|id=\(mediaID)|source=bytes@@@"
    }

    private func request(_ url: URL, method: String, object: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(configuration.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 64 * 1024 else {
            throw Failure("Langfuse media API is unavailable.")
        }
        return data
    }

    static func allowedUploadURL(_ raw: String, configuration: LangfuseConfiguration) throws -> URL {
        guard let parts = URLComponents(string: raw), let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url,
              parts.scheme == "https" || (parts.scheme == "http" && configuration.endpoint.scheme == "http") else {
            throw Failure("Unsafe Langfuse media upload URL.")
        }
        guard host == configuration.endpoint.host?.lowercased() || configuration.mediaUploadHosts.contains(host) else {
            throw Failure("Media storage host is not explicitly allowed; configure LANGFUSE_MEDIA_UPLOAD_HOSTS.")
        }
        return url
    }
}
