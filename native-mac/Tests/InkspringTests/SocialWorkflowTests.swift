import CryptoKit
import Foundation
import Testing
@testable import Inkspring

@Test func managedHandshakeChecksSignatureEncryptionAndState() throws {
    let signing = Curve25519.Signing.PrivateKey()
    let signingPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    let keyPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00])
    let client = try ManagedOAuthHandshake(platform: .x, signingKey: encode(signingPrefix + signing.publicKey.rawRepresentation))
    let query = URLComponents(url: client.url, resolvingAgainstBaseURL: false)?.queryItems
    let clientKey = try #require(query?.first { $0.name == "publicKey" }?.value)
    let decoded = try #require(Data(base64Encoded: clientKey.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/") + "="))
    let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(decoded.dropFirst(keyPrefix.count)))
    let server = Curve25519.KeyAgreement.PrivateKey()
    let purpose = Data("inkspring-desktop-result-v1".utf8)
    let secret = try server.sharedSecretFromKeyAgreement(with: remote)
        .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: purpose, outputByteCount: 32)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let deadline = Int64(now.timeIntervalSince1970 * 1000) + 90_000
    let payload = try JSONSerialization.data(withJSONObject: [
        "provider": "x", "state": client.state, "expiresAt": deadline,
        "session": ["accessToken": "fixture-access", "expiresAt": deadline, "scopes": "tweet.write"]
    ])
    let box = try AES.GCM.seal(payload, using: secret, authenticating: purpose)
    let key = encode(keyPrefix + server.publicKey.rawRepresentation)
    let iv = encode(Data(box.nonce))
    let data = encode(box.ciphertext)
    let tag = encode(box.tag)
    let signed = Data(#"{"v":1,"key":"\#(key)","iv":"\#(iv)","data":"\#(data)","tag":"\#(tag)"}"#.utf8)
    let signature = encode(try signing.signature(for: signed))
    let envelope = try JSONSerialization.data(withJSONObject: ["v": 1, "key": key, "iv": iv, "data": data, "tag": tag, "signature": signature])
    let callback = try #require(URL(string: "inkspring://oauth/x?state=\(client.state)#result=\(encode(envelope))"))
    #expect(try client.open(callback, now: now).accessToken == "fixture-access")
    #expect(throws: WorkspaceError.self) { try client.open(callback, now: now.addingTimeInterval(91)) }
    let wrong = try #require(URL(string: "inkspring://oauth/x?state=x.wrong#result=\(encode(envelope))"))
    #expect(throws: WorkspaceError.self) { try client.open(wrong, now: now) }
    let changed = try JSONSerialization.data(withJSONObject: ["v": 1, "key": key, "iv": iv, "data": data, "tag": tag, "signature": encode(Data(repeating: 0, count: 64))])
    let tampered = try #require(URL(string: "inkspring://oauth/x?state=\(client.state)#result=\(encode(changed))"))
    #expect(throws: WorkspaceError.self) { try client.open(tampered, now: now) }
}

@Test @MainActor func socialConnectionTestOnlyReadsAndRequiresTheSavedIdentity() async throws {
    for platform in SocialPlatform.allCases {
        var requests = 0
        var returnedID = account.id
        let accounts = ManagedSocialAccounts(transport: SocialTransport { request in
            requests += 1
            #expect(request.url == platform.identityURL)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            let payload: [String: Any] = switch platform {
            case .x: ["data": ["id": returnedID, "username": "fixture"]]
            case .linkedin: ["sub": returnedID, "name": "Fixture"]
            case .instagram: ["user_id": returnedID, "username": "fixture", "account_type": "BUSINESS"]
            case .reddit: ["id": returnedID, "name": "fixture"]
            case .tiktok: ["data": ["user": ["open_id": returnedID, "display_name": "Fixture"]]]
            }
            return try response(request, status: 200, json: payload)
        })
        var saved = account
        saved.ownApp = true
        let verified = try await accounts.verifyIdentity(platform, account: saved)
        #expect(verified.id == saved.id)
        #expect(verified.usesDeveloperApp)
        returnedID = "different-user"
        await #expect(throws: WorkspaceError.self) { _ = try await accounts.verifyIdentity(platform, account: saved) }
        saved.session = ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil, expiresAt: 0, scopes: nil)
        await #expect(throws: WorkspaceError.self) { _ = try await accounts.verifyIdentity(platform, account: saved) }
        #expect(requests == 2)
    }
}

