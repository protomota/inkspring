import Foundation
import Testing
@testable import Inkspring
@testable import InkspringSchedule

@Test func phoneScheduleKeepsOutagesReadOnlyAndDropsResponsesFromAnOldAccount() throws {
    let post = CompanionPost(id: "fixture", revision: "first", title: "Synthetic post", project: "Studio",
                             channel: "X", scheduledAt: .now, state: .queued, canCancel: true)
    let snapshot = CompanionSchedule(workspaceID: UUID(), posts: [post])
    var state = CompanionScheduleViewState()
    let firstRequest = state.begin(.refresh)
    let first = try #require(firstRequest)
    let accepted = state.confirmAccount("first", for: first)
    #expect(accepted)
    state.complete(snapshot, for: first)
    #expect(state.canCancel)

    let offlineRequest = state.begin(.refresh)
    let disconnected = try #require(offlineRequest)
    #expect(!state.canCancel)
    state.fail("iCloud offline", keepSchedule: true, for: disconnected)
    #expect(state.schedule == snapshot)
    #expect(!state.canCancel)
    let blockedCancel = state.begin(.cancel)
    #expect(blockedCancel == nil)

    let reconnectRequest = state.begin(.refresh)
    let reconnecting = try #require(reconnectRequest)
    let changed = state.confirmAccount("second", for: reconnecting)
    #expect(changed)
    #expect(state.schedule == nil)
    state = CompanionScheduleViewState()
    let nextRequest = state.begin(.refresh)
    let next = try #require(nextRequest)
    let expired = state.confirmAccount("second", for: reconnecting)
    #expect(!expired)
    state.complete(snapshot, for: reconnecting)
    #expect(state.schedule == nil)
    let newAccount = state.confirmAccount("third", for: next)
    #expect(newAccount)
    state.complete(snapshot, for: next)
    let cancelRequest = state.begin(.cancel)
    let cancel = try #require(cancelRequest)
    var result = snapshot
    try result.cancel(post)
    state.complete(result, for: cancel)
    #expect(state.schedule?.posts.first?.state == .cancelled)
}

@Test func companionCancellationAndSendClaimAreExclusive() throws {
    let post = CompanionPost(id: "post", revision: "first", title: "A draft", project: "Studio",
                             channel: "LinkedIn", scheduledAt: .now, state: .queued, canCancel: true)
    var cancelled = CompanionSchedule(workspaceID: UUID(), posts: [post])
    try cancelled.cancel(post)
    cancelled.mirror([post])
    #expect(cancelled.posts.first?.state == .cancelled)
    #expect(throws: CompanionScheduleError.cancelled) { try cancelled.claim(post) }

    var sending = CompanionSchedule(workspaceID: UUID(), posts: [post])
    try sending.claim(post)
    #expect(throws: CompanionScheduleError.sending) { try sending.cancel(post) }
    sending.mirror([post])
    #expect(sending.posts.first?.state == .sending)
    sending.mirror([post], recoverAbandonedSends: true)
    #expect(sending.posts.first?.state == .queued)
    try sending.cancel(post)
    sending.mirror([post], recoverAbandonedSends: true)
    #expect(sending.posts.first?.state == .cancelled)

    let revised = CompanionPost(id: post.id, revision: "second", title: post.title, project: post.project,
                                channel: post.channel, scheduledAt: post.scheduledAt, state: .queued, canCancel: true)
    cancelled.mirror([revised])
    #expect(throws: CompanionScheduleError.changed) { try cancelled.cancel(post) }
    try cancelled.claim(revised)
    #expect(cancelled.posts.first?.state == .sending)
}

@Test func companionKeepsRemoteNewsletterSchedulesReadOnly() throws {
    let newsletter = CompanionPost(id: "newsletter", revision: "scheduled", title: "An update", project: "Studio",
                                   channel: "Substack", scheduledAt: .now, state: .queued, canCancel: false)
    var schedule = CompanionSchedule(workspaceID: UUID(), posts: [newsletter])
    #expect(throws: CompanionScheduleError.changed) { try schedule.cancel(newsletter) }
    let serialized = try JSONEncoder().encode(schedule)
    #expect(try JSONDecoder().decode(CompanionSchedule.self, from: serialized) == schedule)
    schedule.sharing = false
    #expect(throws: CompanionScheduleError.missing) { try schedule.cancel(newsletter) }
}

