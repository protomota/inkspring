import CryptoKit
import Foundation
@testable import InkspringSchedule
import Testing
@testable import Inkspring

@Test @MainActor func standaloneDraftCoversAndPublishedImagesSurviveCompanionSync() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    let source = folder.appending(path: "artwork.png")
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="))
    try png.write(to: source)
    let attached = try mac.attachImage(source)

    var draft = WorkspaceRecord.new("draft", projectID: mac.projectID)
    draft["title"] = "Ordinary draft"
    draft["platform"] = "linkedin"
    draft.fields["image"] = attached
    draft = try mac.save(draft)
    var newsletter = WorkspaceRecord.new("newsletter", projectID: mac.projectID)
    newsletter["title"] = "Newsletter with cover"
    newsletter.fields["coverImage"] = attached
    newsletter = try mac.save(newsletter)
    var published = draft
    published["id"] = UUID().uuidString.lowercased()
    published["title"] = "Published with an image"
    published.fields["schedule"] = ["status": "posted", "postedAt": "2026-11-23T10:00:00Z"]
    _ = try #require(mac.database).put(published)
    try mac.reload()

    var snapshot = mac.makeCompanionLibrary(workspaceID: UUID())
    let originalPreview = try #require(snapshot.imagePreview(for: draft.id))
    #expect(snapshot.imagePreview(for: newsletter.id) == originalPreview)
    #expect(snapshot.imagePreview(for: published.id) == originalPreview)
    #expect(!snapshot.items.contains { $0.id == published.id })
    let separated = try snapshot.separateFullText()
    let payload = try #require(separated)
    #expect(snapshot.additionalImagePreviews == nil)
    #expect(snapshot.items.allSatisfy { $0.imagePreview == nil })
    try snapshot.applyFullText(payload)
    #expect(snapshot.imagePreview(for: draft.id) == originalPreview)
    #expect(snapshot.imagePreview(for: newsletter.id) == originalPreview)
    #expect(snapshot.imagePreview(for: published.id) == originalPreview)
    #expect(snapshot.imagePreview(for: "nonexistent") == nil)
}

@Test @MainActor func macWritingDefaultsAndMobileOverridesRoundTripWithoutChangingSettings() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    try mac.set("writingConnection", to: "agent")
    let selected = StudioChatAgent.selected
    let preferredModel = try #require(selected.writingModels.last)
    try mac.set(selected.modelPreferenceKey, to: preferredModel.id)
    let workspaceID = UUID()
    var snapshot = mac.makeCompanionLibrary(workspaceID: workspaceID)
    #expect(snapshot.writingAgent == selected.rawValue)
    #expect(snapshot.writingProviders?.first { $0.id == selected.rawValue }?.defaultModel == preferredModel.id)

    let override = CompanionLibrary.WritingSelection(provider: "codex", model: "gpt-6.2-astra")
    var outgoing = CompanionLibrary.Change(action: .note, itemID: "idea", revision: "revision", xFormat: "post")
    outgoing.ideaDraftPlatforms = ["x"]
    outgoing.writingSelection = override
    let entry = CompanionLibraryOutbox.Entry(id: outgoing.id, action: .note, itemID: outgoing.itemID,
        revision: outgoing.revision, title: "", text: "", workspaceID: workspaceID, account: "fixture", xFormat: outgoing.xFormat,
        ideaDraftPlatforms: outgoing.ideaDraftPlatforms, writingSelection: override)
    var outbox = CompanionLibraryOutbox(entries: [entry])
    for advertisedConnection in [false, nil] as [Bool?] {
        snapshot.supportsAgentFeatures = advertisedConnection
        #expect(throws: CompanionLibraryError.self) { try snapshot.enqueue(outgoing) }
        #expect(outbox.prepare(for: snapshot, account: "fixture").isEmpty)
        #expect(outbox.entries == [entry])
    }
    snapshot.supportsAgentFeatures = true
    #expect(outbox.prepare(for: snapshot, account: "fixture") == [outgoing])
    try snapshot.enqueue(outgoing)
    let restored = try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(snapshot))
    #expect(restored.pending.first?.writingSelection == override)
    #expect(restored.writingAgent == selected.rawValue)
    #expect(mac.settings[selected.modelPreferenceKey] as? String == preferredModel.id)

    let old = CompanionLibrary(workspaceID: workspaceID)
    let oldDecoded = try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(old))
    #expect(oldDecoded.writingProviders == nil)
    outgoing.writingSelection = .init(provider: "codex", model: "--help")
    #expect(!outgoing.valid)
}

