import Foundation
import Testing
@testable import Inkspring

@Test @MainActor func newsletterEditorSavesDraftsWithMissingDeliverySettings() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    let database = try #require(workspace.database)
    var legacy = WorkspaceRecord.new("newsletter", projectID: workspace.projectID)
    legacy["title"] = "A saved newsletter"
    legacy["body"] = "We has a plan."
    legacy.fields["revision"] = 4
    legacy.fields["audience"] = nil
    legacy.fields["sendEmail"] = nil
    legacy = try database.put(legacy)

    var edited = legacy
    edited["body"] = "We have a plan."
    let saved = try workspace.saveNewsletterEditor(edited, basedOn: legacy)
    #expect(saved.body == "We have a plan.")
    #expect(saved["audience"] == "everyone")
    #expect(saved.fields["sendEmail"] as? Bool == false)
    #expect(saved.fields["revision"] as? Int == 5)
    #expect(saved["state"] == "draft")

    var invalid = saved
    invalid["subtitle"] = String(repeating: "a", count: 1_001)
    do {
        _ = try workspace.saveNewsletterEditor(invalid, basedOn: saved)
        Issue.record("An overlong subtitle should not save.")
    } catch {
        #expect(error.localizedDescription == "Shorten the subtitle to 1,000 characters or less.")
    }
    #expect(try database.records().first { $0.id == saved.id }?.fields["revision"] as? Int == 5)
}

@Test @MainActor func newsletterMarkdownMatchesElectronFingerprint() throws {
    let markdown = """
    ## Heading

    > Bold **word**

    3. First
    4. Second

    ```swift
    let item = 1
    ```

    ~~struck~~ and [link](https://example.com/)

    ![alt](https://example.com/image.png)
    """
    let document = try NewsletterDocument.parse(markdown)
    let post: [String: Any] = [
        "draft_title": "Test", "draft_subtitle": "", "draft_body": try NewsletterDocument.canonical(document),
        "audience": "everyone", "should_send_email": false, "cover_image": NSNull(), "draft_section_id": NSNull()
    ]
    #expect(try Substack.fingerprint(post) == "5d01928146decb1dc5a4bd8ec93229451ba800a4c3f0f4f29c5d471ab6fc2b63")
    let unsafe = try NewsletterDocument.parse("<script>alert(1)</script>")
    let html = NewsletterDocument.html(unsafe, title: "Test & compare", subtitle: "")
    #expect(html.contains("Test &amp; compare"))
    #expect(!html.contains("<script>"))
}

@Test @MainActor func substackChecksRemoteDraftAndConfirmsScheduleCancellationAndPublication() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let when = now.addingTimeInterval(7200)
    var requests: [String] = []
    var remote: [String: Any] = [:]
    let service = Substack(workspace: workspace, now: { now }) { method, url, payload in
        requests.append(method + " " + url.path)
        if url.host() == "substack.com" {
            #expect(method == "GET")
            return ["id": 18, "name": "Fixture author", "publicationUsers": [
                ["role": "owner", "publication": ["id": 95, "name": "Fixture newsletter", "subdomain": "fixture"]]
            ]]
        }
        #expect(url.host() == "fixture.substack.com")
        switch (method, url.path) {
        case ("POST", "/api/v1/drafts"), ("PUT", "/api/v1/drafts/73"):
            remote = try #require(payload)
            remote["id"] = 73
            remote["is_published"] = false
            return ["id": 73]
        case ("GET", "/api/v1/drafts/73"):
            return remote
        case ("GET", "/api/v1/drafts/73/prepublish"):
            return ["errors": [String]()]
        case ("POST", "/api/v1/drafts/73/scheduled_release"):
            #expect(payload?["email_audience"] as? String == "everyone")
            remote["trigger_at"] = payload?["trigger_at"]
            return [:]
        case ("DELETE", "/api/v1/drafts/73/scheduled_release"):
            remote["trigger_at"] = nil
            return [:]
        case ("POST", "/api/v1/drafts/73/publish"):
            #expect(payload?["send"] as? Bool == false)
            remote["is_published"] = true
            remote["post_date"] = workspaceTimestamp(now)
            remote["slug"] = "swift-fixture"
            return [:]
        default:
            Issue.record("Unexpected Substack request.")
            throw WorkspaceError("Unexpected request.")
        }
    }
    try await service.connect()
    #expect(service.selected == nil)
    try service.select("95")
    var item = WorkspaceRecord.new("newsletter", projectID: workspace.projectID)
    item["title"] = "Swift fixture"
    item["body"] = "A draft in **Markdown**."
    item = try workspace.save(item)
    item = try await service.sync(item.id)
    #expect(item["state"] == "synced")
    #expect(item.fields["syncedRevision"] as? Int == 1)

    let firstReview = try await service.prepare(item.id, at: when)
    remote["draft_title"] = "Edited externally"
    await #expect(throws: WorkspaceError.self) { _ = try await service.commit(firstReview) }
    #expect(!requests.contains("POST /api/v1/drafts/73/scheduled_release"))
    remote["draft_title"] = item.title

    let scheduleReview = try await service.prepare(item.id, at: when)
    item = try await service.commit(scheduleReview)
    #expect(item["state"] == "scheduled")
    #expect(item["scheduledAt"] == workspaceTimestamp(when))
    await #expect(throws: WorkspaceError.self) { _ = try await service.commit(scheduleReview) }
    item = try await service.cancel(item.id)
    #expect(item["state"] == "synced")
    #expect(item["scheduledAt"].isEmpty)

    let publishReview = try await service.prepare(item.id, at: nil)
    item = try await service.commit(publishReview)
    #expect(item["state"] == "published")
    #expect(item["postUrl"] == "https://fixture.substack.com/p/swift-fixture")
    await #expect(throws: WorkspaceError.self) { _ = try await service.commit(publishReview) }
    #expect(requests.filter { $0 == "POST /api/v1/drafts/73/publish" }.count == 1)

    let requestsBeforeCopy = requests
    let copy = NewsletterDocument.localCopy(of: item)
    #expect(copy.id != item.id)
    #expect(copy.title == item.title + " (copy)")
    #expect(copy.body == item.body)
    #expect(copy["audience"] == item["audience"])
    #expect(Substack.emails(copy) == Substack.emails(item))
    #expect(workspace.records.first { $0.id == copy.id } == nil)
    let savedCopy = try workspace.save(copy)
    #expect(savedCopy["state"] == "draft")
    #expect(savedCopy.fields["revision"] as? Int == 1)
    for key in ["remoteId", "remoteFingerprint", "postUrl", "scheduledAt", "syncedRevision"] {
        #expect(savedCopy.fields[key] == nil)
    }
    #expect(workspace.records.first { $0.id == item.id }?["state"] == "published")
    #expect(requests == requestsBeforeCopy)

    var longTitle = item
    longTitle["title"] = String(repeating: "🪶", count: 150)
    let shortened = NewsletterDocument.localCopy(of: longTitle)
    #expect(shortened.title.utf16.count <= 300)
    #expect(shortened.title.hasSuffix(" (copy)"))
}

