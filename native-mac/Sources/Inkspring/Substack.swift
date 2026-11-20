import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SubstackPublication: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let origin: String
    let userId: String
    let role: String

    var fields: [String: String] { ["id": id, "name": name, "origin": origin, "userId": userId, "role": role] }

    func identifies(_ other: Self?) -> Bool {
        guard let other else { return false }
        return id == other.id && userId == other.userId && origin == other.origin
    }

    static func decode(_ value: Any?) -> Self? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let publication = try? JSONDecoder().decode(Self.self, from: data),
              let url = URL(string: publication.origin), SubstackAddresses.publicationOrigin(url) else { return nil }
        return publication
    }
}

private enum SubstackAddresses {
    static func publicationOrigin(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil &&
        url.path.isEmpty && url.query == nil && url.fragment == nil &&
        url.host()?.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.substack\.com$"#, options: .regularExpression) != nil
    }
}

struct SubstackReview: Identifiable {
    let id = UUID()
    let newsletterID: String
    let revision: Int
    let fingerprint: String
    let publication: SubstackPublication
    let title: String
    let audience: String
    let sendEmail: Bool
    let scheduledAt: Date?
    let expires: Date
}

@MainActor
struct Substack {
    typealias Transport = @MainActor (String, URL, [String: Any]?) async throws -> [String: Any]
    let workspace: Workspace
    private let transport: Transport
    private let now: () -> Date
    private static let roles = ["owner", "admin", "editor", "contributor"]

    init(workspace: Workspace, now: @escaping () -> Date = { .now }, transport: Transport? = nil) {
        self.workspace = workspace
        self.now = now
        self.transport = transport ?? { method, url, payload in
            try await workspace.substackSession.request(method, url, payload)
        }
    }

    var selected: SubstackPublication? { SubstackPublication.decode(workspace.settings["substackPublication"]) }
    var accountName: String { (workspace.settings["substackAccount"] as? [String: Any])?["name"] as? String ?? "" }
    var publications: [SubstackPublication] {
        let account = workspace.settings["substackAccount"] as? [String: Any]
        return (account?["publications"] as? [[String: Any]] ?? []).compactMap(SubstackPublication.decode)
    }

    func checkConnection() async throws {
        let account = workspace.settings["substackAccount"] as? [String: Any]
        let expectedUser = try Self.remoteID(account?["userId"])
        let expectedPublication = selected
        let profile = try await profile()
        guard try Self.remoteID(profile["id"]) == expectedUser else {
            throw WorkspaceError("Substack is signed into a different account. Sign in again to confirm which account to use.")
        }
        let accessible = try Self.publications(profile)
        guard !accessible.isEmpty,
              expectedPublication == nil || accessible.contains(where: { $0.identifies(expectedPublication) }) else {
            throw WorkspaceError("Substack could not verify access to this publication. Sign in again and check your publication permissions.")
        }
    }

    func connect() async throws {
        try await run {
            let profile = try await profile()
            let publications = try Self.publications(profile)
            guard !publications.isEmpty else { throw WorkspaceError("This account has no Substack publications you can edit.") }
            let previous = selected
            let name = profile["name"] as? String ?? profile["handle"] as? String ?? "Substack author"
            try workspace.withChanges {
                try workspace.set("substackAccount", to: ["name": String(name.prefix(200)), "userId": publications[0].userId,
                                                           "publications": publications.map(\.fields)])
                let match = publications.first { $0.identifies(previous) }
                try workspace.set("substackPublication", to: match?.fields as Any? ?? NSNull())
            }
            workspace.substackReviews.removeAll()
        }
    }

    func select(_ id: String) throws {
        guard !workspace.substackBusy else { throw WorkspaceError("Wait for the current Substack action.") }
        let lease = try workspace.claimPublication()
        defer { withExtendedLifetime(lease) {} }
        try workspace.withChanges {
            guard id.isEmpty || publications.contains(where: { $0.id == id }) else {
                throw WorkspaceError("Choose a publication from this Substack account.")
            }
            let match = publications.first { $0.id == id }
            try workspace.set("substackPublication", to: match?.fields as Any? ?? NSNull())
        }
        workspace.substackReviews.removeAll()
    }

    func disconnect() async throws {
        try await run {
            await workspace.substackSession.clear()
            try workspace.withChanges {
                try workspace.set("substackAccount", to: NSNull())
                try workspace.set("substackPublication", to: NSNull())
            }
            workspace.substackReviews.removeAll()
        }
    }