@Test @MainActor func restoredMacCanTakeOverAnIdleCompanionSchedule() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    let oldWorkspace = UUID()
    let time = Date.now.addingTimeInterval(3600)
    var matching = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    matching["title"] = "Matching scheduled post"
    matching.fields["schedule"] = ["status": "queued", "slotAt": workspaceTimestamp(time), "companionRevision": "same"]
    try workspace.save(matching)
    var revised = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    revised["title"] = "Reviewed again on the new Mac"
    revised.fields["schedule"] = ["status": "queued", "slotAt": workspaceTimestamp(time), "companionRevision": "new"]
    try workspace.save(revised)
    try workspace.set("autoPost", to: true)

    let cancelled = CompanionPost(id: matching.id, revision: "same", title: matching.title, project: "Fixture",
                                  channel: "X", scheduledAt: time, state: .cancelled, canCancel: true)
    let outdated = CompanionPost(id: revised.id, revision: "previous", title: revised.title, project: "Fixture",
                                 channel: "X", scheduledAt: time, state: .cancelled, canCancel: true)
    let sending = CompanionPost(id: "in-flight", revision: "1", title: "Already sending", project: "Fixture",
                                channel: "X", scheduledAt: time, state: .sending, canCancel: true)
    let cloud = ScheduleFixture(CompanionSchedule(workspaceID: oldWorkspace, posts: [cancelled, outdated, sending]))
    await workspace.setCompanionSharing(true, cloud: cloud)
    let offer = try #require(workspace.companionTransfer)
    #expect(offer.previousWorkspace == oldWorkspace)
    #expect(!workspace.companionSharing)
    #expect(cloud.schedule?.workspaceID == oldWorkspace)

    cloud.account = "switched"
    await workspace.transferCompanionSchedule(offer, cloud: cloud)
    #expect(cloud.schedule?.workspaceID == oldWorkspace)
    #expect(workspace.settings["autoPost"] as? Bool == true)
    cloud.account = "fixture"

    await workspace.transferCompanionSchedule(offer, cloud: cloud)
    #expect(workspace.companionError == CompanionScheduleError.sending.errorDescription)
    #expect(cloud.schedule?.workspaceID == oldWorkspace)
    #expect(workspace.settings["autoPost"] as? Bool == false)

    let reopened = Workspace(directory: folder)
    await reopened.syncCompanion(cloud: cloud)
    #expect(reopened.companionTransfer == offer)
    cloud.schedule?.posts.removeAll { $0.state == .sending }
    await reopened.transferCompanionSchedule(offer, cloud: cloud)
    let moved = try #require(cloud.schedule)
    #expect(moved.workspaceID != oldWorkspace)
    #expect(reopened.companionError == nil)
    #expect(reopened.companionSharing)
    #expect(reopened.companionTransfer == nil)
    #expect(reopened.settings["companionSetupPending"] as? Bool == false)
    #expect(reopened.settings["autoPost"] as? Bool == false)
    #expect(reopened.drafts.first { $0.id == matching.id }?.scheduleStatus == "ready")
    #expect(reopened.drafts.first { $0.id == revised.id }?.scheduleStatus == "queued")
    #expect(moved.posts.first { $0.id == revised.id }?.revision == "new")
    await #expect(throws: CompanionScheduleError.anotherMac) {
        _ = try await cloud.update(workspaceID: oldWorkspace, createIfMissing: false, expectedAccount: "fixture") { try $0.claim(sending) }
    }
}

