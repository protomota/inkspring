import CryptoKit
import Foundation
import SwiftUI

/// X's Articles API uses snake_case DraftJS blocks, lowercase styles and a keyed entity array.
@MainActor enum XArticleDocument {
    static func payload(title: String, markdown: String) throws -> [String: Any] {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 300,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError("Add an article title and text before publishing.")
        }
        let document = try NewsletterDocument.parse(markdown)
        var blocks: [[String: Any]] = []
        var entities: [[String: Any]] = []
        func entity(_ type: String, data: [String: Any], mutable: Bool = false) -> Int {
            let key = entities.count
            entities.append(["key": String(key), "value": ["type": type, "mutability": mutable ? "mutable" : "immutable", "data": data]])
            return key
        }
        func append(_ node: [String: Any], context: String = "unstyled", depth: Int = 0) throws {
            guard depth < 32 else { throw WorkspaceError("Simplify the article’s nested formatting.") }
            let kind = node["type"] as? String ?? ""
            let children = node["content"] as? [[String: Any]] ?? []
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            switch kind {
            case "doc", "listItem", "bulletList", "orderedList", "blockquote":
                let type = ["bulletList": "unordered-list-item", "orderedList": "ordered-list-item", "blockquote": "blockquote"][kind] ?? context
                for child in children { try append(child, context: type, depth: depth + 1) }
            case "horizontal_rule", "code_block":
                let code = children.compactMap { $0["text"] as? String }.joined()
                let language = attrs["language"] as? String ?? ""
                let key = entity(kind == "horizontal_rule" ? "divider" : "markdown",
                    data: kind == "horizontal_rule" ? [:] : ["markdown": "```\(language)\n\(code)\n```"], mutable: kind != "horizontal_rule")
                blocks.append(["type": "atomic", "text": " ", "entity_ranges": [["key": key, "offset": 0, "length": 1]]])
            case "captionedImage":
                // Preserve external images as links; never download an arbitrary remote image with account credentials.
                for image in children {
                    let imageAttrs = image["attrs"] as? [String: Any] ?? [:]
                    guard let url = imageAttrs["src"] as? String else { continue }
                    let label = imageAttrs["alt"] as? String ?? "View image"
                    let key = entity("link", data: ["url": url], mutable: true)
                    blocks.append(["type": "unstyled", "text": label, "entity_ranges": [["key": key, "offset": 0, "length": label.utf16.count]]])
                }
            case "paragraph", "heading":
                var text = ""
                var ranges: [[String: Any]] = []
                var styles: [[String: Any]] = []
                for span in children {
                    let value = span["type"] as? String == "hard_break" ? "\n" : span["text"] as? String ?? ""
                    let offset = text.utf16.count
                    text += value
                    for mark in span["marks"] as? [[String: Any]] ?? [] {
                        let markType = mark["type"] as? String ?? ""
                        if let style = ["strong": "bold", "em": "italic", "strikethrough": "strikethrough"][markType] {
                            styles.append(["offset": offset, "length": value.utf16.count, "style": style])
                        } else if markType == "link", let url = (mark["attrs"] as? [String: Any])?["href"] as? String {
                            let key = entity("link", data: ["url": url], mutable: true)
                            ranges.append(["offset": offset, "length": value.utf16.count, "key": key])
                        }
                    }
                }
                let type = kind == "heading" ? ((attrs["level"] as? Int ?? 1) == 1 ? "header-one" : "header-two") : context
                blocks.append(["type": type, "text": text, "inline_style_ranges": styles, "entity_ranges": ranges])
            default: throw WorkspaceError("This article contains formatting X cannot publish. Check the source before continuing.")
            }
        }
        try append(document)
        guard !blocks.isEmpty else { throw WorkspaceError("Write the article before publishing.") }
        return ["title": title, "content_state": ["blocks": blocks, "entities": entities]]
    }
}

struct XArticlePublishPlan {
    let articleID: String
    let revision: String
    let title: String
    let accountKey: String
    let accountName: String
    let fingerprint: String
    let payload: [String: Any]