    func sync(_ newsletterID: String) async throws -> WorkspaceRecord {
        try await run {
            var item = try record(newsletterID)
            guard ["draft", "synced"].contains(item["state"]),
                  !item["body"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item["title"] != "Untitled newsletter" else {
                throw WorkspaceError("Save a title and body, and check the draft’s status in Substack before syncing.")
            }
            let document = try NewsletterDocument.parse(item["body"])
            let publication = try await authorized(item)
            guard let author = Int64(publication.userId), author <= 9_007_199_254_740_991 else {
                throw WorkspaceError("Substack returned an unsupported author ID.")
            }
            let path = try draftPath(item["remoteId"])
            var payload: [String: Any] = [
                "draft_title": item["title"], "draft_subtitle": item["subtitle"],
                "draft_body": try NewsletterDocument.canonical(document),
                "draft_bylines": [["id": author, "is_guest": false]],
                "audience": item["audience"], "type": "newsletter", "should_send_email": Self.emails(item),
                "section_chosen": true, "draft_section_id": NSNull(), "cover_image": NSNull()
            ]
            if !item["remoteId"].isEmpty {
                let previous = try await remote(publication, item["remoteId"])
                guard !Self.isPublished(previous), Self.schedule(previous) == nil,
                      try Self.fingerprint(previous) == item["remoteFingerprint"] else {
                    throw WorkspaceError("The draft changed in Substack. Open its editor and review the changes.")
                }
                payload["last_updated_at"] = previous["draft_updated_at"]
            }
            if item.fields["coverImage"] is [String: Any] {
                payload["cover_image"] = try await uploadCover(item, publication)
            }
            let previousState = item["state"]
            item = try workspace.patchNewsletter(item, ["state": "syncing", "error": ""])
            var responseArrived = false
            do {
                let response = try await request(item["remoteId"].isEmpty ? "POST" : "PUT", publication, path, payload)
                responseArrived = true
                let remoteID = try Self.remoteID(response["id"] ?? item["remoteId"])
                item = try workspace.patchNewsletter(item, ["remoteId": remoteID, "publication": publication.fields,
                                                           "editUrl": publication.origin + "/publish/post/" + remoteID])
                let actual = try await remote(publication, remoteID)
                guard !Self.isPublished(actual), Self.schedule(actual) == nil,
                      actual["cover_image"] as? String == payload["cover_image"] as? String,
                      try Self.matches(item, actual, document: document) else {
                    throw WorkspaceError("The Substack draft differs from this newsletter. Check its editor.")
                }
                return try workspace.patchNewsletter(item, ["state": "synced", "syncedRevision": Self.revision(item),
                                                            "remoteFingerprint": try Self.fingerprint(actual), "error": ""])
            } catch {
                let uncertain = responseArrived || !item["remoteId"].isEmpty || (error as? SubstackRequestError)?.uncertain == true
                _ = try workspace.patchNewsletter(item, ["state": uncertain ? "uncertain" : previousState, "error": error.localizedDescription])
                throw error
            }
        }
    }

    func prepare(_ newsletterID: String, at date: Date?) async throws -> SubstackReview {
        try await run {
            let item = try record(newsletterID)
            let publication = try await authorized(item)
            try Self.canSend(item, publication)
            try validate(date)
            let post = try await remote(publication, item["remoteId"])
            try Self.verify(item, post, fingerprint: item["remoteFingerprint"])
            let review = SubstackReview(newsletterID: item.id, revision: Self.revision(item), fingerprint: item["remoteFingerprint"],
                                        publication: publication, title: item.title, audience: item["audience"],
                                        sendEmail: Self.emails(item), scheduledAt: date, expires: now().addingTimeInterval(600))
            workspace.substackReviews[item.id] = review.id
            return review
        }
    }

    func commit(_ review: SubstackReview) async throws -> WorkspaceRecord {
        try await run {
            guard workspace.substackReviews[review.newsletterID] == review.id else {
                throw WorkspaceError("Review this newsletter again before sending.")
            }
            workspace.substackReviews.removeValue(forKey: review.newsletterID)
            var item = try record(review.newsletterID)
            guard review.expires > now(), Self.revision(item) == review.revision, review.publication.identifies(selected) else {
                throw WorkspaceError("Review this newsletter again before sending.")
            }
            let publication = try await authorized(item)
            try Self.canSend(item, publication)
            let post = try await remote(publication, item["remoteId"])
            try Self.verify(item, post, fingerprint: review.fingerprint)
            try validate(review.scheduledAt)
            let path = try draftPath(item["remoteId"])
            let at = review.scheduledAt.map(workspaceTimestamp) ?? ""
            let check = try await request("GET", publication, path + "/prepublish" + (at.isEmpty ? "" : "?publish_date=" + at))
            guard let errors = check["errors"] as? [Any], errors.isEmpty else {
                throw WorkspaceError("Check the pre-publish requirements in Substack before sending.")
            }
            guard review.expires > now() else { throw WorkspaceError("The review expired. Review this newsletter again.") }
            try validate(review.scheduledAt)
            item = try workspace.patchNewsletter(item, ["state": "releasing", "requestedAction": at.isEmpty ? "publish" : "schedule",
                                                        "requestedAt": at, "error": ""])
            do {
                if at.isEmpty {
                    _ = try await request("POST", publication, path + "/publish", ["send": Self.emails(item), "share_automatically": false])
                } else {
                    _ = try await request("POST", publication, path + "/scheduled_release",
                                          ["trigger_at": at, "post_audience": item["audience"], "email_audience": item["audience"]])
                }
                let result = try await remote(publication, item["remoteId"])
                guard Self.isPublished(result) || (review.scheduledAt != nil && Self.schedule(result) == review.scheduledAt) else {
                    throw WorkspaceError("Substack hasn’t confirmed the send. Check its editor before trying again.")
                }
                return try recordRemote(item, result, publication)
            } catch {
                _ = try workspace.patchNewsletter(item, ["state": "uncertain", "error": error.localizedDescription])
                throw error
            }
        }
    }

    func refresh(_ newsletterID: String) async throws -> WorkspaceRecord {
        try await run {
            let item = try record(newsletterID)
            let publication = try await authorized(item)
            guard !item["remoteId"].isEmpty else { throw WorkspaceError("No draft ID was confirmed. Check the drafts in Substack.") }
            let post = try await remote(publication, item["remoteId"])
            if Self.isPublished(post) || Self.schedule(post) != nil
                || (item["state"] == "uncertain" && item["requestedAction"] == "cancel") {
                return try recordRemote(item, post, publication)
            }
            if ["uncertain", "scheduled"].contains(item["state"]) {
                return try workspace.patchNewsletter(item, ["state": "uncertain", "error": "Substack reports a draft. Check its editor and confirm the outcome."])
            }
            return item
        }
    }

    func cancel(_ newsletterID: String) async throws -> WorkspaceRecord {
        try await run {
            var item = try record(newsletterID)
            let publication = try await authorized(item)
            guard publication.role != "contributor", item["state"] == "scheduled" else {
                throw WorkspaceError("Refresh the scheduled newsletter and check your Substack permissions.")
            }
            let post = try await remote(publication, item["remoteId"])
            guard !Self.isPublished(post), Self.schedule(post) != nil else {
                throw WorkspaceError("Substack does not report a cancellable schedule. Refresh its status.")
            }
            let path = try draftPath(item["remoteId"])
            item = try workspace.patchNewsletter(item, ["state": "releasing", "requestedAction": "cancel", "error": ""])
            do {
                do {
                    _ = try await request("DELETE", publication, path + "/scheduled_release")
                } catch let error as SubstackRequestError where error.uncertain {
                    // The draft readback below can confirm cancellation even if the response was unreadable.
                }
                let result = try await remote(publication, item["remoteId"])
                guard !Self.isPublished(result), Self.schedule(result) == nil else {
                    throw WorkspaceError("Substack hasn’t confirmed cancellation. Check its editor.")
                }
                return try recordRemote(item, result, publication)
            } catch {
                _ = try workspace.patchNewsletter(item, ["state": "uncertain", "error": error.localizedDescription])
                throw error
            }
        }
    }

    func acknowledge(_ newsletterID: String) async throws -> WorkspaceRecord {
        try await run {
            let item = try record(newsletterID)
            guard item["state"] == "uncertain" else { throw WorkspaceError("Only an unconfirmed attempt needs this check.") }
            if !item["remoteId"].isEmpty {
                let publication = try await authorized(item)
                let result = try await remote(publication, item["remoteId"])
                if Self.isPublished(result) || Self.schedule(result) != nil { return try recordRemote(item, result, publication) }
                return try workspace.patchNewsletter(item, ["state": "synced", "syncedRevision": 0,
                                                            "remoteFingerprint": try Self.fingerprint(result), "error": ""])
            }
            return try workspace.patchNewsletter(item, ["state": "draft", "syncedRevision": 0, "error": ""])
        }
    }

    private func run<T>(_ action: () async throws -> T) async throws -> T {
        guard !workspace.substackBusy else { throw WorkspaceError("Wait for the current Substack action.") }
        let lease = try workspace.claimPublication()
        workspace.substackBusy = true
        defer {
            workspace.substackBusy = false
            withExtendedLifetime(lease) {}
        }
        try workspace.reload()
        return try await action()
    }

    private func profile() async throws -> [String: Any] {
        try await transport("GET", URL(string: "https://substack.com/api/v1/user/profile/self")!, nil)
    }

    private func authorized(_ item: WorkspaceRecord) async throws -> SubstackPublication {
        guard let selected else { throw WorkspaceError("Choose a publication in Connections.") }
        if item.fields["publication"] is [String: Any], !selected.identifies(SubstackPublication.decode(item.fields["publication"])) {
            throw WorkspaceError("Choose this newsletter’s original publication in Connections.")
        }
        let publications = try Self.publications(await profile())
        guard let current = publications.first(where: { $0.identifies(selected) }) else {
            throw WorkspaceError("Reconnect Substack and check your account’s publication permissions.")
        }
        return current
    }

    private static func publications(_ profile: [String: Any]) throws -> [SubstackPublication] {
        let userID = try remoteID(profile["id"])
        return try (profile["publicationUsers"] as? [[String: Any]] ?? []).compactMap { row in
            guard let role = row["role"] as? String, roles.contains(role),
                  let publication = row["publication"] as? [String: Any], let domain = publication["subdomain"] as? String,
                  let url = URL(string: "https://" + domain.lowercased() + ".substack.com"),
                  SubstackAddresses.publicationOrigin(url) else { return nil }
            let name = String((publication["name"] as? String ?? domain).prefix(200))
            return SubstackPublication(id: try remoteID(publication["id"]), name: name, origin: url.absoluteString, userId: userID, role: role)
        }
    }

    private func record(_ id: String) throws -> WorkspaceRecord {
        guard let item = workspace.records.first(where: { $0.kind == "newsletter" && $0.id == id }) else {
            throw WorkspaceError("This newsletter is no longer available.")
        }
        return item
    }

    private func draftPath(_ id: String) throws -> String {
        "/api/v1/drafts" + (id.isEmpty ? "" : "/" + (try Self.remoteID(id)))
    }

    private func request(_ method: String, _ publication: SubstackPublication, _ path: String,
                         _ payload: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: publication.origin + path), SubstackSession.host(url) != nil else {
            throw WorkspaceError("The Substack publication address is invalid.")
        }
        return try await transport(method, url, payload)
    }

