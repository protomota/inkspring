import Foundation
import InkspringSchedule

extension Workspace {
    var companionLibrarySharing: Bool { settings["companionLibrarySharing"] as? Bool == true }

    func setCompanionLibrarySharing(_ enabled: Bool) async {
        await withCompanionLibrarySync { cloud, id, account in
            if enabled {
                let snapshot = makeCompanionLibrary(workspaceID: id)
                _ = try await cloud.updateLibrary(workspaceID: id, account: account, create: true) { library in
                    library.enabled = true
                    updateLibrarySnapshot(&library, from: snapshot)
                }
            } else {
                try await cloud.clearLibrary(workspaceID: id, account: account)
            }
            try set("companionLibrarySharing", to: enabled)
        }
    }

    func syncCompanionLibrary() async {
        guard companionLibrarySharing else { return }
        var scheduleChanged = false
        await withCompanionLibrarySync { cloud, id, account in
            guard let previous = try await cloud.loadLibrary(workspaceID: id, account: account), previous.enabled else {
                throw CompanionLibraryError.disabled
            }
            let completed = try previous.pending.map(applyCompanionLibraryChange)
            scheduleChanged = zip(previous.pending, completed).contains { $0.0.action == .scheduleDraft && $0.1.error == nil }
            let snapshot = makeCompanionLibrary(workspaceID: id)
            _ = try await cloud.updateLibrary(workspaceID: id, account: account) { library in
                guard library.enabled else { throw CompanionLibraryError.disabled }
                library.acknowledge(completed)
                updateLibrarySnapshot(&library, from: snapshot)
            }
        }
        if scheduleChanged { await syncCompanion() }
    }

    private func withCompanionLibrarySync(
        _ operation: (CloudScheduleStore, UUID, String) async throws -> Void
    ) async {
        guard companionSharing, !companionBusy, !companionLibraryBusy else { return }
        companionLibraryBusy = true
        defer { companionLibraryBusy = false }
        do {
            try reload()
            try await operation(companionCloud(), companionWorkspaceID(), companionAccountKey())
            companionLibraryError = nil
        } catch {
            companionLibraryError = error.localizedDescription
        }
    }

    func makeCompanionLibrary(workspaceID: UUID) -> CompanionLibrary {
        var snapshot = CompanionLibrary(workspaceID: workspaceID)
        snapshot.supportsDraftEdits = true
        snapshot.supportsItemManagement = true
        snapshot.postingWindows = Dictionary(uniqueKeysWithValues: SocialPlatform.allCases.filter { $0 != .tiktok }.map {
            ($0.rawValue, postingWindow(for: $0.rawValue))
        })
        snapshot.postingTimeZone = TimeZone.current.identifier
        snapshot.projects = Array(projects.sorted {
            ($0.id == projectID ? 0 : 1, $0.title, $0.id) < ($1.id == projectID ? 0 : 1, $1.title, $1.id)
        }.prefix(100)).map {
            .init(id: $0.id, name: String($0.title.prefix(100)))
        }
        let projectIDs = Set(snapshot.projects.map(\.id))
        let candidates = (records + trashedRecords).filter {
            projectIDs.contains($0.projectID) &&
                ($0.kind == "idea" || $0.kind == "draft" && !["posted", "posting"].contains($0.scheduleStatus))
        }.sorted { ($0["updatedAt"], $0.id) > ($1["updatedAt"], $1.id) }
        let trashIDs = Set(trashedRecords.map(\.id))
        let encoder = JSONEncoder()
        var bytes = 0
        for kind in [CompanionLibrary.Item.Kind.draft, .idea] {
          for inTrash in [false, true] {
            let rows = candidates.filter { $0.kind == kind.rawValue && trashIDs.contains($0.id) == inTrash }
            var selected: [String: CompanionLibrary.Item] = [:]
            var kindBytes = 0
            func add(_ record: WorkspaceRecord) {
                guard selected.count < 50, selected[record.id] == nil else { return }
                let preview = String(record.body.prefix(40_000))
                let comments = record.comments.suffix(4).compactMap { comment -> (String, String)? in
                    guard let text = comment["text"] as? String else { return nil }
                    return (String(text.prefix(1000)), comment["at"] as? String ?? "")
                }
                let attachment: CompanionLibrary.Item.Attachment? =
                    record.fields["video"] is [String: Any] ? .video :
                    record.fields["image"] is [String: Any] ? .image : nil
                var item = CompanionLibrary.Item(
                    id: record.id, revision: record["updatedAt"], kind: kind, projectID: record.projectID,
                    title: String(record.title.prefix(200)), body: preview, shortened: preview != record.body,
                    platform: record["platform"], status: record.scheduleStatus.isEmpty ? record["status"] : record.scheduleStatus,
                    notes: comments.map(\.0), noteDates: comments.map(\.1), attachment: attachment
                )
                item.isTrashed = inTrash
                if record.fields["manualQuote"] as? Bool == true { item.requiresMacScheduling = true }
                guard let encoded = try? encoder.encode(item), kindBytes + encoded.count <= 52_000,
                      bytes + encoded.count <= 208_000 else { return }
                selected[record.id] = item
                kindBytes += encoded.count
                bytes += encoded.count
            }
            if kind == .draft, !inTrash {
                // Preserve a few video entries without increasing the iCloud preview budgets.
                for record in rows where record.fields["video"] is [String: Any] {
                    add(record)
                    if selected.count == 3 { break }
                }
            }
            for record in rows {
                if selected.count == 50 { break }
                add(record)
            }
            snapshot.items.append(contentsOf: rows.compactMap { selected[$0.id] })
            snapshot.hasMore = snapshot.hasMore || selected.count < rows.count
          }
        }
        snapshot.hasMore = snapshot.hasMore || snapshot.projects.count < projects.count
        return snapshot
    }

