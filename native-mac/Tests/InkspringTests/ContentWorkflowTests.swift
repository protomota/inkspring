import Foundation
import Testing
@testable import Inkspring

@Test @MainActor func mcpSettingsProbeUsesTheRealStdioServerAndReadsWithoutEditing() throws {
    guard let command = ProcessInfo.processInfo.environment["INKSPRING_MCP_TEST_COMMAND"] else { return }
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let records = workspace.records.map(\.id)
    try workspace.set("mcpEnabled", to: false)
    #expect(throws: WorkspaceError.self) { try AgentConnectionCheck.run(command: command, workspaceOverride: folder.path) }
    try workspace.set("mcpEnabled", to: true)
    let check = try AgentConnectionCheck.run(command: command, workspaceOverride: folder.path)
    #expect(check.toolCount == AgentMCP.tools.count)
    #expect(check.projectCount == workspace.projects.count)
    try workspace.reload()
    #expect(workspace.records.map(\.id) == records)
    #expect(workspace.settings["autoPost"] as? Bool != true)
    #expect(workspace.settings["mcpAllowPosting"] as? Bool != true)
}

@Test @MainActor func workspaceQuickEditKeepsAttachmentsAndScheduleReview() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var post = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    post["title"] = "Test title"
    post["content"] = "Original post"
    post["format"] = "image"
    post.fields["image"] = ["file": "fixture.png"]
    post = try workspace.save(post)
    #expect(PostBrowserFilter.draft.matches(post, platform: "x", search: "  original "))
    let scheduled = try workspace.scheduleDraft(post, at: .now.addingTimeInterval(3_600))
    #expect(!PostBrowserFilter.draft.matches(scheduled, platform: nil, search: ""))
    #expect(!PostBrowserFilter.scheduling.matches(scheduled, platform: "x", search: ""))
    try workspace.addComment(to: scheduled, text: "Keep this review comment.")
    try workspace.updatePostText(scheduled, title: "Updated title", text: "Edited post")
    let edited = try #require(workspace.drafts.first { $0.id == post.id })
    #expect(edited.title == "Updated title")
    #expect(edited.body == "Edited post")
    #expect(edited.comments.first?["text"] as? String == "Keep this review comment.")
    #expect((edited.fields["image"] as? [String: String])?["file"] == "fixture.png")
    #expect(PostBrowserFilter.draft.matches(edited, platform: "x", search: "edited"))
    #expect(PostBrowserFilter.scheduling.matches(edited, platform: "x", search: "edited"))
    #expect(!PostBrowserFilter.scheduling.matches(edited, platform: "linkedin", search: ""))
    #expect(throws: WorkspaceError.self) { try workspace.updatePostText(scheduled, title: "Stale title", text: "Stale post") }
    let otherWindow = Workspace(directory: folder)
    try otherWindow.updatePostText(edited, title: edited.title, text: "Edited in another window")
    try workspace.addComment(to: edited, text: "Comment from an older preview.")
    let latest = try #require(workspace.drafts.first { $0.id == post.id })
    #expect(latest.body == "Edited in another window")
    #expect(latest.comments.count == 2)

    var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
    idea["topic"] = "Legacy idea"
    idea["text"] = "An old angle"
    idea.fields["suggestedPlatforms"] = nil
    idea = try workspace.save(idea)
    #expect(PostBrowserFilter.ideas.matches(idea, platform: "x", search: "legacy"))
    #expect(!PostBrowserFilter.ideas.matches(idea, platform: "linkedin", search: ""))
    try workspace.updatePostText(idea, title: idea.title, text: "A better angle")
    let updatedIdea = try #require(workspace.ideas.first { $0.id == idea.id })
    #expect(updatedIdea.body == "A better angle")
    #expect(updatedIdea["previousText"] == "An old angle")
}

@Test @MainActor func workspaceBrowsesAllDraftFormatsByProjectAndChannel() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var other = WorkspaceRecord.new("project")
    other["name"] = "Other project"
    try workspace.save(other)
    for format in WorkspaceDraftType.allCases {
        var record = format.makeRecord(projectID: workspace.projectID)
        record["title"] = "Shared title"
        record[record.isLongForm ? "body" : "content"] = "Find this paragraph"
        let saved = try workspace.save(record)
        #expect(workspace.workspaceDrafts.contains { $0.id == saved.id })
        let channel = format == .newsletter ? "substack" : record["platform"]
        #expect(WorkspaceDraftType(record: saved) == format)
        #expect(PostBrowserFilter.all.matches(saved, platform: channel, search: "paragraph"))
        #expect(!PostBrowserFilter.all.matches(saved, platform: "instagram", search: ""))
        #expect(PostBrowserFilter.draft.matches(saved, platform: nil, search: format.name))
        #expect(PostBrowserFilter.scheduling.matches(saved, platform: nil, search: "") == (format == .newsletter))
    }
    workspace.selectProject(other.id)
    #expect(workspace.workspaceDrafts.isEmpty)
}

