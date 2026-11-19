import CryptoKit
import Foundation
import Darwin
import InkspringSchedule

struct SocialPublishOptions {
    var imageURL = ""
    var subreddit = ""
    var flair = ""
    var tiktok: TikTokReviewOptions?
    var creator: TikTokCreator?
    var video: TikTokVideo?
    var linkedInDestination: LinkedInDestination?
    var useR2 = false
    var r2: R2Configuration?
}

struct SocialPublishPlan {
    static let supported = Set(SocialPlatform.allCases)

    let platform: SocialPlatform
    let draftID: String
    let revision: String
    let title: String
    let accountID: String
    let accountName: String
    let posts: [String]
    let replyID: String?
    let image: URL?
    let imageHash: String?
    let linkedInDestination: LinkedInDestination?
    var linkedInAuthor: String? { linkedInDestination?.urn }
    let publicImage: URL?
    let subreddit: String?
    let flair: String?
    let tiktok: TikTokReviewOptions?
    let creator: TikTokCreator?
    let video: TikTokVideo?
    let r2: R2Configuration?

    var fingerprint: String {
        var parts = [platform.rawValue, draftID, accountID, title, replyID ?? ""]
        parts += [imageHash ?? "", linkedInAuthor ?? "", publicImage?.absoluteString ?? "", subreddit ?? "", flair ?? ""]
        parts += posts + (tiktok?.fingerprintFields ?? []) + (r2?.identity ?? [])
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(draft: WorkspaceRecord, account: ManagedSocialAccount, imageURL: URL?, options: SocialPublishOptions = .init(), articles: [WorkspaceRecord] = []) throws {
        guard draft.fields["manualQuote"] as? Bool != true else {
            throw WorkspaceError("Open this quote draft in X to publish it.")
        }
        let text = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkspaceError("Write the post before publishing.") }
        guard let platform = SocialPlatform(rawValue: draft["platform"]), Self.supported.contains(platform) else {
            throw WorkspaceError("Direct publishing for this platform is still being ported.")
        }
        if text.contains(XReplyArticle.prefix), !(platform == .x && ["thread", "followup"].contains(draft["format"])) {
            throw WorkspaceError("Use an X follow-up reply for the linked article.")
        }
        self.platform = platform
        draftID = draft.id
        revision = draft["updatedAt"]
        title = draft.title
        accountID = account.id
        accountName = options.linkedInDestination?.name ?? (account.username.isEmpty ? account.name : account.username)
        let scopes = (account.session.scopes ?? "").split { $0.isWhitespace || $0 == "," }
        tiktok = options.tiktok
        creator = options.creator
        video = options.video
        r2 = platform == .instagram && options.useR2 ? options.r2 : nil
        publicImage = (platform == .instagram && !options.useR2) || (platform == .tiktok && !options.imageURL.isEmpty)
            ? try Self.publicImageURL(options.imageURL) : nil
        let redditName = options.subreddit.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\Ar/"#, with: "", options: .regularExpression)
        subreddit = platform == .reddit ? redditName : nil
        flair = platform == .reddit && !options.flair.isEmpty ? options.flair : nil
        if platform == .x {
            guard ["post", "followup", "thread", "image", "reply"].contains(draft["format"]) else {
                throw WorkspaceError("Choose an X post, thread, image post or reply.")
            }
            if ["followup", "thread"].contains(draft["format"]) {
                posts = try XThreadText.posts(in: text).enumerated().map { index, post in
                    guard post.contains(XReplyArticle.prefix) else { return post }
                    let link = XReplyArticle(post)
                    guard index > 0, let reference = link.reference, !link.copy.contains(XReplyArticle.prefix),
                          let article = articles.first(where: { $0.kind == "article" && $0.projectID == draft.projectID && $0.referenceID == reference }) else {
                        throw WorkspaceError("Choose an available X article for this reply.")
                    }
                    guard article["state"] == "published",
                          article["articleURL"].range(of: #"\Ahttps://x\.com/i/web/status/[0-9]+\z"#, options: .regularExpression) != nil else {
                        throw WorkspaceError("Publish the X article “\(article.title)” before posting this thread.")
                    }
                    return link.copy.isEmpty ? article["articleURL"] : link.copy + "\n" + article["articleURL"]
                }
            } else {
                posts = [text]
            }
            let limit = draft.fields["longPost"] as? Bool == true && !["followup", "thread"].contains(draft["format"]) ? 25_000 : 280
            if draft["format"] == "followup", posts.count != 2 {
                throw WorkspaceError("A post with reply needs an opening post and one follow-up.")
            }
            guard (1...XThreadText.limit).contains(posts.count), posts.allSatisfy({ Self.xWeight($0) <= limit }) else {
                throw WorkspaceError("Use up to 25 thread posts and keep each post within the X character limit.")
            }
            if draft["format"] == "reply" {
                let target = (draft.fields["replyTo"] as? [String: Any])?["url"] as? String ?? ""
                let pattern = #"\Ahttps://(?:www\.|mobile\.)?(?:x|twitter)\.com/(?:[A-Za-z0-9_]{1,15}|i(?:/web)?)/status(?:es)?/([0-9]{1,25})(?:[/?#]|\z)"#
                guard let match = target.range(of: pattern, options: .regularExpression) else {
                    throw WorkspaceError("Add the X post link before publishing a reply.")
                }
                replyID = target[match].split(whereSeparator: { "/?#".contains($0) }).last.map(String.init)
            } else {
                replyID = nil
            }
            if draft["format"] == "image" && imageURL == nil { throw WorkspaceError("Attach an image before publishing.") }
            if ["image", "reply"].contains(draft["format"]), let imageURL {
                guard scopes.isEmpty || scopes.contains("media.write") else {
                    throw WorkspaceError("Reconnect X with permission to upload images.")
                }
                let resource = try imageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard resource.isRegularFile == true, resource.isSymbolicLink != true else {
                    throw WorkspaceError("The attached image is unavailable.")
                }
                image = imageURL
                imageHash = try fileDigest(imageURL, limit: 20_000_000).hash
            } else {
                image = nil
                imageHash = nil
            }
            linkedInDestination = nil
        } else if platform == .linkedin {
            guard draft["format"] == "post", text.unicodeScalars.count <= 3000,
                  account.id.range(of: #"\A[A-Za-z0-9_-]{1,200}\z"#, options: .regularExpression) != nil else {
                throw WorkspaceError("LinkedIn text posts can contain up to 3,000 characters.")
            }
            let destination = options.linkedInDestination ?? LinkedInDestination.personal(account)
            let raw = draft.fields["linkedinDestination"] as? [String: Any]
            let saved = LinkedInDestination(fields: raw)
            guard (raw == nil || saved?.urn == destination.urn),
                  destination.memberId == account.id else {
                throw WorkspaceError("This draft targets a different LinkedIn account. Choose the destination again.")
            }
            if destination.kind == "personal", !scopes.isEmpty, !scopes.contains("w_member_social") {
                throw WorkspaceError("Reconnect LinkedIn with permission to publish to your profile.")
            }
            if destination.kind == "organization", !LinkedInPages.available(account) {
                throw WorkspaceError("Reconnect LinkedIn with company-page publishing access.")
            }
            linkedInDestination = destination
            posts = [text]
            replyID = nil
            image = nil
            imageHash = nil
        } else {
            replyID = nil
            linkedInDestination = nil
            posts = [text]
            if platform == .instagram {
                guard ["image", "post"].contains(draft["format"]), text.unicodeScalars.count <= 2200,
                      account.id.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil else {
                    throw WorkspaceError("Use one Instagram image and a caption of up to 2,200 characters.")
                }
                if options.useR2 {
                    guard r2 != nil, let imageURL else { throw WorkspaceError("Set up R2 and attach an image before publishing.") }
                    image = imageURL
                    imageHash = try fileDigest(imageURL, limit: 20_000_000).hash
                } else {
                    image = nil
                    imageHash = nil
                }
            } else if platform == .tiktok {
                guard let tiktok, let creator else { throw WorkspaceError("Review the TikTok account and posting options.") }
                try tiktok.validate(creator: creator, video: video)
                if draft["format"] == "video", let video, let imageURL {
                    image = imageURL
                    imageHash = video.hash
                } else if draft["format"] == "image" {
                    if creator.usesManagedMedia, let imageURL {
                        image = imageURL
                        imageHash = try fileDigest(imageURL, limit: 20_000_000).hash
                    } else if !creator.usesManagedMedia, publicImage != nil {
                        image = nil
                        imageHash = nil
                    } else {
                        throw WorkspaceError("Choose a photo or enter its verified public URL.")
                    }
                } else {
                    throw WorkspaceError("Attach a photo or video before publishing to TikTok.")
                }
            } else {
                guard ["post", "image"].contains(draft["format"]), draft.title.unicodeScalars.count <= 300,
                      redditName.range(of: #"\A[A-Za-z0-9_]{2,50}\z"#, options: .regularExpression) != nil,
                      flair == nil || flair?.range(of: #"\A[A-Za-z0-9-]{1,100}\z"#, options: .regularExpression) != nil else {
                    throw WorkspaceError("Enter a subreddit, a title of up to 300 characters, and a valid flair ID if required.")
                }
                if draft["format"] == "image" {
                    guard let imageURL else { throw WorkspaceError("Attach an image before publishing.") }
                    image = imageURL
                    imageHash = try fileDigest(imageURL, limit: 20_000_000).hash
                } else {
                    image = nil
                    imageHash = nil
                }
            }
        }
    }

    private static func publicImageURL(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 3000, let url = URL(string: text), url.scheme == "https",
              url.user == nil, url.password == nil, let host = url.host(), host.contains("."),
              host.range(of: #"(^|\.)(localhost|local|internal|test|invalid)\.?\z"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw WorkspaceError("Enter a public HTTPS JPEG URL that Instagram can fetch.")
        }
        var address = in_addr()
        guard inet_aton(host, &address) == 0, !host.contains(":") else {
            throw WorkspaceError("Use a public domain name for the Instagram image.")
        }
        return url
    }

    static func xWeight(_ text: String) -> Int {
        XThreadText.weight(text)
    }
}

@MainActor
struct SocialPublisher {
    typealias Authorization = @MainActor (SocialPlatform) async throws -> ManagedSocialAccount
    let workspace: Workspace
    let transport: SocialTransport
    let authorize: Authorization
    let r2Client: @MainActor () throws -> R2Client?

