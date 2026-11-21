import CloudKit
import CryptoKit
import FoundationModels
import SwiftUI
import UniformTypeIdentifiers

private extension CompanionLibrary.Item {
    var revisionDate: Date? {
        (try? Date(revision, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(revision, strategy: .iso8601))
    }
}

@MainActor @Observable
final class MobileLibrary {
    private struct LibraryState {
        var snapshot: CompanionLibrary?
        var outbox = CompanionLibraryOutbox()
    }

    private var state = LibraryState()
    var snapshot: CompanionLibrary? { state.snapshot }
    var error: String?
    var busy = false
    private(set) var lastCheck: Date?
    private(set) var lastCloudContact: Date?
    private(set) var accountStatus = "Not checked"
    private(set) var remoteWorkspaceFound: Bool?
    private(set) var syncErrorCode: String?
    private var account: String?
    private var accountRevision = UUID()
    private var store: CloudScheduleStore?
    private var syncedText: (workspace: UUID, version: CompanionLibrary.TextVersion, data: Data)?
    static let preferences: UserDefaults = {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--unpaired-fixture"),
           let id = ProcessInfo.processInfo.environment["INKSPRING_FIXTURE_ID"],
           let suite = UserDefaults(suiteName: "inkspring.onboarding.tests." + id) { return suite }
#endif
        return .standard
    }()
    private let defaults = MobileLibrary.preferences
    private static let outboxKey = "inkspring.mobile.libraryOutbox.v1"
    private static let legacyIdeasKey = "inkspring.mobile.localIdeas.v1"
    private var outbox: CompanionLibraryOutbox { state.outbox }
    private var outboxLoaded = false
    private var newsletterRefreshPending = false
#if DEBUG
    private var staleFixtureSnapshot: CompanionLibrary?
#endif

    struct NewsletterEditRecovery: Codable {
        let revision: String
        let base: String
        let markdown: String
        var title: String?
        var baseTitle: String?
    }

    func planRecoveryID(_ itemID: String, workspaceID: UUID) -> String {
        "\(account ?? "unavailable").\(workspaceID).\(itemID)"
    }

    func newsletterRecoveryKey(for itemID: String, workspaceID: UUID) -> String? {
        guard let account, snapshot?.workspaceID == workspaceID else { return nil }
        return "inkspring.mobile.newsletterRecovery.\(account).\(workspaceID).\(itemID)"
    }

