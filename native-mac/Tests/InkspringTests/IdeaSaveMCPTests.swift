import Foundation
import Testing
@testable import Inkspring

@MainActor
private func ideaTool(_ agent: AgentMCP, _ name: String, _ arguments: [String: Any]) async -> [String: Any] {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                 "params": ["name": name, "arguments": arguments]]
    let result = await agent.handle(request)?["result"] as? [String: Any] ?? [:]
    return result["structuredContent"] as? [String: Any] ?? result
}

@Test @MainActor func suppliedIdeaSavesOnceAndReadsBackInFull() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let projectID = workspace.projectID
    let body = String(repeating: "Keep the exact paragraph.\n\n", count: 35) + "https://example.com/source\n"
    let args: [String: Any] = ["project_id": projectID, "title": "An exact idea", "text": body,
                               "request_key": "test-exact-idea"]
    let agent = AgentMCP(workspace: workspace, credentialEnvironment: [:])
    #expect(await ideaTool(agent, "save_idea", args)["isError"] as? Bool == true)
    try workspace.set("mcpEnabled", to: true)
    try workspace.set("writingConnection", to: "api")

    let saved = await ideaTool(agent, "save_idea", args)
    let id = try #require(saved["id"] as? String)
    #expect(saved["status"] as? String == "draft")
    #expect(saved["projectId"] as? String == projectID)
    #expect(saved["topic"] as? String == "An exact idea")
    #expect(saved["text"] as? String == body)
    for key in ["platform", "format", "suggestedPlatforms", "platforms", "kind"] {
        #expect(saved[key] == nil)
    }

    let reopened = Workspace(directory: folder)
    let freshAgent = AgentMCP(workspace: reopened, credentialEnvironment: [:])
    let retry = await ideaTool(freshAgent, "save_idea", args)
    #expect(retry["id"] as? String == id)
    #expect(retry["updatedAt"] as? String == saved["updatedAt"] as? String)
    #expect(reopened.ideas.filter { $0.id == id && $0.isPendingPostIdea }.count == 1)
    let list = await ideaTool(freshAgent, "list_ideas", ["project_id": projectID, "status": "draft"])
    #expect((list["items"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)
    let readback = await ideaTool(freshAgent, "get_idea", ["idea_id": id])
    #expect(readback["text"] as? String == body)
    #expect(readback["suggestedPlatforms"] == nil)

    var changed = args
    changed["text"] = "Different copy for the same key."
    #expect(await ideaTool(freshAgent, "save_idea", changed)["isError"] as? Bool == true)
    let chat = AgentMCP(workspace: reopened, chatProjectID: projectID)
    #expect(await ideaTool(chat, "save_idea", args)["isError"] as? Bool == true)
    #expect(await ideaTool(chat, "get_idea", ["idea_id": id])["text"] as? String == body)
    let otherChat = AgentMCP(workspace: reopened, chatProjectID: "other-project")
    #expect(await ideaTool(otherChat, "get_idea", ["idea_id": id])["isError"] as? Bool == true)

    let listing = try #require(AgentMCP.tools.first { $0.name == "save_idea" })
    #expect(listing.writes)
    #expect(!listing.usesNetwork)
}

@Test @MainActor func suppliedIdeaRejectsInvalidInputWithoutCreatingRecords() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let agent = AgentMCP(workspace: workspace)
    let recordCount = workspace.records.count
    let invalid: [[String: Any]] = [
        ["title": " ", "text": "Text"],
        ["title": "Title", "text": "\n"],
        ["title": "Title", "text": "Bad\0text"],
        ["title": String(repeating: "x", count: 141), "text": "Text"],
        ["title": "Title", "text": String(repeating: "x", count: 2_001)],
        ["title": "Title", "text": "Text", "request_key": ""],
        ["title": "Title", "text": "Text", "project_id": "missing-project"]
    ]
    for input in invalid {
        let args = ["project_id": workspace.projectID as Any].merging(input) { _, supplied in supplied }
        #expect(await ideaTool(agent, "save_idea", args)["isError"] as? Bool == true)
    }
    #expect(workspace.records.count == recordCount)
}