@Test @MainActor func scheduleRevisionKeepsTheDraftAndRequiresANewPostingTime() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var project = WorkspaceRecord.new("project")
    project["name"] = "Another project"
    try workspace.save(project)
    #expect(workspace.projectID != project.id)
    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    draft["title"] = "Scheduled draft"
    draft["content"] = "Original wording."
    draft["format"] = "image"
    draft["imagePrompt"] = "Earlier direction"
    draft.fields["image"] = ["file": "fixture.png", "prompt": "Earlier direction"]
    draft = try workspace.save(draft)
    let queued = try workspace.scheduleDraft(draft, at: .now.addingTimeInterval(3_600))

    let notes = "Start with the result."
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] },
        object: { _, input in
            #expect(input["notes"] as? String == notes)
            return ["text": "Revised wording.", "reply": "Moved the result up.", "imagePrompt": "Updated direction"]
        }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let studio = ContentStudio(workspace: workspace, model: model)
    let revised = try await studio.rewrite(queued, notes: notes)
    #expect(revised.id == queued.id)
    #expect(revised.body == "Revised wording.")
    #expect(revised["notesReply"] == "Moved the result up.")
    #expect(revised["imagePrompt"] == "Updated direction")
    #expect(revised.fields["image"] as? [String: String] == queued.fields["image"] as? [String: String])
    #expect(!revised["mediaError"].isEmpty)
    #expect(ScheduleListing.section(for: revised) == .ready)
    #expect(revised.schedule["slotAt"] as? String == "")
    let restored = try studio.undoRewrite(revised)
    #expect(restored.body == queued.body)
    #expect(restored["previousContent"] == revised.body)
    #expect(restored.scheduleStatus == "ready")

    let database = try WorkspaceDatabase(url: folder.appending(path: "workspace.sqlite"))
    let deletingModel = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] },
        object: { _, _ in
            try database.remove(restored.id, kind: "draft")
            return ["text": "Late rewrite."]
        }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let deletingStudio = ContentStudio(workspace: workspace, model: deletingModel)
    await #expect(throws: WorkspaceError.self) { _ = try await deletingStudio.rewrite(restored, notes: notes) }
    #expect(throws: WorkspaceError.self) { _ = try studio.undoRewrite(restored) }
    #expect(!workspace.records.contains { $0.id == restored.id })
}

@Test @MainActor func learningWritingStyleUsesSelectedPublishedExamplesAndRequiresSave() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let active = ["voice": "Existing voice", "imageStyle": "Soft pencil"]
    try workspace.set("personalProfile", to: active)
    var published = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    published["title"] = "A published example"
    published["content"] = "This was shared publicly."
    try workspace.save(published)
    var receipt = WorkspaceRecord.new("publication", projectID: workspace.projectID)
    receipt["title"] = published.title
    receipt["draftId"] = published.id
    receipt["status"] = "published"
    try workspace.save(receipt)
    var sample = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    sample["title"] = "Template example"
    sample["content"] = "Do not include sample templates."
    sample.fields["sample"] = true
    sample.fields["schedule"] = ["status": "posted"]
    try workspace.save(sample)
    let candidates = PersonalProfile.publishedDrafts(in: workspace.records)
    #expect(candidates.map(\.id) == [published.id])
    let samples = try PersonalProfile.samples(appending: candidates, to: "A pasted example.")
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, input in
        #expect(input.keys.sorted() == ["samples"])
        #expect(input["samples"] as? String == "A pasted example.\n\nThis was shared publicly.")
        return ["voice": "Short sentences", "interests": "Engineering", "avoid": "Jargon"]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let suggestion = try await ContentStudio(workspace: workspace, model: model).learnWritingStyle(from: samples)
    #expect((workspace.settings["personalProfile"] as? [String: String]) == active)
    var reviewed: [String: Any] = active.merging(suggestion) { _, suggested in suggested }
    reviewed["samples"] = samples
    try workspace.savePersonalProfile(reviewed, replacing: active)
    let saved = try #require(workspace.settings["personalProfile"] as? [String: Any])
    #expect(saved["voice"] as? String == "Short sentences")
    #expect(saved["imageStyle"] as? String == "Soft pencil")
    #expect(throws: WorkspaceError.self) { try workspace.savePersonalProfile(reviewed, replacing: active) }
}

@Test @MainActor func savingReviewedProfileAppliesEditsAndResolvesTheSuggestion() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let active = workspace.settings["personalProfile"] as? [String: Any] ?? [:]
    let suggestion = try workspace.suggestProfile(["voice": "Proposed voice"])
    var reviewed = try #require(suggestion.fields["profile"] as? [String: Any])
    reviewed["voice"] = "Reviewed voice"
    try workspace.savePersonalProfile(reviewed, replacing: active, suggestionID: suggestion.id)
    #expect((workspace.settings["personalProfile"] as? [String: Any])?["voice"] as? String == "Reviewed voice")
    #expect(workspace.records.first { $0.id == suggestion.id }?["status"] == "accepted")
}