    init(workspace: Workspace, transport: SocialTransport = SocialTransport(), authorize: Authorization? = nil,
         r2Client: @escaping @MainActor () throws -> R2Client? = { try R2Profile.saved().map { R2Client(profile: $0) } }) {
        self.workspace = workspace
        self.transport = transport
        self.authorize = authorize ?? { try await workspace.socialAccounts.authorized($0) }
        self.r2Client = r2Client
    }

    func review(_ draft: WorkspaceRecord, options: SocialPublishOptions = .init()) async throws -> SocialPublishPlan {
        guard let platform = SocialPlatform(rawValue: draft["platform"]), SocialPublishPlan.supported.contains(platform) else {
            throw WorkspaceError("Direct publishing for this platform is still being ported.")
        }
        let account = try await authorize(platform)
        return try await prepare(draft, account: account, options: options)
    }

    private func prepare(_ draft: WorkspaceRecord, account: ManagedSocialAccount,
                         options: SocialPublishOptions) async throws -> SocialPublishPlan {
        var options = options
        let url = draft["format"] == "video" ? workspace.videoURL(draft) : workspace.imageURL(draft)
        if draft["platform"] == "instagram", options.useR2 {
            options.r2 = try r2Client()?.profile.configuration
        }
        if draft["platform"] == "linkedin",
           let destination = LinkedInDestination(fields: draft.fields["linkedinDestination"] as? [String: Any]) {
            guard account.id == destination.memberId else {
                throw WorkspaceError("The LinkedIn account changed. Choose the destination and review again.")
            }
            if destination.kind == "organization" {
                let pages = try await LinkedInPages.refresh(account, transport: transport)
                guard let page = pages.first(where: { $0.urn == destination.urn && $0.memberId == destination.memberId }) else {
                    throw WorkspaceError("LinkedIn no longer confirms access to this company page.")
                }
                options.linkedInDestination = page
            } else {
                options.linkedInDestination = LinkedInDestination.personal(account)
            }
        }
        if draft["platform"] == "tiktok" {
            options.creator = try await tikTokCreator(account: account)
            if draft["format"] == "video", let url { options.video = try await TikTokVideo.inspect(url) }
        }
        return try SocialPublishPlan(draft: draft, account: account, imageURL: url, options: options, articles: workspace.records)
    }

