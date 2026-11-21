import AppKit
import Foundation
import InkspringSchedule
import UniformTypeIdentifiers

@MainActor @Observable
final class Workspace {
    private(set) var records: [WorkspaceRecord] = []
    private(set) var trashedRecords: [WorkspaceRecord] = []
    private(set) var settings: [String: Any] = [:]
    private(set) var directory: URL?
    private(set) var startupError: String?
    let socialAccounts = ManagedSocialAccounts()
    @ObservationIgnored lazy var substackSession = SubstackSession()
    @ObservationIgnored var substackReviews: [String: UUID] = [:]
    var substackBusy = false
    var companionBusy = false
    var companionLastSync: Date?
    var companionError: String?
    var companionTransfer: CompanionTransfer?
    var companionLibraryBusy = false
    var companionLibraryTextCleanupPending = false
    var companionLibraryError: String?
    var projectID = ""
    var error: String?
    var notice: String?
    var postResultNotice: PostResultNotice?
    var scheduleReminderDraftID: String?
    var backupRegistrationError: String?
    var importingWorkspaceFolder = false
    var restoringBackup = false
    var runningDuePosts = false
    var runningDraftRevisions = false
    var runningMobileXGeneration = false
    var refreshingReplies = false
    var refreshingAnalytics: Set<SocialPlatform> = []
    private var lastIdeaQueueAttempt: [String: Date] = [:]
    var refreshingWorkSources = false
    private(set) var verifiedAgentConnection: AgentConnectionCheck.Result?
    private(set) var database: WorkspaceDatabase?
    private var lastDataVersion: Int32?

    init(directory override: URL? = nil) {
        do {
            let directory = try override ?? DailyBackup.directory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
            self.directory = directory
            self.database = database
            try seed(database)
            try reload()
            projectID = (settings["selectedProjectID"] as? String).flatMap { id in
                projects.first { $0.id == id }?.id
            } ?? projects.first?.id ?? ""
        } catch {
            startupError = error.localizedDescription
        }
    }

    var projects: [WorkspaceRecord] { records.filter { $0.kind == "project" } }
    var project: WorkspaceRecord? { projects.first { $0.id == projectID } }
    var drafts: [WorkspaceRecord] { items("draft") }
    var workspaceDrafts: [WorkspaceRecord] {
        records.filter { $0.projectID == projectID && ($0.kind == "draft" || $0.isLongForm) && !$0.isPublishedContent }
    }
    var ideas: [WorkspaceRecord] { items("idea") }
    var sources: [WorkspaceRecord] { items("source") }
    var agentAccessEnabled: Bool { settings["mcpEnabled"] as? Bool == true }
    var agentConnected: Bool {
        agentAccessEnabled && verifiedAgentConnection != nil && StudioChatAgent.selected.executable != nil
    }
    var writingToolsAvailable: Bool { StudioWritingConnection(settings: settings) == .api || agentConnected }