@Test @MainActor func agentWritesAndPicksDraftsInTheUIWorkspace() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in
        ["title": "Fixture draft", "content": "An original local post."]
    }, object: { instructions, _ in
        if instructions.contains("Generate up to") {
            return ["ideas": [
                ["slot": 2, "kind": "work", "topic": "Draft stewardship",
                 "text": "Open with the cost of replacing a useful draft.", "sourceId": "s1"]
            ]]
        }
        return ["text": "A finished draft about stewardship."]
    }, prompt: { _ in "An illustration" }, image: { _ in (Data([1, 2, 3]), "png") }, imageProvider: "Fixture")
    let agent = AgentMCP(workspace: workspace, model: model)
    let created = await tool(agent, "write_post", ["platform": "x", "idea": "Writing care"])
    let draft = try #require(created["draft"] as? [String: Any])
    #expect(draft["content"] as? String == "An original local post.")
    #expect(workspace.drafts.contains { $0.id == draft["id"] as? String })
    let refreshed = await tool(agent, "refresh_ideas", ["research": false])
    #expect(refreshed["written"] as? Int == 1)
    let idea = try #require(workspace.ideas.first)
    let selected = await tool(agent, "pick_idea", ["idea_id": idea.id, "platforms": ["x", "linkedin"]])
    let versions = try #require(selected["versions"] as? [[String: Any]])
    #expect(versions.count == 2)
    #expect(workspace.ideas.first?["status"] == "draft")
    #expect(workspace.ideas.first?.body == idea.body)
    #expect(workspace.ideas.first?.draftVersions.count == 2)
    #expect(workspace.ideas.first?.isPendingPostIdea == false)
    #expect(!workspace.trashedRecords.contains { $0.id == idea.id })
    let duplicate = await tool(agent, "pick_idea", ["idea_id": idea.id, "platforms": ["x"]])
    #expect(duplicate["isError"] as? Bool == true)
    #expect(workspace.drafts.filter { $0.scheduleStatus == "ready" }.count == 2)
    #expect(workspace.drafts.filter { $0["ideaId"] == idea.id }.allSatisfy { $0.fields["image"] == nil })
    let reopened = Workspace(directory: folder)
    #expect(reopened.drafts.count == workspace.drafts.count)
    #expect(reopened.ideas.first?["status"] == "draft")

    let posted = await tool(agent, "post_now", ["draft_id": draft["id"] ?? ""])
    #expect(posted["isError"] as? Bool == true)
    #expect(workspace.records.filter { $0.kind == "publication" }.isEmpty)
}

@Test @MainActor func writingStudioKeepsItsSavedTextAndPreviousImageWhenImageGenerationFails() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var reference = WorkspaceRecord.new("source", projectID: workspace.projectID)
    reference["title"] = "A selected reference"
    reference["text"] = "Fixture evidence for the writing request."
    try workspace.save(reference)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Earlier draft"
    draft["content"] = "Earlier wording"
    draft["brief"] = "Use the selected evidence."
    draft["format"] = "image"
    draft.fields["sourceIds"] = [reference.id, "missing"]
    let previous = try workspace.writeGeneratedImage(Data("previous fixture image".utf8), fileExtension: "png")
    draft.fields["image"] = ["file": previous]
    draft = try workspace.save(draft)
    let draftID = draft.id

    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { input, format in
        #expect(format == "image")
        #expect((input["evidence"] as? [[String: String]])?.map { $0["title"] } == ["A selected reference"])
        return ["title": "Revised draft", "content": "New wording.", "imagePrompt": "A line drawing"]
    }, object: { _, _ in [:] }, prompt: { _ in "" }, image: { prompt in
        #expect(prompt == "A line drawing")
        let disk = try WorkspaceDatabase(url: folder.appending(path: "workspace.sqlite"))
        #expect(try disk.records().first { $0.id == draftID }?.body == "New wording.")
        throw WorkspaceError("The image provider is unavailable.")
    }, imageProvider: "Fixture")
    let (saved, imageError) = try await ContentStudio(workspace: workspace, model: model).compose(draft, withImage: true) { textDraft in
        #expect(textDraft.id == draftID)
        #expect(textDraft.body == "New wording.")
    }
    #expect(imageError == "The image provider is unavailable.")
    #expect(saved.id == draftID)
    #expect(saved["imagePrompt"] == "A line drawing")
    #expect(saved.fields["sourceIds"] as? [String] == [reference.id])
    #expect(workspace.mediaURL(saved)?.lastPathComponent == previous)
    #expect(workspace.drafts.first { $0.id == draftID }?.body == "New wording.")
}

@Test(arguments: [false, true])
@MainActor func generatedImageDoesNotOverwriteAnEditOrSendClaim(mimicSendClaim: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "An image draft"
    draft["brief"] = "Describe this image."
    draft["format"] = "image"
    let draftID = draft.id
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in
        ["title": "An image draft", "content": "New text", "imagePrompt": "A diagram"]
    }, object: { _, _ in [:] }, prompt: { _ in "" }, image: { _ in
        let concurrent = Workspace(directory: folder)
        var latest = try #require(concurrent.drafts.first { $0.id == draftID })
        if mimicSendClaim {
            latest.fields["schedule"] = ["status": "posting"]
            let disk = try WorkspaceDatabase(url: folder.appending(path: "workspace.sqlite"))
            try disk.put(latest)
        } else {
            latest["content"] = "Concurrent edit"
            try concurrent.save(latest)
        }
        return (Data("new fixture image".utf8), "png")
    }, imageProvider: "Fixture")
    let (_, imageError) = try await ContentStudio(workspace: workspace, model: model).compose(draft, withImage: true)
    #expect(imageError?.contains("draft changed") == true)
    let latest = try #require(workspace.drafts.first { $0.id == draftID })
    #expect(latest.body == (mimicSendClaim ? "New text" : "Concurrent edit"))
    #expect(latest.scheduleStatus == (mimicSendClaim ? "posting" : ""))
    #expect(latest.fields["image"] == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "images").path))
}

