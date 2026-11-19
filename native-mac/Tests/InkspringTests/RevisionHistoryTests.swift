import Foundation
import Testing
@testable import Inkspring
@testable import InkspringSchedule

@Test @MainActor func everyPostSaveSurvivesRestartAndRestoreKeepsNewerVersions() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var post = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    post["title"] = "Original title"
    post["content"] = ["Opening.\n\nA paragraph.", "Read more: https://example.com/news", "Join us: https://example.com/join"].joined(separator: XThreadText.separator)
    post["format"] = "thread"
    post = try workspace.save(post)
    let original = try #require(workspace.revisionHistory(for: post).first)
    post["title"] = "Changed title"
    post["content"] = "A later edit."
    post["format"] = "post"
    post = try workspace.save(post)
    let newer = post
    let reopened = Workspace(directory: folder)
    #expect(try reopened.revisionHistory(for: post).count == 2)
    let restored = try reopened.restoreRevision(original, to: newer)
    #expect(restored.body == original.text)
    #expect(restored.title == original.title)
    #expect(restored["format"] == "thread")
    #expect(restored["updatedAt"] > newer["updatedAt"])
    #expect(restored.scheduleStatus != "queued")
    #expect(try reopened.revisionHistory(for: restored).count == 3)
    #expect(try reopened.revisionHistory(for: restored).contains { $0.text == newer.body })
    #expect(throws: WorkspaceError.self) { try reopened.restoreRevision(original, to: newer) }
}

@Test @MainActor func newsletterHistoryAndSubtitlesSurviveBackupAndRestore() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder.appending(path: "source"))
    var newsletter = WorkspaceRecord.new("newsletter", projectID: workspace.projectID)
    newsletter["title"] = "Original newsletter"
    newsletter["subtitle"] = "Original subtitle"
    newsletter["body"] = "# Original\n\n[Read](https://example.com/)"
    newsletter = try workspace.save(newsletter)
    let first = try #require(workspace.revisionHistory(for: newsletter).first)
    newsletter["body"] = "Updated body."
    newsletter["subtitle"] = "Updated subtitle"
    newsletter = try workspace.save(newsletter)
    let backupURL = folder.appending(path: "history.zip")
    try workspace.exportBackup(to: backupURL)
    let destination = Workspace(directory: folder.appending(path: "restored"))
    let (backup, files) = try WorkspaceBackup.stage(backupURL, in: #require(destination.directory))
    try destination.apply(backup, files: files)
    let current = try #require(destination.records.first { $0.id == newsletter.id })
    #expect(try destination.revisionHistory(for: current).contains { $0.id == first.id })
    let restored = try destination.restoreRevision(first, to: current)
    #expect(restored.body == first.text)
    #expect(restored["subtitle"] == "Original subtitle")
    #expect(restored["state"] == "draft")
    #expect(try destination.revisionHistory(for: restored).contains { $0.text == "Updated body." })
}

@Test @MainActor func mobileHistoryRoundTripsWithoutReplacingCurrentWriting() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var post = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    post["title"] = "Current"
    post["content"] = "Current Mac text."
    post = try workspace.save(post)
    let mobile = ContentRevision(savedAt: WorkspaceRecord.timestamp, title: "Mobile", text: "An intermediate offline save.", format: "post", source: "iPhone")
    let request = CompanionLibrary.Change(action: .saveRevision, itemID: post.id, historySnapshot: mobile)
    #expect(request.valid)
    #expect(try workspace.applyCompanionLibraryChange(request).error == nil)
    #expect(try workspace.applyCompanionLibraryChange(request).error == nil)
    #expect(workspace.records.first { $0.id == post.id }?.body == post.body)
    #expect(workspace.records.first { $0.id == post.id }?["updatedAt"] == post["updatedAt"])
    #expect(try workspace.revisionHistory(for: post).filter { $0.id == mobile.id }.count == 1)
    var library = workspace.makeCompanionLibrary(workspaceID: UUID())
    let before = try #require(library.items.first { $0.id == post.id })
    #expect(before.history?.contains(mobile) == true)
    let payload = try library.separateFullText()
    let data = try #require(payload)
    #expect(library.items.first { $0.id == post.id }?.history == nil)
    var delivered = try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(library))
    try delivered.applyFullText(data)
    #expect(delivered.items.first { $0.id == post.id }?.history == before.history)
    #expect(delivered.items.first { $0.id == post.id }?.body == post.body)
}