@Test @MainActor func mobileIdeaRequestCreatesTextAndLongFormDraftsOnce() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var idea = WorkspaceRecord.new("idea", projectID: mac.projectID)
    idea["topic"] = "Signal and noise"
    idea["text"] = "Write about deliberate publishing."
    idea = try mac.save(idea)
    var request = CompanionLibrary.Change(action: .note, itemID: idea.id, revision: idea["updatedAt"], xFormat: "thread")
    request.ideaDraftPlatforms = ["x", "linkedin", "reddit", "x-article", "linkedin-article", "substack", "youtube"]
    #expect(request.valid)
    let workspaceID = UUID()
    var oldMac = CompanionLibrary(workspaceID: workspaceID)
    oldMac.enabled = true
    #expect(throws: CompanionLibraryError.self) { try oldMac.enqueue(request) }
    var snapshot = CompanionLibrary(workspaceID: workspaceID)
    snapshot.enabled = true
    snapshot.supportsClaudeIdeaDrafts = true
    snapshot.supportsAgentFeatures = true
    try snapshot.enqueue(request)
    #expect(try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(snapshot)).pending == [request])
    #expect(await mac.draftMobileIdea(request).error != nil)
    try mac.set("mcpEnabled", to: true)
    try mac.set("writingConnection", to: "api")
    let model = ContentStudio.Model(provider: "agent", name: "Claude",
        draft: { _, _ in throw WorkspaceError("Unexpected alternate writing route.") },
        object: { _, _ in
            ["title": "Signal and noise", "subtitle": "Make something useful", "body": "## Signal\n\nBring value.", "text": "Bring value."]
        }, prompt: { _ in throw WorkspaceError("No image prompt expected.") },
        image: { _ in throw WorkspaceError("No image expected.") }, imageProvider: "unused")
    #expect(await mac.draftMobileIdea(request, model: model).error == nil)
    #expect(await mac.draftMobileIdea(request, model: model).error == nil)
    let generated = mac.records.filter { $0["ideaId"] == idea.id }
    #expect(generated.count == 7)
    #expect(generated.allSatisfy { $0["model"] == "Claude" && !$0.isPublishedContent })
    #expect(generated.filter { $0.kind == "draft" }.map { $0["platform"] }.sorted() == ["linkedin", "reddit", "x"])
    #expect(generated.first { $0["platform"] == "x" && $0.kind == "draft" }?["format"] == "post")
    #expect(generated.contains { $0.isLinkedInWritingArticle })
    #expect(generated.contains { $0.kind == "newsletter" && $0.fields["sendEmail"] as? Bool == false })
    let updated = try #require(mac.records.first { $0.id == idea.id })
    let writing = try #require(updated.fields["mobileWritingVersions"] as? [String: String])
    #expect(Set(updated.draftVersions.keys).union(writing.keys) == Set(request.ideaDraftPlatforms ?? []))
    let syncedIdea = try #require(mac.makeCompanionLibrary(workspaceID: workspaceID).items.first { $0.id == idea.id })
    #expect(syncedIdea.draftedIdeaIDs == updated.draftVersions.merging(writing) { current, _ in current })
    #expect(generated.contains { $0.kind == "newsletter" && $0.body == "## Signal\n\nBring value." })
}

@Test @MainActor func mobileMediaDraftImportsCaptionAndRequiresVideoForTikTok() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2bkAAAAASUVORK5CYII="))
    var request = CompanionLibrary.Change(action: .note, itemID: mac.projectID, title: "image.png", text: "A short caption.")
    request.mediaDraft = .init(platform: "tiktok", fileName: "image.png", data: image)
    #expect(!request.valid)
    request.mediaDraft = .init(platform: "instagram", fileName: "image.png", data: image)
    #expect(request.valid)
    #expect(await mac.createMobileMediaDraft(request, data: image).error == nil)
    #expect(await mac.createMobileMediaDraft(request, data: image).error == nil)
    let matched = mac.records.filter { $0.id == request.id.uuidString.lowercased() }
    let draft = try #require(matched.first)
    #expect(matched.count == 1)
    #expect(draft.body == "A short caption.")
    #expect(draft["platform"] == "instagram")
    #expect(mac.imageURL(draft) != nil)
    #expect(draft.schedule.isEmpty)
}

@Test @MainActor func mobileNewsletterEditPreservesMarkdownAndRejectsOutdatedRevisions() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var newsletter = WorkspaceRecord.new("newsletter", projectID: mac.projectID)
    newsletter["title"] = "Friday newsletter"
    newsletter["subtitle"] = "Studio update"
    newsletter["body"] = "Original article"
    newsletter = try mac.save(newsletter)

    let workspaceID = UUID()
    var library = mac.makeCompanionLibrary(workspaceID: workspaceID)
    #expect(library.supportsNewsletterEdits == true)
    let markdown = "## Heading\n\n[Read more](https://example.com/)  \nNext line.\n"
    let edit = CompanionLibrary.Change(action: .editDraft, itemID: newsletter.id,
                                       revision: newsletter["updatedAt"], text: markdown, editsNewsletter: true)
    try library.enqueue(edit)
    #expect(try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(library)).pending == [edit])
    let receipt = try mac.applyCompanionLibraryChange(edit)
    #expect(receipt.error == nil)
    #expect(try mac.applyCompanionLibraryChange(edit) == receipt)

    let saved = try #require(mac.records.first { $0.id == newsletter.id })
    #expect(saved.body == markdown)
    #expect(receipt.newsletterRevision == saved["updatedAt"])
    #expect(saved.title == newsletter.title)
    #expect(saved["subtitle"] == "Studio update")
    #expect(saved["state"] == "draft")
    #expect((saved.fields["revision"] as? Int) == (newsletter.fields["revision"] as? Int).map { $0 + 1 })
    let staleEdit = CompanionLibrary.Change(action: .editDraft, itemID: saved.id,
                                            revision: edit.revision, text: "Old copy", editsNewsletter: true)
    #expect(try mac.applyCompanionLibraryChange(staleEdit).error != nil)
    #expect(mac.makeCompanionLibrary(workspaceID: workspaceID).newsletters?.first?.body == markdown)
}

