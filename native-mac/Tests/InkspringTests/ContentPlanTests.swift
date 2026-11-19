import Foundation
import Testing
@testable import Inkspring
@testable import InkspringSchedule

@Test @MainActor func plansSurviveReopenTrashAndIndependentContentEdits() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var letter = WorkspaceRecord.new("newsletter", projectID: mac.projectID)
    letter["title"] = "Notes"; letter["body"] = "Original body"
    letter = try mac.save(letter)
    let plan = "# Plan 👋\n\n- [ ] Verify [source](https://example.com)\n\n```swift\nlet x = 1\n```\n"
    let withPlan = try mac.savePlan(itemID: letter.id, markdown: plan, base: "")
    #expect(withPlan.body == "Original body")
    var oldEditor = letter; oldEditor["body"] = "Edited body"
    let merged = try mac.saveNewsletterEditor(oldEditor, basedOn: letter)
    #expect(merged["planMarkdown"] == plan)
    #expect(throws: ContentPlanError.self) { try mac.savePlan(itemID: letter.id, markdown: "stale", base: "") }
    let reopened = Workspace(directory: folder)
    #expect(reopened.records.first { $0.id == letter.id }?["planMarkdown"] == plan)
    var post = WorkspaceRecord.new("draft", projectID: mac.projectID)
    post["title"] = "Draft"; post["content"] = "Content"; post["planMarkdown"] = plan
    post = try mac.save(post)
    try mac.trashLibraryItem(post)
    let trashed = try #require(mac.trashedRecords.first { $0.id == post.id })
    #expect(trashed["planMarkdown"] == plan)
    try mac.restoreLibraryItem(trashed)
    #expect(mac.records.first { $0.id == post.id }?["planMarkdown"] == plan)
    #expect(try ContentPlan.decode(Data(plan.utf8)) == plan)
    #expect(ContentPlan.filename("pro-001") == "PRO-001-plan.md")
}

@Test @MainActor func mobilePlansUseSeparateFullTextAndDocumentConflicts() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    var post = WorkspaceRecord.new("draft", projectID: mac.projectID)
    post["title"] = "Draft"; post["content"] = "Post"
    post = try mac.save(post)
    var change = CompanionLibrary.Change(action: .editDraft, itemID: post.id, revision: post["updatedAt"], text: "# Plan\n\n- [ ] Test")
    change.contentOperation = .savePlan; change.basePlan = ""
    #expect(change.valid)
    var oldMac = CompanionLibrary(workspaceID: UUID()); oldMac.supportsDraftEdits = true
    #expect(throws: CompanionLibraryError.self) { try oldMac.enqueue(change) }
    #expect(try mac.applyCompanionLibraryChange(change).error == nil)
    #expect(try mac.applyCompanionLibraryChange(change).error == nil)
    #expect(mac.records.first { $0.id == post.id }?.body == "Post")
    var conflict = change
    conflict = CompanionLibrary.Change(action: .editDraft, itemID: post.id, revision: post["updatedAt"], text: "Conflicting plan")
    conflict.contentOperation = .savePlan; conflict.basePlan = ""
    #expect(try mac.applyCompanionLibraryChange(conflict).error != nil)
    var library = mac.makeCompanionLibrary(workspaceID: UUID())
    let expected = library.items.first { $0.id == post.id }?.planMarkdown
    let separated = try library.separateFullText()
    let fullText = try #require(separated)
    #expect(library.items.first { $0.id == post.id }?.planMarkdown == nil)
    try library.applyFullText(fullText)
    #expect(library.items.first { $0.id == post.id }?.planMarkdown == expected)
    var outbox = CompanionLibraryOutbox()
    outbox.entries = [.init(id: change.id, action: .editDraft, itemID: post.id, revision: post["updatedAt"], title: "", text: change.text,
                            workspaceID: library.workspaceID, account: "owner", contentOperation: .savePlan, basePlan: "")]
    #expect(try JSONDecoder().decode(CompanionLibraryOutbox.self, from: JSONEncoder().encode(outbox)) == outbox)
    #expect(outbox.prepare(for: oldMac, account: "owner").isEmpty)
}

