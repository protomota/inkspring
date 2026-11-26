import Foundation
import Testing
@testable import Inkspring
@testable import InkspringSchedule

@MainActor private func articleAccount(_ key: String = "connected") -> ManagedSocialAccount {
    ManagedSocialAccount(session: .init(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
        expiresAt: Int64(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000), scopes: "tweet.read tweet.write users.read"),
        id: "123", name: "Fixture", username: "fixture", connectedAt: key)
}

@MainActor private func articleWorkspace() throws -> (Workspace, WorkspaceRecord, URL) {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let workspace = Workspace(directory: folder)
    var article = WorkspaceRecord.new("article", projectID: workspace.projectID)
    article["title"] = "A complete article"; article["body"] = "# Our mission\n\nWe **build** useful tools. [Read more](https://example.com/mission)\n\n" + String(repeating: "Full text stays here. ", count: 1000)
    article = try workspace.save(article)
    return (workspace, article, folder)
}

@Test @MainActor func xArticlePayloadUsesOfficialSchemaAndKeepsLinksAndFormatting() throws {
    let payload = try XArticleDocument.payload(title: "Title", markdown: "# Heading\n\n😀 **bold** and [our site](https://example.com)\n\n- One\n- Two\n\n> Quote\n\n```swift\nlet value = 1\n```\n\n---")
    let state = try #require(payload["content_state"] as? [String: Any])
    let blocks = try #require(state["blocks"] as? [[String: Any]])
    #expect(blocks[0]["type"] as? String == "header-one")
    let styles = try #require(blocks[1]["inline_style_ranges"] as? [[String: Any]])
    #expect(styles[0]["style"] as? String == "bold")
    #expect(styles[0]["offset"] as? Int == 3) // UTF-16 emoji pair plus space.
    #expect(blocks.filter { $0["type"] as? String == "unordered-list-item" }.count == 2)
    #expect(blocks.contains { $0["type"] as? String == "blockquote" })
    let entities = try #require(state["entities"] as? [[String: Any]])
    #expect((entities[0]["value"] as? [String: Any])?["type"] as? String == "link")
    #expect(((entities[0]["value"] as? [String: Any])?["data"] as? [String: Any])?["url"] as? String == "https://example.com")
    #expect(try JSONSerialization.data(withJSONObject: payload).count > 0)
}