@Test func mobileNewsletterOutboxWaitsForCompatibleMac() throws {
    let workspaceID = UUID()
    var library = CompanionLibrary(workspaceID: workspaceID)
    library.supportsDraftEdits = true
    let markdown = "  Keep [the link](https://example.com/) and spacing.  \n"
    var outbox = CompanionLibraryOutbox()
    outbox.entries = [.init(id: UUID(), action: .editDraft, itemID: "newsletter", revision: "1",
                            title: "", text: markdown, workspaceID: workspaceID, account: "test",
                            editsNewsletter: true)]
    #expect(outbox.prepare(for: library, account: "test").isEmpty)
    let pending = try #require(outbox.entries.first?.change)
    #expect(pending.text == markdown)
    #expect(throws: CompanionLibraryError.self) { try library.enqueue(pending) }
    library.supportsNewsletterEdits = true
    #expect(outbox.prepare(for: library, account: "test") == [pending])
    try library.enqueue(pending)
    #expect(outbox.prepare(for: library, account: "test").isEmpty)
    library.acknowledge([.init(id: pending.id)])
    #expect(outbox.prepare(for: library, account: "test").isEmpty)
    #expect(outbox.entries.isEmpty)
}

@Test @MainActor func newsletterEditsMergeAcrossMacAndMobileThroughTheLibrary() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var newsletter = WorkspaceRecord.new("newsletter", projectID: mac.projectID)
    newsletter["title"] = "Newsletter"
    newsletter["body"] = "Original heading\n\nOriginal closing\n"
    let base = try mac.save(newsletter)
    let workspaceID = UUID()
    var outbox = CompanionLibraryOutbox()
    func edit(_ text: String, basedOn markdown: String) -> CompanionLibraryOutbox.Entry {
        .init(id: UUID(), action: .editDraft, itemID: base.id, revision: base["updatedAt"], title: "",
              text: text, workspaceID: workspaceID, account: "test", editsNewsletter: true, baseNewsletterText: markdown)
    }
    outbox.queueNewsletterEdit(edit("Mobile heading\n\nOriginal closing\n", basedOn: base.body))
    var library = mac.makeCompanionLibrary(workspaceID: workspaceID)
    let changes = outbox.prepare(for: library, account: "test")
    let pending = try #require(changes.first)
    try library.enqueue(pending)
    outbox.queueNewsletterEdit(edit("Mobile heading\n\nMobile addition\n\nOriginal closing\n", basedOn: pending.text))

    newsletter = base
    newsletter["body"] = "Original heading\n\nMac closing\n"
    newsletter["subtitle"] = "Changed on Mac"
    let macEdit = try mac.save(newsletter)
    let firstReceipt = try mac.applyCompanionLibraryChange(pending)
    #expect(firstReceipt.error == nil)
    #expect(mac.records.first { $0.id == base.id }?.body == "Mobile heading\n\nMac closing\n")
    library = mac.makeCompanionLibrary(workspaceID: workspaceID)
    library.acknowledge([firstReceipt])
    let successor = try #require(outbox.prepare(for: library, account: "test").first)
    let secondReceipt = try mac.applyCompanionLibraryChange(successor)
    #expect(secondReceipt.error == nil)
    #expect(mac.records.first { $0.id == base.id }?.body == "Mobile heading\n\nMobile addition\n\nMac closing\n")

    var desktopEditor = macEdit
    desktopEditor["body"] += "\nMac postscript"
    let final = try mac.saveNewsletterEditor(desktopEditor, basedOn: macEdit)
    #expect(final.body == "Mobile heading\n\nMobile addition\n\nMac closing\n\nMac postscript")
    #expect(final["subtitle"] == "Changed on Mac")
    let conflict = CompanionLibrary.Change(action: .editDraft, itemID: base.id, revision: base["updatedAt"],
                                           text: "Conflicting heading\n\nOriginal closing\n", editsNewsletter: true,
                                           baseNewsletterText: base.body)
    #expect(try mac.applyCompanionLibraryChange(conflict).error?.contains("same part") == true)
    #expect(mac.records.first { $0.id == base.id }?.body == final.body)
}

@Test func coalescedNewsletterEditKeepsItsOriginalBase() {
    let workspaceID = UUID()
    var outbox = CompanionLibraryOutbox()
    func edit(_ text: String, basedOn base: String) -> CompanionLibraryOutbox.Entry {
        .init(id: UUID(), action: .editDraft, itemID: "letter", revision: "1", title: "",
              text: text, workspaceID: workspaceID, account: "test", editsNewsletter: true, baseNewsletterText: base)
    }
    outbox.queueNewsletterEdit(edit("First save", basedOn: "Original newsletter"))
    outbox.queueNewsletterEdit(edit("Second save", basedOn: "First save"))
    #expect(outbox.entries.first?.text == "Second save")
    #expect(outbox.entries.first?.baseNewsletterText == "Original newsletter")
}

@Test func repeatedNewsletterSavesKeepLatestAndWaitForTheConfirmedRevision() throws {
    var library = CompanionLibrary(workspaceID: UUID())
    library.supportsDraftEdits = true
    var outbox = CompanionLibraryOutbox()
    let account = "test"
    func edit(_ markdown: String) -> CompanionLibraryOutbox.Entry {
        .init(id: UUID(), action: .editDraft, itemID: "letter", revision: "1", title: "", text: markdown,
              workspaceID: library.workspaceID, account: account, editsNewsletter: true)
    }
    outbox.queueNewsletterEdit(edit("First save"))
    #expect(outbox.prepare(for: library, account: account).isEmpty)
    outbox.queueNewsletterEdit(edit("Second save"))
    #expect(outbox.entries.map(\.text) == ["Second save"])

    library.supportsNewsletterEdits = true
    let sent = try #require(outbox.prepare(for: library, account: account).first)
    try library.enqueue(sent)
    outbox.queueNewsletterEdit(edit("Third save"))
    outbox.queueNewsletterEdit(edit("Fourth save"))
    #expect(outbox.entries.map(\.text) == ["Second save", "Fourth save"])
    #expect(outbox.prepare(for: library, account: account).isEmpty)
    outbox = try JSONDecoder().decode(CompanionLibraryOutbox.self, from: JSONEncoder().encode(outbox))

    library.newsletters = [.init(id: "letter", revision: "2", kind: .newsletter, projectID: "test",
                                 title: "Letter", body: "", shortened: true, platform: "substack", status: "draft", notes: [])]
    library.acknowledge([.init(id: sent.id, newsletterRevision: "2")])
    var conflict = outbox
    var changedLibrary = library
    changedLibrary.newsletters = [.init(id: "letter", revision: "3", kind: .newsletter, projectID: "test",
                                        title: "Letter", body: "Mac edits", shortened: false, platform: "substack", status: "draft", notes: [])]
    #expect(conflict.prepare(for: changedLibrary, account: account).isEmpty)
    #expect(conflict.entries.first?.text == "Fourth save")
    #expect(conflict.entries.first?.error != nil)

    let newest = try #require(outbox.prepare(for: library, account: account).first)
    #expect(newest.text == "Fourth save")
    #expect(newest.revision == "2")
    #expect(outbox.entries.count == 1)
}