    func publish(_ reviewed: SocialPublishPlan, automatic: Bool = false, fromAgent: Bool = false) async throws -> WorkspaceRecord {
        let account = try await authorize(reviewed.platform)
        try workspace.reload()
        guard let draft = workspace.records.first(where: { $0.id == reviewed.draftID && $0.kind == "draft" }),
              draft["updatedAt"] == reviewed.revision else {
            throw WorkspaceError("The draft changed. Open the review again.")
        }
        let options = SocialPublishOptions(imageURL: reviewed.publicImage?.absoluteString ?? "",
                                           subreddit: reviewed.subreddit ?? "", flair: reviewed.flair ?? "", tiktok: reviewed.tiktok,
                                           useR2: reviewed.r2 != nil)
        let plan = try await prepare(draft, account: account, options: options)
        guard plan.fingerprint == reviewed.fingerprint else {
            throw WorkspaceError("The account or attachment changed. Open the review again.")
        }
        let lease = try workspace.claimPublication()
        defer { withExtendedLifetime(lease) {} }
        try workspace.reload()
        guard let current = workspace.records.first(where: { $0.id == draft.id && $0.kind == "draft" }),
              current["updatedAt"] == plan.revision else {
            throw WorkspaceError("The draft changed. Open the review again.")
        }
        let companionClaim = try await workspace.claimCompanionPublication(current)
        var receipt: WorkspaceRecord
        do {
            receipt = try workspace.beginPublication(plan, automatic: automatic, fromAgent: fromAgent)
        } catch {
            if let companionClaim { await workspace.releaseCompanionClaim(companionClaim) }
            throw error
        }
        var steps = receipt.fields["steps"] as? [[String: Any]] ?? []
        do {
            switch plan.platform {
            case .x:
                for index in steps.count..<plan.posts.count {
                    let previous = index == 0 ? plan.replyID : steps[index - 1]["id"] as? String
                    var payload: [String: Any] = ["text": plan.posts[index]]
                    if let previous { payload["reply"] = ["in_reply_to_tweet_id": previous] }
                    if index == 0, let image = plan.image {
                        let uploaded = try await uploadXImage(image, expectedHash: plan.imageHash, token: account.session.accessToken)
                        payload["media"] = ["media_ids": [uploaded]]
                    }
                    let (value, _) = try await transport.request(URL(string: "https://api.x.com/2/tweets")!,
                                                                 token: account.session.accessToken, method: "POST", json: payload, publishes: true)
                    guard let id = (value["data"] as? [String: Any])?["id"] as? String,
                          id.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil else {
                        throw SocialRequestError("X didn’t confirm a post ID. Check the account before retrying.", uncertain: true)
                    }
                    steps.append(["id": id, "url": "https://x.com/i/web/status/" + id, "at": WorkspaceRecord.timestamp])
                    receipt.fields["steps"] = steps
                    try workspace.updatePublication(receipt)
                }
            case .linkedin:
                guard let author = plan.linkedInAuthor else { throw WorkspaceError("Choose a LinkedIn destination.") }
                let (_, response) = try await transport.request(URL(string: "https://api.linkedin.com/rest/posts")!,
                                                                 token: account.session.accessToken, method: "POST", json: [
                    "author": author, "commentary": plan.posts[0], "visibility": "PUBLIC",
                    "distribution": ["feedDistribution": "MAIN_FEED", "targetEntities": [String](), "thirdPartyDistributionChannels": [String]()],
                    "lifecycleState": "PUBLISHED", "isReshareDisabledByAuthor": false
                ], headers: LinkedInPages.headers, publishes: true)
                guard let id = response.value(forHTTPHeaderField: "x-restli-id"),
                      id.range(of: #"\Aurn:li:(share|ugcPost):[0-9]+\z"#, options: .regularExpression) != nil else {
                    throw SocialRequestError("LinkedIn didn’t confirm a post ID. Check the account before retrying.", uncertain: true)
                }
                steps.append(["id": id, "url": "https://www.linkedin.com/feed/update/" + id + "/", "at": WorkspaceRecord.timestamp])
                receipt.fields["steps"] = steps
            case .instagram:
                steps = [try await instagram(plan, account: account, receipt: &receipt)]
                receipt.fields["steps"] = steps
            case .reddit:
                steps = [try await reddit(plan, account: account)]
                receipt.fields["steps"] = steps
            case .tiktok:
                steps = [try await tiktok(plan, account: account, receipt: &receipt)]
                receipt.fields["steps"] = steps
            }
            receipt["status"] = "published"
            receipt["publishedAt"] = WorkspaceRecord.timestamp
            try workspace.updatePublication(receipt)
            return receipt
        } catch {
            let uncertain = (error as? SocialRequestError)?.uncertain ?? !(error is WorkspaceError)
            receipt["status"] = uncertain ? "uncertain" : steps.isEmpty ? "failed" : "partial"
            receipt["error"] = error.localizedDescription
            try? workspace.updatePublication(receipt)
            throw error
        }
    }

