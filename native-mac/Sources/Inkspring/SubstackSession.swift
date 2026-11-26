import Foundation
import WebKit

@MainActor
final class SubstackSession {
    lazy var storage = DailyBackup.usesTestWorkspace
        ? WKWebsiteDataStore.nonPersistent()
        : WKWebsiteDataStore(forIdentifier: UUID(uuidString: "CCB7C9C0-5EBA-4287-8C24-F910B2A468F3")!)
    private var nextRequest = ContinuousClock.now
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoHTTPRedirects(), delegateQueue: nil)
    }()

    static func host(_ url: URL) -> String? {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host(), host == "substack.com" ||
              host.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.substack\.com$"#, options: .regularExpression) != nil else { return nil }
        return host
    }

    static func loginAddress(_ url: URL) -> Bool {
        host(url) != nil || (url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil &&
            ["accounts.google.com", "appleid.apple.com"].contains(url.host() ?? ""))
    }

    func clear() async {
        await storage.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func request(_ method: String, _ url: URL, _ payload: [String: Any]?) async throws -> [String: Any] {
        guard let host = Self.host(url) else { throw WorkspaceError("This request requires a Substack address.") }
        try await ContinuousClock().sleep(until: nextRequest)
        nextRequest = ContinuousClock.now + .seconds(1)
        let cookies = await storage.httpCookieStore.allCookies().filter { cookie in
            guard cookie.expiresDate.map({ $0 > Date.now }) ?? true else { return false }
            let domain = cookie.domain.lowercased()
            let domainMatches = host == domain || (domain.hasPrefix(".") && ("." + host).hasSuffix(domain))
            let path = cookie.path
            let pathMatches = url.path == path || url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/")
            return domainMatches && pathMatches
        }
        guard cookies.contains(where: { ["substack.sid", "connect.sid"].contains($0.name) }) else {
            throw WorkspaceError("Sign in to Substack in Connections.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await network.bytes(for: request) }
        catch { throw SubstackRequestError("Substack did not confirm the request. Check its editor before trying again.", uncertain: method != "GET") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401, 403: throw WorkspaceError("Sign in to Substack again and check your publication permissions.")
        case 429: throw WorkspaceError("Substack is limiting requests. Wait a few minutes before trying again.")
        default: throw SubstackRequestError("Substack returned HTTP \(status).", uncertain: method != "GET" && (status < 400 || status >= 500))
        }
        do {
            let limit = 5_000_000
            guard response.expectedContentLength <= limit else { throw WorkspaceError("Substack returned too much data.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw WorkspaceError("Substack returned too much data.") }
                data.append(byte)
            }
            if data.isEmpty { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WorkspaceError("Substack returned an unreadable response.")
            }
            return object
        } catch {
            throw SubstackRequestError("Substack returned an unreadable response. Check its editor before trying again.", uncertain: method != "GET")
        }
    }
}

struct SubstackRequestError: LocalizedError {
    let errorDescription: String?
    let uncertain: Bool

    init(_ message: String, uncertain: Bool) {
        errorDescription = message
        self.uncertain = uncertain
    }
}
