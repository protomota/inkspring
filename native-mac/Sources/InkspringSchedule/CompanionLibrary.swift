import Foundation

public struct CompanionPostingWindow: Codable, Equatable, Sendable {
    public let firstHour: Int
    public let lastHour: Int

    public init(firstHour: Int = 9, lastHour: Int = 17) {
        self.firstHour = min(max(firstHour, 0), 23)
        self.lastHour = min(max(lastHour, self.firstHour), 23)
    }

    public var hours: ClosedRange<Int> {
        let normalized = Self(firstHour: firstHour, lastHour: lastHour)
        return normalized.firstHour...normalized.lastHour
    }
}

public struct CompanionLibrary: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public var enabled = true
    public var projects: [Project] = []
    public var items: [Item] = []
    public var pending: [Change] = []
    public var results: [Result] = []
    public var hasMore = false
    public var supportsDraftEdits: Bool?
    public var supportsItemManagement: Bool?
    public var postingWindows: [String: CompanionPostingWindow]?
    public var postingTimeZone: String?
    public var updatedAt = Date.now

    public init(workspaceID: UUID) { self.workspaceID = workspaceID }

    public struct Project: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case draft, idea }
        public enum Attachment: String, Codable, Sendable { case image, video }
        public let id: String
        public let revision: String
        public let kind: Kind
        public let projectID: String
        public let title: String
        public let body: String
        public let shortened: Bool
        public let platform: String
        public let status: String
        public let notes: [String]
        public let noteDates: [String]?
        public let attachment: Attachment?
        public var isTrashed: Bool?
        public var requiresMacScheduling: Bool?

        public init(id: String, revision: String, kind: Kind, projectID: String, title: String, body: String,
                    shortened: Bool, platform: String, status: String, notes: [String],
                    noteDates: [String]? = nil, attachment: Attachment? = nil) {
            self.id = id
            self.revision = revision
            self.kind = kind
            self.projectID = projectID
            self.title = title
            self.body = body
            self.shortened = shortened
            self.platform = platform
            self.status = status
            self.notes = notes
            self.noteDates = noteDates
            self.attachment = attachment
        }
    }

    public struct Change: Codable, Equatable, Identifiable, Sendable {
        public enum Action: String, Codable, Sendable {
            case addIdea, note, skipIdea, restoreIdea, editDraft, editIdea, trashItem, restoreItem, deleteItem, scheduleDraft
        }
        public let id: UUID
        public let action: Action
        public let itemID: String
        public let revision: String
        public let title: String
        public let text: String

        public init(id: UUID = UUID(), action: Action, itemID: String, revision: String = "",
                    title: String = "", text: String = "") {
            self.id = id
            self.action = action
            self.itemID = itemID
            self.revision = revision
            self.title = action == .editDraft ? title : title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = action == .editDraft ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var valid: Bool {
            guard !itemID.isEmpty, itemID.utf8.count <= 200, revision.utf8.count <= 100 else { return false }
            switch action {
            case .addIdea: return (1...140).contains(title.utf16.count) && (1...2000).contains(text.utf16.count)
            case .note: return !revision.isEmpty && (1...1000).contains(text.utf16.count) && title.isEmpty
            case .skipIdea, .restoreIdea: return !revision.isEmpty && text.isEmpty && title.isEmpty
            case .trashItem, .restoreItem, .deleteItem: return !revision.isEmpty && text.isEmpty && title.isEmpty
            case .editIdea:
                return !revision.isEmpty && (1...140).contains(title.utf16.count) && (1...2000).contains(text.utf16.count)
            case .editDraft:
                return !revision.isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && title.utf16.count <= 200 && text.utf16.count <= 40_000
            case .scheduleDraft:
                return !revision.isEmpty && title.isEmpty && postingHour != nil
            }
        }

        public var postingHour: Date? {
            guard action == .scheduleDraft, text.utf8.count <= 32 else { return nil }
            return try? Date(text, strategy: .iso8601)
        }
    }

    public struct Result: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let error: String?
        public init(id: UUID, error: String? = nil) { self.id = id; self.error = error }
    }

    public mutating func enqueue(_ change: Change) throws {
        guard enabled else { throw CompanionLibraryError.disabled }
        guard change.valid else { throw CompanionLibraryError.invalid }
        if change.action == .editDraft, supportsDraftEdits != true { throw CompanionLibraryError.disabled }
        if [.editIdea, .trashItem, .restoreItem, .deleteItem].contains(change.action), supportsItemManagement != true { throw CompanionLibraryError.disabled }
        if change.action == .scheduleDraft, postingWindows == nil { throw CompanionLibraryError.disabled }
        if pending.contains(where: { $0.id == change.id }) || results.contains(where: { $0.id == change.id }) { return }
        guard pending.count < 24 else { throw CompanionLibraryError.full }
        let limit = change.action == .editDraft ? 245_000 : 14_000
        guard try JSONEncoder().encode(change).count <= limit else { throw CompanionLibraryError.invalid }
        guard try JSONEncoder().encode(pending + [change]).count <= 280_000 else { throw CompanionLibraryError.full }
        pending.append(change)
    }

    public mutating func acknowledge(_ finished: [Result]) {
        let ids = Set(finished.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        results = Array((results.filter { !ids.contains($0.id) } + finished).suffix(48))
    }

    public mutating func clear() {
        enabled = false
        projects = []
        items = []
        pending = []
        results = []
        hasMore = false
        updatedAt = .now
        supportsDraftEdits = nil
        supportsItemManagement = nil
        postingWindows = nil
        postingTimeZone = nil
    }
}