    func verifyAgentConnection() async throws -> AgentConnectionCheck.Result {
        guard agentAccessEnabled, let directory else {
            throw WorkspaceError("Turn on agent access before testing the connection.")
        }
        let command = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let path = directory.path
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try AgentConnectionCheck.run(command: command, workspaceOverride: path)
            }.value
            try Task.checkCancellation()
            guard agentAccessEnabled else { throw CancellationError() }
            verifiedAgentConnection = result
            return result
        } catch {
            if !Task.isCancelled { verifiedAgentConnection = nil }
            throw error
        }
    }

    func items(_ kind: String) -> [WorkspaceRecord] {
        records.filter { $0.kind == kind && $0.projectID == projectID }
    }

    func selectProject(_ id: String) {
        projectID = id
        perform { try set("selectedProjectID", to: id) }
    }

    func showPostResult(_ result: WorkspaceRecord) {
        guard let result = PostResultNotice(result) else { return }
        notice = nil
        postResultNotice = result
    }

    func reload() throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        let version = try database.dataVersion()
        let records = try database.records().compactMap { stored -> WorkspaceRecord? in
            // Keep retired writing in the database and full backups.
            guard stored.kind != "article" || stored["platform"] != "linkedin" else { return nil }
            guard stored.kind == "draft", !stored["linkedinArticleID"].isEmpty else { return stored }
            var post = stored
            post.fields["linkedinArticleID"] = nil
            if ["queued", "due"].contains(post.scheduleStatus) {
                var schedule = post.schedule
                schedule["status"] = "ready"
                schedule["slotAt"] = ""
                post.fields["schedule"] = schedule
            }
            return post
        }
        let settings = try database.settings()
        func inTrash(_ record: WorkspaceRecord) -> Bool {
            !record["trashedAt"].isEmpty || record.kind == "idea" && record["status"] == "skipped"
        }
        self.records = records.filter { !inTrash($0) }
        trashedRecords = records.filter(inTrash)
        self.settings = settings
        if !agentAccessEnabled { verifiedAgentConnection = nil }
        lastDataVersion = version
    }

    func refreshAfterExternalWrite() {
        guard let database, let version = try? database.dataVersion(), version != lastDataVersion else { return }
        perform { try reload() }
    }

    func set(_ key: String, to value: Any) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try database.set(key, to: value)
        settings[key] = value
        if !agentAccessEnabled { verifiedAgentConnection = nil }
    }

    @discardableResult
    func save(_ original: WorkspaceRecord) throws -> WorkspaceRecord {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try database.transaction {
            try reload()
            return try saveCurrent(original, to: database)
        }
    }

    private func saveCurrent(_ original: WorkspaceRecord, to database: WorkspaceDatabase,
                             scheduling: Bool = false) throws -> WorkspaceRecord {
        var record = original
        guard !trashedRecords.contains(where: { $0.id == record.id }) else {
            throw WorkspaceError("This item is in Trash. Restore it before editing.")
        }
        guard !(settings["libraryDeletedIDs"] as? [String] ?? []).contains(record.id) else {
            throw WorkspaceError("This item was permanently deleted. Create a new draft or idea instead.")
        }
        if record.kind == "draft" {
            record["title"] = record.draftTitle
            record.fields["linkedinArticleID"] = nil
            if record["platform"] != "x" { record.fields["xArticleID"] = nil }
        }
        if ["script", "article"].contains(record.kind) {
            if record.kind == "script" { record["platform"] = "youtube" }
            if record.kind == "article" {
                guard record["platform"] == "x" || record["platform"].isEmpty else {
                    throw WorkspaceError("Choose X for an article draft.")
                }
                record["platform"] = "x"
            }
            record["state"] = "draft"
            for key in ["schedule", "remoteId", "publication", "editUrl", "sendEmail", "audience"] { record.fields[key] = nil }
        }
        if record.kind == "newsletter" {
            if record.fields["audience"] == nil || record.fields["audience"] as? String == "" { record["audience"] = "everyone" }
            if record.fields["sendEmail"] == nil { record.fields["sendEmail"] = false }
        }
        if let plan = record.fields["planMarkdown"] as? String { try ContentPlan.validate(plan) }
        try validate(record)
        let current = records.first { $0.id == record.id }
        if current?.fields["mobileGenerationPending"] as? Bool == true, record.body != current?.body {
            record.fields["mobileGenerationPending"] = nil
            record.fields["generationError"] = nil
        }
        if record.kind == "draft", record.fields["image"] != nil, record.fields["video"] != nil {
            guard let current, !scheduling,
                  ["image", "video"].allSatisfy({ (record.fields[$0] as? NSDictionary) == (current.fields[$0] as? NSDictionary) }) else {
                throw WorkspaceError("Choose one attachment to keep in Writing Studio before saving.")
            }
        }
        if let current, !record.isLongForm {
            guard current["updatedAt"] == record["updatedAt"] else {
                throw WorkspaceError("This item changed in another window or agent. Reopen the latest version before saving.")
            }
            if ["draft", "idea"].contains(record.kind) {
                record.fields["reviewComments"] = current.fields["reviewComments"]
            }
        }
        if record.isLongForm {
            if let current, !["draft", "synced"].contains(current["state"]) {
                throw WorkspaceError("Check this newsletter in Substack before editing.")
            }
            if let current {
                record.fields["reviewComments"] = current.fields["reviewComments"]
                let applied = current.appliedRevisionCommentIDs + record.appliedRevisionCommentIDs
                record.fields["appliedRevisionCommentIDs"] = Array(NSOrderedSet(array: applied))
            }
            let revision = record.fields["revision"] as? Int ?? 0
            guard revision == (current?.fields["revision"] as? Int ?? 0) else {
                throw WorkspaceError("Reopen the latest version of this newsletter before saving.")
            }
            if let current {
                guard current["updatedAt"] == record["updatedAt"] else {
                    throw WorkspaceError("Reopen the latest version of this newsletter before saving.")
                }
                for key in record.kind == "newsletter" ? ["remoteId", "publication", "editUrl", "syncedRevision", "remoteFingerprint", "embeddedCoverURL", "error"] : [] {
                    record.fields[key] = current.fields[key]
                }
            }
            record.fields["state"] = current?["state"] ?? "draft"
            record.fields["revision"] = revision + 1
        }
        if let current, record.kind == "draft" {
            guard !["posting", "posted"].contains(current.scheduleStatus) else {
                throw WorkspaceError("This post is already publishing or published. Create a new draft to revise it.")
            }
            let keys = ["title", "content", "format", "platform", "xArticleID", "tiktokCoverTime"]
            let oldContent = keys.map { current[$0] }
            let newContent = keys.map { record[$0] }
            let oldMedia = ["image", "video", "videoThumbnail", "linkedinDestination"].map { current.fields[$0] as? NSDictionary }
            let newMedia = ["image", "video", "videoThumbnail", "linkedinDestination"].map { record.fields[$0] as? NSDictionary }
            if !scheduling, ["queued", "due"].contains(current.scheduleStatus),
               oldContent != newContent || oldMedia != newMedia {
                record.fields["schedule"] = ["status": "ready", "slotAt": "",
                                             "error": "This post changed. Review it and choose a new posting time."]
            }
        }
        record.markUpdated(after: current?["updatedAt"])
        record = try database.put(record)
        try reload()
        return record
    }

    func withChanges<T>(_ changes: () throws -> T) throws -> T {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        do {
            return try database.transaction {
                try reload()
                return try changes()
            }
        } catch {
            try? reload()
            throw error
        }
    }

    func revisionHistory(for record: WorkspaceRecord) throws -> [ContentRevision] {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try database.revisionHistory(recordID: record.id)
    }

    func retainRevision(_ revision: ContentRevision, recordID: String) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try database.storeRevision(revision, recordID: recordID)
    }

    func restoreRevision(_ revision: ContentRevision, to expected: WorkspaceRecord) throws -> WorkspaceRecord {
        try withChanges {
            guard var current = records.first(where: { $0.id == expected.id && $0.kind == expected.kind }),
                  current["updatedAt"] == expected["updatedAt"],
                  ["draft", "newsletter", "script", "article"].contains(current.kind),
                  !["posting", "posted", "uncertain"].contains(current.scheduleStatus),
                  current.kind != "newsletter" || ["draft", "synced"].contains(current["state"]) else {
                throw WorkspaceError("This item changed. Reopen the latest version before restoring.")
            }
            current["title"] = revision.title
            current[current.isLongForm ? "body" : "content"] = revision.text
            if let format = revision.format { current["format"] = format }
            if let subtitle = revision.subtitle { current["subtitle"] = subtitle }
            return try save(current)
        }
    }

    func updateFromAgent<T>(_ changes: () throws -> T) throws -> T {
        try withChanges {
            guard settings["mcpEnabled"] as? Bool == true else {
                throw WorkspaceError("Turn on agent access in Inkspring Settings.")
            }
            return try changes()
        }
    }

    func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }

    func mediaURL(_ record: WorkspaceRecord) -> URL? {
        if record.kind == "draft", record["format"] == "video" { return videoURL(record) }
        return imageURL(record) ?? videoURL(record)
    }

    func imageURL(_ record: WorkspaceRecord) -> URL? {
        storedImageURL(record.fields["image"] ?? record.fields["coverImage"])
    }

    func videoThumbnailURL(_ record: WorkspaceRecord) -> URL? {
        guard record.fields["video"] is [String: Any] else { return nil }
        return storedImageURL(record.fields["videoThumbnail"])
    }

    private func storedImageURL(_ value: Any?) -> URL? {
        if let image = value as? [String: Any],
           let file = image["file"] as? String,
           file.range(of: #"^[a-f0-9-]{36}\.(png|jpe?g|webp)$"#, options: .regularExpression) != nil {
            return directory?.appending(path: "images").appending(path: file)
        }
        return nil
    }

    func videoURL(_ record: WorkspaceRecord) -> URL? {
        if let video = record.fields["video"] as? [String: Any], let id = video["id"] as? String,
           let path = records.first(where: { $0.kind == "local-video" && $0.id == id })?["path"],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func attachImage(_ source: URL) throws -> [String: String] {
        let attributes = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              (1...30_000_000).contains(attributes.fileSize ?? 0),
              let image = NSImage(contentsOf: source), image.isValid, let directory else {
            throw WorkspaceError("Choose a valid local image of up to 30 MB.")
        }
        let fileExtension = source.pathExtension.lowercased()
        guard ["png", "jpeg", "jpg", "webp"].contains(fileExtension) else {
            throw WorkspaceError("Choose a PNG, JPEG or WebP image.")
        }
        let images = directory.appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let name = UUID().uuidString.lowercased() + "." + fileExtension
        try FileManager.default.copyItem(at: source, to: images.appending(path: name))
        return ["file": name, "origin": "Attached"]
    }

    func addComment(to record: WorkspaceRecord, text: String, revisionRequestID: String? = nil) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            guard var current = records.first(where: { $0.id == record.id && $0.kind == record.kind }) else {
                throw WorkspaceError("This item is no longer available.")
            }
            if let revisionRequestID,
               current.comments.contains(where: { $0["revisionRequestID"] as? String == revisionRequestID }) { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf16.count <= 4000, current.comments.count < 100 else {
                throw WorkspaceError("Enter a comment of up to 4,000 characters. Each item can hold 100 comments.")
            }
            var comment = ["text": text, "at": WorkspaceRecord.timestamp]
            if ["draft", "idea"].contains(current.kind) || current.isLongForm { comment["revisionRequestID"] = revisionRequestID }
            current.fields["writingRequestError"] = nil
            current.fields["reviewComments"] = current.comments + [comment]
            try database.put(current)
            try reload()
        }
    }

    func trashLibraryItem(_ input: WorkspaceRecord) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        let lease = try claimPublication()
        defer { withExtendedLifetime(lease) {} }
        try withChanges {
            guard var record = records.first(where: { $0.id == input.id && $0.kind == input.kind }),
                  record["updatedAt"] == input["updatedAt"], ["draft", "idea"].contains(record.kind) else {
                throw WorkspaceError("This item changed. Refresh it before deleting.")
            }
            guard !["posting", "posted", "uncertain"].contains(record.scheduleStatus),
                  !records.contains(where: { ["publication", "reply-inbox"].contains($0.kind) && $0["draftId"] == record.id }) else {
                throw WorkspaceError("This post has publishing history and cannot be deleted here.")
            }
            record["trashedAt"] = WorkspaceRecord.timestamp
            if record.kind == "idea", record["status"] == "draft" {
                record["status"] = "skipped"
                record["skippedAt"] = WorkspaceRecord.timestamp
            }
            if record.kind == "draft" { record.fields["schedule"] = [:] as [String: Any] }
            record.markUpdated()
            try database.put(record)
            try reload()
        }
    }

    func restoreLibraryItem(_ input: WorkspaceRecord) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            guard var record = trashedRecords.first(where: { $0.id == input.id && $0.kind == input.kind }),
                  record["updatedAt"] == input["updatedAt"] else {
                throw WorkspaceError("This item changed. Refresh Trash and try again.")
            }
            record["trashedAt"] = ""
            if record.kind == "idea", record["status"] == "skipped" { record["status"] = "draft"; record["skippedAt"] = "" }
            record.markUpdated()
            try database.put(record)
            try reload()
        }
    }

    func deleteLibraryItem(_ input: WorkspaceRecord) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            guard let record = trashedRecords.first(where: { $0.id == input.id && $0.kind == input.kind }),
                  record["updatedAt"] == input["updatedAt"] else {
                throw WorkspaceError("Only items already in Trash can be permanently deleted.")
            }
            // Keep linked drafts and media; permanent deletion removes only the item and its links.
            for var draft in records + trashedRecords where record.kind == "idea" && draft.kind == "draft" && draft["ideaId"] == record.id {
                draft["ideaId"] = ""
                draft.markUpdated()
                try database.put(draft)
            }
            for var idea in records + trashedRecords where record.kind == "draft" && idea.kind == "idea" {
                let versions = idea.fields["versions"] as? [String: String] ?? [:]
                guard versions.values.contains(record.id) else { continue }
                let remaining = versions.filter { $0.value != record.id }
                idea.fields["versions"] = remaining
                idea.fields["platforms"] = remaining.keys.sorted()
                if remaining.isEmpty { idea["status"] = "draft"; idea["pickedAt"] = "" }
                idea.markUpdated()
                try database.put(idea)
            }
            for consent in records where consent.kind == "tiktok-consent" && consent["draftId"] == record.id {
                try database.remove(consent.id, kind: consent.kind)
            }
            try database.remove(record.id, kind: record.kind)
            var deletedIDs = settings["libraryDeletedIDs"] as? [String] ?? []
            if !deletedIDs.contains(record.id) { deletedIDs.append(record.id) }
            try database.set("libraryDeletedIDs", to: deletedIDs)
            try reload()
        }
    }

    func updatePostText(_ input: WorkspaceRecord, title: String, text: String, format: String? = nil,
                        xArticleID: String? = nil) throws {
        try withChanges {
            guard var record = records.first(where: { $0.kind == input.kind && $0.id == input.id }),
                  record["updatedAt"] == input["updatedAt"] else {
                throw WorkspaceError("This item changed. Reopen the latest version before editing.")
            }
            switch record.kind {
            case "idea":
                let angle = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard record["status"] == "draft", (1...2000).contains(angle.utf16.count) else {
                    throw WorkspaceError("Enter up to 2,000 characters for an open idea.")
                }
                record["topic"] = title.trimmingCharacters(in: .whitespacesAndNewlines)
                record["previousText"] = record.body
                record["text"] = angle
                record["revisedAt"] = WorkspaceRecord.timestamp
                record["notesReply"] = ""
            case "draft":
                record["title"] = title.trimmingCharacters(in: .whitespacesAndNewlines)
                record["content"] = text
                if let format, record["platform"] == "x", XPostStyle(rawValue: format) != nil {
                    record["format"] = format
                }
                if let xArticleID, record["platform"] == "x" {
                    record["xArticleID"] = xArticleID
                }
            default:
                throw WorkspaceError("Choose an idea or post to edit.")
            }
            try save(record)
        }
    }

    private func validate(_ record: WorkspaceRecord) throws {
        let title = switch record.kind {
        case "project": record["name"]
        case "local-video": record["name"]
        case "idea": record["topic"]
        default: record["title"]
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError("Enter a title before saving.")
        }
        if !["project", "local-video"].contains(record.kind), !projects.contains(where: { $0.id == record.projectID }) {
            throw WorkspaceError("Choose an existing project.")
        }
        if record.kind == "source", !record["url"].isEmpty {
            guard let components = URLComponents(string: record["url"]), components.scheme == "https",
                  components.host != nil, components.user == nil, components.password == nil else {
                throw WorkspaceError("Enter an HTTPS source link.")
            }
        }
        if record.kind == "draft" {
            guard record["title"].utf16.count <= 200, record["content"].utf16.count <= 40_000 else {
                throw WorkspaceError("Use up to 200 characters for the title and 40,000 for the draft.")
            }
            if !record["xArticleID"].isEmpty,
               records.first(where: { $0.id == record.id })?["xArticleID"] != record["xArticleID"] {
                guard record["platform"] == "x",
                      records.contains(where: {
                          $0.isXArticle && $0.projectID == record.projectID && $0.id == record["xArticleID"]
                      }) else {
                    throw WorkspaceError("Choose an X article from this project.")
                }
            }
            if record["format"] == "reply" {
                let reply = record.fields["replyTo"] as? [String: String]
                guard record["platform"] == "x", !(reply?["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkspaceError("Enter the X post you are replying to.")
                }
                let url = reply?["url"] ?? ""
                guard url.isEmpty || url.range(of: #"^https://(?:www\.|mobile\.)?(?:x|twitter)\.com/(?:[A-Za-z0-9_]{1,15}|i(?:/web)?)/status(?:es)?/[0-9]{1,25}(?:[/?#]|$)"#,
                                                options: .regularExpression) != nil else {
                    throw WorkspaceError("Enter a valid X post link.")
                }
            }
        }
        if record.isLongForm {
            guard record["title"].utf16.count <= 300 else {
                throw WorkspaceError("Shorten the title to 300 characters or less.")
            }
            guard record["subtitle"].utf16.count <= 1_000 else {
                throw WorkspaceError("Shorten the subtitle to 1,000 characters or less.")
            }
            guard record["body"].utf16.count <= 200_000 else {
                throw WorkspaceError("Shorten the newsletter to 200,000 characters or less.")
            }
            guard !record["body"].contains("\0") else {
                throw WorkspaceError("Remove the invalid control character from the newsletter text.")
            }
            if ["script", "article"].contains(record.kind) { return }
            guard ["everyone", "only_paid", "founding"].contains(record["audience"]) else {
                throw WorkspaceError("Choose an audience in Newsletter settings.")
            }
            guard record.fields["sendEmail"] is Bool else {
                throw WorkspaceError("Check the Email subscribers setting in Newsletter settings.")
            }
        }
        if record.kind == "idea", record["text"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkspaceError("Enter the idea before saving.")
        }
    }

    private func seed(_ database: WorkspaceDatabase) throws {
        guard try database.settings()["initialized"] == nil, try database.records().isEmpty else { return }
        var project = WorkspaceRecord.new("project")
        project["name"] = "The independent studio"
        project["description"] = "A one-person lab making useful, private desktop software. Small tools that give people room to do their own work."
        project["audience"] = "Independent makers, curious people, and founders who care about owning their tools."
        project["voice"] = "Plainspoken, specific, a little opinionated. First person singular. No marketing jargon."
        project.fields["sample"] = true
        var draft = WorkspaceRecord.new("draft", projectID: project.id)
        draft["title"] = "Tools you can keep"
        draft["content"] = "I like software that leaves me with a folder I can open.\n\nNotes, drafts, projects. Still there when the Wi-Fi drops. Still mine if the company disappears.\n\nThat feels like a reasonable starting point for a tool."
        draft.fields["sample"] = true
        var source = WorkspaceRecord.new("source", projectID: project.id)
        source["title"] = "Show the unfinished thing"
        source["text"] = "Sample research note: a small detail from the making of a tool can be more interesting than a polished launch announcement. Show a real decision, the constraint, and what changed."
        source["origin"] = "Sample note"
        source.fields["sample"] = true
        try database.transaction {
            try database.put(project)
            try database.put(draft)
            try database.put(source)
            try database.set("initialized", to: true)
        }
    }
}

