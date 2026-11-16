import Foundation
import InkspringSchedule
import SwiftUI

struct CompanionTransfer: Equatable {
    let previousWorkspace: UUID
    let accountKey: String
}

@MainActor
protocol CompanionScheduleAccess {
    func accountKey() async throws -> String
    func load(confirmedAccount: String) async throws -> CompanionSchedule?
    func update(workspaceID: UUID, createIfMissing: Bool, expectedAccount: String,
                _ update: (inout CompanionSchedule) throws -> Void) async throws -> CompanionSchedule
}

extension CloudScheduleStore: CompanionScheduleAccess {}

extension Workspace {
    var companionSharing: Bool { settings["companionSharing"] as? Bool == true }

    func setCompanionSharing(_ enabled: Bool, cloud override: (any CompanionScheduleAccess)? = nil) async {
        guard !companionLibraryBusy else { return }
        await withCompanionSync {
            let cloud = try override ?? companionCloud()
            let account = try await verifiedCompanionAccount(cloud, allowSetup: enabled)
            if enabled {
                let id = try companionWorkspaceID(create: true)
                if try await offerTransferIfNeeded(to: id, account: account, cloud: cloud) { return }
                companionTransfer = nil
                try beginCompanionSetup(account: account, pausePosting: false)
                let posts = companionPosts()
                let schedule = try await cloud.update(workspaceID: id, createIfMissing: true, expectedAccount: account) {
                    $0.sharing = true
                    $0.mirror(posts, recoverAbandonedSends: true)
                }
                try applyCompanionCancellations(schedule)
                try set("companionSetupPending", to: false)
                companionLastSync = .now
            } else {
                let id = try companionWorkspaceID()
                if override == nil { try await companionCloud().clearLibrary(workspaceID: id, account: account) }
                do {
                    let schedule = try await cloud.update(workspaceID: id, createIfMissing: false, expectedAccount: account) {
                        $0.sharing = false
                        $0.posts.removeAll { $0.state != .cancelled }
                    }
                    try applyCompanionCancellations(schedule)
                } catch CompanionScheduleError.missing where companionSetupPending {
                    // This account has no published schedule to close.
                }
                try withChanges {
                    try set("companionSharing", to: false)
                    try set("companionLibrarySharing", to: false)
                    try set("companionSetupPending", to: false)
                    try set("companionAccountKey", to: NSNull())
                }
                companionTransfer = nil
            }
        }
    }

    func transferCompanionSchedule(_ offer: CompanionTransfer, cloud override: (any CompanionScheduleAccess)? = nil) async {
        guard !companionLibraryBusy else { return }
        await withCompanionSync {
            guard companionTransfer == offer else { throw CompanionScheduleError.changed }
            let cloud = try override ?? companionCloud()
            let account = try await verifiedCompanionAccount(cloud, allowSetup: true)
            guard account == offer.accountKey else { throw CompanionScheduleError.accountChanged }
            let id = try companionWorkspaceID(create: true)
            if override == nil {
                try await companionCloud().clearLibrary(workspaceID: offer.previousWorkspace, account: account)
            }
            try beginCompanionSetup(account: account, pausePosting: true)
            let posts = companionPosts()
            let schedule = try await cloud.update(workspaceID: offer.previousWorkspace, createIfMissing: false, expectedAccount: account) {
                $0 = try $0.transferred(to: id, posts: posts)
            }
            try applyCompanionCancellations(schedule)
            try set("companionSetupPending", to: false)
            companionTransfer = nil
            companionLastSync = .now
        }
    }

    func syncCompanion(cloud override: (any CompanionScheduleAccess)? = nil) async {
        guard companionSharing, !companionBusy else { return }
        await withCompanionSync {
            let id = try companionWorkspaceID()
            let posts = companionPosts()
            let setupPending = companionSetupPending
            let cloud = try override ?? companionCloud()
            let account = try companionAccountKey()
            if setupPending {
                if try await offerTransferIfNeeded(to: id, account: account, cloud: cloud) { return }
            }
            let schedule = try await cloud.update(workspaceID: id, createIfMissing: setupPending, expectedAccount: account) { schedule in
                guard schedule.sharing || setupPending else { throw CompanionScheduleError.missing }
                var updated = schedule
                updated.sharing = true
                // The publication lease rules out a local send still owning a claim.
                updated.mirror(posts, recoverAbandonedSends: true)
                if updated.sharing != schedule.sharing || updated.posts != schedule.posts ||
                    Date.now.timeIntervalSince(schedule.updatedAt) >= 300 {
                    schedule = updated
                }
            }
            try applyCompanionCancellations(schedule)
            if setupPending { try set("companionSetupPending", to: false) }
            companionTransfer = nil
            companionLastSync = .now
        }
    }