    func recoverNewsletterEdit(key: String) -> NewsletterEditRecovery? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NewsletterEditRecovery.self, from: data)
    }

    func storeNewsletterRecovery(_ edit: NewsletterEditRecovery?, key: String) {
        guard let edit else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(edit) {
            defaults.set(data, forKey: key)
        }
    }

    var pendingIdeas: [CompanionLibraryOutbox.Entry] {
        outbox.entries.reversed().filter {
            $0.action == .addIdea && $0.generatesXDraft != true && $0.createsScript != true && ($0.account == nil || $0.account == account)
                && ($0.workspaceID == nil || $0.workspaceID == snapshot?.workspaceID || snapshot == nil)
                && !isDeleting($0.id.uuidString.lowercased())
        }
    }

    func isDeleting(_ itemID: String) -> Bool {
        outbox.entries.contains { [.trashItem, .deleteItem, .skipIdea].contains($0.action) && $0.itemID == itemID && $0.error == nil
            && ($0.account == nil || $0.account == account)
            && ($0.workspaceID == nil || $0.workspaceID == snapshot?.workspaceID) }
    }

    func skipPendingIdea(_ entry: CompanionLibraryOutbox.Entry) throws {
        try loadOutbox()
        guard !isDeleting(entry.id.uuidString.lowercased()) else { return }
        try queue(.init(id: UUID(), action: .trashItem, itemID: entry.id.uuidString.lowercased(),
                        revision: "pending-add", title: "", text: "", workspaceID: entry.workspaceID, account: entry.account))
    }

    var canUseAgentFeatures: Bool { snapshot?.enabled == true && snapshot?.supportsAgentFeatures == true }

    func revisionRequests(for item: CompanionLibrary.Item) -> [StudioWritingRequest] {
        let current = (snapshot?.items ?? []).first { $0.id == item.id }
            ?? (snapshot?.newsletters ?? []).first { $0.id == item.id }
            ?? (snapshot?.scripts ?? []).first { $0.id == item.id }
            ?? (snapshot?.articles ?? []).first { $0.id == item.id }
            ?? item
        let saved = current.revisionRequests?.map(StudioWritingRequest.init) ?? current.notes.enumerated().map { index, text in
            let raw = current.noteStates?.indices.contains(index) == true ? current.noteStates?[index] : nil
            let state: CompanionLibrary.RevisionRequest.State = switch raw {
            case "applied": .actedOn
            case "pending": .pending
            case "waitingForDraft": .waitingForEditable
            default: .savedNote
            }
            let date = current.noteDates?.indices.contains(index) == true ? current.noteDates?[index] : nil
            return StudioWritingRequest(.init(id: "legacy-\(index)", text: text, date: date, state: state))
        }
        let synced = Set(saved.map(\.id))
        return saved + pendingChanges(for: item.id).compactMap { entry in
            let id = entry.requestID.uuidString.lowercased()
            guard entry.requestsWritingHelp == true, !synced.contains(id) else { return nil }
            return StudioWritingRequest(id: id, text: entry.text, state: entry.error ?? "Waiting for your Mac to revise")
        }
    }

    var pendingMediaDrafts: [CompanionLibraryOutbox.Entry] {
        outbox.entries.filter { $0.mediaDraft != nil && $0.workspaceID == snapshot?.workspaceID && $0.account == account }
    }

    var pendingQuickXPosts: [CompanionLibraryOutbox.Entry] {
        outbox.entries.filter { $0.quickXAccountKey != nil && $0.workspaceID == snapshot?.workspaceID && $0.account == account }
    }

    func pendingChanges(for itemID: String) -> [CompanionLibraryOutbox.Entry] {
        outbox.entries.filter {
            $0.itemID == itemID && $0.workspaceID == snapshot?.workspaceID && $0.account == account
                && $0.action != .saveRevision
        }
    }

    private func historyURL(workspaceID: UUID, account: String) -> URL {
        let scope = SHA256.hash(data: Data((account + workspaceID.uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory.appending(path: "Inkspring/Revisions/\(scope).json")
    }

    private func localHistory(workspaceID: UUID, account: String) throws -> [String: [ContentRevision]] {
        let url = historyURL(workspaceID: workspaceID, account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: [ContentRevision]].self, from: Data(contentsOf: url))
    }

    func history(for item: CompanionLibrary.Item) throws -> [ContentRevision] {
        guard let snapshot, let account else { return item.history ?? [] }
        let local = try localHistory(workspaceID: snapshot.workspaceID, account: account)[item.id] ?? []
        let current = (snapshot.items + (snapshot.newsletters ?? []) + (snapshot.scripts ?? []) + (snapshot.articles ?? [])).first { $0.id == item.id } ?? item
        let all = (current.history ?? []) + local
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { ($0.savedAt ?? "") > ($1.savedAt ?? "") }
    }

    private func recordHistory(_ entry: CompanionLibraryOutbox.Entry) throws {
        guard entry.action == .editDraft, let itemID = entry.itemID, let workspaceID = entry.workspaceID,
              let account = entry.account,
              let item = ((snapshot?.items ?? []) + (snapshot?.newsletters ?? []) + (snapshot?.scripts ?? []) + (snapshot?.articles ?? [])).first(where: { $0.id == itemID }) else { return }
        var archive = try localHistory(workspaceID: workspaceID, account: account)
        var versions = archive[itemID] ?? []
        if !item.shortened, !(versions + (item.history ?? [])).contains(where: { $0.text == item.body && $0.savedAt == item.revision }) {
            versions.append(.init(savedAt: item.revision, title: item.title, text: item.body,
                                  format: item.format, source: "Mac"))
        }
        versions.append(.init(id: entry.id.uuidString, savedAt: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)),
                              title: entry.title.isEmpty ? item.title : entry.title, text: entry.text,
                              format: entry.xFormat ?? item.format, subtitle: entry.subtitle ?? item.history?.first?.subtitle,
                              source: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))
        archive[itemID] = versions
        let url = historyURL(workspaceID: workspaceID, account: account)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func queueHistory(in library: CompanionLibrary, account: String, outbox: inout CompanionLibraryOutbox) throws {
        guard library.supportsRevisionHistory == true else { return }
        let items = library.items + (library.newsletters ?? []) + (library.scripts ?? []) + (library.articles ?? [])
        let existing = Set(items.flatMap { $0.history ?? [] }.map(\.id) +
            library.pending.compactMap { $0.historySnapshot?.id } + outbox.entries.compactMap { $0.historySnapshot?.id })
        for (itemID, revisions) in try localHistory(workspaceID: library.workspaceID, account: account) {
            guard items.contains(where: { $0.id == itemID }) else { continue }
            for revision in revisions where !existing.contains(revision.id) {
                outbox.entries.append(.init(id: UUID(), action: .saveRevision, itemID: itemID, revision: "",
                    title: "", text: "", workspaceID: library.workspaceID, account: account, historySnapshot: revision))
            }
        }
    }

    enum NewsletterSyncStatus: String {
        case savedOnDevice = "Saved on this device"
        case needsMacUpdate = "Mac update needed"
        case waitingForMac = "Waiting for Mac"
        case needsReview = "Edit needs review"

        var icon: String {
            switch self {
            case .savedOnDevice, .waitingForMac: "clock"
            case .needsMacUpdate: "arrow.down.circle"
            case .needsReview: "exclamationmark.circle"
            }
        }
    }

    func newsletterSyncStatus(for entry: CompanionLibraryOutbox.Entry) -> NewsletterSyncStatus {
        if entry.error != nil { return .needsReview }
        if entry.change?.needsWritingTools == true && snapshot?.supportsWritingTools != true || (entry.editsScript == true ? snapshot?.supportsScripts != true : snapshot?.supportsNewsletterEdits != true) { return .needsMacUpdate }
        if snapshot?.pending.contains(where: { $0.id == entry.requestID }) == true { return .waitingForMac }
        return .savedOnDevice
    }

    var newsletterSyncSummary: String? {
        guard let snapshot else { return nil }
        let edits = outbox.entries.filter {
            $0.isLongFormEdit && $0.workspaceID == snapshot.workspaceID && $0.account == account
        }
        let latestByItem = Dictionary(edits.compactMap { edit in edit.itemID.map { ($0, edit) } },
                                      uniquingKeysWith: { _, newest in newest })
        let statuses = latestByItem.values.map(newsletterSyncStatus)
        if statuses.contains(.needsReview) { return NewsletterSyncStatus.needsReview.rawValue }
        if snapshot.supportsNewsletterEdits != true { return NewsletterSyncStatus.needsMacUpdate.rawValue }
        if statuses.contains(.savedOnDevice) { return NewsletterSyncStatus.savedOnDevice.rawValue }
        if statuses.contains(.waitingForMac) { return NewsletterSyncStatus.waitingForMac.rawValue }
        if error != nil { return "Check failed" }
        return "Up to date"
    }

    struct SchedulingRequest: Identifiable {
        let item: CompanionLibrary.Item
        let hour: Date
        let error: String?
        var id: String { item.id }
    }

    var pendingSchedules: [SchedulingRequest] {
        (snapshot?.items ?? []).compactMap { item in
            guard let entry = pendingChanges(for: item.id).last(where: { $0.action == .scheduleDraft }),
                  let hour = entry.change?.postingHour else { return nil }
            return SchedulingRequest(item: item, hour: hour, error: entry.error)
        }
    }

    var visibleItems: [CompanionLibrary.Item] {
        let remote: [CompanionLibrary.Item] = (snapshot?.items ?? []).compactMap { original in
            var item = original
            for change in pendingChanges(for: item.id) where change.error == nil {
                switch change.action {
                case .trashItem, .skipIdea: item.isTrashed = true
                case .restoreItem, .restoreIdea: item.isTrashed = false
                case .deleteItem: return nil
                default: break
                }
            }
            return item
        }
        let remoteIDs = Set(remote.map(\.id))
        let local = pendingIdeas.compactMap { entry -> CompanionLibrary.Item? in
            let id = entry.id.uuidString.lowercased()
            guard !remoteIDs.contains(id) else { return nil }
            var item = CompanionLibrary.Item(id: id, revision: "pending-add", kind: .idea,
                projectID: entry.itemID ?? snapshot?.projects.first?.id ?? "", title: entry.title, body: entry.text,
                shortened: false, platform: "", status: "draft", notes: [])
            item.generationStatus = entry.error ?? (snapshot == nil ? "Saved on this device" : "Waiting for your Mac to sync this idea")
            item.planMarkdown = entry.initialPlan
            return item
        }
        return local + remote
    }

    func isChanging(_ itemID: String) -> Bool {
        pendingChanges(for: itemID).contains { !([CompanionLibrary.Change.Action.note, .saveRevision].contains($0.action)) && $0.error == nil }
            || snapshot?.pending.contains { $0.itemID == itemID && !([CompanionLibrary.Change.Action.note, .saveRevision].contains($0.action)) } == true
    }

    func canDelete(_ itemID: String) -> Bool {
        if !isChanging(itemID) { return true }
        guard let move = pendingTrash(for: itemID) else { return false }
        return pendingChanges(for: itemID).allSatisfy { $0.id == move.id || $0.action == .note || $0.error != nil }
            && snapshot?.pending.contains { $0.itemID == itemID && $0.id != move.requestID && !([CompanionLibrary.Change.Action.note, .saveRevision].contains($0.action)) } != true
    }

    private func pendingTrash(for itemID: String) -> CompanionLibraryOutbox.Entry? {
        pendingChanges(for: itemID).last { $0.movesToTrash && $0.error == nil }
    }

    var visibleScripts: [CompanionLibrary.Item] {
        let remote = (snapshot?.scripts ?? []) + (snapshot?.articles ?? []).filter { $0.platform != "linkedin" }
        let ids = Set((remote + (snapshot?.newsletters ?? [])).map(\.id))
        let local = outbox.entries.filter {
            $0.createsScript == true && $0.account == account && $0.workspaceID == snapshot?.workspaceID
                && !ids.contains($0.id.uuidString.lowercased())
        }.map { entry in
            CompanionLibrary.Item(id: entry.id.uuidString.lowercased(), revision: "pending-add", kind: mobileWritingKind(entry.writingKind),
                projectID: entry.itemID ?? "", title: entry.title, body: entry.text, shortened: false,
                platform: mobileWritingPlatform(entry.writingKind), status: "draft", notes: [])
        }
        return remote + local
    }

    func createScript(projectID: String, kind: String = "script") throws -> String {
        guard let snapshot else { throw CompanionScheduleError.changed }
        let title = kind == "newsletter" ? "Untitled newsletter" : kind == "script" ? "Untitled YouTube script" :
            "Untitled \(reviewPlatformName(mobileWritingPlatform(kind))) article"
        let change = CompanionLibrary.Change(action: .addIdea, itemID: projectID, title: title, createsScript: true, writingKind: kind)
        try saveChange(change, workspaceID: snapshot.workspaceID)
        return change.id.uuidString.lowercased()
    }

    @discardableResult
    func saveIdea(title: String, text: String, projectID: String?, plan: String? = nil) throws -> String {
        let id = UUID()
        try queue(.init(id: id, action: .addIdea, itemID: projectID, revision: "", title: title, text: text,
                        workspaceID: snapshot?.workspaceID, account: account, initialPlan: plan))
        return id.uuidString.lowercased()
    }

    func saveChange(_ change: CompanionLibrary.Change, workspaceID: UUID) throws {
        guard let account, snapshot?.workspaceID == workspaceID else { throw CompanionScheduleError.changed }
        guard !change.usesMacAgent || canUseAgentFeatures else { throw CompanionLibraryError.disabled }
        guard change.ideaDraftPlatforms == nil || snapshot?.supportsClaudeIdeaDrafts == true else {
            throw CompanionLibraryError.macUpdateForIdeaDrafts
        }
        guard change.mediaDraft == nil || snapshot?.supportsMediaDrafts == true else { throw CompanionLibraryError.disabled }
        guard change.quickXAccountKey == nil || snapshot?.supportsQuickXPost == true else { throw CompanionLibraryError.disabled }
        guard change.valid else { throw CompanionLibraryError.invalid }
        if change.isLongFormEdit, try JSONEncoder().encode(change).count > change.payloadLimit {
            throw CompanionLibraryError.invalid
        }
        if change.action == .scheduleDraft, snapshot?.postingWindows == nil { throw CompanionLibraryError.disabled }
        let afterTrash = change.action == .deleteItem ? pendingTrash(for: change.itemID)?.id : nil
        let creation = change.isLongFormEdit || change.requestsWritingHelp == true ? outbox.entries.last {
            $0.createsScript == true && $0.id.uuidString.lowercased() == change.itemID && $0.account == account
                && $0.workspaceID == workspaceID
        }?.requestID : nil
        let predecessor = change.requestsWritingHelp == true ? outbox.entries.last {
            $0.action == .editDraft && $0.itemID == change.itemID && $0.account == account && $0.workspaceID == workspaceID && $0.error == nil
        }?.requestID ?? creation : creation
        try queue(.init(id: change.id, action: change.action, itemID: change.itemID, revision: change.revision,
                        title: change.title, text: change.text, workspaceID: workspaceID, account: account,
                        afterTrash: afterTrash, publishesXArticle: change.publishesXArticle, xArticleAccountKey: change.xArticleAccountKey, requestsWritingHelp: change.requestsWritingHelp, writingKind: change.writingKind, baseScriptTitle: change.baseScriptTitle, editsScript: change.editsScript, createsScript: change.createsScript, editsNewsletter: change.editsNewsletter, afterNewsletterEdit: predecessor,
                        baseNewsletterText: change.baseNewsletterText, xFormat: change.xFormat, generatesXDraft: change.generatesXDraft,
                        restoresRevision: change.restoresRevision, subtitle: change.subtitle, contentOperation: change.contentOperation, basePlan: change.basePlan, initialPlan: change.initialPlan,
                        ideaDraftPlatforms: change.ideaDraftPlatforms, mediaDraft: change.mediaDraft, quickXAccountKey: change.quickXAccountKey))
    }

    func queueQuickXPost(text: String, projectID: String, accountKey: String) throws -> UUID {
        guard let snapshot, snapshot.supportsQuickXPost == true, snapshot.xArticleAccountKey == accountKey else {
            throw CompanionLibraryError.disabled
        }
        var request = CompanionLibrary.Change(action: .note, itemID: projectID, text: text)
        request.quickXAccountKey = accountKey
        try saveChange(request, workspaceID: snapshot.workspaceID)
        return request.id
    }

    private func mediaOutboxURL(_ id: UUID) -> URL {
        URL.applicationSupportDirectory.appending(path: "Inkspring/Media Outbox/\(id.uuidString.lowercased())")
    }

    func queueMediaDraft(file: URL, platform: String, caption: String, projectID: String, ideaID: String? = nil) throws {
        guard let snapshot else { throw CompanionScheduleError.changed }
        let opened = file.startAccessingSecurityScopedResource()
        defer { if opened { file.stopAccessingSecurityScopedResource() } }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize,
              (1...CompanionLibrary.MediaDraft.limit).contains(size) else { throw CompanionLibraryError.invalid }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let name = file.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        var change = CompanionLibrary.Change(action: .note, itemID: projectID, title: name, text: caption)
        change.mediaDraft = .init(platform: platform, fileName: name, data: data, ideaID: ideaID)
        guard change.valid else { throw CompanionLibraryError.invalid }
        let destination = mediaOutboxURL(change.id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        do { try saveChange(change, workspaceID: snapshot.workspaceID) }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func queue(_ entry: CompanionLibraryOutbox.Entry) throws {
        try loadOutbox()
        try recordHistory(entry)
        var next = outbox
        if entry.action == .editDraft {
            next.queueNewsletterEdit(entry)
        } else {
            if entry.ideaDraftPlatforms != nil {
                next.entries.removeAll {
                    $0.ideaDraftPlatforms != nil && $0.itemID == entry.itemID && $0.workspaceID == entry.workspaceID
                        && $0.account == entry.account && $0.error != nil
                }
            }
            if [.editDraft, .editIdea, .trashItem, .restoreItem, .deleteItem, .scheduleDraft].contains(entry.action) {
                next.entries.removeAll {
                    $0.action == entry.action && $0.contentOperation == entry.contentOperation
                        && $0.editsNewsletter == entry.editsNewsletter && $0.itemID == entry.itemID && $0.workspaceID == entry.workspaceID
                        && $0.account == entry.account && $0.error != nil
                }
            }
            next.entries.append(entry)
        }
        try persist(next)
        if (entry.isLongFormEdit || entry.requestsWritingHelp == true || entry.publishesXArticle == true
            || entry.ideaDraftPlatforms != nil || entry.mediaDraft != nil || entry.quickXAccountKey != nil) && busy {
            newsletterRefreshPending = true
        } else {
            Task { await refresh() }
        }
    }

    private func loadOutbox() throws {
        guard !outboxLoaded else { return }
        if let data = defaults.data(forKey: Self.outboxKey) {
            state.outbox = try JSONDecoder().decode(CompanionLibraryOutbox.self, from: data)
        } else if let data = defaults.data(forKey: Self.legacyIdeasKey), !data.isEmpty {
            var migrated = outbox
            try migrated.migrateIdeas(from: data)
            try persist(migrated)
        }
        outboxLoaded = true
    }

    private func persist(_ value: CompanionLibraryOutbox) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: Self.outboxKey)
        state.outbox = value
    }

#if DEBUG
    private func prepareChanges(in library: CompanionLibrary, account: String) throws -> [CompanionLibrary.Change] {
        var next = outbox
        try queueHistory(in: library, account: account, outbox: &next)
        let changes = next.prepare(for: library, account: account)
        try persist(next)
        return changes
    }
#endif

    private func acceptSnapshot(_ incoming: CompanionLibrary, account: String) throws -> [CompanionLibrary.Change] {
        guard !isOlderSnapshot(incoming) else { return [] }
        var next = outbox
        try queueHistory(in: incoming, account: account, outbox: &next)
        let changes = next.prepare(for: incoming, account: account)
        let completedMedia = outbox.entries.filter { entry in
            entry.mediaDraft != nil && incoming.results.contains { $0.id == entry.requestID && $0.error == nil }
        }
        if next != outbox { defaults.set(try JSONEncoder().encode(next), forKey: Self.outboxKey) }
        if snapshot != incoming || next != outbox {
            // Clearing an acknowledged local edit must replace the displayed text in the same update.
            state = LibraryState(snapshot: incoming, outbox: next)
        }
        for entry in completedMedia { try? FileManager.default.removeItem(at: mediaOutboxURL(entry.id)) }
        return changes
    }

    private func isOlderSnapshot(_ incoming: CompanionLibrary) -> Bool {
        guard let snapshot, incoming.workspaceID == snapshot.workspaceID else { return false }
        if incoming.updatedAt < snapshot.updatedAt { return true }
        let currentRevisions = Dictionary(((snapshot.newsletters ?? []) + (snapshot.scripts ?? []) + (snapshot.articles ?? [])).compactMap { item in
            item.revisionDate.map { (item.id, $0) }
        }, uniquingKeysWith: max)
        return ((incoming.newsletters ?? []) + (incoming.scripts ?? []) + (incoming.articles ?? [])).contains { item in
            guard let current = currentRevisions[item.id], let incoming = item.revisionDate else { return false }
            return incoming < current
        }
    }

    private func clearSnapshot() {
        state.snapshot = nil
        syncedText = nil
    }

    private func cloud() -> CloudScheduleStore {
        if let store { return store }
        let value = CloudScheduleStore()
        store = value
        return value
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        syncErrorCode = nil
        let revision = accountRevision
        var checkedAccount = false
        defer {
            busy = false
            let refreshAgain = newsletterRefreshPending || revision != accountRevision
            newsletterRefreshPending = false
            if refreshAgain {
                Task { await refresh() }
            } else if !Task.isCancelled {
                lastCheck = .now
            }
        }
        do {
            try loadOutbox()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--unpaired-fixture") { return }
            if ProcessInfo.processInfo.arguments.contains("--library-fixture") {
                account = "fixture"
                if var stale = staleFixtureSnapshot {
                    staleFixtureSnapshot = nil
                    stale.updatedAt = .now
                    _ = try acceptSnapshot(stale, account: "fixture")
                    return
                }
                var fixture = snapshot ?? Self.fixture
                for change in try prepareChanges(in: fixture, account: "fixture").prefix(24 - fixture.pending.count) {
                    try fixture.enqueue(change)
                }
                if ProcessInfo.processInfo.arguments.contains("--quick-x-fixture") {
                    fixture.acknowledge(fixture.pending.filter { $0.quickXAccountKey != nil }
                        .map { .init(id: $0.id, publicationURL: "https://x.com/i/web/status/789") })
                }
                if ProcessInfo.processInfo.arguments.contains("--idea-draft-result-fixture") {
                    let requests = fixture.pending.filter { $0.ideaDraftPlatforms == ["x"] && $0.xFormat == "post" }
                    for change in requests {
                        guard let index = fixture.items.firstIndex(where: { $0.id == change.itemID }) else { continue }
                        let id = change.id.uuidString.lowercased()
                        fixture.items[index].draftedIdeaPlatforms = ["x"]
                        fixture.items[index].draftedIdeaIDs = ["x": id]
                        var draft = CompanionLibrary.Item(id: id, revision: "2026-11-21T12:00:00.000Z", kind: .draft,
                            projectID: fixture.items[index].projectID, title: "Show the unfinished work",
                            body: "Show one trade-off from your work in progress.", shortened: false, platform: "x", status: "ready", notes: [])
                        draft.format = "post"
                        fixture.items.append(draft)
                    }
                    fixture.acknowledge(requests.map { .init(id: $0.id) })
                }
                if ProcessInfo.processInfo.arguments.contains("--idea-first-fixture") {
                    let additions = fixture.pending.filter { $0.action == .addIdea && $0.createsScript != true }
                    for change in additions {
                        fixture.items.insert(.init(id: change.id.uuidString.lowercased(),
                            revision: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)), kind: .idea,
                            projectID: change.itemID, title: change.title, body: change.text,
                            shortened: false, platform: "", status: "draft", notes: []), at: 0)
                    }
                    fixture.acknowledge(additions.map { .init(id: $0.id) })
                }
                if ProcessInfo.processInfo.arguments.contains("--history-fixture") {
                    for change in fixture.pending where change.action == .saveRevision || change.action == .editDraft && change.editsNewsletter != true {
                        guard let index = fixture.items.firstIndex(where: { $0.id == change.itemID }) else { continue }
                        if let history = change.historySnapshot {
                            if fixture.items[index].history?.contains(where: { $0.id == history.id }) != true {
                                fixture.items[index].history = (fixture.items[index].history ?? []) + [history]
                            }
                        } else {
                            let item = fixture.items[index]
                            var updated = CompanionLibrary.Item(id: item.id, revision: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)),
                                kind: item.kind, projectID: item.projectID, title: change.title, body: change.text,
                                shortened: false, platform: item.platform, status: item.status, notes: item.notes, referenceID: item.referenceID)
                            updated.format = change.xFormat ?? item.format
                            updated.history = item.history
                            fixture.items[index] = updated
                        }
                        fixture.results.append(.init(id: change.id))
                    }
                    let completed = Set(fixture.results.map(\.id))
                    fixture.pending.removeAll { completed.contains($0.id) }
                    fixture.updatedAt = .now
                }
                if ProcessInfo.processInfo.arguments.contains("--revision-requests-fixture"),
                   let index = fixture.items.firstIndex(where: { $0.kind == .idea }) {
                    let itemID = fixture.items[index].id
                    let requests = fixture.pending.filter { $0.itemID == itemID && $0.requestsWritingHelp == true }
                    if requests.count >= 2 {
                        fixture.items[index].revisionRequests = requests.map {
                            .init(id: $0.id.uuidString.lowercased(), text: $0.text, date: nil, state: .actedOn)
                        }
                        let ids = Set(requests.map(\.id))
                        fixture.results += requests.map { .init(id: $0.id) }
                        fixture.pending.removeAll { ids.contains($0.id) }
                        fixture.updatedAt = .now
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--script-fixture") {
                    var writing = (fixture.scripts ?? []) + (fixture.articles ?? []) + (fixture.newsletters ?? [])
                    for change in fixture.pending where change.createsScript == true || change.isLongFormEdit || change.action == .saveRevision || change.requestsWritingHelp == true || change.publishesXArticle == true {
                        let id = change.createsScript == true ? change.id.uuidString.lowercased() : change.itemID
                        if let index = writing.firstIndex(where: { $0.id == id }) {
                            let item = writing[index]
                            var updated = CompanionLibrary.Item(id: id, revision: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)), kind: item.kind,
                                projectID: item.projectID, title: change.title.isEmpty ? item.title : change.title,
                                body: change.requestsWritingHelp == true ? "# Local AI models\n\nA short brief explaining how local models run on your own hardware, where they help, and what to test." : change.action == .saveRevision || change.publishesXArticle == true ? item.body : change.text,
                                shortened: false, platform: item.platform, status: change.publishesXArticle == true ? "published" : "draft", notes: change.requestsWritingHelp == true ? item.notes + [change.text] : item.notes, referenceID: item.referenceID)
                            updated.publicationStatus = change.publishesXArticle == true ? "published" : item.publicationStatus
                            updated.publicationURL = change.publishesXArticle == true ? "https://x.com/i/web/status/789" : item.publicationURL
                            updated.history = item.history ?? []
                            updated.noteStates = item.noteStates
                            updated.writingReply = item.writingReply
                            if change.requestsWritingHelp == true { updated.noteStates = Array(repeating: "applied", count: updated.notes.count); updated.writingReply = "Wrote a short brief about local AI models." }
                            if let revision = change.historySnapshot, updated.history?.contains(where: { $0.id == revision.id }) != true {
                                updated.history?.append(revision)
                            }
                            writing[index] = updated
                        } else if change.createsScript == true {
                            writing.append(.init(id: id, revision: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)), kind: mobileWritingKind(change.writingKind),
                                projectID: change.itemID, title: change.title, body: change.text, shortened: false, platform: mobileWritingPlatform(change.writingKind), status: "draft", notes: [], referenceID: "STU–003"))
                        } else { continue }
                        fixture.results.append(.init(id: change.id, newsletterRevision: writing.first { $0.id == id }?.revision))
                    }
                    fixture.scripts = writing.filter { $0.kind == .script }
                    fixture.articles = writing.filter { $0.kind == .article }
                    fixture.newsletters = writing.filter { $0.kind == .newsletter }
                    let completed = Set(fixture.results.map(\.id))
                    fixture.pending.removeAll { completed.contains($0.id) }
                }
                let newsletterEdits = fixture.pending.filter { $0.editsNewsletter == true }
                let exercisesSyncRace = ProcessInfo.processInfo.arguments.contains("--newsletter-sync-race-fixture")
                for change in newsletterEdits {
                    if let index = fixture.newsletters?.firstIndex(where: { $0.id == change.itemID }) {
                        if exercisesSyncRace, let item = fixture.newsletters?[index] {
                            fixture.newsletters?[index] = .init(
                                id: item.id, revision: "2026-11-17T12:00:00.000Z", kind: item.kind,
                                projectID: item.projectID, title: item.title,
                                body: change.text + "\n\nApplied on Mac.\n\n"
                                    + String(repeating: "This text is delivered separately through iCloud. ", count: 12),
                                shortened: false, platform: item.platform, status: item.status, notes: item.notes
                            )
                            fixture.updatedAt = .now
                            staleFixtureSnapshot = snapshot
                        } else {
                            fixture.newsletters?[index].body = change.text
                        }
                    }
                }
                fixture.acknowledge(newsletterEdits.map { .init(id: $0.id) })
                let data = try fixture.separateFullText()
                let completed = try await snapshotWithFullText(fixture) { _ in
                    if exercisesSyncRace && !newsletterEdits.isEmpty { try await Task.sleep(for: .seconds(3)) }
                    guard let data else { throw CompanionScheduleError.changed }
                    return data
                }
                _ = try acceptSnapshot(completed, account: "fixture")
                accountStatus = "Preview data"
                remoteWorkspaceFound = true
                error = nil
                return
            }
