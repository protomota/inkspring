import CryptoKit
import Foundation

public struct ContentRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let savedAt: String?
    public let title: String
    public let text: String
    public let format: String?
    public let subtitle: String?
    public let source: String

    public init(id: String = UUID().uuidString, savedAt: String?, title: String, text: String,
                format: String? = nil, subtitle: String? = nil, source: String) {
        self.id = id; self.savedAt = savedAt; self.title = title; self.text = text
        self.format = format; self.subtitle = subtitle; self.source = source
    }

    public var valid: Bool {
        !id.isEmpty && id.utf8.count <= 200 && title.utf16.count <= 300 && text.utf16.count <= 200_000
            && (subtitle?.utf16.count ?? 0) <= 1000 && !text.contains("\0")
            && (format?.utf16.count ?? 0) <= 100 && source.utf16.count <= 100
    }

    public var date: Date? {
        savedAt.flatMap {
            (try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date($0, strategy: .iso8601))
        }
    }
}

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

// The local reference travels with its reply through edits, history and iCloud.
public struct XReplyArticle {
    public static let prefix = "[[X article: "
    public let copy: String
    public let reference: String?

    public init(_ post: String) {
        guard let range = post.range(of: #"\[\[X article: [A-Z]{3}-[0-9]+\]\]\z"#, options: .regularExpression) else {
            copy = post
            reference = nil
            return
        }
        let before = post[..<range.lowerBound]
        copy = String(before.hasSuffix("\n") ? before.dropLast() : before)
        reference = String(post[range].dropFirst(Self.prefix.count).dropLast(2))
    }

    public static func attach(_ reference: String?, to copy: String) -> String {
        guard let reference else { return copy }
        return copy + (copy.isEmpty ? "" : "\n") + prefix + reference + "]]"
    }
}

public enum XThreadText {
    // Reply boundaries must not share the same representation as paragraphs.
    public static let separator = "\n\n<!-- inkspring:x-reply -->\n\n"
    public static let limit = 25
    private static let boundary = #"\r?\n\s*\r?\n"#

