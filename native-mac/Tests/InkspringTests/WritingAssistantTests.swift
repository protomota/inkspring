import Foundation
import Testing
@testable import Inkspring
@testable import InkspringSchedule

@Test(arguments: ["draft", "idea"]) @MainActor
func socialWritingRequestsApplyOnceAndRetainTheirComments(kind: String) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    var record = WorkspaceRecord.new(kind, projectID: workspace.projectID)
    record[kind == "idea" ? "topic" : "title"] = "Useful tools"
    let longIdea = String(repeating: "Preserve this context about our tools and the people who use them. ", count: 10)
    record[kind == "idea" ? "text" : "content"] = kind == "idea" ? longIdea : "We build useful tools."
    record["platform"] = "x"
    record = try workspace.save(record)
    let request = CompanionLibrary.Change(action: .note, itemID: record.id, revision: record["updatedAt"],
        text: "Make this clearer.", requestsWritingHelp: true)
    #expect(try workspace.applyCompanionLibraryChange(request).error == nil)
    var calls = 0
    let expected = kind == "idea" ? String(longIdea.dropLast()) : "We build tools that save people time."
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        calls += 1
        return ["text": expected, "reply": "Clarified the goal."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await workspace.runDraftRevisionComments(model: model)
    await workspace.runDraftRevisionComments(model: model)
    let revised = try #require(workspace.records.first { $0.id == record.id })
    #expect(calls == 1)
    #expect(revised.body == expected)
    #expect(revised.comments.count == 1)
    #expect(revised.appliedRevisionCommentIDs == [request.id.uuidString.lowercased()])
}

@Test @MainActor func failedWritingRequestKeepsDraftAndRetriesSafely() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    var record = WorkspaceRecord.new("newsletter", projectID: workspace.projectID)
    record["title"] = "Original"; record["body"] = "Original text."
    record = try workspace.save(record)
    try workspace.addComment(to: record, text: "Make it clearer.", revisionRequestID: "request")
    let failed = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        throw WorkspaceError("Internal provider detail")
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await workspace.runDraftRevisionComments(model: failed)
    let retained = try #require(workspace.records.first { $0.id == record.id })
    #expect(retained.body == "Original text." && retained.pendingRevisionComments.count == 1)
    #expect(!retained["writingRequestError"].contains("Internal provider"))
    #expect(retained["writingRequestError"].contains("safe"))
    let success = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        ["body": "Clearer text."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await workspace.runDraftRevisionComments(model: success)
    let revised = try #require(workspace.records.first { $0.id == record.id })
    #expect(revised.body == "Clearer text." && revised.pendingRevisionComments.isEmpty)
    #expect(revised["writingRequestError"].isEmpty)
}