@Test @MainActor func macCompanionSyncAndSendClaimRequireTheOriginalAccount() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = Workspace(directory: folder)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Scheduled fixture"
    draft["platform"] = "x"
    draft["content"] = "Synthetic post text."
    draft = try workspace.save(draft)
    draft = try workspace.scheduleDraft(draft, at: .now.addingTimeInterval(3600))
    let cloud = ScheduleFixture(nil)

    cloud.switchAfterLoad = "other"
    await workspace.setCompanionSharing(true, cloud: cloud)
    #expect(cloud.schedule == nil)
    #expect(workspace.companionError == CompanionScheduleError.accountChanged.errorDescription)

    cloud.account = "fixture"
    cloud.switchAfterLoad = nil
    await workspace.syncCompanion(cloud: cloud)
    let original = try #require(cloud.schedule)
    #expect(original.posts.first?.title == draft.title)

    cloud.account = "other"
    draft["title"] = "Revised fixture"
    draft = try workspace.save(draft)
    draft = try workspace.scheduleDraft(draft, at: .now.addingTimeInterval(7200))
    await workspace.syncCompanion(cloud: cloud)
    #expect(cloud.schedule == original)
    #expect(workspace.companionError == CompanionScheduleError.accountChanged.errorDescription)
    await #expect(throws: CompanionScheduleError.cloudUnavailable) {
        _ = try await workspace.claimCompanionPublication(draft, cloud: cloud)
    }
    #expect(cloud.schedule == original)

    cloud.account = "fixture"
    await workspace.syncCompanion(cloud: cloud)
    #expect(workspace.companionError == nil)
    #expect(cloud.schedule?.posts.first?.title == draft.title)
}

@MainActor
private final class ScheduleFixture: CompanionScheduleAccess {
    var schedule: CompanionSchedule?
    var account = "fixture"
    var switchAfterLoad: String?

    init(_ schedule: CompanionSchedule?) { self.schedule = schedule }

    func accountKey() async throws -> String { account }
    func load(confirmedAccount: String) async throws -> CompanionSchedule? {
        guard account == confirmedAccount else { throw CompanionScheduleError.accountChanged }
        if let switchAfterLoad { account = switchAfterLoad }
        return schedule
    }

    func update(workspaceID: UUID, createIfMissing: Bool, expectedAccount: String,
                _ update: (inout CompanionSchedule) throws -> Void) async throws -> CompanionSchedule {
        guard account == expectedAccount else { throw CompanionScheduleError.accountChanged }
        guard schedule != nil || createIfMissing else { throw CompanionScheduleError.missing }
        var current = schedule ?? CompanionSchedule(workspaceID: workspaceID, posts: [])
        guard current.workspaceID == workspaceID else { throw CompanionScheduleError.anotherMac }
        try update(&current)
        schedule = current
        return current
    }
}

@Test @MainActor func mobileSchedulingRequestAppearsInTheMirroredSchedule() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = Workspace(directory: folder)
    let cloud = ScheduleFixture(nil)
    await mac.setCompanionSharing(true, cloud: cloud)
    let schedule = try #require(cloud.schedule)
    var draft = WorkspaceRecord.new("draft", projectID: mac.projectID)
    draft["title"] = "Schedule from mobile"
    draft["content"] = "A synthetic post."
    draft = try mac.save(draft)

    let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: .now))
    let hour = try #require(Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: tomorrow))
    var library = mac.makeCompanionLibrary(workspaceID: schedule.workspaceID)
    let item = try #require(library.items.first { $0.id == draft.id })
    try library.enqueue(.init(action: .scheduleDraft, itemID: item.id, revision: item.revision, text: hour.formatted(.iso8601)))
    let synced = try JSONDecoder().decode(CompanionLibrary.self, from: JSONEncoder().encode(library))
    let results = try synced.pending.map(mac.applyCompanionLibraryChange)
    #expect(results.count == 1)
    #expect(results.first?.error == nil)
    library.acknowledge(results)
    #expect(library.pending.isEmpty)

    await mac.syncCompanion(cloud: cloud)
    let post = try #require(cloud.schedule?.posts.first { $0.id == item.id })
    let minute = Calendar.current.component(.minute, from: post.scheduledAt)
    #expect(post.state == .queued)
    #expect(Calendar.current.isDate(post.scheduledAt, equalTo: hour, toGranularity: .hour))
    #expect((7...55).contains(minute) && minute % 5 != 0)
}