    /// Called while holding the publication lease, before creating the local send receipt.
    func claimCompanionPublication(_ draft: WorkspaceRecord, cloud override: (any CompanionScheduleAccess)? = nil) async throws -> CompanionPost? {
        guard companionSharing, let post = companionPost(draft) else { return nil }
        let id = try companionWorkspaceID()
        let cloud = try override ?? companionCloud()
        do {
            let account = try companionAccountKey()
            _ = try await cloud.update(workspaceID: id, createIfMissing: false, expectedAccount: account) { try $0.claim(post) }
            return post
        } catch CompanionScheduleError.cancelled {
            try applyCompanionCancellation(post)
            throw CompanionScheduleError.cancelled
        } catch {
            companionError = error.localizedDescription
            throw CompanionScheduleError.cloudUnavailable
        }
    }

    func releaseCompanionClaim(_ post: CompanionPost) async {
        do {
            let id = try companionWorkspaceID()
            let account = try companionAccountKey()
            _ = try await companionCloud().update(workspaceID: id, createIfMissing: false, expectedAccount: account) { schedule in
                guard let index = schedule.posts.firstIndex(where: { $0.id == post.id && $0.revision == post.revision }),
                      schedule.posts[index].state == .sending else { return }
                schedule.posts[index].state = post.state
            }
        } catch {
            companionError = error.localizedDescription
        }
    }

    private func withCompanionSync(_ operation: () async throws -> Void) async {
        guard !companionBusy else { return }
        companionBusy = true
        defer { companionBusy = false }
        do {
            let lease = try claimPublication()
            defer { withExtendedLifetime(lease) {} }
            try reload()
            try await operation()
            companionError = nil
        } catch {
            companionError = error.localizedDescription
        }
    }

    func companionCloud() throws -> CloudScheduleStore {
        guard CloudScheduleStore.hasEntitlement else { throw CompanionScheduleError.cloudUnavailable }
        return CloudScheduleStore()
    }

    private var companionSetupPending: Bool { settings["companionSetupPending"] as? Bool == true }

    func companionAccountKey() throws -> String {
        guard let account = settings["companionAccountKey"] as? String else { throw CompanionScheduleError.missing }
        return account
    }

    private func verifiedCompanionAccount(_ cloud: any CompanionScheduleAccess, allowSetup: Bool = false) async throws -> String {
        let current = try await cloud.accountKey()
        if let saved = settings["companionAccountKey"] as? String {
            guard saved == current else { throw CompanionScheduleError.accountChanged }
        } else if !allowSetup {
            throw CompanionScheduleError.missing
        }
        return current
    }

    private func beginCompanionSetup(account: String, pausePosting: Bool) throws {
        try withChanges {
            try set("companionAccountKey", to: account)
            try set("companionSetupPending", to: true)
            try set("companionSharing", to: true)
            if pausePosting { try set("autoPost", to: false) }
        }
    }

    private func offerTransferIfNeeded(to id: UUID, account: String, cloud: any CompanionScheduleAccess) async throws -> Bool {
        guard let remote = try await cloud.load(confirmedAccount: account), remote.workspaceID != id else { return false }
        companionTransfer = CompanionTransfer(previousWorkspace: remote.workspaceID, accountKey: account)
        return true
    }

    func companionWorkspaceID(create: Bool = false) throws -> UUID {
        if let stored = settings["companionWorkspaceID"] as? String, let id = UUID(uuidString: stored) { return id }
        guard create else { throw CompanionScheduleError.missing }
        let id = UUID()
        try set("companionWorkspaceID", to: id.uuidString)
        return id
    }

    private func companionPosts() -> [CompanionPost] {
        records.compactMap(companionPost).sorted { $0.scheduledAt == $1.scheduledAt ? $0.id < $1.id : $0.scheduledAt < $1.scheduledAt }
    }