extension Workspace {
    func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Inkspring-backup-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try exportBackup(to: url)
            notice = "Backup ZIP saved"
        }
    }

    func exportBackup(to url: URL) throws {
        guard let database, let directory else { throw WorkspaceError("The workspace is unavailable.") }
        let snapshot = try database.snapshot()
        try WorkspaceBackup.export(records: snapshot.records, preferences: snapshot.settings, directory: directory, to: url)
    }

    func restoreBackup() async {
        guard !restoringBackup, !importingWorkspaceFolder else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoringBackup = true
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            restoringBackup = false
        }
        do {
            try await ICloudBackup.downloadIfNeeded(url)
            try reviewRestore(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func importWorkspaceFolder() async {
        guard let directory, !importingWorkspaceFolder, !restoringBackup else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Inkspring workspace folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            panel.directoryURL = support
        }
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importingWorkspaceFolder = true
        defer { importingWorkspaceFolder = false }
        do {
            let archive = try await Task.detached(priority: .utility) {
                try WorkspaceMigration.prepareImport(from: source, into: directory)
            }.value
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            try reviewRestore(archive, importingFolder: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reviewRestore(_ url: URL, importingFolder: Bool = false) throws {
        guard let directory else { throw WorkspaceError("The workspace is unavailable.") }
        let (backup, files) = try WorkspaceBackup.stage(url, in: directory)
        defer {
            if let staging = backup.stagingDirectory { try? FileManager.default.removeItem(at: staging) }
        }
        try reload()
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        let plan = try backup.restorePlan(over: database.records())
        let added = backup.records.count - plan.preservedIDs.count - plan.replacements.count
        let alert = NSAlert()
        alert.messageText = importingFolder ? "Import this workspace?" : "Restore this backup?"
        alert.informativeText = "Add \(added) records and restore \(backup.media.count) media files. Replace \(plan.replacements.count) matching records. Restored posts will need a new schedule."
        if !plan.preservedIDs.isEmpty {
            alert.informativeText += "\n\nKeep \(plan.preservedIDs.count) matching records with publishing history or Substack links."
        }
        if importingFolder {
            alert.informativeText += "\n\nThe source workspace stays unchanged. Reconnect social accounts in this app after importing."
        } else if backup.isLegacy {
            alert.informativeText += "\n\nOlder JSON backups contain text only. Reattach media after restoring."
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: importingFolder ? "Import workspace" : "Restore backup")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        try apply(backup, files: files, reviewedPlan: plan)
        notice = importingFolder ? "Workspace imported" : "Workspace restored"
    }

    func apply(_ backup: WorkspaceBackup, files: [String: URL], reviewedPlan: WorkspaceBackup.RestorePlan? = nil) throws {
        guard let directory, let database else { throw WorkspaceError("The workspace is unavailable.") }
        let lease = try claimPublication()
        defer { withExtendedLifetime(lease) {} }
        let initialPlan = try backup.restorePlan(over: database.records())
        guard reviewedPlan == nil || reviewedPlan == initialPlan else {
            throw WorkspaceError("The workspace changed after review. Review the restore again.")
        }
        let manager = FileManager.default
        var created: [URL] = []
        var images: [String: String] = [:]
        var videos: [String: (WorkspaceBackup.Media, URL)] = [:]
        do {
            for item in backup.media {
                guard let input = files[item.entry], try fileDigest(input) == (item.sha256, item.size) else {
                    throw WorkspaceError("A staged backup file is missing or changed.")
                }
                let fileExtension = URL(fileURLWithPath: item.entry).pathExtension
                let imageID = UUID(uuidString: uuidText(from: item.sha256))!.uuidString.lowercased()
                let name = (item.kind == "image" ? imageID : item.sha256) + "." + fileExtension
                let folder = directory.appending(path: item.kind == "image" ? "images" : "videos", directoryHint: .isDirectory)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let target = folder.appending(path: name)
                if manager.fileExists(atPath: target.path) {
                    let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                          try fileDigest(target) == (item.sha256, item.size) else {
                        throw WorkspaceError("A restored file conflicts with an existing attachment.")
                    }
                } else {
                    let temporary = folder.appending(path: ".restore-\(UUID().uuidString)")
                    defer { try? manager.removeItem(at: temporary) }
                    try manager.copyItem(at: input, to: temporary)
                    try manager.linkItem(at: temporary, to: target)
                    created.append(target)
                }
                if let original = item.file { images[original] = name }
                if let id = item.id { videos[id] = (item, target) }
            }
            try database.transaction {
                let current = try database.records()
                let plan = try backup.restorePlan(over: current)
                guard reviewedPlan == nil || reviewedPlan == plan else {
                    throw WorkspaceError("The workspace changed after review. Review the restore again.")
                }
                let local = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
                let rows = backup.records.filter { $0.kind == "project" } + backup.records.filter { $0.kind != "project" }
                for input in rows where !plan.preservedIDs.contains(input.id) {
                    var row = backup.restored(input)
                    for key in ["image", "coverImage", "videoThumbnail"] {
                        if var image = row.fields[key] as? [String: Any],
                           let name = image["file"] as? String, let replacement = images[name] {
                            image["file"] = replacement
                            row.fields[key] = image
                        }
                    }
                    if row.kind == "local-video", let (item, target) = videos[row.id] {
                        row["path"] = target.path
                        row["hash"] = item.sha256
                        row.fields["size"] = item.size
                        row.fields["mtime"] = try target.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate.map { $0.timeIntervalSince1970 * 1000 }
                    }
                    if let previous = local[row.id] {
                        row.fields["updatedAt"] = previous.fields["updatedAt"]
                        if NSDictionary(dictionary: row.fields).isEqual(to: previous.fields) { continue }
                        row.markUpdated(after: previous["updatedAt"])
                    }
                    try database.put(row)
                }
                for (key, value) in backup.preferences { try database.set(key, to: value) }
                for key in ["autoPost", "ideaQueueAutomatic", "mcpEnabled", "mcpAllowPosting"] {
                    try database.set(key, to: false)
                }
                try database.set("replyMonitoringX", to: ["enabled": false])
                try database.set("analyticsAutomatic", to: [String: Bool]())
                if var schedules = try database.settings()["workSourceSchedules"] as? [String: [String: Any]] {
                    for key in schedules.keys { schedules[key]?["enabled"] = false }
                    try database.set("workSourceSchedules", to: schedules)
                }
                try database.set("backupRestoredAt", to: WorkspaceRecord.timestamp)
            }
        } catch {
            for file in created { try? manager.removeItem(at: file) }
            throw error
        }
        try reload()
        if let first = backup.records.last(where: { $0.kind == "project" }) { selectProject(first.id) }
    }

    private func uuidText(from digest: String) -> String {
        let hex = Array(digest.prefix(32))
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
    }
}

extension Workspace {
    func writeGeneratedImage(_ data: Data, fileExtension: String) throws -> String {
        guard let directory, ["png", "jpeg", "jpg", "webp"].contains(fileExtension) else {
            throw WorkspaceError("The generated image format is unsupported.")
        }
        let images = directory.appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = UUID().uuidString.lowercased() + "." + fileExtension
        try data.write(to: images.appending(path: file), options: .atomic)
        return file
    }
}

extension Workspace {
    func chooseDailyBackupFolder(startingAt: URL? = nil) {
        guard let database else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for daily Inkspring backups"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = startingAt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try DailyBackup.chooseFolder(url, database: database)
            try reload()
        }
        Task { await checkDailyBackup() }
    }

    func setDailyBackupEnabled(_ enabled: Bool) {
        perform {
            try set(DailyBackup.enabledKey, to: enabled)
            guard !DailyBackup.usesTestWorkspace else { return }
            let service = DailyBackup.service
            if enabled && [.notRegistered, .notFound].contains(service.status) {
                try service.register()
                try set(DailyBackup.registrationKey, to: DailyBackup.registrationVersion() ?? "")
            } else if !enabled && [.enabled, .requiresApproval].contains(service.status) {
                try service.unregister()
            }
            backupRegistrationError = nil
        }
        if enabled { Task { await checkDailyBackup() } }
    }

    func refreshDailyBackupRegistration() async {
        guard settings[DailyBackup.enabledKey] as? Bool == true, let directory else { return }
        do {
            if try await DailyBackup.refreshRegistration(in: directory) { try reload() }
            backupRegistrationError = nil
        } catch {
            backupRegistrationError = error.localizedDescription
        }
    }

    func checkDailyBackup(requested: Bool = false) async {
        guard requested || settings[DailyBackup.enabledKey] as? Bool == true, let directory else { return }
        let backup = Task.detached(priority: .utility) { try DailyBackup.run(in: directory, requested: requested) }
        do {
            if try await backup.value != nil, requested { notice = "Backup ZIP saved" }
        } catch {
            if requested { self.error = error.localizedDescription }
        }
        // The background helper may have updated these settings in another process.
        if let current = try? database?.settings() { settings = current }
    }
}

extension Workspace {
    func beginPublication(_ plan: SocialPublishPlan, automatic: Bool, fromAgent: Bool) throws -> WorkspaceRecord {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try database.transaction {
            try reload()
            guard let draft = records.first(where: { $0.id == plan.draftID && $0.kind == "draft" }),
                  draft["updatedAt"] == plan.revision, !["posting", "posted"].contains(draft.scheduleStatus) else {
                throw WorkspaceError("This draft changed or already went out. Review it again.")
            }
            if fromAgent, settings["mcpEnabled"] as? Bool != true || settings["mcpAllowPosting"] as? Bool != true {
                throw WorkspaceError("Immediate agent posting is off in Inkspring Settings.")
            }
            if automatic, settings["autoPost"] as? Bool != true || draft.scheduleStatus != "queued" {
                throw WorkspaceError("Automatic posting is paused or this post was unscheduled.")
            }
            let receipts = records.filter { $0.kind == "publication" && $0["draftId"] == draft.id }
            guard !receipts.contains(where: { ["publishing", "published", "uncertain"].contains($0["status"]) }) else {
                throw WorkspaceError("This post already went out or has an unresolved publishing attempt. Check the account before retrying.")
            }
            if let partial = receipts.first(where: { $0["status"] == "partial" }), partial["fingerprint"] != plan.fingerprint {
                throw WorkspaceError("Part of this thread already went out. Restore the reviewed text before resuming.")
            }
            var receipt = receipts.first { $0["fingerprint"] == plan.fingerprint && ["failed", "partial"].contains($0["status"]) }
                ?? .new("publication", projectID: draft.projectID)
            receipt["draftId"] = draft.id
            receipt["platform"] = plan.platform.rawValue
            receipt["title"] = plan.title
            receipt["accountId"] = plan.accountID
            receipt["accountName"] = plan.accountName
            receipt["fingerprint"] = plan.fingerprint
            if let destination = plan.linkedInDestination { receipt.fields["linkedinDestination"] = destination.fields }
            receipt["replyToId"] = plan.replyID ?? ""
            receipt["status"] = "publishing"
            receipt["error"] = ""
            if receipt.fields["steps"] == nil { receipt.fields["steps"] = [[String: Any]]() }
            try database.put(receipt)
            var locked = draft
            var schedule = locked.schedule
            if !automatic { schedule["slotAt"] = nil }
            schedule["status"] = "posting"
            locked.fields["schedule"] = schedule
            try database.put(locked)
            try reload()
            return receipt
        }
    }

    func saveNewsletterEditor(_ edited: WorkspaceRecord, basedOn base: WorkspaceRecord) throws -> WorkspaceRecord {
        try withChanges {
            guard var current = records.first(where: { $0.isLongForm && $0.kind == edited.kind && $0.id == edited.id }) else {
                guard (base.fields["revision"] as? Int ?? 0) == 0 else {
                    throw WorkspaceError("This newsletter is no longer available.")
                }
                return try save(edited)
            }
            guard let body = NewsletterMerge.merge(base: base.body, mac: edited.body, mobile: current.body) else {
                throw WorkspaceError("Both versions changed the same part of this newsletter. Your edits are still open here.")
            }
            current["body"] = body
            for key in ["title", "subtitle", "audience"] where base[key] != edited[key] {
                current[key] = edited[key]
            }
            for key in ["sendEmail", "coverImage"] {
                if (base.fields[key] as? NSObject) != (edited.fields[key] as? NSObject) {
                    current.fields[key] = edited.fields[key]
                }
            }
            return try save(current)
        }
    }

    func patchNewsletter(_ expected: WorkspaceRecord, _ changes: [String: Any]) throws -> WorkspaceRecord {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try withChanges {
            guard var item = records.first(where: { $0.kind == "newsletter" && $0.id == expected.id }),
                  item.fields["revision"] as? Int == expected.fields["revision"] as? Int,
                  item["updatedAt"] == expected["updatedAt"], item["state"] == expected["state"] else {
                throw WorkspaceError("The newsletter changed. Open the latest version and check Substack.")
            }
            item.fields.merge(changes) { _, replacement in replacement }
            item.markUpdated(after: expected["updatedAt"])
            try database.put(item)
            try reload()
            return item
        }
    }

    func recoverInterruptedNewsletters() {
        guard records.contains(where: { $0.kind == "newsletter" && ["syncing", "releasing"].contains($0["state"]) }),
              let lease = try? claimPublication() else { return }
        defer { withExtendedLifetime(lease) {} }
        perform {
            try reload()
            for item in records where item.kind == "newsletter" && ["syncing", "releasing"].contains(item["state"]) {
                _ = try patchNewsletter(item, [
                    "state": "uncertain",
                    "error": "Inkspring closed before Substack confirmed the result. Check Substack before trying again."
                ])
            }
        }
    }

    func claimPublication() throws -> PublicationLease {
        guard let directory else { throw WorkspaceError("The workspace is unavailable.") }
        return try PublicationLease(directory: directory)
    }

    func allowPublicationRetry(_ id: String) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        let lease = try claimPublication()
        defer { withExtendedLifetime(lease) {} }
        try database.transaction {
            try reload()
            guard var receipt = records.first(where: { $0.kind == "publication" && $0.id == id }),
                  ["publishing", "uncertain"].contains(receipt["status"]) else {
                throw WorkspaceError("Wait for the active publishing attempt to finish.")
            }
            let steps = receipt.fields["steps"] as? [[String: Any]] ?? []
            if receipt["contentKind"] == "article", !steps.isEmpty {
                throw WorkspaceError("X already confirmed this article’s post ID. Open the published article instead of retrying.")
            }
            receipt["status"] = steps.isEmpty ? "failed" : "partial"
            receipt["error"] = "The author checked the platform and allowed another attempt."
            try updatePublication(receipt)
        }
    }

    func recoverInterruptedPublications() {
        guard let database, records.contains(where: {
            $0.kind == "publication" && $0["status"] == "publishing" || $0.kind == "draft" && $0.scheduleStatus == "posting"
        }), let lease = try? claimPublication() else { return }
        defer { withExtendedLifetime(lease) {} }
        perform {
            try withChanges {
                let message = "Publishing was interrupted. Check the connected account before retrying."
                var receipts = records.filter { $0.kind == "publication" }
                for index in receipts.indices where receipts[index]["status"] == "publishing" {
                    receipts[index]["status"] = "uncertain"
                    receipts[index]["error"] = message
                    receipts[index].markUpdated()
                    try database.put(receipts[index])
                    if receipts[index]["contentKind"] == "article",
                       var article = records.first(where: { $0.kind == "article" && $0.id == receipts[index]["draftId"] }) {
                        article["state"] = "uncertain"
                        article["articlePublicationStatus"] = "uncertain"
                        article["articlePublicationError"] = message
                        try database.put(article)
                    }
                }
                let receiptsByDraft = Dictionary(grouping: receipts, by: { $0["draftId"] })
                for draft in records where draft.kind == "draft" && draft.scheduleStatus == "posting" {
                    let attempts = receiptsByDraft[draft.id] ?? []
                    if let receipt = attempts.first(where: { $0["status"] == "published" })
                        ?? attempts.first(where: { $0["status"] == "uncertain" })
                        ?? attempts.first(where: { ["failed", "partial"].contains($0["status"]) }) {
                        try database.put(draftAfterPublication(draft, receipt: receipt))
                    } else {
                        var receipt = WorkspaceRecord.new("publication", projectID: draft.projectID)
                        receipt["title"] = draft.title
                        receipt["draftId"] = draft.id
                        receipt["platform"] = draft["platform"]
                        receipt["status"] = "uncertain"
                        receipt["error"] = message
                        try database.put(receipt)
                        try database.put(draftAfterPublication(draft, receipt: receipt))
                    }
                }
                try reload()
            }
        }
    }

    func updatePublication(_ receipt: WorkspaceRecord) throws {
        if receipt["contentKind"] == "article" { try updateXArticlePublication(receipt); return }
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try database.transaction {
            try reload()
            var receipt = receipt
            receipt.markUpdated()
            try database.put(receipt)
            if receipt["status"] != "publishing",
               let draft = records.first(where: { $0.id == receipt["draftId"] && $0.kind == "draft" }),
               draft.scheduleStatus != "posted" || receipt["status"] == "published" {
                try database.put(draftAfterPublication(draft, receipt: receipt))
            }
            try reload()
        }
    }

    func savePublishedPostLink(_ input: WorkspaceRecord, address: String) throws {
        guard let url = CompanionPublication.postURL(address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WorkspaceError("Enter a valid HTTPS link to the published post.")
        }
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            guard var draft = records.first(where: { $0.id == input.id && $0.kind == "draft" }),
                  draft.scheduleStatus == "posted", draft["updatedAt"] == input["updatedAt"] else {
                throw WorkspaceError("This published post changed. Open it again before adding its link.")
            }
            var schedule = draft.schedule
            schedule["url"] = url.absoluteString
            draft.fields["schedule"] = schedule
            draft.markUpdated()
            try database.put(draft)
            try reload()
        }
    }

    private func draftAfterPublication(_ input: WorkspaceRecord, receipt: WorkspaceRecord) -> WorkspaceRecord {
        var draft = input
        var schedule = draft.schedule
        if receipt["status"] == "published" {
            schedule["status"] = "posted"
            if !receipt["publishedAt"].isEmpty { schedule["postedAt"] = receipt["publishedAt"] }
            let steps = receipt.fields["steps"] as? [[String: Any]] ?? []
            if let address = steps.compactMap({ $0["url"] as? String }).first(where: { !$0.isEmpty }) {
                schedule["url"] = address
            }
            schedule["error"] = ""
        } else {
            schedule["status"] = "failed"
            schedule["error"] = receipt["error"]
        }
        draft.fields["schedule"] = schedule
        draft.markUpdated()
        return draft
    }
}