@Test @MainActor func xThreadResumesOnlyAfterConfirmedSteps() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Thread fixture"
    draft["format"] = "thread"
    draft["content"] = "First post.\n\nSecond post."
    draft = try workspace.save(draft)
    var requests: [[String: Any]] = []
    let transport = SocialTransport { request in
        #expect(request.url?.host == "api.x.com")
        let body = try #require(request.httpBody)
        requests.append(try #require(JSONSerialization.jsonObject(with: body) as? [String: Any]))
        let status = requests.count == 2 ? 400 : 201
        let json = try JSONSerialization.data(withJSONObject: ["data": ["id": requests.count == 1 ? "101" : "102"]])
        let url = try #require(request.url)
        return (json, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in account })
    let review = try await publisher.review(draft)
    await #expect(throws: SocialRequestError.self) { _ = try await publisher.publish(review) }
    #expect(workspace.records.first { $0.kind == "publication" }?["status"] == "partial")
    let current = try #require(workspace.drafts.first { $0.id == draft.id })
    let receipt = try await publisher.publish(publisher.review(current))
    #expect(receipt["status"] == "published")
    #expect(requests.count == 3)
    #expect(requests[0]["text"] as? String == "First post.")
    #expect((requests[2]["reply"] as? [String: String])?["in_reply_to_tweet_id"] == "101")
    #expect(workspace.drafts.first { $0.id == draft.id }?.scheduleStatus == "posted")
    let posted = try #require(workspace.drafts.first { $0.id == draft.id })
    let repeatReview = try await publisher.review(posted)
    await #expect(throws: WorkspaceError.self) { _ = try await publisher.publish(repeatReview) }
    #expect(requests.count == 3)
}

private let account = ManagedSocialAccount(
    session: ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil, expiresAt: 2_000_000_000_000, scopes: "tweet.write"),
    id: "user", name: "Test", username: "test"
)

private func encode(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

@Test @MainActor func developerOAuthMatchesCallbackAndExchangesCode() async throws {
    let personal = try DeveloperOAuth(platform: .linkedin, configuration: .init(clientID: "fixture-id", clientSecret: "fixture-secret"))
    let personalQuery = try #require(URLComponents(url: personal.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(personalQuery.first { $0.name == "scope" }?.value == "openid profile w_member_social")
    #expect(personalQuery.first { $0.name == "redirect_uri" }?.value == "https://inkspring.ai/desktop-connect/")
    let configuration = DeveloperOAuthConfiguration(clientID: "fixture-id", clientSecret: "fixture-secret", linkedInPages: true)
    let linkedIn = try DeveloperOAuth(platform: .linkedin, configuration: configuration)
    let query = try #require(URLComponents(url: linkedIn.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "scope" }?.value?.contains("w_organization_social") == true)
    #expect(!linkedIn.url.absoluteString.contains(configuration.clientSecret))
    let callback = try #require(URL(string: "inkspring://oauth/linkedin?state=\(linkedIn.state)&code=fixture%2Bcode"))
    let wrong = try #require(URL(string: "inkspring://oauth/linkedin?state=wrong&code=fixture"))
    #expect(throws: WorkspaceError.self) { try linkedIn.callbackCode(wrong) }
    let transport = SocialTransport { request in
        #expect(request.url?.host == "www.linkedin.com")
        let payload = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(payload.contains("code=fixture%2Bcode"))
        #expect(payload.contains("client_secret=fixture-secret"))
        return try response(request, status: 200, json: ["access_token": "fixture", "expires_in": 3600])
    }
    #expect(try await linkedIn.exchange(callback, transport: transport).accessToken == "fixture")
    let reddit = try DeveloperOAuth(platform: .reddit, configuration: .init(clientID: "fixture-id", clientSecret: ""))
    let listener = LoopbackOAuth(callback: SocialPlatform.reddit.developerCallback, state: reddit.state)
    let request = "GET /oauth/reddit?state=\(reddit.state)&code=fixture HTTP/1.1\r\nHost: 127.0.0.1:43821"
    let local = try #require(listener.parse(request))
    #expect(try reddit.callbackCode(local) == "fixture")
    #expect(listener.parse(request + "\r\nOrigin: https://example.org") == nil)
    #expect(listener.parse(request.replacingOccurrences(of: "Host: 127.0.0.1", with: "Host: example.org")) == nil)
}

@Test @MainActor func instagramAndRedditConfirmRemoteReceipts() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    var instagram = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    instagram["title"] = "Instagram fixture"
    instagram["content"] = "Caption"
    instagram["platform"] = "instagram"
    instagram["format"] = "image"
    instagram = try workspace.save(instagram)
    let profile = ManagedSocialAccount(session: account.session, id: "123", name: "Test", username: "fixture")
    let invalid = SocialPublishOptions(imageURL: "https://127.0.0.1/image.jpg")
    #expect(throws: WorkspaceError.self) {
        try SocialPublishPlan(draft: instagram, account: profile, imageURL: nil, options: invalid)
    }

    var paths: [String] = []
    let transport = SocialTransport { request in
        let path = request.url?.path ?? ""
        paths.append(path)
        let json: [String: Any] = switch path {
        case "/v25.0/123/media": ["id": "456"]
        case "/v25.0/456": ["status_code": "FINISHED"]
        case "/v25.0/123/media_publish": ["id": "789"]
        case "/v25.0/789": ["permalink": "https://www.instagram.com/p/fixture/"]
        case "/api/submit": ["json": ["errors": [], "data": ["name": "t3_abc", "url": "https://www.reddit.com/r/example/comments/abc/fixture/"]]]
        default: [:]
        }
        return try response(request, status: 200, json: json)
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in profile })
    let image = SocialPublishOptions(imageURL: "https://example.org/image.jpg")
    let photoReview = try await publisher.review(instagram, options: image)
    let photoReceipt = try await publisher.publish(photoReview)
    #expect(photoReceipt["status"] == "published")
    #expect((photoReceipt.fields["steps"] as? [[String: String]])?.first?["url"] == "https://www.instagram.com/p/fixture/")

    var reddit = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    reddit["title"] = "Reddit fixture"
    reddit["content"] = "Text"
    reddit["platform"] = "reddit"
    reddit = try workspace.save(reddit)
    let redditReview = try await publisher.review(reddit, options: .init(subreddit: "r/example"))
    let redditReceipt = try await publisher.publish(redditReview)
    #expect(redditReceipt["status"] == "published")
    #expect(paths == ["/v25.0/123/media", "/v25.0/456", "/v25.0/123/media_publish", "/v25.0/789", "/api/submit"])
}

