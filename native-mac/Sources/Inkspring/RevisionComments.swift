import Foundation
import OSLog
import InkspringSchedule

extension WorkspaceRecord {
    var acceptsRevisionComments: Bool {
        (kind == "idea" && self["status"] == "draft" && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
        (kind == "draft" && (scheduleStatus.isEmpty || scheduleStatus == "ready")
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
            (isLongForm && ["draft", "synced"].contains(self["state"]))
    }

    var appliedRevisionCommentIDs: [String] {
        fields["appliedRevisionCommentIDs"] as? [String] ?? []
    }

    var revisionRequests: [CompanionLibrary.RevisionRequest] {
        let applied = Set(appliedRevisionCommentIDs)
        let acceptsRequests = acceptsRevisionComments
        return comments.enumerated().compactMap { index, row in
            guard let text = row["text"] as? String else { return nil }
            let id = row["revisionRequestID"] as? String
            let state: CompanionLibrary.RevisionRequest.State
            if let id {
                state = applied.contains(id) ? .actedOn : acceptsRequests ? .pending : .waitingForEditable
            } else { state = .savedNote }
            return .init(id: id ?? "legacy-\(index)", text: text, date: row["at"] as? String, state: state)
        }
    }

    var pendingRevisionComments: [(id: String, text: String, writing: CompanionLibrary.WritingSelection?, fromCompanion: Bool)] {
        let applied = Set(appliedRevisionCommentIDs)
        return comments.compactMap { comment in
            guard let id = comment["revisionRequestID"] as? String, !applied.contains(id),
                  let text = comment["text"] as? String else { return nil }
            let writing = (comment["writingProvider"] as? String).map {
                CompanionLibrary.WritingSelection(provider: $0, model: comment["writingModel"] as? String)
            }
            return (id, text, writing, comment["source"] as? String == "companion" || writing != nil)
        }
    }
}

extension Workspace {
    func withdrawnRevisionIDs(for itemID: String) -> Set<String> {
        Set((settings["companionRevisionWithdrawals"] as? [String: [String]])?[itemID] ?? [])
    }

    // Called inside the same database transaction as the companion change receipt.
    func withdrawRevision(_ target: UUID, itemID: String) throws -> String? {
        let id = target.uuidString.lowercased()
        let record = (records + trashedRecords).first { $0.id == itemID }
        if record?.appliedRevisionCommentIDs.contains(id) == true {
            return "Already applied on your Mac. Your revision history is available."
        }
        var withdrawals = settings["companionRevisionWithdrawals"] as? [String: [String]] ?? [:]
        if !(withdrawals[itemID] ?? []).contains(id) {
            withdrawals[itemID, default: []].append(id)
            try set("companionRevisionWithdrawals", to: withdrawals)
        }
        if var record, record.comments.contains(where: { $0["revisionRequestID"] as? String == id }) {
            record.fields["reviewComments"] = record.comments.filter { $0["revisionRequestID"] as? String != id }
            if record.pendingRevisionComments.isEmpty { record.fields["writingRequestError"] = nil }
            try database?.put(record)
            try reload()
        }
        if let activeRevision, activeRevision.itemID == itemID, activeRevision.ids.contains(id) {
            activeRevision.task.cancel()
        }
        return nil
    }

    func runDraftRevisionComments(model: ContentStudio.Model? = nil) async {
        guard !runningDraftRevisions else { return }
        runningDraftRevisions = true
        defer { runningDraftRevisions = false }
        do { try reload() }
        catch { return }
        let draftIDs = records.filter { $0.acceptsRevisionComments && !$0.pendingRevisionComments.isEmpty }.map(\.id)
        for id in draftIDs {
            while !Task.isCancelled {
                refreshAfterExternalWrite()
                guard let draft = records.first(where: { $0.id == id && $0.acceptsRevisionComments }) else { break }
                let appliedMobileIDs = settings["companionLibraryApplied"] as? [String] ?? []
                let pending = draft.pendingRevisionComments.filter { request in
                    if agentConnected || (agentAccessEnabled && model != nil) { return true }
                    return writingToolsAvailable && !request.fromCompanion && !appliedMobileIDs.contains(request.id)
                }
                let selection = pending.first?.writing
                var requestIDs: [String] = []
                var notes = ""
                for request in pending {
                    guard request.writing == selection else { break }
                    let next = notes.isEmpty ? request.text : notes + "\n\n" + request.text
                    guard next.utf16.count <= 4_000 else { break }
                    notes = next
                    requestIDs.append(request.id)
                }
                guard !requestIDs.isEmpty else { break }
                do {
                    let writer = try model ?? selection.map { try companionWritingModel($0) }
                    let task = Task {
                        _ = try await ContentStudio(workspace: self, model: writer)
                            .rewrite(draft, notes: notes, revisionCommentIDs: requestIDs)
                    }
                    activeRevision = (id, Set(requestIDs), task)
                    defer { activeRevision = nil }
                    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                } catch is CancellationError {
                    if Task.isCancelled { return }
                    if !withdrawnRevisionIDs(for: id).isDisjoint(with: requestIDs) { continue }
                    return
                } catch {
                    try? withChanges {
                        guard var current = records.first(where: { $0.id == id }), !current.pendingRevisionComments.isEmpty else { return }
                        current["writingRequestError"] = selection == nil
                            ? "Your Mac couldn’t finish these revision requests. The draft and requests are saved and will be checked again."
                            : error.localizedDescription
                        try database?.put(current)
                        try reload()
                    }
                    Logger(subsystem: "com.protomota.inkspring.native", category: "RevisionComments")
                        .error("Could not apply a queued draft revision. It will be checked again.")
                    break
                }
            }
        }
    }
}
