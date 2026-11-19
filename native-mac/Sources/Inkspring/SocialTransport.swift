import Foundation

struct SocialRequestError: LocalizedError {
    let errorDescription: String?
    let uncertain: Bool
    let statusCode: Int?

    init(_ message: String, uncertain: Bool = false, statusCode: Int? = nil) {
        errorDescription = message
        self.uncertain = uncertain
        self.statusCode = statusCode
    }
}

@MainActor
struct SocialTransport {
    typealias Send = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let send: Send

    init(send: @escaping Send = live) { self.send = send }

    func request(_ url: URL, token: String? = nil, method: String = "GET",
                 json: [String: Any]? = nil, body: Data? = nil, headers: [String: String] = [:],
                 publishes: Bool = false, expectsJSON: Bool = true, timeout: TimeInterval = 45, acceptsArray: Bool = false) async throws -> (value: [String: Any], response: HTTPURLResponse) {
        guard url.scheme == "https", url.user == nil, url.password == nil else {
            throw SocialRequestError("Invalid social service address.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            request.httpBody = body
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await send(request) }
        catch {
            throw SocialRequestError(publishes ? "The connection ended during publishing. Check the account before trying again."
                                     : "Couldn’t reach the social service.", uncertain: publishes)
        }
        guard (200...299).contains(response.statusCode) else {
            let uncertain = publishes && (response.statusCode >= 500 || [408, 409, 425].contains(response.statusCode))
            let message = switch response.statusCode {
            case 401, 403: "The account or requested permission was declined. Check Connections."
            case 429: "The platform reached a rate limit. Wait before retrying."
            default: "The social service returned HTTP \(response.statusCode)."
            }
            throw SocialRequestError(message, uncertain: uncertain, statusCode: response.statusCode)
        }
        if data.isEmpty || !expectsJSON { return ([:], response) }
        let decoded = try? JSONSerialization.jsonObject(with: data)
        if acceptsArray, let list = decoded as? [Any] { return (["items": list], response) }
        guard let value = decoded as? [String: Any] else {
            throw SocialRequestError("The service returned an unreadable response.", uncertain: publishes)
        }
        return (value, response)
    }

    func form(_ url: URL, token: String? = nil, values: [String: String], headers: [String: String] = [:],
              publishes: Bool = false) async throws -> (value: [String: Any], response: HTTPURLResponse) {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let fields = values.sorted { $0.key < $1.key }.map { pair in
            let name = pair.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = pair.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return name + "=" + value
        }.joined(separator: "&")
        var headers = headers
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        return try await request(url, token: token, method: "POST", body: Data(fields.utf8), headers: headers, publishes: publishes)
    }

    private static func live(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = max(60, request.timeoutInterval)
        let session = URLSession(configuration: config, delegate: NoHTTPRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse, response.expectedContentLength <= 4_194_304 else {
            throw SocialRequestError("The service returned an invalid response.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4_194_304 else { throw SocialRequestError("The service response is too large.") }
            data.append(byte)
        }
        return (data, response)
    }
}
