import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct R2Settings: View {
    let workspace: Workspace
    @State private var account = ""
    @State private var bucket = ""
    @State private var jurisdiction = "default"
    @State private var key = ""
    @State private var secret = ""
    @State private var current: R2Configuration?
    @State private var busy = false

    private var media: [WorkspaceRecord] {
        guard let current else { return [] }
        return Array(workspace.records.filter {
            $0.kind == "r2-object" && $0["accountId"] == current.accountId && $0["bucket"] == current.bucket
                && ($0["jurisdiction"].isEmpty ? "default" : $0["jurisdiction"]) == current.jurisdiction
        }.prefix(10))
    }

    var body: some View {
        GroupBox("Instagram media hosting") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use a private Cloudflare R2 bucket to publish attached Instagram images.")
                SetupHelpLink("Instagram media hosting help", topic: "media-hosting")
                TextField("Cloudflare account ID", text: $account).studioInput()
                TextField("R2 bucket", text: $bucket).studioInput()
                let regions = ["default": "Default", "eu": "European Union", "us": "United States", "fedramp": "FedRAMP"]
                StudioLabeledChoice(title: "Jurisdiction", selection: $jurisdiction,
                                    options: ["default", "eu", "us", "fedramp"], label: { regions[$0] ?? $0 })
                SecureField("S3 Access Key ID", text: $key).studioInput()
                SecureField("S3 Secret Access Key", text: $secret).studioInput()
                HStack {
                    Button("Save R2 connection", action: save)
                    if current != nil {
                        Button("Test connection") { Task { await test() } }
                        Button("Disconnect") {
                            workspace.perform { try R2Profile.remove(); current = nil }
                        }
                    }
                    Spacer()
                    StudioExternalLink("Cloudflare R2", destination: URL(string: "https://dash.cloudflare.com/?to=/:account/r2/overview")!)
                }
                if current != nil {
                    Button("Upload image or video…", systemImage: "square.and.arrow.up", action: upload)
                    ForEach(media) { item in
                        HStack {
                            Text(item["name"]).lineLimit(1)
                            Spacer()
                            Button("Copy temporary link") {
                                workspace.perform {
                                    copy(try client().link(item["key"]).absoluteString)
                                    workspace.notice = "Two-hour media link copied"
                                }
                            }
                        }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            workspace.perform {
                let saved = try R2Profile.saved()?.configuration
                current = saved
                if let saved { account = saved.accountId; bucket = saved.bucket; jurisdiction = saved.jurisdiction }
            }
        }
    }

    private func save() {
        workspace.perform {
            let config = R2Configuration(accountId: account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                                         bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines), jurisdiction: jurisdiction)
            let existing = try R2Profile.saved()
            let profile = R2Profile(
                configuration: config,
                accessKeyId: key.isEmpty && existing?.configuration == config ? existing?.accessKeyId ?? "" : key.trimmingCharacters(in: .whitespacesAndNewlines),
                secretAccessKey: secret.isEmpty && existing?.configuration == config ? existing?.secretAccessKey ?? "" : secret.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try profile.save()
            current = config
            key = ""
            secret = ""
            workspace.notice = "R2 connection saved"
        }
    }

    private func client() throws -> R2Client {
        guard let profile = try R2Profile.saved() else { throw WorkspaceError("Save the R2 connection first.") }
        return R2Client(profile: profile)
    }

    private func test() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await client().test(); workspace.notice = "R2 read, write, and cleanup worked" }
        catch { workspace.error = error.localizedDescription }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .mpeg4Movie, .quickTimeMovie] + [UTType(filenameExtension: "webm")].compactMap { $0 }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                let client = try client()
                let media = try await client.upload(file)
                try workspace.saveR2Media(media, config: client.profile.configuration)
                workspace.notice = "Media uploaded to R2"
            } catch { workspace.error = error.localizedDescription }
        }
    }
}