@Test @MainActor func xArticlePublishesFullDraftAndRecordsItsURLWithoutTweetConversion() async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    var paths: [String] = []
    let publisher = XArticlePublisher(workspace: workspace, transport: .init { request in
        paths.append(request.url!.path)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        if paths.count == 1 {
            let payload = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(payload["text"] == nil)
            #expect(String(decoding: request.httpBody!, as: UTF8.self).components(separatedBy: "Full text stays here.").count - 1 == 1000)
            return (Data(#"{"data":{"id":"456","title":"A complete article"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        #expect(request.httpBody == nil)
        return (Data(#"{"data":{"post_id":"789"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, authorize: { articleAccount() })
    let plan = try await publisher.review(article)
    #expect(paths.isEmpty)
    let receipt = try await publisher.publish(plan)
    #expect(paths == ["/2/articles/draft", "/2/articles/456/publish"])
    #expect(receipt["status"] == "published")
    let saved = try #require(workspace.records.first { $0.id == article.id })
    #expect(saved.body == article.body && saved["state"] == "published")
    #expect(saved["articleURL"] == "https://x.com/i/web/status/789")
    let snapshot = workspace.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.articles?.first?.publicationURL == saved["articleURL"])
    await #expect(throws: Error.self) { _ = try await publisher.publish(plan) }
    #expect(paths.count == 2)
}

@Test @MainActor func xArticleKnownPublishFailureReusesRemoteDraftOnRetry() async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    var paths: [String] = []
    let publisher = XArticlePublisher(workspace: workspace, transport: .init { request in
        paths.append(request.url!.path)
        let status = paths.count == 2 ? 429 : paths.count == 1 ? 201 : 200
        let body = paths.count == 1 ? #"{"data":{"id":"456"}}"# : #"{"data":{"post_id":"789"}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }, authorize: { articleAccount() })
    let plan = try await publisher.review(article)
    await #expect(throws: Error.self) { _ = try await publisher.publish(plan) }
    #expect(workspace.records.first { $0.id == article.id }?["state"] == "draft")
    _ = try await publisher.publish(plan)
    #expect(paths == ["/2/articles/draft", "/2/articles/456/publish", "/2/articles/456/publish"])
}

@Test @MainActor func xArticleAmbiguousPublicationBlocksRetriesAndRecoversSafely() async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    var writes = 0
    let publisher = XArticlePublisher(workspace: workspace, transport: .init { request in
        writes += 1
        if writes > 1 { throw URLError(.networkConnectionLost) }
        return (Data(#"{"data":{"id":"456"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }, authorize: { articleAccount() })
    let plan = try await publisher.review(article)
    await #expect(throws: Error.self) { _ = try await publisher.publish(plan) }
    #expect(workspace.records.first { $0.id == article.id }?["state"] == "uncertain")
    await #expect(throws: Error.self) { _ = try await publisher.publish(plan) }
    #expect(writes == 2)
    let receipt = try #require(workspace.records.first { $0.kind == "publication" })
    #expect(receipt["remoteArticleId"] == "456")
    try workspace.allowPublicationRetry(receipt.id)
    #expect(workspace.records.first { $0.id == article.id }?["state"] == "draft")
    // A process exit while the second request is active has the same protected recovery state.
    _ = try workspace.beginXArticlePublication(plan, fromAgent: false)
    workspace.recoverInterruptedPublications()
    #expect(workspace.records.first { $0.id == article.id }?["state"] == "uncertain")
}

@Test(arguments: [401, 402, 403]) @MainActor func xArticleDeclinedAccessKeepsDraftAndShowsUsefulMessage(status: Int) async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    let publisher = XArticlePublisher(workspace: workspace, transport: .init { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }, authorize: { articleAccount() })
    do { _ = try await publisher.publish(publisher.review(article)); Issue.record("Expected rejection") }
    catch { #expect(error.localizedDescription.contains(status == 402 ? "credits" : status == 403 ? "Article access" : "Reconnect")) }
    #expect(workspace.records.first { $0.id == article.id }?.body == article.body)
    #expect(workspace.records.first { $0.id == article.id }?["state"] == "draft")
}

@Test @MainActor func xArticleRejectsStaleTextAccountChangesAndUnapprovedAgentPublishing() async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    var account = articleAccount()
    var writes = 0
    let publisher = XArticlePublisher(workspace: workspace, transport: .init { _ in writes += 1; throw URLError(.badURL) }, authorize: { account })
    let plan = try await publisher.review(article)
    account = articleAccount("reconnected")
    await #expect(throws: Error.self) { _ = try await publisher.publish(plan) }
    account = articleAccount()
    await #expect(throws: Error.self) { _ = try await publisher.publish(plan, fromAgent: true) }
    var edited = article; edited["body"] = "Author changed this."; _ = try workspace.save(edited)
    await #expect(throws: Error.self) { _ = try await publisher.publish(plan) }
    #expect(writes == 0)
}

@Test @MainActor func mobileXArticleRequestIsCompatibleIdempotentAndBindsReviewedVersion() async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    let change = CompanionLibrary.Change(action: .note, itemID: article.id, revision: article["updatedAt"],
        text: "Publish X article", publishesXArticle: true, xArticleAccountKey: articleAccount().connectionKey)
    #expect(change.valid)
    var library = CompanionLibrary(workspaceID: UUID())
    #expect(throws: CompanionLibraryError.self) { try library.enqueue(change) }
    library.supportsXArticlePublishing = true; try library.enqueue(change)
    #expect(try workspace.applyCompanionLibraryChange(change).error == nil)
    #expect(try workspace.applyCompanionLibraryChange(change).error == nil)
    var edited = article; edited["body"] = "A newer author edit."; _ = try workspace.save(edited)
    var writes = 0
    await workspace.publishPendingXArticles(publisher: .init(workspace: workspace, transport: .init { _ in
        writes += 1; throw URLError(.badURL)
    }, authorize: { articleAccount() }))
    #expect(writes == 0)
    #expect(workspace.records.first { $0.id == article.id }?.body == "A newer author edit.")
}

@Test @MainActor func linkedArticleResolvesOnlyForPublishedSameProjectAndPreservesThreadOrder() async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reference = try #require(article.referenceID)
    let reply = XReplyArticle.attach(reference, to: "Read the manifesto.\n\nHere’s the full X article.")
    let parts = ["Opening post", reply, "Newsletter: https://example.org/news", "Discord: https://example.org/join"]
    var draft = WorkspaceRecord.new("draft", projectID: article.projectID)
    draft["platform"] = "x"
    draft["format"] = "thread"
    draft["content"] = parts.joined(separator: XThreadText.separator)
    draft = try workspace.save(draft)
    var sent: [String] = []
    let publisher = SocialPublisher(workspace: workspace, transport: .init { request in
        let payload = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let previous = (payload["reply"] as? [String: String])?["in_reply_to_tweet_id"]
        #expect(previous == (sent.isEmpty ? nil : String(sent.count)))
        sent.append(try #require(payload["text"] as? String))
        return (Data("{\"data\":{\"id\":\"\(sent.count)\"}}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }, authorize: { _ in articleAccount() })
    await #expect(throws: Error.self) { _ = try await publisher.review(draft) }
    #expect(sent.isEmpty)
    let articlePublisher = XArticlePublisher(workspace: workspace, transport: .init { request in
        let payload = request.url!.path.hasSuffix("/publish") ? #"{"data":{"post_id":"789"}}"# : #"{"data":{"id":"456"}}"#
        return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, authorize: { articleAccount() })
    _ = try await articlePublisher.publish(articlePublisher.review(article))
    let published = try #require(workspace.records.first { $0.id == article.id })
    let review = try await publisher.review(draft)
    #expect(review.posts[0] == parts[0] + "\n" + published["articleURL"])
    #expect(review.posts[1] == XReplyArticle(reply).copy + "\n" + published["articleURL"])
    #expect(XThreadText.weight(reply) == XThreadText.weight(review.posts[1]))
    #expect(review.posts[2...] == parts[2...])
    _ = try await publisher.publish(review)
    #expect(sent == review.posts)
    draft.fields["projectId"] = "another-project"
    #expect(throws: Error.self) {
        try SocialPublishPlan(draft: draft, account: articleAccount(), imageURL: nil, articles: [published])
    }
}

@Test(arguments: [true, false], [true, false])
@MainActor func xPostPublishesWithItsArticleAndRetriesWithoutRepublishingArticle(opening: Bool, failsFirstPost: Bool) async throws {
    let (workspace, article, folder) = try articleWorkspace()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reference = try #require(article.referenceID)
    var draft = WorkspaceRecord.new("draft", projectID: article.projectID)
    draft["platform"] = "x"
    draft["format"] = "thread"
    draft["title"] = "Our launch"
    if opening { draft["xArticleID"] = article.id }
    let reply = "Here's the full story."
    draft["content"] = ["The opening post.", opening ? reply : XReplyArticle.attach(reference, to: reply)]
        .joined(separator: XThreadText.separator)
    draft = try workspace.save(draft)

    var requests: [String] = []
    var postedTexts: [String] = []
    let publisher = SocialPublisher(workspace: workspace, transport: .init { request in
        let url = try #require(request.url)
        requests.append(url.path)
        let result: String
        let status: Int
        switch url.path {
        case "/2/articles/draft":
            result = #"{"data":{"id":"456"}}"#; status = 201
        case "/2/articles/456/publish":
            result = #"{"data":{"post_id":"789"}}"#; status = 200
        case "/2/tweets":
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let text = try #require(payload["text"] as? String)
            #expect(!text.contains(XPostArticleLinks.pendingURL))
            if failsFirstPost && requests.count == 3 {
                result = #"{"detail":"Please retry"}"#; status = 429
            } else {
                postedTexts.append(text)
                result = #"{"data":{"id":"\#(postedTexts.count + 100)"}}"#; status = 201
            }
        default: throw WorkspaceError("Unexpected fixture URL.")
        }
        return (Data(result.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }, authorize: { _ in articleAccount() })
    let pair = try #require(try await publisher.reviewXArticlePost(draft))
    #expect(pair.articles.map(\.articleID) == [article.id])
    #expect(requests.isEmpty)
    #expect(throws: WorkspaceError.self) {
        try workspace.scheduleDraft(draft, at: Date.now.addingTimeInterval(86400))
    }
    if failsFirstPost {
        await #expect(throws: WorkspaceError.self) { _ = try await publisher.publishXArticlePost(pair) }
        #expect(requests == ["/2/articles/draft", "/2/articles/456/publish", "/2/tweets"])
        let retry = try #require(workspace.records.first { $0.id == draft.id })
        #expect(try await publisher.reviewXArticlePost(retry) == nil)
        let revised = try await publisher.review(retry)
        _ = try await publisher.publish(revised)
    } else {
        let receipt = try await publisher.publishXArticlePost(pair)
        #expect(receipt["status"] == "published")
    }
    let url = "\nhttps://x.com/i/web/status/789"
    #expect(postedTexts == ["The opening post." + url, reply + (opening ? "" : url)])
    #expect(requests == ["/2/articles/draft", "/2/articles/456/publish"] +
        Array(repeating: "/2/tweets", count: failsFirstPost ? 3 : 2))
}
