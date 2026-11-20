import Foundation
import Testing
@testable import Inkspring
@testable import InkspringSchedule

@MainActor private func linkedInFixture() throws -> (Workspace, WorkspaceRecord, WorkspaceRecord, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let workspace = Workspace(directory: directory)
    var post = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    post["platform"] = "linkedin"
    post["title"] = "Learning in public"
    post["content"] = "# The work\n\n" + String(repeating: "We build what we need and share what we learn. ", count: 100)
    post = try workspace.save(post)
    let article = try workspace.linkedInArticleDraft(from: post)
    let linked = try #require(workspace.records.first { $0.id == post.id })
    return (workspace, article, linked, directory)
}

@Test @MainActor func linkedInConversionPreservesSourceCopyAndSavedAssociations() throws {
    let (workspace, article, post, directory) = try linkedInFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(article.isLinkedInArticle && article.body == post.body)
    #expect(article.body.count > 3_000 && post["linkedinArticleID"] == article.id)
    #expect(try workspace.linkedInArticleDraft(from: post).id == article.id)
    #expect(try workspace.linkedInShareDraft(for: article.id).id == post.id)
    #expect(throws: WorkspaceError.self) { _ = try LinkedInArticleShare.resolve(post: post, in: workspace.records) }

    let saved = try workspace.saveLinkedInArticleURL(" https://linkedin.com/pulse/learning-in-public/?trk=share#preview ", article: article)
    #expect(saved["articleURL"] == "https://www.linkedin.com/pulse/learning-in-public/")
    #expect(saved.body == article.body)
    #expect(try LinkedInArticleShare.resolve(post: post, in: workspace.records)?.url.absoluteString == saved["articleURL"])
    #expect(throws: WorkspaceError.self) { _ = try workspace.saveLinkedInArticleURL("", article: article) }
    #expect(LinkedInArticleShare.publishedURL("https://www.linkedin.com/pulse/caf%C3%A9") != nil)
    for invalid in ["http://www.linkedin.com/pulse/example/", "https://www.linkedin.com/article/new/",
                    "https://www.linkedin.com/pulse/a%2Fb/", "https://www.linkedin.com/pulse/%2E%2E/",
                    "https://www.linkedin.com@elsewhere.example/pulse/test/", "https://linkedin.com.evil.example/pulse/test/"] {
        #expect(LinkedInArticleShare.publishedURL(invalid) == nil)
    }
    let reopened = Workspace(directory: directory)
    let snapshot = reopened.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.supportsLinkedInArticles == true)
    #expect(snapshot.articles?.first(where: { $0.id == saved.id })?.platform == "linkedin")
    #expect(snapshot.articles?.first(where: { $0.id == saved.id })?.publicationURL == saved["articleURL"])
    #expect(snapshot.items.first(where: { $0.id == post.id })?.linkedInArticleID == saved.id)
    #expect(WorkspaceDraftType(record: saved) == .linkedInArticle)
}

@Test @MainActor func linkedInArticleUsesTheReviewedCardAndRejectsStaleLinks() async throws {
    let (workspace, article, post, directory) = try linkedInFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try workspace.updatePostText(post, title: post.title, text: "Read the full article.")
    let short = try #require(workspace.records.first { $0.id == post.id })
    let account = ManagedSocialAccount(session: .init(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
        expiresAt: Int64(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000), scopes: "w_member_social"),
        id: "member123", name: "Fixture", username: "", connectedAt: "fixture")
    var writes = 0
    let publisher = SocialPublisher(workspace: workspace, transport: .init { request in
        writes += 1
        #expect(request.url?.path == "/rest/posts")
        let data = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = payload["content"] as? [String: [String: String]]
        #expect(content?["article"] == ["source": "https://www.linkedin.com/pulse/learning-updated/", "title": article.title])
        #expect(payload["commentary"] as? String == short.body)
        let url = try #require(request.url)
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
            headerFields: ["x-restli-id": "urn:li:share:12345"])))
    }, authorize: { _ in account })
    await #expect(throws: WorkspaceError.self) { _ = try await publisher.review(short) }
    let saved = try workspace.saveLinkedInArticleURL("https://www.linkedin.com/pulse/learning-first/", article: article)
    let oldPlan = try await publisher.review(short)
    _ = try workspace.saveLinkedInArticleURL("https://www.linkedin.com/pulse/learning-updated/", article: saved)
    await #expect(throws: WorkspaceError.self) { _ = try await publisher.publish(oldPlan) }
    #expect(writes == 0)
    let plan = try await publisher.review(short)
    let receipt = try await publisher.publish(plan)
    #expect(writes == 1 && receipt["status"] == "published")
    #expect(workspace.records.first { $0.id == post.id }?.scheduleStatus == "posted")
}

@Test @MainActor func companionLinkedInCreationUsesArticleEditorWithoutXPublishing() throws {
    let (workspace, _, _, directory) = try linkedInFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let change = CompanionLibrary.Change(action: .addIdea, itemID: workspace.projectID,
        title: "A LinkedIn article", text: "# A beginning\n\nStart with one idea.", createsScript: true, writingKind: "linkedin-article")
    #expect(change.valid)
    var oldLibrary = CompanionLibrary(workspaceID: UUID())
    oldLibrary.supportsScripts = true
    #expect(throws: CompanionLibraryError.self) { try oldLibrary.enqueue(change) }
    let receipt = try workspace.applyCompanionLibraryChange(change)
    #expect(receipt.error == nil)
    let article = try #require(workspace.records.first { $0.id == change.id.uuidString.lowercased() })
    #expect(article.isLinkedInArticle && article.body == change.text)
    #expect(throws: WorkspaceError.self) {
        try workspace.queueXArticlePublication(id: article.id, revision: article["updatedAt"], accountKey: "fixture", requestID: UUID().uuidString)
    }
}