@Test(arguments: ["newsletter", "article", "script"]) @MainActor
func writingRequestCreatesBriefOnMacAndRetainsHistory(kind: String) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let creation = CompanionLibrary.Change(action: .addIdea, itemID: workspace.projectID,
        title: "A useful brief", createsScript: true, writingKind: kind)
    #expect(creation.valid)
    #expect(try workspace.applyCompanionLibraryChange(creation).error == nil)
    let id = creation.id.uuidString.lowercased()
    var record = try #require(workspace.records.first { $0.id == id })
    #expect(record.kind == kind && record.body.isEmpty)
    let request = CompanionLibrary.Change(action: .note, itemID: id, revision: record["updatedAt"],
        text: "Write a quick brief about local AI models.", requestsWritingHelp: true)
    #expect(request.valid)
    #expect(try workspace.applyCompanionLibraryChange(request).error == nil)
    #expect(try workspace.applyCompanionLibraryChange(request).error == nil)
    var calls = 0
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { instructions, input in
        calls += 1
        #expect(instructions.contains("complete revised document"))
        #expect((input["record"] as? [String: String])?["body"] == "")
        return ["body": "# Local AI models\n\nA useful brief with two clear points.", "title": "Local AI models", "reply": "Wrote a concise brief."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await workspace.runDraftRevisionComments(model: model)
    await workspace.runDraftRevisionComments(model: model)
    #expect(calls == 1)
    record = try #require(workspace.records.first { $0.id == id })
    #expect(record.title == "Local AI models")
    #expect(record.body.contains("two clear points"))
    #expect(record.appliedRevisionCommentIDs == [request.id.uuidString.lowercased()])
    #expect(record.comments.count == 1)
    #expect(try workspace.revisionHistory(for: record).contains { $0.text.isEmpty })
    let snapshot = workspace.makeCompanionLibrary(workspaceID: UUID())
    let synced = try #require(((snapshot.newsletters ?? []) + (snapshot.articles ?? []) + (snapshot.scripts ?? [])).first { $0.id == id })
    #expect(synced.noteStates == ["applied"] && synced.writingReply == "Wrote a concise brief.")
    #expect(synced.body == record.body)
    #expect(record.schedule.isEmpty)
}

@Test func newWritingRequestsAndNewsletterCreationWaitForCompatibleMac() throws {
    var library = CompanionLibrary(workspaceID: UUID())
    library.supportsScripts = true; library.supportsDraftEdits = true; library.supportsNewsletterEdits = true
    let create = CompanionLibrary.Change(action: .addIdea, itemID: "project", title: "Newsletter", createsScript: true, writingKind: "newsletter")
    let request = CompanionLibrary.Change(action: .note, itemID: "newsletter", revision: "1", text: "Write a brief.", requestsWritingHelp: true)
    #expect(create.valid && request.valid)
    #expect(throws: CompanionLibraryError.self) { try library.enqueue(create) }
    #expect(throws: CompanionLibraryError.self) { try library.enqueue(request) }
    library.supportsWritingTools = true
    try library.enqueue(create); try library.enqueue(request)
    #expect(library.pending.count == 2)
    let malformed = CompanionLibrary.Change(action: .deleteItem, itemID: "draft", revision: "1", requestsWritingHelp: true)
    #expect(!malformed.valid)
}

@Test @MainActor func agentRewriteMergesIndependentChangesAndDoesNotOverwriteConcurrentWriting() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var article = WorkspaceRecord.new("article", projectID: workspace.projectID)
    article["title"] = "Article"; article["body"] = "Opening.\n\nMiddle.\n\nClosing."
    article = try workspace.save(article)
    let base = article
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        var current = try #require(workspace.records.first { $0.id == base.id })
        current["body"] = "Opening.\n\nMiddle.\n\nAuthor closing."
        _ = try workspace.save(current)
        return ["body": "Agent opening.\n\nMiddle.\n\nClosing."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    let revised = try await ContentStudio(workspace: workspace, model: model).rewrite(base, notes: "Improve the opening.")
    #expect(revised.body == "Agent opening.\n\nMiddle.\n\nAuthor closing.")
    let conflict = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        var current = try #require(workspace.records.first { $0.id == revised.id })
        current["body"] = "Author replacement."
        _ = try workspace.save(current)
        return ["body": "Agent replacement."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await #expect(throws: WorkspaceError.self) { _ = try await ContentStudio(workspace: workspace, model: conflict).rewrite(revised, notes: "Replace this.") }
    #expect(workspace.records.first { $0.id == revised.id }?.body == "Author replacement.")
}

@Test func newsletterTitleCoalescingKeepsTheOriginalMergeBase() throws {
    let id = UUID()
    var outbox = CompanionLibraryOutbox()
    outbox.queueNewsletterEdit(.init(id: id, action: .editDraft, itemID: "newsletter", revision: "1", title: "New title", text: "Body.", baseScriptTitle: "Original title", editsNewsletter: true, newsletterPrepared: false, baseNewsletterText: "Body."))
    outbox.queueNewsletterEdit(.init(id: UUID(), action: .editDraft, itemID: "newsletter", revision: "1", title: "", text: "Edited body.", editsNewsletter: true, baseNewsletterText: "Body."))
    #expect(outbox.entries.count == 1)
    #expect(outbox.entries[0].title == "New title")
    #expect(outbox.entries[0].baseScriptTitle == "Original title")
    var bodyFirst = CompanionLibraryOutbox()
    bodyFirst.queueNewsletterEdit(.init(id: UUID(), action: .editDraft, itemID: "newsletter", revision: "1", title: "", text: "First body edit.", editsNewsletter: true, newsletterPrepared: false, baseNewsletterText: "Body."))
    bodyFirst.queueNewsletterEdit(.init(id: UUID(), action: .editDraft, itemID: "newsletter", revision: "1", title: "New title", text: "Second body edit.", baseScriptTitle: "Original title", editsNewsletter: true, baseNewsletterText: "First body edit."))
    #expect(bodyFirst.entries[0].baseScriptTitle == "Original title")
    #expect(bodyFirst.entries[0].change?.needsWritingTools == true)
    #expect(bodyFirst.entries[0].baseNewsletterText == "Body.")
}