@Test func r2SignaturesMatchElectronImplementation() throws {
    let profile = R2Profile(configuration: R2Configuration(accountId: String(repeating: "a", count: 32),
                                                           bucket: "media-fixture", jurisdiction: "eu"),
                            accessKeyId: "TESTKEY123", secretAccessKey: "SYNTHETICONLY")
    let signer = R2Signer(profile: profile)
    let date = try Date("2026-01-02T03:04:05Z", strategy: .iso8601)
    let key = "inkspring-instagram/media/example.jpg"
    let request = try signer.signedRequest(method: "PUT", key: key, hash: R2Signer.sha(Data("Example media".utf8)), now: date)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=aed37dbf5ff83847587eb5547170e5c738938ce7b2d528ace1f18c7bde3b027e") == true)
    let url = try signer.link(key, now: date)
    #expect(url.absoluteString.hasSuffix("X-Amz-Signature=6b1b17150260e27772a3a13a71d01919bb10de0c646b50a35b949c65f23be4f0"))
    #expect(throws: WorkspaceError.self) { try signer.link("inkspring-instagram/../other", now: date) }
}

@Test @MainActor func newsletterGenerationUsesSelectedSourcesAndRejectsConcurrentEdits() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let projectID = workspace.projectID
    let selected = try workspace.saveResearchReference(["title": "Selected evidence", "text": "A useful source."], projectID: projectID)
    _ = try workspace.saveResearchReference(["title": "Unselected evidence", "text": "Keep this local."], projectID: projectID)
    var draft = WorkspaceRecord.new("newsletter", projectID: projectID)
    draft["body"] = "Existing editor text."
    let draftID = draft.id
    var requestCount = 0
    let model = ContentStudio.Model(provider: "fixture", name: "fixture", draft: { _, _ in [:] }, object: { _, input in
        requestCount += 1
        let sources = try #require(input["sources"] as? [[String: String]])
        #expect(sources.compactMap { $0["title"] } == ["Selected evidence"])
        let draft = try #require(input["currentDraft"] as? [String: String])
        #expect(draft["body"] == "Existing editor text." || draft["body"] == "A fresh **newsletter**.")
        if requestCount == 2, var editing = workspace.records.first(where: { $0.id == draftID }) {
            editing["body"] = "An edit from another window."
            try workspace.save(editing)
        }
        return ["title": "Fixture newsletter", "subtitle": "A test issue", "body": "A fresh **newsletter**."]
    }, prompt: { _ in "" }, image: { _ in (Data(), "") }, imageProvider: "Fixture")
    let studio = ContentStudio(workspace: workspace, model: model)
    let generated = try await studio.writeNewsletter(draft, brief: "Write a draft.", sourceIDs: [selected.id])
    #expect(generated["state"] == "draft")
    #expect(generated.fields["sendEmail"] as? Bool == false)
    #expect(generated.fields["revision"] as? Int == 1)
    #expect(workspace.records.first { $0.id == draft.id }?["body"] == "A fresh **newsletter**.")

    await #expect(throws: WorkspaceError.self) {
        _ = try await studio.writeNewsletter(generated, brief: "Revise the draft.", sourceIDs: [selected.id])
    }
    #expect(workspace.records.first { $0.id == draft.id }?["body"] == "An edit from another window.")
    await #expect(throws: WorkspaceError.self) {
        _ = try await studio.writeNewsletter(generated, brief: "Retry with the old version.", sourceIDs: [selected.id])
    }
    #expect(requestCount == 2)
}

@Test @MainActor func newsletterMarkdownImportKeepsCodeIndentation() {
    let draft = NewsletterDocument.importMarkdown("\u{feff}# Title\r\n\r\n    let item = 1\r\n", filename: "Fixture")
    #expect(draft.title == "Title")
    #expect(draft.body == "    let item = 1\n")
    let noHeading = NewsletterDocument.importMarkdown("## Section\nBody", filename: "Fixture")
    #expect(noHeading.title == "Fixture")
    #expect(noHeading.body == "## Section\nBody")
}