    private func companionPost(_ record: WorkspaceRecord) -> CompanionPost? {
        let scheduledAt: Date
        let state: CompanionPost.State
        let revision: String
        let channel: String
        if record.kind == "draft", ["queued", "due"].contains(record.scheduleStatus),
           let slot = record.schedule["slotAt"] as? String, let date = scheduleDate(slot) {
            scheduledAt = date
            state = record.scheduleStatus == "due" ? .review : .queued
            revision = record.schedule["companionRevision"] as? String ?? slot
            channel = SocialPlatform(rawValue: record["platform"])?.name ?? record["platform"]
        } else if record.kind == "newsletter", record["state"] == "scheduled", let date = scheduleDate(record["scheduledAt"]) {
            scheduledAt = date
            state = .queued
            revision = record["scheduledAt"]
            channel = "Substack"
        } else { return nil }
        let project = projects.first { $0.id == record.projectID }?["name"] ?? "Inkspring"
        return CompanionPost(id: record.id, revision: revision, title: String(record.title.prefix(200)),
                             project: String(project.prefix(200)), channel: channel, scheduledAt: scheduledAt,
                             state: state, canCancel: record.kind == "draft")
    }

    private func applyCompanionCancellations(_ schedule: CompanionSchedule) throws {
        for post in schedule.posts where post.state == .cancelled {
            try applyCompanionCancellation(post)
        }
    }

    private func applyCompanionCancellation(_ post: CompanionPost) throws {
        try withChanges {
            guard var draft = records.first(where: { $0.id == post.id && $0.kind == "draft" }),
                  companionPost(draft)?.revision == post.revision else { return }
            var schedule = draft.schedule
            schedule["slotAt"] = ""
            schedule["status"] = "ready"
            schedule["error"] = "Cancelled from a mobile device."
            draft.fields["schedule"] = schedule
            try save(draft)
        }
    }
}

struct CompanionSyncSettings: View {
    let workspace: Workspace
    @State private var confirming = false
    @State private var confirmingTransfer: CompanionTransfer?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text("Sync upcoming posts to Inkspring on iPhone and iPad using your private iCloud account. Titles, projects, platforms, and scheduled times appear there.")
                    .foregroundStyle(.secondary)
                if !CloudScheduleStore.hasEntitlement {
                    Text("This build needs iCloud provisioning to connect a mobile device.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        if let transfer = workspace.companionTransfer {
                            Button("Use this Mac for mobile sync…") { confirmingTransfer = transfer }
                            Button("Check again") { Task { await workspace.setCompanionSharing(true) } }
                        } else if workspace.companionSharing {
                            Button("Sync now") { Task { await workspace.syncCompanion() } }
                            Button("Turn off sync…") { confirming = true }
                        } else {
                            Button("Turn on schedule sync") { Task { await workspace.setCompanionSharing(true) } }
                        }
                        if workspace.companionBusy { ProgressView().controlSize(.small) }
                    }
                    .disabled(workspace.companionBusy || workspace.companionLibraryBusy)
                }
                if workspace.companionSharing, let date = workspace.companionLastSync {
                    Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }
                if workspace.companionTransfer != nil {
                    Text("Another Mac workspace manages mobile sync. Transfer it here to reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = workspace.companionError { Text(error).font(.caption).foregroundStyle(.red) }
                if workspace.companionSharing, workspace.companionTransfer == nil {
                    StudioRule()
                    Text("Library sync shares recent drafts, ideas, and review notes with Inkspring on your iPhone and iPad through private iCloud.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if workspace.companionLibrarySharing {
                            Button("Sync library now") { Task { await workspace.syncCompanionLibrary() } }
                        }
                        Button(workspace.companionLibrarySharing ? "Turn off library sync" : "Turn on library sync") {
                            Task { await workspace.setCompanionLibrarySharing(!workspace.companionLibrarySharing) }
                        }
                        if workspace.companionLibraryBusy { ProgressView().controlSize(.small) }
                    }
                    .disabled(workspace.companionLibraryBusy || workspace.companionBusy)
                    if let error = workspace.companionLibraryError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("iPhone and iPad", systemImage: "iphone")
        }
        .confirmationDialog("Turn off mobile sync?", isPresented: $confirming) {
            Button("Turn off sync", role: .destructive) { Task { await workspace.setCompanionSharing(false) } }
        } message: {
            Text("This also turns off library sync and clears shared copies and pending changes from iCloud.")
        }
        .confirmationDialog("Move mobile sync to this Mac?", isPresented: Binding(
            get: { confirmingTransfer != nil }, set: { if !$0 { confirmingTransfer = nil } }
        ), presenting: confirmingTransfer) { transfer in
            Button("Use this Mac") { Task { await workspace.transferCompanionSchedule(transfer) } }
        } message: { _ in
            Text("The iPhone schedule will come from this workspace. Automatic posting on this Mac will be paused so you can review the schedule.")
        }
    }
}
