import CloudKit
import SwiftUI

@MainActor @Observable
final class MobileLibrary {
    var snapshot: CompanionLibrary?
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
    private let defaults = UserDefaults.standard
    private static let outboxKey = "inkspring.mobile.libraryOutbox.v1"
    private static let legacyIdeasKey = "inkspring.mobile.localIdeas.v1"
    private var outbox = CompanionLibraryOutbox()
    private var outboxLoaded = false

    var pendingIdeas: [CompanionLibraryOutbox.Entry] {
        outbox.entries.reversed().filter {
            $0.action == .addIdea && ($0.account == nil || $0.account == account)
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
        }
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
        pendingChanges(for: itemID).contains { $0.action != .note && $0.error == nil }
            || snapshot?.pending.contains { $0.itemID == itemID && $0.action != .note } == true
    }

    func canDelete(_ itemID: String) -> Bool {
        if !isChanging(itemID) { return true }
        guard let move = pendingTrash(for: itemID) else { return false }
        return pendingChanges(for: itemID).allSatisfy { $0.id == move.id || $0.action == .note || $0.error != nil }
            && snapshot?.pending.contains { $0.itemID == itemID && $0.id != move.requestID && $0.action != .note } != true
    }

    private func pendingTrash(for itemID: String) -> CompanionLibraryOutbox.Entry? {
        pendingChanges(for: itemID).last { $0.movesToTrash && $0.error == nil }
    }

    func saveIdea(title: String, text: String, projectID: String?) throws {
        try queue(.init(id: UUID(), action: .addIdea, itemID: projectID, revision: "", title: title, text: text,
                        workspaceID: snapshot?.workspaceID, account: account))
    }

    func saveChange(_ change: CompanionLibrary.Change, workspaceID: UUID) throws {
        guard let account, snapshot?.workspaceID == workspaceID else { throw CompanionScheduleError.changed }
        guard change.valid else { throw CompanionLibraryError.invalid }
        if change.action == .scheduleDraft, snapshot?.postingWindows == nil { throw CompanionLibraryError.disabled }
        let afterTrash = change.action == .deleteItem ? pendingTrash(for: change.itemID)?.id : nil
        try queue(.init(id: change.id, action: change.action, itemID: change.itemID, revision: change.revision,
                        title: change.title, text: change.text, workspaceID: workspaceID, account: account,
                        afterTrash: afterTrash))
    }

    private func queue(_ entry: CompanionLibraryOutbox.Entry) throws {
        try loadOutbox()
        var next = outbox
        if [.editDraft, .editIdea, .trashItem, .restoreItem, .deleteItem, .scheduleDraft].contains(entry.action) {
            next.entries.removeAll {
                $0.action == entry.action && $0.itemID == entry.itemID && $0.workspaceID == entry.workspaceID
                    && $0.account == entry.account && $0.error != nil
            }
        }
        next.entries.append(entry)
        try persist(next)
        Task { await refresh() }
    }

    private func loadOutbox() throws {
        guard !outboxLoaded else { return }
        if let data = defaults.data(forKey: Self.outboxKey) {
            outbox = try JSONDecoder().decode(CompanionLibraryOutbox.self, from: data)
        } else if let data = defaults.data(forKey: Self.legacyIdeasKey), !data.isEmpty {
            var migrated = outbox
            try migrated.migrateIdeas(from: data)
            try persist(migrated)
        }
        outboxLoaded = true
    }