@Test @MainActor func newsletterSyncKeepsTitlesAndAllStatesWithoutChangingLegacyItems() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let database = try #require(workspace.database)
    let draft = try #require(workspace.drafts.first)
    let states = ["draft", "synced", "scheduled", "published"]
    for index in 0..<64 {
        var newsletter = WorkspaceRecord.new("newsletter", projectID: workspace.projectID)
        newsletter["title"] = "Newsletter \(index)"
        newsletter["body"] = String(repeating: "A long issue. ", count: 1_000)
        newsletter = try workspace.save(newsletter)
        newsletter["state"] = states[index % states.count]
        try database.put(newsletter)
    }
    try workspace.reload()
    let snapshot = workspace.makeCompanionLibrary(workspaceID: UUID())
    let newsletters = try #require(snapshot.newsletters)
    #expect(newsletters.count == 64)
    #expect(newsletters.allSatisfy { $0.kind == .newsletter && $0.platform == "substack" && !$0.shortened })
    #expect(Set(newsletters.map(\.status)) == Set(states))
    #expect(newsletters.allSatisfy { $0.body == String(repeating: "A long issue. ", count: 1_000) })
    #expect(snapshot.hasMoreNewsletters == false)
    #expect(snapshot.items.contains { $0.id == draft.id })
    #expect(snapshot.items.allSatisfy { $0.kind != .newsletter })
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(CompanionLibrary.self, from: data) == snapshot)
    let oldSnapshot = CompanionLibrary(workspaceID: snapshot.workspaceID)
    #expect(try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(oldSnapshot)).newsletters == nil)
}

@Test func fullTextSurvivesMultipleCloudRecordsAndRejectsIncompleteData() throws {
    let randomText = Data((0..<14_000).flatMap { SHA256.hash(data: Data(String($0).utf8)) }).base64EncodedString()
    let post = randomText + "\nEnd of post. 🎨"
    let newsletter = String(randomText.reversed()) + "\nEnd of newsletter. 📰"
    var library = CompanionLibrary(workspaceID: UUID())
    library.items = [.init(id: "post", revision: "1", kind: .draft, projectID: "studio",
                           title: "Post", body: post, shortened: false, platform: "linkedin", status: "draft", notes: [])]
    library.newsletters = [.init(id: "letter", revision: "1", kind: .newsletter, projectID: "studio",
                                 title: "Newsletter", body: newsletter, shortened: false, platform: "substack", status: "published", notes: [])]
    let separated = try library.separateFullText()
    let data = try #require(separated)
    #expect(try #require(library.fullText).partCount > 1)
    #expect(library.items[0].shortened && library.items[0].body.isEmpty)
    var received = try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(library))
    #expect(throws: CompanionScheduleError.changed) { try received.applyFullText(Data(data.dropLast())) }
    #expect(received == library)
    try received.applyFullText(data)
    #expect(received.items[0].body == post && !received.items[0].shortened)
    #expect(received.newsletters?.first?.body == newsletter && received.newsletters?.first?.shortened == false)
}

@Test @MainActor func syncedRevisionCommentRunsOnMacOnceAndUpdatesTheNextSnapshot() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    let draft = try #require(mac.drafts.first)
    let request = CompanionLibrary.Change(action: .note, itemID: draft.id,
                                          revision: draft["updatedAt"], text: "Open with a shorter sentence.")
    #expect(try mac.applyCompanionLibraryChange(request).error == nil)
    #expect(try mac.applyCompanionLibraryChange(request).error == nil)
    let cloudID = UUID()
    let waiting = mac.makeCompanionLibrary(workspaceID: cloudID).items.first { $0.id == draft.id }
    #expect(waiting?.notes == ["Open with a shorter sentence."])
    #expect(waiting?.noteStates == ["pending"])
    var calls = 0
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, context in
        calls += 1
        #expect(context["notes"] as? String == "Open with a shorter sentence.")
        return ["text": "Keep the tools you use."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await mac.runDraftRevisionComments(model: model)
    #expect(calls == 0)
    try mac.set("mcpEnabled", to: true)
    await mac.runDraftRevisionComments(model: model)
    await mac.runDraftRevisionComments(model: model)
    #expect(calls == 1)
    let updated = try #require(mac.drafts.first { $0.id == draft.id })
    #expect(updated.body == "Keep the tools you use.")
    #expect(updated["previousContent"] == draft.body)
    #expect(updated.scheduleStatus == draft.scheduleStatus)
    let synced = mac.makeCompanionLibrary(workspaceID: cloudID).items.first { $0.id == draft.id }
    #expect(synced?.noteStates == ["applied"])
    #expect(synced?.body == updated.body)
}

