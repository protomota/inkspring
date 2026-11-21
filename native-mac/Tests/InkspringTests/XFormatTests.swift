import Foundation
@testable import InkspringSchedule
import Testing
@testable import Inkspring

@Test func mobileParagraphEditsWaitSafelyForACompatibleMac() throws {
    let workspaceID = UUID()
    var library = CompanionLibrary(workspaceID: workspaceID)
    library.supportsDraftEdits = true
    library.supportsXThreads = true
    library.items = [.init(id: "draft", revision: "1", kind: .draft, projectID: "project", title: "Title",
                          body: "Legacy opening.\n\nLegacy reply.", shortened: false, platform: "x", status: "draft", notes: [])]
    let text = ["Opening.\n\nA paragraph.", "Read more: https://example.com/"].joined(separator: XThreadText.separator)
    let change = CompanionLibrary.Change(action: .editDraft, itemID: "draft", revision: "1", title: "Title", text: text, xFormat: "followup")
    var outbox = CompanionLibraryOutbox()
    outbox.entries = [.init(id: change.id, action: .editDraft, itemID: "draft", revision: "1", title: "Title",
                            text: text, workspaceID: workspaceID, account: "owner", xFormat: "followup")]
    #expect(outbox.prepare(for: library, account: "owner").isEmpty)
    #expect(outbox.entries.first?.text == text)
    #expect(throws: CompanionLibraryError.self) { try library.enqueue(change) }
    #expect(library.items.first?.body == "Legacy opening.\n\nLegacy reply.")
    library.supportsXParagraphs = true
    #expect(outbox.prepare(for: library, account: "owner") == [change])
    try library.enqueue(change)
    #expect(library.pending.first?.text == text)
}

@Test func xParagraphsAndEmptyEditingLinesAreNotReplyBoundaries() {
    let posts = ["Opening.\n\nSecond paragraph.\n", "Newsletter: https://example.com/news\n\nRead it.", "Discord: https://example.com/join"]
    let encoded = posts.joined(separator: XThreadText.separator)
    #expect(XThreadText.parts(in: encoded) == posts)
    #expect(XThreadText.posts(in: encoded).count == 3)
    #expect(XThreadText.valid(encoded, format: "thread"))
    #expect(XThreadText.singlePost(posts[1]) == posts[1])
    #expect(XThreadText.parts(in: encoded + XThreadText.separator).last == "")
    #expect(XThreadText.posts(in: "Legacy opening.\n\nLegacy reply.") == ["Legacy opening.", "Legacy reply."])
    let adjacentMarkers = "<!-- inkspring:x-reply -->\n\n<!-- inkspring:x-reply -->"
    let malformed = [posts[0], adjacentMarkers, posts[1], "", posts[2]].joined(separator: XThreadText.separator)
    #expect(XThreadText.parts(in: malformed) == [posts[0], "", "", "", posts[1], "", posts[2]])
    #expect(XThreadText.posts(in: malformed) == posts.map(XThreadText.singlePost))
}

@Test @MainActor func xParagraphsSurviveMobileSaveReloadAndPublishPlanning() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Paragraphs and replies"
    draft["format"] = "thread"
    draft["content"] = "Opening.\n\nNewsletter.\n\nDiscord."
    draft = try workspace.save(draft)
    let posts = ["Opening.\n\nAnother line.", "Newsletter.\n\nhttps://example.com/news", "Discord.\nhttps://example.com/join"]
    let edit = CompanionLibrary.Change(action: .editDraft, itemID: draft.id, revision: draft["updatedAt"],
        title: draft.title, text: posts.joined(separator: XThreadText.separator), xFormat: "thread")
    let restored = try JSONDecoder().decode(CompanionLibrary.Change.self, from: JSONEncoder().encode(edit))
    #expect(try workspace.applyCompanionLibraryChange(restored).error == nil)
    try workspace.reload()
    let saved = try #require(workspace.drafts.first { $0.id == draft.id })
    #expect(XThreadText.parts(in: saved.body) == posts)
    let account = ManagedSocialAccount(session: .init(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
        expiresAt: 2_000_000_000_000, scopes: "tweet.write"), id: "user", name: "Test", username: "test")
    let plan = try SocialPublishPlan(draft: saved, account: account, imageURL: nil)
    #expect(plan.posts == posts)
    #expect(!plan.posts.contains { $0.contains("inkspring:x-reply") })
    let mobile = workspace.makeCompanionLibrary(workspaceID: UUID())
    #expect(mobile.items.first { $0.id == draft.id }?.body == saved.body)
}

