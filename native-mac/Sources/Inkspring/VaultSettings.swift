import AppKit
import SwiftUI

struct VaultSettings: View {
    let workspace: Workspace
    @State private var notes: [[String: Any]] = []
    @State private var selected: Set<String> = []
    @State private var previews: [[String: String]] = []
    @State private var query = ""
    @State private var busy = false

    private var config: [String: Any] { workspace.settings["obsidianVault"] as? [String: Any] ?? [:] }

    var body: some View {
        GroupBox("Obsidian vault") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(config["name"] as? String ?? "Choose a folder of Markdown notes.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose folder…", action: chooseFolder)
                    if config["path"] is String {
                        Button("Disconnect") {
                            workspace.perform {
                                try workspace.set("obsidianVault", to: NSNull())
                                notes = []
                                selected = []
                                previews = []
                            }
                        }
                    }
                }
                if config["path"] is String {
                    Toggle("Allow connected agents to browse and read notes", isOn: Binding(get: {
                        config["allowAgents"] as? Bool == true
                    }, set: { enabled in
                        workspace.perform {
                            var next = config
                            next["allowAgents"] = enabled
                            try workspace.set("obsidianVault", to: next)
                        }
                    }))
                    HStack {
                        TextField("Search note titles", text: $query).studioInput()
                        Button("List notes", action: load)
                        Button("Preview selection", action: preview).disabled(selected.isEmpty)
                    }
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        if let id = note["id"] as? String {
                            Toggle(id, isOn: Binding(get: { selected.contains(id) }, set: { include in
                                if include && selected.count < 8 { selected.insert(id) }
                                else if !include { selected.remove(id) }
                                previews = []
                            }))
                        }
                    }
                    if !previews.isEmpty {
                        ForEach(Array(previews.enumerated()), id: \.offset) { _, note in
                            DisclosureGroup(note["title"] ?? "Note") {
                                Text(note["text"] ?? "").textSelection(.enabled)
                            }
                        }
                        Button("Suggest ideas from these notes") { Task { await suggest() } }
                            .disabled(workspace.project == nil || busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.perform {
            let vault = try ObsidianVault(url.path)
            try workspace.set("obsidianVault", to: ["path": vault.root.path, "name": vault.root.lastPathComponent, "allowAgents": false])
            notes = []
            selected = []
            previews = []
        }
    }

    private func load() {
        workspace.perform {
            let result = try workspace.connectedVault().list(query: query)
            notes = result.notes
            selected = []
            previews = []
        }
    }

    private func preview() {
        workspace.perform { previews = try workspace.connectedVault().preview(selected.sorted()).notes }
    }

    private func suggest() async {
        guard !busy, let project = workspace.project else { return }
        busy = true
        defer { busy = false }
        do {
            let count = try await ContentStudio(workspace: workspace).suggestVaultIdeas(
                projectID: project.id, references: previews
            )
            workspace.notice = "\(count) suggestions saved for review"
        } catch { workspace.error = error.localizedDescription }
    }
}