    private func remote(_ publication: SubstackPublication, _ id: String) async throws -> [String: Any] {
        let id = try Self.remoteID(id)
        let post = try await request("GET", publication, draftPath(id))
        guard try Self.remoteID(post["id"]) == id else { throw WorkspaceError("Substack returned a different draft.") }
        return post
    }

    private func uploadCover(_ item: WorkspaceRecord, _ publication: SubstackPublication) async throws -> String {
        guard let file = workspace.mediaURL(item) else { throw WorkspaceError("The newsletter cover image is unavailable.") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (1...30_000_000).contains(values.fileSize ?? 0),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source),
              let mime = UTType(type as String)?.preferredMIMEType, ["image/jpeg", "image/png", "image/webp"].contains(mime) else {
            throw WorkspaceError("Use a PNG, JPEG or WebP newsletter cover up to 30 MB.")
        }
        let bytes = try Data(contentsOf: file)
        let result = try await request("POST", publication, "/api/v1/image", ["image": "data:" + mime + ";base64," + bytes.base64EncodedString()])
        guard let raw = result["url"] as? String, let url = URL(string: raw), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil, let host = url.host(),
              host.hasSuffix(".substackcdn.com") || (host.hasPrefix("substack-post-media.") && host.hasSuffix(".amazonaws.com")) else {
            throw WorkspaceError("Substack did not return a valid cover image address.")
        }
        return url.absoluteString
    }