extension Workspace {
    struct IdeaReturnPlan: Equatable {
        let ideaID: String
        let ideaTitle: String
        let ideaRevision: String
    }

    func reviewIdeaReturn(for draft: WorkspaceRecord) throws -> IdeaReturnPlan {
        try reload()
        guard let latest = records.first(where: { $0.id == draft.id && $0.kind == "draft" }),
              latest["updatedAt"] == draft["updatedAt"] else {
            throw WorkspaceError("This draft changed. Open it again before returning the idea.")
        }
        let ideaID = latest["ideaId"].isEmpty ? records.first {
            $0.kind == "idea" && $0.projectID == latest.projectID &&
                ($0.fields["versions"] as? [String: String])?.values.contains(latest.id) == true
        }?.id ?? "" : latest["ideaId"]
        return try ideaReturnPlan(ideaID: ideaID)
    }

    func returnToIdeas(_ reviewed: IdeaReturnPlan) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        let lease = try claimPublication()
        defer { withExtendedLifetime(lease) {} }
        try withChanges {
            guard try ideaReturnPlan(ideaID: reviewed.ideaID) == reviewed,
                  var idea = records.first(where: { $0.id == reviewed.ideaID && $0.kind == "idea" }) else {
                throw WorkspaceError("The idea or its drafts changed. Review them before returning the idea.")
            }
            idea["status"] = "draft"
            _ = try saveCurrent(idea, to: database)
        }
    }

    private func ideaReturnPlan(ideaID: String) throws -> IdeaReturnPlan {
        guard !ideaID.isEmpty, let idea = records.first(where: { $0.id == ideaID && $0.kind == "idea" }),
              idea["status"] == "picked" else {
            throw WorkspaceError("This post does not belong to a picked idea.")
        }
        return IdeaReturnPlan(ideaID: idea.id, ideaTitle: idea.title, ideaRevision: idea["updatedAt"])
    }

    func quoteComposerURL(for draft: WorkspaceRecord) -> URL? {
        guard draft.kind == "draft", draft["platform"] == "x", !["posting", "posted"].contains(draft.scheduleStatus),
              let idea = records.first(where: { $0.kind == "idea" && $0.id == draft["ideaId"] && $0.projectID == draft.projectID }),
              let source = XQuoteComposer.source(in: idea) else { return nil }
        return XQuoteComposer.url(text: draft.body, quoting: source)
    }

    func prepareManualQuote(_ draft: WorkspaceRecord) throws -> URL {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        let lease = try claimPublication()
        defer { withExtendedLifetime(lease) {} }
        return try withChanges {
            guard var latest = records.first(where: { $0.kind == "draft" && $0.id == draft.id }),
                  latest["updatedAt"] == draft["updatedAt"], let url = quoteComposerURL(for: latest),
                  !records.contains(where: { $0.kind == "publication" && $0["draftId"] == draft.id }) else {
                throw WorkspaceError("Review the latest draft and its publishing history before opening X.")
            }
            if latest.scheduleStatus != "manual" || latest.fields["manualQuote"] as? Bool != true ||
                !(latest.schedule["slotAt"] as? String ?? "").isEmpty {
                var schedule = latest.schedule
                schedule["status"] = "manual"
                schedule["slotAt"] = ""
                schedule["error"] = ""
                latest.fields["schedule"] = schedule
                latest.fields["manualQuote"] = true
                _ = try saveCurrent(latest, to: database)
            }
            return url
        }
    }

    @discardableResult
    func scheduleDraft(_ input: WorkspaceRecord, at time: Date, tiktok plan: SocialPublishPlan? = nil,
                       linkedin selected: LinkedInDestination? = nil,
                       linkedInAccount override: ManagedSocialAccount? = nil,
                       customTime: Bool = false) throws -> WorkspaceRecord {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try database.transaction {
            try reload()
            guard var draft = records.first(where: { $0.kind == "draft" && $0.id == input.id }),
                  input["updatedAt"] == draft["updatedAt"], !["posting", "posted"].contains(draft.scheduleStatus),
                  !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceError("Reopen the latest draft and add its post text before scheduling.")
            }
            guard draft.fields["manualQuote"] as? Bool != true else {
                throw WorkspaceError("Open this quote draft in X to publish it.")
            }
            guard !records.contains(where: {
                $0.kind == "publication" && $0["draftId"] == draft.id && ["published", "publishing", "uncertain"].contains($0["status"])
            }) else {
                throw WorkspaceError("Check this post in Publishing history before scheduling it again.")
            }
            _ = try PostVideo.forDraft(draft, in: records)
            var personalURN: String?
            if draft["platform"] == "x" {
                let posts = ["followup", "thread"].contains(draft["format"]) ? XThreadText.posts(in: draft.body) : [draft.body]
                let links = try XPostArticleLinks(draft: draft, posts: posts, records: records)
                let pending = Set(links.articles.filter { $0["state"] != "published" }.map(\.id))
                guard customTime || pending.isEmpty else {
                    throw WorkspaceError("Use Publish together on X to send the draft article and its post.")
                }
                _ = try links.resolve(posts, pending: pending)
            }
            if draft["platform"] == "linkedin" {
                guard let account = try override ?? socialAccounts.savedAccount(.linkedin) else {
                    throw WorkspaceError("Connect LinkedIn and choose a destination before scheduling.")
                }
                let destination = try LinkedInPages.schedulingDestination(for: draft, account: account, selected: selected)
                draft.fields["linkedinDestination"] = destination.fields
                personalURN = LinkedInDestination.personal(account).urn
            }
            guard time >= Date.now.addingTimeInterval(PostScheduling.leadTime) else {
                throw WorkspaceError("Choose a posting time at least two minutes from now.")
            }
            guard PostScheduling.isFree(time, for: draft, in: records, linkedInPersonalURN: personalURN, customTime: customTime) else {
                throw WorkspaceError(customTime ? "This destination already has a post at that minute. Choose another time."
                                                 : "Choose another open posting time for this platform.")
            }
            var schedule = draft.schedule
            let slot = workspaceTimestamp(time)
            schedule["slotAt"] = slot
            schedule["companionRevision"] = UUID().uuidString
            schedule["status"] = "queued"
            schedule["error"] = ""
            schedule["pickedAt"] = schedule["pickedAt"] ?? WorkspaceRecord.timestamp
            if draft["platform"] == "tiktok" {
                guard let plan, let options = plan.tiktok, options.consent, plan.revision == draft["updatedAt"],
                      plan.draftID == draft.id, plan.platform == .tiktok else {
                    throw WorkspaceError("Review TikTok’s privacy, caption and consent before scheduling.")
                }
                draft["content"] = options.caption
                if draft["format"] == "image", !options.title.isEmpty { draft["title"] = options.title }
                draft.markUpdated()
                draft.fields["schedule"] = schedule
                var consent = WorkspaceRecord.new("tiktok-consent", projectID: draft.projectID)
                consent["id"] = "tiktok-consent:" + draft.id
                consent["draftId"] = draft.id
                consent["accountId"] = plan.accountID
                consent["slotAt"] = slot
                consent["draftRevision"] = draft["updatedAt"]
                consent["imageURL"] = plan.publicImage?.absoluteString ?? ""
                consent.fields["options"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options))
                try database.put(draft)
                try database.put(consent)
                try reload()
                return draft
            }
            draft.fields["schedule"] = schedule
            return try saveCurrent(draft, to: database, scheduling: true)
        }
    }
}