@Test @MainActor func vaultRejectsLinksAndRequiresReviewBeforeSavingSuggestions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root.appending(path: "workspace"))
    let folder = root.appending(path: "vault")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let note = folder.appending(path: "Project.md")
    try Data("---\nprivate: fixture\n---\nProject notes.\n".utf8).write(to: note)
    try FileManager.default.createSymbolicLink(at: folder.appending(path: "Linked.md"), withDestinationURL: note)
    let vault = try ObsidianVault(folder.path)
    let listing = try vault.list(query: "")
    #expect(listing.notes.compactMap { $0["id"] as? String } == ["Project.md"])
    #expect(throws: WorkspaceError.self) { try vault.preview(["Linked.md"]) }
    #expect(throws: WorkspaceError.self) { try vault.preview(["../Project.md"]) }
    let selected = try vault.preview(["Project.md"]).notes
    #expect(selected.first?["text"] == "Project notes.")
    try workspace.set("obsidianVault", to: ["path": folder.path, "allowAgents": false])
    try workspace.set("mcpEnabled", to: true)
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, context in
        let notes = try #require(context["notes"] as? [[String: String]])
        #expect(notes.first?["text"] == "Project notes.")
        return ["ideas": [["title": "Public angle", "summary": "A reviewable suggestion.", "noteIds": ["Project.md"]]]]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let agent = AgentMCP(workspace: workspace, model: model)
    let denied = await tool(agent, "preview_vault_notes", ["note_ids": ["Project.md"]])
    #expect(denied["isError"] as? Bool == true)
    try workspace.set("obsidianVault", to: ["path": folder.path, "allowAgents": true])
    let generated = await tool(agent, "suggest_vault_ideas", ["notes": selected])
    #expect(generated["count"] as? Int == 1)
    let suggestion = try #require(workspace.records.first { $0.kind == "personal-inbox" })
    #expect(suggestion["status"] == "pending")
    #expect(!workspace.sources.contains { $0.title == "Public angle" })
    try workspace.reviewSuggestion(suggestion.id, accept: true)
    #expect(workspace.sources.contains { $0.title == "Public angle" })
    try Data("Changed".utf8).write(to: note)
    let changed = await tool(agent, "suggest_vault_ideas", ["notes": selected])
    #expect(changed["isError"] as? Bool == true)
}

@Test @MainActor func discoverySavesEvidenceAndKeepsDismissalsAcrossRefreshes() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let now = Date.now
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { instructions, _ in
        if instructions.contains("Choose three") {
            return ["focus": "Writing tools", "topics": [["topic": "Drafts", "query": "writing drafts"]]]
        }
        return ["items": [["id": "0", "headline": "Draft care", "relevance": 95, "angle": "Make drafts easy to reopen."]]]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let discovery = ResearchDiscovery(studio: ContentStudio(workspace: workspace, model: model)) { _, _, topic in
        [["url": "https://news.google.com/rss/articles/fixture", "title": "Public headline", "text": "A public headline with enough context",
          "postedAt": workspaceTimestamp(now), "topic": topic, "author": "Fixture publisher"]]
    }
    let feed = try await discovery.discover(.news, projectID: workspace.projectID, now: now)
    let item = try #require((feed.fields["items"] as? [[String: Any]])?.first)
    let source = try #require(item["source"] as? [String: Any])
    let first = try workspace.saveResearchReference(source, projectID: workspace.projectID)
    let second = try workspace.saveResearchReference(source, projectID: workspace.projectID)
    #expect(first.id == second.id)
    try workspace.dismissResearch(try #require(item["id"] as? String), from: feed.id)
    let refreshed = try await discovery.discover(.news, projectID: workspace.projectID, now: now)
    #expect((refreshed.fields["items"] as? [[String: Any]])?.isEmpty == true)
    #expect(workspace.sources.contains { $0.id == first.id })
}

@Test @MainActor func researchRanksFreshEvidenceAndLimitsRepeatAuthors() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let now = Date.now
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { instructions, context in
        if instructions.contains("Choose three") {
            return ["topics": [["topic": "Draft care", "query": "draft care"]]]
        }
        let candidates = try #require(context["candidates"] as? [[String: Any]])
        #expect(candidates.count == 4)
        #expect((candidates.first?["text"] as? String)?.hasPrefix("Fresh") == true)
        return ["items": candidates.map {
            ["id": $0["id"] as? String ?? "", "relevance": 85, "headline": "Draft care", "angle": "Keep the source handy."]
        }]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let discovery = ResearchDiscovery(studio: ContentStudio(workspace: workspace, model: model)) { _, _, topic in
        func post(_ id: Int, text: String, age: TimeInterval, author: String, likes: String = "200") -> [String: Any] {
            ["url": "https://x.com/i/web/status/\(id)", "title": text, "text": text, "postedAt": workspaceTimestamp(now.addingTimeInterval(-age)),
             "author": author, "topic": topic, "likes": likes]
        }
        return [
            post(1, text: "Older results with enough detail to compare engagement.", age: 5 * 86_400, author: "example"),
            post(2, text: "Fresh results with enough detail to compare engagement. https://example.test/first", age: 60, author: "example"),
            post(3, text: "Fresh results with enough detail to compare engagement. https://example.test/copy", age: 120, author: "other"),
            post(4, text: "Another useful account of the same writing project.", age: 3600, author: "@EXAMPLE"),
            post(5, text: "A distinct author's example of careful writing and editing.", age: 7200, author: "different"),
            post(6, text: "A third author with only a small amount of engagement.", age: 120, author: "third", likes: "2"),
            post(7, text: "A previously useful example from outside the research window.", age: 8 * 86_400, author: "fourth")
        ]
    }
    let feed = try await discovery.discover(.x, projectID: workspace.projectID, now: now)
    let items = try #require(feed.fields["items"] as? [[String: Any]])
    #expect(items.compactMap { $0["id"] as? String } == [2, 4, 5].map { "https://x.com/i/web/status/\($0)" })
}

@Test @MainActor func instagramResearchRotatesFollowedHashtagsAcrossRefreshes() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("personalProfile", to: ["hashtags": ["drafts", "writing", "editing", "publishing"]])
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        ["topics": [["topic": "Draft care", "query": "draft care", "hashtag": "draftcare"]]]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    var searched: [String] = []
    let discovery = ResearchDiscovery(studio: ContentStudio(workspace: workspace, model: model)) { _, query, _ in
        searched.append(query)
        return []
    }
    let now = Date.now
    _ = try await discovery.discover(.instagram, projectID: workspace.projectID, now: now)
    #expect(searched == ["drafts", "writing", "editing"])
    searched.removeAll()
    _ = try await discovery.discover(.instagram, projectID: workspace.projectID, now: now.addingTimeInterval(60))
    #expect(searched == ["publishing", "drafts", "writing"])
}

