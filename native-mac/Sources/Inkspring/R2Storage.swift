import CryptoKit
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

struct R2Configuration: Codable, Equatable, Sendable {
    var accountId: String
    var bucket: String
    var jurisdiction: String

    var host: String {
        accountId + (jurisdiction == "default" ? "" : "." + jurisdiction) + ".r2.cloudflarestorage.com"
    }

    var identity: [String] { [accountId, bucket, jurisdiction] }

    func validate() throws {
        guard accountId.range(of: #"\A[a-f0-9]{32}\z"#, options: .regularExpression) != nil else {
            throw WorkspaceError("Enter the 32-character Cloudflare account ID.")
        }
        guard bucket.range(of: #"\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z"#, options: .regularExpression) != nil else {
            throw WorkspaceError("Use a bucket name with 3–63 lowercase letters, numbers, or hyphens.")
        }
        guard ["default", "eu", "us", "fedramp"].contains(jurisdiction) else {
            throw WorkspaceError("Choose the bucket’s R2 jurisdiction.")
        }
    }
}

struct R2Profile: Codable, Sendable {
    let configuration: R2Configuration
    let accessKeyId: String
    let secretAccessKey: String

    func validate() throws {
        try configuration.validate()
        guard accessKeyId.range(of: #"\A[A-Za-z0-9_-]{16,256}\z"#, options: .regularExpression) != nil,
              secretAccessKey.range(of: #"\A[A-Za-z0-9/+=_-]{32,1024}\z"#, options: .regularExpression) != nil else {
            throw WorkspaceError("Enter the S3 Access Key ID and Secret Access Key from Cloudflare R2.")
        }
    }

    private static let query: [String: String] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.protomota.inkspring.native.r2",
        kSecAttrAccount as String: "configuration"
    ]

    static func saved() throws -> Self? {
        var attributes: [String: Any] = query
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let profile = try? JSONDecoder().decode(Self.self, from: data) else {
            throw WorkspaceError("The saved R2 connection could not be read. Configure it again.")
        }
        try profile.validate()
        return profile
    }

    func save(replaceExisting: Bool = true) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        let status = replaceExisting
            ? SecItemUpdate(Self.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            : errSecItemNotFound
        if status == errSecItemNotFound {
            var attributes: [String: Any] = Self.query
            attributes[kSecValueData as String] = data
            let added = SecItemAdd(attributes as CFDictionary, nil)
            if !replaceExisting, added == errSecDuplicateItem {
                throw WorkspaceError("An R2 connection is already saved. Request a replacement to change it.")
            }
            try Self.check(added)
        } else { try Self.check(status) }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw WorkspaceError("Keychain could not access the R2 connection (\(status)).") }
    }
}

struct R2Signer {
    static let prefix = "inkspring-instagram/"
    static let expires: TimeInterval = 7200
    let profile: R2Profile

    static func validateKey(_ key: String) throws {
        guard key.hasPrefix(prefix), key.utf8.count <= 200, !key.contains(".."),
              key.range(of: #"\A[A-Za-z0-9/._-]+\z"#, options: .regularExpression) != nil else {
            throw WorkspaceError("Choose media uploaded by Inkspring.")
        }
    }

