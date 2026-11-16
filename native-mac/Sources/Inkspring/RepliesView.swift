import SwiftUI

struct RepliesView: View {
    let workspace: Workspace
    let openDraft: (WorkspaceRecord) -> Void
    @State private var filter = "Inbox"

    private var inbox: ReplyInbox { ReplyInbox(workspace: workspace) }
    private var rows: [WorkspaceRecord] {
        inbox.rows.filter { filter == "Ignored" ? $0["status"] == "archived" : $0["status"] != "archived" }
    }

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    PageHeading(title: "Keep the conversation going.",
                                subtitle: "Read replies and mentions, then draft a response for review.")
                    Spacer()
                    if workspace.refreshingReplies { ProgressView().controlSize(.small) }
                    Button("Refresh X", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(workspace.refreshingReplies)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Check X every five minutes while Inkspring is open", isOn: Binding(
                        get: { inbox.monitoring }, set: { value in workspace.perform { try inbox.setMonitoring(value) } }
                    ))
                    if let date = inbox.lastChecked {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .studioSurface()
                StudioTabs(selection: $filter, tabs: ["Inbox", "Ignored"], label: { $0 })
                if rows.isEmpty {
                    ContentUnavailableView("No replies here", systemImage: "bubble.left.and.bubble.right")
                }
                ForEach(rows) { reply in
                    GroupBox(reply.title) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let received = scheduleDate(reply["createdAt"]) {
                                Text(received.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(reply.body).textSelection(.enabled)
                            if let parent = reply.fields["parent"] as? [String: Any], let text = parent["text"] as? String {
                                DisclosureGroup("Conversation context") { Text(text).textSelection(.enabled) }
                            }
                            HStack {
                                Text(reply["status"] == "archived" ? "Ignored" : reply["status"].capitalized)
                                    .foregroundStyle(.secondary)
                                if let url = URL(string: reply["url"]), url.scheme == "https", url.host == "x.com" {
                                    StudioExternalLink("View on X", destination: url)
                                }
                                Spacer()
                                if reply["status"] != "replied" && reply["status"] != "archived" {
                                    Button(reply["draftId"].isEmpty ? "Draft a reply" : "Open draft") { openDraft(reply) }
                                    if reply["status"] == "unread" {
                                        Button("Mark read") { mark(reply, "read") }
                                    }
                                }
                                Button(reply["status"] == "archived" ? "Move to inbox" : "Ignore") {
                                    mark(reply, reply["status"] == "archived" ? "read" : "archived")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if inbox.hasOlder && filter != "Ignored" {
                    Button("Load older replies") { Task { await refresh(older: true) } }
                        .disabled(workspace.refreshingReplies)
                }
            }
            .studioPage()
        }
    }

    private func mark(_ reply: WorkspaceRecord, _ status: String) {
        workspace.perform { try workspace.markReply(reply.id, status: status) }
    }

    private func refresh(older: Bool = false) async {
        do {
            let added = try await inbox.refresh(older: older)
            workspace.notice = "\(added) new replies"
        } catch { workspace.error = error.localizedDescription }
    }
}
