import Foundation
import Testing
@testable import Inkspring

@Test func writingAgentArgumentsForwardTheExactModel() throws {
    for (agent, model) in [(StudioChatAgent.codex, "gpt-6.2-astra"), (.claude, "claude-fable-5-2")] {
        let output = URL(fileURLWithPath: "/tmp/answer")
        var baseline = try agent.arguments(server: "/tmp/inkspring", parameters: ["--mcp-write", "/tmp/input"],
                                           output: output, workspaceOverride: nil)
        var explicit = try agent.arguments(server: "/tmp/inkspring", parameters: ["--mcp-write", "/tmp/input"],
                                           output: output, workspaceOverride: nil, model: model)
        let modelFlag = try #require(explicit.firstIndex(of: "--model"))
        #expect(explicit[modelFlag + 1] == model)
        explicit.removeSubrange(modelFlag...modelFlag + 1)
        if agent == .claude {
            let index = try #require(baseline.firstIndex(of: "--mcp-config")) + 1
            try #require(explicit.indices.contains(index))
            let expected = try JSONSerialization.jsonObject(with: Data(baseline.remove(at: index).utf8)) as? NSDictionary
            let actual = try JSONSerialization.jsonObject(with: Data(explicit.remove(at: index).utf8)) as? NSDictionary
            #expect(try #require(actual) == #require(expected))
        }
        #expect(explicit == baseline)
    }
}

@Test @MainActor func quickPromptsSendImmediatelyAndKeepUnsentText() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let database = try #require(workspace.database)
    let project = WorkspaceRecord.new("project")
    let chat = StudioAgentChat { agent, projectID, prompt in
        #expect(agent == .claude)
        #expect(projectID == project.id)
        #expect(prompt.contains("Which drafts are closest to ready?"))
        #expect(!prompt.contains("Unsent text"))
        return "One draft is ready for review."
    }
    chat.load(projectID: project.id, database: database)
    chat.message = "Unsent text"
    chat.send("Which drafts are closest to ready?", to: .claude, project: project)
    #expect(chat.entries.map(\.text) == ["Which drafts are closest to ready?"])
    #expect(chat.message == "Unsent text")
    chat.send("Ignored while a response is pending", to: .claude, project: project)
    await chat.task?.value
    #expect(chat.entries.last?.text == "One draft is ready for review.")
    #expect(chat.recentPrompts == ["Which drafts are closest to ready?"])
}

@Test @MainActor func recentPromptsPersistPerProjectAndPutRepeatedPromptsFirst() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let database = try #require(workspace.database)
    let project = WorkspaceRecord.new("project")
    let chat = StudioAgentChat { _, _, _ in "Reply" }
    chat.load(projectID: project.id, database: database)
    for number in 1...6 {
        chat.message = "  Question \(number)  "
        chat.send(to: .codex, project: project)
        await chat.task?.value
    }
    #expect(chat.message.isEmpty)
    chat.open(nil)
    let reopened = StudioAgentChat { _, _, _ in "Reply" }
    let reopenedDatabase = try WorkspaceDatabase(url: folder.appending(path: "workspace.sqlite"))
    reopened.load(projectID: project.id, database: reopenedDatabase)
    #expect(reopened.recentPrompts == [
        "Question 6", "Question 5", "Question 4", "Question 3", "Question 2"
    ])
    reopened.send("Question 3", to: .codex, project: project)
    await reopened.task?.value
    #expect(reopened.recentPrompts == [
        "Question 3", "Question 6", "Question 5", "Question 4", "Question 2"
    ])
}

@Test @MainActor func chatHistoryOpensAndDeletesIndividualChatsOrAllProjects() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let database = try #require(workspace.database)
    let project = WorkspaceRecord.new("project")
    let otherProject = WorkspaceRecord.new("project")
    let chat = StudioAgentChat { _, _, _ in "Reply" }
    chat.load(projectID: project.id, database: database)
    chat.send("First chat", to: .claude, project: project)
    await chat.task?.value
    let firstID = try #require(chat.currentID)
    chat.open(nil)
    #expect(chat.entries.isEmpty)
    chat.send("Second chat", to: .codex, project: project)
    await chat.task?.value
    #expect(chat.history.count == 2)
    chat.open(firstID)
    #expect(chat.entries.map(\.text) == ["First chat", "Reply"])
    #expect(chat.entries.last?.agent == .claude)
    chat.delete(firstID)
    #expect(chat.entries.isEmpty)
    #expect(chat.recentPrompts == ["Second chat"])

    let otherChat = StudioAgentChat { _, _, _ in "Reply" }
    otherChat.load(projectID: otherProject.id, database: database)
    #expect(otherChat.history.isEmpty)
    #expect(otherChat.hasSavedChats)
    otherChat.send("Other project chat", to: .codex, project: otherProject)
    await otherChat.task?.value
    chat.delete()
    otherChat.load(projectID: otherProject.id, database: database)
    #expect(otherChat.history.isEmpty)
    #expect(!otherChat.hasSavedChats)
    #expect(otherChat.recentPrompts.isEmpty)
}

@Test func geminiWritingSelectionKeepsChatIndependentAndUsesSupportedCLIModelIDs() throws {
    let agent = StudioChatAgent.gemini
    #expect(StudioChatAgent.writingAgent(settings: [:]) == .selected)
    let settings = [StudioChatAgent.writingPreference: agent.rawValue, agent.modelPreferenceKey: "gemini-4-carbon-high"]
    #expect(StudioChatAgent.writingAgent(settings: settings) == .gemini)
    #expect(agent.preferredWritingModel(settings: settings) == "gemini-4-carbon-high")
    #expect(agent.preferredWritingModel(settings: [agent.modelPreferenceKey: "retired"]) == GeminiWritingAgent.defaultModel)
    for model in agent.writingModels {
        let args = try GeminiWritingAgent.arguments(model: model.id)
        let index = try #require(args.firstIndex(of: "--model"))
        #expect(args[index + 1] == model.id)
        #expect(args.contains("--sandbox"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }
    #expect(throws: WorkspaceError.self) { try GeminiWritingAgent.arguments(model: "unsupported") }
}

@Test func geminiWritesWithAnIsolatedToolFreeProfileAndOnlyReadsTheFinalReply() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let context = Data(#"{"instructions":"Return JSON","writingContext":{"brief":"line one\nline two"}}"#.utf8)
    let input = try GeminiWritingAgent.input(context: context, workingDirectory: folder)
    let event = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
    #expect(event["event"] as? String == "user")
    #expect((event["message"] as? [String: String])?["content"] == String(decoding: context, as: UTF8.self))
    #expect(input.filter { $0 == 0x0a }.count == 1)
    let profile = try String(contentsOf: folder.appending(path: ".agents/agents/inkspring-writer.md"), encoding: .utf8)
    #expect(profile.contains("tools: []"))
    #expect(profile.contains("mcpServers: []"))
    #expect(profile.contains("subagent: false"))
    #expect(!profile.contains("line one"))
    let response = """
    {"event":"step_update","step_update":{"text_delta":"unfinished"}}
    {"event":"result","result":{"status":"SUCCESS","response":"OK"}}
    """
    #expect(try GeminiWritingAgent.response(from: Data(response.utf8)) == "OK")
    #expect(throws: WorkspaceError.self) { try GeminiWritingAgent.response(from: Data(response.replacing("SUCCESS", with: "ERROR").utf8)) }
    #expect(throws: WorkspaceError.self) { try GeminiWritingAgent.response(from: Data(response.prefix(30).utf8)) }
}