@Test @MainActor func mobileNewsletterRestorePreservesMetadataAndRejectsStaleRestores() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var newsletter = WorkspaceRecord.new("newsletter", projectID: workspace.projectID)
    newsletter["title"] = "New title"
    newsletter["subtitle"] = "New subtitle"
    newsletter["body"] = "Same body."
    newsletter = try workspace.save(newsletter)
    let restore = CompanionLibrary.Change(action: .editDraft, itemID: newsletter.id, revision: newsletter["updatedAt"],
        title: "Old title", text: newsletter.body, editsNewsletter: true, restoresRevision: true, subtitle: "Old subtitle")
    #expect(restore.valid)
    #expect(try workspace.applyCompanionLibraryChange(restore).error == nil)
    let saved = try #require(workspace.records.first { $0.id == newsletter.id })
    #expect(saved.title == "Old title")
    #expect(saved["subtitle"] == "Old subtitle")
    let stale = CompanionLibrary.Change(action: .editDraft, itemID: newsletter.id, revision: newsletter["updatedAt"],
        title: "Stale title", text: "Stale body", editsNewsletter: true, restoresRevision: true)
    #expect(try workspace.applyCompanionLibraryChange(stale).error != nil)
    #expect(workspace.records.first { $0.id == newsletter.id }?.title == saved.title)
}

@Test func coalescedNewsletterSavesKeepIndependentHistoryDelivery() throws {
    let workspaceID = UUID()
    let first = ContentRevision(savedAt: "2026-11-19T12:00:00Z", title: "Title", text: "First offline save", source: "iPhone")
    let second = ContentRevision(savedAt: "2026-11-19T12:00:01Z", title: "Title", text: "Second offline save", source: "iPhone")
    var outbox = CompanionLibraryOutbox()
    for version in [first, second] {
        outbox.entries.append(.init(id: UUID(), action: .saveRevision, itemID: "newsletter", revision: "", title: "", text: "",
                                    workspaceID: workspaceID, account: "owner", historySnapshot: version))
        outbox.queueNewsletterEdit(.init(id: UUID(), action: .editDraft, itemID: "newsletter", revision: "base", title: "", text: version.text,
                                        workspaceID: workspaceID, account: "owner", editsNewsletter: true, newsletterPrepared: false))
    }
    let restored = try JSONDecoder().decode(CompanionLibraryOutbox.self, from: JSONEncoder().encode(outbox))
    #expect(restored.entries.filter { $0.action == .editDraft }.count == 1)
    #expect(restored.entries.compactMap { $0.change?.historySnapshot } == [first, second])
}

@Test @MainActor func mcpReadsAndRestoresHistoryWithConflictProtection() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["content"] = "Original copy."
    draft = try workspace.save(draft)
    let original = try #require(workspace.revisionHistory(for: draft).first)
    draft["content"] = "Later copy."
    draft = try workspace.save(draft)
    let agent = AgentMCP(workspace: workspace)
    func call(_ name: String, _ fields: [String: Any]) async -> [String: Any] {
        let response = await agent.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": fields]])
        return response?["result"] as? [String: Any] ?? [:]
    }
    let listed = await call("list_revisions", ["content_id": draft.id])
    #expect((listed["structuredContent"] as? [String: Any])?["revisions"] as? [[String: String]] != nil)
    let stale = await call("restore_revision", ["content_id": draft.id, "revision_id": original.id, "expected_updated_at": "stale"])
    #expect(stale["isError"] as? Bool == true)
    let restored = await call("restore_revision", ["content_id": draft.id, "revision_id": original.id, "expected_updated_at": draft["updatedAt"]])
    #expect(restored["isError"] as? Bool != true)
    #expect(workspace.records.first { $0.id == draft.id }?.body == "Original copy.")
    #expect(try workspace.revisionHistory(for: draft).count == 3)
}
