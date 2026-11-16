import Foundation
@testable import InkspringSchedule
import Testing
@testable import Inkspring

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
    draft["content"] = String(repeating: "a", count: 20_000)
    draft = try mac.save(draft)
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
