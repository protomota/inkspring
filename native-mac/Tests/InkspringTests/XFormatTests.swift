import Foundation
@testable import InkspringSchedule
import Testing
@testable import Inkspring

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
