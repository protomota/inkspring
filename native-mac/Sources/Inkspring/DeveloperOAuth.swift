import CryptoKit
import Foundation

struct DeveloperOAuthConfiguration: Codable, Equatable {
    var clientID: String
    var clientSecret: String
    var linkedInPages = false

    func validate(_ platform: SocialPlatform) throws {
        guard (1...300).contains(clientID.utf8.count), clientSecret.utf8.count <= 4096,
              !(clientID + clientSecret).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !platform.needsClientSecret || !clientSecret.isEmpty else {
            throw WorkspaceError("Enter the developer app’s client ID and required secret.")
        }
    }
}

extension SocialPlatform {
    var needsClientSecret: Bool { [.linkedin, .instagram, .tiktok].contains(self) }
    var usesLoopback: Bool { [.x, .reddit, .tiktok].contains(self) }

    var developerCallback: URL {
        URL(string: usesLoopback ? "http://127.0.0.1:43821/oauth/" + rawValue : "https://inkspring.ai/desktop-connect/")!
    }

    var developerConsole: URL {
        let address = switch self {
        case .x: "https://console.x.com/"
        case .reddit: "https://www.reddit.com/prefs/apps"
        case .linkedin: "https://www.linkedin.com/developers/apps"
        case .instagram: "https://developers.facebook.com/apps/"
        case .tiktok: "https://developers.tiktok.com/apps/"
        }
        return URL(string: address)!
    }

    fileprivate var authorizeURL: URL {
        let address = switch self {
        case .x: "https://x.com/i/oauth2/authorize"
        case .reddit: "https://www.reddit.com/api/v1/authorize"
        case .linkedin: "https://www.linkedin.com/oauth/v2/authorization"
        case .instagram: "https://www.instagram.com/oauth/authorize"
        case .tiktok: "https://www.tiktok.com/v2/auth/authorize/"
        }
        return URL(string: address)!
    }

    fileprivate var tokenURL: URL {
        let address = switch self {
        case .x: "https://api.x.com/2/oauth2/token"
        case .reddit: "https://www.reddit.com/api/v1/access_token"
        case .linkedin: "https://www.linkedin.com/oauth/v2/accessToken"
        case .instagram: "https://api.instagram.com/oauth/access_token"
        case .tiktok: "https://open.tiktokapis.com/v2/oauth/token/"
        }
        return URL(string: address)!
    }

    fileprivate var clientField: String { self == .tiktok ? "client_key" : "client_id" }

    fileprivate func scopes(_ configuration: DeveloperOAuthConfiguration) -> String {
        switch self {
        case .x: "tweet.read tweet.write users.read media.write offline.access"
        case .reddit: "identity submit read"
        case .linkedin: configuration.linkedInPages
            ? "openid profile w_member_social rw_organization_admin w_organization_social"
            : "openid profile w_member_social"
        case .instagram: "instagram_business_basic,instagram_business_content_publish"
        case .tiktok: "user.info.basic,video.publish"
        }
    }
}

struct DeveloperOAuth {
    let platform: SocialPlatform
    let configuration: DeveloperOAuthConfiguration
    let state: String
    private let verifier: String

    init(platform: SocialPlatform, configuration: DeveloperOAuthConfiguration) throws {
        try configuration.validate(platform)
        self.platform = platform
        self.configuration = configuration
        let nonce = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        state = platform.rawValue + "." + nonce.base64URL
        verifier = (Curve25519.KeyAgreement.PrivateKey().rawRepresentation
            + Curve25519.KeyAgreement.PrivateKey().rawRepresentation).base64URL
    }