    public static func parts(in text: String) -> [String] {
        if text.contains(separator) { return text.components(separatedBy: separator) }
        // Read existing drafts without rewriting or losing empty editor fields.
        return text.replacingOccurrences(of: boundary, with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
    }

    public static func posts(in text: String) -> [String] {
        parts(in: text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func singlePost(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func weight(_ text: String) -> Int {
        let link = XReplyArticle(text)
        let measured = link.reference == nil ? text : link.copy + (link.copy.isEmpty ? "" : "\n") + "https://x.com/article"
        let links = measured.replacingOccurrences(of: #"https?://\S+"#, with: String(repeating: "x", count: 23),
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
    public var articles: [Item]?
    public var scripts: [Item]?
    public var supportsScripts: Bool?
    public var supportsXArticlePublishing: Bool?
    public var xArticleAccountKey: String?
    public var xArticleAccountName: String?
    public var supportsWritingTools: Bool?
    public var writingAgent: String?
    public var newsletters: [Item]?
    public var hasMoreNewsletters: Bool?
    public var fullText: TextVersion?
    public var pending: [Change] = []
    public var results: [Result] = []
    public var hasMore = false
    public var supportsDraftEdits: Bool?
    public var supportsNewsletterEdits: Bool?
    public var supportsItemManagement: Bool?
    public var supportsXReplyArticles: Bool?
    public var supportsXThreads: Bool?
    public var supportsXParagraphs: Bool?
    public var supportsRevisionHistory: Bool?
    public var supportsContentPlans: Bool?
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
        public var publicationStatus: String?
        public var publicationURL: String?
        public var publicationError: String?
        public var writingError: String?
        public var writingReply: String?
        public var history: [ContentRevision]?
        public enum Kind: String, Codable, Sendable { case draft, idea, newsletter, script, article }
        public var isLongForm: Bool { kind == .newsletter || kind == .script || kind == .article }
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
        public var planMarkdown: String?
        public var previousPlanMarkdown: String?

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
            var entry = self
            entry.history = nil
            entry.planMarkdown = nil
            entry.previousPlanMarkdown = nil
            guard body.utf8.count > 512 else { return entry }
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
            var entry = item.indexEntry
            if let plan = item.planMarkdown { bodies["plan:" + item.id] = plan; entry.planMarkdown = nil }
            if let previous = item.previousPlanMarkdown { bodies["previousPlan:" + item.id] = previous; entry.previousPlanMarkdown = nil }
            if entry.shortened && !item.shortened { bodies[item.id] = item.body }
            if let history = item.history, !history.isEmpty,
               let data = try? JSONEncoder().encode(history) {
                bodies["history:" + item.id] = String(decoding: data, as: UTF8.self)
            }
            return entry
        }
        items = items.map(separate)
        newsletters = newsletters?.map(separate)
        scripts = scripts?.map(separate)
        articles = articles?.map(separate)
        let data = try bodies.isEmpty ? nil : Self.encodeFullText(bodies)
        fullText = data.map(TextVersion.init(data:))
        return data
    }

    public mutating func applyFullText(_ data: Data) throws {
        guard fullText == TextVersion(data: data) else { throw CompanionScheduleError.changed }
        let decoded = try (data as NSData).decompressed(using: .zlib) as Data
        let bodies = try JSONDecoder().decode([String: String].self, from: decoded)
        func complete(_ item: Item) throws -> Item {
            var item = item
            item.planMarkdown = bodies["plan:" + item.id] ?? item.planMarkdown
            item.previousPlanMarkdown = bodies["previousPlan:" + item.id] ?? item.previousPlanMarkdown
            if item.shortened {
                guard let body = bodies[item.id] else { throw CompanionScheduleError.changed }
                item.body = body
                item.shortened = false
            }
            if let history = bodies["history:" + item.id] {
                item.history = try JSONDecoder().decode([ContentRevision].self, from: Data(history.utf8))
            }
            return item
        }
        let completedItems = try items.map(complete)
        let completedNewsletters = try newsletters?.map(complete)
        let completedScripts = try scripts?.map(complete)
        let completedArticles = try articles?.map(complete)
        items = completedItems
        newsletters = completedNewsletters
        scripts = completedScripts
        articles = completedArticles
    }

    public struct Change: Codable, Equatable, Identifiable, Sendable {
        public enum Action: String, Codable, Sendable {
            case addIdea, note, skipIdea, restoreIdea, editDraft, editIdea, trashItem, restoreItem, deleteItem, scheduleDraft, saveRevision
        }
        public let id: UUID
        public let action: Action
        public let itemID: String
        public let revision: String
        public let title: String
        public let text: String
        // Newsletter edits use the existing wire action so older clients can decode the queue.
        public let publishesXArticle: Bool?
        public let xArticleAccountKey: String?
        public let requestsWritingHelp: Bool?
        public let writingKind: String?
        public let baseScriptTitle: String?
        public let editsScript: Bool?
        public let createsScript: Bool?
        public var isLongFormEdit: Bool { editsNewsletter == true || editsScript == true }
        public let editsNewsletter: Bool?
        public let baseNewsletterText: String?
        public let xFormat: String?
        public let generatesXDraft: Bool?
        public let historySnapshot: ContentRevision?
        public let restoresRevision: Bool?
        public let subtitle: String?
        public var contentOperation: CompanionContentOperation?
        public var basePlan: String?
        public var initialPlan: String?

        public init(id: UUID = UUID(), action: Action, itemID: String, revision: String = "",
                    title: String = "", text: String = "", editsNewsletter: Bool? = nil,
                    baseNewsletterText: String? = nil, xFormat: String? = nil, generatesXDraft: Bool? = nil,
                    historySnapshot: ContentRevision? = nil, restoresRevision: Bool? = nil, subtitle: String? = nil,
                    editsScript: Bool? = nil, createsScript: Bool? = nil, baseScriptTitle: String? = nil, writingKind: String? = nil, requestsWritingHelp: Bool? = nil, publishesXArticle: Bool? = nil, xArticleAccountKey: String? = nil) {
            self.id = id
            self.action = action
            self.itemID = itemID
            self.revision = revision
            self.title = action == .editDraft ? title : title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = action == .editDraft || createsScript == true ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publishesXArticle = publishesXArticle
            self.xArticleAccountKey = xArticleAccountKey
            self.requestsWritingHelp = requestsWritingHelp
            self.writingKind = writingKind
            self.baseScriptTitle = baseScriptTitle
            self.editsScript = editsScript
            self.createsScript = createsScript
            self.editsNewsletter = editsNewsletter
            self.baseNewsletterText = baseNewsletterText
            self.xFormat = xFormat
            self.generatesXDraft = generatesXDraft
            self.historySnapshot = historySnapshot
            self.restoresRevision = restoresRevision
            self.subtitle = subtitle
        }

        public var valid: Bool {
            if let initialPlan {
                guard initialPlan.utf16.count <= ContentPlan.limit, !initialPlan.contains("\0"),
                      (action == .addIdea && generatesXDraft != true && createsScript != true || contentOperation.map({ [.createDraft, .createNewsletter].contains($0) }) == true) else { return false }
            }
            if let operation = contentOperation {
                guard action == .editDraft, !itemID.isEmpty, itemID.utf8.count <= 200,
                      title.utf16.count <= 200, text.utf16.count <= ContentPlan.limit,
                      !text.contains("\0"), !title.contains("\0"), !isLongFormEdit,
                      generatesXDraft != true, xFormat == nil, createsScript != true,
                      publishesXArticle != true, xArticleAccountKey == nil, requestsWritingHelp != true,
                      writingKind == nil, historySnapshot == nil, restoresRevision != true,
                      baseNewsletterText == nil, baseScriptTitle == nil, subtitle == nil else { return false }
                switch operation {
                case .savePlan: return !revision.isEmpty && title.isEmpty && basePlan != nil
                    && (basePlan?.utf16.count ?? 0) <= ContentPlan.limit && basePlan?.contains("\0") != true
                case .createDraft, .createNewsletter, .createProject: return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && basePlan == nil
                case .setTitle: return !revision.isEmpty && title.isEmpty && (1...200).contains(text.utf16.count) && basePlan == nil
                case .moveProject: return !revision.isEmpty && !text.isEmpty && title.isEmpty && basePlan == nil
                }
            }
            guard basePlan == nil else { return false }
            if publishesXArticle == true {
                return action == .note && !itemID.isEmpty && itemID.utf8.count <= 200 && !revision.isEmpty && revision.utf8.count <= 100
                    && text == "Publish X article" && title.isEmpty && !isLongFormEdit && createsScript != true
                    && requestsWritingHelp != true && generatesXDraft != true && historySnapshot == nil
                    && baseNewsletterText == nil && writingKind == nil && xFormat == nil && restoresRevision != true
                    && xArticleAccountKey.map { !$0.isEmpty && $0.utf8.count <= 500 } == true
            }
            guard xArticleAccountKey == nil else { return false }

            guard (requestsWritingHelp != true || action == .note && !isLongFormEdit && createsScript != true && generatesXDraft != true && historySnapshot == nil),
                  (writingKind == nil || ["script", "article", "newsletter"].contains(writingKind ?? "") && (createsScript == true || editsScript == true)),
                  !(editsScript == true && editsNewsletter == true),
                  !(generatesXDraft == true && (editsScript == true || createsScript == true)),
                  !itemID.isEmpty, itemID.utf8.count <= 200, revision.utf8.count <= 100 else { return false }
            if createsScript == true {
                return action == .addIdea && !isLongFormEdit && generatesXDraft != true && xFormat == nil
                    && historySnapshot == nil && baseNewsletterText == nil && !title.isEmpty && title.utf16.count <= 300
                    && text.utf16.count <= 200_000 && !text.contains("\0")
            }
            if action == .saveRevision {
                return historySnapshot?.valid == true && title.isEmpty && text.isEmpty && editsNewsletter != true && xFormat == nil
            }
            guard historySnapshot == nil else { return false }
            if generatesXDraft == true {
                return action == .addIdea && editsNewsletter != true && baseNewsletterText == nil
                    && xFormat.flatMap(XPostStyle.init(rawValue:)) != nil
                    && (1...200).contains(title.utf16.count) && (1...10_000).contains(text.utf16.count)
                    && !text.contains("\0")
            }
            if let xFormat {
                guard action == .editDraft, editsNewsletter != true, XPostStyle(rawValue: xFormat) != nil else { return false }
            }
            if isLongFormEdit {
                return action == .editDraft && !revision.isEmpty && (title.isEmpty || (restoresRevision == true || editsScript == true || baseScriptTitle != nil) && title.utf16.count <= 300)
                    && text.utf16.count <= 200_000 && !text.contains("\0")
                    && (subtitle?.utf16.count ?? 0) <= 1000
                    && (baseScriptTitle?.utf16.count ?? 0) <= 300
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
            case .saveRevision: return false
            }
        }

        public var needsWritingTools: Bool {
            requestsWritingHelp == true || createsScript == true && writingKind == "newsletter" ||
                editsNewsletter == true && !title.isEmpty && restoresRevision != true && baseScriptTitle != nil
        }

        public var postingHour: Date? {
            guard action == .scheduleDraft, text.utf8.count <= 32 else { return nil }
            return try? Date(text, strategy: .iso8601)
        }

        var payloadLimit: Int { createsScript == true || [.editDraft, .saveRevision].contains(action) ? 245_000 : 14_000 }
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
        guard (change.createsScript != true && change.editsScript != true) || supportsScripts == true else { throw CompanionLibraryError.disabled }
        guard change.publishesXArticle != true || supportsXArticlePublishing == true else { throw CompanionLibraryError.disabled }
        guard !change.needsWritingTools || supportsWritingTools == true else { throw CompanionLibraryError.disabled }
        guard change.valid else { throw CompanionLibraryError.invalid }
        if change.xFormat != nil, change.text.contains(XThreadText.separator), supportsXParagraphs != true {
            throw CompanionLibraryError.disabled
        }
        if change.action == .saveRevision, supportsRevisionHistory != true { throw CompanionLibraryError.disabled }
        if change.contentOperation != nil || change.initialPlan != nil, supportsContentPlans != true { throw CompanionLibraryError.disabled }
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
        scripts = nil
        articles = nil
        supportsScripts = nil
        supportsXArticlePublishing = nil
        xArticleAccountKey = nil
        xArticleAccountName = nil
        supportsWritingTools = nil
        writingAgent = nil
        hasMoreNewsletters = nil
        fullText = nil
        pending = []
        results = []
        hasMore = false
        updatedAt = .now
        supportsDraftEdits = nil
        supportsNewsletterEdits = nil
        supportsItemManagement = nil
        supportsContentPlans = nil
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
        var title: String
        let text: String
        var workspaceID: UUID?
        var account: String?
        var error: String?
        var afterTrash: UUID?
        var retryID: UUID?
        var trashRetries: Int?
        var publishesXArticle: Bool?
        var xArticleAccountKey: String?
        var requestsWritingHelp: Bool?
        var writingKind: String?
        var baseScriptTitle: String?
        var editsScript: Bool?
        var createsScript: Bool?
        var isLongFormEdit: Bool { editsNewsletter == true || editsScript == true }
        var editsNewsletter: Bool?
        var newsletterPrepared: Bool?
        var afterNewsletterEdit: UUID?
        var baseNewsletterText: String?
        var xFormat: String?
        var generatesXDraft: Bool?
        var historySnapshot: ContentRevision?
        var restoresRevision: Bool?
        var subtitle: String?
        var contentOperation: CompanionContentOperation?
        var basePlan: String?
        var initialPlan: String?

        var requestID: UUID { retryID ?? id }
        var movesToTrash: Bool { action == .trashItem || action == .skipIdea }

        var change: CompanionLibrary.Change? {
            guard let itemID else { return nil }
            var change = CompanionLibrary.Change(id: requestID, action: action, itemID: itemID, revision: revision,
                                                 title: title, text: text, editsNewsletter: editsNewsletter,
                                                 baseNewsletterText: baseNewsletterText, xFormat: xFormat, generatesXDraft: generatesXDraft,
                                                 historySnapshot: historySnapshot, restoresRevision: restoresRevision, subtitle: subtitle, editsScript: editsScript, createsScript: createsScript, baseScriptTitle: baseScriptTitle, writingKind: writingKind, requestsWritingHelp: requestsWritingHelp, publishesXArticle: publishesXArticle, xArticleAccountKey: xArticleAccountKey)
            change.contentOperation = contentOperation
            change.basePlan = basePlan
            change.initialPlan = initialPlan
            // Keep the existing edit limit even when the original plus the edit exceed one record.
            if baseNewsletterText != nil, let size = try? JSONEncoder().encode(change).count, size > change.payloadLimit {
                return .init(id: requestID, action: action, itemID: itemID, revision: revision, title: title, text: text,
                             editsNewsletter: editsNewsletter, restoresRevision: restoresRevision, subtitle: subtitle, editsScript: editsScript, createsScript: createsScript, baseScriptTitle: baseScriptTitle, writingKind: writingKind, requestsWritingHelp: requestsWritingHelp, publishesXArticle: publishesXArticle, xArticleAccountKey: xArticleAccountKey)
            }
            return change
        }
    }

    var entries: [Entry] = []

    mutating func queueNewsletterEdit(_ edit: Entry) {
        var edit = edit
        let matches = entries.filter {
            $0.action == .editDraft && $0.itemID == edit.itemID &&
                $0.workspaceID == edit.workspaceID && $0.account == edit.account
        }
        // Entries from before this flag was added may already be in CloudKit.
        let predecessor = matches.last { $0.error == nil && $0.newsletterPrepared != false }
        if let unsent = matches.first(where: { $0.error == nil && $0.newsletterPrepared == false }) {
            edit.baseNewsletterText = unsent.baseNewsletterText
            edit.baseScriptTitle = unsent.baseScriptTitle ?? edit.baseScriptTitle
            if edit.title.isEmpty { edit.title = unsent.title }
            edit.revision = unsent.revision
        }
        let replaced = Set(matches.map(\.id))
        entries.removeAll { replaced.contains($0.id) && $0.id != predecessor?.id }
        edit.newsletterPrepared = false
        edit.afterNewsletterEdit = predecessor?.requestID ?? edit.afterNewsletterEdit
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
        let newsletters = Dictionary(((library.newsletters ?? []) + (library.scripts ?? []) + (library.articles ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let waitingNewsletterEdits = entries.filter { $0.workspaceID == library.workspaceID && $0.account == account }
        let predecessors = Dictionary(waitingNewsletterEdits.filter { $0.action == .editDraft || $0.createsScript == true }
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
                if entry.isLongFormEdit, superseded.contains(entry.requestID) { return nil }
                if entry.movesToTrash, let itemID = entry.itemID, items[itemID]?.isTrashed == true { return nil }
                entry.error = error
            } else if entry.action == .addIdea, (items[entry.id.uuidString.lowercased()] ?? newsletters[entry.id.uuidString.lowercased()]) != nil {
                return nil
            }
            entry.workspaceID = library.workspaceID
            entry.account = account
            if let previous = entry.afterNewsletterEdit {
                guard let receipt = results[previous] else { return entry }
                entry.afterNewsletterEdit = nil
                let newsletter = entry.itemID.flatMap { newsletters[$0] ?? items[$0] }
                if let error = receipt.error {
                    entry.error = error
                } else if entry.change?.baseNewsletterText != nil {
                    entry.revision = receipt.newsletterRevision ?? newsletter?.revision ?? entry.revision
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
            if entry.action == .addIdea, entry.generatesXDraft != true, entry.createsScript != true,
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
               (change.publishesXArticle != true || library.supportsXArticlePublishing == true),
               (!change.needsWritingTools || library.supportsWritingTools == true),
               (entry.action != .saveRevision || library.supportsRevisionHistory == true),
               (entry.xFormat == nil || library.supportsXThreads == true),
               (entry.xFormat == nil || !entry.text.contains(XThreadText.separator) || library.supportsXParagraphs == true),
               (entry.editsNewsletter != true || library.supportsNewsletterEdits == true),
               ((entry.editsScript != true && entry.createsScript != true) || library.supportsScripts == true),
               (entry.contentOperation == nil && entry.initialPlan == nil || library.supportsContentPlans == true),
               (entry.action != .scheduleDraft || library.postingWindows != nil),
               (![.editIdea, .trashItem, .restoreItem, .deleteItem].contains(entry.action) || library.supportsItemManagement == true) {
                if entry.action == .editDraft { entry.newsletterPrepared = true }
                changes.append(change)
            }
            return entry
        }
        return changes.filter { $0.action != .saveRevision } + changes.filter { $0.action == .saveRevision }
    }
}
