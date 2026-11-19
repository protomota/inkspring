import Foundation
import Testing
@testable import Inkspring
@testable import InkspringSchedule

@Test @MainActor func scriptsKeepFullTextHistoryAndStayOutOfPublishing() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    var script = WorkspaceRecord.new("script", projectID: workspace.projectID)
    script["title"] = "Hallway manifesto"
    script["body"] = String(repeating: "We build useful skills.\n\n", count: 1500)
    script.fields["schedule"] = ["status": "queued", "slotAt": "2030-01-01T12:00:00Z"]
    script.fields["sendEmail"] = true
    script = try workspace.save(script)
    #expect(script.referenceID != nil)
    #expect(script.body.count > 30_000)
    #expect(script.fields["schedule"] == nil && script.fields["sendEmail"] == nil)
    #expect(script["platform"] == "youtube")
    let original = try #require(workspace.revisionHistory(for: script).first)
    script["body"] += "Final spoken sentence.\n"
    script = try workspace.save(script)
    let restarted = Workspace(directory: directory)
    #expect(restarted.records.first { $0.id == script.id }?.body == script.body)
    #expect(try restarted.revisionHistory(for: script).count == 2)
    var snapshot = restarted.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.items.allSatisfy { $0.id != script.id })
    #expect(snapshot.newsletters?.allSatisfy { $0.id != script.id } == true)
    #expect(snapshot.scripts?.first?.referenceID == script.referenceID)
    let fullText = try snapshot.separateFullText()
    let text = try #require(fullText)
    #expect(snapshot.scripts?.first?.shortened == true)
    var decoded = try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(snapshot))
    try decoded.applyFullText(text)
    #expect(decoded.scripts?.first?.body == script.body)
    #expect(decoded.scripts?.first?.history?.count == 2)
    let restored = try restarted.restoreRevision(original, to: script)
    #expect(restored.body == original.text)
    #expect(try restarted.revisionHistory(for: restored).count == 3)
    let schedule = CompanionLibrary.Change(action: .scheduleDraft, itemID: script.id, revision: restored["updatedAt"], text: "2030-01-01T12:00:00Z")
    #expect(try restarted.applyCompanionLibraryChange(schedule).error != nil)
    #expect(throws: WorkspaceError.self) { try restarted.scheduleDraft(restored, at: Date.now.addingTimeInterval(3600)) }
}

@Test @MainActor func mobileScriptCreationIsIdempotentAndEditsMergeWithMac() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    let create = CompanionLibrary.Change(action: .addIdea, itemID: workspace.projectID,
        title: "Hallway", text: "Opening.\n\nMiddle.\n\nClosing.\n", createsScript: true)
    #expect(create.valid)
    #expect(try workspace.applyCompanionLibraryChange(create).error == nil)
    #expect(try workspace.applyCompanionLibraryChange(create).error == nil)
    let id = create.id.uuidString.lowercased()
    let original = try #require(workspace.records.first { $0.id == id })
    #expect(workspace.records.filter { $0.id == id }.count == 1)
    var mac = original
    mac["body"] = "Mac opening.\n\nMiddle.\n\nClosing.\n"
    mac["title"] = "Mac title"
    _ = try workspace.save(mac)
    let mobile = CompanionLibrary.Change(action: .editDraft, itemID: id, revision: original["updatedAt"], title: original.title,
        text: "Opening.\n\nMiddle.\n\nMobile closing.\n", baseNewsletterText: original.body, editsScript: true, baseScriptTitle: original.title)
    #expect(mobile.valid)
    #expect(try workspace.applyCompanionLibraryChange(mobile).error == nil)
    let merged = try #require(workspace.records.first { $0.id == id })
    #expect(merged.body == "Mac opening.\n\nMiddle.\n\nMobile closing.\n")
    #expect(merged.title == "Mac title")
    let conflict = CompanionLibrary.Change(action: .editDraft, itemID: id, revision: original["updatedAt"], title: "Mobile title",
        text: merged.body, baseNewsletterText: merged.body, editsScript: true, baseScriptTitle: original.title)
    #expect(try workspace.applyCompanionLibraryChange(conflict).error != nil)
}

