import CryptoKit
import Foundation

public enum XPostStyle: String, CaseIterable, Identifiable, Sendable {
    case post, followup, thread
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .post: "Single post"
        case .followup: "Post with reply"
        case .thread: "Thread"
        }
    }
    public var instructions: String {
        switch self {
        case .post: "Write one X post."
        case .followup: "Write exactly two X posts. Make the opening substantial and put all supplied URLs in the follow-up reply."
        case .thread: "Write a coherent thread of 3 to 8 X posts. Put supplied URLs in the final reply."
        }
    }
}

public enum XThreadText {
    public static let separator = "\n\n"
    public static let limit = 25
    private static let boundary = #"\r?\n\s*\r?\n"#

    public static func posts(in text: String) -> [String] {
        text.replacingOccurrences(of: boundary, with: "\u{0}", options: .regularExpression)
            .split(separator: "\u{0}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func singlePost(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: boundary, with: "\n", options: .regularExpression)
    }

    public static func weight(_ text: String) -> Int {
        let links = text.replacingOccurrences(of: #"https?://\S+"#, with: String(repeating: "x", count: 23),
                                              options: .regularExpression)
        return links.unicodeScalars.reduce(0) { $0 + ($1.value > 0x10ff ? 2 : 1) }
    }

    public static func valid(_ text: String, format: String) -> Bool {
        let posts = posts(in: text)
        let count = format == "followup" ? 2...2 : 2...limit
        return count.contains(posts.count) && posts.allSatisfy { weight($0) <= 280 }
    }
}

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
    // Separate from items so older companions can still decode the library.
    public var newsletters: [Item]?
    public var hasMoreNewsletters: Bool?
    public var fullText: TextVersion?
    public var pending: [Change] = []
    public var results: [Result] = []
    public var hasMore = false
    public var supportsDraftEdits: Bool?
    public var supportsNewsletterEdits: Bool?
    public var supportsItemManagement: Bool?
    public var supportsXThreads: Bool?
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
        public enum Kind: String, Codable, Sendable { case draft, idea, newsletter }
        public enum Attachment: String, Codable, Sendable { case image, video }
        public let id: String
        public let revision: String
        public let kind: Kind
        public let projectID: String
        public let title: String
        public var body: String
        public var shortened: Bool
        public let platform: String
        public let status: String
        public let notes: [String]
        public let noteDates: [String]?
        public let referenceID: String?
        public var format: String?
        public var generationStatus: String?
        public var noteStates: [String?]?
        public let attachment: Attachment?
        public var isTrashed: Bool?
        public var requiresMacScheduling: Bool?

        public init(id: String, revision: String, kind: Kind, projectID: String, title: String, body: String,
                    shortened: Bool, platform: String, status: String, notes: [String],
                    noteDates: [String]? = nil, attachment: Attachment? = nil, referenceID: String? = nil) {
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
            self.referenceID = referenceID
        }