#endif
            let cloud = cloud()
            let key = try await cloud.accountKey()
            guard revision == accountRevision else { return }
            checkedAccount = true
            accountStatus = "Connected"
            if account != key {
                clearSnapshot()
                remoteWorkspaceFound = nil
                lastCloudContact = nil
            }
            account = key
            let schedule = try await cloud.load(confirmedAccount: key)
            guard revision == accountRevision else { return }
            lastCloudContact = .now
            remoteWorkspaceFound = schedule != nil
            guard let schedule, schedule.sharing else {
                clearSnapshot()
                error = "Turn on schedule and library sync in Inkspring on your Mac."
                return
            }
            if snapshot?.workspaceID != schedule.workspaceID {
                clearSnapshot()
            }
            let incoming = try await cloud.loadLibrary(workspaceID: schedule.workspaceID, account: key)
            guard revision == accountRevision else { return }
            lastCloudContact = .now
            guard let incoming, incoming.enabled else {
                clearSnapshot()
                error = CompanionLibraryError.disabled.localizedDescription
                return
            }
            error = nil
            guard !isOlderSnapshot(incoming) else { return }
            let completed = try await snapshotWithFullText(incoming) { version in
                try await cloud.loadLibraryText(version, workspaceID: incoming.workspaceID, account: key)
            }
            guard revision == accountRevision else { return }
            let changes = try acceptSnapshot(completed, account: key)
            let ready = Array(changes.prefix(max(0, 24 - incoming.pending.count)))
            if !ready.isEmpty {
                for change in ready where change.mediaDraft != nil {
                    let data = try Data(contentsOf: mediaOutboxURL(change.id), options: .mappedIfSafe)
                    try await cloud.stageLibraryMedia(data, change: change, workspaceID: incoming.workspaceID, account: key)
                }
                _ = try await cloud.updateLibrary(workspaceID: incoming.workspaceID, account: key) { library in
                    for change in ready.prefix(max(0, 24 - library.pending.count)) {
                        do { try library.enqueue(change) }
                        catch CompanionLibraryError.full { break }
                    }
                }
            }
        } catch {
            guard revision == accountRevision else { return }
            let failure = error as NSError
            syncErrorCode = "\(failure.domain) (\(failure.code))"
            if !checkedAccount { accountStatus = "Unavailable" }
            if (error as? CompanionScheduleError) == .accountChanged {
                clearSnapshot()
                account = nil
                accountStatus = "Not checked"
                remoteWorkspaceFound = nil
                lastCloudContact = nil
            }
            self.error = error.localizedDescription
        }
    }

    private func snapshotWithFullText(_ incoming: CompanionLibrary,
                                      loadText: (CompanionLibrary.TextVersion) async throws -> Data) async throws -> CompanionLibrary {
        guard let version = incoming.fullText else {
            syncedText = nil
            return incoming
        }
        let revision = accountRevision
        let data: Data
        if let syncedText, syncedText.workspace == incoming.workspaceID, syncedText.version == version {
            data = syncedText.data
        } else {
            data = try await loadText(version)
        }
        let completed = try await Task.detached(priority: .utility) {
            var completed = incoming
            try completed.applyFullText(data)
            return completed
        }.value
        guard revision == accountRevision else { throw CompanionScheduleError.accountChanged }
        syncedText = (incoming.workspaceID, version, data)
        return completed
    }

    func accountChanged() {
        accountRevision = UUID()
        clearSnapshot()
        account = nil
        accountStatus = "Not checked"
        remoteWorkspaceFound = nil
        lastCheck = nil
        lastCloudContact = nil
        syncErrorCode = nil
    }

#if DEBUG
    private static var fixture: CompanionLibrary {
        let fixtureID = ProcessInfo.processInfo.environment["INKSPRING_FIXTURE_ID"].flatMap(UUID.init(uuidString:))
        var value = CompanionLibrary(workspaceID: fixtureID ?? UUID(uuidString: "de6b0e64-2e7a-4bc6-a4b2-79a3e63b8e1a")!)
        value.projects = [.init(id: "studio", name: "Studio")]
        value.items = [
            .init(id: "draft", revision: "2026-11-16T12:00:00.000Z", kind: .draft, projectID: "studio", title: "A quieter way to draft",
                  body: "Start with the decision you made and why it mattered. One concrete example is enough.",
                  shortened: false, platform: "linkedin", status: "ready", notes: [], attachment: .video, referenceID: "STU-001"),
            .init(id: "idea", revision: "1", kind: .idea, projectID: "studio", title: "Show the unfinished work",
                  body: "Explain a trade-off from a work in progress and ask readers how they would handle it.",
                  shortened: false, platform: "", status: "draft", notes: [])
        ]
        value.supportsDraftEdits = true
        value.supportsNewsletterEdits = true
        if ProcessInfo.processInfo.arguments.contains("--newsletter-offline-fixture") {
            value.supportsNewsletterEdits = nil
        }
        value.supportsItemManagement = true
        value.supportsXThreads = true
        value.supportsXParagraphs = true
        value.supportsRevisionHistory = true
        value.supportsContentPlans = true
        value.supportsClaudeIdeaDrafts = !ProcessInfo.processInfo.arguments.contains("--old-idea-draft-mac-fixture")
        value.supportsMediaDrafts = true
        if ProcessInfo.processInfo.arguments.contains("--quick-x-fixture") {
            value.supportsQuickXPost = true
            value.xArticleAccountKey = "fixture:connected"
            value.xArticleAccountName = "@fixture"
        }
        if ProcessInfo.processInfo.arguments.contains("--x-thread-fixture") {
            var draft = CompanionLibrary.Item(id: "x-followup-demo", revision: "2026-11-18T16:00:00.000Z", kind: .draft,
                projectID: "studio", title: "I started a cult", body: ["We build useful tools and give them away.", "Read more: https://newsletter.protomota.com/", "Join us: https://protomota.com/discord"].joined(separator: XThreadText.separator),
                shortened: false, platform: "x", status: "draft", notes: [], referenceID: "STU-003")
            if ProcessInfo.processInfo.arguments.contains("--article-link-fixture") {
                value.supportsXReplyArticles = true
                value.articles = [.init(id: "linked-article", revision: draft.revision, kind: .article, projectID: "studio",
                    title: "The manifesto", body: "# Our mission\n\nWe build useful tools together.", shortened: false,
                    platform: "x", status: "draft", notes: [], referenceID: "STU-004")]
                var posts = XThreadText.posts(in: draft.body)
                posts.insert(XReplyArticle.attach("STU-004", to: "Read the full manifesto on X."), at: 1)
                draft.body = posts.joined(separator: XThreadText.separator)
            }
            draft.format = "thread"
            value.items.insert(draft, at: 0)
        }
        if ProcessInfo.processInfo.arguments.contains("--script-fixture") {
            value.supportsScripts = true
            value.supportsWritingTools = true
            value.supportsAgentFeatures = !ProcessInfo.processInfo.arguments.contains("--no-mcp-fixture")
            value.supportsXArticlePublishing = true
            value.xArticleAccountKey = "fixture:connected"
            value.xArticleAccountName = "@fixture"
            value.writingAgent = "codex"
            value.scripts = [.init(id: "script-example", revision: "2026-11-19T12:00:00.000Z", kind: .script,
                projectID: "studio", title: "I started a cult — YouTube script",
                body: "We build real skills.\n\nWe protect our signal.\n\n" + String(repeating: "We learn by building and testing useful tools.\n\n", count: 50) + "End of the hallway script.",
                shortened: false, platform: "youtube", status: "draft", notes: [], referenceID: "STU–003")]
        }
        if ProcessInfo.processInfo.arguments.contains("--newsletter-fixture") {
            value.newsletters = [
                .init(id: "newsletter-draft", revision: "2026-11-16T12:00:00.000Z", kind: .newsletter,
                      projectID: "studio", title: "A better first paragraph", body: """
                      ## Start with a detail

                      Give the reader **one thing** they can picture.

                      - Open with an example.
                      - Keep the first sentence short.

                      [Visit Inkspring](https://inkspring.ai/)
                      """,
                      shortened: false, platform: "substack", status: "draft", notes: [], referenceID: "STU-002"),
                .init(id: "newsletter-published", revision: "2026-11-15T12:00:00.000Z", kind: .newsletter,
                      projectID: "studio", title: "Notes from the studio", body: "What changed after a week of testing.",
                      shortened: false, platform: "substack", status: "published", notes: [], referenceID: "STU-003")
            ]
        }
        if ProcessInfo.processInfo.arguments.contains("--existing-writing-fixture") {
            let revision = "2026-11-19T12:00:00.000Z"
            value.articles = [.init(id: "article-fixture", revision: revision, kind: .article, projectID: "studio",
                title: "Untitled X article", body: "", shortened: false, platform: "x", status: "draft", notes: [])]
            value.scripts = [.init(id: "script-fixture", revision: revision, kind: .script, projectID: "studio",
                title: "Untitled YouTube script", body: "", shortened: false, platform: "youtube", status: "draft", notes: [])]
            value.newsletters = [.init(id: "newsletter-fixture", revision: revision, kind: .newsletter, projectID: "studio",
                title: "Untitled newsletter", body: "", shortened: false, platform: "substack", status: "draft", notes: [])]
        }
        if ProcessInfo.processInfo.arguments.contains("--project-filter-fixture") {
            value.projects.append(.init(id: "field-notes", name: "Field Notes"))
            value.items.append(.init(id: "field-draft", revision: "1", kind: .draft, projectID: "field-notes",
                                     title: "What we learned in the field", body: "Lead with one example.",
                                     shortened: false, platform: "linkedin", status: "draft", notes: []))
            value.newsletters?.append(.init(id: "field-newsletter", revision: "1", kind: .newsletter, projectID: "field-notes",
                                           title: "A dispatch from the field", body: "One idea worth sharing.",
                                           shortened: false, platform: "substack", status: "draft", notes: []))
        }
        if ProcessInfo.processInfo.arguments.contains("--full-text-fixture") {
            let paragraphs = String(repeating: "A complete paragraph stays in the library when contents sync through iCloud.\n\n", count: 126)
            value.items.append(.init(id: "full-post", revision: "1", kind: .draft, projectID: "studio",
                                     title: "Long post with complete text", body: paragraphs + "End of the complete post.",
                                     shortened: false, platform: "linkedin", status: "draft", notes: []))
            value.newsletters = [.init(id: "full-newsletter", revision: "1", kind: .newsletter, projectID: "studio",
                                       title: "Long newsletter with complete text", body: paragraphs + "End of the complete newsletter.",
                                       shortened: false, platform: "substack", status: "draft", notes: [])]
        }
        value.postingWindows = ["linkedin": .init(), "reddit": .init()]
        value.postingTimeZone = TimeZone.current.identifier
        if ProcessInfo.processInfo.arguments.contains("--editing-fixture") {
            value.items.insert(.init(id: "long-draft", revision: "2026-11-15T12:00:00.000Z", kind: .draft, projectID: "studio",
                title: "I built a free AI transcription and notes app for Mac, iPhone and iPad that runs on-device with Apple Intelligence. No account, no subscription.",
                body: "I'm a solo developer, and I built Jotley for Mac, iPhone and iPad.\n\n" + String(repeating: "Your recordings, transcripts and notes stay on your device. Review the transcript, edit the summary and keep the details that matter.\n\n", count: 8),
                shortened: false, platform: "reddit", status: "draft", notes: [], attachment: .image), at: 0)
            var trashed = CompanionLibrary.Item(id: "trashed-example", revision: "1", kind: .draft, projectID: "studio",
                title: "What we changed after the first demo",
                body: "Our first PulseCanvas demo opened with the export settings. For the second cut, we started with eight bars of music so viewers could hear the beat and see the visual respond before we showed the controls.",
                shortened: false, platform: "linkedin", status: "draft", notes: ["Try a shorter introduction."])
            trashed.isTrashed = true
            value.items.append(trashed)
        }
        return value
    }
#endif
}