    private func instagram(_ plan: SocialPublishPlan, account: ManagedSocialAccount, receipt: inout WorkspaceRecord) async throws -> [String: String] {
        let base = URL(string: "https://graph.instagram.com/v25.0/")!
        let token = account.session.accessToken
        let accountURL = base.appending(path: account.id)
        var container = receipt["containerId"]
        if container.isEmpty {
            let image: URL
            if let config = plan.r2 {
                guard let client = try r2Client(), client.profile.configuration == config,
                      let local = plan.image, let hash = plan.imageHash else {
                    throw WorkspaceError("The R2 connection or image changed. Review the post again.")
                }
                let media = try await client.uploadInstagram(local, hash: hash)
                try workspace.saveR2Media(media, config: config)
                image = try client.link(media.key)
            } else if let url = plan.publicImage {
                image = url
            } else {
                throw WorkspaceError("Enter an Instagram image URL.")
            }
            let (value, _) = try await transport.form(accountURL.appending(path: "media"), token: token,
                                                      values: ["image_url": image.absoluteString, "caption": plan.posts[0]])
            guard let id = value["id"] as? String, validNumericID(id) else {
                throw WorkspaceError("Instagram didn’t return a media container.")
            }
            container = id
            receipt["containerId"] = id
            receipt.fields["containers"] = [id]
            try workspace.updatePublication(receipt)
        }
        guard validNumericID(container) else { throw WorkspaceError("The saved Instagram container is invalid.") }
        let statusURL = base.appending(path: container).appending(queryItems: [URLQueryItem(name: "fields", value: "status_code")])
        var ready = false
        for attempt in 0..<30 {
            let (value, _) = try await transport.request(statusURL, token: token)
            switch value["status_code"] as? String {
            case "FINISHED": ready = true
            case "PUBLISHED":
                throw SocialRequestError("Instagram reports this container already went out. Check the account.", uncertain: true)
            case "ERROR", "EXPIRED":
                receipt["containerId"] = ""
                receipt.fields["containers"] = [String]()
                throw WorkspaceError("Instagram couldn’t process this image. Check the public JPEG URL.")
            default:
                if attempt < 29 { try await Task.sleep(for: .seconds(2)) }
            }
            if ready { break }
        }
        guard ready else { throw WorkspaceError("Instagram is still processing the image. Review and try again later.") }
        let (value, _) = try await transport.form(accountURL.appending(path: "media_publish"), token: token,
                                                  values: ["creation_id": container], publishes: true)
        guard let id = value["id"] as? String, validNumericID(id) else {
            throw SocialRequestError("Instagram didn’t confirm a published post ID. Check the account.", uncertain: true)
        }
        var step = ["id": id, "url": "", "at": WorkspaceRecord.timestamp]
        receipt.fields["steps"] = [step]
        try workspace.updatePublication(receipt)
        let permalinkURL = base.appending(path: id).appending(queryItems: [URLQueryItem(name: "fields", value: "permalink")])
        if let (details, _) = try? await transport.request(permalinkURL, token: token),
           let raw = details["permalink"] as? String, let url = URL(string: raw), url.scheme == "https",
           ["instagram.com", "www.instagram.com"].contains(url.host ?? ""), url.user == nil, url.password == nil {
            step["url"] = url.absoluteString
        }
        return step
    }