    private func recordRemote(_ item: WorkspaceRecord, _ post: [String: Any], _ publication: SubstackPublication) throws -> WorkspaceRecord {
        let scheduledAt = Self.schedule(post)
        let published = Self.isPublished(post)
        let same = (try? Self.matches(item, post)) == true
        let slug = post["slug"] as? String ?? ""
        let postURL = published && slug.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9-]*$"#, options: .regularExpression) != nil
            ? publication.origin + "/p/" + slug : ""
        return try workspace.patchNewsletter(item, [
            "state": published ? "published" : scheduledAt == nil ? "synced" : "scheduled",
            "scheduledAt": scheduledAt.map(workspaceTimestamp) ?? "",
            "publishedAt": published ? post["post_date"] as? String ?? "" : "",
            "postUrl": postURL,
            "remoteFingerprint": same ? try Self.fingerprint(post) : item["remoteFingerprint"],
            "error": same ? "" : "The Substack content differs from this local copy. Open its editor to review."
        ])
    }

    private func validate(_ date: Date?) throws {
        guard let date else { return }
        let current = now()
        let limit = Calendar(identifier: .gregorian).date(byAdding: .month, value: 3, to: current) ?? current
        guard date >= current.addingTimeInterval(60), date <= limit, date == PostScheduling.startOfMinute(date) else {
            throw WorkspaceError("Choose a time at least one minute from now and within the next three months.")
        }
    }

    private static func canSend(_ item: WorkspaceRecord, _ publication: SubstackPublication) throws {
        guard publication.role != "contributor" else { throw WorkspaceError("This role can save drafts. Ask a publication editor to send.") }
        guard item["state"] == "synced", item.fields["syncedRevision"] as? Int == revision(item) else {
            throw WorkspaceError("Save the latest newsletter to Substack before reviewing the send.")
        }
    }

    private static func verify(_ item: WorkspaceRecord, _ post: [String: Any], fingerprint: String) throws {
        guard !isPublished(post), schedule(post) == nil, try matches(item, post), try Self.fingerprint(post) == fingerprint else {
            throw WorkspaceError("The draft changed in Substack. Refresh its status and review it again.")
        }
    }

    private static func remoteID(_ value: Any?) throws -> String {
        let id = value as? String ?? (value as? NSNumber)?.stringValue ?? ""
        guard id.range(of: #"^[0-9]{1,24}$"#, options: .regularExpression) != nil else {
            throw WorkspaceError("Substack returned an invalid record ID.")
        }
        return id
    }

    static func editorURL(_ item: WorkspaceRecord) -> URL? {
        guard let publication = SubstackPublication.decode(item.fields["publication"]), let id = try? remoteID(item["remoteId"]) else { return nil }
        return URL(string: publication.origin + "/publish/post/" + id)
    }

    static func audienceLabel(_ audience: String) -> String {
        ["only_paid": "Paid subscribers", "founding": "Founding members"][audience] ?? "Everyone"
    }

    static func emails(_ item: WorkspaceRecord) -> Bool { item.fields["sendEmail"] as? Bool ?? false }
    private static func revision(_ item: WorkspaceRecord) -> Int { item.fields["revision"] as? Int ?? 0 }
    private static func isPublished(_ post: [String: Any]) -> Bool { post["is_published"] as? Bool == true }

    private static func schedule(_ post: [String: Any]) -> Date? {
        let rows = post["postSchedules"] as? [[String: Any]]
        guard let raw = post["trigger_at"] as? String ?? rows?.first?["trigger_at"] as? String else { return nil }
        return (try? Date(raw, strategy: .iso8601)) ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    private static func body(_ post: [String: Any]) throws -> Any {
        guard let value = post["draft_body"] else { throw WorkspaceError("Substack returned an unreadable draft.") }
        if let text = value as? String { return try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        return value
    }

    private static func matches(_ item: WorkspaceRecord, _ post: [String: Any], document: [String: Any]? = nil) throws -> Bool {
        guard post["draft_title"] as? String == item.title, (post["draft_subtitle"] as? String ?? "") == item["subtitle"],
              post["audience"] as? String == item["audience"], post["should_send_email"] as? Bool == emails(item) else { return false }
        return try NewsletterDocument.canonical(body(post)) == NewsletterDocument.canonical(document ?? NewsletterDocument.parse(item["body"]))
    }

    static func fingerprint(_ post: [String: Any]) throws -> String {
        let values: [Any] = [post["draft_title"] ?? NSNull(), post["draft_subtitle"] as? String ?? "",
                             try body(post), post["audience"] ?? NSNull(), post["should_send_email"] ?? NSNull(),
                             post["cover_image"] ?? NSNull(), post["draft_section_id"] ?? NSNull()]
        return SHA256.hash(data: Data(try NewsletterDocument.canonical(values).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