@Test @MainActor func researchOpensDraftsWithTheDestinationAndOriginalEvidence() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let evidence: [String: Any] = [
        "title": "A public example", "text": "Original evidence.", "author": "fixture",
        "url": "https://twitter.com/fixture/status/123456?source=fixture", "likes": 10, "reposts": 3
    ]
    let source = try workspace.saveResearchReference(evidence, projectID: workspace.projectID)
    let instagram = try workspace.save(ResearchDraft.post(from: source, platform: "instagram", hook: "Open here.", angle: "Explore the result."))
    #expect(instagram["platform"] == "instagram")
    #expect(instagram["format"] == "image")
    #expect(instagram["brief"] == "Original hook: Open here.\nExplore the result.")
    #expect(instagram.fields["sourceIds"] as? [String] == [source.id])
    #expect(source.fields["reposts"] as? Int == 3)
    let reply = try workspace.save(ResearchDraft.reply(to: evidence, projectID: workspace.projectID))
    #expect(reply["platform"] == "x")
    #expect(reply["format"] == "reply")
    #expect(reply.fields["replyTo"] as? [String: String] == [
        "text": "Original evidence.", "author": "fixture", "url": "https://x.com/i/web/status/123456"
    ])
    #expect(throws: WorkspaceError.self) {
        _ = try ResearchDraft.reply(to: ["text": "A copied link.", "url": "https://example.test/status/123456"], projectID: workspace.projectID)
    }
}

@Test @MainActor func ideaRefillReplacesTheMissingKindAndRejectsUnsupportedNumbers() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("ideaQueueTarget", to: 10)
    for (index, kind) in (Array(repeating: "trend", count: 4) + Array(repeating: "work", count: 4) + ["data"]).enumerated() {
        var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
        idea["topic"] = "Existing topic \(index)"
        idea["text"] = "Existing concept \(index)"
        idea["kind"] = kind
        try workspace.save(idea)
    }
    var source = WorkspaceRecord.new("source", projectID: workspace.projectID)
    source["title"] = "Project measurement"
    source["text"] = "The measured export took 12 seconds."
    try workspace.save(source)
    func studio(number: String) -> ContentStudio {
        let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, context in
            let slots = try #require(context["slots"] as? [[String: Any]])
            #expect(slots.count == 1)
            #expect(slots.first?["kind"] as? String == "data")
            #expect(slots.first?["long"] as? Bool == false)
            let materials = try #require(context["materials"] as? [[String: Any]])
            let material = try #require(materials.first { $0["title"] as? String == "Project measurement" })
            let id = try #require(material["id"] as? String)
            return ["ideas": [["slot": 1, "kind": "data", "topic": "Measured export speed",
                               "text": "Explain why a \(number)-second export matters for this workflow.", "sourceId": id]]]
        }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
        return ContentStudio(workspace: workspace, model: model)
    }
    let rejected = try await studio(number: "95").refresh(projectID: workspace.projectID)
    #expect(rejected.written == 0)
    #expect(!rejected.warnings.isEmpty)
    let accepted = try await studio(number: "12").refresh(projectID: workspace.projectID)
    #expect(accepted.written == 1)
    #expect(accepted.full)
    let saved = try #require(workspace.ideas.first { $0.title == "Measured export speed" })
    #expect((saved.fields["source"] as? [String: String])?["referenceId"] == source.id)
}

@Test @MainActor func automaticIdeaChecksStopAtTheTargetWithoutLimitingManualIdeas() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    #expect(IdeaQueuePlan.target(nil) == 20)
    #expect(IdeaQueuePlan.target(51) == 20)
    try workspace.set("ideaQueueTarget", to: 50)
    try workspace.set("ideaQueueAutomatic", to: true)
    for index in 1...51 {
        var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
        idea["topic"] = "Manual idea \(index)"
        idea["text"] = "A distinct topic, number \(index)."
        try workspace.save(idea)
    }
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        throw WorkspaceError("A full queue should not call the model.")
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let result = try await ResearchDiscovery(studio: ContentStudio(workspace: workspace, model: model))
        .refreshIdeas(projectID: workspace.projectID, withResearch: true, automatic: true)
    #expect(result.full)
    #expect(result.written == 0)
    #expect(result.warnings.isEmpty)
    #expect(result.open.count == 51)
}

