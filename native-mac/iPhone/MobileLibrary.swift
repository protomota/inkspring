import CloudKit
import CryptoKit
import SwiftUI

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
    private let defaults = UserDefaults.standard
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
        (snapshot?.items ?? []).compactMap { original in
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
        let remote = (snapshot?.scripts ?? []) + (snapshot?.articles ?? [])
        let ids = Set((remote + (snapshot?.newsletters ?? [])).map(\.id))
        let local = outbox.entries.filter {
            $0.createsScript == true && $0.account == account && $0.workspaceID == snapshot?.workspaceID
                && !ids.contains($0.id.uuidString.lowercased())
        }.map { entry in
            CompanionLibrary.Item(id: entry.id.uuidString.lowercased(), revision: "pending-add", kind: entry.writingKind == "newsletter" ? .newsletter : entry.writingKind == "article" ? .article : .script,
                projectID: entry.itemID ?? "", title: entry.title, body: entry.text, shortened: false,
                platform: entry.writingKind == "newsletter" ? "substack" : entry.writingKind == "article" ? "x" : "youtube", status: "draft", notes: [])
        }
        return remote + local
    }

    func createScript(projectID: String, kind: String = "script") throws -> String {
        guard let snapshot else { throw CompanionScheduleError.changed }
        let change = CompanionLibrary.Change(action: .addIdea, itemID: projectID, title: kind == "newsletter" ? "Untitled newsletter" : kind == "article" ? "Untitled X article" : "Untitled YouTube script", createsScript: true, writingKind: kind)
        try saveChange(change, workspaceID: snapshot.workspaceID)
        return change.id.uuidString.lowercased()
    }

    func saveIdea(title: String, text: String, projectID: String?) throws {
        try queue(.init(id: UUID(), action: .addIdea, itemID: projectID, revision: "", title: title, text: text,
                        workspaceID: snapshot?.workspaceID, account: account))
    }

    func saveChange(_ change: CompanionLibrary.Change, workspaceID: UUID) throws {
        guard let account, snapshot?.workspaceID == workspaceID else { throw CompanionScheduleError.changed }
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
                        restoresRevision: change.restoresRevision, subtitle: change.subtitle))
    }

    private func queue(_ entry: CompanionLibraryOutbox.Entry) throws {
        try loadOutbox()
        try recordHistory(entry)
        var next = outbox
        if entry.action == .editDraft {
            next.queueNewsletterEdit(entry)
        } else {
            if [.editDraft, .editIdea, .trashItem, .restoreItem, .deleteItem, .scheduleDraft].contains(entry.action) {
                next.entries.removeAll {
                    $0.action == entry.action && $0.itemID == entry.itemID && $0.workspaceID == entry.workspaceID
                        && $0.account == entry.account && $0.error != nil
                }
            }
            next.entries.append(entry)
        }
        try persist(next)
        if (entry.isLongFormEdit || entry.requestsWritingHelp == true || entry.publishesXArticle == true) && busy {
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
        if next != outbox { defaults.set(try JSONEncoder().encode(next), forKey: Self.outboxKey) }
        if snapshot != incoming || next != outbox {
            // Clearing an acknowledged local edit must replace the displayed text in the same update.
            state = LibraryState(snapshot: incoming, outbox: next)
        }
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
                            writing.append(.init(id: id, revision: Date.now.ISO8601Format(.init(includingFractionalSeconds: true)), kind: change.writingKind == "newsletter" ? .newsletter : change.writingKind == "article" ? .article : .script,
                                projectID: change.itemID, title: change.title, body: change.text, shortened: false, platform: change.writingKind == "newsletter" ? "substack" : change.writingKind == "article" ? "x" : "youtube", status: "draft", notes: [], referenceID: "STU–003"))
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
            if !changes.isEmpty {
                _ = try await cloud.updateLibrary(workspaceID: incoming.workspaceID, account: key) { library in
                    for change in changes.prefix(max(0, 24 - library.pending.count)) {
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
        if ProcessInfo.processInfo.arguments.contains("--x-thread-fixture") {
            var draft = CompanionLibrary.Item(id: "x-followup-demo", revision: "2026-11-18T16:00:00.000Z", kind: .draft,
                projectID: "studio", title: "I started a cult", body: ["We build useful tools and give them away.", "Read more: https://newsletter.protomota.com/", "Join us: https://protomota.com/discord"].joined(separator: XThreadText.separator),
                shortened: false, platform: "x", status: "draft", notes: [], referenceID: "STU-003")
            draft.format = "thread"
            value.items.insert(draft, at: 0)
        }
        if ProcessInfo.processInfo.arguments.contains("--script-fixture") {
            value.supportsScripts = true
            value.supportsWritingTools = true
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
                        if item.kind == .article { articlePublishing }
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
        .navigationTitle(item.kind == .article ? "X article" : item.kind == .script ? "YouTube script" : "Newsletter")
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
                    MobileWritingTools(title: $scriptTitle, text: $markdown, presented: $showsWritingTools,
                        agent: library.snapshot?.writingAgent ?? "agent", requests: writingRequests, reply: item.writingReply, error: item.writingError) { prompt in
                            save()
                            guard saveError == nil else { throw CompanionLibraryError.invalid }
                            try library.saveChange(.init(action: .note, itemID: item.id, revision: editingRevision ?? item.revision,
                                text: prompt, requestsWritingHelp: true), workspaceID: workspaceID)
                        }
                    Button("Done") { save(ending: true) }.fontWeight(.semibold)
                } else {
                    Menu {
                        if ["draft", "synced"].contains(item.status) {
                            Button("Edit Markdown", systemImage: "pencil", action: beginEditing).disabled(!canEdit)
                            Button("Ask AI…", systemImage: "bubble.left.and.text.bubble.right") { beginEditing(); showsWritingTools = true }.disabled(!canEdit)
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
        let pending = library.pendingChanges(for: item.id).filter { $0.requestsWritingHelp == true }.map {
            StudioWritingRequest(id: $0.id.uuidString, text: $0.text, state: $0.error == nil ? "Saved; waiting for Mac" : "Needs attention")
        }
        return item.notes.enumerated().map { index, text in
            let state = (item.noteStates ?? []).indices.contains(index) ? item.noteStates?[index] : nil
            return StudioWritingRequest(id: "saved-\(index)", text: text, state: state == "applied" ? "Applied" : "Waiting for Mac")
        } + pending
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
                StudioPlatformLabel(name: item.kind == .article ? "x" : item.kind == .script ? "youtube" : "substack", title: item.kind == .article ? "X article" : item.kind == .script ? "YouTube" : "Substack")
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
    let openSettings: () -> Void
    @Environment(\.studioPalette) private var palette
    @State private var selection: String?
    @State private var filter = "Drafts"
    @State private var platformFilter: String?
    @State private var projectFilter: String?
    @AppStorage("inkspring.mobile.draftSort") private var draftSort = DraftSort.lastUpdated
    @State private var editItem: CompanionLibrary.Item?
    @State private var deleteItem: CompanionLibrary.Item?
    @State private var actionError: String?
    @State private var creatingXDraft = false
    @State private var scriptError: String?

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
        return posts + (library.snapshot?.newsletters ?? []) + library.visibleScripts
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
        NavigationSplitView {
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
                } else if library.busy {
                    ProgressView("Checking iCloud…")
                } else {
                    ContentUnavailableView {
                        Label("Library unavailable", systemImage: "icloud")
                    } description: {
                        Text(library.error ?? "Turn on library sync in Settings on your Mac and use the same Apple Account.")
                    } actions: {
                        Button("Open Settings", action: openSettings).buttonStyle(.bordered)
                    }
                }
            }
            .mobileCanvas()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(wideLayout ? .inline : .automatic)
            .toolbar(wideLayout ? .hidden : .visible, for: .tabBar)
            .refreshable { await library.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Long-form") {
                            Button { createWriting("newsletter") } label: { Label { Text("New Substack newsletter") } icon: { platformMenuIcon("substack") } }
                                .accessibilityIdentifier("newsletter.new")
                            Button { createWriting("article") } label: { Label { Text("New X article") } icon: { platformMenuIcon("x") } }
                                .accessibilityIdentifier("article.new")
                            Button { createWriting("script") } label: { Label { Text("New YouTube script") } icon: { platformMenuIcon("youtube") } }
                                .accessibilityIdentifier("script.new")
                        }
                        Section("Social posts") {
                            if library.snapshot?.supportsXThreads == true {
                                Button { creatingXDraft = true } label: { Label { Text("New X post or thread") } icon: { platformMenuIcon("x") } }
                                    .accessibilityIdentifier("x.newDraft")
                            }
                        }
                    } label: { Text("New") }.accessibilityIdentifier("writing.new")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                        .disabled(library.busy)
                }
            }
            .alert("Couldn’t create draft", isPresented: Binding(get: { scriptError != nil }, set: { if !$0 { scriptError = nil } })) { Button("OK") { scriptError = nil } } message: { Text(scriptError ?? "") }
            .navigationDestination(isPresented: $creatingXDraft) {
                MobileXGeneration(library: library, idea: nil)
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

    private func createWriting(_ kind: String) {
        do {
            guard let projectID = projectFilter ?? library.snapshot?.projects.first?.id else { return }
            selection = try library.createScript(projectID: projectID, kind: kind)
            filter = "Drafts"
            platformFilter = kind == "newsletter" ? "substack" : kind == "article" ? "x-article" : "youtube"
        } catch { scriptError = error.localizedDescription }
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
        guard let mark = PlatformMark.bitmap(platform == "x-article" ? "x" : platform) ?? (platform == "youtube" ? UIImage(systemName: "play.rectangle.fill") : nil) else { return Image(systemName: "link") }
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
    var reviewPlatform: String { kind == .article ? "x-article" : platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

private func reviewPlatformName(_ platform: String) -> String {
    switch platform {
    case "x": "X"
    case "linkedin": "LinkedIn"
    case "tiktok": "TikTok"
    case "youtube": "YouTube"
    case "x-article": "X article"
    default: platform.capitalized
    }
}

private struct MobileXGeneration: View {
    @Environment(\.studioPalette) private var palette
    let library: MobileLibrary
    let idea: CompanionLibrary.Item?
    @State private var projectID = ""
    @State private var title = ""
    @State private var brief = ""
    @State private var format = "post"
    @State private var message: String?
    @State private var queued = false

    var body: some View {
        Form {
            Section {
                if idea == nil, let projects = library.snapshot?.projects {
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
                        try library.saveChange(.init(action: .addIdea, itemID: idea?.id ?? projectID,
                                                     revision: idea?.revision ?? "", title: title, text: brief,
                                                     xFormat: format, generatesXDraft: true), workspaceID: snapshot.workspaceID)
                        queued = true
                        message = "Queued for your Mac. The generated draft will appear in Review."
                    } catch { message = error.localizedDescription }
                }
                .disabled(queued || library.snapshot?.supportsXThreads != true || projectID.isEmpty ||
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
            projectID = idea?.projectID ?? library.snapshot?.projects.first?.id ?? ""
            title = idea?.title ?? ""
            brief = idea?.body ?? ""
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
                StudioXPostEditor(text: $text, format: $format).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                MobileWritingTools(title: $title, text: $text, presented: $showsWritingTools,
                    agent: library.snapshot?.writingAgent ?? "agent", requests: item.notes.enumerated().map { index, text in
                        StudioWritingRequest(id: "saved-\(index)", text: text,
                            state: (item.noteStates ?? []).indices.contains(index) && item.noteStates?[index] == "applied" ? "Applied" : "Waiting for Mac")
                    } + library.pendingChanges(for: item.id).filter { $0.requestsWritingHelp == true }.map {
                        StudioWritingRequest(id: $0.id.uuidString, text: $0.text, state: "Waiting for Mac")
                    }, reply: item.writingReply, error: item.writingError) { prompt in
                        guard save() else { throw CompanionLibraryError.invalid }
                        try library.saveChange(.init(action: .note, itemID: item.id, revision: item.revision,
                            text: prompt, requestsWritingHelp: true), workspaceID: workspaceID)
                    }
                Button("Done") { if save() { if let close { close() } else { dismiss() } } }
            }
        }
        .task {
            guard !initialized else { return }
            let pending = library.pendingChanges(for: item.id).last { [.editDraft, .editIdea].contains($0.action) }
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

private struct MobileReviewDetail: View {
    let item: CompanionLibrary.Item
    let library: MobileLibrary
    let workspaceID: UUID
    @Environment(\.studioPalette) private var palette
    @Environment(\.mobileWideLayout) private var wideLayout
    @State private var note = ""
    @State private var message: String?
    @State private var savedNoteID: UUID?
    @State private var editingDraft = false
    @State private var choosingSchedule = false
    @State private var generatingXDraft = false
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

    private var inTrash: Bool { item.isTrashed == true }

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
        Group {
            if editingDraft {
                MobileItemEditor(item: item, library: library, workspaceID: workspaceID, bodyFirst: editBodyFirst, close: { editingDraft = false })
            } else { preview }
        }
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
                                Text(posts[index]).font(.body).foregroundStyle(palette.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("x.reply.\(index)")
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
            if item.kind == .idea, !inTrash, library.snapshot?.supportsXThreads == true {
                Section {
                    Button("Draft for X", systemImage: "square.and.pencil") { generatingXDraft = true }
                }
                .listRowBackground(palette.card)
            }
            if item.isTrashed != true {
            Section {
                ForEach(Array(item.notes.enumerated()), id: \.offset) { index, text in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text)
                        if let dates = item.noteDates, dates.indices.contains(index), let timestamp = date(dates[index]) {
                            Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let states = item.noteStates, states.indices.contains(index), let state = states[index] {
                            let label = state == "applied" ? "Revision applied" :
                                state == "waitingForDraft" ? "Waiting for an editable draft on Mac" : "Waiting for your Mac to revise"
                            Label(label, systemImage: state == "applied" ? "checkmark" : "clock")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(library.pendingChanges(for: item.id).filter { $0.action == .note }) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                        if let error = entry.error {
                            Label(error, systemImage: "exclamationmark.icloud").font(.footnote)
                        }
                    }
                }
                TextField(item.kind == .draft ? "What should change?" : "Write a comment", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($editingNote)
                if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(item.kind == .draft ? "Add revision comment" : "Add comment") {
                        if saveNote() { editingNote = false }
                    }
                    .disabled(note.utf16.count > 1000)
                }
                if note.utf16.count > 1000 {
                    Text("Use up to 1,000 characters.").font(.footnote).foregroundStyle(.secondary)
                }
                if let savedNoteID {
                    let entry = library.pendingChanges(for: item.id).first { $0.id == savedNoteID }
                    let uploaded = entry == nil || library.snapshot?.pending.contains { $0.id == savedNoteID } == true
                    if entry?.error == nil {
                        Label(uploaded ? "Comment synced" : "Comment saved · iCloud sync pending", systemImage: "checkmark")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(item.kind == .draft ? "Revision comments" : "Comments")
            } footer: {
                if item.kind == .draft {
                    Text("Inkspring on your Mac checks for new comments every five minutes and applies them to editable, unscheduled drafts using your writing connection.")
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
                Section {
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
        .navigationDestination(isPresented: $generatingXDraft) {
            MobileXGeneration(library: library, idea: item)
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
        let change = CompanionLibrary.Change(action: .note, itemID: item.id, revision: item.revision, text: text)
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
