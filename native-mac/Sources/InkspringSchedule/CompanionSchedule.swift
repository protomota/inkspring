import Foundation

public struct CompanionPost: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, review, cancelled, sending
    }

    public let id: String
    public let revision: String
    public let title: String
    public let project: String
    public let channel: String
    public let scheduledAt: Date
    public var state: State
    public let canCancel: Bool

    public init(id: String, revision: String, title: String, project: String, channel: String,
                scheduledAt: Date, state: State, canCancel: Bool) {
        self.id = id
        self.revision = revision
        self.title = title
        self.project = project
        self.channel = channel
        self.scheduledAt = scheduledAt
        self.state = state
        self.canCancel = canCancel
    }
}

public struct CompanionSchedule: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public var sharing: Bool
    public var updatedAt: Date
    public var posts: [CompanionPost]

    public init(workspaceID: UUID, sharing: Bool = true, updatedAt: Date = .now, posts: [CompanionPost]) {
        self.workspaceID = workspaceID
        self.sharing = sharing
        self.updatedAt = updatedAt
        self.posts = posts
    }

    public mutating func cancel(_ post: CompanionPost) throws {
        guard sharing else { throw CompanionScheduleError.missing }
        guard let index = posts.firstIndex(where: { $0.id == post.id && $0.revision == post.revision }),
              posts[index].canCancel else { throw CompanionScheduleError.changed }
        switch posts[index].state {
        case .cancelled: return
        case .queued, .review: posts[index].state = .cancelled
        case .sending: throw CompanionScheduleError.sending
        }
    }

    public mutating func claim(_ post: CompanionPost) throws {
        guard sharing else { throw CompanionScheduleError.missing }
        if let index = posts.firstIndex(where: { $0.id == post.id && $0.revision == post.revision }) {
            guard posts[index].state != .cancelled else { throw CompanionScheduleError.cancelled }
            guard posts[index].state != .sending else { throw CompanionScheduleError.sending }
            posts[index].state = .sending
        } else {
            posts.removeAll { $0.id == post.id }
            var claimed = post
            claimed.state = .sending
            posts.append(claimed)
        }
    }

    public mutating func mirror(_ local: [CompanionPost], now: Date = .now, recoverAbandonedSends: Bool = false) {
        let previous = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        posts = local.map { post in
            guard let current = previous[post.id], current.revision == post.revision,
                  current.state == .cancelled || current.state == .sending && !recoverAbandonedSends else { return post }
            return current
        }
        updatedAt = now
    }

    public func transferred(to newWorkspace: UUID, posts local: [CompanionPost], now: Date = .now) throws -> CompanionSchedule {
        guard newWorkspace != workspaceID else { throw CompanionScheduleError.changed }
        guard !posts.contains(where: { $0.state == .sending }) else { throw CompanionScheduleError.sending }
        var replacement = CompanionSchedule(workspaceID: newWorkspace, sharing: true, updatedAt: now, posts: posts)
        replacement.mirror(local, now: now)
        return replacement
    }
}

public enum CompanionScheduleError: LocalizedError, Equatable {
    case changed, cancelled, sending, missing, anotherMac, accountChanged, cloudUnavailable, cloudTemporarilyUnavailable, oversized

    public var errorDescription: String? {
        switch self {
        case .changed: "This schedule changed. Refresh it and try again."
        case .cancelled: "This post was cancelled from the iPhone."
        case .sending: "Inkspring on Mac has already started sending this post."
        case .missing: "Enable iPhone schedule sync in Inkspring on your Mac."
        case .anotherMac: "A different Inkspring workspace manages the schedule on this Apple Account."
        case .accountChanged: "Switch back to the Apple Account that set up iPhone schedule sync."
        case .cloudUnavailable: "Sign in to iCloud and check that Inkspring can use iCloud on this device."
        case .cloudTemporarilyUnavailable: "iCloud is temporarily unavailable. Check again when it reconnects."
        case .oversized: "There are too many upcoming posts to sync."
        }
    }
}

struct CompanionScheduleViewState {
    enum Operation { case refresh, cancel }

    private(set) var schedule: CompanionSchedule?
    private(set) var account: String?
    private(set) var error: String?
    private var operation: Operation?
    private var request: UUID?
    private var loaded = false

    var busy: Bool { request != nil }
    var loading: Bool { !loaded || operation == .refresh }
    var canCancel: Bool { schedule != nil && account != nil && error == nil && !busy }

    mutating func begin(_ operation: Operation) -> UUID? {
        guard !busy, operation != .cancel || canCancel else { return nil }
        let token = UUID()
        self.operation = operation
        request = token
        return token
    }

    func isCurrent(_ token: UUID) -> Bool { request == token }

    mutating func confirmAccount(_ newAccount: String, for token: UUID) -> Bool {
        guard isCurrent(token) else { return false }
        if account != newAccount { schedule = nil }
        account = newAccount
        return true
    }

    mutating func complete(_ snapshot: CompanionSchedule?, for token: UUID) {
        guard isCurrent(token) else { return }
        schedule = snapshot?.sharing == true ? snapshot : nil
        error = nil
        finish()
    }

    mutating func fail(_ message: String, keepSchedule: Bool, for token: UUID) {
        guard isCurrent(token) else { return }
        if !keepSchedule {
            schedule = nil
            account = nil
        }
        error = message
        finish()
    }

    private mutating func finish() {
        loaded = true
        request = nil
        operation = nil
    }
}