    private func updateLibrarySnapshot(_ library: inout CompanionLibrary, from snapshot: CompanionLibrary) {
        guard library.supportsDraftEdits != snapshot.supportsDraftEdits ||
              library.supportsItemManagement != snapshot.supportsItemManagement ||
              library.postingWindows != snapshot.postingWindows || library.postingTimeZone != snapshot.postingTimeZone ||
              library.projects != snapshot.projects || library.items != snapshot.items ||
              library.hasMore != snapshot.hasMore else { return }
        library.projects = snapshot.projects
        library.supportsDraftEdits = snapshot.supportsDraftEdits
        library.supportsItemManagement = snapshot.supportsItemManagement
        library.postingWindows = snapshot.postingWindows
        library.postingTimeZone = snapshot.postingTimeZone
        library.items = snapshot.items
        library.hasMore = snapshot.hasMore
        library.updatedAt = .now
    }

    func applyCompanionLibraryChange(_ change: CompanionLibrary.Change) throws -> CompanionLibrary.Result {
        try withChanges {
            let savedIDs = settings["companionLibraryApplied"] as? [String] ?? []
            let id = change.id.uuidString.lowercased()
            if savedIDs.contains(id) { return .init(id: change.id) }
            guard change.valid else { return .init(id: change.id, error: "Invalid mobile change.") }
            if let error = try applyLibraryAction(change, id: id) { return .init(id: change.id, error: error) }
            try set("companionLibraryApplied", to: Array((savedIDs + [id]).suffix(160)))
            return .init(id: change.id)
        }
    }

    private func applyLibraryAction(_ change: CompanionLibrary.Change, id: String) throws -> String? {
        if change.action == .addIdea {
            guard projects.contains(where: { $0.id == change.itemID }) else { return "This project no longer exists on your Mac." }
            if records.contains(where: { $0.id == id && $0.kind == "idea" }) { return nil }
            var idea = WorkspaceRecord.new("idea", projectID: change.itemID)
            idea["id"] = id
            idea["topic"] = change.title
            idea["text"] = change.text
            idea["origin"] = "Mobile"
            try save(idea)
            return nil
        }
        let active = records.first { $0.id == change.itemID && ["draft", "idea"].contains($0.kind) }
        let trashed = trashedRecords.first { $0.id == change.itemID && ["draft", "idea"].contains($0.kind) }
        let movesToTrash = change.action == .trashItem || change.action == .skipIdea
        if movesToTrash, trashed != nil { return nil }
        if change.action == .deleteItem, trashed == nil {
            if active != nil { return "Move this item to Trash again before deleting it." }
            if (settings["libraryDeletedIDs"] as? [String] ?? []).contains(change.itemID) { return nil }
        }
        let needsTrash = [.restoreItem, .restoreIdea, .deleteItem].contains(change.action)
        guard var record = needsTrash ? trashed : active else {
            return "This item is no longer available."
        }
        guard change.action == .note || record["updatedAt"] == change.revision else {
            return "This item changed since you opened it."
        }
        switch change.action {
        case .scheduleDraft:
            guard record.kind == "draft", let hour = change.postingHour,
                  let platform = SocialPlatform(rawValue: record["platform"]),
                  platform != .tiktok, record.fields["manualQuote"] as? Bool != true else {
                return "Finish scheduling this post on your Mac."
            }
            guard !["queued", "due", "posting", "posted", "uncertain"].contains(record.scheduleStatus) else {
                return "Check the post’s current status in Schedule before scheduling it again."
            }
            do {
                let slot = try preferredPostingDate(for: platform.rawValue, hour: hour, minute: postingMinute(for: platform.rawValue))
                _ = try scheduleDraft(record, at: slot)
            } catch { return error.localizedDescription }
        case .trashItem:
            do { try trashLibraryItem(record) } catch { return error.localizedDescription }
        case .restoreItem:
            do { try restoreLibraryItem(record) } catch { return error.localizedDescription }
        case .deleteItem:
            do { try deleteLibraryItem(record) } catch { return error.localizedDescription }
        case .editIdea:
            guard record.kind == "idea", ["draft", "skipped"].contains(record["status"]) else {
                return "This idea already has drafts. Edit those posts instead."
            }
            record["topic"] = change.title
            record["text"] = change.text
            try save(record)
        case .note:
            guard record.comments.count < 100 else { return "This item already has 100 review notes." }
            try addComment(to: record, text: change.text)
        case .skipIdea, .restoreIdea:
            let skipping = change.action == .skipIdea
            guard record.kind == "idea", record["status"] == (skipping ? "draft" : "skipped") else {
                return "This idea has already changed status."
            }
            if skipping {
                do { try trashLibraryItem(record) } catch { return error.localizedDescription }
                return nil
            }
            do { try restoreLibraryItem(record) } catch { return error.localizedDescription }
        case .editDraft:
            guard record.kind == "draft", !["posting", "posted", "uncertain"].contains(record.scheduleStatus) else {
                return "This draft can’t be edited while it’s publishing or published."
            }
            record["title"] = change.title
            record["content"] = change.text
            try save(record)
        case .addIdea:
            break
        }
        return nil
    }
}