@Test @MainActor func trashRoundTripPreservesContentAndRejectsStaleEditors() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var draft = try #require(mac.drafts.first)
    draft.fields["video"] = ["file": "keep-this-video.mp4"]
    draft = try mac.save(draft)
    try mac.addComment(to: draft, text: "Keep this note")
    draft = try #require(mac.drafts.first { $0.id == draft.id })
    #expect(throws: WorkspaceError.self) { try mac.deleteLibraryItem(draft) }
    let trash = CompanionLibrary.Change(action: .trashItem, itemID: draft.id, revision: draft["updatedAt"])
    #expect(try mac.applyCompanionLibraryChange(trash).error == nil)
    #expect(try mac.applyCompanionLibraryChange(trash).error == nil)
    let repeatedMove = CompanionLibrary.Change(action: .trashItem, itemID: draft.id, revision: draft["updatedAt"])
    #expect(try mac.applyCompanionLibraryChange(repeatedMove).error == nil)
    #expect(!mac.drafts.contains { $0.id == draft.id })
    #expect(throws: WorkspaceError.self) { try mac.save(draft) }
    let trashed = try #require(mac.trashedRecords.first { $0.id == draft.id })
    #expect(mac.makeCompanionLibrary(workspaceID: UUID()).items.first { $0.id == draft.id }?.isTrashed == true)
    let restore = CompanionLibrary.Change(action: .restoreItem, itemID: draft.id, revision: trashed["updatedAt"])
    #expect(try mac.applyCompanionLibraryChange(restore).error == nil)
    let restored = try #require(mac.drafts.first { $0.id == draft.id })
    #expect(restored.body == draft.body)
    #expect(restored.fields["video"] as? [String: String] == ["file": "keep-this-video.mp4"])
    #expect(restored.comments.first?["text"] as? String == "Keep this note")
    #expect(restored.schedule.isEmpty)
    try mac.trashLibraryItem(restored)
    let current = try #require(mac.trashedRecords.first { $0.id == draft.id })
    let delete = CompanionLibrary.Change(action: .deleteItem, itemID: draft.id, revision: current["updatedAt"])
    #expect(try mac.applyCompanionLibraryChange(delete).error == nil)
    #expect(try mac.applyCompanionLibraryChange(delete).error == nil)
    let repeatedDelete = CompanionLibrary.Change(action: .deleteItem, itemID: draft.id, revision: current["updatedAt"])
    #expect(try mac.applyCompanionLibraryChange(repeatedDelete).error == nil)
    #expect(!mac.trashedRecords.contains { $0.id == draft.id })
    #expect(throws: WorkspaceError.self) { try mac.save(restored) }
    let reopened = Workspace(directory: folder)
    #expect(throws: WorkspaceError.self) { try reopened.save(restored) }
}

@Test @MainActor func mobileAndMacManualEditsUnschedulePostsConsistently() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var draft = try #require(mac.drafts.first)
    draft.fields["schedule"] = ["status": "queued", "slotAt": "2030-01-01T12:00:00Z"]
    draft = try mac.save(draft)
    let edit = CompanionLibrary.Change(action: .editDraft, itemID: draft.id, revision: draft["updatedAt"], title: "A manually edited title", text: "A manually edited post.")
    #expect(try mac.applyCompanionLibraryChange(edit).error == nil)
    let edited = try #require(mac.drafts.first { $0.id == draft.id })
    #expect(edited.title == "A manually edited title")
    #expect(edited.body == "A manually edited post.")
    #expect(edited.scheduleStatus == "ready")
    #expect(edited.schedule["slotAt"] as? String == "")
    try mac.updatePostText(edited, title: "Edited on Mac", text: "No AI required.")
    #expect(mac.drafts.first { $0.id == draft.id }?.title == "Edited on Mac")
}

@Test(arguments: [false, true])
@MainActor func mobileTrashRetriesAndConfirmedDeletionUsesTheTrashedRevision(busyMac: Bool) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    let workspaceID = UUID()
    var idea = WorkspaceRecord.new("idea", projectID: mac.projectID)
    idea["topic"] = "Fixture for Trash"
    idea["text"] = "An idea to remove."
    idea = try mac.save(idea)
    var library = mac.makeCompanionLibrary(workspaceID: workspaceID)
    let moveID = UUID()
    let deleteID = UUID()
    var outbox = CompanionLibraryOutbox()
    outbox.entries = [
        .init(id: moveID, action: .trashItem, itemID: idea.id, revision: idea["updatedAt"],
              title: "", text: "", workspaceID: workspaceID, account: "fixture"),
        .init(id: deleteID, action: .deleteItem, itemID: idea.id, revision: idea["updatedAt"],
              title: "", text: "", workspaceID: workspaceID, account: "fixture", afterTrash: moveID)
    ]
    let moves = outbox.prepare(for: library, account: "fixture")
    #expect(moves.count == 1)
    let move = try #require(moves.first)
    let failure: CompanionLibrary.Result
    if busyMac {
        let lease = try mac.claimPublication()
        failure = try withExtendedLifetime(lease) { try mac.applyCompanionLibraryChange(move) }
    } else {
        idea["text"] = "Edited on the Mac while mobile was offline."
        try mac.save(idea)
        failure = try mac.applyCompanionLibraryChange(move)
    }
    #expect(failure.error != nil)
    library = mac.makeCompanionLibrary(workspaceID: workspaceID)
    library.acknowledge([failure])
    let retries = outbox.prepare(for: library, account: "fixture")
    #expect(retries.count == 1)
    let retry = try #require(retries.first)
    #expect(retry.action == .trashItem)
    #expect(retry.id != moveID)
    #expect(outbox.entries.allSatisfy { $0.error == nil })
    let moved = try mac.applyCompanionLibraryChange(retry)
    #expect(moved.error == nil)
    let reopened = Workspace(directory: folder)
    #expect(reopened.trashedRecords.contains { $0.id == idea.id })
    #expect(!reopened.ideas.contains { $0.id == idea.id })

    library = reopened.makeCompanionLibrary(workspaceID: workspaceID)
    library.acknowledge([moved])
    let deletes = outbox.prepare(for: library, account: "fixture")
    #expect(deletes.count == 1)
    let delete = try #require(deletes.first)
    #expect(delete.action == .deleteItem)
    #expect(delete.id == deleteID)
    #expect(delete.revision != move.revision)
    #expect(try reopened.applyCompanionLibraryChange(delete).error == nil)
    #expect(try reopened.applyCompanionLibraryChange(delete).error == nil)
    let final = Workspace(directory: folder)
    #expect(!(final.records + final.trashedRecords).contains { $0.id == idea.id })
    #expect(throws: WorkspaceError.self) { try final.save(idea) }
}