    var url: URL {
        var fields = [
            platform.clientField: configuration.clientID, "redirect_uri": platform.developerCallback.absoluteString,
            "response_type": "code", "scope": platform.scopes(configuration), "state": state
        ]
        if [.x, .tiktok].contains(platform) {
            let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
            fields["code_challenge"] = platform == .tiktok
                ? digest.map { String(format: "%02x", $0) }.joined() : digest.base64URL
            fields["code_challenge_method"] = "S256"
        }
        if platform == .reddit { fields["duration"] = "permanent" }
        if platform == .instagram {
            fields["enable_fb_login"] = "0"
            fields["force_authentication"] = "1"
        }
        return platform.authorizeURL.appending(queryItems: fields.map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    func callbackCode(_ url: URL) throws -> String {
        guard url.absoluteString.utf8.count <= 12_000, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil,
              let query = components.queryItems,
              query.filter({ $0.name == "state" }).map(\.value) == [state] else {
            throw WorkspaceError("The sign-in return belongs to another session.")
        }
        if platform.usesLoopback {
            guard components.scheme == "http", components.host == "127.0.0.1", components.port == 43821,
                  components.path == platform.developerCallback.path else { throw WorkspaceError("Unexpected sign-in return address.") }
        } else {
            guard components.scheme == "inkspring", components.host == "oauth", components.port == nil,
                  components.path == "/" + platform.rawValue else { throw WorkspaceError("Unexpected sign-in return address.") }
        }
        if query.contains(where: { $0.name == "error" }) { throw CancellationError() }
        let codes = query.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, (1...8000).contains(code.utf8.count),
              !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceError("The provider didn’t return a valid authorization code.")
        }
        return code
    }

    @MainActor
    func exchange(_ callback: URL, transport: SocialTransport) async throws -> ManagedSocialSession {
        let code = try callbackCode(callback)
        var fields = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": platform.developerCallback.absoluteString,
            platform.clientField: configuration.clientID
        ]
        if [.x, .tiktok].contains(platform) { fields["code_verifier"] = verifier }
        let session = try await Self.token(platform, configuration: configuration, fields: fields, old: nil, transport: transport)
        if platform == .instagram {
            let url = URL(string: "https://graph.instagram.com/access_token")!.appending(queryItems: [
                .init(name: "grant_type", value: "ig_exchange_token"),
                .init(name: "client_secret", value: configuration.clientSecret),
                .init(name: "access_token", value: session.accessToken)
            ])
            let (value, _) = try await transport.request(url)
            return try Self.parseToken(value, old: session)
        }
        return session
    }

    @MainActor
    static func refresh(_ platform: SocialPlatform, configuration: DeveloperOAuthConfiguration,
                        session: ManagedSocialSession, transport: SocialTransport) async throws -> ManagedSocialSession {
        guard let refresh = session.refreshToken, !refresh.isEmpty, platform != .instagram else {
            throw WorkspaceError("This account needs to sign in again.")
        }
        return try await token(platform, configuration: configuration, fields: [
            "grant_type": "refresh_token", "refresh_token": refresh, platform.clientField: configuration.clientID
        ], old: session, transport: transport)
    }

    @MainActor
    private static func token(_ platform: SocialPlatform, configuration: DeveloperOAuthConfiguration, fields: [String: String],
                              old: ManagedSocialSession?, transport: SocialTransport) async throws -> ManagedSocialSession {
        var fields = fields
        var headers: [String: String] = [:]
        if platform == .reddit || platform == .x && !configuration.clientSecret.isEmpty {
            let secret = platform == .reddit ? "" : configuration.clientSecret
            headers["Authorization"] = "Basic " + Data((configuration.clientID + ":" + secret).utf8).base64EncodedString()
        }
        if platform == .reddit {
            headers["User-Agent"] = "desktop:com.protomota.inkspring:v1.0 (Inkspring; https://inkspring.ai)"
        }
        if platform.needsClientSecret { fields["client_secret"] = configuration.clientSecret }
        let (value, _) = try await transport.form(platform.tokenURL, values: fields, headers: headers)
        return try parseToken(value, old: old)
    }

    private static func parseToken(_ response: [String: Any], old: ManagedSocialSession?) throws -> ManagedSocialSession {
        let value = (response["data"] as? [[String: Any]])?.first ?? response
        guard let token = value["access_token"] as? String else {
            throw WorkspaceError("The platform did not authorize the developer app.")
        }
        let duration = value["expires_in"] as? Int64 ?? 3600
        guard (1...31_536_000).contains(duration) else { throw WorkspaceError("The platform returned an invalid token lifetime.") }
        let session = ManagedSocialSession(
            accessToken: token, refreshToken: value["refresh_token"] as? String ?? old?.refreshToken, managedTicket: nil,
            expiresAt: Int64(Date.now.timeIntervalSince1970 * 1000) + duration * 1000,
            scopes: value["scope"] as? String ?? value["permissions"] as? String ?? old?.scopes
        )
        try session.validate()
        return session
    }
}
