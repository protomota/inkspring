import Foundation
import Testing
@testable import Inkspring

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