@Test @MainActor func legacySkippedIdeasAppearInTrashAndRestore() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var idea = WorkspaceRecord.new("idea", projectID: mac.projectID)
    idea["topic"] = "Recover this idea"
    idea["text"] = "Original angle"
    idea["status"] = "skipped"
    try mac.save(idea)
    let skipped = try #require(mac.trashedRecords.first { $0.id == idea.id })
    try mac.restoreLibraryItem(skipped)
    let restored = try #require(mac.ideas.first { $0.id == idea.id })
    #expect(restored["status"] == "draft")
    try mac.updatePostText(restored, title: "Edited idea title", text: "Edited idea angle")
    #expect(mac.ideas.first { $0.id == idea.id }?.title == "Edited idea title")
}

@Test @MainActor func busyLibraryReservesRoomForTrashAndCompleteDraftText() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var draft = try #require(mac.drafts.first)
    draft["content"] = String(repeating: "a", count: 60_000)
    try #require(mac.database).put(draft)
    try mac.reload()
    for index in 0..<55 {
        var idea = WorkspaceRecord.new("idea", projectID: mac.projectID)
        idea["topic"] = "Idea \(index)"
        idea["text"] = "An angle"
        let saved = try mac.save(idea)
        if index == 0 { try mac.trashLibraryItem(saved) }
    }
    let snapshot = mac.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.hasMore)
    #expect(snapshot.items.contains { $0.kind == .idea && $0.isTrashed == true })
    #expect(snapshot.items.first { $0.id == draft.id }?.body == draft.body)
    #expect(snapshot.items.first { $0.id == draft.id }?.shortened == false)
}

@Test func managementWaitsForCompatibleMacAndOriginalAccount() throws {
    var library = CompanionLibrary(workspaceID: UUID())
    library.projects = [.init(id: "studio", name: "Studio")]
    let change = CompanionLibrary.Change(action: .trashItem, itemID: "draft", revision: "1")
    var outbox = CompanionLibraryOutbox()
    outbox.entries = [.init(id: change.id, action: change.action, itemID: change.itemID, revision: change.revision,
                            title: "", text: "", workspaceID: library.workspaceID, account: "original")]
    #expect(outbox.prepare(for: library, account: "original").isEmpty)
    library.supportsItemManagement = true
    #expect(outbox.prepare(for: library, account: "other").isEmpty)
    #expect(outbox.prepare(for: library, account: "original") == [change])
}

@Test @MainActor func recentMobileDraftsIncludeOlderVideoAttachments() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var video = WorkspaceRecord.new("draft", projectID: mac.projectID)
    video["title"] = "Edited video"
    video.setDraftMedia(["file": "clip.mp4"], as: .video)
    try mac.save(video)
    for index in 0..<52 {
        var image = WorkspaceRecord.new("draft", projectID: mac.projectID)
        image["title"] = "Image draft \(index)"
        image.setDraftMedia(["file": "still.png"], as: .image)
        try mac.save(image)
    }
    let snapshot = mac.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.hasMore)
    #expect(snapshot.items.first { $0.id == video.id }?.attachment == .video)
    #expect(snapshot.items.filter { $0.kind == .draft && $0.isTrashed != true }.count == 50)
    #expect(snapshot.items.contains { $0.attachment == .image })
}

@Test @MainActor func mobileScheduleUsesMacPostingPreferencesAndRejectsDuplicateSlots() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: .now))
    let hour = try #require(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow))
    let outside = try #require(Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow))
    try mac.setPostingPreferences(for: "x", window: .init(firstHour: 10, lastHour: 15), minute: 23)
    var draft = WorkspaceRecord.new("draft", projectID: mac.projectID)
    draft["content"] = "A draft to schedule."
    draft = try mac.save(draft)
    let next = try mac.save(WorkspaceRecord(kind: "draft", fields: draft.fields.merging(["id": UUID().uuidString]) { _, new in new }))
    func request(_ item: WorkspaceRecord, at hour: Date) -> CompanionLibrary.Change {
        .init(action: .scheduleDraft, itemID: item.id, revision: item["updatedAt"], text: hour.formatted(.iso8601))
    }
    var snapshot = mac.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.postingWindows?["x"]?.hours == 10...15)
    #expect(try mac.applyCompanionLibraryChange(request(draft, at: outside)).error != nil)
    let schedule = request(draft, at: hour)
    try snapshot.enqueue(schedule)
    #expect(try mac.applyCompanionLibraryChange(schedule).error == nil)
    #expect(try mac.applyCompanionLibraryChange(schedule).error == nil)
    let scheduled = try #require(mac.drafts.first { $0.id == draft.id })
    let slot = try #require((scheduled.schedule["slotAt"] as? String).flatMap(scheduleDate))
    #expect(scheduled.scheduleStatus == "queued")
    #expect(Calendar.current.component(.minute, from: slot) == 23)
    #expect(try mac.applyCompanionLibraryChange(request(next, at: hour)).error != nil)
    #expect(mac.drafts.first { $0.id == next.id }?.scheduleStatus == "")
}

