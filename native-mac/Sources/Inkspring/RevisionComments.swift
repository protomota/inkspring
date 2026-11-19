import Foundation
import OSLog

extension WorkspaceRecord {
    var acceptsRevisionComments: Bool {
        (kind == "idea" && self["status"] == "draft") ||
        (kind == "draft" && (scheduleStatus.isEmpty || scheduleStatus == "ready")
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
            (isLongForm && ["draft", "synced"].contains(self["state"]))
    }

    var appliedRevisionCommentIDs: [String] {
        fields["appliedRevisionCommentIDs"] as? [String] ?? []
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
            if Task.isCancelled { return }
            refreshAfterExternalWrite()
            if StudioWritingConnection(settings: settings) == .agent, settings["mcpEnabled"] as? Bool != true { return }
            guard let draft = records.first(where: { $0.id == id && $0.acceptsRevisionComments }) else { continue }
            var comments: [(id: String, text: String)] = []
            var notes = ""
            for comment in draft.pendingRevisionComments {
                let next = notes.isEmpty ? comment.text : notes + "\n\n" + comment.text
                guard next.utf16.count <= 4_000 else { break }
                notes = next
                comments.append(comment)
            }
            guard !comments.isEmpty else { continue }
            do {
                _ = try await ContentStudio(workspace: self, model: model)
                    .rewrite(draft, notes: notes, revisionCommentIDs: comments.map(\.id))
            } catch is CancellationError {
                return
            } catch {
                try? withChanges {
                    guard var current = records.first(where: { $0.id == id }), !current.pendingRevisionComments.isEmpty else { return }
                    current["writingRequestError"] = "Your Mac couldn’t finish this writing request. Your draft and request are safe; it will retry while Inkspring is open."
                    try database?.put(current)
                    try reload()
                }
                Logger(subsystem: "com.protomota.inkspring.native", category: "RevisionComments")
                    .error("Could not apply a queued draft revision. It will be checked again.")
            }
        }
    }
}
