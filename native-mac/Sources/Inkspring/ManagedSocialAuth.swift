import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum SocialPlatform: String, CaseIterable, Identifiable {
    case x, linkedin, instagram, reddit, tiktok

    var id: Self { self }
    var name: String { platformName(rawValue) }

    var identityURL: URL {
        let address = switch self {
        case .x: "https://api.x.com/2/users/me"
        case .linkedin: "https://api.linkedin.com/v2/userinfo"
        case .instagram: "https://graph.instagram.com/v25.0/me?fields=user_id,username,account_type"
        case .reddit: "https://oauth.reddit.com/api/v1/me"
        case .tiktok: "https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name,avatar_url"
        }
        return URL(string: address)!
    }
}

struct ManagedSocialSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let managedTicket: String?
    let expiresAt: Int64
    let scopes: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, managedTicket, expiresAt, scopes
    }

    init(accessToken: String, refreshToken: String?, managedTicket: String?, expiresAt: Int64, scopes: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.managedTicket = managedTicket
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try fields.decode(String.self, forKey: .accessToken)
        refreshToken = try fields.decodeIfPresent(String.self, forKey: .refreshToken)
        managedTicket = try fields.decodeIfPresent(String.self, forKey: .managedTicket)
        expiresAt = try fields.decode(Int64.self, forKey: .expiresAt)
        if let permissions = try? fields.decode([String].self, forKey: .scopes) {
            scopes = permissions.joined(separator: ",")
        } else {
            scopes = try fields.decodeIfPresent(String.self, forKey: .scopes)
        }
    }

    func validate(now: Date = .now) throws {
        guard !accessToken.isEmpty, accessToken.utf8.count <= 24_000,
              (refreshToken?.utf8.count ?? 0) <= 12_000, (managedTicket?.utf8.count ?? 0) <= 12_000,
              (scopes?.utf8.count ?? 0) <= 5000, expiration > now else {
            throw WorkspaceError("The platform returned an incomplete connection. Connect again.")
        }
    }

    var expiration: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }
}

struct ManagedSocialAccount: Codable, Sendable {
    var session: ManagedSocialSession
    let id: String
    let name: String
    let username: String
    var ownApp: Bool? = nil
    var linkedInPages: [LinkedInDestination]? = nil
    var connectedAt: String? = nil
    var connectionKey: String { id + ":" + (connectedAt ?? "") }
}

