import Foundation
import SwiftUI
import InkspringSchedule

extension Workspace {
    @discardableResult
    func savePlan(itemID: String, markdown: String, base: String) throws -> WorkspaceRecord {
        try ContentPlan.validate(markdown)
        return try withChanges {
            guard var current = records.first(where: { $0.id == itemID && ["draft", "idea", "newsletter", "script", "article"].contains($0.kind) }) else {
                throw WorkspaceError("This content is unavailable. Restore it from Trash before editing its plan.")
            }
            guard current["planMarkdown"] == base else { throw ContentPlanError.conflict }
            current["previousPlanMarkdown"] = current["planMarkdown"]
            current["planMarkdown"] = markdown
            return try save(current)
        }
    }

    func applyContentOperation(_ change: CompanionLibrary.Change, requestID: String) throws -> String? {
        guard let operation = change.contentOperation else { return "Unsupported content operation." }
        switch operation {
        case .savePlan:
            do { try savePlan(itemID: change.itemID, markdown: change.text, base: change.basePlan ?? "") }
            catch { return error.localizedDescription }
        case .createProject, .createDraft, .createNewsletter:
            if (records + trashedRecords).contains(where: { $0.id == requestID }) ||
                (settings["libraryDeletedIDs"] as? [String] ?? []).contains(requestID) { return nil }
            if operation != .createProject, !projects.contains(where: { $0.id == change.itemID }) { return "Choose an existing project." }
            var record = WorkspaceRecord.new(operation == .createProject ? "project" : operation == .createDraft ? "draft" : "newsletter", projectID: operation == .createProject ? "" : change.itemID)
            record["id"] = requestID
            record.fields["planMarkdown"] = change.initialPlan
            record[operation == .createProject ? "name" : "title"] = change.title
            record[operation == .createNewsletter ? "body" : "content"] = change.text
            try save(record)
        case .setTitle:
            guard var record = records.first(where: { $0.id == change.itemID }), record["updatedAt"] == change.revision else { return "This item changed. Refresh before renaming it." }
            record[record.kind == "project" ? "name" : record.kind == "idea" ? "topic" : "title"] = change.text
            try save(record)
        case .moveProject:
            guard var record = records.first(where: { $0.id == change.itemID }),
                  projects.contains(where: { $0.id == change.text }), record["updatedAt"] == change.revision else {
                return "The item or project changed. Refresh before moving it."
            }
            record["projectId"] = change.text
            try save(record)
        }
        return nil
    }
}

struct WorkspacePlanSection: View {
    let record: WorkspaceRecord
    let workspace: Workspace
    var editable = true
    private var current: WorkspaceRecord { workspace.records.first { $0.id == record.id } ?? record }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        ContentPlanSection(markdown: current["planMarkdown"], reference: current.referenceID ?? current.id,
                           context: current.title, recoveryID: (workspace.directory?.path ?? "workspace") + "." + current.id,
                           editable: editable && workspace.records.contains { $0.id == record.id }) { markdown, base in
            try workspace.savePlan(itemID: record.id, markdown: markdown, base: base)
        }
        if editable, let previous = current.fields["previousPlanMarkdown"] as? String {
            Button("Restore previous plan", systemImage: "arrow.uturn.backward") {
                workspace.perform { try workspace.savePlan(itemID: current.id, markdown: previous, base: current["planMarkdown"]) }
            }
        }
        }
    }
}

extension Workspace {
    var assistantContents: [AssistantContent] {
        records.filter { ["project", "draft", "idea", "newsletter"].contains($0.kind) }.map {
            .init(id: $0.id, reference: $0.referenceID ?? $0.id, kind: $0.kind, title: $0.title,
                  project: $0.projectID, revision: $0["updatedAt"], body: $0.body)
        }
    }
    func executeAssistant(_ command: LocalContentCommand, request: String) throws -> AssistantActionResult {
        try command.validateIntent(request)
        if command.operation == .find {
            let query = command.target.lowercased()
            let matches = assistantContents.filter { query.isEmpty || query == "my drafts" && $0.kind == "draft" ||
                query == "drafts" && $0.kind == "draft" || $0.kind == query || $0.title.localizedCaseInsensitiveContains(query) || $0.reference.localizedCaseInsensitiveContains(query) }
            return .init(message: matches.isEmpty ? "No matches. Try an ID or title words." : matches.map { "\($0.reference) · \($0.kind) · \($0.title)" }.joined(separator: "\n"))
        }
        if command.operation == .review {
            return .init(message: "Use the item’s Schedule, publishing, Trash or agent controls to review and confirm this action. Nothing was changed.")
        }
        if [.createIdea, .createDraft, .createNewsletter, .createProject].contains(command.operation) {
            let kind = command.operation == .createIdea ? "idea" : command.operation == .createDraft ? "draft" : command.operation == .createNewsletter ? "newsletter" : "project"
            let project = kind == "project" ? "" : try assistantProject(command.project)
            var record = WorkspaceRecord.new(kind, projectID: kind == "project" ? "" : project)
            record[kind == "project" ? "name" : kind == "idea" ? "topic" : "title"] = command.title
            record[kind == "idea" ? "text" : kind == "newsletter" ? "body" : "content"] = command.value
            if kind != "project", ContentPlan.requested(in: request) { record["planMarkdown"] = ContentPlan.starter(command.title) }
            let saved = try save(record)
            return .init(message: "Created \(saved.referenceID ?? saved.id) · \(saved.title). Saved on this Mac; unpublished.", itemID: saved.id)
        }
        let target = try command.resolve(in: assistantContents, request: request)
        guard var record = records.first(where: { $0.id == target.id }) else { throw WorkspaceError("Refresh and try again.") }
        if command.operation == .read { return .init(message: "\(target.reference) · \(target.title)\n\n\(target.body)", itemID: target.id) }
        if command.operation == .plan { return .init(message: "Open \(target.reference) to edit its Plan and review AI suggestions. No saved text changed.", itemID: target.id) }
        switch command.operation {
        case .title: record[record.kind == "project" ? "name" : record.kind == "idea" ? "topic" : "title"] = command.value
        case .body:
            guard ["draft", "idea", "newsletter"].contains(record.kind) else { throw WorkspaceError("Choose a post, idea or newsletter.") }
            record[record.kind == "idea" ? "text" : record.kind == "newsletter" ? "body" : "content"] = command.value
        case .project:
            guard record.kind != "project" else { throw WorkspaceError("Choose writing to move between projects.") }
            record["projectId"] = try assistantProject(command.value)
        default: throw WorkspaceError("That action needs the app’s review controls. Nothing changed.")
        }
        let saved = try save(record)
        return .init(message: "Updated \(saved.referenceID ?? saved.id) · \(saved.title). Saved on this Mac; no publication was sent.", itemID: saved.id)
    }
    private func assistantProject(_ query: String) throws -> String {
        if query.isEmpty { return projectID }
        let matches = projects.filter { $0.matchesID(query) || $0.title.caseInsensitiveCompare(query) == .orderedSame }
        guard matches.count == 1, let project = matches.first else { throw WorkspaceError("Use the exact project name or ID.") }
        return project.id
    }
}
