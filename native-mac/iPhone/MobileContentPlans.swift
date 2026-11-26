import SwiftUI

extension MobileLibrary {
    func planText(_ item: CompanionLibrary.Item) -> String {
        let current = ((snapshot?.items ?? []) + (snapshot?.newsletters ?? []) + (snapshot?.scripts ?? []) + (snapshot?.articles ?? [])).first { $0.id == item.id } ?? item
        return pendingChanges(for: item.id).last(where: { $0.contentOperation == .savePlan })?.text ?? current.planMarkdown ?? ""
    }
    func savePlan(_ text: String, base: String, item: CompanionLibrary.Item, workspaceID: UUID) throws {
        try ContentPlan.validate(text)
        guard planText(item) == base else { throw ContentPlanError.conflict }
        var change = CompanionLibrary.Change(action: .editDraft, itemID: item.id, revision: item.revision, text: text)
        change.contentOperation = .savePlan; change.basePlan = base
        try saveChange(change, workspaceID: workspaceID)
    }
    var assistantContents: [AssistantContent] {
        let projects = (snapshot?.projects ?? []).map {
            AssistantContent(id: $0.id, reference: $0.id, kind: "project", title: $0.name, project: "", revision: "", body: "")
        }
        return projects + ((snapshot?.items ?? []) + (snapshot?.newsletters ?? [])).filter { $0.isTrashed != true }.map {
            let edit = pendingChanges(for: $0.id).last { [.editDraft, .editIdea].contains($0.action) && $0.contentOperation == nil && $0.error == nil }
            return .init(id: $0.id, reference: $0.referenceID ?? $0.id, kind: $0.kind.rawValue,
                         title: edit?.title.isEmpty == false ? edit!.title : $0.title, project: $0.projectID,
                         revision: $0.revision, body: edit?.text ?? $0.body)
        }
    }
    func executeAssistant(_ command: LocalContentCommand, request: String) throws -> AssistantActionResult {
        try command.validateIntent(request)
        guard let snapshot else { throw PlanAIError("Sync your library first. Nothing changed.") }
        if command.operation == .find {
            let query = command.target.lowercased()
            let matches = assistantContents.filter { query.isEmpty || query == "drafts" && $0.kind == "draft" ||
                query == "my drafts" && $0.kind == "draft" || $0.kind == query || $0.title.localizedCaseInsensitiveContains(query) || $0.reference.localizedCaseInsensitiveContains(query) }
            return .init(message: matches.isEmpty ? "No matches. Try an ID or title words." : matches.map { "\($0.reference) · \($0.kind) · \($0.title)" }.joined(separator: "\n"))
        }
        if command.operation == .review { return .init(message: "Use the item’s Schedule, Trash or publishing review controls. Nothing changed.") }
        func project(_ query: String) throws -> String {
            if query.isEmpty, let first = snapshot.projects.first { return first.id }
            let matches = snapshot.projects.filter { $0.id.caseInsensitiveCompare(query) == .orderedSame || $0.name.caseInsensitiveCompare(query) == .orderedSame }
            guard matches.count == 1, let match = matches.first else { throw PlanAIError("Use the exact project name or ID.") }
            return match.id
        }
        if [.createIdea, .createDraft, .createNewsletter, .createProject].contains(command.operation) {
            let projectID = try project(command.project)
            if command.operation == .createIdea {
                try saveIdea(title: command.title, text: command.value, projectID: projectID,
                             plan: ContentPlan.requested(in: request) ? ContentPlan.starter(command.title) : nil)
            } else {
                guard snapshot.supportsContentPlans == true else { throw PlanAIError("This Mac version cannot accept this action yet. Your writing is unchanged.") }
                var change = CompanionLibrary.Change(action: .editDraft, itemID: projectID, title: command.title, text: command.value)
                change.contentOperation = command.operation == .createDraft ? .createDraft : command.operation == .createNewsletter ? .createNewsletter : .createProject
                if command.operation != .createProject, ContentPlan.requested(in: request) { change.initialPlan = ContentPlan.starter(command.title) }
                try saveChange(change, workspaceID: snapshot.workspaceID)
            }
            return .init(message: "Saved the request on this device. Waiting for your Mac to create “\(command.title)”. It has not been published.")
        }
        let target = try command.resolve(in: assistantContents, request: request)
        if command.operation == .read { return .init(message: "\(target.reference) · \(target.title)\n\n\(target.body)", itemID: target.id) }
        if command.operation == .plan { return .init(message: "Open \(target.reference) to edit its Plan and review suggestions. No saved text changed.", itemID: target.id) }
        guard let item = ((snapshot.items) + (snapshot.newsletters ?? [])).first(where: { $0.id == target.id }) else { throw PlanAIError("Choose writing from your synced library.") }
        var change: CompanionLibrary.Change
        if command.operation == .project {
            change = .init(action: .editDraft, itemID: item.id, revision: item.revision, text: try project(command.value))
            change.contentOperation = .moveProject
        } else if item.kind == .newsletter {
            if command.operation == .title {
                change = .init(action: .editDraft, itemID: item.id, revision: item.revision, text: command.value)
                change.contentOperation = .setTitle
            } else {
                change = .init(action: .editDraft, itemID: item.id, revision: item.revision, text: command.value, editsNewsletter: true, baseNewsletterText: target.body)
            }
        } else {
            change = .init(action: item.kind == .idea ? .editIdea : .editDraft, itemID: item.id, revision: item.revision,
                           title: command.operation == .title ? command.value : target.title,
                           text: command.operation == .body ? command.value : target.body)
        }
        try saveChange(change, workspaceID: snapshot.workspaceID)
        return .init(message: "Saved the edit on this device. Waiting for your Mac to apply it to \(target.reference).", itemID: target.id)
    }
}