@Test @MainActor func assistantOnlyConfirmsValidatedWritesAndRejectsAmbiguity() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    for title in ["Weekly notes one", "Weekly notes two"] {
        var draft = WorkspaceRecord.new("draft", projectID: mac.projectID)
        draft["title"] = title; draft["content"] = "Untouched"
        try mac.save(draft)
    }
    let ambiguous = LocalContentCommand(operation: .title, target: "Weekly notes", value: "Changed")
    #expect(throws: PlanAIError.self) { try mac.executeAssistant(ambiguous, request: "Rename Weekly notes to Changed") }
    let item = try #require(mac.assistantContents.first { $0.title == "Weekly notes one" })
    let injected = LocalContentCommand(operation: .body, target: item.reference, value: "Bad")
    #expect(throws: PlanAIError.self) { try mac.executeAssistant(injected, request: "Read the other item") }
    #expect(throws: PlanAIError.self) { try mac.executeAssistant(injected, request: "Do not change \(item.reference)") }
    let edit = LocalContentCommand(operation: .title, target: item.reference, value: "Better title")
    let receipt = try mac.executeAssistant(edit, request: "Rename \(item.reference) to Better title")
    #expect(receipt.itemID == item.id)
    #expect(mac.records.first { $0.id == item.id }?.title == "Better title")
    #expect(receipt.message.contains("Saved on this Mac"))
    #expect(mac.records.filter { $0.kind == "draft" }.allSatisfy { $0.scheduleStatus != "posted" })
}

@Test @MainActor func planProofreadingCannotDropMarkdownPrefixesOrCode() async throws {
    let original = "# We has a plan\n\n- [ ] Check this\n\n    We has code\n\n~~~swift\nWe has code too\n~~~"
    let review = try await ProofreadReview.check(.init(body: original), chunkSize: 500) { _ in
        [.init(original: "# We has a plan", replacement: "We have a plan", reason: "Bad heading loss"),
         .init(original: "- [ ] Check this", replacement: "Check this", reason: "Bad checklist loss"),
         .init(original: "We has code too", replacement: "We have code too", reason: "Code"),
         .init(original: "We has a plan", replacement: "We have a plan", reason: "Grammar")]
    }
    #expect(review.corrected.body == original.replacingOccurrences(of: "We has a plan", with: "We have a plan"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["INKSPRING_TEST_LOCAL_AI"] == "1")) @MainActor
func realAppleIntelligencePreservesMarkdownAndExecutesValidatedRename() async throws {
    #expect(PlanIntelligence.unavailable == nil)
    let original = "# Studio update\n\nWe has a plan.\n\n- [ ] Test the draft\n\n[Read](https://example.com/)\n\n```swift\nlet value = 1\n```"
    let corrected = try await PlanIntelligence.proofread(original)
    #expect(corrected.contains("# Studio update"))
    #expect(corrected.contains("- [ ] Test the draft"))
    #expect(corrected.contains("https://example.com/"))
    #expect(corrected.contains("```swift\nlet value = 1\n```"))
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    if let error = workspace.startupError { throw PlanAIError("Test workspace startup: " + error) }
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Test newsletter angle"; draft["content"] = "Untouched body"
    draft = try workspace.save(draft)
    let request = "Rename \(draft.referenceID!) to A clearer title"
    let command = try await OnDeviceContentAssistant.command(request, items: workspace.assistantContents)
    #expect(command.operation == .title)
    let result = try workspace.executeAssistant(command, request: request)
    #expect(result.itemID == draft.id)
    #expect(workspace.records.first { $0.id == draft.id }?.title == "A clearer title")
    print("REAL ON-DEVICE AI: proofreading preserved Markdown; structured rename applied and read back from SQLite. \(result.message)")
}

@Test @MainActor func fullBackupPreservesPlansAndPreviousRevision() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    if let error = workspace.startupError { throw PlanAIError("Test workspace startup: " + error) }
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Backup test"; draft["content"] = "Content"
    draft = try workspace.save(draft)
    try workspace.savePlan(itemID: draft.id, markdown: "# First plan", base: "")
    try workspace.savePlan(itemID: draft.id, markdown: "# Second plan", base: "# First plan")
    let archive = folder.appending(path: "backup.zip")
    try WorkspaceBackup.export(records: workspace.records, preferences: workspace.settings, directory: folder, to: archive)
    let (backup, _) = try WorkspaceBackup.stage(archive, in: folder)
    let restored = try #require(backup.records.first { $0.id == draft.id })
    #expect(restored["planMarkdown"] == "# Second plan")
    #expect(restored["previousPlanMarkdown"] == "# First plan")
}

@Test @MainActor func proofreadingProtectsNestedShorterFencesAndIndentedCode() async throws {
    let body = "~~~~text\nWe has fenced code\n~~~\nWe has more code\n~~~~\n\n    We has indented code\n\nWe has prose."
    let review = try await ProofreadReview.check(.init(body: body), chunkSize: 500) { _ in
        ["We has fenced code", "We has more code", "We has indented code", "We has prose."].map {
            ProofreadEdit(original: $0, replacement: $0.replacingOccurrences(of: "has", with: "have"), reason: "Grammar")
        }
    }
    #expect(review.corrected.body == body.replacingOccurrences(of: "We has prose.", with: "We have prose."))
}