    private func persist(_ value: CompanionLibraryOutbox) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: Self.outboxKey)
        outbox = value
    }

    private func prepareChanges(in library: CompanionLibrary, account: String) throws -> [CompanionLibrary.Change] {
        var next = outbox
        let changes = next.prepare(for: library, account: account)
        try persist(next)
        return changes
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
            if revision != accountRevision {
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
                var fixture = snapshot ?? Self.fixture
                for change in try prepareChanges(in: fixture, account: "fixture").prefix(24 - fixture.pending.count) {
                    try fixture.enqueue(change)
                }
                snapshot = fixture
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
                snapshot = nil
                remoteWorkspaceFound = nil
                lastCloudContact = nil
            }
            account = key
            let schedule = try await cloud.load(confirmedAccount: key)
            guard revision == accountRevision else { return }
            lastCloudContact = .now
            remoteWorkspaceFound = schedule != nil
            guard let schedule, schedule.sharing else {
                snapshot = nil
                error = "Turn on schedule and library sync in Inkspring on your Mac."
                return
            }
            if snapshot?.workspaceID != schedule.workspaceID { snapshot = nil }
            let library = try await cloud.loadLibrary(workspaceID: schedule.workspaceID, account: key)
            guard revision == accountRevision else { return }
            lastCloudContact = .now
            snapshot = library?.enabled == true ? library : nil
            error = snapshot == nil ? CompanionLibraryError.disabled.localizedDescription : nil
            guard let snapshot else { return }
            let changes = try prepareChanges(in: snapshot, account: key)
            guard !changes.isEmpty else { return }
            let updated = try await cloud.updateLibrary(workspaceID: snapshot.workspaceID, account: key) { library in
                for change in changes.prefix(max(0, 24 - library.pending.count)) {
                    do { try library.enqueue(change) }
                    catch CompanionLibraryError.full { break }
                }
            }
            if revision == accountRevision {
                self.snapshot = updated
                lastCloudContact = .now
            }
        } catch {
            guard revision == accountRevision else { return }
            let failure = error as NSError
            syncErrorCode = "\(failure.domain) (\(failure.code))"
            if !checkedAccount { accountStatus = "Unavailable" }
            if (error as? CompanionScheduleError) == .accountChanged {
                snapshot = nil
                account = nil
                accountStatus = "Not checked"
                remoteWorkspaceFound = nil
                lastCloudContact = nil
            }
            self.error = error.localizedDescription
        }
    }

    func accountChanged() {
        accountRevision = UUID()
        snapshot = nil
        account = nil
        accountStatus = "Not checked"
        remoteWorkspaceFound = nil
        lastCheck = nil
        lastCloudContact = nil
        syncErrorCode = nil
    }