@Test @MainActor func agentCanWriteDraftTextWithoutAProviderAndRejectsAStaleRevision() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["brief"] = "Draft a post about quiet writing tools."
    draft["title"] = "Draft for AI agent"
    draft = try workspace.save(draft)
    let agent = AgentMCP(workspace: workspace)
    let read = await tool(agent, "get_draft", ["draft_id": draft.id])
    #expect(read["brief"] as? String == draft["brief"])
    let written = await tool(agent, "edit_draft", [
        "draft_id": draft.id, "expected_updated_at": draft["updatedAt"], "content": "A draft for review."
    ])
    #expect(written["content"] as? String == "A draft for review.")
    let stale = await tool(agent, "edit_draft", [
        "draft_id": draft.id, "expected_updated_at": draft["updatedAt"], "content": "An outdated overwrite."
    ])
    #expect(stale["isError"] as? Bool == true)
    let current = try #require(workspace.drafts.first { $0.id == draft.id })
    #expect(current.body == "A draft for review.")
    #expect(current.scheduleStatus.isEmpty)
}

@Test @MainActor func disablingAutomaticIdeaRefillDuringGenerationDiscardsItsOutput() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("ideaQueueAutomatic", to: true)
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, _ in
        try workspace.set("ideaQueueAutomatic", to: false)
        return ["ideas": [["slot": 2, "kind": "work", "topic": "Late suggestion",
                           "text": "A model result returned after refill was disabled.", "sourceId": "s1"]]]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let result = try await ContentStudio(workspace: workspace, model: model)
        .refresh(projectID: workspace.projectID, automatic: true)
    #expect(result.written == 0)
    #expect(workspace.ideas.isEmpty)
}

@MainActor
private func tool(_ agent: AgentMCP, _ name: String, _ arguments: [String: Any]) async -> [String: Any] {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    let response = await agent.handle(request)?["result"] as? [String: Any] ?? [:]
    return response["structuredContent"] as? [String: Any] ?? response
}

@Test @MainActor func writingDefaultsToAgentAndAPIWritingRequiresAnExplicitSelection() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("provider", to: "anthropic")
    try workspace.set("imageProvider", to: "gemini")
    let studio = ContentStudio(workspace: workspace)
    #expect(studio.model.provider == "agent")
    #expect(studio.model.imageProvider == ProviderKey.gemini.name)
    await #expect(throws: WorkspaceError.self) {
        try await studio.model.object("Return an empty JSON object.", [:])
    }

    try workspace.set("mcpEnabled", to: true)
    try workspace.set(StudioWritingConnection.preferenceKey, to: StudioWritingConnection.api.rawValue)
    #expect(ContentStudio(workspace: workspace).model.provider == "anthropic")
}

@Test @MainActor func mcpCredentialSetupRequiresPermissionAndUsesOnlyTheLocalEnvironment() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let agent = AgentMCP(workspace: workspace, credentialEnvironment: [:])
    let provider = ["provider": "x"]

    let denied = await tool(agent, "set_provider_key", provider)
    #expect(denied["isError"] as? Bool == true)
    #expect(String(describing: denied["content"]).contains("Enable credential setup"))

    try workspace.set(AgentMCP.credentialPermission, to: true)
    let missing = await tool(agent, "set_provider_key", ["provider": "x", "value": "fixture-value"])
    #expect(missing["isError"] as? Bool == true)
    #expect(String(describing: missing["content"]).contains("INKSPRING_X_BEARER_TOKEN"))
    #expect(!String(describing: missing).contains("fixture-value"))

    let r2 = await tool(agent, "set_r2_credentials", ["account_id": String(repeating: "a", count: 32), "bucket": "example"])
    #expect(r2["isError"] as? Bool == true)
    #expect(String(describing: r2["content"]).contains("INKSPRING_R2_ACCESS_KEY_ID"))

    let chat = AgentMCP(workspace: workspace, chatProjectID: workspace.projectID, credentialEnvironment: [:])
    let blocked = await tool(chat, "set_provider_key", provider)
    #expect(blocked["isError"] as? Bool == true)
    #expect(String(describing: blocked["content"]).contains("Unknown tool"))
}

