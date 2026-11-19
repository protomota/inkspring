import Foundation
import Testing
import InkspringSchedule
@testable import Inkspring

@MainActor private func draftTool(_ agent: AgentMCP, _ name: String, _ arguments: [String: Any]) async -> [String: Any] {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                "params": ["name": name, "arguments": arguments]]
    let result = await agent.handle(request)?["result"] as? [String: Any] ?? [:]
    return result["structuredContent"] as? [String: Any] ?? result
}

@Test @MainActor func mcpThreadEditsKeepParagraphsAndPromoteTwoRepliesToAThread() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let agent = AgentMCP(workspace: workspace)
    let first = await draftTool(agent, "save_draft", ["project_id": workspace.projectID, "platform": "x",
        "format": "followup", "content": "Opening.\n\nLinks: https://example.com/news"])
    let posts = ["Opening.\n\nClosing.", "Read the newsletter: https://example.com/news", "Join us: https://example.com/join"]
    let saved = await draftTool(agent, "edit_draft", ["draft_id": try #require(first["id"] as? String),
        "expected_updated_at": try #require(first["updatedAt"] as? String), "format": "followup", "posts": posts])
    #expect(saved["format"] as? String == "thread")
    #expect(saved["posts"] as? [String] == posts)
    #expect(XThreadText.parts(in: saved["content"] as? String ?? "") == posts)
}

@Test @MainActor func suppliedDraftSavesExactCopyWithoutAKeyAndSurvivesRestart() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    try workspace.set("writingConnection", to: "api")
    let agent = AgentMCP(workspace: workspace, credentialEnvironment: [:])
    let body = "I started a cult.\n\nRead: https://newsletter.protomota.com\nJoin: https://protomota.com/discord\n"
    let saved = await draftTool(agent, "save_draft", ["project_id": workspace.projectID, "platform": "linkedin",
        "title": "I started a cult", "content": body])
    let id = try #require(saved["id"] as? String)
    #expect(saved["content"] as? String == body)
    #expect(saved["status"] as? String == "draft")
    #expect(saved["schedule"] == nil)
    #expect(saved["referenceId"] as? String != nil)
    let reopened = Workspace(directory: folder)
    let stored = try #require(reopened.records.first { $0.id == id })
    #expect(stored.body == body)
    #expect(stored["platform"] == "linkedin")
    #expect(stored.schedule.isEmpty)
}

@Test @MainActor func suppliedWritePostBypassesGenerationAndDoesNotDuplicateOnRetry() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let model = ContentStudio.Model(provider: "must-not-run", name: "must-not-run",
        draft: { _, _ in throw WorkspaceError("Generation must not run for supplied copy.") },
        object: { _, _ in throw WorkspaceError("Generation must not run.") },
        prompt: { _ in throw WorkspaceError("Generation must not run.") },
        image: { _ in throw WorkspaceError("Generation must not run.") }, imageProvider: "must-not-run")
    let agent = AgentMCP(workspace: workspace, model: model, credentialEnvironment: [:])
    let args: [String: Any] = ["project_id": workspace.projectID, "platform": "linkedin", "title": "Exact copy",
        "content": "Supplied copy with https://example.com/ intact.", "request_key": "test-exact-copy",
        "idea": "This must not trigger generation", "with_image": true]
    let first = await draftTool(agent, "write_post", args)
    let id = try #require(first["id"] as? String)
    let retry = await draftTool(agent, "save_draft", args)
    #expect(retry["id"] as? String == id)
    #expect(retry["updatedAt"] as? String == first["updatedAt"] as? String)
    #expect(workspace.records.filter { $0["mcpDraftRequestKey"] == "test-exact-copy" }.count == 1)
    var different = args
    different["content"] = "Different copy with the same key"
    #expect(await draftTool(agent, "save_draft", different)["isError"] as? Bool == true)
    #expect(workspace.records.first { $0.id == id }?.body == args["content"] as? String)
}

@Test @MainActor func localDraftToolsRespectAgentAccessAndReadOnlyChat() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let args: [String: Any] = ["project_id": workspace.projectID, "platform": "linkedin", "content": "A local draft."]
    let before = workspace.records.count
    let agent = AgentMCP(workspace: workspace)
    #expect(await draftTool(agent, "save_draft", args)["isError"] as? Bool == true)
    try workspace.set("mcpEnabled", to: true)
    let chat = AgentMCP(workspace: workspace, chatProjectID: workspace.projectID)
    #expect(await draftTool(chat, "save_draft", args)["isError"] as? Bool == true)
    #expect(await draftTool(chat, "write_post", args)["isError"] as? Bool == true)
    #expect(workspace.records.count == before)
    let listing = try #require(AgentMCP.tools.first { $0.name == "save_draft" })
    #expect(listing.writes)
    #expect(!listing.usesNetwork)
    #expect(AgentMCP.tools.first { $0.name == "write_post" }?.required == ["platform"])
}

@Test @MainActor func suppliedDraftRejectsInvalidCopyAndFormatsWithoutCreatingAnything() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let agent = AgentMCP(workspace: workspace)
    let before = workspace.records.count
    let invalid: [[String: Any]] = [
        ["platform": "linkedin", "content": "   "],
        ["platform": "unsupported", "content": "Text"],
        ["platform": "linkedin", "content": "Bad\0text"],
        ["platform": "linkedin", "content": String(repeating: "x", count: 40_001)],
        ["platform": "linkedin", "content": "Text", "title": String(repeating: "x", count: 201)],
        ["platform": "linkedin", "content": "Text", "format": "followup"],
        ["platform": "x", "content": "Only one post", "format": "followup"],
        ["platform": "x", "content": "Text", "format": "video"],
        ["platform": "linkedin", "content": "Text", "project_id": "missing-project"]
    ]
    for var args in invalid {
        if args["project_id"] == nil { args["project_id"] = workspace.projectID }
        #expect(await draftTool(agent, "save_draft", args)["isError"] as? Bool == true)
    }
    #expect(workspace.records.count == before)
}

@Test @MainActor func suppliedDraftCanBeEditedWithTheExistingConflictProtection() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let agent = AgentMCP(workspace: workspace)
    let first = await draftTool(agent, "save_draft", ["project_id": workspace.projectID,
        "platform": "x", "format": "followup", "content": "Opening.\n\nFollow-up: https://example.com/"])
    let id = try #require(first["id"] as? String)
    let reference = try #require(first["referenceId"] as? String)
    let revision = try #require(first["updatedAt"] as? String)
    let edited = await draftTool(agent, "edit_draft", ["draft_id": reference, "expected_updated_at": revision,
        "content": "Updated opening.\n\nFollow-up: https://example.com/"])
    #expect(edited["id"] as? String == id)
    #expect(edited["format"] as? String == "followup")
    #expect(await draftTool(agent, "edit_draft", ["draft_id": id, "expected_updated_at": revision,
        "content": "Stale overwrite"])["isError"] as? Bool == true)
    #expect(workspace.records.first { $0.id == id }?.body == edited["content"] as? String)
}
