import Foundation
import OSLog

extension WorkspaceRecord {
    var acceptsRevisionComments: Bool {
        kind == "draft" && (scheduleStatus.isEmpty || scheduleStatus == "ready")
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                Logger(subsystem: "com.protomota.inkspring.native", category: "RevisionComments")
                    .error("Could not apply a queued draft revision. It will be checked again.")
            }
        }
    }
}