extension Workspace {
    func savePersonalProfile(_ profile: [String: Any], replacing expected: [String: Any], suggestionID: String? = nil) throws {
        try withChanges {
            let active = settings["personalProfile"] as? [String: Any] ?? [:]
            guard NSDictionary(dictionary: active).isEqual(to: expected) else {
                throw WorkspaceError("The saved profile changed. Reload it before applying your edits.")
            }
            let normalized = try PersonalProfile.normalized(profile)
            if let suggestionID {
                try reviewSuggestion(suggestionID, accept: true, reviewedProfile: normalized)
            } else {
                try set("personalProfile", to: normalized)
            }
        }
    }

    func suggestProfile(_ patch: [String: Any]) throws -> WorkspaceRecord {
        guard !patch.isEmpty else { throw WorkspaceError("Include a profile field to suggest.") }
        let existing = settings["personalProfile"] as? [String: Any] ?? [:]
        let profile = try PersonalProfile.normalized(existing.merging(patch) { _, value in value })
        var item = WorkspaceRecord.new("personal-inbox")
        item["kind"] = "profile"
        item["origin"] = "Connected agent"
        item.fields["profile"] = profile
        return try saveSuggestion(item)
    }

    func suggestContext(projectID: String, title: String, summary: String, origin: String,
                        noteIDs: [String]? = nil) throws -> WorkspaceRecord {
        guard projects.contains(where: { $0.id == projectID }),
              (1...200).contains(title.utf16.count), (1...5000).contains(summary.utf16.count),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, origin.utf16.count <= 100 else {
            throw WorkspaceError("Choose a project and enter a short title and public-safe summary.")
        }
        var item = WorkspaceRecord.new("personal-inbox", projectID: projectID)
        item["kind"] = "context"
        item["title"] = title
        item["summary"] = summary
        item["origin"] = origin.isEmpty ? "Connected agent" : origin
        item.fields["noteIds"] = noteIDs
        return try saveSuggestion(item)
    }