private func response(_ request: URLRequest, status: Int, json: [String: Any]) throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let http = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    return (try JSONSerialization.data(withJSONObject: json), http)
}

@Test @MainActor func tiktokRequiresConsentAndRechecksPrivacyBeforePublishing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "TikTok photo"
    draft["content"] = "Original caption"
    draft["platform"] = "tiktok"
    draft["format"] = "image"
    draft = try workspace.save(draft)
    var profile = account
    profile.ownApp = true
    var paths: [String] = []
    let transport = SocialTransport { request in
        let path = request.url?.path ?? ""
        paths.append(path)
        var data: [String: Any] = [:]
        if path.hasSuffix("/creator_info/query") {
            data = ["creator_username": "fixture", "privacy_level_options": ["SELF_ONLY"]]
        } else if path.hasSuffix("/content/init") {
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let info = try #require(payload["post_info"] as? [String: Any])
            #expect(info["description"] as? String == "Reviewed caption")
            #expect(info["privacy_level"] as? String == "SELF_ONLY")
            data = ["publish_id": "fixture-post"]
        } else if path.hasSuffix("/status/fetch") {
            data = ["status": "PUBLISH_COMPLETE", "publicaly_available_post_id": ["123"]]
        }
        return try response(request, status: 200, json: ["data": data, "error": ["code": "ok"]])
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in profile })
    var options = TikTokReviewOptions(privacy: "SELF_ONLY", title: "Fixture", caption: "Reviewed caption")
    let image = "https://example.org/image.jpg"
    await #expect(throws: WorkspaceError.self) {
        _ = try await publisher.review(draft, options: .init(imageURL: image, tiktok: options))
    }
    options.consent = true
    let reviewed = try await publisher.review(draft, options: .init(imageURL: image, tiktok: options))
    let receipt = try await publisher.publish(reviewed)
    #expect(receipt["status"] == "published")
    #expect(paths.filter { $0.hasSuffix("/creator_info/query") }.count == 3)
    #expect(paths.filter { $0.hasSuffix("/content/init") }.count == 1)
    #expect((receipt.fields["steps"] as? [[String: String]])?.first?["url"] == "https://www.tiktok.com/@fixture/photo/123")
}