        public var indexEntry: Item {
            guard body.utf8.count > 512 else { return self }
            var entry = self
            entry.body = ""
            entry.shortened = true
            return entry
        }
    }

    public struct TextVersion: Codable, Equatable, Sendable {
        public static let partSize = 500_000
        public let digest: String
        public let partCount: Int

        public init(data: Data) {
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            partCount = data.isEmpty ? 0 : (data.count - 1) / Self.partSize + 1
        }
    }

    public static func encodeFullText(_ bodies: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try (encoder.encode(bodies) as NSData).compressed(using: .zlib) as Data
    }

    public mutating func separateFullText() throws -> Data? {
        var bodies: [String: String] = [:]
        func separate(_ item: Item) -> Item {
            let entry = item.indexEntry
            if entry.shortened && !item.shortened { bodies[item.id] = item.body }
            return entry
        }
        items = items.map(separate)
        newsletters = newsletters?.map(separate)
        let data = try bodies.isEmpty ? nil : Self.encodeFullText(bodies)
        fullText = data.map(TextVersion.init(data:))
        return data
    }

    public mutating func applyFullText(_ data: Data) throws {
        guard fullText == TextVersion(data: data) else { throw CompanionScheduleError.changed }
        let decoded = try (data as NSData).decompressed(using: .zlib) as Data
        let bodies = try JSONDecoder().decode([String: String].self, from: decoded)
        func complete(_ item: Item) throws -> Item {
            guard item.shortened else { return item }
            guard let body = bodies[item.id] else { throw CompanionScheduleError.changed }
            var item = item
            item.body = body
            item.shortened = false
            return item
        }
        let completedItems = try items.map(complete)
        let completedNewsletters = try newsletters?.map(complete)
        items = completedItems
        newsletters = completedNewsletters
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
        // Newsletter edits use the existing wire action so older clients can decode the queue.
        public let editsNewsletter: Bool?
        public let baseNewsletterText: String?
        public let xFormat: String?
        public let generatesXDraft: Bool?

        public init(id: UUID = UUID(), action: Action, itemID: String, revision: String = "",
                    title: String = "", text: String = "", editsNewsletter: Bool? = nil,
                    baseNewsletterText: String? = nil, xFormat: String? = nil, generatesXDraft: Bool? = nil) {
            self.id = id
            self.action = action
            self.itemID = itemID
            self.revision = revision
            self.title = action == .editDraft ? title : title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = action == .editDraft ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.editsNewsletter = editsNewsletter
            self.baseNewsletterText = baseNewsletterText
            self.xFormat = xFormat
            self.generatesXDraft = generatesXDraft
        }

        public var valid: Bool {
            guard !itemID.isEmpty, itemID.utf8.count <= 200, revision.utf8.count <= 100 else { return false }
            if generatesXDraft == true {
                return action == .addIdea && editsNewsletter != true && baseNewsletterText == nil
                    && xFormat.flatMap(XPostStyle.init(rawValue:)) != nil
                    && (1...200).contains(title.utf16.count) && (1...10_000).contains(text.utf16.count)
                    && !text.contains("\0")
            }
            if let xFormat {
                guard action == .editDraft, editsNewsletter != true, XPostStyle(rawValue: xFormat) != nil else { return false }
            }
            if editsNewsletter == true {
                return action == .editDraft && !revision.isEmpty && title.isEmpty
                    && text.utf16.count <= 200_000 && !text.contains("\0")
                    && (baseNewsletterText.map { $0.utf16.count <= 200_000 && !$0.contains("\0") } ?? true)
            }
            guard baseNewsletterText == nil else { return false }
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

        var payloadLimit: Int { action == .editDraft ? 245_000 : 14_000 }
    }

    public struct Result: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let error: String?
        public let newsletterRevision: String?

        public init(id: UUID, error: String? = nil, newsletterRevision: String? = nil) {
            self.id = id
            self.error = error
            self.newsletterRevision = newsletterRevision
        }
    }

    public mutating func enqueue(_ change: Change) throws {
        guard enabled else { throw CompanionLibraryError.disabled }
        guard change.valid else { throw CompanionLibraryError.invalid }
        if change.action == .editDraft, supportsDraftEdits != true { throw CompanionLibraryError.disabled }
        if change.editsNewsletter == true, supportsNewsletterEdits != true { throw CompanionLibraryError.disabled }
        if [.editIdea, .trashItem, .restoreItem, .deleteItem].contains(change.action), supportsItemManagement != true { throw CompanionLibraryError.disabled }
        if change.action == .scheduleDraft, postingWindows == nil { throw CompanionLibraryError.disabled }
        if pending.contains(where: { $0.id == change.id }) || results.contains(where: { $0.id == change.id }) { return }
        guard pending.count < 24 else { throw CompanionLibraryError.full }
        guard try JSONEncoder().encode(change).count <= change.payloadLimit else { throw CompanionLibraryError.invalid }
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
        newsletters = nil
        hasMoreNewsletters = nil
        fullText = nil
        pending = []
        results = []
        hasMore = false
        updatedAt = .now
        supportsDraftEdits = nil
        supportsNewsletterEdits = nil
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

struct CompanionLibraryOutbox: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
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
        var editsNewsletter: Bool?
        var newsletterPrepared: Bool?
        var afterNewsletterEdit: UUID?
        var baseNewsletterText: String?
        var xFormat: String?
        var generatesXDraft: Bool?

        var requestID: UUID { retryID ?? id }
        var movesToTrash: Bool { action == .trashItem || action == .skipIdea }

        var change: CompanionLibrary.Change? {
            guard let itemID else { return nil }
            let change = CompanionLibrary.Change(id: requestID, action: action, itemID: itemID, revision: revision,
                                                 title: title, text: text, editsNewsletter: editsNewsletter,
                                                 baseNewsletterText: baseNewsletterText, xFormat: xFormat, generatesXDraft: generatesXDraft)
            // Keep the existing edit limit even when the original plus the edit exceed one record.
            if baseNewsletterText != nil, let size = try? JSONEncoder().encode(change).count, size > change.payloadLimit {
                return .init(id: requestID, action: action, itemID: itemID, revision: revision, title: title, text: text,
                             editsNewsletter: editsNewsletter)
            }
            return change
        }
    }

    var entries: [Entry] = []

    mutating func queueNewsletterEdit(_ edit: Entry) {
        var edit = edit
        let matches = entries.filter {
            $0.editsNewsletter == true && $0.itemID == edit.itemID &&
                $0.workspaceID == edit.workspaceID && $0.account == edit.account
        }
        // Entries from before this flag was added may already be in CloudKit.
        let predecessor = matches.last { $0.error == nil && $0.newsletterPrepared != false }
        if let unsent = matches.first(where: { $0.error == nil && $0.newsletterPrepared == false }) {
            edit.baseNewsletterText = unsent.baseNewsletterText
            edit.revision = unsent.revision
        }
        let replaced = Set(matches.map(\.id))
        entries.removeAll { replaced.contains($0.id) && $0.id != predecessor?.id }
        edit.newsletterPrepared = false
        edit.afterNewsletterEdit = predecessor?.requestID
        entries.append(edit)
    }

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
        let newsletters = Dictionary((library.newsletters ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let waitingNewsletterEdits = entries.filter { $0.workspaceID == library.workspaceID && $0.account == account }
        let predecessors = Dictionary(waitingNewsletterEdits.filter { $0.editsNewsletter == true }
            .map { ($0.requestID, $0) }, uniquingKeysWith: { _, latest in latest })
        let superseded = Set(waitingNewsletterEdits.compactMap(\.afterNewsletterEdit))
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
                if entry.editsNewsletter == true, superseded.contains(entry.requestID) { return nil }
                if entry.movesToTrash, let itemID = entry.itemID, items[itemID]?.isTrashed == true { return nil }
                entry.error = error
            } else if entry.action == .addIdea, items[entry.id.uuidString.lowercased()] != nil {
                return nil
            }
            entry.workspaceID = library.workspaceID
            entry.account = account
            if let previous = entry.afterNewsletterEdit {
                guard let receipt = results[previous] else { return entry }
                entry.afterNewsletterEdit = nil
                let newsletter = entry.itemID.flatMap { newsletters[$0] }
                if let error = receipt.error {
                    entry.error = error
                } else if entry.change?.baseNewsletterText != nil {
                    // The Mac compares this edit's own base against its current body, including any
                    // changes already merged while processing the predecessor.
                } else if let newsletter,
                          receipt.newsletterRevision == newsletter.revision ||
                            (receipt.newsletterRevision == nil && !newsletter.shortened
                                && predecessors[previous]?.text == newsletter.body) {
                    entry.revision = newsletter.revision
                } else {
                    entry.error = "This newsletter changed on your Mac before the edit could sync."
                }
            }
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
            if entry.action == .addIdea, entry.generatesXDraft != true,
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
               (entry.xFormat == nil || library.supportsXThreads == true),
               (entry.editsNewsletter != true || library.supportsNewsletterEdits == true),
               (entry.action != .scheduleDraft || library.postingWindows != nil),
               (![.editIdea, .trashItem, .restoreItem, .deleteItem].contains(entry.action) || library.supportsItemManagement == true) {
                if entry.editsNewsletter == true { entry.newsletterPrepared = true }
                changes.append(change)
            }
            return entry
        }
        return changes
    }
}
