import Foundation
import Testing
@testable import Inkspring

@Test @MainActor func workSourceRefreshImportsOnlyApprovedRecentNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let notes = root.appending(path: "notes")
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let current = notes.appending(path: "Recent.md")
    let old = notes.appending(path: "Old.md")
    try "---\ninternal: metadata\n---\nA fresh reference".write(to: current, atomically: true, encoding: .utf8)
    try "An old reference".write(to: old, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-72 * 3600)], ofItemAtPath: old.path)
    try FileManager.default.createSymbolicLink(at: notes.appending(path: "Linked.md"), withDestinationURL: current)

    let workspace = Workspace(directory: root.appending(path: "workspace"))
    let project = try #require(workspace.projects.first)
    try workspace.updateWorkSourceSchedule(project.id, fields: ["enabled": true, "hours": 6, "notesFolder": notes.path])
    await workspace.refreshScheduledWork()
    #expect(!workspace.records.contains { $0["origin"] == "Obsidian notes" })
    try workspace.updateWorkSourceSchedule(project.id, fields: ["nativeApproved": true])
    await workspace.refreshScheduledWork()
    let imported = workspace.records.filter { $0["origin"] == "Obsidian notes" }
    #expect(imported.count == 1)
    #expect(imported.first?.title == "Recent")
    #expect(imported.first?.body == "A fresh reference")
    #expect(workspace.workSourceSchedule(project.id)["lastCount"] as? Int == 1)
    try workspace.updateWorkSourceSchedule(project.id, fields: [:])
    await workspace.refreshScheduledWork()
    #expect(workspace.records.filter { $0["origin"] == "Obsidian notes" }.count == 1)
    #expect(workspace.workSourceSchedule(project.id)["lastCount"] as? Int == 0)
}

@Test func workContextReadsOnlyRecapsForTheSelectedFolder() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let project = root.appending(path: "project")
    let claude = root.appending(path: "Library/Application Support/Claude/claude-code-sessions")
    let codex = root.appending(path: ".codex")
    for folder in [project, claude, codex] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date.now
    for (name, folder) in [("In scope", project.path + "/feature"), ("Sibling", project.path + "-other")] {
        let data = try JSONSerialization.data(withJSONObject: [
            "title": name, "cwd": folder, "lastActivityAt": now.timeIntervalSince1970 * 1000,
            "turnWrapUp": ["description": "The local recap."]
        ])
        try data.write(to: claude.appending(path: "local_\(name).json"))
    }
    let rollout = codex.appending(path: "recent.jsonl")
    try #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Completed local work."}}"#
        .write(to: rollout, atomically: true, encoding: .utf8)
    try runFixtureProcess("/usr/bin/sqlite3", [codex.appending(path: "state_5.sqlite").path, """
        CREATE TABLE threads(title TEXT, cwd TEXT, rollout_path TEXT, updated_at INTEGER);
        INSERT INTO threads VALUES ('Codex fixture','\(project.path)','\(rollout.path)',\(Int(now.timeIntervalSince1970)));
        INSERT INTO threads VALUES ('Outside rollout','\(project.path)','\(claude.path)/local_In scope.json',\(Int(now.timeIntervalSince1970)));
        """])
    let git = ["-C", project.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
               "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"]
    try runFixtureProcess("/usr/bin/git", git + ["init", "-q"])
    try "Fixture".write(to: project.appending(path: "draft.md"), atomically: true, encoding: .utf8)
    try runFixtureProcess("/usr/bin/git", git + ["add", "draft.md"])
    try runFixtureProcess("/usr/bin/git", git + ["commit", "-qm", "Write a local draft"])
    let result = WorkContext(now: now, home: root).collect(code: project, notes: nil)
    #expect(Set(result.items.map(\.title)) == ["In scope", "Codex fixture", "Write a local draft"])
    #expect(result.items.first { $0.origin == .codex }?.text == "Completed local work.")
    #expect(result.unavailable.isEmpty)
}

private func runFixtureProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
}

@Test @MainActor func legacyJSONRestorePreservesTextAndPausesDelivery() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "legacy.json")
    let data = try JSONSerialization.data(withJSONObject: [
        "app": "inkspring-desktop", "version": 1,
        "projects": [["id": "project", "name": "Legacy"]],
        "drafts": [["id": "draft", "projectId": "project", "title": "Older post", "content": "Keep this text.",
                    "format": "image", "platform": "x", "image": ["file": "old.png"],
                    "schedule": ["status": "queued", "slotAt": "2027-01-01T12:00:00Z"]]],
        "sources": [],
        "newsletters": [["id": "news", "projectId": "project", "title": "Newsletter", "body": "Old issue",
                         "remoteId": "123", "sendEmail": true]]
    ])
    try data.write(to: file)
    let workspace = Workspace(directory: root.appending(path: "workspace"))
    let (backup, files) = try WorkspaceBackup.stage(file, in: root)
    #expect(backup.isLegacy)
    #expect(files.isEmpty)
    try workspace.apply(backup, files: files)
    let draft = try #require(workspace.records.first { $0.id == "draft" })
    #expect(draft.body == "Keep this text.")
    #expect(draft.scheduleStatus == "ready")
    #expect(draft.fields["image"] == nil)
    let newsletter = try #require(workspace.records.first { $0.id == "news" })
    #expect(newsletter["remoteId"].isEmpty)
    #expect(newsletter.fields["sendEmail"] as? Bool == false)
}
