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

@Test(arguments: [true, false]) @MainActor func xIdeaGenerationMovesURLsToTheReply(includesLinks: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
    idea["topic"] = "A useful manifesto"
    let sourceLink = "https://example.com/manifesto"
    let additionalLink = "https://example.org/guide_(new)?ref=one#section"
    idea["text"] = includesLinks ? "Read it at \(sourceLink), then [see the guide](\(additionalLink))." : "We build tools we use."
    idea = try workspace.save(idea)
    let originalText = idea.body
    let opening = "We build tools we use.\n\nRead the manifesto."
    let output = includesLinks ? "We build tools we use.\n\nRead the [manifesto](\(sourceLink))." : opening
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] },
        object: { instructions, input in
            #expect(instructions.contains("Write one opening post"))
            #expect(instructions.contains("no URLs"))
            #expect(instructions.contains("what they will find and what to do") == includesLinks)
            #expect((input["ideaLinks"] as? [String]) == (includesLinks ? [sourceLink, additionalLink] : nil))
            return ["text": output, "linkCallsToAction": [
                ["url": sourceLink, "text": "Read our manifesto to learn why we build tools we use."],
                ["url": additionalLink, "text": "Follow the guide to put that approach into practice."]
            ]]
        }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    let (kept, posts) = try await ContentStudio(workspace: workspace, model: model).pick(idea, platforms: ["x"])
    #expect(kept.body == originalText)
    #expect(kept["status"] == "draft")
    let draft = try #require(posts.first)
    #expect(draft["format"] == (includesLinks ? "followup" : "post"))
    let expected = includesLinks ? [opening, "Read our manifesto to learn why we build tools we use.\n\(sourceLink)\n\nFollow the guide to put that approach into practice.\n\(additionalLink)"] : [opening]
    #expect(draft.body == expected.joined(separator: XThreadText.separator))
    let account = ManagedSocialAccount(session: .init(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
        expiresAt: 2_000_000_000_000, scopes: "tweet.write"), id: "user", name: "Test", username: "test")
    #expect(try SocialPublishPlan(draft: draft, account: account, imageURL: nil).posts == expected)
    #expect(kept.draftVersions["x"] == posts.first?.id)
}

@Test func xIdeaReplyRepairsBareRepliesAndKeepsTheExactLink() throws {
    let link = "https://inkspring.ai/?ref=welcome"
    let authored = "Read the release notes to see what changed.\nhttps://example.com/updates"
    let result = try XIdeaDraft.separate("An opening.", replies: ["Links: \(link)", authored], suppliedLinks: [link], linkCopy: [
        ["url": link, "text": "Use https://wrong.example.com/ instead."],
        ["url": "https://nowhere.example.com/", "text": "A link the author didn't give us."]
    ])
    #expect(XThreadText.posts(in: result.text) == ["An opening.", authored,
        "Download Inkspring for Mac and try it for yourself.\n\(link)"])
}

@Test func xIdeaReplyKeepsAllLinksAndSplitsOnlyAtTheXLimit() throws {
    let links = (1...14).map { "https://example.com/\($0)" }
    let opening = String(repeating: "Long copy. ", count: 30) + "Use (www.example.net/path)."
    let result = try XIdeaDraft.separate(opening, suppliedLinks: links, long: true)
    let posts = XThreadText.posts(in: result.text)
    #expect(result.format == "thread")
    #expect(posts.count == 3)
    #expect(XIdeaDraft.links(in: posts[0]).isEmpty)
    #expect(XThreadText.weight(posts[0]) > 280)
    #expect(posts.dropFirst().flatMap { XIdeaDraft.links(in: $0) } == links + ["https://www.example.net/path"])
    #expect(posts.dropFirst().allSatisfy { XThreadText.weight($0) <= 280 })
}

@Test @MainActor func mobileXGenerationQueuesIdempotentlyAndThreadEditsRoundTrip() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
    idea["topic"] = "A useful manifesto"
    idea["text"] = "Our approach. https://example.org/approach"
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
        #expect(input["ideaLinks"] as? [String] == ["https://example.org/approach"])
        return ["title": "A useful manifesto", "content": "First post. https://example.net/\n\nSecond post.\n\nLinks: https://example.com/",
            "linkCallsToAction": [["url": "https://example.org/approach", "text": "See how we put this approach into practice."]]]
    }, object: { _, _ in [:] }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await workspace.generateMobileXDraft(model: model)
    let draft = try #require(workspace.drafts.first { $0.id == request.id.uuidString.lowercased() })
    #expect(draft.fields["mobileGenerationPending"] == nil)
    #expect(draft["format"] == "thread")
    #expect(XThreadText.posts(in: draft.body) == ["First post.", "Second post.",
        "See how we put this approach into practice.\nhttps://example.org/approach\n\nFind more information here:\nhttps://example.net/\nhttps://example.com/"])
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