struct ManagedOAuthHandshake {
    static let base = URL(string: "https://inkspring.ai/api/desktop/connect/")!
    private static let purpose = Data("inkspring-desktop-result-v1".utf8)
    private static let x25519Prefix = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x6E, 0x03, 0x21, 0x00])
    private static let ed25519Prefix = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00])

    let platform: SocialPlatform
    let state: String
    private let key: Curve25519.KeyAgreement.PrivateKey
    private let signing: Curve25519.Signing.PublicKey

    init(platform: SocialPlatform, signingKey: String) throws {
        self.platform = platform
        key = Curve25519.KeyAgreement.PrivateKey()
        signing = try Curve25519.Signing.PublicKey(rawRepresentation: Self.rawKey(signingKey, prefix: Self.ed25519Prefix))
        var entropy = Data(count: 32)
        let result = entropy.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { throw WorkspaceError("Couldn’t create a secure sign-in request.") }
        state = platform.rawValue + "." + entropy.base64URL
    }

    var url: URL {
        Self.base.appending(path: "start").appending(queryItems: [
            URLQueryItem(name: "provider", value: platform.rawValue),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "publicKey", value: (Self.x25519Prefix + key.publicKey.rawRepresentation).base64URL)
        ])
    }

    private struct Envelope: Decodable {
        let v: Int
        let key: String
        let iv: String
        let data: String
        let tag: String
        let signature: String

        var signedBytes: Data {
            Data(#"{"v":1,"key":"\#(key)","iv":"\#(iv)","data":"\#(data)","tag":"\#(tag)"}"#.utf8)
        }
    }

    private struct Result: Decodable {
        let provider: String
        let state: String
        let expiresAt: Int64
        let error: String?
        let session: ManagedSocialSession?
    }

    func open(_ callback: URL, now: Date = .now) throws -> ManagedSocialSession {
        guard callback.absoluteString.utf8.count < 100_000,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == "inkspring", components.host == "oauth", components.port == nil,
              components.user == nil, components.password == nil, components.path == "/" + platform.rawValue,
              components.queryItems?.filter({ $0.name == "state" }).map(\.value) == [state] else {
            throw WorkspaceError("This sign-in belongs to another session. Connect again.")
        }
        if components.queryItems?.contains(where: { $0.name == "error" }) == true {
            throw WorkspaceError("Sign-in was declined. Your previous connection is unchanged.")
        }
        guard let fragment = components.percentEncodedFragment,
              let results = URLComponents(string: "https://inkspring.ai/?" + fragment)?.queryItems?.filter({ $0.name == "result" }),
              results.count == 1, let text = results.first?.value, text.utf8.count <= 96_000 else {
            throw WorkspaceError("The connection return was incomplete. Connect again.")
        }
        let result: Result
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(base64URL: text))
            let ciphertext = try Data(base64URL: envelope.data)
            let tag = try Data(base64URL: envelope.tag)
            let iv = try Data(base64URL: envelope.iv)
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Self.rawKey(envelope.key, prefix: Self.x25519Prefix))
            guard envelope.v == 1, iv.count == 12, tag.count == 16,
                  signing.isValidSignature(try Data(base64URL: envelope.signature), for: envelope.signedBytes) else {
                throw WorkspaceError("Invalid sign-in signature.")
            }
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
                .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Self.purpose, outputByteCount: 32)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            result = try JSONDecoder().decode(Result.self, from: AES.GCM.open(box, using: secret, authenticating: Self.purpose))
        } catch {
            throw WorkspaceError("The connection return could not be verified. Connect again.")
        }
        guard result.provider == platform.rawValue, result.state == state,
              Double(result.expiresAt) / 1000 > now.timeIntervalSince1970 else {
            throw WorkspaceError("The sign-in expired or belongs to another session.")
        }
        if let error = result.error { throw WorkspaceError(error) }
        guard let session = result.session else {
            throw WorkspaceError("The connection service could not authorize this account.")
        }
        try session.validate(now: now)
        return session
    }

    private static func rawKey(_ value: String, prefix: Data) throws -> Data {
        let bytes = try Data(base64URL: value)
        guard bytes.count == prefix.count + 32, bytes.starts(with: prefix) else {
            throw WorkspaceError("The connection service returned an invalid public key.")
        }
        return Data(bytes.dropFirst(prefix.count))
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    fileprivate init(base64URL: String) throws {
        guard !base64URL.isEmpty, base64URL.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw WorkspaceError("Invalid sign-in encoding.") }
        let padded = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - base64URL.utf8.count % 4) % 4)
        guard let result = Data(base64Encoded: padded), result.base64URL == base64URL else {
            throw WorkspaceError("Invalid sign-in encoding.")
        }
        self = result
    }
}

@MainActor @Observable
final class ManagedSocialAccounts: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Profile: Equatable {
        let id: String
        let name: String
        let username: String
        let usesDeveloperApp: Bool

