import AppKit
import SwiftUI

struct AgentSettings: View {
    let workspace: Workspace
    @State private var client = StudioChatAgent.claude
    @State private var checking = false
    @State private var result: AgentConnectionCheck.Result?
    @State private var failure: String?

    private var enabled: Bool { workspace.settings["mcpEnabled"] as? Bool == true }
    private var command: String { Bundle.main.executableURL?.path ?? CommandLine.arguments[0] }

    enum Section { case all, access, client, test }
    var section: Section = .all
    @State private var showsGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if section == .all {
                Button("Open connection guide", systemImage: "book") { showsGuide = true }
                SetupHelpLink("Writing agent setup and troubleshooting", topic: "writing-agent")
            }
            if section == .access || section == .all { accessControls }
            if section == .client || section == .all { clientControls }
            if section == .test || section == .all { testControls }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showsGuide) { AgentConnectionGuide(workspace: workspace) }
        .onChange(of: enabled) { _, _ in
            result = nil
            failure = nil
        }
    }

    @ViewBuilder private var accessControls: some View {
        Toggle("Let AI agents use Inkspring", isOn: Binding(get: { enabled }, set: { value in
            workspace.perform { try workspace.set("mcpEnabled", to: value) }
        }))
        Text(enabled ? "Connected local agents can read and edit this workspace."
             : "Turn on agent access to set permissions and test your connection.")
            .foregroundStyle(.secondary)
        Toggle("Let agents set API keys and R2 credentials", isOn: Binding(get: {
            workspace.settings[AgentMCP.credentialPermission] as? Bool == true
        }, set: { value in
            workspace.perform { try workspace.set(AgentMCP.credentialPermission, to: value) }
        }))
        .disabled(!enabled)
        Toggle("Let agents publish X and LinkedIn posts immediately", isOn: Binding(get: {
            workspace.settings["mcpAllowPosting"] as? Bool == true
        }, set: { value in
            workspace.perform { try workspace.set("mcpAllowPosting", to: value) }
        }))
        .disabled(!enabled)
    }

    @ViewBuilder private var clientControls: some View {
        StudioSegmentedControl(selection: $client, options: [.claude, .codex]) { StudioAgentLabel(agent: $0) }
            .accessibilityLabel("Client")
        if client == .claude {
            StudioAgentLabel(agent: .claude, title: "Save the connection in the folder you use for your local Claude session.")
            Button("Save project connection…", action: saveProjectConnection).disabled(!enabled)
        } else {
            StudioAgentLabel(agent: .codex, title: "In Codex Settings, add an STDIO MCP server named inkspring.")
            field("Command", value: command)
            field("Argument", value: "--mcp")
        }
    }

    @ViewBuilder private var testControls: some View {
        HStack {
            Button("Test connection", systemImage: "checkmark.circle") {
                Task { await testConnection() }
            }
            .disabled(!enabled || checking)
            if checking { ProgressView().controlSize(.small).accessibilityLabel("Testing MCP connection") }
        }
        if enabled, let result {
            Label("Inkspring answered. \(result.toolCount) tools available. Projects read: \(result.projectCount).",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if enabled, let failure {
            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private func testConnection() async {
        guard enabled, !checking else { return }
        checking = true
        result = nil
        failure = nil
        defer { checking = false }
        do {
            let checked = try await workspace.verifyAgentConnection()
            if enabled { result = checked }
        } catch {
            if enabled { failure = error.localizedDescription }
        }
    }

    private func field(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
                    .textSelection(.enabled)
                Spacer()
                Button("Copy \(label.lowercased())") { copy(value) }
            }
        }
    }

    private func saveProjectConnection() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        workspace.perform {
            let file = directory.appending(path: ".mcp.json")
            var configuration: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw WorkspaceError("The existing .mcp.json is not a valid configuration.")
                }
                configuration = existing
            }
            let existing = configuration["mcpServers"]
            guard existing == nil || existing is [String: Any] else {
                throw WorkspaceError("The existing mcpServers entry is not a valid object.")
            }
            var servers = existing as? [String: Any] ?? [:]
            let connection: [String: Any] = ["type": "stdio", "command": command, "args": ["--mcp"]]
            if let previous = servers["inkspring"] {
                if let previous = previous as? NSDictionary, previous.isEqual(to: connection) {
                    workspace.notice = "Project already connects to native Inkspring"
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Replace the Inkspring connection?"
                alert.informativeText = "This project will use the native Inkspring workspace."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Replace connection")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            servers["inkspring"] = connection
            configuration["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
            workspace.notice = "Project connection saved"
        }
    }
}