@Test @MainActor func inAppChatToolsAreReadOnlyAndLimitedToTheOpenProject() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    let projectID = workspace.projectID
    var other = WorkspaceRecord.new("project")
    other["name"] = "Other project"
    other = try workspace.save(other)
    var first = WorkspaceRecord.new("draft", projectID: projectID)
    first["title"] = "Open project draft"
    first = try workspace.save(first)
    var second = WorkspaceRecord.new("draft", projectID: other.id)
    second["title"] = "Other project draft"
    second = try workspace.save(second)
    let agent = AgentMCP(workspace: workspace, chatProjectID: projectID)
    let listed = await tool(agent, "list_drafts", ["project_id": other.id])
    let ids = (listed["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    #expect(ids.contains(first.id))
    #expect(!ids.contains(second.id))
    let otherRead = await tool(agent, "get_draft", ["draft_id": second.id])
    #expect(otherRead["isError"] as? Bool == true)
    let edit = await tool(agent, "edit_draft", ["draft_id": first.id, "content": "Should be blocked."])
    #expect(edit["isError"] as? Bool == true)
}

@Test @MainActor func contentIDsAreSharedByPostsAndNewslettersAndResolveInMCP() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    var project = WorkspaceRecord.new("project")
    project["name"] = "Protomota"
    project = try workspace.save(project)
    var other = WorkspaceRecord.new("project")
    other["name"] = "Production"
    other = try workspace.save(other)
    #expect(project["projectKey"] == "PRO")
    #expect(other["projectKey"] != project["projectKey"])

    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    draft["title"] = "First post"
    draft["content"] = "Post content"
    draft = try workspace.save(draft)
    var newsletter = WorkspaceRecord.new("newsletter", projectID: project.id)
    newsletter["title"] = "First newsletter"
    newsletter["body"] = "Newsletter content"
    newsletter = try workspace.save(newsletter)
    #expect(draft.referenceID == "PRO-001")
    #expect(newsletter.referenceID == "PRO-002")

    project["name"] = "Studio"
    _ = try workspace.save(project)
    let external = AgentMCP(workspace: workspace)
    let readPost = await tool(external, "get_content", ["id": " pro-001 "])
    #expect(readPost["kind"] as? String == "post")
    #expect((readPost["item"] as? [String: Any])?["id"] as? String == draft.id)
    let readNewsletter = await tool(external, "get_newsletter", ["newsletter_id": "PRO-002"])
    #expect(readNewsletter["id"] as? String == newsletter.id)
    #expect(readNewsletter["body"] as? String == "Newsletter content")
    let chat = AgentMCP(workspace: workspace, chatProjectID: other.id)
    let scoped = await tool(chat, "get_content", ["id": "PRO-001"])
    #expect(scoped["isError"] as? Bool == true)

    let snapshot = workspace.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.items.first { $0.id == draft.id }?.referenceID == draft.referenceID)
    #expect(snapshot.newsletters?.first { $0.id == newsletter.id }?.referenceID == newsletter.referenceID)

    let secondConnection = try WorkspaceDatabase(url: folder.appending(path: "workspace.sqlite"))
    try secondConnection.remove(draft.id, kind: draft.kind)
    var replacement = WorkspaceRecord.new("draft", projectID: project.id)
    replacement["title"] = "Another post"
    replacement = try workspace.save(replacement)
    #expect(replacement.referenceID == "PRO-003")
    let removed = await tool(external, "get_content", ["id": "PRO-001"])
    #expect(removed["isError"] as? Bool == true)
}

@Test @MainActor func repliesPageWithoutDroppingCursorAndReuseDraft() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let account = ManagedSocialAccount(
        session: ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
                                      expiresAt: 2_000_000_000_000, scopes: "tweet.read"),
        id: "100", name: "Fixture", username: "fixture", connectedAt: "fixture"
    )
    let transport = SocialTransport { request in
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let older = query.contains { $0.name == "pagination_token" && $0.value == "old" }
        if older { #expect(!query.contains { $0.name == "since_id" }) }
        let rows = [["id": older ? "101" : "103", "author_id": "200", "text": "Reply to the fixture."]]
        let meta: [String: Any] = older ? ["result_count": 1] : ["result_count": 1, "newest_id": "103", "next_token": "old"]
        let fields: [String: Any] = ["data": rows, "meta": meta]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
    let inbox = ReplyInbox(workspace: workspace, transport: transport, accountOverride: account)
    #expect(try await inbox.refresh() == 1)
    #expect(inbox.hasOlder)
    let reply = try #require(inbox.rows.first)
    let draft = try workspace.makeReplyDraft(reply.id, projectID: workspace.projectID)
    #expect(try workspace.makeReplyDraft(reply.id, projectID: workspace.projectID).id == draft.id)
    #expect(try await inbox.refresh(older: true) == 1)
    #expect(!inbox.hasOlder)
    #expect(inbox.rows.count == 2)
    #expect(inbox.rows.first { $0.id == reply.id }?["status"] == "drafted")
    try inbox.setMonitoring(true)
    #expect(inbox.monitoring)
    var newAccount = account
    newAccount.connectedAt = "different session"
    #expect(!ReplyInbox(workspace: workspace, accountOverride: newAccount).monitoring)
}

@Test @MainActor func analyticsKeepsDailyBaselineAndUpdatesCurrentMetrics() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let account = ManagedSocialAccount(
        session: ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
                                      expiresAt: 2_000_000_000_000, scopes: "users.read tweet.read"),
        id: "100", name: "Fixture", username: "fixture"
    )
    var count = 0
    let transport = SocialTransport { request in
        let url = try #require(request.url)
        let fields: [String: Any]
        if url.path.hasSuffix("/tweets") {
            let post: [String: Any] = ["id": "20", "text": "Sample post", "created_at": "2027-01-01T09:00:00Z",
                                       "public_metrics": ["like_count": 5]]
            fields = ["data": [post], "meta": ["next_token": "older"]]
        } else {
            count += 1
            let profile: [String: Any] = ["id": "100", "public_metrics": ["followers_count": 50 + count]]
            fields = ["data": profile]
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: fields), response)
    }
    let analytics = AccountAnalytics(workspace: workspace, transport: transport, accountOverride: account)
    let now = try #require(scheduleDate("2027-01-01T10:00:00Z"))
    #expect(try await analytics.refresh(.x, now: now).isEmpty)
    #expect(try await analytics.refresh(.x, now: now.addingTimeInterval(120)).isEmpty)
    let rows = workspace.records.filter { $0.kind == "analytics-day" }
    #expect(rows.count == 1)
    #expect((rows.first?.fields["first"] as? [String: Any])?["followers"] as? Int == 51)
    #expect((rows.first?.fields["last"] as? [String: Any])?["followers"] as? Int == 52)
    #expect(workspace.records.filter { $0.kind == "analytics-post" }.count == 1)
    #expect(analytics.state(.x, account: account)?["cursor"] == "older")
}