#if DEBUG
    private static var fixture: CompanionLibrary {
        var value = CompanionLibrary(workspaceID: UUID(uuidString: "de6b0e64-2e7a-4bc6-a4b2-79a3e63b8e1a")!)
        value.projects = [.init(id: "studio", name: "Studio")]
        value.items = [
            .init(id: "draft", revision: "1", kind: .draft, projectID: "studio", title: "A quieter way to draft",
                  body: "Start with the decision you made and why it mattered. One concrete example is enough.",
                  shortened: false, platform: "linkedin", status: "ready", notes: [], attachment: .video),
            .init(id: "idea", revision: "1", kind: .idea, projectID: "studio", title: "Show the unfinished work",
                  body: "Explain a trade-off from a work in progress and ask readers how they would handle it.",
                  shortened: false, platform: "", status: "draft", notes: [])
        ]
        value.supportsDraftEdits = true
        value.supportsItemManagement = true
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

struct MobileReviewView: View {
    @Environment(\.mobileWideLayout) private var wideLayout
    let library: MobileLibrary
    let isSelected: Bool
    let openSettings: () -> Void
    @Environment(\.studioPalette) private var palette
    @State private var selection: String?
    @State private var filter = "Drafts"
    @State private var platformFilter: String?
    @State private var editItem: CompanionLibrary.Item?
    @State private var deleteItem: CompanionLibrary.Item?
    @State private var actionError: String?

    private static let filters = ["Drafts", "Ideas", "Trash"]

    private var drafts: [CompanionLibrary.Item] {
        library.visibleItems.filter { $0.kind == .draft && $0.isTrashed != true }
    }

    private var platformOptions: [String] {
        var platforms = Set(drafts.map(\.reviewPlatform).filter { !$0.isEmpty })
        if let platformFilter { platforms.insert(platformFilter) }
        return platforms.sorted { reviewPlatformName($0).localizedStandardCompare(reviewPlatformName($1)) == .orderedAscending }
    }

    private var items: [CompanionLibrary.Item] {
        switch filter {
        case "Drafts":
            guard let platformFilter else { return drafts }
            return drafts.filter { $0.reviewPlatform == platformFilter }
        case "Trash": return library.visibleItems.filter { $0.isTrashed == true }
        default: return library.visibleItems.filter { $0.isTrashed != true && $0.kind == .idea }
        }
    }

    private var emptyMessage: String {
        if filter == "Trash" { return "Trash is empty." }
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
                                if filter == "Drafts", !platformOptions.isEmpty { platformMenu }
                            }
                            .listRowBackground(Color.clear)
                        }
                        Section {
                            if items.isEmpty {
                                Text(emptyMessage)
                                    .foregroundStyle(.secondary)
                                    .listRowBackground(palette.card)
                            }
                            ForEach(items) { item in
                                let selected = wideLayout && selection == item.id
                                let showsProjectStatus = filter != "Drafts"
                                let showsPlatform = item.kind == .draft && !item.reviewPlatform.isEmpty
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
                                            if library.isChanging(item.id) {
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
                                    if item.isTrashed == true {
                                        Button("Restore", systemImage: "arrow.uturn.backward") { restore(item, in: snapshot) }
                                            .disabled(library.isChanging(item.id))
                                    } else {
                                        Button("Edit", systemImage: "pencil") { editItem = item }
                                    }
                                    Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.body }
                                    Button(item.isTrashed == true ? "Delete permanently…" : item.kind == .idea ? "Skip idea" : "Move to Trash", systemImage: "trash", role: .destructive) { requestRemoval(item) }
                                        .disabled(item.isTrashed == true ? !library.canDelete(item.id) : library.isChanging(item.id))
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(item.isTrashed == true ? "Delete" : item.kind == .idea ? "Skip" : "Trash", systemImage: "trash", role: .destructive) { requestRemoval(item) }
                                        .disabled(item.isTrashed == true ? !library.canDelete(item.id) : library.isChanging(item.id))
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if item.isTrashed == true {
                                        Button("Restore", systemImage: "arrow.uturn.backward") { restore(item, in: snapshot) }.tint(palette.iconAccent)
                                            .disabled(library.isChanging(item.id))
                                    } else {
                                        Button("Edit", systemImage: "pencil") { editItem = item }.tint(palette.iconAccent)
                                    }
                                }
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
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                        .disabled(library.busy)
                }
            }
        } detail: {
            Group {
                if let snapshot = library.snapshot, let item = items.first(where: { $0.id == selection }) {
                    MobileReviewDetail(item: item, library: library, workspaceID: snapshot.workspaceID)
                        .id("\(snapshot.workspaceID)-\(item.id)")
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
        .sheet(item: $editItem) { item in
            if let snapshot = library.snapshot {
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
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(palette.iconAccent)
                Text(title).foregroundStyle(palette.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.muted)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(platformFilter == nil ? palette.control : palette.active, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.line).allowsHitTesting(false) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by platform")
        .accessibilityValue(title)
        .accessibilityIdentifier("review.platformFilter")
    }

    private func platformMenuIcon(_ platform: String) -> Image {
        guard let mark = PlatformMark.bitmap(platform) else { return Image(systemName: "link") }
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
    var reviewPlatform: String { platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

private func reviewPlatformName(_ platform: String) -> String {
    switch platform {
    case "x": "X"
    case "linkedin": "LinkedIn"
    case "tiktok": "TikTok"
    default: platform.capitalized
    }
}

private struct MobileItemEditor: View {
    let item: CompanionLibrary.Item
    let library: MobileLibrary
    let workspaceID: UUID
    var bodyFirst = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studioPalette) private var palette
    @State private var title = ""
    @State private var text = ""
    @State private var message: String?
    @FocusState private var focus: Field?
    private enum Field { case title, text }

    private var unavailable: String? {
        if item.isTrashed == true { return "Restore this item from Trash before editing." }
        if item.shortened { return "This is a shortened copy. Update and open Inkspring on Mac to sync the complete text before editing." }
        if ["posting", "posted", "uncertain"].contains(item.status) {
            return "This post is publishing or published. Check its status before editing."
        }
        if item.kind == .idea && !["draft", "skipped"].contains(item.status) { return "This idea already has drafts. Edit those posts instead." }
        if library.pendingChanges(for: item.id).contains(where: { $0.action != .note && $0.error == nil }) ||
            library.snapshot?.pending.contains(where: { $0.itemID == item.id && $0.action != .note }) == true {
            return "Your previous change is saved. Keep Inkspring open on Mac to finish syncing before editing again."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let unavailable { Section { Label(unavailable, systemImage: "info.circle") } }
                Section("Title") {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.body).lineLimit(1...5).focused($focus, equals: .title)
                        .accessibilityIdentifier("mobile.edit.title")
                }.listRowBackground(palette.card)
                Section(item.kind == .draft ? "Post text" : "Idea") {
                    TextEditor(text: $text).font(.body).frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .text).accessibilityLabel("Post text")
                        .accessibilityIdentifier("mobile.edit.body")
                }.listRowBackground(palette.card)
                if let message { Text(message).foregroundStyle(palette.danger) }
                Section {
                    Text("Save keeps your changes on this device and syncs them automatically through iCloud.").font(.footnote)
                    if ["queued", "due"].contains(item.status) {
                        Text("Saving changes returns this post to Ready to schedule. Choose a new posting time after reviewing it.").font(.footnote)
                    }
                    if (item.kind == .draft ? library.snapshot?.supportsDraftEdits : library.snapshot?.supportsItemManagement) != true {
                        Text("Update and open Inkspring on Mac to finish syncing these changes.").font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(palette.canvas)
            .navigationTitle(item.kind == .draft ? "Edit draft" : "Edit idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try library.saveChange(.init(action: item.kind == .draft ? .editDraft : .editIdea,
                                itemID: item.id, revision: item.revision, title: title, text: text), workspaceID: workspaceID)
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(unavailable != nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              title.utf16.count > (item.kind == .draft ? 200 : 140) || text.utf16.count > (item.kind == .draft ? 40_000 : 2000) ||
                              (item.kind == .idea && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .task {
                let pending = library.pendingChanges(for: item.id).last { [.editDraft, .editIdea].contains($0.action) }
                title = pending?.title ?? item.title
                text = pending?.text ?? item.body
                if unavailable == nil { focus = bodyFirst ? .text : .title }
            }
        }
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
    @State private var needsMacUpdate = false
    @State private var confirmDeletion = false
    @State private var editBodyFirst = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingNote: Bool

    private var hasPendingChange: Bool {
        library.pendingChanges(for: item.id).contains { $0.action != .note && $0.error == nil }
            || library.snapshot?.pending.contains { $0.itemID == item.id && $0.action != .note } == true
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
                if let updated = date(item.revision) {
                    Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if inTrash {
                    Text(pendingEdit?.text ?? item.body).foregroundStyle(palette.text).textSelection(.enabled)
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
                if item.shortened { Text("Open the full text on your Mac.").font(.footnote).foregroundStyle(.secondary) }
                if let error = pendingEdit?.error {
                    Label(error, systemImage: "exclamationmark.icloud").font(.footnote)
                }

            }
            .listRowBackground(palette.card)
            if item.isTrashed != true {
            Section("Review notes") {
                ForEach(Array(item.notes.enumerated()), id: \.offset) { index, text in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text)
                        if let dates = item.noteDates, dates.indices.contains(index), let timestamp = date(dates[index]) {
                            Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
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
                TextField("Write a review note", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($editingNote)
                    .onChange(of: editingNote) { _, focused in
                        if !focused { saveNote() }
                    }
                if editingNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Done") { editingNote = false }
                }
                if note.utf16.count > 1000 {
                    Text("Use up to 1,000 characters.").font(.footnote).foregroundStyle(.secondary)
                }
                if let savedNoteID {
                    let entry = library.pendingChanges(for: item.id).first { $0.id == savedNoteID }
                    let uploaded = entry == nil || library.snapshot?.pending.contains { $0.id == savedNoteID } == true
                    if entry?.error == nil {
                        Label(uploaded ? "Saved to iCloud" : "Saved · iCloud sync pending", systemImage: "checkmark")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
        .onDisappear { saveNote() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if item.isTrashed != true {
                    Button("Edit", systemImage: "pencil") { editingDraft = true }
                }
                moreActions
            }
        }
        .sheet(isPresented: $editingDraft) {
            MobileItemEditor(item: item, library: library, workspaceID: workspaceID, bodyFirst: editBodyFirst)
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

    private func saveNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 1000 else { return }
        let change = CompanionLibrary.Change(action: .note, itemID: item.id, revision: item.revision, text: text)
        if save(change) {
            note = ""
            savedNoteID = change.id
        }
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