@Test @MainActor func mobileIdeasAndReviewNotesAreAppliedOnceWithoutScheduling() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    let idea = CompanionLibrary.Change(action: .addIdea, itemID: mac.projectID,
                                       title: "Show a work in progress", text: "Explain one decision and why it mattered.")
    #expect(try mac.applyCompanionLibraryChange(idea).error == nil)
    let reopened = Workspace(directory: folder)
    #expect(try reopened.applyCompanionLibraryChange(idea).error == nil)
    let imported = try #require(reopened.ideas.first { $0.id == idea.id.uuidString.lowercased() })
    #expect(reopened.ideas.filter { $0.id == imported.id }.count == 1)
    #expect(imported["status"] == "draft")
    #expect(imported.schedule.isEmpty)

    let draft = try #require(reopened.drafts.first)
    let note = CompanionLibrary.Change(action: .note, itemID: draft.id, revision: draft["updatedAt"],
                                       text: "Lead with the example.")
    #expect(try reopened.applyCompanionLibraryChange(note).error == nil)
    #expect(try reopened.applyCompanionLibraryChange(note).error == nil)
    let reviewed = try #require(reopened.drafts.first { $0.id == draft.id })
    #expect(reviewed.comments.compactMap { $0["text"] as? String } == ["Lead with the example."])
    #expect(reviewed.schedule.isEmpty)
    #expect(reopened.settings["autoPost"] as? Bool != true)

    let skip = CompanionLibrary.Change(action: .skipIdea, itemID: imported.id, revision: imported["updatedAt"])
    #expect(try reopened.applyCompanionLibraryChange(skip).error == nil)
    let stale = CompanionLibrary.Change(action: .restoreIdea, itemID: imported.id, revision: imported["updatedAt"])
    #expect(try reopened.applyCompanionLibraryChange(stale).error != nil)
    #expect(reopened.trashedRecords.contains { $0.id == imported.id })
    let snapshot = reopened.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.items.first { $0.id == draft.id }?.notes == ["Lead with the example."])
}

@Test func mobileLibraryAcknowledgmentsKeepConcurrentChangesAndDisableSharing() throws {
    var library = CompanionLibrary(workspaceID: UUID())
    let first = CompanionLibrary.Change(action: .addIdea, itemID: "studio", title: "First", text: "First angle")
    let second = CompanionLibrary.Change(action: .addIdea, itemID: "studio", title: "Second", text: "Second angle")
    try library.enqueue(first)
    try library.enqueue(second)
    library.acknowledge([.init(id: first.id)])
    try library.enqueue(first)
    #expect(library.pending == [second])
    #expect(try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(library)) == library)
    library.clear()
    #expect(library.pending.isEmpty && library.items.isEmpty && library.results.isEmpty)
    #expect(throws: CompanionLibraryError.self) { try library.enqueue(second) }
}

@Test func legacyMobileIdeasJoinTheOutboxWithoutResendingAcknowledgedIdeas() throws {
    let workspaceID = UUID()
    let unsentID = UUID()
    let sentID = UUID()
    let deliveryID = UUID()
    let legacy: [[String: Any]] = [
        ["id": unsentID.uuidString, "title": "Local idea", "body": "An angle"],
        ["id": sentID.uuidString, "title": "Already synced", "body": "An earlier angle",
         "delivery": ["workspaceID": workspaceID.uuidString, "changeID": deliveryID.uuidString]]
    ]
    var outbox = CompanionLibraryOutbox()
    try outbox.migrateIdeas(from: JSONSerialization.data(withJSONObject: legacy))
    var library = CompanionLibrary(workspaceID: workspaceID)
    library.projects = [.init(id: "studio", name: "Studio")]
    library.acknowledge([.init(id: deliveryID)])

    let changes = outbox.prepare(for: library, account: "original")
    #expect(changes.map(\.id) == [unsentID])
    #expect(changes.first?.itemID == "studio")
    #expect(outbox.prepare(for: library, account: "other").isEmpty)
    try library.enqueue(try #require(changes.first))
    #expect(outbox.prepare(for: library, account: "original").isEmpty)
    library.acknowledge([.init(id: unsentID)])
    #expect(outbox.prepare(for: library, account: "original").isEmpty)
    #expect(outbox.entries.isEmpty)
}

@Test @MainActor func mobileDraftEditsPreserveMediaAndRejectStaleRevisions() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var draft = try #require(mac.drafts.first)
    draft["format"] = "image"
    let image = ["file": "\(UUID().uuidString.lowercased()).png"]
    draft.fields["image"] = image
    draft = try mac.save(draft)
    let revision = draft["updatedAt"]
    let edit = CompanionLibrary.Change(action: .editDraft, itemID: draft.id, revision: revision,
                                       title: "Updated title", text: "Updated body\n")
    var library = mac.makeCompanionLibrary(workspaceID: UUID())
    #expect(library.supportsDraftEdits == true)
    try library.enqueue(edit)
    #expect(try mac.applyCompanionLibraryChange(edit).error == nil)
    let saved = try #require(mac.drafts.first)
    #expect(saved.title == "Updated title")
    #expect(saved.body == "Updated body\n")
    #expect(saved.fields["image"] as? [String: String] == image)
    #expect(saved.schedule.isEmpty)
    let stale = CompanionLibrary.Change(action: .editDraft, itemID: draft.id, revision: revision,
                                        title: "Stale edit", text: "Stale")
    #expect(try mac.applyCompanionLibraryChange(stale).error != nil)
    let note = CompanionLibrary.Change(action: .note, itemID: draft.id, revision: revision, text: "Review this.")
    #expect(try mac.applyCompanionLibraryChange(note).error == nil)
    library = mac.makeCompanionLibrary(workspaceID: library.workspaceID)
    let item = try #require(library.items.first { $0.id == draft.id })
    #expect(item.attachment == .image)
    #expect(item.notes == ["Review this."])
    #expect(item.noteDates?.first?.isEmpty == false)
}