@Test @MainActor func restoringEarlierWordingReturnsQueuedPostToReview() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Local draft"
    draft["content"] = "Revised wording"
    draft["previousContent"] = "Earlier wording"
    draft.fields["schedule"] = ["status": "queued", "slotAt": "2027-01-01T12:00:00Z"]
    draft = try workspace.save(draft)
    let studio = ContentStudio(workspace: workspace)
    let restored = try studio.undoRewrite(draft)
    #expect(restored.body == "Earlier wording")
    #expect(restored["previousContent"] == "Revised wording")
    #expect(restored.scheduleStatus == "ready")
    #expect(restored.schedule["slotAt"] as? String == "")
    #expect(throws: WorkspaceError.self) { _ = try studio.undoRewrite(draft) }
    let reverted = try studio.undoRewrite(restored)
    #expect(reverted.body == "Revised wording")
}

@Test @MainActor func reopeningAnIdeaKeepsDraftsAndPublishingHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var idea = WorkspaceRecord.new("idea", projectID: workspace.projectID)
    idea["topic"] = "Project update"
    idea["text"] = "An update on the project."
    idea["status"] = "picked"
    var discarded = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    discarded["title"] = "Unpublished draft"
    discarded["ideaId"] = idea.id
    discarded = try workspace.save(discarded)
    var kept = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    kept["title"] = "Previously attempted draft"
    kept["platform"] = "linkedin"
    kept["ideaId"] = idea.id
    kept.fields["schedule"] = ["status": "failed"]
    kept = try workspace.save(kept)
    var receipt = WorkspaceRecord.new("publication", projectID: workspace.projectID)
    receipt["title"] = kept.title
    receipt["draftId"] = kept.id
    receipt["status"] = "uncertain"
    try workspace.save(receipt)
    idea.fields["versions"] = ["x": discarded.id, "linkedin": kept.id]
    idea = try workspace.save(idea)

    let preview = try workspace.reviewIdeaReturn(for: discarded)
    idea["text"] = "Changed after review."
    idea = try workspace.save(idea)
    #expect(throws: WorkspaceError.self) { try workspace.returnToIdeas(preview) }
    #expect(workspace.ideas.first?["status"] == "picked")
    #expect(workspace.drafts.filter { $0["ideaId"] == idea.id }.count == 2)
    try workspace.returnToIdeas(workspace.reviewIdeaReturn(for: discarded))
    let reopened = try #require(workspace.ideas.first { $0.id == idea.id })
    #expect(reopened["status"] == "draft")
    #expect(Set(workspace.drafts.filter { $0["ideaId"] == idea.id }.map(\.id)) == [kept.id, discarded.id])
    #expect(workspace.records.contains { $0.id == receipt.id })

    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] },
        object: { _, _ in ["text": "The new platform version."] },
        prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let studio = ContentStudio(workspace: workspace, model: model)
    await #expect(throws: WorkspaceError.self) { _ = try await studio.pick(reopened, platforms: ["linkedin"]) }
    let (picked, versions) = try await studio.pick(reopened, platforms: ["instagram"])
    let replacement = try #require(versions.first)
    #expect(picked["status"] == "draft")
    #expect(picked.draftVersions == ["linkedin": kept.id, "x": discarded.id, "instagram": replacement.id])
}

@Test @MainActor func anXQuoteUsesItsCitedResearchAndLeavesThePostingQueue() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let address = "https://twitter.com/example/status/123456?source=fixture"
    let body = "A + B & C #writing"
    var feed = WorkspaceRecord.new("discovery", projectID: workspace.projectID)
    feed["title"] = "Fixture research"
    feed["platform"] = "x"
    feed["searchedAt"] = WorkspaceRecord.timestamp
    feed.fields["items"] = [["id": address, "headline": "Example post",
                             "source": ["url": address, "author": "example", "text": "Cited evidence"]]]
    try workspace.save(feed)
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] },
        object: { instructions, context in
            if instructions.contains("Generate up to") {
                return ["ideas": [["slot": 1, "kind": "trend", "topic": "Quote angle", "text": "Explain the cited example.",
                                   "sourceId": "r1", "mediaPlan": "A diagram"]]]
            }
            let evidence = try #require(context["evidence"] as? [[String: Any]])
            #expect(evidence.first?["text"] as? String == "Cited evidence")
            return ["text": body]
        }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let studio = ContentStudio(workspace: workspace, model: model)
    _ = try await studio.refresh(projectID: workspace.projectID)
    let idea = try #require(workspace.ideas.first)
    #expect(XQuoteComposer.source(in: idea)?.absoluteString == "https://x.com/i/web/status/123456")
    #expect(XQuoteComposer.postURL("https://x.com.evil.test/example/status/123456") == nil)
    #expect(XQuoteComposer.postURL("https://name@x.com/example/status/123456") == nil)
    let (_, drafts) = try await studio.pick(idea, platforms: ["x"])
    let draft = try #require(drafts.first)
    #expect(draft["mediaPlan"] == "A diagram")
    let scheduled = try workspace.scheduleDraft(draft, at: .now.addingTimeInterval(3600))
    #expect(scheduled.scheduleStatus == "queued")
    let url = try workspace.prepareManualQuote(scheduled)
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "text" }?.value == body)
    #expect(query.first { $0.name == "url" }?.value == "https://x.com/i/web/status/123456")
    #expect(url.absoluteString.contains("%2B"))
    let manual = try #require(workspace.drafts.first { $0.id == scheduled.id })
    #expect(manual.scheduleStatus == "manual")
    #expect(manual.schedule["slotAt"] as? String == "")
    #expect(throws: WorkspaceError.self) { try workspace.scheduleDraft(manual, at: .now.addingTimeInterval(7200)) }
}
