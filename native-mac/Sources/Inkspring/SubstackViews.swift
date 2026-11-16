import SwiftUI
import WebKit

struct SubstackConnectionSettings: View {
    let workspace: Workspace
    @State private var signingIn = false
    @State private var disconnecting = false

    private var service: Substack { Substack(workspace: workspace) }

    var body: some View {
        GroupBox("Substack") {
            VStack(alignment: .leading, spacing: 10) {
                SetupHelpLink("Substack setup and troubleshooting", topic: "substack")
                HStack {
                    Text(service.accountName.isEmpty ? "Connect a Substack publication" : service.accountName)
                    Spacer()
                    if workspace.substackBusy { ProgressView().controlSize(.small) }
                    Button(service.accountName.isEmpty ? "Sign in…" : "Sign in again…") { signingIn = true }
                    if !service.accountName.isEmpty { Button("Disconnect…") { disconnecting = true } }
                }
                if !service.publications.isEmpty {
                    StudioLabeledChoice(title: "Publication", selection: Binding(get: { service.selected?.id ?? "" }, set: { id in
                        guard !id.isEmpty else { return }
                        workspace.perform { try service.select(id) }
                    }), options: service.publications.map(\.id),
                       label: { id in service.publications.first(where: { $0.id == id })?.name ?? "Choose a publication" })
                    .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(workspace.substackBusy)
        }
        .sheet(isPresented: $signingIn) { SubstackSignIn(workspace: workspace) }
        .confirmationDialog("Disconnect Substack?", isPresented: $disconnecting) {
            Button("Disconnect", role: .destructive) {
                Task {
                    do { try await service.disconnect() }
                    catch { workspace.error = error.localizedDescription }
                }
            }
        } message: {
            Text("This clears the Inkspring sign-in on this Mac. Your saved newsletters and their Substack links are kept.")
        }
    }
}

private struct SubstackSignIn: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading(title: "Sign in to Substack")
            SubstackLoginPage(storage: workspace.substackSession.storage) { message = $0 }
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Close", role: .cancel) { dismiss() }
                Spacer()
                if workspace.substackBusy { ProgressView().controlSize(.small) }
                Button("Check connection") {
                    Task {
                        do {
                            try await Substack(workspace: workspace).connect()
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(workspace.substackBusy)
            }
        }
        .padding(20)
        .frame(width: 660, height: 680)
        .studioAppearance(palette)
    }
}

private struct SubstackLoginPage: NSViewRepresentable {
    let storage: WKWebsiteDataStore
    let report: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(report: report) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = storage
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://substack.com/sign-in")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let report: (String) -> Void

        init(report: @escaping (String) -> Void) {
            self.report = report
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url.map(SubstackSession.loginAddress) == true ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.request.url.map(SubstackSession.loginAddress) == true { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            report("Substack sign-in couldn’t load. Check your connection and reopen sign-in.")
        }
    }
}

struct NewsletterSubstackControls: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let record: WorkspaceRecord
    let hasEdits: Bool
    let updated: (WorkspaceRecord) -> Void
    let report: (String?) -> Void

    @State private var reviewing = false
    @State private var scheduling = false
    @State private var selectedDate = Date.now.addingTimeInterval(3600)
    @State private var review: SubstackReview?
    @State private var cancelling = false
    @State private var acknowledging = false

    private var service: Substack { Substack(workspace: workspace) }
    private var state: String { record["state"] }

    var body: some View {
        GroupBox("Substack") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(state == "uncertain" ? "Check the last attempt" : state.capitalized)
                    if let date = record["scheduledAt"].isEmpty ? nil : try? Date(record["scheduledAt"], strategy: .iso8601) {
                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if workspace.substackBusy { ProgressView().controlSize(.small) }
                    if let url = Substack.editorURL(record) { StudioExternalLink("Open in Substack", destination: url) }
                }
                if !record["error"].isEmpty { Text(record["error"]).font(.callout).foregroundStyle(.secondary) }
                if let publication = service.selected {
                    Text(publication.name).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Choose a publication in Settings → Connections.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if ["draft", "synced"].contains(state) {
                        Button("Save to Substack") { run { try await service.sync(record.id) } }
                            .disabled(hasEdits || service.selected == nil || record["body"].isEmpty)
                    }
                    if !record["remoteId"].isEmpty {
                        Button("Check status") { run { try await service.refresh(record.id) } }
                            .disabled(hasEdits || service.selected == nil)
                    }
                    if state == "synced" {
                        Button("Review send…") { reviewing = true }
                            .disabled(hasEdits || service.selected == nil ||
                                      record.fields["revision"] as? Int != record.fields["syncedRevision"] as? Int)
                    }
                    if state == "scheduled" {
                        Button("Cancel schedule…") { cancelling = true }
                            .disabled(service.selected == nil)
                    }
                    if state == "uncertain" {
                        Button("Confirm Substack check…") { acknowledging = true }
                    }
                }
                .disabled(workspace.substackBusy)
                if hasEdits { Text("Save your local changes before continuing.").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $reviewing) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeading(title: "Review newsletter send")
                if let review {
                    Text(review.title).font(.headline)
                    LabeledContent("Publication", value: review.publication.name)
                    LabeledContent("Audience", value: Substack.audienceLabel(review.audience))
                    LabeledContent("Email subscribers", value: review.sendEmail ? "Yes" : "No")
                    if let date = review.scheduledAt { LabeledContent("Scheduled", value: date.formatted(date: .long, time: .shortened)) }
                } else {
                    StudioLabeledChoice(title: "Send", selection: $scheduling,
                                        options: [false, true], label: { $0 ? "Schedule" : "Publish now" })
                    if scheduling {
                        StudioDateTimePicker(selection: $selectedDate)
                    }
                }
                HStack {
                    Button("Cancel", role: .cancel) { reviewing = false }
                    Spacer()
                    if workspace.substackBusy { ProgressView().controlSize(.small) }
                    if let review {
                        Button(review.scheduledAt == nil ? "Publish now" : "Schedule newsletter") {
                            reviewing = false
                            run { try await service.commit(review) }
                        }
                        .modifier(PrimaryActionStyle())
                    } else {
                        Button("Review in Inkspring") { prepare() }
                    }
                }
                .disabled(workspace.substackBusy)
            }
            .padding(24)
            .frame(width: 430)
            .studioAppearance(palette)
            .onDisappear { review = nil }
        }
        .confirmationDialog("Cancel the send in Substack?", isPresented: $cancelling) {
            Button("Cancel schedule", role: .destructive) { run { try await service.cancel(record.id) } }
        }
        .confirmationDialog("Did you check the outcome in Substack?", isPresented: $acknowledging) {
            Button("I checked Substack") { run { try await service.acknowledge(record.id) } }
        } message: {
            Text("Check your drafts, scheduled posts, and published posts before continuing.")
        }
    }

    private func prepare() {
        let time = Date(timeIntervalSince1970: floor(selectedDate.timeIntervalSince1970 / 60) * 60)
        Task {
            do { review = try await service.prepare(record.id, at: scheduling ? time : nil) }
            catch {
                reviewing = false
                report(error.localizedDescription)
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> WorkspaceRecord) {
        report(nil)
        Task {
            do { updated(try await operation()) }
            catch {
                if let latest = workspace.records.first(where: { $0.id == record.id }) { updated(latest) }
                report(error.localizedDescription)
            }
        }
    }
}