@Test @MainActor func scheduleUsesSlotRulesAndPublishesOnlyEligibleDuePosts() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    var x = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    x["title"] = "X test"
    x["content"] = "Synthetic post"
    x = try workspace.save(x)
    let slot = Date.now.addingTimeInterval(4000)
    let exact = try PostScheduling.date(hour: slot, minute: 0)
    #expect(Calendar.current.component(.minute, from: exact) == 0)
    #expect(PostScheduling.parseLocalHour("2027-02-31T13:00") == nil)
    x = try workspace.scheduleDraft(x, at: slot)
    var anotherX = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    anotherX["title"] = "Conflicting slot"
    anotherX["content"] = "Synthetic"
    anotherX = try workspace.save(anotherX)
    #expect(throws: WorkspaceError.self) { try workspace.scheduleDraft(anotherX, at: slot) }

    var ig = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    ig["title"] = "Instagram test"
    ig["content"] = "Await review"
    ig["platform"] = "instagram"
    ig["format"] = "image"
    ig = try workspace.save(ig)
    ig = try workspace.scheduleDraft(ig, at: slot)
    var requests = 0
    let transport = SocialTransport { request in
        requests += 1
        #expect(request.url?.host == "api.x.com")
        return try response(request, status: 201, json: ["data": ["id": "456"]])
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in account })
    await workspace.runDuePosts(publisher: publisher, now: slot)
    #expect(requests == 0)
    try workspace.set("autoPost", to: true)
    await workspace.runDuePosts(publisher: publisher, now: slot)
    #expect(requests == 1)
    #expect(workspace.drafts.first { $0.id == x.id }?.scheduleStatus == "posted")
    #expect(workspace.drafts.first { $0.id == ig.id }?.scheduleStatus == "due")
}

@Test @MainActor func scheduleRemindersOnlyFollowCommittedReviewAndFailureStates() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    let now = Date.now.addingTimeInterval(6 * 3600)
    func queue(_ platform: String, slot: Date) throws -> WorkspaceRecord {
        var post = WorkspaceRecord.new("draft", projectID: workspace.projectID)
        post["platform"] = platform
        post["title"] = "Private synthetic title"
        post["content"] = "Private synthetic content"
        return try workspace.scheduleDraft(workspace.save(post), at: slot)
    }
    let missed = try queue("x", slot: now.addingTimeInterval(-4 * 3600))
    let manual = try queue("instagram", slot: now.addingTimeInterval(-1))
    let rejected = try queue("x", slot: now.addingTimeInterval(-1))
    var calls = 0
    let transport = SocialTransport { request in
        calls += 1
        return try response(request, status: 400, json: ["detail": "Synthetic provider rejection"])
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in account })
    try workspace.set(ScheduleNotifications.settingKey, to: true)
    var reminders: [ScheduleReminder] = []
    await workspace.runDuePosts(publisher: publisher, now: now) { reminders.append($0) }
    #expect(reminders.isEmpty)
    #expect(calls == 0)

    try workspace.set("autoPost", to: true)
    await workspace.runDuePosts(publisher: publisher, now: now) { reminders.append($0) }
    #expect(calls == 1)
    #expect(Set(reminders.map(\.draftID)) == [missed.id, manual.id, rejected.id])
    #expect(reminders.first { $0.draftID == manual.id }?.reason == .review)
    #expect(reminders.filter { $0.reason == .check }.count == 2)
    #expect(reminders.allSatisfy { !$0.title.contains("Private") && !$0.message.contains("Private") })
    #expect(workspace.drafts.first { $0.id == rejected.id }?.scheduleStatus == "failed")

    await workspace.runDuePosts(publisher: publisher, now: now) { reminders.append($0) }
    #expect(reminders.count == 3)
    #expect(calls == 1)
}

