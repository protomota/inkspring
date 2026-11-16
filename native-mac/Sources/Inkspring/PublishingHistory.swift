import SwiftUI

struct PublishingHistory: View {
    let workspace: Workspace
    @State private var retry: WorkspaceRecord?

    private var receipts: [WorkspaceRecord] {
        Array(workspace.records.filter { $0.kind == "publication" }.prefix(50))
    }

    var body: some View {
        GroupBox("Publishing history") {
            if receipts.isEmpty {
                Text("No publishing attempts yet.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(receipt.title).font(.headline)
                                Spacer()
                                StudioPlatformLabel(name: receipt["platform"],
                                                    title: platformName(receipt["platform"]) + " · " + receipt["status"].capitalized)
                                    .foregroundStyle(.secondary)
                            }
                            if !receipt["error"].isEmpty { Text(receipt["error"]).foregroundStyle(.secondary) }
                            let steps = receipt.fields["steps"] as? [[String: Any]] ?? []
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                if let raw = step["url"] as? String, let url = URL(string: raw),
                                   url.scheme == "https", url.user == nil, url.password == nil {
                                    StudioExternalLink(steps.count == 1 ? "View post" : "View post \(index + 1)", destination: url)
                                }
                            }
                            if ["uncertain", "publishing"].contains(receipt["status"]) {
                                Button("Allow retry after checking…") { retry = receipt }
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .alert("Did you check the post on the platform?", isPresented: Binding(
            get: { retry != nil }, set: { if !$0 { retry = nil } }
        )) {
            Button("Cancel", role: .cancel) { retry = nil }
            Button("Allow another attempt") {
                if let receipt = retry { workspace.perform { try workspace.allowPublicationRetry(receipt.id) } }
                retry = nil
            }
        } message: {
            Text("Only allow a retry if you checked the connected account and the post is missing. An unconfirmed request can still have gone out.")
        }
    }
}