    private func saveSuggestion(_ input: WorkspaceRecord) throws -> WorkspaceRecord {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try withChanges {
            guard records.filter({ $0.kind == "personal-inbox" && $0["status"] == "pending" }).count < 40 else {
                throw WorkspaceError("Review the pending suggestions in Settings before adding more.")
            }
            var item = input
            item["status"] = "pending"
            try database.put(item)
            try reload()
            return item
        }
    }

    func reviewSuggestion(_ id: String, accept: Bool, reviewedProfile: [String: Any]? = nil) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            guard var item = records.first(where: { $0.kind == "personal-inbox" && $0.id == id && $0["status"] == "pending" }) else {
                throw WorkspaceError("This suggestion was already reviewed.")
            }
            if accept {
                if item["kind"] == "profile", let profile = reviewedProfile ?? item.fields["profile"] as? [String: Any] {
                    try set("personalProfile", to: PersonalProfile.normalized(profile))
                } else if item["kind"] == "context" {
                    var source = WorkspaceRecord.new("source", projectID: item.projectID)
                    source["title"] = item["title"]
                    source["text"] = item["summary"]
                    source["origin"] = item["origin"]
                    try save(source)
                } else {
                    throw WorkspaceError("This suggestion is invalid.")
                }
            }
            item["status"] = accept ? "accepted" : "dismissed"
            item["updatedAt"] = WorkspaceRecord.timestamp
            try database.put(item)
            try reload()
        }
    }
}