@Test func scheduleShowsPostsAndNewslettersAcrossProjectsInPostingOrder() {
    let x = WorkspaceRecord(kind: "draft", fields: [
        "id": "x", "projectId": "second", "platform": "x",
        "schedule": ["status": "queued", "slotAt": "2027-01-01T15:00:00Z"]
    ])
    let newsletter = WorkspaceRecord(kind: "newsletter", fields: [
        "id": "newsletter", "projectId": "first", "state": "scheduled", "scheduledAt": "2027-01-01T09:00:00Z"
    ])
    let uncertain = WorkspaceRecord(kind: "newsletter", fields: [
        "id": "uncertain", "projectId": "second", "state": "uncertain", "scheduledAt": "2027-01-01T11:00:00Z"
    ])
    let ready = WorkspaceRecord(kind: "draft", fields: [
        "id": "ready", "projectId": "first", "platform": "linkedin", "schedule": ["status": "ready"]
    ])
    let posted = WorkspaceRecord(kind: "draft", fields: [
        "id": "posted", "projectId": "second", "platform": "x",
        "schedule": ["status": "posted", "postedAt": "2026-12-29T15:00:00Z"]
    ])
    let unscheduled = WorkspaceRecord(kind: "draft", fields: ["id": "unscheduled", "projectId": "second", "platform": "x"])
    let records = [x, newsletter, ready, posted, uncertain, unscheduled]
    let all = ScheduleListing(records: records)
    #expect(all[.scheduled].map(\.id) == ["newsletter", "uncertain", "x"])
    #expect(all[.ready].map(\.id) == ["ready"])
    #expect(all[.history].map(\.id) == ["posted"])
    #expect(ScheduleListing(records: records, projectID: "second")[.scheduled].map(\.id) == ["uncertain", "x"])
    #expect(ScheduleListing(records: records, channel: "substack")[.scheduled].map(\.id) == ["newsletter", "uncertain"])
    #expect(ScheduleListing(records: records, projectID: "second", channel: "substack")[.scheduled].map(\.id) == ["uncertain"])
    #expect(ScheduleListing.section(for: unscheduled) == nil)
    #expect(ScheduleListing.date(for: posted, in: .history) == scheduleDate("2026-12-29T15:00:00Z"))
    for status in ["failed", "removed", "manual"] {
        var waiting = ready
        waiting.fields["schedule"] = ["status": status]
        #expect(ScheduleListing.section(for: waiting) == .ready)
    }
}

@Test func xPostingHoursUseTheSameCrossProjectOccupancyAsScheduling() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let day = try #require(scheduleDate("2026-11-01T16:00:00Z"))
    let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: day))
    let drafts = [
        WorkspaceRecord(kind: "draft", fields: [
            "id": "posted", "platform": "x", "projectId": "a",
            "schedule": ["status": "posted", "slotAt": "2026-11-01T16:00:00Z", "postedAt": "2026-11-01T14:25:00Z"]
        ]),
        WorkspaceRecord(kind: "draft", fields: [
            "id": "queued", "platform": "x", "projectId": "b",
            "schedule": ["status": "queued", "slotAt": "2026-11-01T18:15:00Z"]
        ]),
        WorkspaceRecord(kind: "draft", fields: [
            "id": "failed", "platform": "x", "projectId": "b",
            "schedule": ["status": "failed", "slotAt": "2026-11-01T20:15:00Z"]
        ]),
        WorkspaceRecord(kind: "draft", fields: [
            "id": "linkedin", "platform": "linkedin", "projectId": "a",
            "schedule": ["status": "queued", "slotAt": "2026-11-01T22:30:00Z"]
        ])
    ]
    let hours = PostScheduling.xPostingHours(on: day, in: drafts, calendar: calendar)
    #expect(hours.map { calendar.component(.hour, from: $0.start) } == [9, 11, 13, 15, 17])
    #expect(hours.map { $0.post?.id } == ["posted", nil, "queued", nil, nil])
    #expect(PostScheduling.xPostingHours(on: nextDay, in: drafts, calendar: calendar).allSatisfy { $0.post == nil })
    let draft = WorkspaceRecord(kind: "draft", fields: ["id": "new", "platform": "x"])
    for hour in hours {
        #expect(PostScheduling.isFree(hour.start, for: draft, in: drafts, calendar: calendar) == (hour.post == nil))
    }
}