@Test @MainActor func xRevisionCanSeparateLinksIntoTwoRepliesWithoutLosingParagraphs() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["format"] = "followup"
    draft["content"] = "Opening.\n\nRead: https://example.com/news\nJoin: https://example.com/join"
    draft = try workspace.save(draft)
    let posts = ["Opening.\n\nClosing.", "Read: https://example.com/news", "Join: https://example.com/join"]
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { instructions, input in
        #expect(instructions.contains("unless the author's notes request a change"))
        #expect((input["record"] as? [String: Any])?["posts"] as? [String] == XThreadText.posts(in: draft.body))
        return ["posts": posts, "reply": "Separated the links into two replies."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    let saved = try await ContentStudio(workspace: workspace, model: model).rewrite(draft, notes: "Put each URL in its own reply.")
    #expect(saved["format"] == "thread")
    #expect(XThreadText.parts(in: saved.body) == posts)
}

@Test @MainActor func xRevisionCannotSilentlyCombineExistingReplies() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["format"] = "thread"
    let posts = ["Opening.", "Read: https://example.com/news", "Join: https://example.com/join"]
    draft["content"] = posts.joined(separator: XThreadText.separator)
    draft = try workspace.save(draft)
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        ["posts": ["Opening.", "Read: https://example.com/news\nJoin: https://example.com/join"]]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await #expect(throws: WorkspaceError.self) {
        _ = try await ContentStudio(workspace: workspace, model: model).rewrite(draft, notes: "Improve the wording.")
    }
    #expect(workspace.drafts.first { $0.id == draft.id }?.body == draft.body)
}

@Test @MainActor func xIdeaGenerationKeepsTheIdeaAndSelectedFormat() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
    idea["topic"] = "A useful manifesto"
    idea["text"] = "Read it at https://example.com/manifesto"
    idea = try workspace.save(idea)
    let originalText = idea.body
    let output = "We build tools we use.\n\nRead the manifesto: https://example.com/manifesto"
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] },
        object: { instructions, _ in
            #expect(instructions.contains("exactly two"))
            #expect(instructions.contains("supplied URLs"))
            return ["text": output]
        }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    let (kept, posts) = try await ContentStudio(workspace: workspace, model: model).pick(idea, platforms: ["x"], xFormat: "followup")
    #expect(kept.body == originalText)
    #expect(kept["status"] == "draft")
    #expect(posts.first?["format"] == "followup")
    #expect(posts.first?.body == output)
    #expect(kept.draftVersions["x"] == posts.first?.id)
}

@Test @MainActor func mobileXGenerationQueuesIdempotentlyAndThreadEditsRoundTrip() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
    idea["topic"] = "A useful manifesto"
    idea["text"] = "Our approach."
    idea = try workspace.save(idea)
    let request = CompanionLibrary.Change(action: .addIdea, itemID: idea.id, revision: idea["updatedAt"],
        title: idea.title, text: idea.body, xFormat: "thread", generatesXDraft: true)
    #expect(request.valid)
    #expect(try workspace.applyCompanionLibraryChange(request).error == nil)
    #expect(try workspace.applyCompanionLibraryChange(request).error == nil)
    let queued = workspace.records.filter { $0.fields["mobileGenerationPending"] as? Bool == true }
    #expect(queued.count == 1)
    #expect(workspace.ideas.contains { $0.id == idea.id && $0.body == idea.body })
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { input, format in
        #expect(format == "thread")
        #expect(input["brief"] as? String == idea.body)
        return ["title": "A useful manifesto", "content": "First post.\n\nSecond post.\n\nLinks: https://example.com/"]
    }, object: { _, _ in [:] }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await workspace.generateMobileXDraft(model: model)
    let draft = try #require(workspace.drafts.first { $0.id == request.id.uuidString.lowercased() })
    #expect(draft.fields["mobileGenerationPending"] == nil)
    #expect(draft["format"] == "thread")
    let snapshot = workspace.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.supportsXThreads == true)
    #expect(snapshot.items.first { $0.id == draft.id }?.format == "thread")
    let edit = CompanionLibrary.Change(action: .editDraft, itemID: draft.id, revision: draft["updatedAt"],
        title: draft.title, text: "Opening.\n\nUpdated reply.", xFormat: "followup")
    #expect(try workspace.applyCompanionLibraryChange(edit).error == nil)
    let saved = try #require(workspace.drafts.first { $0.id == draft.id })
    #expect(saved["format"] == "followup")
    #expect(XThreadText.posts(in: saved.body) == ["Opening.", "Updated reply."])
    let encoded = try JSONEncoder().encode(CompanionLibraryOutbox.Entry(id: edit.id, action: .editDraft,
        itemID: edit.itemID, revision: edit.revision, title: edit.title, text: edit.text, xFormat: edit.xFormat))
    let restored = try JSONDecoder().decode(CompanionLibraryOutbox.Entry.self, from: encoded)
    #expect(restored.change?.xFormat == "followup")
}