extension Workspace {
    func saveResearchReference(_ fields: [String: Any], projectID: String) throws -> WorkspaceRecord {
        try withChanges {
            let link = fields["url"] as? String ?? ""
            if !link.isEmpty, let existing = records.first(where: { $0.kind == "source" && $0.projectID == projectID && $0["url"] == link }) {
                return existing
            }
            var source = WorkspaceRecord.new("source", projectID: projectID)
            for key in ["title", "text", "url", "author", "origin", "likes", "reposts", "replies", "views", "followers", "postedAt", "sourceType"] {
                source.fields[key] = fields[key]
            }
            source["title"] = String(source["title"].prefix(150))
            return try save(source)
        }
    }

    func dismissResearch(_ itemID: String, from feedID: String) throws {
        try withChanges {
            guard var feed = records.first(where: { $0.kind == "discovery" && $0.id == feedID }),
                  let items = feed.fields["items"] as? [[String: Any]],
                  items.contains(where: { $0["id"] as? String == itemID }) else {
                throw WorkspaceError("This research item is no longer available.")
            }
            var feedback = records.first { $0.kind == "research-feedback" && $0.id == feedID + ":feedback" }
                ?? WorkspaceRecord.new("research-feedback", projectID: feed.projectID)
            feedback["id"] = feedID + ":feedback"
            feedback["title"] = "Dismissed research"
            let dismissed = feedback.fields["dismissed"] as? [String] ?? []
            feedback.fields["dismissed"] = Array((dismissed.filter { $0 != itemID } + [itemID]).suffix(300))
            try save(feedback)
            if feed["title"].isEmpty { feed["title"] = platformName(feed["platform"]) }
            feed.fields["items"] = items.filter { $0["id"] as? String != itemID }
            try save(feed)
        }
    }
}

