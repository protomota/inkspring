import Foundation
import Testing
@testable import Inkspring

@Test @MainActor func retiredWritingStaysInBackupsAndFormerPairsRequireANewSchedule() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    let database = try #require(workspace.database)
    var archived = WorkspaceRecord.new("article", projectID: workspace.projectID)
    archived["platform"] = "linkedin"
    archived["title"] = "Saved writing"
    archived["body"] = "# A heading\n\nKeep the original text."
    _ = try database.put(archived)

    var post = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    post["platform"] = "linkedin"
    post["content"] = "This text is ready for a video post."
    post["linkedinArticleID"] = archived.id
    post.fields["schedule"] = ["status": "queued", "slotAt": "2026-11-20T17:00:00Z"]
    _ = try database.put(post)
    var xArticle = WorkspaceRecord.new("article", projectID: workspace.projectID)
    xArticle["title"] = "Write for X"
    xArticle = try workspace.save(xArticle)

    let active = try #require(workspace.drafts.first { $0.id == post.id })
    #expect(active.body == post.body)
    #expect(active["linkedinArticleID"].isEmpty)
    #expect(active.scheduleStatus == "ready")
    #expect(active.schedule["slotAt"] as? String == "")
    #expect(!workspace.records.contains { $0.id == archived.id })
    #expect(!workspace.trashedRecords.contains { $0.id == archived.id })
    let snapshot = workspace.makeCompanionLibrary(workspaceID: UUID())
    #expect(snapshot.supportsLinkedInArticles == false)
    #expect(snapshot.articles?.map(\.id) == [xArticle.id])
    let backup = try database.snapshot()
    #expect(backup.records.first { $0.id == archived.id }?.body == archived.body)
    #expect(throws: WorkspaceError.self) { try workspace.save(archived) }
}