public enum CompanionLibraryError: LocalizedError {
    case disabled, invalid, full

    public var errorDescription: String? {
        switch self {
        case .disabled: "Turn on library sync in Inkspring on your Mac."
        case .invalid: "Check the text and try again."
        case .full: "There are changes waiting for your Mac. Open Inkspring on your Mac to sync them."
        }
    }
}

struct CompanionLibraryOutbox: Codable {
    struct Entry: Codable, Identifiable {
        var id: UUID
        let action: CompanionLibrary.Change.Action
        var itemID: String?
        var revision: String
        let title: String
        let text: String
        var workspaceID: UUID?
        var account: String?
        var error: String?
        var afterTrash: UUID?
        var retryID: UUID?
        var trashRetries: Int?

        var requestID: UUID { retryID ?? id }
        var movesToTrash: Bool { action == .trashItem || action == .skipIdea }

        var change: CompanionLibrary.Change? {
            itemID.map { .init(id: requestID, action: action, itemID: $0, revision: revision, title: title, text: text) }
        }
    }

    var entries: [Entry] = []

    mutating func migrateIdeas(from data: Data) throws {
        struct SavedIdea: Decodable {
            struct Delivery: Decodable {
                let workspaceID: UUID
                let changeID: UUID
            }
            let id: UUID
            let title: String
            let body: String
            let delivery: Delivery?
            let failure: String?
        }
        for idea in try JSONDecoder().decode([SavedIdea].self, from: data) {
            let id = idea.delivery?.changeID ?? (idea.failure == nil ? idea.id : UUID())
            guard !entries.contains(where: { $0.id == id }) else { continue }
            entries.append(.init(id: id, action: .addIdea, revision: "", title: idea.title, text: idea.body,
                                 workspaceID: idea.delivery?.workspaceID))
        }
    }

    mutating func prepare(for library: CompanionLibrary, account: String) -> [CompanionLibrary.Change] {
        var changes: [CompanionLibrary.Change] = []
        let results = Dictionary(library.results.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let pendingIDs = Set(library.pending.map(\.id))
        let items = Dictionary(library.items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let requestIDs = Dictionary(entries.map { ($0.id, $0.requestID) }, uniquingKeysWith: { _, latest in latest })
        let retryItems = Dictionary(entries.compactMap { entry -> (UUID, CompanionLibrary.Item)? in
            guard entry.movesToTrash, entry.error == nil, (entry.trashRetries ?? 0) < 3,
                  entry.workspaceID == library.workspaceID, entry.account == account,
                  let error = results[entry.requestID]?.error,
                  ["This item changed since you opened it.", "Wait for the current publishing attempt to finish."].contains(error),
                  let itemID = entry.itemID, let item = items[itemID], item.isTrashed != true else { return nil }
            return (entry.id, item)
        }, uniquingKeysWith: { _, latest in latest })
        entries = entries.compactMap { entry in
            var entry = entry
            guard entry.workspaceID == nil || entry.workspaceID == library.workspaceID,
                  entry.account == nil || entry.account == account else { return entry }
            if let item = retryItems[entry.id] {
                entry.retryID = UUID()
                entry.trashRetries = (entry.trashRetries ?? 0) + 1
                entry.revision = item.revision
            } else if let result = results[entry.requestID] {
                guard let error = result.error else { return nil }
                if entry.movesToTrash, let itemID = entry.itemID, items[itemID]?.isTrashed == true { return nil }
                entry.error = error
            } else if entry.action == .addIdea, items[entry.id.uuidString.lowercased()] != nil {
                return nil
            }
            entry.workspaceID = library.workspaceID
            entry.account = account
            if let afterTrash = entry.afterTrash {
                guard entry.error == nil, retryItems[afterTrash] == nil,
                      let result = results[requestIDs[afterTrash] ?? afterTrash] else { return entry }
                guard let itemID = entry.itemID, let item = items[itemID], item.isTrashed == true else {
                    entry.error = result.error == nil ? "This item is no longer available in Trash. Refresh and try again."
                        : "This item could not be moved to Trash. Try moving it again before deleting."
                    return entry
                }
                entry.revision = item.revision
                entry.afterTrash = nil
            }
            if entry.action == .addIdea,
               entry.itemID == nil || !library.projects.contains(where: { $0.id == entry.itemID }),
               !pendingIDs.contains(entry.id),
               let project = library.projects.first {
                if entry.error != nil { entry.id = UUID() }
                entry.itemID = project.id
                entry.error = nil
            }
            if entry.action == .trashItem, entry.revision == "pending-add",
               let itemID = entry.itemID, let item = items[itemID] {
                entry.revision = item.revision
            }
            if entry.error == nil, !pendingIDs.contains(entry.requestID), let change = entry.change,
               entry.revision != "pending-add",
               (entry.action != .editDraft || library.supportsDraftEdits == true),
               (entry.action != .scheduleDraft || library.postingWindows != nil),
               (![.editIdea, .trashItem, .restoreItem, .deleteItem].contains(entry.action) || library.supportsItemManagement == true) {
                changes.append(change)
            }
            return entry
        }
        return changes
    }
}