private struct MobileNewsletterDetail: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    let item: CompanionLibrary.Item
    let metadata: String
    let library: MobileLibrary
    let workspaceID: UUID
    @State private var showsOutline = false
    @State private var editingRevision: String?
    @State private var editingBaseMarkdown = ""
    @State private var confirmsArticlePublication = false
    @State private var showsWritingTools = false
    @State private var scriptTitle = ""
    @State private var baseScriptTitle = ""
    @State private var findRequest = 0
    @State private var markdown = ""
    @State private var saveError: String?
    @State private var showsMacVersion = false
    @State private var recoveryKey: String?

    private var pendingEdit: CompanionLibraryOutbox.Entry? {
        library.pendingChanges(for: item.id).last { $0.isLongFormEdit }
    }

    private var canEdit: Bool {
        !showsMacVersion && hasFullText && ["draft", "synced"].contains(item.status)
    }

    private var hasFullText: Bool {
        !item.shortened || (pendingEdit != nil && pendingEdit?.error == nil)
    }

    private var previewMarkdown: String {
        if let pendingEdit, pendingEdit.error == nil, !showsMacVersion { return pendingEdit.text }
        return item.body
    }

    var body: some View {
        if showsOutline {
            MobilePlanSection(item: item, library: library, workspaceID: workspaceID) { showsOutline = false }
        } else {
            document
        }
    }

    private var document: some View {
        Group {
            if editingRevision != nil {
                VStack(alignment: .leading, spacing: 12) {
                    if item.isLongForm {
                        TextField(item.kind == .newsletter ? "Newsletter title" : item.kind == .article ? "Article title" : "Script title", text: $scriptTitle)
                            .textFieldStyle(.plain).font(.headline)
                            .accessibilityIdentifier("script.title")
                    }
                    MobileWritingTextView(text: $markdown, identifier: "newsletter.markdown", findRequest: findRequest, monospaced: true, onFocusLost: { save() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .studioSurface()
                    if let saveError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(saveError).font(.footnote).foregroundStyle(palette.danger)
                            Button("Copy unsaved Markdown", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = markdown
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metadataHeader
                        if item.kind == .article, item.reviewPlatform == "x-article" { articlePublishing }
                        Divider()
                        if !hasFullText || (showsMacVersion && item.shortened) {
                            Text("Waiting for the full text to sync.").font(.footnote).foregroundStyle(palette.muted)
                        } else {
                            Group {
                                if previewMarkdown.isEmpty {
                                    Text(item.kind == .article ? "No article text yet. Double-tap to start writing." : item.kind == .script ? "No script text yet. Double-tap to start writing." : "No newsletter text yet.").foregroundStyle(palette.muted)
                                } else {
                                    MobileNewsletterMarkdown(markdown: previewMarkdown).equatable()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture(count: 2).onEnded { beginEditing() })
                        }
                        if !library.planText(item).isEmpty {
                            Button("View outline", systemImage: "list.bullet.clipboard") { showsOutline = true }
                                .font(.callout)
                                .accessibilityIdentifier("outline.view")
                        }
                        if let pendingEdit {
                            if let error = pendingEdit.error {
                                Text(error).font(.footnote).foregroundStyle(palette.danger)
                                Button("Copy unsynced Markdown", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = pendingEdit.text
                                }
                            } else {
                                let status = library.newsletterSyncStatus(for: pendingEdit)
                                Text(syncMessage(status)).font(.footnote).foregroundStyle(palette.muted)
                                if pendingEdit.revision != item.revision && !item.shortened {
                                    Button(showsMacVersion ? "Show saved mobile edit" : "Show version from Mac") {
                                        showsMacVersion.toggle()
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioSurface()
                    .padding(16)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("newsletter.preview")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(palette.iconAccent)
        .toolbar(editingRevision == nil ? .visible : .hidden, for: .tabBar)
        .navigationTitle(item.kind == .newsletter ? "Newsletter" : reviewPlatformName(item.reviewPlatform == "youtube" ? "youtube-script" : item.reviewPlatform))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: markdown + "\0" + scriptTitle) {
            guard let editingRevision, let recoveryKey, markdown != editingBaseMarkdown || scriptTitle != baseScriptTitle else { return }
            library.storeNewsletterRecovery(.init(revision: editingRevision, base: editingBaseMarkdown, markdown: markdown, title: scriptTitle, baseTitle: baseScriptTitle),
                                            key: recoveryKey)
        }
        .task(id: markdown + "\0" + scriptTitle) {
            guard editingRevision != nil, markdown != editingBaseMarkdown || scriptTitle != baseScriptTitle else { return }
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch { return }
            save()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
        .onDisappear { save() }
        .onChange(of: item.revision) {
            guard editingRevision != nil, markdown == editingBaseMarkdown, scriptTitle == baseScriptTitle, pendingEdit == nil,
                  item.revisionDate != nil else { return }
            markdown = item.body
            editingBaseMarkdown = item.body
            scriptTitle = item.title
            baseScriptTitle = item.title
            editingRevision = item.revision
        }
        .onChange(of: pendingEdit?.id) {
            if pendingEdit == nil { showsMacVersion = false }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editingRevision != nil {
                    Button("Find", systemImage: "magnifyingglass") { findRequest += 1 }
                        .accessibilityIdentifier("editor.find")
                    if library.canUseAgentFeatures {
                        MobileWritingTools(title: $scriptTitle, text: $markdown, presented: $showsWritingTools,
                            agent: library.snapshot?.writingAgent ?? "agent", requests: writingRequests, reply: item.writingReply, error: item.writingError) { prompt in
                                save()
                                guard saveError == nil else { throw CompanionLibraryError.invalid }
                                try library.saveChange(.init(action: .note, itemID: item.id, revision: editingRevision ?? item.revision,
                                    text: prompt, requestsWritingHelp: true), workspaceID: workspaceID)
                            }
                    }
                    Button("Done") { save(ending: true) }.fontWeight(.semibold)
                } else {
                    Menu {
                        if ["draft", "synced"].contains(item.status) {
                            Button("Edit Markdown", systemImage: "pencil", action: beginEditing).disabled(!canEdit)
                            if library.canUseAgentFeatures {
                                Button("Ask AI…", systemImage: "bubble.left.and.text.bubble.right") { beginEditing(); showsWritingTools = true }.disabled(!canEdit)
                            }
                        }
                        if library.snapshot?.supportsContentPlans == true && item.isTrashed != true {
                            Button(library.planText(item).isEmpty ? "Add outline" : "View outline", systemImage: "list.bullet.clipboard") { showsOutline = true }
                            .accessibilityIdentifier("outline.menu")
                        }
                        Button("Copy Markdown", systemImage: "doc.on.doc") { UIPasteboard.general.string = previewMarkdown }
                            .disabled(!hasFullText || previewMarkdown.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("newsletter.more")
                }
            }
        }
    }

    private var articlePublishing: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let raw = item.publicationURL, let url = URL(string: raw), url.scheme == "https", url.host == "x.com" {
                Link("View published X article", destination: url)
            } else if item.status == "published" || item.status == "uncertain" || item.status == "publishing" {
                Text(item.status == "uncertain" ? "X hasn’t confirmed publication. Check X Articles on your Mac before retrying." : "Publishing to X…")
                    .font(.footnote)
            } else if library.pendingChanges(for: item.id).contains(where: { $0.publishesXArticle == true }) || item.publicationStatus == "queued" {
                Text("Publishing request saved. Your Mac will publish while Inkspring is open.").font(.footnote)
            } else {
                Button("Review & publish on X…", systemImage: "paperplane") { confirmsArticlePublication = true }
                    .disabled(!hasFullText || item.body.isEmpty || pendingEdit != nil || library.snapshot?.supportsXArticlePublishing != true || library.snapshot?.xArticleAccountKey == nil)
                    .accessibilityIdentifier("article.reviewPublish")
                Text(library.snapshot?.xArticleAccountKey == nil ? "Connect X in Inkspring on your Mac to publish Articles." : "Your Mac publishes the full article to X while Inkspring is open. Requires X Article access and API credits.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }
            if let error = item.publicationError, !error.isEmpty { Text(error).font(.footnote).foregroundStyle(palette.muted) }
        }
        .confirmationDialog("Publish this X article?", isPresented: $confirmsArticlePublication, titleVisibility: .visible) {
            Button("Publish article now") {
                do {
                    try library.saveChange(.init(action: .note, itemID: item.id, revision: item.revision,
                        text: "Publish X article", publishesXArticle: true, xArticleAccountKey: library.snapshot?.xArticleAccountKey), workspaceID: workspaceID)
                } catch { saveError = error.localizedDescription }
            }.accessibilityIdentifier("article.publish")
        } message: {
            Text("Publish “\(item.title)” publicly as \(library.snapshot?.xArticleAccountName ?? "your connected X account")? Your Mac must be awake with Inkspring open.")
        }
    }

    private var writingRequests: [StudioWritingRequest] {
        library.revisionRequests(for: item)
    }

    private func syncMessage(_ status: MobileLibrary.NewsletterSyncStatus) -> String {
        switch status {
        case .needsMacUpdate: "Saved on this device. Open the latest Inkspring on your Mac to sync this edit."
        case .waitingForMac: "Sent to iCloud. Waiting for Inkspring on your Mac to apply the edit."
        case .savedOnDevice: "Saved on this device. Waiting to upload to iCloud."
        case .needsReview: "Your mobile edit is saved on this device."
        }
    }

    private var metadataHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.isLongForm && pendingEdit?.title.isEmpty == false || pendingEdit?.restoresRevision == true ? pendingEdit?.title ?? item.title : item.title)
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StudioPlatformLabel(name: item.platform, title: reviewPlatformName(item.reviewPlatform))
                Text("·").accessibilityHidden(true)
                Text(metadata)
            }
            .font(.footnote)
            .foregroundStyle(palette.muted)
            if let reference = item.referenceID {
                StudioCopyReference(reference: reference)
            }
            if let updatedAt = item.revisionDate {
                Text("Last updated \(updatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .accessibilityIdentifier("newsletter.lastUpdated")
            }
            NavigationLink {
                MobileRevisionHistory(item: item, library: library, workspaceID: workspaceID)
            } label: { Label("Revision history", systemImage: "clock.arrow.circlepath") }
            .accessibilityIdentifier("history.open")
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginEditing() {
        guard canEdit, editingRevision == nil else { return }
        recoveryKey = library.newsletterRecoveryKey(for: item.id, workspaceID: workspaceID)
        let recovery = recoveryKey.flatMap { library.recoverNewsletterEdit(key: $0) }
        editingBaseMarkdown = recovery?.base ?? previewMarkdown
        markdown = recovery?.markdown ?? editingBaseMarkdown
        scriptTitle = recovery?.title ?? (pendingEdit?.title.isEmpty == false ? pendingEdit?.title ?? item.title : item.title)
        baseScriptTitle = recovery?.baseTitle ?? (pendingEdit?.title.isEmpty == false ? pendingEdit?.title ?? item.title : item.title)
        editingRevision = recovery?.revision ?? item.revision
    }

    private func endEditing() {
        editingRevision = nil
        saveError = nil
        recoveryKey = nil
    }

    private func save(ending: Bool = false) {
        guard let editingRevision else { return }
        if markdown == editingBaseMarkdown && scriptTitle == baseScriptTitle {
            if let recoveryKey { library.storeNewsletterRecovery(nil, key: recoveryKey) }
            if ending { endEditing() }
            return
        }
        do {
            var edit = CompanionLibrary.Change(action: .editDraft, itemID: item.id, revision: editingRevision, title: [.script, .article].contains(item.kind) || scriptTitle != baseScriptTitle ? scriptTitle : "",
                                                text: markdown, editsNewsletter: item.kind == .newsletter ? true : nil, baseNewsletterText: editingBaseMarkdown, editsScript: [.script, .article].contains(item.kind) ? true : nil, baseScriptTitle: [.script, .article].contains(item.kind) || scriptTitle != baseScriptTitle ? baseScriptTitle : nil, writingKind: item.kind == .article ? "article" : nil)
            if !edit.valid || (try? JSONEncoder().encode(edit).count).map({ $0 > edit.payloadLimit }) == true {
                edit = .init(id: edit.id, action: edit.action, itemID: edit.itemID, revision: edit.revision, title: edit.title,
                             text: edit.text, editsNewsletter: item.kind == .newsletter ? true : nil, editsScript: [.script, .article].contains(item.kind) ? true : nil, baseScriptTitle: [.script, .article].contains(item.kind) || scriptTitle != baseScriptTitle ? baseScriptTitle : nil, writingKind: item.kind == .article ? "article" : nil)
            }
            try library.saveChange(edit, workspaceID: workspaceID)
            showsMacVersion = false
            editingBaseMarkdown = markdown
            baseScriptTitle = scriptTitle
            if let recoveryKey { library.storeNewsletterRecovery(nil, key: recoveryKey) }
            saveError = nil
            if ending { endEditing() }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct MobileNewsletterMarkdown: View, Equatable {
    @Environment(\.studioPalette) private var palette
    let markdown: String

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.markdown == rhs.markdown }

    private struct Block: Identifiable {
        let id: Int
        let kind: PresentationIntent.Kind
        let quote: Bool
        let listDepth: Int
        let marker: String?
        var text: AttributedString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.parse(markdown)) { block in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let marker = block.marker {
                        Text(marker).foregroundStyle(palette.muted).accessibilityHidden(true)
                    }
                    blockContent(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(block.listDepth) * 16 + (block.quote ? 12 : 0))
                .overlay(alignment: .leading) {
                    if block.quote { Rectangle().fill(palette.line).frame(width: 2) }
                }
            }
        }
        .foregroundStyle(palette.text)
    }

    @ViewBuilder private func blockContent(_ block: Block) -> some View {
        switch block.kind {
        case .header(let level):
            Text(block.text)
                .font((level == 1 ? Font.title : level == 2 ? .title2 : .headline).bold())
                .accessibilityAddTraits(.isHeader)
        case .codeBlock:
            Text(block.text).font(.system(.callout, design: .monospaced))
                .padding(10).studioSurface(StudioRadius.control, fill: palette.well)
        case .thematicBreak:
            Divider()
        default:
            Text(block.text).font(.body)
        }
    }

    private static func parse(_ markdown: String) -> [Block] {
        guard let attributed = try? AttributedString(markdown: markdown, options: .init(failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return [.init(id: 0, kind: .paragraph, quote: false, listDepth: 0, marker: nil, text: AttributedString(markdown))]
        }
        var result: [Block] = []
        var seenListItems: Set<Int> = []
        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var text = AttributedString(attributed[run.range])
            text.presentationIntent = nil
            if let url = run.link {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    text.underlineStyle = .single
                } else {
                    text.link = nil
                }
            }
            if run.inlinePresentationIntent?.contains(.code) == true { text.font = .system(.body, design: .monospaced) }
            if result.last?.id == id {
                result[result.count - 1].text.append(text)
                continue
            }
            let quote = components.contains { $0.kind == .blockQuote }
            let listDepth = components.count { $0.kind == .orderedList || $0.kind == .unorderedList }
            let listPosition = components.firstIndex { if case .listItem = $0.kind { true } else { false } }
            var marker: String?
            if let listPosition, case .listItem(let ordinal) = components[listPosition].kind,
               seenListItems.insert(components[listPosition].identity).inserted {
                marker = components.dropFirst(listPosition + 1).first?.kind == .orderedList ? "\(ordinal)." : "•"
            }
            result.append(.init(id: id, kind: components.first?.kind ?? .paragraph, quote: quote,
                                listDepth: max(0, listDepth - (marker == nil ? 0 : 1)), marker: marker, text: text))
        }
        return result
    }
}

struct MobileReviewView: View {
    @Environment(\.mobileWideLayout) private var wideLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let library: MobileLibrary
    let isSelected: Bool
    let writeIdea: () -> Void
    let openSetup: () -> Void
    let openSettings: () -> Void
    @Environment(\.studioPalette) private var palette
    @State private var selection: String?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var filter = "Drafts"
    @State private var platformFilter: String?
    @State private var projectFilter: String?
    @AppStorage("inkspring.mobile.draftSort") private var draftSort = DraftSort.lastUpdated
    @State private var editItem: CompanionLibrary.Item?
    @State private var deleteItem: CompanionLibrary.Item?
    @State private var actionError: String?
    @State private var draftingIdea = false
    @State private var quickXPost = false
    @State private var askingInkspring = false

    private static let filters = ["Drafts", "Ideas", "Trash"]

    private enum DraftSort: String, CaseIterable {
        case lastUpdated = "Last updated"
        case oldestUpdate = "Oldest update"
        case title = "Title A–Z"

        func sorted(_ items: [CompanionLibrary.Item]) -> [CompanionLibrary.Item] {
            if self == .title {
                return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            return items.map { (item: $0, date: $0.revisionDate) }
                .sorted { lhs, rhs in
                    guard let lhsDate = lhs.date else { return false }
                    guard let rhsDate = rhs.date else { return true }
                    return self == .lastUpdated ? lhsDate > rhsDate : lhsDate < rhsDate
                }
                .map(\.item)
        }
    }

    private var drafts: [CompanionLibrary.Item] {
        let posts = library.visibleItems.filter { $0.kind == .draft && $0.isTrashed != true }
        return (posts + (library.snapshot?.newsletters ?? []) + library.visibleScripts).filter {
            $0.status != "published" && $0.status != "posted"
                && ($0.kind != .article || ($0.publicationURL ?? "").isEmpty)
        }
    }

    private var platformOptions: [String] {
        var platforms = Set(drafts.map(\.reviewPlatform).filter { !$0.isEmpty })
        platforms.insert("substack")
        platforms.insert("youtube")
        platforms.insert("x-article")
        if let platformFilter { platforms.insert(platformFilter) }
        return platforms.sorted { reviewPlatformName($0).localizedStandardCompare(reviewPlatformName($1)) == .orderedAscending }
    }

    private var projectOptions: [CompanionLibrary.Project] {
        (library.snapshot?.projects ?? []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var items: [CompanionLibrary.Item] {
        switch filter {
        case "Drafts":
            return draftSort.sorted(drafts.filter { item in
                (projectFilter == nil || item.projectID == projectFilter) &&
                    (platformFilter == nil || item.reviewPlatform == platformFilter)
            })
        case "Trash": return library.visibleItems.filter { $0.isTrashed == true }
        default: return library.visibleItems.filter { $0.isTrashed != true && $0.kind == .idea }
        }
    }

    private var emptyMessage: String {
        if filter == "Trash" { return "Trash is empty." }
        if filter == "Drafts", platformFilter == "substack" {
            if library.snapshot?.newsletters == nil { return "Update Inkspring on your Mac to sync newsletters." }
            return projectFilter == nil ? "No Substack newsletters in your workspace." : "No Substack newsletters in this project."
        }
        if filter == "Drafts", projectFilter != nil { return "No matching drafts in this project." }
        if filter == "Drafts", let platformFilter { return "No \(reviewPlatformName(platformFilter)) drafts to review." }
        return "No \(filter.lowercased()) to review."
    }

    var body: some View {
        if library.snapshot == nil {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(palette.iconAccent)
                        Text("Your writing workspace").font(.title2.bold())
                        Text("Your drafts will appear here when your Mac library syncs. In the meantime, you can save ideas on this device.")
                            .foregroundStyle(palette.muted)
                        Button("Write an idea", systemImage: "square.and.pencil", action: writeIdea)
                            .buttonStyle(MobilePrimaryActionStyle(fillsWidth: false))
                        Button("Mac setup guide", systemImage: "desktopcomputer", action: openSetup)
                        Button("Check sync in Settings", systemImage: "icloud", action: openSettings)
                    }.frame(maxWidth: 480, alignment: .leading).padding(24)
                        .frame(maxWidth: .infinity, alignment: .center)
                }.mobileCanvas().mobilePageTitle("Review", wide: wideLayout, background: palette.canvas)
                    .toolbar(wideLayout ? .hidden : .visible, for: .tabBar)
            }
        } else if askingInkspring { assistantView }
        else {
            reviewWithIdeaComposer
                .sheet(isPresented: $quickXPost) {
                    NavigationStack { MobileQuickXComposer(library: library, preferredProject: projectFilter) }
                }
        }
    }

    @ViewBuilder private var reviewWithIdeaComposer: some View {
        if wideLayout {
            reviewBody.fullScreenCover(isPresented: $draftingIdea, onDismiss: showCreatedIdea) { newIdeaComposer }
        } else {
            reviewBody.sheet(isPresented: $draftingIdea, onDismiss: showCreatedIdea) { newIdeaComposer }
        }
    }

    private var newIdeaComposer: some View {
        MobileIdeasView(library: library, isSelected: true, initialProject: projectFilter) { id in
            newIdeaID = id
            draftingIdea = false
        }
    }

    private var assistantView: some View {
                InkspringAssistantChat(workspaceID: library.planRecoveryID("assistant", workspaceID: library.snapshot?.workspaceID ?? UUID()),
                                       items: { library.assistantContents }, execute: library.executeAssistant,
                                       open: { id in selection = id; askingInkspring = false }, back: { askingInkspring = false },
                                       readPlan: { id in
                    guard let item = ((library.snapshot?.items ?? []) + (library.snapshot?.newsletters ?? [])).first(where: { $0.id == id }) else { return nil }
                    return library.planText(item)
                }, applyPlan: { id, text, base in
                    guard let snapshot = library.snapshot,
                          let item = (snapshot.items + (snapshot.newsletters ?? [])).first(where: { $0.id == id }) else { throw CompanionScheduleError.changed }
                    try library.savePlan(text, base: base, item: item, workspaceID: snapshot.workspaceID)
                    return .init(message: "Plan saved on this device. Waiting for your Mac to apply it.", itemID: id)
                })
    }

    private var reviewBody: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            Group {
                if let snapshot = library.snapshot {
                    List(selection: $selection) {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                reviewFilters
                                if filter == "Drafts" { draftFilters }
                            }
                            .listRowBackground(Color.clear)
                        }
                        Section {
                            if filter == "Drafts" {
                                ForEach(library.pendingQuickXPosts) { request in
                                    Label(request.error ?? "Quick X post queued for your Mac.",
                                          systemImage: request.error == nil ? "clock" : "exclamationmark.icloud")
                                        .font(.footnote)
                                        .listRowBackground(palette.card)
                                }
                                ForEach(library.pendingMediaDrafts) { request in
                                    if let media = request.mediaDraft, (projectFilter == nil || request.itemID == projectFilter),
                                       (platformFilter == nil || media.platform == platformFilter) {
                                        Label(request.error ?? "\(reviewPlatformName(media.platform)) draft queued for your Mac.",
                                              systemImage: request.error == nil ? "clock" : "exclamationmark.icloud")
                                            .font(.footnote)
                                            .listRowBackground(palette.card)
                                    }
                                }
                            }
                            if items.isEmpty {
                                Text(emptyMessage)
                                    .foregroundStyle(.secondary)
                                    .listRowBackground(palette.card)
                            }
                            ForEach(items) { item in reviewRow(item, in: snapshot) }
                            if filter == "Drafts", platformFilter == "substack", snapshot.hasMoreNewsletters == true {
                                Text("Open Inkspring on Mac to see the rest of your newsletters.")
                                    .font(.footnote).foregroundStyle(palette.muted)
                            }
                        }
                        .listRowBackground(palette.card)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .listSectionSpacing(.compact)

                }
            }
            .mobileCanvas()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(wideLayout ? .inline : .automatic)
            .toolbar(wideLayout ? .hidden : .visible, for: .tabBar)
            .refreshable { await library.refresh() }
            .toolbar {
                ideaToolbarItem
                ToolbarItem(placement: .topBarTrailing) {
                    Button { askingInkspring = true } label: {
                        Label("Ask Inkspring", systemImage: "sparkles").labelStyle(.titleAndIcon)
                    }
                    .accessibilityIdentifier("assistant.open")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { quickXPost = true } label: {
                        PlatformMark(name: "x", fallback: "paperplane").frame(width: 18, height: 18)
                    }
                    .accessibilityLabel("Quick X post")
                    .accessibilityIdentifier("quickX.open")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                        .disabled(library.busy)
                }
            }
        } detail: {
            Group {
                if let snapshot = library.snapshot, let item = items.first(where: { $0.id == selection }) {
                    if item.isLongForm {
                        MobileNewsletterDetail(item: item, metadata: [projectName(item, in: snapshot), status(item)]
                            .joined(separator: " · "), library: library, workspaceID: snapshot.workspaceID)
                            .id("\(snapshot.workspaceID)-\(item.id)")
                    } else {
                        MobileReviewDetail(item: item, library: library, workspaceID: snapshot.workspaceID)
                            .id("\(snapshot.workspaceID)-\(item.id)")
                    }
                } else if library.snapshot != nil && items.isEmpty {
                    if filter == "Trash" {
                        ContentUnavailableView("Trash is empty", systemImage: "trash")
                    } else {
                        ContentUnavailableView(emptyMessage, systemImage: "doc.text")
                    }
                } else {
                    Color.clear
                }
            }
            .mobileCanvas()
        }
        .onChange(of: items.map(\.id), initial: true) { _, _ in updateSelection() }
        .onChange(of: wideLayout) { _, _ in updateSelection() }
        .onChange(of: library.snapshot?.workspaceID) { _, _ in projectFilter = nil }
        .onChange(of: projectOptions.map(\.id)) { _, ids in
            if let projectFilter, !ids.contains(projectFilter) { self.projectFilter = nil }
        }
        .navigationDestination(isPresented: Binding(get: { editItem != nil }, set: { if !$0 { editItem = nil } })) {
            if let item = editItem, let snapshot = library.snapshot {
                MobileItemEditor(item: item, library: library, workspaceID: snapshot.workspaceID)
            }
        }
        .modifier(MobilePermanentDeletionConfirmation(
            isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }),
            message: "This cannot be undone. Linked posts and media files are kept.",
            remove: removeSelectedItem
        ))
        .alert("Couldn't save the change", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .modifier(InkspringRatingPrompt(isIdle: isSelected && selection == nil && !library.busy && library.snapshot != nil))
    }

    private var draftFilters: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: wideLayout ? 6 : 8))
        return layout {
            platformMenu
            projectMenu
            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort drafts", selection: $draftSort) {
                ForEach(DraftSort.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel("Sort", icon: "arrow.up.arrow.down", isFiltered: draftSort != .lastUpdated)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort drafts")
        .accessibilityValue(draftSort.rawValue)
        .accessibilityIdentifier("review.draftSort")
    }

    private var platformMenu: some View {
        let title = platformFilter.map(reviewPlatformName) ?? "All platforms"
        return Menu {
            Picker("Platform", selection: $platformFilter) {
                Label("All platforms", systemImage: "line.3.horizontal.decrease").tag(nil as String?)
                ForEach(platformOptions, id: \.self) { platform in
                    Label {
                        Text(reviewPlatformName(platform))
                    } icon: {
                        platformMenuIcon(platform)
                    }
                    .tag(Optional(platform))
                }
            }
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel(title, icon: "line.3.horizontal.decrease", isFiltered: platformFilter != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by platform")
        .accessibilityValue(title)
        .accessibilityIdentifier("review.platformFilter")
    }

    private var projectMenu: some View {
        let title = projectOptions.first { $0.id == projectFilter }?.name ?? "All projects"
        return Menu {
            Picker("Project", selection: $projectFilter) {
                Label("All projects", systemImage: "folder").tag(nil as String?)
                ForEach(projectOptions) { project in
                    Label(project.name, systemImage: "folder").tag(Optional(project.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel(title, icon: "folder", isFiltered: projectFilter != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by project")
        .accessibilityValue(title)
        .accessibilityIdentifier("review.projectFilter")
    }

    private func filterMenuLabel(_ title: String, icon: String, isFiltered: Bool) -> some View {
        let compact = !dynamicTypeSize.isAccessibilitySize
        return HStack(spacing: compact ? 4 : 7) {
            Image(systemName: icon)
                .foregroundStyle(palette.iconAccent)
            Text(title).foregroundStyle(palette.text).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.muted)
        }
        .font((compact ? Font.caption : .subheadline).weight(.medium))
        .padding(.horizontal, compact ? 7 : 12)
        .padding(.vertical, 7)
        .background(isFiltered ? palette.active : palette.control, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.line).allowsHitTesting(false) }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @State private var newIdeaID: String?

    @ToolbarContentBuilder private var ideaToolbarItem: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarTrailing) { StudioNewIdeaButton { draftingIdea = true } }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { StudioNewIdeaButton { draftingIdea = true } }
        }
    }

    private func showCreatedIdea() {
        guard let id = newIdeaID else { return }
        filter = "Ideas"
        selection = id
        compactColumn = .detail
        newIdeaID = nil
    }

    @ViewBuilder private func reviewRow(_ item: CompanionLibrary.Item, in snapshot: CompanionLibrary) -> some View {
        let selected = wideLayout && selection == item.id
        let showsProjectStatus = filter != "Drafts" || item.isLongForm
        let showsPlatform = !item.reviewPlatform.isEmpty
        NavigationLink(value: item.id) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline).foregroundStyle(palette.text)
                        .lineLimit(wideLayout ? 3 : nil)
                    if showsPlatform || showsProjectStatus {
                        HStack(spacing: 5) {
                            if showsPlatform {
                                StudioPlatformLabel(name: item.reviewPlatform,
                                                    title: reviewPlatformName(item.reviewPlatform))
                            }
                            if showsProjectStatus {
                                if showsPlatform { Text("·").accessibilityHidden(true) }
                                Text([projectName(item, in: snapshot), status(item)].joined(separator: " · "))
                            }
                        }
                        .font(.caption).foregroundStyle(palette.muted)
                    }
                    if let attachment = item.attachment {
                        MobileAttachmentLabel(attachment: attachment).font(.caption)
                    }
                    if item.isLongForm,
                       let edit = library.pendingChanges(for: item.id).last(where: { $0.isLongFormEdit }) {
                        let syncStatus = library.newsletterSyncStatus(for: edit)
                        Label(syncStatus.rawValue, systemImage: syncStatus.icon)
                            .font(.caption).foregroundStyle(palette.muted)
                    } else if library.isChanging(item.id) {
                        Label("iCloud sync pending", systemImage: "checkmark").font(.caption).foregroundStyle(palette.muted)
                    }
                }
                if selected {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.iconAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(selected ? palette.well : palette.card)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if item.isLongForm {
                if !item.shortened && !item.body.isEmpty {
                    Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.body }
                }
            } else {
                if item.isTrashed == true {
                    Button("Restore", systemImage: "arrow.uturn.backward") { restore(item, in: snapshot) }
                        .disabled(library.isChanging(item.id))
                } else {
                    Button("Edit", systemImage: "pencil") { editItem = item }
                }
                Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.body }
                    .disabled(item.shortened)
                Button(item.isTrashed == true ? "Delete permanently…" : item.kind == .idea ? "Skip idea" : "Move to Trash", systemImage: "trash", role: .destructive) { requestRemoval(item) }
                    .disabled(item.isTrashed == true ? !library.canDelete(item.id) : library.isChanging(item.id))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !item.isLongForm {
                Button(item.isTrashed == true ? "Delete" : item.kind == .idea ? "Skip" : "Trash", systemImage: "trash", role: .destructive) { requestRemoval(item) }
                    .disabled(item.isTrashed == true ? !library.canDelete(item.id) : library.isChanging(item.id))
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !item.isLongForm {
                if item.isTrashed == true {
                    Button("Restore", systemImage: "arrow.uturn.backward") { restore(item, in: snapshot) }.tint(palette.iconAccent)
                        .disabled(library.isChanging(item.id))
                } else {
                    Button("Edit", systemImage: "pencil") { editItem = item }.tint(palette.iconAccent)
                }
            }
        }
    }

    private func platformMenuIcon(_ platform: String) -> Image {
        let markPlatform = platform.hasSuffix("-article") ? String(platform.dropLast("-article".count)) : platform
        guard let mark = PlatformMark.bitmap(markPlatform) ?? (platform == "youtube" ? UIImage(systemName: "play.rectangle.fill") : nil) else { return Image(systemName: "link") }
        // Native menus lay out the image itself, independently of SwiftUI label styles.
        let tinted = mark.withTintColor(UIColor(palette.iconAccent), renderingMode: .alwaysOriginal)
        let canvas = CGSize(width: 24, height: 24)
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in
            tinted.draw(in: CGRect(x: 5.5, y: 5.5, width: 13, height: 13))
        }
        return Image(uiImage: image).renderingMode(.original)
    }

    @ViewBuilder private var reviewFilters: some View {
        if palette.theme == .paper {
            HStack(spacing: 2) {
                ForEach(Self.filters, id: \.self) { option in
                    Button { filter = option } label: {
                        Text(option)
                            .font(.subheadline.weight(filter == option ? .semibold : .medium))
                            .foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .padding(.vertical, 2)
                            .background(filter == option ? palette.active : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
            .padding(3)
            .background(palette.well, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.line).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Content")
        } else {
            Picker("Content", selection: $filter) {
                ForEach(Self.filters, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func removeSelectedItem() {
        guard let item = deleteItem else { return }
        remove(item, action: .deleteItem)
        deleteItem = nil
    }

    private func requestRemoval(_ item: CompanionLibrary.Item) {
        if item.isTrashed == true { deleteItem = item }
        else { remove(item, action: .trashItem) }
    }

    private func remove(_ item: CompanionLibrary.Item, action: CompanionLibrary.Change.Action) {
        guard let snapshot = library.snapshot else { return }
        do {
            try library.saveChange(.init(action: action, itemID: item.id, revision: item.revision), workspaceID: snapshot.workspaceID)
            updateSelection()
        } catch { actionError = error.localizedDescription }
    }

    private func updateSelection() {
        guard !items.contains(where: { $0.id == selection }) else { return }
        selection = wideLayout ? items.first?.id : nil
    }

    private func restore(_ item: CompanionLibrary.Item, in snapshot: CompanionLibrary) {
        do { try library.saveChange(.init(action: .restoreItem, itemID: item.id, revision: item.revision), workspaceID: snapshot.workspaceID) }
        catch { actionError = error.localizedDescription }
    }

    private func projectName(_ item: CompanionLibrary.Item, in snapshot: CompanionLibrary) -> String {
        snapshot.projects.first { $0.id == item.projectID }?.name ?? "Inkspring"
    }

    private func status(_ item: CompanionLibrary.Item) -> String {
        if item.isTrashed == true { return item.kind == .draft ? "Trashed draft" : "Trashed idea" }
        return switch item.status {
        case "draft": item.kind == .idea ? "Open idea" : "Draft"
        case "queued": "Scheduled"
        case "due": "Needs review"
        case "ready": "Ready to schedule"
        case "picked": "Drafted"
        default: item.status.capitalized
        }
    }
}

private extension CompanionLibrary.Item {
    var reviewPlatform: String {
        let channel = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return kind == .article ? (channel == "linkedin" ? "linkedin-article" : "x-article") : channel
    }
}

private func mobileWritingKind(_ kind: String?) -> CompanionLibrary.Item.Kind {
    if kind == "linkedin-article" { return .article }
    return kind.flatMap(CompanionLibrary.Item.Kind.init(rawValue:)) ?? .script
}

private func mobileWritingPlatform(_ kind: String?) -> String {
    switch kind {
    case "newsletter": "substack"
    case "article": "x"
    case "linkedin-article": "linkedin"
    default: "youtube"
    }
}

private func reviewPlatformName(_ platform: String) -> String {
    switch platform {
    case "x": "X"
    case "linkedin": "LinkedIn"
    case "tiktok": "TikTok"
    case "youtube": "YouTube"
    case "youtube-script": "YouTube script"
    case "x-article": "X article"
    case "linkedin-article": "LinkedIn article"
    default: platform.capitalized
    }
}

private struct MobileXGeneration: View {
    @Environment(\.studioPalette) private var palette
    let library: MobileLibrary
    @State private var projectID = ""
    @State private var title = ""
    @State private var brief = ""
    @State private var format = "post"
    @State private var message: String?
    @State private var queued = false

    var body: some View {
        Form {
            Section {
                if let projects = library.snapshot?.projects {
                    Picker("Project", selection: $projectID) {
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }
                }
                TextField("Draft title", text: $title, axis: .vertical)
                Picker("X post type", selection: $format) {
                    ForEach(XPostStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("x.generationType")
                TextField("What should the post be about?", text: $brief, axis: .vertical).lineLimit(4...10)
                Button("Generate on my Mac", systemImage: "sparkles") {
                    guard let snapshot = library.snapshot else { return }
                    do {
                        try library.saveChange(.init(action: .addIdea, itemID: projectID, title: title, text: brief,
                                                     xFormat: format, generatesXDraft: true), workspaceID: snapshot.workspaceID)
                        queued = true
                        message = "Queued for your Mac. The generated draft will appear in Review."
                    } catch { message = error.localizedDescription }
                }
                .disabled(queued || !library.canUseAgentFeatures || library.snapshot?.supportsXThreads != true || projectID.isEmpty ||
                          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          title.utf16.count > 200 || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          brief.utf16.count > 10_000)
                .accessibilityIdentifier("x.generate")
                Text("Your Mac uses your writing connection. Keep Inkspring open there.").font(.footnote)
                if let message { Text(message).font(.callout) }
            }
            .listRowBackground(palette.card)
            .disabled(queued)
        }
        .scrollContentBackground(.hidden).background(palette.canvas)
        .navigationTitle("Draft for X").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            projectID = library.snapshot?.projects.first?.id ?? ""
        }
    }
}

private struct MobilePrimaryActionStyle: ButtonStyle {
    @Environment(\.studioPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: StudioRadius.card)
        let foreground = isEnabled ? palette.accentText : palette.disabledText
        return configuration.label
            .labelStyle(.titleAndIcon)
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 48)
            .background(isEnabled ? palette.primaryAction : palette.well, in: shape)
            .overlay {
                if isEnabled && configuration.isPressed {
                    shape.strokeBorder(foreground.opacity(0.45), lineWidth: 2)
                        .allowsHitTesting(false)
                } else if !isEnabled {
                    shape.strokeBorder(palette.line).allowsHitTesting(false)
                }
            }
            .contentShape(shape)
    }
}

private struct MobileIdeaDraftPicker: View {
    @Environment(\.studioPalette) private var palette
    let item: CompanionLibrary.Item
    let library: MobileLibrary
    let workspaceID: UUID
    let onQueued: ([String]) -> Void
    @State private var chosen: Set<String> = []
    @State private var message: String?

    private var compatibleMac: Bool { library.snapshot?.supportsClaudeIdeaDrafts == true }

    var body: some View {
        Form {
            Section("Drafts to create") {
                ForEach(CompanionLibrary.ideaDraftPlatforms, id: \.self) { platform in
                    if item.draftedIdeaPlatforms?.contains(platform) == true {
                        Label("\(ideaDraftLabel(platform)) draft exists", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(palette.muted)
                    } else {
                        Button {
                            if chosen.contains(platform) { chosen.remove(platform) }
                            else { chosen.insert(platform) }
                        } label: {
                            HStack {
                                Label(ideaDraftLabel(platform), systemImage: platform.hasSuffix("-article") || platform == "substack" ? "doc.richtext" : "text.bubble")
                                Spacer()
                                Image(systemName: chosen.contains(platform) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(platform) ? palette.iconAccent : palette.muted)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 35)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen.contains(platform) ? .isSelected : [])
                        .accessibilityIdentifier("idea.draft.platform.\(platform)")
                    }
                }
            }
            .listRowBackground(palette.card)

        }
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button {
                    queueDrafts()
                } label: {
                    Label("Send to Claude", systemImage: "paperplane")
                }
                .buttonStyle(MobilePrimaryActionStyle())
                .disabled(chosen.isEmpty || !compatibleMac)
                .accessibilityIdentifier("idea.draft.send")
                Text(message ?? (compatibleMac
                     ? "Claude Code on your Mac creates one draft per selection. Find them in Review."
                     : "Update and open Inkspring on your Mac, then refresh here to send post ideas to Claude."))
                    .font(.footnote)
                    .foregroundStyle(message == nil ? palette.muted : palette.danger)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(palette.canvas)
        }
        .navigationTitle("Draft from post idea").navigationBarTitleDisplayMode(.inline)
    }

    private func queueDrafts() {
        let platforms = CompanionLibrary.ideaDraftPlatforms.filter(chosen.contains)
        guard !platforms.isEmpty else { return }
        var change = CompanionLibrary.Change(action: .note, itemID: item.id, revision: item.revision,
                                             xFormat: chosen.contains("x") ? XPostStyle.post.rawValue : nil)
        change.ideaDraftPlatforms = platforms
        do {
            try library.saveChange(change, workspaceID: workspaceID)
            chosen.removeAll()
            onQueued(platforms)
        } catch { message = error.localizedDescription }
    }

    private func ideaDraftLabel(_ platform: String) -> String {
        switch platform {
        case "x": "X post"
        case "linkedin": "LinkedIn post"
        case "reddit": "Reddit post"
        case "substack": "Substack article or newsletter"
        case "youtube": "YouTube script"
        default: reviewPlatformName(platform)
        }
    }
}

private struct MobileQuickXComposer: View {
    let library: MobileLibrary
    let preferredProject: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studioPalette) private var palette
    @State private var text = ""
    @State private var projectID: String?
    @State private var confirming = false
    @State private var requestID: UUID?
    @State private var error: String?
    @State private var polishing = false
    @State private var suggestedText: String?
    @FocusState private var editingPost: Bool

    private var projects: [CompanionLibrary.Project] { library.snapshot?.projects ?? [] }
    private var project: String? { projectID ?? preferredProject ?? projects.first?.id }
    private var account: String? { library.snapshot?.xArticleAccountKey }
    private var accountName: String { library.snapshot?.xArticleAccountName ?? "your connected account" }
    private var post: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var weight: Int { XThreadText.weight(post) }
    private var canPost: Bool {
        library.snapshot?.supportsQuickXPost == true && account != nil && project != nil && requestID == nil
            && XThreadText.validSinglePost(post)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let requestID {
                    publicationStatus(requestID)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .studioSurface()
                } else {
                    composer
                }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .mobileCanvas()
        .navigationTitle("Quick X post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(requestID == nil ? "Cancel" : "Done") { dismiss() } } }
        .alert("Publish this post to \(accountName)?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Publish to X", action: publish)
        } message: {
            Text(post)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if projects.count > 1 {
                Picker("Project", selection: Binding(get: { project ?? "" }, set: { projectID = $0 })) {
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
            }
            TextField("Your post", text: $text,
                      prompt: Text("Write the one thing you want to say."), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(4...10)
                .focused($editingPost)
                .accessibilityIdentifier("quickX.text")
                .padding(14)
                .studioSurface()
            Text("\(weight) / 280")
                .font(.caption)
                .foregroundStyle(weight > 280 ? palette.danger : palette.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
            StudioProofreadAction(document: .init(title: "", body: text),
                                  unavailable: proofreadUnavailable, begin: { editingPost = false }, reviewInSheet: true,
                                  check: proofread) { text = $0.body }
            if MobileProofreading.availabilityMessage == nil {
                Button("Polish with Apple Intelligence", systemImage: "sparkles") {
                    editingPost = false
                    Task { await polish() }
                }
                .buttonStyle(.bordered)
                .disabled(polishing || post.isEmpty || weight > 1_000)
            }
            if polishing { ProgressView("Polishing…") }
            if let suggestedText {
                Text(suggestedText).textSelection(.enabled)
                HStack {
                    Button("Use this version") { text = suggestedText; self.suggestedText = nil }
                    Button("Dismiss") { self.suggestedText = nil }
                }
                .buttonStyle(.bordered)
            }
            Button("Post to X", systemImage: "paperplane") {
                editingPost = false
                confirming = true
            }
            .buttonStyle(MobilePrimaryActionStyle())
            .disabled(!canPost)
            .accessibilityIdentifier("quickX.review")
            Text("Your Mac publishes this as a single post to \(accountName).")
                .font(.footnote).foregroundStyle(palette.muted)
            if library.snapshot?.supportsQuickXPost != true {
                Text("Update and open Inkspring on your Mac to use Quick X.")
            } else if account == nil {
                Text("Connect your X account in Inkspring on your Mac.")
            }
            if let error { Label(error, systemImage: "exclamationmark.circle") }
        }
    }

    @ViewBuilder private func publicationStatus(_ id: UUID) -> some View {
        if let result = library.snapshot?.results.first(where: { $0.id == id }) {
            if let error = result.error {
                Label(error, systemImage: "exclamationmark.circle")
            } else if let address = result.publicationURL, let url = CompanionPublication.postURL(address) {
                Link("View published post", destination: url)
                    .accessibilityIdentifier("quickX.published")
            } else {
                Label("Published on X", systemImage: "checkmark.circle")
            }
        } else if let error = library.pendingQuickXPosts.first(where: { $0.id == id })?.error {
            Label(error, systemImage: "exclamationmark.circle")
        } else {
            Label("Waiting for your Mac to publish.", systemImage: "clock")
        }
    }

    private func publish() {
        guard canPost, let account, let project else { return }
        do { requestID = try library.queueQuickXPost(text: post, projectID: project, accountKey: account) }
        catch { self.error = error.localizedDescription }
    }

    private var proofreadUnavailable: String? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--quick-x-fixture") { return nil }
        #endif
        return MobileProofreading.availabilityMessage
    }

    @MainActor private func proofread(_ document: ProofreadDocument) async throws -> ProofreadReview {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--quick-x-fixture") {
            return try await ProofreadReview.check(document, chunkSize: 1_350) { _ in
                [.init(original: "teh", replacement: "the", reason: "Fix a spelling error")]
            }
        }
        #endif
        return try await MobileProofreading.check(document)
    }

    private func polish() async {
        guard #available(iOS 26, *), MobileProofreading.availabilityMessage == nil, !polishing else { return }
        let original = text
        polishing = true
        error = nil
        defer { polishing = false }
        do {
            let session = LanguageModelSession(instructions: """
                Tighten the author's text into one short post for X, keeping the voice, meaning, and claims.
                Use the author's language. Do not add hashtags, links, or facts. Return only the post text, within 280 characters.
                """)
            let response = try await session.respond(to: original)
            let candidate = XThreadText.singlePost(response.content)
            guard original == text else { return }
            guard XThreadText.validSinglePost(candidate) else {
                error = "Apple Intelligence didn’t suggest a version that fits in one X post."
                return
            }
            suggestedText = candidate
        } catch { self.error = error.localizedDescription }
    }
}

private struct MobileMediaDraftForm: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    let platform: String
    let library: MobileLibrary
    let initialProject: String
    let ideaID: String?
    @State private var projectID = ""
    @State private var caption = ""
    @State private var importing = false
    @State private var selected: URL?
    @State private var message: String?
    @State private var queued = false

    var body: some View {
        Form {
            Section {
                if ideaID == nil {
                    Picker("Project", selection: $projectID) {
                        ForEach(library.snapshot?.projects ?? []) { Text($0.name).tag($0.id) }
                    }
                }
                Button(selected?.lastPathComponent ?? (platform == "tiktok" ? "Choose a video" : "Choose a photo or video"),
                       systemImage: platform == "tiktok" ? "video" : "photo") { importing = true }
                TextField("Caption (optional)", text: $caption, axis: .vertical).lineLimit(2...4)
            } footer: {
                Text("MP4 or MOV video up to 30 MB. Instagram also accepts PNG and JPEG.")
            }
            .listRowBackground(palette.card)
            .disabled(queued)

            Section {
                Button("Save draft on Mac", systemImage: "square.and.pencil") {
                    guard let selected else { return }
                    do {
                        try library.queueMediaDraft(file: selected, platform: platform, caption: caption,
                                                    projectID: projectID, ideaID: ideaID)
                        queued = true
                        message = "Queued for your Mac. The draft will appear in Review."
                    } catch { message = error.localizedDescription }
                }
                .disabled(selected == nil || projectID.isEmpty || queued || caption.utf16.count > 2_200)
                if let message { Text(message).font(.callout) }
            }
            .listRowBackground(palette.card)
        }
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
        .navigationTitle(platform == "tiktok" ? "New TikTok video" : "New Instagram post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear { if projectID.isEmpty { projectID = initialProject } }
        .fileImporter(isPresented: $importing, allowedContentTypes: platform == "tiktok" ? [.mpeg4Movie, .quickTimeMovie] : [.mpeg4Movie, .quickTimeMovie, .png, .jpeg]) { result in
            do { selected = try result.get(); message = nil }
            catch { message = error.localizedDescription }
        }
    }
}

private struct MobileItemEditor: View {
    let item: CompanionLibrary.Item
    let library: MobileLibrary
    let workspaceID: UUID
    var bodyFirst = false
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.studioPalette) private var palette
    @State private var showsWritingTools = false
    @State private var title = ""
    @State private var text = ""
    @State private var format = "post"
    @State private var baseTitle = ""
    @State private var baseText = ""
    @State private var baseFormat = "post"
    @State private var initialized = false
    @State private var message: String?
    @State private var findRequest = 0

    private var unavailable: Bool {
        item.isTrashed == true || item.shortened || ["posting", "posted", "uncertain"].contains(item.status)
    }
    private var dirty: Bool { title != baseTitle || text != baseText || format != baseFormat }
    private var recoveryKey: String { library.newsletterRecoveryKey(for: item.id, workspaceID: workspaceID) ?? "" }
    private var isX: Bool {
        item.platform == "x" && XPostStyle(rawValue: item.format ?? "post") != nil &&
            item.requiresMacScheduling != true && library.snapshot?.supportsXThreads == true
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Title", text: $title, axis: .vertical).font(.headline).lineLimit(1...2)
                .accessibilityIdentifier("mobile.edit.title").padding(.horizontal, 12)
            if isX {
                StudioXPostEditor(text: $text, format: $format, articles: library.snapshot?.supportsXReplyArticles == true ? (library.snapshot?.articles ?? []).compactMap { article in
                    guard article.platform != "linkedin", article.projectID == item.projectID, let ref = article.referenceID else { return nil }
                    return XArticleChoice(id: ref, title: article.title)
                } : []).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MobileWritingTextView(text: $text, identifier: "mobile.edit.body", findRequest: findRequest, onFocusLost: { _ = save() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(palette.danger).padding(.horizontal, 12) }
        }
        .padding(.vertical, 8).background(palette.canvas)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(item.kind == .draft ? "Edit draft" : "Edit idea")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isX { Button("Find", systemImage: "magnifyingglass") { findRequest += 1 }.accessibilityIdentifier("editor.find") }
                if library.canUseAgentFeatures {
                    MobileWritingTools(title: $title, text: $text, presented: $showsWritingTools,
                        agent: library.snapshot?.writingAgent ?? "agent", requests: library.revisionRequests(for: item),
                        reply: item.writingReply, error: item.writingError) { prompt in
                            guard save() else { throw CompanionLibraryError.invalid }
                            try library.saveChange(.init(action: .note, itemID: item.id, revision: item.revision,
                                text: prompt, requestsWritingHelp: true), workspaceID: workspaceID)
                        }
                }
                Button("Done") { if save() { if let close { close() } else { dismiss() } } }
            }
        }
        .task {
            guard !initialized else { return }
            let pending = library.pendingChanges(for: item.id).last { [.editDraft, .editIdea].contains($0.action) && $0.contentOperation == nil }
            baseTitle = pending?.title ?? item.title
            baseText = pending?.text ?? item.body
            baseFormat = pending?.xFormat ?? item.format ?? "post"
            let recovery = library.recoverNewsletterEdit(key: recoveryKey)
            title = recovery?.title ?? baseTitle
            text = recovery?.markdown ?? baseText
            format = baseFormat
            initialized = true
        }
        .onChange(of: title + "\0" + text + "\0" + format) {
            guard initialized, dirty else { return }
            library.storeNewsletterRecovery(.init(revision: item.revision, base: baseText, markdown: text, title: title), key: recoveryKey)
        }
        .task(id: title + "\0" + text + "\0" + format) {
            guard initialized, dirty else { return }
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            _ = save()
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { _ = save() } }
        .onDisappear { _ = save() }
    }

    @discardableResult private func save() -> Bool {
        guard initialized, dirty else { return true }
        guard !unavailable else { message = "This item is not currently editable. Your text is saved on this device."; return false }
        do {
            let latest = library.snapshot?.items.first { $0.id == item.id } ?? item
            try library.saveChange(.init(action: item.kind == .draft ? .editDraft : .editIdea, itemID: item.id,
                revision: latest.revision, title: title, text: text, xFormat: isX ? format : nil), workspaceID: workspaceID)
            baseTitle = title; baseText = text; baseFormat = format
            library.storeNewsletterRecovery(nil, key: recoveryKey)
            message = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }
}

private struct MobileAttachmentLabel: View {
    let attachment: CompanionLibrary.Item.Attachment

    var body: some View {
        Label(attachment == .video ? "Video attached" : "Image attached",
              systemImage: attachment == .video ? "video" : "photo")
            .foregroundStyle(.secondary)
    }
}

enum IdeaMediaPlatform: String, Identifiable {
    case tiktok, instagram
    var id: String { rawValue }
}

struct MobileReviewDetail: View {
    let item: CompanionLibrary.Item
    let library: MobileLibrary
    let workspaceID: UUID
    @Environment(\.studioPalette) private var palette
    @Environment(\.mobileWideLayout) private var wideLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var note = ""
    @State private var message: String?
    @State private var savedNoteID: UUID?
    @State private var composingRevisionRequest = false
    @State private var showsOutline = false
    @State private var editingDraft = false
    @State private var choosingSchedule = false
    @State private var draftingIdea = false
    @State private var queuedDraftPlatforms: [String] = []
    @State private var viewingIdeaDraftID: String?
    @State private var mediaPlatform: IdeaMediaPlatform?
    @State private var needsMacUpdate = false
    @State private var confirmDeletion = false
    @State private var editBodyFirst = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingNote: Bool

    private var hasPendingChange: Bool {
        library.pendingChanges(for: item.id).contains { !([CompanionLibrary.Change.Action.note, .saveRevision].contains($0.action)) && $0.error == nil }
            || library.snapshot?.pending.contains { $0.itemID == item.id && !([CompanionLibrary.Change.Action.note, .saveRevision].contains($0.action)) } == true
    }

    private var pendingEdit: CompanionLibraryOutbox.Entry? {
        library.pendingChanges(for: item.id).last { [.editDraft, .editIdea].contains($0.action) }
    }

    private var ideaDraftRequest: CompanionLibraryOutbox.Entry? {
        library.pendingChanges(for: item.id).last { $0.ideaDraftPlatforms != nil }
    }

    private var hasPendingIdeaDraft: Bool {
        (ideaDraftRequest.map { $0.error == nil } ?? false)
            || library.snapshot?.pending.contains { $0.itemID == item.id && $0.ideaDraftPlatforms != nil } == true
    }

    private var linkedIdeaDrafts: [CompanionLibrary.Item] {
        guard item.kind == .idea, let links = item.draftedIdeaIDs else { return [] }
        let drafts = library.visibleItems + (library.snapshot?.newsletters ?? []) + library.visibleScripts
        return CompanionLibrary.ideaDraftPlatforms.compactMap { platform in
            drafts.first { $0.id == links[platform] && $0.isTrashed != true && !["published", "posted", "posting"].contains($0.status)
                && ($0.publicationURL ?? "").isEmpty }
        }
    }

    private var inTrash: Bool { item.isTrashed == true }

    private var canRequestRevision: Bool {
        guard !inTrash, !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return item.kind == .idea ? item.status == "draft" : ["", "draft", "ready"].contains(item.status)
    }

    private var canChooseSchedule: Bool {
        item.kind == .draft && !inTrash && !["queued", "due", "posting", "posted", "uncertain"].contains(item.status)
            && !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var postingWindow: CompanionPostingWindow? {
        guard item.requiresMacScheduling != true else { return nil }
        return library.snapshot?.postingWindows?[item.reviewPlatform]
    }

    private var showsScheduleAction: Bool {
        guard canChooseSchedule, item.requiresMacScheduling != true else { return false }
        if library.snapshot?.postingWindows != nil { return postingWindow != nil }
        return ["x", "linkedin", "instagram", "reddit"].contains(item.reviewPlatform)
    }

    private var schedulingRequest: MobileLibrary.SchedulingRequest? {
        library.pendingSchedules.first { $0.item.id == item.id }
    }

    private func date(_ timestamp: String) -> Date? {
        try? Date(timestamp, strategy: .iso8601.time(includingFractionalSeconds: true))
    }

    var body: some View {
        if showsOutline {
            MobilePlanSection(item: item, library: library, workspaceID: workspaceID) { showsOutline = false }
        } else {
            document
        }
    }

    private var document: some View {
        Group {
            if let draft = linkedIdeaDrafts.first(where: { $0.id == viewingIdeaDraftID }) {
                if draft.isLongForm {
                    MobileNewsletterDetail(item: draft, metadata: reviewPlatformName(draft.reviewPlatform),
                                           library: library, workspaceID: workspaceID)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Back to idea", systemImage: "chevron.left") { viewingIdeaDraftID = nil }
                            }
                        }
                } else {
                    MobileItemEditor(item: draft, library: library, workspaceID: workspaceID,
                                     close: { viewingIdeaDraftID = nil })
                        .id(draft.id)
                }
            } else if editingDraft {
                MobileItemEditor(item: item, library: library, workspaceID: workspaceID, bodyFirst: editBodyFirst, close: { editingDraft = false })
            } else {
                ScrollViewReader { scroll in
                    preview.safeAreaInset(edge: .top, spacing: 0) {
                        if !queuedDraftPlatforms.isEmpty && !draftingIdea {
                            ideaDraftConfirmation {
                                if let draft = linkedIdeaDrafts.first(where: { queuedDraftPlatforms.contains($0.reviewPlatform) }) {
                                    viewingIdeaDraftID = draft.id
                                } else {
                                    withAnimation { scroll.scrollTo("idea.draft.source", anchor: .top) }
                                }
                                queuedDraftPlatforms = []
                            }
                        }
                    }
                }
            }
        }
    }

    private func ideaDraftConfirmation(view: @escaping () -> Void) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Label("Sent to Claude", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("View Post", action: view).fixedSize()
                    .accessibilityIdentifier("idea.draft.viewPost")
                Button("Dismiss", systemImage: "xmark") { queuedDraftPlatforms = [] }
                    .labelStyle(.iconOnly)
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .studioSurface()
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(palette.canvas)
    }

    private var preview: some View {
        Form {
            if inTrash {
                Section {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        if save(.init(action: .restoreItem, itemID: item.id, revision: item.revision)), !wideLayout { dismiss() }
                    }
                    .disabled(hasPendingChange)
                    Button(role: .destructive) { confirmDeletion = true } label: {
                        Label("Delete permanently…", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(palette.theme == .paper ? palette.danger : Color.red)
                    }
                    .disabled(!library.canDelete(item.id))
                    .modifier(MobilePermanentDeletionConfirmation(
                        isPresented: $confirmDeletion,
                        message: "This cannot be undone."
                    ) { remove(.deleteItem) })
                } header: {
                    Text(item.kind == .draft ? "Draft in Trash" : "Idea in Trash")
                }
                .listRowBackground(palette.card)
            }
            Section {
                if inTrash {
                    Text(pendingEdit?.title ?? item.title)
                        .font(.headline).foregroundStyle(palette.text)
                } else {
                    Button { editBodyFirst = false; editingDraft = true } label: {
                        Text(pendingEdit?.title ?? item.title)
                            .font(.headline).foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit title")
                    .accessibilityIdentifier(item.kind == .idea ? "idea.detail.title" : "draft.detail.title")
                    .id("idea.draft.source")
                }
                if !inTrash && item.kind == .idea {
                    if let error = ideaDraftRequest?.error {
                        Label(error, systemImage: "exclamationmark.icloud").font(.footnote)
                    } else if hasPendingIdeaDraft {
                        Label("Queued for Claude on your Mac.", systemImage: "clock").font(.footnote)
                    }
                    ForEach(linkedIdeaDrafts) { draft in
                        Button("View \(reviewPlatformName(draft.reviewPlatform)) draft", systemImage: "arrow.up.right") {
                            viewingIdeaDraftID = draft.id
                        }
                        .accessibilityIdentifier("idea.draft.link.\(draft.reviewPlatform)")
                    }
                }
                if !item.platform.isEmpty {
                    StudioPlatformLabel(name: item.reviewPlatform, title: reviewPlatformName(item.reviewPlatform))
                        .foregroundStyle(palette.muted)
                }
                if let attachment = item.attachment { MobileAttachmentLabel(attachment: attachment) }
                if let reference = item.referenceID {
                    StudioCopyReference(reference: reference)
                }
                if let updatedAt = item.revisionDate {
                    Text("Last updated \(updatedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                        .accessibilityIdentifier("post.lastUpdated")
                }
                NavigationLink {
                    MobileRevisionHistory(item: item, library: library, workspaceID: workspaceID)
                } label: { Label("Revision history", systemImage: "clock.arrow.circlepath") }
                .accessibilityIdentifier("history.open")
                if item.shortened && pendingEdit == nil {
                    Text("Waiting for the full text to sync.").font(.footnote).foregroundStyle(.secondary)
                } else if inTrash {
                    Text(pendingEdit?.text ?? item.body).foregroundStyle(palette.text).textSelection(.enabled)
                } else if item.platform == "x", ["followup", "thread"].contains(pendingEdit?.xFormat ?? item.format ?? "") {
                    let posts = XThreadText.posts(in: pendingEdit?.text ?? item.body)
                    ForEach(posts.indices, id: \.self) { index in
                        Button {
                            editBodyFirst = true
                            editingDraft = true
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(index == 0 ? "Opening post" : "Follow-up reply \(index)", systemImage: index == 0 ? "text.bubble" : "arrow.turn.down.right")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.iconAccent)
                                Text(XReplyArticle(posts[index]).copy).font(.body).foregroundStyle(palette.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("x.reply.\(index)")
                        if let ref = XReplyArticle(posts[index]).reference {
                            if let article = library.snapshot?.articles?.first(where: { $0.platform != "linkedin" && $0.projectID == item.projectID && $0.referenceID == ref }) {
                                NavigationLink {
                                    MobileNewsletterDetail(item: article, metadata: article.referenceID ?? "", library: library, workspaceID: workspaceID)
                                } label: { Label("X article · " + article.title, systemImage: "doc.text") }
                                if article.publicationURL?.isEmpty != false { Text("Publish the article first to include its X link.").font(.footnote).foregroundStyle(palette.muted) }
                            } else { Text("Linked X article unavailable · " + ref).font(.footnote) }
                        }
                    }
                } else {
                    Button { editBodyFirst = true; editingDraft = true } label: {
                        Text(pendingEdit?.text ?? item.body)
                            .font(.body).foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit text")
                }
                if let error = pendingEdit?.error {
                    Label(error, systemImage: "exclamationmark.icloud").font(.footnote)
                }
                if let status = item.generationStatus { Text(status).font(.footnote).foregroundStyle(palette.muted) }

            }
            .listRowBackground(palette.card)
            if !library.planText(item).isEmpty {
                Button("View outline", systemImage: "list.bullet.clipboard") { showsOutline = true }
                    .font(.callout)
                    .accessibilityIdentifier("outline.view")
                    .listRowBackground(palette.card)
            }
            if !inTrash, canRequestRevision || !library.revisionRequests(for: item).isEmpty {
            Section {
                if canRequestRevision && library.canUseAgentFeatures {
                    if composingRevisionRequest {
                        TextField(StudioRevisionRequestCopy.field, text: $note,
                                  prompt: Text(item.kind == .idea ? StudioRevisionRequestCopy.ideaExample : StudioRevisionRequestCopy.draftExample),
                                  axis: .vertical)
                            .lineLimit(2...5)
                            .focused($editingNote)
                            .accessibilityIdentifier("review.revisionRequest")
                        HStack {
                            Button("Cancel") {
                                editingNote = false
                                composingRevisionRequest = false
                            }.buttonStyle(.borderless)
                            Spacer()
                            Button(StudioRevisionRequestCopy.send) {
                                if saveNote() {
                                    editingNote = false
                                    composingRevisionRequest = false
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.utf16.count > 1000)
                        }
                        if note.utf16.count > 1000 {
                            Text("Use up to 1,000 characters.").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Button(StudioRevisionRequestCopy.add, systemImage: "plus") {
                            composingRevisionRequest = true
                        }
                        .accessibilityIdentifier("review.addRevisionRequest")
                    }
                }
                ForEach(library.revisionRequests(for: item)) { request in
                    StudioRevisionRequestRow(request: request)
                }
                if let savedNoteID {
                    let entry = library.pendingChanges(for: item.id).first { $0.id == savedNoteID }
                    let uploaded = entry == nil || library.snapshot?.pending.contains { $0.id == savedNoteID } == true
                    if entry?.error == nil {
                        Label(uploaded ? "Revision request synced" : "Revision request saved · iCloud sync pending",
                              systemImage: "checkmark")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = item.writingError {
                    Label(error, systemImage: "exclamationmark.icloud").font(.footnote)
                }
            } header: {
                Text(StudioRevisionRequestCopy.heading)
            } footer: {
                if canRequestRevision {
                    Text(library.canUseAgentFeatures
                         ? "Inkspring on your Mac applies the request using its writing connection. The earlier version stays in revision history."
                         : "Connect a writing agent in Inkspring on your Mac to send a revision request.")
                }
            }
            .listRowBackground(palette.card)
            }
            if showsScheduleAction || canChooseSchedule && schedulingRequest != nil {
                Section {
                    if showsScheduleAction {
                        Button("Schedule post…", systemImage: "calendar.badge.clock", action: openSchedule)
                            .disabled(hasPendingChange)
                            .accessibilityIdentifier("review.schedulePost")
                    }
                    if let request = schedulingRequest {
                        Label(request.error ?? "Waiting for your Mac to schedule this post.",
                              systemImage: request.error == nil ? "clock" : "exclamationmark.icloud")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(palette.card)
            }
            if item.isTrashed != true, item.kind == .idea, ["draft", "skipped"].contains(item.status) {
                if item.status == "draft", item.revision != "pending-add", library.snapshot?.supportsMediaDrafts == true {
                    Section {
                        Menu("Create media draft", systemImage: "photo.on.rectangle") {
                            Button("TikTok video") { mediaPlatform = .tiktok }
                            Button("Instagram post") { mediaPlatform = .instagram }
                        }
                        .accessibilityIdentifier("idea.media.open")
                    }
                    .listRowBackground(palette.card)
                }
                Section {
                    if item.status == "draft" {
                        Button {
                            queuedDraftPlatforms = []
                            draftingIdea = true
                        } label: {
                            Label("Draft from post idea", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(MobilePrimaryActionStyle())
                        .disabled(hasPendingChange || hasPendingIdeaDraft || item.revision == "pending-add"
                                  || CompanionLibrary.ideaDraftPlatforms.allSatisfy { item.draftedIdeaPlatforms?.contains($0) == true })
                        .accessibilityIdentifier("idea.draft.open")
                    }
                    Button(item.status == "draft" ? "Skip idea" : "Restore idea") {
                        save(.init(action: item.status == "draft" ? .skipIdea : .restoreIdea,
                                   itemID: item.id, revision: item.revision))
                    }
                    .disabled(library.busy || hasPendingChange)
                }
                .listRowBackground(palette.card)
            }
            if hasPendingChange { Text("iCloud sync in progress.").foregroundStyle(.secondary) }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(inTrash ? "Trash" : item.kind == .draft ? "Draft" : "Idea")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if item.isTrashed != true {
                    Button("Edit", systemImage: "pencil") { editingDraft = true }
                }
                moreActions
            }
        }
        .sheet(isPresented: $draftingIdea, onDismiss: {
            if !queuedDraftPlatforms.isEmpty { AccessibilityNotification.Announcement("Sent to Claude").post() }
        }) {
            NavigationStack {
                MobileIdeaDraftPicker(item: item, library: library, workspaceID: workspaceID) { platforms in
                    queuedDraftPlatforms = platforms
                    draftingIdea = false
                }
                .toolbar { Button("Done") { draftingIdea = false } }
            }
        }
        .sheet(item: $mediaPlatform) { platform in
            NavigationStack {
                MobileMediaDraftForm(platform: platform.rawValue, library: library, initialProject: item.projectID, ideaID: item.id)
            }
        }
        .sheet(isPresented: $choosingSchedule) {
            if let postingWindow {
                let zone = library.snapshot?.postingTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
                MobileSchedulePicker(item: item, window: postingWindow, timeZone: zone) { hour in
                    try library.saveChange(.init(action: .scheduleDraft, itemID: item.id, revision: item.revision,
                                                 text: hour.formatted(.iso8601)), workspaceID: workspaceID)
                }
            }
        }
        .alert("Schedule from this device", isPresented: $needsMacUpdate) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your Mac handles scheduled posts. You can schedule this draft from Schedule in Inkspring on your Mac. To schedule from this device, update and open Inkspring on your Mac, then refresh Review here.")
        }
    }

    private func openSchedule() {
        if postingWindow != nil { choosingSchedule = true }
        else { needsMacUpdate = true }
    }

    private var moreActions: some View {
        Menu {
            if !inTrash {
                if library.snapshot?.supportsContentPlans == true {
                    Button(library.planText(item).isEmpty ? "Add outline" : "View outline", systemImage: "list.bullet.clipboard") { showsOutline = true }
                            .accessibilityIdentifier("outline.menu")
                }
                Button("Edit title", systemImage: "pencil") { editBodyFirst = false; editingDraft = true }
                Button("Edit text", systemImage: "square.and.pencil") { editBodyFirst = true; editingDraft = true }
                if showsScheduleAction {
                    Button("Schedule post…", systemImage: "calendar.badge.clock", action: openSchedule)
                        .disabled(hasPendingChange)
                }
            }
            Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = pendingEdit?.text ?? item.body }
                .disabled(item.shortened && pendingEdit == nil)
            ShareLink(item: pendingEdit?.text ?? item.body) { Label("Share text", systemImage: "square.and.arrow.up") }
            if !inTrash {
                Button(item.kind == .idea ? "Skip idea" : "Move to Trash", systemImage: "trash", role: .destructive) { remove(.trashItem) }
                    .disabled(hasPendingChange)
            }
        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
        .accessibilityLabel("More actions")
    }

    private func remove(_ action: CompanionLibrary.Change.Action) {
        if save(.init(action: action, itemID: item.id, revision: item.revision)), !wideLayout { dismiss() }
    }

    private func saveNote() -> Bool {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 1000 else { return false }
        let change = CompanionLibrary.Change(action: .note, itemID: item.id, revision: item.revision,
                                             text: text, requestsWritingHelp: true)
        if save(change) {
            note = ""
            savedNoteID = change.id
            return true
        }
        return false
    }

    @discardableResult
    private func save(_ change: CompanionLibrary.Change) -> Bool {
        do {
            try library.saveChange(change, workspaceID: workspaceID)
            message = nil
            InkspringReview.recordActivity()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

private struct MobileRevisionHistory: View {
    let item: CompanionLibrary.Item
    let library: MobileLibrary
    let workspaceID: UUID
    @Environment(\.studioPalette) private var palette
    @State private var revisions: [ContentRevision] = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("Every save keeps a snapshot. Restoring creates a new version and keeps the later versions.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }.listRowBackground(palette.card)
            Section {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                    NavigationLink {
                        MobileRevisionDetail(item: item, revision: revision, library: library, workspaceID: workspaceID)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(revision.date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Earlier version")
                                .font(.headline)
                            Text(revision.source).font(.caption).foregroundStyle(palette.muted)
                            Text(revision.title).font(.callout)
                            Text(revision.text).font(.footnote).lineLimit(2).foregroundStyle(palette.muted)
                        }
                    }.accessibilityIdentifier("history.version.\(index)")
                }
                if revisions.isEmpty { Text("History starts with saves in this version of Inkspring.") }
            }.listRowBackground(palette.card)
            if let message { Text(message).foregroundStyle(palette.danger) }
        }
        .scrollContentBackground(.hidden).background(palette.canvas)
        .navigationTitle("Revision history").navigationBarTitleDisplayMode(.inline)
        .task(id: library.snapshot?.updatedAt) {
            do { revisions = try library.history(for: item) }
            catch { message = "Saved history couldn’t be read. \(error.localizedDescription)" }
        }
    }
}

private struct MobileRevisionDetail: View {
    let item: CompanionLibrary.Item
    let revision: ContentRevision
    let library: MobileLibrary
    let workspaceID: UUID
    @Environment(\.studioPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(revision.title).font(.title2.bold())
                Text(revision.source).font(.footnote).foregroundStyle(palette.muted)
                if ["thread", "followup"].contains(revision.format ?? "") {
                    let posts = XThreadText.posts(in: revision.text)
                    ForEach(posts.indices, id: \.self) { index in
                        Text(index == 0 ? "Opening post" : "Follow-up reply \(index)").font(.headline)
                        Text(posts[index]).textSelection(.enabled)
                    }
                } else if item.isLongForm {
                    MobileNewsletterMarkdown(markdown: revision.text)
                } else { Text(revision.text).textSelection(.enabled) }
                Text("Your current version stays in history when you restore.").font(.footnote).foregroundStyle(palette.muted)
                Button("Restore this version", systemImage: "clock.arrow.circlepath") {
                    do {
                        let latest = ((library.snapshot?.items ?? []) + (library.snapshot?.newsletters ?? []) + (library.snapshot?.scripts ?? []) + (library.snapshot?.articles ?? []))
                            .first { $0.id == item.id } ?? item
                        try library.saveChange(.init(action: .editDraft, itemID: latest.id, revision: latest.revision,
                            title: revision.title, text: revision.text, editsNewsletter: latest.kind == .newsletter ? true : nil,
                            baseNewsletterText: latest.isLongForm ? latest.body : nil,
                            xFormat: latest.platform == "x" ? revision.format : nil,
                            restoresRevision: true, subtitle: revision.subtitle, editsScript: [.script, .article].contains(latest.kind) ? true : nil, writingKind: latest.kind == .article ? "article" : nil), workspaceID: workspaceID)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.iconAccent)
                .disabled(item.isTrashed == true || library.isChanging(item.id) ||
                          ["posting", "posted", "uncertain", "published"].contains(item.status))
                .accessibilityIdentifier("history.restore")
                if let message { Text(message).foregroundStyle(palette.danger) }
            }
            .font(.body).lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18).studioSurface().padding(16)
        }
        .background(palette.canvas).navigationTitle("Saved version").navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSchedulePicker: View {
    let item: CompanionLibrary.Item
    let window: CompanionPostingWindow
    let timeZone: TimeZone
    let schedule: (Date) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studioPalette) private var palette
    @State private var day = Date.now
    @State private var selectedHour: Date?
    @State private var message: String?

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    private var hours: [Date] {
        window.hours.compactMap { hour in
            guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day, matchingPolicy: .strict),
                  calendar.isDate(date, inSameDayAs: day), date.addingTimeInterval(3600) > .now.addingTimeInterval(120)
            else { return nil }
            return date
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title).font(.headline)
                    StudioPlatformLabel(name: item.reviewPlatform, title: reviewPlatformName(item.reviewPlatform))
                }
                .listRowBackground(palette.card)
                Section("Posting day") {
                    DatePicker("Posting day", selection: $day, in: calendar.startOfDay(for: .now)..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .accessibilityIdentifier("schedule.postingDay")
                }
                .listRowBackground(palette.card)
                Section {
                    if hours.isEmpty {
                        Text("Choose another day to see available posting hours.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Posting hour", selection: $selectedHour) {
                            ForEach(hours, id: \.self) { hour in
                                Text(hour, format: Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
                                    .tag(Optional(hour))
                            }
                        }
                        .accessibilityIdentifier("schedule.postingHour")
                    }
                } footer: {
                    Text("Uses your Mac’s posting hours (\(timeZone.identifier)). Your Mac chooses the posting minute and checks the time before scheduling.")
                }
                .listRowBackground(palette.card)
                if let message { Text(message).foregroundStyle(palette.danger) }
            }
            .environment(\.calendar, calendar)
            .environment(\.timeZone, timeZone)
            .scrollContentBackground(.hidden)
            .background(palette.canvas)
            .navigationTitle("Schedule post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        guard let selectedHour, hours.contains(selectedHour) else { return }
                        do { try schedule(selectedHour); dismiss() }
                        catch { message = error.localizedDescription }
                    }
                    .disabled(selectedHour.map { !hours.contains($0) } ?? true)
                    .accessibilityIdentifier("schedule.confirm")
                }
            }
            .onChange(of: hours, initial: true) { _, hours in
                if selectedHour.map({ hours.contains($0) }) != true { selectedHour = hours.first }
            }
            .onAppear {
                if hours.isEmpty, let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) { day = tomorrow }
            }
        }
    }
}

private struct MobilePermanentDeletionConfirmation: ViewModifier {
    @Environment(\.studioPalette) private var palette
    @Binding var isPresented: Bool
    let message: String
    let remove: () -> Void

    func body(content: Content) -> some View {
        if palette.theme == .paper {
            content.popover(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Delete permanently?")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(message).font(.subheadline).foregroundStyle(palette.muted)
                    Button("Delete permanently", role: .destructive) {
                        remove()
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accentText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(palette.danger, in: Capsule())
                    Button("Cancel", role: .cancel) { isPresented = false }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(palette.well, in: Capsule())
                }
                .foregroundStyle(palette.text)
                .padding(18)
                .frame(idealWidth: 270, maxWidth: 340)
                .presentationBackground(palette.panel)
                .presentationDetents([.medium, .large])
            }
        } else {
            content.confirmationDialog("Delete permanently?",
                                       isPresented: $isPresented, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
        }
    }
}