    private func reddit(_ plan: SocialPublishPlan, account: ManagedSocialAccount) async throws -> [String: String] {
        guard let subreddit = plan.subreddit else { throw WorkspaceError("Choose a subreddit.") }
        var values = ["api_type": "json", "kind": "self", "sr": subreddit, "title": plan.title,
                      "text": plan.posts[0], "resubmit": "false"]
        if let flair = plan.flair { values["flair_id"] = flair }
        if let image = plan.image {
            values["url"] = try await redditUpload(image, hash: plan.imageHash, account: account).absoluteString
            values["kind"] = "image"
            values["validate_on_submit"] = "true"
        }
        let (value, _) = try await transport.form(URL(string: "https://oauth.reddit.com/api/submit")!,
                                                  token: account.session.accessToken, values: values,
                                                  headers: Self.redditHeaders, publishes: true)
        let result = value["json"] as? [String: Any] ?? [:]
        if let errors = result["errors"] as? [Any], !errors.isEmpty {
            throw WorkspaceError("Reddit rejected the submission. Check the subreddit’s rules, flair, and posting limits.")
        }
        let data = result["data"] as? [String: Any] ?? [:]
        if let url = data["url"] as? String {
            let step = try redditReceipt(url)
            guard step["id"] == data["name"] as? String else {
                throw SocialRequestError("Reddit returned conflicting post details. Check the account.", uncertain: true)
            }
            return step
        }
        if plan.image != nil, let address = data["websocket_url"] as? String {
            return try await redditImageReceipt(address)
        }
        throw SocialRequestError("Reddit didn’t confirm a submission. Check the subreddit.", uncertain: true)
    }