    @MainActor init(article: WorkspaceRecord, account: ManagedSocialAccount) throws {
        guard article.kind == "article", article["state"] == "draft" else {
            throw WorkspaceError("Choose an unpublished X article. Check any previous publishing attempt before retrying.")
        }
        let scopes = (account.session.scopes ?? "").split(whereSeparator: \.isWhitespace)
        guard scopes.isEmpty || scopes.contains("tweet.write") else {
            throw WorkspaceError("Reconnect X in Connections with permission to publish.")
        }
        articleID = article.id; revision = article["updatedAt"]; title = article.title
        accountKey = account.connectionKey
        accountName = account.username.isEmpty ? account.name : "@" + account.username
        payload = try XArticleDocument.payload(title: title, markdown: article.body)
        fingerprint = SHA256.hash(data: Data((try NewsletterDocument.canonical(["account": accountKey, "payload": payload])).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor struct XArticlePublisher {
    let workspace: Workspace
    let transport: SocialTransport
    let authorize: @MainActor () async throws -> ManagedSocialAccount

    init(workspace: Workspace, transport: SocialTransport = .init(),
         authorize: (@MainActor () async throws -> ManagedSocialAccount)? = nil) {
        self.workspace = workspace; self.transport = transport
        self.authorize = authorize ?? { try await workspace.socialAccounts.authorized(.x) }
    }

    func review(_ article: WorkspaceRecord) async throws -> XArticlePublishPlan {
        try XArticlePublishPlan(article: article, account: await authorize())
    }

    func publish(_ plan: XArticlePublishPlan, fromAgent: Bool = false) async throws -> WorkspaceRecord {
        let account = try await authorize()
        let lease = try workspace.claimPublication()
        defer { withExtendedLifetime(lease) {} }
        try workspace.reload()
        guard let article = workspace.records.first(where: { $0.id == plan.articleID && $0.kind == "article" }),
              article["updatedAt"] == plan.revision,
              try XArticlePublishPlan(article: article, account: account).fingerprint == plan.fingerprint else {
            throw WorkspaceError("The article or X account changed. Review it again before publishing.")
        }
        var receipt = try workspace.beginXArticlePublication(plan, fromAgent: fromAgent)
        do {
            if receipt["remoteArticleId"].isEmpty {
                receipt["phase"] = "creatingDraft"; try workspace.updateXArticlePublication(receipt)
                let (result, _) = try await transport.request(URL(string: "https://api.x.com/2/articles/draft")!,
                    token: account.session.accessToken, method: "POST", json: plan.payload, publishes: true)
                guard let id = (result["data"] as? [String: Any])?["id"] as? String, Self.validID(id) else {
                    throw SocialRequestError("X didn’t confirm the article draft. Check Articles on X before retrying.", uncertain: true)
                }
                receipt["remoteArticleId"] = id
                receipt["phase"] = "draftCreated"; try workspace.updateXArticlePublication(receipt)
            }
            // Persist the remote draft before publishing so a known rejection can safely reuse it.
            receipt["phase"] = "publishingArticle"; try workspace.updateXArticlePublication(receipt)
            let address = "https://api.x.com/2/articles/" + receipt["remoteArticleId"] + "/publish"
            let (result, _) = try await transport.request(URL(string: address)!, token: account.session.accessToken,
                                                        method: "POST", publishes: true)
            guard let id = (result["data"] as? [String: Any])?["post_id"] as? String, Self.validID(id) else {
                throw SocialRequestError("X didn’t confirm publication. Check your X profile before retrying.", uncertain: true)
            }
            receipt["status"] = "published"; receipt["phase"] = "published"
            receipt["publishedAt"] = WorkspaceRecord.timestamp
            receipt.fields["steps"] = [["id": id, "url": "https://x.com/i/web/status/" + id, "at": receipt["publishedAt"]]]
            try workspace.updateXArticlePublication(receipt)
            return receipt
        } catch {
            let uncertain = (error as? SocialRequestError)?.uncertain ?? true
            receipt["status"] = uncertain ? "uncertain" : "failed"
            let message: String
            switch (error as? SocialRequestError)?.statusCode {
            case 401: message = "Reconnect your X account in Connections, then review the article again."
            case 403: message = "X declined Article access. Check that this account can publish Articles and the connection has posting permission. Your draft is safe."
            case 402: message = "X requires API credits to publish this article. Add credits in the X Developer Console, then retry. Your draft is safe."
            default: message = error.localizedDescription
            }
            receipt["error"] = message
            try? workspace.updateXArticlePublication(receipt)
            throw SocialRequestError(message, uncertain: uncertain)
        }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: #"\A[0-9]{1,19}\z"#, options: .regularExpression) != nil
    }
}

extension Workspace {
    func beginXArticlePublication(_ plan: XArticlePublishPlan, fromAgent: Bool) throws -> WorkspaceRecord {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try database.transaction {
            try reload()
            guard var article = records.first(where: { $0.kind == "article" && $0.id == plan.articleID }),
                  article["state"] == "draft", article["updatedAt"] == plan.revision else {
                throw WorkspaceError("The article changed or has an unresolved publishing attempt.")
            }
            if fromAgent, settings["mcpEnabled"] as? Bool != true || settings["mcpAllowPosting"] as? Bool != true {
                throw WorkspaceError("Immediate agent posting is off in Inkspring Settings.")
            }
            let receipts = records.filter { $0.kind == "publication" && $0["draftId"] == article.id }
            guard !receipts.contains(where: { ["publishing", "published", "uncertain"].contains($0["status"]) }) else {
                throw WorkspaceError("Check the existing X Article publishing attempt before retrying.")
            }
            var receipt = receipts.first { $0["fingerprint"] == plan.fingerprint && $0["status"] == "failed" }
                ?? .new("publication", projectID: article.projectID)
            receipt["draftId"] = article.id; receipt["contentKind"] = "article"; receipt["platform"] = "x"
            receipt["title"] = plan.title; receipt["accountId"] = plan.accountKey; receipt["accountName"] = plan.accountName
            receipt["fingerprint"] = plan.fingerprint; receipt["status"] = "publishing"; receipt["error"] = ""
            try database.put(receipt)
            article["state"] = "publishing"; article["articlePublicationId"] = receipt.id
            article.fields["articlePublishRequest"] = nil
            try database.put(article); try reload()
            return receipt
        }
    }

    func updateXArticlePublication(_ input: WorkspaceRecord) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try database.transaction {
            try reload()
            var receipt = input; receipt.markUpdated(); try database.put(receipt)
            if var article = records.first(where: { $0.kind == "article" && $0.id == receipt["draftId"] }) {
                article["state"] = receipt["status"] == "failed" ? "draft" : receipt["status"]
                article["articlePublicationStatus"] = receipt["status"]
                article["articlePublicationError"] = receipt["error"]
                if receipt["status"] == "published" {
                    article["articleURL"] = (receipt.fields["steps"] as? [[String: String]])?.first?["url"] ?? ""
                    article["articlePublishedAt"] = receipt["publishedAt"]
                }
                try database.put(article)
            }
            try reload()
        }
    }

    func queueXArticlePublication(id: String, revision: String, accountKey: String, requestID: String) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try database.transaction {
            try reload()
            guard var article = records.first(where: { $0.kind == "article" && $0.id == id }),
                  article["updatedAt"] == revision, article["state"] == "draft", !article.body.isEmpty,
                  !accountKey.isEmpty else { throw WorkspaceError("The article changed. Review the latest text before publishing.") }
            if let pending = article.fields["articlePublishRequest"] as? [String: String] {
                guard pending["id"] == requestID else { throw WorkspaceError("This article is already waiting for your Mac to publish.") }
                return
            }
            article.fields["articlePublishRequest"] = ["id": requestID, "revision": revision, "account": accountKey]
            article["articlePublicationStatus"] = "queued"; article["articlePublicationError"] = ""
            try database.put(article); try reload()
        }
    }

    func publishPendingXArticles(publisher: XArticlePublisher? = nil) async {
        let publisher = publisher ?? XArticlePublisher(workspace: self)
        for record in records where record.kind == "article" && record.fields["articlePublishRequest"] != nil {
            guard let request = record.fields["articlePublishRequest"] as? [String: String] else { continue }
            do {
                let plan = try await publisher.review(record)
                guard request["revision"] == plan.revision, request["account"] == plan.accountKey else {
                    throw WorkspaceError("The article or connected X account changed. Review it again before publishing.")
                }
                _ = try await publisher.publish(plan)
            } catch {
                try? withChanges {
                    guard var current = records.first(where: { $0.id == record.id }), current["state"] == "draft" else { return }
                    current.fields["articlePublishRequest"] = nil
                    current["articlePublicationStatus"] = "failed"; current["articlePublicationError"] = error.localizedDescription
                    try database?.put(current); try reload()
                }
            }
        }
    }
}

struct XArticlePublishControls: View {
    let workspace: Workspace
    let article: WorkspaceRecord
    let save: () -> Bool
    @State private var reviewed: XArticlePublishPlan?
    @State private var busy = false
    @State private var error: String?
    private var current: WorkspaceRecord { workspace.records.first { $0.id == article.id } ?? article }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StudioPlatformLabel(name: "x", title: "X article")
                if current["state"] == "draft" {
                    Button("Review & publish on X…", systemImage: "paperplane") {
                        guard save() else { return }
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do { reviewed = try await XArticlePublisher(workspace: workspace).review(current) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy).accessibilityIdentifier("article.reviewPublish")
                }
                if busy || current["state"] == "publishing" { ProgressView().controlSize(.small) }
                if let url = URL(string: current["articleURL"]), url.scheme == "https", url.host == "x.com" {
                    StudioExternalLink("View published article", destination: url)
                }
            }
            Text("Publishes the full article to your connected X account. Requires X Article access and API credits.")
                .font(.caption).foregroundStyle(.secondary)
            if let reviewed {
                Text("Publish “\(reviewed.title)” publicly as \(reviewed.accountName)?").font(.callout)
                HStack {
                    Button("Cancel") { self.reviewed = nil }
                    Button("Publish article now", systemImage: "paperplane.fill") {
                        self.reviewed = nil; busy = true
                        Task {
                            defer { busy = false }
                            do { _ = try await XArticlePublisher(workspace: workspace).publish(reviewed) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy).accessibilityIdentifier("article.publish")
                }
            }
            if current["state"] == "uncertain" {
                Text("X hasn’t confirmed the result. Check your X Articles before allowing another attempt in Publishing history.").font(.callout)
            }
            if let message = error ?? (current["articlePublicationError"].isEmpty ? nil : current["articlePublicationError"]) {
                Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("article.publishError")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).studioSurface()
    }
}