@Test func withdrawingMobileRevisionIsDurableAndTakesPriorityInAFullQueue() throws {
    var library = CompanionLibrary(workspaceID: UUID())
    library.supportsRevisionWithdrawal = true
    library.supportsAgentFeatures = true
    library.supportsWritingTools = true
    let pending = CompanionLibraryOutbox.Entry(id: UUID(), action: .note, itemID: "draft", revision: "first",
        title: "", text: "Shorten it.", workspaceID: library.workspaceID, account: "phone", requestsWritingHelp: true,
        revisionPrepared: false)
    var local = CompanionLibraryOutbox(entries: [pending])
    try local.withdrawRevision(pending.id, itemID: "draft", workspaceID: library.workspaceID, account: "phone", supportedByMac: false)
    #expect(local.entries.isEmpty)

    var prepared = CompanionLibraryOutbox(entries: [pending])
    let original = try #require(prepared.prepare(for: library, account: "phone").first)
    #expect(prepared.entries.first?.revisionPrepared == true)
    try library.enqueue(original)
    try prepared.withdrawRevision(pending.id, itemID: "draft", workspaceID: library.workspaceID, account: "phone", supportedByMac: true)
    var relaunched = try JSONDecoder().decode(CompanionLibraryOutbox.self, from: JSONEncoder().encode(prepared))
    let withdrawal = try #require(relaunched.prepare(for: library, account: "phone").first)
    #expect(withdrawal.withdrawsRevision == original.id)
    try library.enqueue(withdrawal)
    #expect(library.pending.map(\.id) == [withdrawal.id])
    library.pending = []
    for index in 0..<24 {
        try library.enqueue(.init(action: .note, itemID: "other", revision: "v1", text: "Ordinary note \(index)"))
    }
    try library.enqueue(withdrawal)
    #expect(library.pending.count == 25 && library.pending.last?.id == withdrawal.id)
    library.acknowledge([.init(id: withdrawal.id)])
    #expect(relaunched.prepare(for: library, account: "phone").isEmpty)
    #expect(relaunched.entries.isEmpty)
}

@Test @MainActor func withdrawingRevisionDuringGenerationDiscardsItsOutputAndPreservesOtherWork() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    try mac.set("mcpEnabled", to: true)
    let draft = try #require(mac.drafts.first)
    let first = CompanionLibrary.Change(action: .note, itemID: draft.id, revision: draft["updatedAt"], text: "Change the title.", requestsWritingHelp: true)
    let second = CompanionLibrary.Change(action: .note, itemID: draft.id, revision: draft["updatedAt"], text: "Keep the introduction.", requestsWritingHelp: true)
    var withdrawal = CompanionLibrary.Change(action: .note, itemID: draft.id)
    withdrawal.withdrawsRevision = first.id
    #expect(try mac.applyCompanionLibraryChange(first).error == nil)
    #expect(try mac.applyCompanionLibraryChange(second).error == nil)
    var calls = 0
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, context in
        calls += 1
        if calls == 1 {
            #expect((context["notes"] as? String)?.contains(first.text) == true)
            let receipt = try? mac.applyCompanionLibraryChange(withdrawal)
            #expect(receipt?.id == withdrawal.id && receipt?.error == nil)
            return ["text": "This cancelled result must never be saved."]
        }
        #expect(context["notes"] as? String == second.text)
        return ["text": "Only the remaining change was applied."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "fixture")
    await mac.runDraftRevisionComments(model: model)
    #expect(calls == 2)
    let updated = try #require(mac.drafts.first { $0.id == draft.id })
    #expect(updated.body == "Only the remaining change was applied.")
    #expect(updated.appliedRevisionCommentIDs == [second.id.uuidString.lowercased()])
    #expect(updated.comments.count == 1)
    var tooLate = CompanionLibrary.Change(action: .note, itemID: draft.id)
    tooLate.withdrawsRevision = second.id
    #expect(try mac.applyCompanionLibraryChange(tooLate).error?.contains("Already applied") == true)
    // Simulate delivery of an original request after its ordinary short-lived receipt fell out of the window.
    try mac.set("companionLibraryApplied", to: [String]())
    let reopened = Workspace(directory: folder)
    #expect(try reopened.applyCompanionLibraryChange(first).error == nil)
    #expect(reopened.drafts.first { $0.id == draft.id }?.pendingRevisionComments.isEmpty == true)
    #expect(reopened.withdrawnRevisionIDs(for: draft.id).contains(first.id.uuidString.lowercased()))
}
