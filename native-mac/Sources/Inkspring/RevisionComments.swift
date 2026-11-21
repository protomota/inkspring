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

    var pendingRevisionComments: [(id: String, text: String)] {
        let applied = Set(appliedRevisionCommentIDs)
        return comments.compactMap { comment in
            guard let id = comment["revisionRequestID"] as? String, !applied.contains(id),
                  let text = comment["text"] as? String else { return nil }
            return (id, text)
        }
    }
}

extension Workspace {
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
                guard writingToolsAvailable || (model != nil && agentAccessEnabled) else { return }
                guard let draft = records.first(where: { $0.id == id && $0.acceptsRevisionComments }) else { break }
                var requestIDs: [String] = []
                var notes = ""
                for request in draft.pendingRevisionComments {
                    let next = notes.isEmpty ? request.text : notes + "\n\n" + request.text
                    guard next.utf16.count <= 4_000 else { break }
                    notes = next
                    requestIDs.append(request.id)
                }
                guard !requestIDs.isEmpty else { break }
                do {
                    _ = try await ContentStudio(workspace: self, model: model)
                        .rewrite(draft, notes: notes, revisionCommentIDs: requestIDs)
                } catch is CancellationError {
                    return
                } catch {
                    try? withChanges {
                        guard var current = records.first(where: { $0.id == id }), !current.pendingRevisionComments.isEmpty else { return }
                        current["writingRequestError"] = "Your Mac couldn’t finish these revision requests. The draft and requests are saved and will be checked again."
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