@Test @MainActor func createWithPlanPersistsItWithoutPublishing() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let command = LocalContentCommand(operation: .createDraft, value: "A first draft", title: "Studio notes")
    let result = try workspace.executeAssistant(command, request: "Create a draft called Studio notes with a plan")
    let draft = try #require(workspace.records.first { $0.id == result.itemID })
    #expect(draft["planMarkdown"].contains("# Studio notes"))
    #expect(draft.scheduleStatus != "posted")
    #expect(try ContentPlan.decode(Data(draft["planMarkdown"].utf8)) == draft["planMarkdown"])
}

@Test @MainActor func mcpPlansRequireExpectedTextAndRespectProjectScope() async throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    try workspace.set("mcpEnabled", to: true)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Plan via MCP"; draft = try workspace.save(draft)
    let agent = AgentMCP(workspace: workspace)
    func call(_ agent: AgentMCP, _ name: String, _ args: [String: Any]) async -> [String: Any] {
        await agent.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])?["result"] as? [String: Any] ?? [:]
    }
    let result = await call(agent, "save_plan", ["content_id": draft.referenceID!, "markdown": "# MCP Plan", "expected_markdown": ""])
    #expect(result["isError"] as? Bool != true)
    let read = await call(agent, "get_plan", ["content_id": draft.referenceID!.lowercased()])
    #expect((read["structuredContent"] as? [String: Any])?["markdown"] as? String == "# MCP Plan")
    let stale = await call(agent, "save_plan", ["content_id": draft.id, "markdown": "Old update", "expected_markdown": ""])
    #expect(stale["isError"] as? Bool == true)
    let scoped = await call(AgentMCP(workspace: workspace, chatProjectID: "other-project"), "get_plan", ["content_id": draft.id])
    #expect(scoped["isError"] as? Bool == true)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["INKSPRING_PLAN_REVIEW_WORKSPACE"] != nil)) @MainActor
func prepareLocalPlanReviewLibrary() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INKSPRING_PLAN_REVIEW_WORKSPACE"]!)
    let workspace = Workspace(directory: folder)
    if let error = workspace.startupError { throw PlanAIError(error) }
    try workspace.set("autoPost", to: false)
    try workspace.set("mcpEnabled", to: true)
    var project = try #require(workspace.projects.first)
    project["name"] = "Plan review"
    project = try workspace.save(project)
    workspace.selectProject(project.id)
    if !workspace.records.contains(where: { $0.title == "Notes from the studio" }) {
        var newsletter = WorkspaceRecord.new("newsletter", projectID: project.id)
        newsletter["title"] = "Notes from the studio"
        newsletter["body"] = "# A clearer opening\n\nWe use AI and automation to make more time for work that matters.\n\n[Visit Inkspring](https://inkspring.ai/)"
        newsletter["planMarkdown"] = "# Newsletter plan\n\n## Goal\n\nWe has a plan to explain the workflow.\n\n- [ ] Write the opening\n- [ ] Check the links\n\n[Source](https://inkspring.ai/)\n\n```swift\nlet draft = \"Keep code unchanged\"\n```"
        try workspace.save(newsletter)
        var draft = WorkspaceRecord.new("draft", projectID: project.id)
        draft["title"] = "A quieter way to draft"; draft["platform"] = "linkedin"
        draft["content"] = "Start with the decision you made and why it mattered. One concrete example is enough."
        draft["planMarkdown"] = "# Post plan\n\n- [ ] Open with one useful detail\n- [ ] Keep the claim specific\n- [ ] Review the final draft"
        try workspace.save(draft)
    }
    print("Local review library ready: \(folder.path)")
}

@Test func planOperationsCannotAlsoRequestPublishingOrWriting() {
    var change = CompanionLibrary.Change(action: .editDraft, itemID: "article", revision: "revision", text: "# Plan", publishesXArticle: true, xArticleAccountKey: "account")
    change.contentOperation = .savePlan; change.basePlan = ""
    #expect(!change.valid)
    var request = CompanionLibrary.Change(action: .editDraft, itemID: "post", revision: "revision", text: "# Plan", requestsWritingHelp: true)
    request.contentOperation = .savePlan; request.basePlan = ""
    #expect(!request.valid)
}

@Test @MainActor func longFormPlansAndHistoryTravelTogether() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    for kind in ["script", "article"] {
        var record = WorkspaceRecord.new(kind, projectID: mac.projectID)
        record["title"] = "Writing"; record["body"] = "Original full text"
        record = try mac.save(record)
        record = try mac.savePlan(itemID: record.id, markdown: "# Outline", base: "")
        var library = mac.makeCompanionLibrary(workspaceID: UUID())
        let separated = try library.separateFullText()
        let text = try #require(separated)
        try library.applyFullText(text)
        let item = try #require(((library.scripts ?? []) + (library.articles ?? [])).first { $0.id == record.id })
        #expect(item.body == "Original full text")
        #expect(item.planMarkdown == "# Outline")
        #expect(item.history?.isEmpty == false)
    }
}