@Test @MainActor func linkedInVerifiesCompanyPageAgainBeforePublishing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    let profile = ManagedSocialAccount(
        session: ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
                                      expiresAt: 2_000_000_000_000,
                                      scopes: "w_member_social rw_organization_admin w_organization_social"),
        id: "member", name: "Test", username: "test"
    )
    let destination = LinkedInDestination(kind: "organization", urn: "urn:li:organization:123", memberId: profile.id, name: "Fixture page")
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "LinkedIn fixture"
    draft["content"] = "A company-page post"
    draft["platform"] = "linkedin"
    draft.fields["linkedinDestination"] = destination.fields
    draft = try workspace.save(draft)

    var pageChecks = 0
    var posts = 0
    let transport = SocialTransport { request in
        let url = try #require(request.url)
        switch url.path {
        case "/rest/organizationAcls":
            pageChecks += 1
            let row = ["state": "APPROVED", "roleAssignee": "urn:li:person:member",
                       "role": "ADMINISTRATOR", "organization": destination.urn]
            return try response(request, status: 200, json: ["elements": pageChecks == 2 ? [] : [row]])
        case "/rest/organizations/123":
            return try response(request, status: 200, json: ["id": 123, "localizedName": "Fixture page"])
        case "/rest/posts":
            posts += 1
            let data = try #require(request.httpBody)
            let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(fields["author"] as? String == destination.urn)
            let headers = ["x-restli-id": "urn:li:share:456"]
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: headers)))
        default:
            Issue.record("Unexpected LinkedIn request")
            return try response(request, status: 400, json: [:])
        }
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in profile })
    let reviewed = try await publisher.review(draft)
    #expect(reviewed.accountName == "Fixture page")
    await #expect(throws: WorkspaceError.self) { _ = try await publisher.publish(reviewed) }
    #expect(posts == 0)
    let receipt = try await publisher.publish(reviewed)
    #expect(receipt["status"] == "published")
    #expect(posts == 1)
    #expect(pageChecks == 3)
}

@Test @MainActor func scheduledLinkedInPostStaysBoundToItsProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    let session = ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
                                       expiresAt: 2_000_000_000_000, scopes: "w_member_social")
    let original = ManagedSocialAccount(session: session, id: "original", name: "Original profile", username: "original")
    let switched = ManagedSocialAccount(session: session, id: "different", name: "Different profile", username: "different")
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "LinkedIn schedule fixture"
    draft["content"] = "A fixture that should stay on its original profile."
    draft["platform"] = "linkedin"
    draft = try workspace.save(draft)
    let slot = Date.now.addingTimeInterval(3600)
    let queued = try workspace.scheduleDraft(draft, at: slot, linkedInAccount: original)
    #expect(queued.scheduleStatus == "queued")
    #expect(LinkedInDestination(fields: queued.fields["linkedinDestination"] as? [String: Any])?.memberId == original.id)
    #expect(throws: WorkspaceError.self) {
        try workspace.scheduleDraft(queued, at: slot.addingTimeInterval(3600), linkedInAccount: switched)
    }
    try workspace.set("autoPost", to: true)
    let transport = SocialTransport { request in
        Issue.record("Unexpected publishing request after the account changed.")
        return try response(request, status: 400, json: [:])
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in switched })
    await workspace.runDuePosts(publisher: publisher, now: slot)
    #expect(workspace.records.first { $0.id == draft.id }?.scheduleStatus == "failed")
    #expect(workspace.records.allSatisfy { $0.kind != "publication" })
}

@Test @MainActor func interruptedPublishingIsRecoveredOnlyAfterTheLeaseEnds() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    var sending = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    sending["title"] = "Interrupted thread"
    sending["content"] = "Existing fixture text"
    sending.fields["schedule"] = ["status": "posting"]
    sending = try workspace.save(sending)
    var orphan = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    orphan["title"] = "Interrupted legacy post without a receipt"
    orphan.fields["schedule"] = ["status": "posting"]
    try workspace.save(orphan)
    var receipt = WorkspaceRecord.new("publication", projectID: workspace.projectID)
    receipt["title"] = sending.title
    receipt["draftId"] = sending.id
    receipt["status"] = "publishing"
    receipt.fields["steps"] = [["id": "123", "url": "https://x.com/i/web/status/123"]]
    try workspace.save(receipt)

    do {
        let lease = try workspace.claimPublication()
        defer { withExtendedLifetime(lease) {} }
        workspace.recoverInterruptedPublications()
        #expect(workspace.records.first { $0.id == receipt.id }?["status"] == "publishing")
    }
    workspace.recoverInterruptedPublications()
    let recovered = try #require(workspace.records.first { $0.id == receipt.id })
    #expect(recovered["status"] == "uncertain")
    #expect((recovered.fields["steps"] as? [[String: Any]])?.first?["id"] as? String == "123")
    #expect(workspace.drafts.first { $0.id == sending.id }?.scheduleStatus == "failed")
    #expect(workspace.drafts.first { $0.id == orphan.id }?.scheduleStatus == "failed")
    #expect(workspace.records.filter { $0.kind == "publication" && $0["status"] == "uncertain" }.count == 2)
    let restored = try #require(workspace.drafts.first { $0.id == sending.id })
    #expect(throws: WorkspaceError.self) { try workspace.scheduleDraft(restored, at: .now.addingTimeInterval(3600)) }
}