struct MobilePlanSection: View {
    let item: CompanionLibrary.Item
    let library: MobileLibrary
    let workspaceID: UUID
    let close: () -> Void
    @State private var conflictMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if item.isTrashed != true && library.snapshot?.supportsContentPlans == true {
                    ContentPlanEditor(markdown: library.planText(item), reference: item.referenceID ?? item.id, context: item.title,
                                   recoveryID: library.planRecoveryID(item.id, workspaceID: workspaceID),
                                   save: { text, base in
                                       try library.savePlan(text, base: base, item: item, workspaceID: workspaceID)
                                   }, close: close)
                } else {
                    Button("Back", systemImage: "chevron.left", action: close)
                    PlanMarkdownPreview(markdown: library.planText(item))
                }
                if let previous = item.previousPlanMarkdown, library.snapshot?.supportsContentPlans == true, item.isTrashed != true {
                    Button("Restore previous plan", systemImage: "arrow.uturn.backward") {
                        do { try library.savePlan(previous, base: library.planText(item), item: item, workspaceID: workspaceID) }
                        catch { library.error = error.localizedDescription }
                    }
                }
                if library.snapshot?.supportsContentPlans != true { Text("Plan editing will be available after your Mac shares support for Plans.").font(.caption) }
                if let entry = library.pendingChanges(for: item.id).last(where: { $0.contentOperation == .savePlan }) {
                    Text(entry.error ?? "Plan saved on this device. Waiting for your Mac to apply it.").font(.caption)
                    if entry.error != nil {
                        DisclosureGroup("Compare the Plan on your Mac") {
                            PlanMarkdownPreview(markdown: item.planMarkdown ?? "")
                            Button("Replace Mac Plan with my saved version") {
                                do {
                                    var change = CompanionLibrary.Change(action: .editDraft, itemID: item.id, revision: item.revision, text: entry.text)
                                    change.contentOperation = .savePlan; change.basePlan = item.planMarkdown ?? ""
                                    try library.saveChange(change, workspaceID: workspaceID)
                                    conflictMessage = nil
                                } catch { conflictMessage = error.localizedDescription }
                            }
                        }
                    }
                    if let conflictMessage { Text(conflictMessage).font(.caption) }
                }
            }
            .padding()
        }
        .navigationTitle("Outline")
        .navigationBarTitleDisplayMode(.inline)
    }
}