    func signedRequest(method: String, key: String, hash: String, contentType: String? = nil,
                       now: Date = .now) throws -> URLRequest {
        try Self.validateKey(key)
        let host = profile.configuration.host
        let path = "/" + profile.configuration.bucket + "/" + key
        let date = Self.date(now)
        let scope = Self.scope(date)
        let signed = "host;x-amz-content-sha256;x-amz-date"
        let headers = "host:\(host)\nx-amz-content-sha256:\(hash)\nx-amz-date:\(date)\n"
        let canonical = [method, path, "", headers, signed, hash].joined(separator: "\n")
        let signature = signature(canonical, date: date, scope: scope)
        let url = URL(string: "https://" + host + path)!
        var request = URLRequest(url: url, timeoutInterval: method == "PUT" ? 1800 : 30)
        request.httpMethod = method
        request.setValue(hash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        request.setValue(date, forHTTPHeaderField: "X-Amz-Date")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(profile.accessKeyId)/\(scope), SignedHeaders=\(signed), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    func link(_ key: String, now: Date = .now) throws -> URL {
        try Self.validateKey(key)
        let host = profile.configuration.host
        let path = "/" + profile.configuration.bucket + "/" + key
        let date = Self.date(now)
        let scope = Self.scope(date)
        let pairs = [
            "X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": profile.accessKeyId + "/" + scope,
            "X-Amz-Date": date, "X-Amz-Expires": String(Int(Self.expires)), "X-Amz-SignedHeaders": "host"
        ]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = pairs.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        let canonical = ["GET", path, query, "host:\(host)\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let signed = signature(canonical, date: date, scope: scope)
        return URL(string: "https://" + host + path + "?" + query + "&X-Amz-Signature=" + signed)!
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func date(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: now)
    }

    private static func scope(_ date: String) -> String { String(date.prefix(8)) + "/auto/s3/aws4_request" }

    private func signature(_ canonical: String, date: String, scope: String) -> String {
        func hmac(_ secret: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: secret)))
        }
        let day = hmac(Data(("AWS4" + profile.secretAccessKey).utf8), String(date.prefix(8)))
        let region = hmac(day, "auto")
        let service = hmac(region, "s3")
        let key = hmac(service, "aws4_request")
        let input = ["AWS4-HMAC-SHA256", date, scope, Self.sha(Data(canonical.utf8))].joined(separator: "\n")
        return hmac(key, input).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
struct R2Client {
    struct Media {
        let key: String
        let type: String
        let size: Int64
        let name: String
    }

    typealias Send = @MainActor (URLRequest, URL?) async throws -> (Data, HTTPURLResponse)
    static let types = [".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp",
                        ".mp4": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm"]
    let profile: R2Profile
    var send: Send = live

    private var signer: R2Signer { R2Signer(profile: profile) }

    func link(_ key: String) throws -> URL { try signer.link(key) }

    func upload(_ file: URL) async throws -> Media {
        let ext = "." + file.pathExtension.lowercased()
        guard let type = Self.types[ext] else { throw WorkspaceError("Choose a PNG, JPEG, WebP, MP4, MOV, or WebM.") }
        let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else {
            throw WorkspaceError("Choose a regular media file.")
        }
        let digest = try await Task.detached(priority: .utility) { try fileDigest(file) }.value
        guard digest.size > 0 else { throw WorkspaceError("The file is empty.") }
        try verify(file, size: digest.size, date: attrs.contentModificationDate)
        let key = R2Signer.prefix + "media/" + digest.hash + ext
        _ = try await request("PUT", key: key, type: type, hash: digest.hash, file: file)
        try verify(file, size: digest.size, date: attrs.contentModificationDate)
        return Media(key: key, type: type, size: digest.size, name: file.lastPathComponent)
    }

    func uploadInstagram(_ image: URL, hash: String) async throws -> Media {
        let attrs = try image.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (1...20_000_000).contains(attrs.fileSize ?? 0) else {
            throw WorkspaceError("Choose a local image up to 20 MB.")
        }
        let input = try Data(contentsOf: image)
        guard input.count <= 20_000_000, R2Signer.sha(input) == hash,
              let source = CGImageSourceCreateWithData(input as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1440
              ] as CFDictionary) else { throw WorkspaceError("The image changed or could not be read. Review it again.") }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw WorkspaceError("Couldn’t encode the Instagram photo.")
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination), jpeg.length <= 8_000_000 else {
            throw WorkspaceError("Choose a smaller photo.")
        }
        let bytes = jpeg as Data
        let digest = R2Signer.sha(bytes)
        let key = R2Signer.prefix + "media/" + digest + ".jpg"
        _ = try await request("PUT", key: key, type: "image/jpeg", hash: digest, bytes: bytes)
        return Media(key: key, type: "image/jpeg", size: Int64(bytes.count), name: "Instagram image.jpg")
    }

    func test() async throws {
        let key = R2Signer.prefix + "connection-check/" + UUID().uuidString.lowercased() + ".txt"
        let bytes = Data("Inkspring R2 connection check".utf8)
        var failure: Error?
        do {
            _ = try await request("PUT", key: key, type: "text/plain", hash: R2Signer.sha(bytes), bytes: bytes)
            let response = try await request("GET", key: key)
            guard response == bytes else { throw WorkspaceError("R2 returned unexpected connection-test data.") }
        } catch { failure = error }
        do { _ = try await request("DELETE", key: key) }
        catch { if failure == nil { failure = WorkspaceError("R2 read and write worked. Check permission to remove the test object.") } }
        if let failure { throw failure }
    }

    private func request(_ method: String, key: String, type: String? = nil, hash: String? = nil,
                         bytes: Data? = nil, file: URL? = nil) async throws -> Data {
        var request = try signer.signedRequest(method: method, key: key, hash: hash ?? R2Signer.sha(Data()), contentType: type)
        request.httpBody = bytes
        let result: (Data, HTTPURLResponse)
        do { result = try await send(request, file) }
        catch { throw WorkspaceError("Couldn’t reach the R2 bucket. Check the account ID, bucket, and jurisdiction.") }
        guard (200...299).contains(result.1.statusCode) else {
            throw WorkspaceError("R2 returned HTTP \(result.1.statusCode). Check the bucket-scoped key and permissions.")
        }
        return result.0
    }

    private func verify(_ file: URL, size: Int64, date: Date?) throws {
        let current = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard current.fileSize == Int(size), current.contentModificationDate == date else {
            throw WorkspaceError("The media changed during upload. Choose the finished file again.")
        }
    }

    private static func live(_ request: URLRequest, _ file: URL?) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config, delegate: NoHTTPRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        if let file {
            let (data, response) = try await session.upload(for: request, fromFile: file)
            guard let response = response as? HTTPURLResponse, data.count <= 65_536 else {
                throw WorkspaceError("R2 returned an unreadable response.")
            }
            return (data, response)
        }
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse, raw.expectedContentLength <= 65_536 else {
            throw WorkspaceError("R2 returned an unreadable response.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw WorkspaceError("R2 returned an oversized response.") }
            data.append(byte)
        }
        return (data, response)
    }
}