    private static let redditHeaders = ["User-Agent": "desktop:com.protomota.inkspring:v1.0 (Inkspring; https://inkspring.ai)"]

    private func redditUpload(_ url: URL, hash: String?, account: ManagedSocialAccount) async throws -> URL {
        let (data, type) = try imageBytes(url, expectedHash: hash, limit: 20_000_000)
        let name = type == "image/png" ? "image.png" : "image.jpg"
        let (value, _) = try await transport.form(URL(string: "https://oauth.reddit.com/api/media/asset.json")!,
                                                  token: account.session.accessToken,
                                                  values: ["filepath": name, "mimetype": type], headers: Self.redditHeaders)
        let lease = value["args"] as? [String: Any] ?? [:]
        guard let raw = lease["action"] as? String, let upload = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw),
              upload.scheme == "https", upload.user == nil, upload.password == nil, upload.port == nil,
              let host = upload.host, host.range(of: #"\Areddit-uploaded-media\.s3(?:[.-][a-z0-9-]+)?\.amazonaws\.com\z"#,
                                                 options: .regularExpression) != nil,
              let fields = lease["fields"] as? [[String: String]], fields.count <= 30 else {
            throw WorkspaceError("Reddit returned an unsupported image upload destination.")
        }
        let boundary = "Inkspring" + UUID().uuidString
        var form = Data()
        var key: String?
        for field in fields {
            guard let name = field["name"], let value = field["value"], name != "file",
                  name.range(of: #"\A[A-Za-z0-9_.-]{1,80}\z"#, options: .regularExpression) != nil else {
                throw WorkspaceError("Reddit returned an invalid upload form.")
            }
            if name == "key" { key = value }
            form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        guard let key, key.range(of: #"\A[A-Za-z0-9_./-]+\z"#, options: .regularExpression) != nil,
              !key.split(separator: "/").contains("..") else {
            throw WorkspaceError("Reddit didn’t return a valid media key.")
        }
        form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        form.append(data)
        form.append(Data("\r\n--\(boundary)--\r\n".utf8))
        _ = try await transport.request(upload, method: "POST", body: form,
                                        headers: ["Content-Type": "multipart/form-data; boundary=" + boundary], expectsJSON: false)
        return URL(string: "https://" + host + "/")!.appending(path: key)
    }

    private func redditImageReceipt(_ address: String) async throws -> [String: String] {
        guard let url = URL(string: address), url.scheme == "wss", url.host?.hasSuffix(".wss.redditmedia.com") == true,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw SocialRequestError("Reddit returned an unexpected confirmation address.", uncertain: true)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: NoHTTPRedirects(), delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 100_000
        socket.resume()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel(); socket.cancel(); session.invalidateAndCancel() }
        while true {
            guard let message = try? await socket.receive(), case let .string(json) = message,
                  let value = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                throw SocialRequestError("Reddit hasn’t confirmed the image post. Check the account.", uncertain: true)
            }
            if value["type"] as? String == "failed" { throw WorkspaceError("Reddit couldn’t process this image post.") }
            if let redirect = (value["payload"] as? [String: Any])?["redirect"] as? String { return try redditReceipt(redirect) }
        }
    }