extension Workspace {
    func refillIdeaQueueIfNeeded(projectID requestedProject: String? = nil) async {
        let id = requestedProject ?? projectID
        guard settings["ideaQueueAutomatic"] as? Bool == true,
              let project = projects.first(where: { $0.id == id }),
              project.fields["sample"] as? Bool != true else { return }
        let now = Date.now
        let target = IdeaQueuePlan.target(settings["ideaQueueTarget"])
        guard records.filter({ $0.isPendingPostIdea && $0.projectID == id }).count < target,
              now.timeIntervalSince(lastIdeaQueueAttempt[project.id] ?? .distantPast) > 3600 else { return }
        lastIdeaQueueAttempt[project.id] = now
        do {
            _ = try await ResearchDiscovery(studio: ContentStudio(workspace: self))
                .refreshIdeas(projectID: project.id, withResearch: true, automatic: true)
        } catch {
            notice = "Idea refill paused: " + error.localizedDescription
        }
    }
}

extension Workspace {
    @discardableResult
    func saveReplyPage(_ rows: [WorkspaceRecord], session: String, state: [String: Any]) throws -> Int {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try withChanges {
            var count = 0
            for row in rows {
                var next = row
                let old = records.first { $0.kind == "reply-inbox" && $0.id == row.id }
                next["status"] = old?["status"] ?? "unread"
                next["draftId"] = old?["draftId"] ?? ""
                if old == nil { count += 1 }
                try database.put(next)
            }
            var states = settings["replyInboxSync"] as? [String: [String: Any]] ?? [:]
            states[session] = state
            try database.set("replyInboxSync", to: states)
            try reload()
            return count
        }
    }

    func markReply(_ id: String, status: String) throws {
        guard let database, ["unread", "read", "archived"].contains(status) else {
            throw WorkspaceError("Choose a reply status.")
        }
        try withChanges {
            guard var row = records.first(where: { $0.kind == "reply-inbox" && $0.id == id }) else {
                throw WorkspaceError("This reply no longer exists.")
            }
            row["status"] = status
            try database.put(row)
            try reload()
        }
    }

    func ignoreReplies(_ ids: Set<String>) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            for var row in records where row.kind == "reply-inbox" && ids.contains(row.id) && row["status"] != "archived" {
                row["status"] = "archived"
                try database.put(row)
            }
            try reload()
        }
    }

    func makeReplyDraft(_ id: String, projectID: String) throws -> WorkspaceRecord {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        return try withChanges {
            guard var row = records.first(where: { $0.kind == "reply-inbox" && $0.id == id }) else {
                throw WorkspaceError("This reply no longer exists.")
            }
            if let prior = records.first(where: { $0.kind == "draft" && $0.id == row["draftId"] }) { return prior }
            var draft = WorkspaceRecord.new("draft", projectID: projectID)
            draft["title"] = "Reply to " + String(row.title.prefix(150))
            draft["format"] = "reply"
            draft.fields["replyTo"] = ["text": row.body, "url": row["url"], "author": String(row["author"].prefix(100))]
            if let parent = row.fields["parent"] as? [String: Any], let text = parent["text"] as? String {
                draft["brief"] = "Conversation context for this reply: " + String(text.prefix(4500))
            }
            let saved = try save(draft)
            row["draftId"] = saved.id
            row["status"] = "drafted"
            try database.put(row)
            try reload()
            return saved
        }
    }
}

extension Workspace {
    func saveAnalyticsRows(_ rows: [WorkspaceRecord]) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            for row in rows {
                guard ["analytics-day", "analytics-post", "analytics-state"].contains(row.kind) else {
                    throw WorkspaceError("Invalid analytics record.")
                }
                try database.put(row)
            }
            try reload()
        }
    }
}

extension Workspace {
    func saveR2Media(_ media: R2Client.Media, config: R2Configuration) throws {
        guard let database else { throw WorkspaceError("The workspace is unavailable.") }
        try withChanges {
            let existing = records.first {
                $0.kind == "r2-object" && $0["accountId"] == config.accountId && $0["bucket"] == config.bucket
                    && $0["jurisdiction"] == config.jurisdiction && $0["key"] == media.key
            }
            var record = existing ?? WorkspaceRecord.new("r2-object")
            record["accountId"] = config.accountId
            record["bucket"] = config.bucket
            record["jurisdiction"] = config.jurisdiction
            record["key"] = media.key
            record["type"] = media.type
            record["name"] = media.name
            record["uploadedAt"] = WorkspaceRecord.timestamp
            record.fields["size"] = media.size
            try database.put(record)
            try reload()
        }
    }
}