@Test func scriptOutboxWaitsForCapableMacAndCreationReceipt() throws {
    let workspaceID = UUID()
    let creationID = UUID()
    var outbox = CompanionLibraryOutbox()
    let id = creationID.uuidString.lowercased()
    outbox.entries.append(.init(id: creationID, action: .addIdea, itemID: "project", revision: "", title: "Script", text: "", workspaceID: workspaceID, account: "account", createsScript: true))
    outbox.queueNewsletterEdit(.init(id: UUID(), action: .editDraft, itemID: id, revision: "pending-add", title: "Script", text: "First edit.\n\n", workspaceID: workspaceID, account: "account", editsScript: true, afterNewsletterEdit: creationID, baseNewsletterText: ""))
    var library = CompanionLibrary(workspaceID: workspaceID)
    library.supportsDraftEdits = true
    library.projects = [.init(id: "project", name: "Project")]
    #expect(outbox.prepare(for: library, account: "account").isEmpty)
    library.supportsScripts = true
    #expect(outbox.prepare(for: library, account: "account").map(\.id) == [creationID])
    library.scripts = [.init(id: id, revision: "mac-1", kind: .script, projectID: "project", title: "Script", body: "", shortened: false, platform: "youtube", status: "draft", notes: [])]
    library.results = [.init(id: creationID, newsletterRevision: "mac-1")]
    let edits = outbox.prepare(for: library, account: "account")
    #expect(edits.count == 1)
    #expect(edits.first?.text == "First edit.\n\n")
    #expect(edits.first?.editsScript == true)
}

@Test @MainActor func scriptMCPPreservesAuthoredTextWithoutGenerationAndProtectsEdits() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    try workspace.set("mcpEnabled", to: true)
    let agent = AgentMCP(workspace: workspace, credentialEnvironment: [:])
    func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        let response = await agent.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let result = response?["result"] as? [String: Any] ?? [:]
        return result["structuredContent"] as? [String: Any] ?? result
    }
    let body = "We build real skills.\n\nWe protect our signal.\n"
    let args: [String: Any] = ["project_id": workspace.projectID, "title": "A script", "body": body, "request_key": "hallway"]
    let saved = await call("save_script", args)
    let id = try #require(saved["id"] as? String)
    #expect(saved["body"] as? String == body)
    let retry = await call("save_script", args)
    #expect(retry["id"] as? String == id)
    let read = await call("get_script", ["script_id": saved["referenceId"] as? String ?? id])
    #expect(read["body"] as? String == body)
    _ = await call("save_script", ["script_id": id, "body": "Must not overwrite."])
    #expect(workspace.records.first { $0.id == id }?.body == body)
    _ = await call("save_script", ["script_id": id, "expected_updated_at": saved["updatedAt"] as? String ?? "", "body": body + "A revision."])
    #expect(workspace.records.first { $0.id == id }?.body == body + "A revision.")
}

@Test @MainActor func xArticleStaysDistinctFromTweetsAndSurvivesBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory.appending(path: "source"))
    try workspace.set("mcpEnabled", to: true)
    let agent = AgentMCP(workspace: workspace, credentialEnvironment: [:])
    let body = "# I started a cult\n\n" + String(repeating: "We build skills that matter.\n\n", count: 200)
    let response = await agent.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "save_article", "arguments": ["project_id": workspace.projectID, "title": "I started a cult", "body": body, "request_key": "article"]]])
    let result = response?["result"] as? [String: Any]
    #expect(result?["isError"] as? Bool != true)
    var article = try #require(workspace.records.first { $0.kind == "article" })
    #expect(article["platform"] == "x" && article.body == body)
    #expect(article.referenceID != nil)
    let first = try #require(workspace.revisionHistory(for: article).first)
    let edit = CompanionLibrary.Change(action: .editDraft, itemID: article.id, revision: article["updatedAt"], title: article.title,
        text: body + "Closing.\n", baseNewsletterText: body, editsScript: true, baseScriptTitle: article.title, writingKind: "article")
    #expect(edit.valid)
    #expect(try workspace.applyCompanionLibraryChange(edit).error == nil)
    article = try #require(workspace.records.first { $0.id == article.id })
    let snapshot = workspace.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.articles?.first?.kind == .article)
    #expect(snapshot.items.allSatisfy { $0.id != article.id })
    #expect(snapshot.scripts?.isEmpty == true)
    let zip = directory.appending(path: "writing.zip")
    try workspace.exportBackup(to: zip)
    let restored = Workspace(directory: directory.appending(path: "restored"))
    let (backup, files) = try WorkspaceBackup.stage(zip, in: #require(restored.directory))
    try restored.apply(backup, files: files)
    let current = try #require(restored.records.first { $0.id == article.id })
    #expect(current.body == article.body)
    #expect(try restored.revisionHistory(for: current).contains { $0.id == first.id })
    let scheduled = CompanionLibrary.Change(action: .scheduleDraft, itemID: article.id, revision: article["updatedAt"], text: "2030-01-01T12:00:00Z")
    #expect(try workspace.applyCompanionLibraryChange(scheduled).error != nil)
}
