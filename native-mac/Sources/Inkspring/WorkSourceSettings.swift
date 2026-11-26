import AppKit
import SwiftUI

struct WorkSourceSettings: View {
    let workspace: Workspace
    @State private var projectID = ""
    @State private var scanning = false
    @State private var found: WorkContext.Result?
    @State private var selected: Set<Int> = []

    private var schedule: [String: Any] { workspace.workSourceSchedule(projectID) }
    private var enabled: Bool { schedule["enabled"] as? Bool == true && schedule["nativeApproved"] as? Bool == true }
    private var hours: Int { schedule["hours"] as? Int ?? 24 }

    var body: some View {
        GroupBox("Idea source schedule") {
            VStack(alignment: .leading, spacing: 12) {
                StudioLabeledChoice(title: "Project", selection: $projectID,
                                    options: [""] + workspace.projects.map(\.id),
                                    label: { id in workspace.projects.first(where: { $0.id == id })?.title ?? "Choose a project" })
                Group {
                    folder("Project folder", key: "codeFolder")
                    folder("Obsidian notes folder", key: "notesFolder")
                    StudioLabeledChoice(title: "Refresh frequency", selection: Binding(get: { hours }, set: {
                        configure(hours: $0, enabled: enabled)
                    }), options: [1, 6, 24], label: { $0 == 24 ? "Every day" : $0 == 1 ? "Every hour" : "Every 6 hours" })
                    Toggle("Refresh idea sources automatically", isOn: Binding(get: { enabled }, set: {
                        configure(hours: hours, enabled: $0)
                    }))
                    .disabled(!["codeFolder", "notesFolder"].contains { !(schedule[$0] as? String ?? "").isEmpty })
                }
                .disabled(projectID.isEmpty)
                Text("Automatic refresh saves recent work and notes from your chosen folders as project references. Your writing model can use those references when generating ideas.")
                    .font(.caption).foregroundStyle(.secondary)
                if enabled, let count = schedule["lastCount"] as? Int,
                   let value = schedule["lastAttemptAt"] as? String, let date = scheduleDate(value) {
                    Text("Last refresh \(date.formatted(date: .abbreviated, time: .shortened)) · \(count) new references")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if enabled { availability(schedule["unavailable"] as? [String] ?? []) }
                Divider()
                Button(scanning ? "Finding recent work…" : "Review recent work manually…",
                       systemImage: "folder", action: scan)
                    .disabled(projectID.isEmpty || scanning)
                if let found {
                    availability(found.unavailable)
                    if found.items.isEmpty { Text("No work found in the last two days.").foregroundStyle(.secondary) }
                    ForEach(found.items.indices, id: \.self) { index in
                        review(index, item: found.items[index])
                    }
                    if !found.items.isEmpty {
                        Button("Save selected references", action: save)
                            .disabled(projectID.isEmpty || selected.isEmpty || scanning)
                    }
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if projectID.isEmpty { projectID = workspace.projectID }
        }
        .onChange(of: projectID) { _, _ in found = nil; selected.removeAll() }
    }

    private func folder(_ title: String, key: String) -> some View {
        let path = schedule[key] as? String ?? ""
        return HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(path.isEmpty ? "Choose a folder" : path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(path.isEmpty ? "Choose…" : "Change…") {
                guard let url = chooseFolder("Choose " + title.lowercased()) else { return }
                update([key: url.resolvingSymlinksInPath().path, "enabled": false])
            }
            if !path.isEmpty { Button("Remove") { update([key: "", "enabled": false]) } }
        }
    }

    @ViewBuilder private func availability(_ sources: [String]) -> some View {
        if !sources.isEmpty {
            Text("Couldn’t read " + sources.joined(separator: ", ") + ".")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func review(_ index: Int, item: WorkReference) -> some View {
        DisclosureGroup {
            Toggle("Use this reference", isOn: Binding(get: { selected.contains(index) }, set: {
                if $0 { selected.insert(index) } else { selected.remove(index) }
            }))
            .disabled(selected.count >= 20 && !selected.contains(index))
            TextField("Summary", text: Binding(get: { found?.items[index].text ?? "" }, set: {
                found?.items[index].text = String($0.prefix(2000))
            }), axis: .vertical)
            .lineLimit(3...6)
            .studioInput()
        } label: {
            VStack(alignment: .leading) {
                Text(item.title).lineLimit(1)
                Group {
                    switch item.origin {
                    case .claude: StudioAgentLabel(agent: .claude, title: "Claude recap")
                    case .codex: StudioAgentLabel(agent: .codex, title: "Codex recap")
                    default: Text(item.origin.rawValue)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func configure(hours: Int, enabled: Bool) {
        update(["hours": hours, "enabled": enabled, "nativeApproved": enabled])
        if enabled { Task { await workspace.refreshScheduledWork() } }
    }

    private func update(_ fields: [String: Any]) {
        workspace.perform { try workspace.updateWorkSourceSchedule(projectID, fields: fields) }
    }

    private func scan() {
        guard let folder = chooseFolder("Choose a project folder to find recent work") else { return }
        let project = projectID
        scanning = true
        Task {
            let result = await Task.detached(priority: .utility) { WorkContext().collect(code: folder, notes: nil) }.value
            scanning = false
            guard project == projectID else { return }
            found = result
            selected.removeAll()
        }
    }

    private func save() {
        guard let found else { return }
        let items = selected.sorted().map { found.items[$0] }
        workspace.perform {
            let count = try workspace.saveWorkReferences(items, projectID: projectID)
            selected.removeAll()
            workspace.notice = count == 0 ? "These references are already saved." : "Saved \(count) project references."
        }
    }

    private func chooseFolder(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension Workspace {
    func workSourceSchedule(_ projectID: String) -> [String: Any] {
        (settings["workSourceSchedules"] as? [String: [String: Any]])?[projectID] ?? [:]
    }

    func updateWorkSourceSchedule(_ projectID: String, fields: [String: Any], reset: Bool = true) throws {
        try withChanges {
            guard projects.contains(where: { $0.id == projectID }) else { throw WorkspaceError("Choose an existing project.") }
            var all = settings["workSourceSchedules"] as? [String: [String: Any]] ?? [:]
            var next = all[projectID] ?? [:]
            if reset {
                for key in ["lastAttemptAt", "lastCount", "unavailable"] { next.removeValue(forKey: key) }
            }
            next.merge(fields) { _, value in value }
            all[projectID] = next
            try set("workSourceSchedules", to: all)
        }
    }

    func saveWorkReferences(_ items: [WorkReference], projectID: String) throws -> Int {
        guard (1...20).contains(items.count) else { throw WorkspaceError("Choose up to 20 references.") }
        return try withChanges {
            guard projects.contains(where: { $0.id == projectID }) else { throw WorkspaceError("Choose an existing project.") }
            var known = Set(records.filter { $0.kind == "source" && $0.projectID == projectID }.map { [$0["title"], $0["text"]] })
            var count = 0
            for item in items {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 2000, !item.title.isEmpty else {
                    throw WorkspaceError("Enter a title and a summary for each selected reference.")
                }
                guard known.insert([item.title, text]).inserted else { continue }
                var source = WorkspaceRecord.new("source", projectID: projectID)
                source["title"] = item.title
                source["text"] = text
                source["origin"] = item.origin.rawValue
                source["postedAt"] = workspaceTimestamp(item.at)
                _ = try save(source)
                count += 1
            }
            return count
        }
    }

    func refreshScheduledWork() async {
        guard !refreshingWorkSources else { return }
        refreshingWorkSources = true
        defer { refreshingWorkSources = false }
        for id in projects.map(\.id) where !Task.isCancelled {
            let config = workSourceSchedule(id)
            guard config["enabled"] as? Bool == true, config["nativeApproved"] as? Bool == true else { continue }
            let hours = config["hours"] as? Int ?? 24
            let interval = [1, 6, 24].contains(hours) ? hours : 24
            let last = (config["lastAttemptAt"] as? String).flatMap(scheduleDate) ?? .distantPast
            guard Date.now.timeIntervalSince(last) >= Double(interval * 3600) else { continue }
            let code = (config["codeFolder"] as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            let notes = (config["notesFolder"] as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            guard code != nil || notes != nil else { continue }
            let attempt = WorkspaceRecord.timestamp
            do {
                try updateWorkSourceSchedule(id, fields: ["lastAttemptAt": attempt], reset: false)
                let result = await Task.detached(priority: .utility) { WorkContext().collect(code: code, notes: notes, limit: 20) }.value
                guard !Task.isCancelled else { return }
                let saved = try withChanges {
                    let latest = workSourceSchedule(id)
                    guard latest["enabled"] as? Bool == true, latest["lastAttemptAt"] as? String == attempt else { return false }
                    let count = result.items.isEmpty ? 0 : try saveWorkReferences(result.items.reversed(), projectID: id)
                    try updateWorkSourceSchedule(id, fields: ["lastCount": count, "unavailable": result.unavailable], reset: false)
                    return true
                }
                if saved { await refillIdeaQueueIfNeeded(projectID: id) }
            } catch {
                notice = "Idea sources couldn’t refresh: " + error.localizedDescription
            }
        }
    }
}