    private func redditReceipt(_ text: String) throws -> [String: String] {
        guard let url = URL(string: text), url.scheme == "https", ["reddit.com", "www.reddit.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let match = url.path.range(of: #"/comments/[a-z0-9]+(?:/|\z)"#, options: .regularExpression),
              let id = url.path[match].split(separator: "/").last else {
            throw SocialRequestError("Reddit didn’t confirm a valid post address. Check the account.", uncertain: true)
        }
        return ["id": "t3_" + id, "url": url.absoluteString, "at": WorkspaceRecord.timestamp]
    }

    private func validNumericID(_ id: String) -> Bool {
        id.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil
    }

    private func imageBytes(_ url: URL, expectedHash: String?, limit: Int) throws -> (Data, String) {
        let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true, (1...limit).contains(resource.fileSize ?? 0) else {
            throw WorkspaceError("Choose a PNG or JPEG within the platform’s file size limit.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedHash else {
            throw WorkspaceError("The image changed. Review the attachment again.")
        }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return (data, "image/png") }
        if data.starts(with: [0xff, 0xd8]) { return (data, "image/jpeg") }
        throw WorkspaceError("Choose a PNG or JPEG image.")
    }

    private func uploadXImage(_ url: URL, expectedHash: String?, token: String) async throws -> String {
        let (input, type) = try imageBytes(url, expectedHash: expectedHash, limit: 5_000_000)
        let boundary = "Inkspring" + UUID().uuidString
        var multipart = Data()
        for (key, value) in [("media_category", "tweet_image"), ("media_type", type)] {
            multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        multipart.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"attachment\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        multipart.append(input)
        multipart.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (value, _) = try await transport.request(URL(string: "https://api.x.com/2/media/upload")!,
                                                     token: token, method: "POST", body: multipart,
                                                     headers: ["Content-Type": "multipart/form-data; boundary=" + boundary])
        guard let id = (value["data"] as? [String: Any])?["id"] as? String ?? value["media_id_string"] as? String,
              id.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil else {
            throw WorkspaceError("X didn’t return an uploaded image ID.")
        }
        return id
    }
}