        var displayName: String { username.isEmpty ? name : username }
    }

    private(set) var profiles: [SocialPlatform: Profile] = [:]
    private(set) var availability: Set<SocialPlatform> = []
    private(set) var developerAppIDs: [SocialPlatform: String] = [:]
    private(set) var developerPages = false
    private(set) var linkedInDestinations: [LinkedInDestination] = []
    private(set) var connecting: SocialPlatform?
    private var signingKey = ""
    private var browserSession: ASWebAuthenticationSession?
    private var loopback: LoopbackOAuth?
    private var signInTimeout: Task<Void, Never>?
    private var refreshes: [SocialPlatform: Task<ManagedSocialAccount, Error>] = [:]
    private var revisions: [SocialPlatform: UUID] = [:]
    private let transport: SocialTransport

    init(transport: SocialTransport = SocialTransport()) {
        self.transport = transport
    }

    func loadSavedConnections() throws {
        for platform in SocialPlatform.allCases where profiles[platform] == nil {
            if let account = try SocialAccountKeychain.read(platform) {
                profiles[platform] = profile(account)
                if platform == .linkedin { setLinkedInDestinations(account) }
            }
        }
        for platform in SocialPlatform.allCases {
            if let configuration = try SocialAccountKeychain.configuration(platform) {
                developerAppIDs[platform] = configuration.clientID
                if platform == .linkedin { developerPages = configuration.linkedInPages }
            }
        }
    }

    func load() async throws {
        try loadSavedConnections()
        let (result, _) = try await transport.request(ManagedOAuthHandshake.base.appending(path: "config"))
        guard result["version"] as? Int == 1, let signingKey = result["signingKey"] as? String,
              signingKey.utf8.count <= 100, let providers = result["providers"] as? [String: Any] else {
            throw WorkspaceError("The Inkspring connection service returned an unreadable configuration.")
        }
        self.signingKey = signingKey
        availability = Set(SocialPlatform.allCases.filter { platform in
            (providers[platform.rawValue] as? [String: Any])?["available"] as? Bool == true && !signingKey.isEmpty
        })
    }

    func saveDeveloperApp(_ platform: SocialPlatform, input: DeveloperOAuthConfiguration) throws {
        guard connecting != platform else { throw WorkspaceError("Finish the current sign-in first.") }
        let old = try SocialAccountKeychain.configuration(platform)
        var configuration = input
        configuration.clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.clientSecret = configuration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.clientSecret.isEmpty && old?.clientID == configuration.clientID {
            configuration.clientSecret = old?.clientSecret ?? ""
        }
        try configuration.validate(platform)
        if old != configuration, try SocialAccountKeychain.read(platform)?.ownApp == true {
            try disconnect(platform)
        }
        try SocialAccountKeychain.saveConfiguration(configuration, for: platform)
        developerAppIDs[platform] = configuration.clientID
        if platform == .linkedin { developerPages = configuration.linkedInPages }
    }

    func connect(_ platform: SocialPlatform, developerApp: Bool = false) async throws {
        guard connecting == nil else { throw WorkspaceError("Finish the current sign-in first.") }
        connecting = platform
        defer {
            connecting = nil
            browserSession = nil
            loopback = nil
            signInTimeout?.cancel()
            signInTimeout = nil
        }
        let revision = UUID()
        revisions[platform] = revision
        let session: ManagedSocialSession
        if developerApp {
            guard let configuration = try SocialAccountKeychain.configuration(platform) else {
                throw WorkspaceError("Save the developer app before connecting.")
            }
            let request = try DeveloperOAuth(platform: platform, configuration: configuration)
            let callback: URL
            if platform.usesLoopback {
                let listener = LoopbackOAuth(callback: platform.developerCallback, state: request.state)
                loopback = listener
                callback = try await listener.wait(opening: request.url)
            } else {
                callback = try await authorize(request.url)
            }
            session = try await request.exchange(callback, transport: transport)
        } else {
            try await load()
            guard availability.contains(platform) else { throw WorkspaceError("Shared sign-in is unavailable for \(platform.name).") }
            let handshake = try ManagedOAuthHandshake(platform: platform, signingKey: signingKey)
            let callback = try await authorize(handshake.url)
            session = try handshake.open(callback)
        }
        var account = try await identify(platform, session: session)
        account.ownApp = developerApp
        account.connectedAt = WorkspaceRecord.timestamp
        guard revisions[platform] == revision else { throw CancellationError() }
        try SocialAccountKeychain.save(account, for: platform)
        profiles[platform] = profile(account)
        if platform == .linkedin { setLinkedInDestinations(account) }
    }

    func refreshLinkedInPages() async throws {
        let account = try await authorized(.linkedin)
        let pages = try await LinkedInPages.refresh(account, transport: transport)
        guard var current = try SocialAccountKeychain.read(.linkedin), current.id == account.id,
              current.session.accessToken == account.session.accessToken else {
            throw WorkspaceError("The LinkedIn account changed. Refresh company pages again.")
        }
        current.linkedInPages = pages
        try SocialAccountKeychain.save(current, for: .linkedin)
        setLinkedInDestinations(current)
    }

    func savedLinkedInDestinations() throws -> [LinkedInDestination] {
        guard let account = try SocialAccountKeychain.read(.linkedin) else { return [] }
        return [LinkedInDestination.personal(account)] + (LinkedInPages.available(account) ? account.linkedInPages ?? [] : [])
    }

    private func setLinkedInDestinations(_ account: ManagedSocialAccount) {
        linkedInDestinations = [LinkedInDestination.personal(account)] + (LinkedInPages.available(account) ? account.linkedInPages ?? [] : [])
    }

    func disconnect(_ platform: SocialPlatform) throws {
        revisions[platform] = UUID()
        if connecting == platform {
            browserSession?.cancel()
            loopback?.cancel()
        }
        refreshes[platform]?.cancel()
        try SocialAccountKeychain.remove(platform)
        profiles[platform] = nil
        if platform == .linkedin { linkedInDestinations = [] }
    }

    func savedAccount(_ platform: SocialPlatform) throws -> ManagedSocialAccount? {
        try SocialAccountKeychain.read(platform)
    }

    func xReadToken() async throws -> String? {
        if ProviderKey.x.isSaved { return try ProviderKey.x.read() }
        guard try savedAccount(.x) != nil else { return nil }
        return try await authorized(.x).session.accessToken
    }

    func testConnection(_ platform: SocialPlatform) async throws -> Profile {
        guard let saved = try savedAccount(platform) else {
            throw WorkspaceError("Connect \(platform.name) before testing the connection.")
        }
        let revision = revisions[platform]
        let checked = try await verifyIdentity(platform, account: saved)
        guard revision == revisions[platform], let current = try savedAccount(platform),
              current.connectionKey == saved.connectionKey,
              current.session.accessToken == saved.session.accessToken else {
            throw WorkspaceError("The account changed during the check. Test the connection again.")
        }
        return checked
    }

    func verifyIdentity(_ platform: SocialPlatform, account: ManagedSocialAccount) async throws -> Profile {
        guard account.session.expiration > .now else {
            throw WorkspaceError("This session has expired. Reconnect \(platform.name) before testing again.")
        }
        var current = try await identify(platform, session: account.session, timeout: 15)
        try Task.checkCancellation()
        guard current.id == account.id else {
            throw WorkspaceError("The platform returned a different account. Reconnect \(platform.name).")
        }
        current.ownApp = account.ownApp
        return profile(current)
    }

    func authorized(_ platform: SocialPlatform) async throws -> ManagedSocialAccount {
        if let refresh = refreshes[platform] { return try await refresh.value }
        guard let account = try SocialAccountKeychain.read(platform) else {
            throw WorkspaceError("Connect \(platform.name) in Connections first.")
        }
        let threshold: TimeInterval = platform == .instagram ? 7 * 86_400 : 60
        if account.session.expiration.timeIntervalSinceNow > threshold { return account }
        let revision = revisions[platform]
        let refresh = Task { @MainActor in
            var updated = account
            if account.ownApp == true, platform != .instagram {
                guard let configuration = try SocialAccountKeychain.configuration(platform) else {
                    throw WorkspaceError("Configure the developer app and reconnect.")
                }
                updated.session = try await DeveloperOAuth.refresh(platform, configuration: configuration,
                                                                   session: account.session, transport: self.transport)
            } else {
                updated.session = try await self.refreshSession(platform, account.session)
            }
            try Task.checkCancellation()
            guard revision == self.revisions[platform] else { throw CancellationError() }
            try SocialAccountKeychain.save(updated, for: platform)
            return updated
        }
        refreshes[platform] = refresh
        defer { refreshes[platform] = nil }
        return try await refresh.value
    }

    private func refreshSession(_ platform: SocialPlatform, _ session: ManagedSocialSession) async throws -> ManagedSocialSession {
        if platform == .instagram, session.expiration > .now {
            let url = URL(string: "https://graph.instagram.com/refresh_access_token")!.appending(queryItems: [
                URLQueryItem(name: "grant_type", value: "ig_refresh_token"),
                URLQueryItem(name: "access_token", value: session.accessToken)
            ])
            let (value, _) = try await transport.request(url)
            if let token = value["access_token"] as? String, let duration = value["expires_in"] as? Int64,
               (1...31_536_000).contains(duration) {
                let new = ManagedSocialSession(accessToken: token, refreshToken: session.refreshToken,
                                               managedTicket: session.managedTicket,
                                               expiresAt: Int64(Date.now.timeIntervalSince1970 * 1000) + duration * 1000, scopes: session.scopes)
                try new.validate()
                return new
            }
        } else if let token = session.refreshToken, !token.isEmpty,
                  let ticket = session.managedTicket, !ticket.isEmpty {
            let (value, _) = try await transport.request(ManagedOAuthHandshake.base.appending(path: "refresh"), method: "POST",
                                                        json: ["provider": platform.rawValue, "refreshToken": token, "ticket": ticket])
            let new = try JSONDecoder().decode(ManagedSocialSession.self, from: JSONSerialization.data(withJSONObject: value))
            try new.validate()
            return new
        }
        throw WorkspaceError("This social session has expired. Reconnect in Connections.")
    }

    private func identify(_ platform: SocialPlatform, session: ManagedSocialSession, timeout: TimeInterval = 45) async throws -> ManagedSocialAccount {
        let headers = platform == .reddit ? ["User-Agent": "desktop:com.protomota.inkspring:v1.0 (Inkspring; https://inkspring.ai)"] : [:]
        let (value, _) = try await transport.request(platform.identityURL, token: session.accessToken, headers: headers, timeout: timeout)
        let data = value["data"] as? [String: Any] ?? [:]
        let person = switch platform {
        case .x: data
        case .tiktok: data["user"] as? [String: Any] ?? [:]
        default: value
        }
        let id: Any? = switch platform {
        case .linkedin: person["sub"]
        case .instagram: person["user_id"] ?? person["id"]
        case .tiktok: person["open_id"]
        default: person["id"]
        }
        let accountID = id as? String ?? (id as? NSNumber)?.stringValue ?? ""
        guard !accountID.isEmpty, accountID.utf8.count <= 300 else {
            throw WorkspaceError("The platform did not identify this account.")
        }
        if platform == .instagram, let type = person["account_type"] as? String,
           !["BUSINESS", "CREATOR", "MEDIA_CREATOR"].contains(type) {
            throw WorkspaceError("Instagram publishing requires a Business or Creator account.")
        }
        let username = String((person["username"] as? String ?? person["name"] as? String ?? "").prefix(300))
        let name = String((person["display_name"] as? String ?? person["name"] as? String ?? person["username"] as? String ?? "Connected account").prefix(300))
        return ManagedSocialAccount(session: session, id: accountID, name: name, username: username)
    }

    private func authorize(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completion: ASWebAuthenticationSession.CompletionHandler = { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: WorkspaceError("Couldn’t complete browser sign-in."))
                }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(url: url, callback: .customScheme("inkspring"), completionHandler: completion)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: "inkspring", completionHandler: completion)
            }
            session.presentationContextProvider = self
            browserSession = session
            if session.start() {
                signInTimeout = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(600))
                    if !Task.isCancelled { session.cancel() }
                }
            } else {
                continuation.resume(throwing: WorkspaceError("Couldn’t open browser sign-in."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }

    private func profile(_ account: ManagedSocialAccount) -> Profile {
        Profile(id: account.id, name: account.name, username: account.username, usesDeveloperApp: account.ownApp == true)
    }
}

private enum SocialAccountKeychain {
    private static func query(_ item: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.protomota.inkspring.native.social",
            kSecAttrAccount as String: item
        ]
    }

    static func read(_ platform: SocialPlatform) throws -> ManagedSocialAccount? {
        try readItem(platform.rawValue)
    }

    static func save(_ account: ManagedSocialAccount, for platform: SocialPlatform) throws {
        try writeItem(platform.rawValue, value: account)
    }

    static func configuration(_ platform: SocialPlatform) throws -> DeveloperOAuthConfiguration? {
        try readItem("developer-" + platform.rawValue)
    }

    static func saveConfiguration(_ configuration: DeveloperOAuthConfiguration, for platform: SocialPlatform) throws {
        try writeItem("developer-" + platform.rawValue, value: configuration)
    }

    private static func readItem<T: Decodable>(_ item: String) throws -> T? {
        var query = query(item)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw WorkspaceError("The saved connection couldn’t be read. Configure it again.")
        }
        return value
    }

    private static func writeItem<T: Encodable>(_ item: String, value: T) throws {
        let query = query(item)
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            try check(SecItemAdd(attributes as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func remove(_ platform: SocialPlatform) throws {
        let status = SecItemDelete(query(platform.rawValue) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw WorkspaceError("Keychain couldn’t access this social connection (\(status)).") }
    }
}
