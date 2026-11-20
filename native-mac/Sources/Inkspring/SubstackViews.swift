import SwiftUI
import WebKit

struct SubstackConnectionSettings: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    @State private var signingIn = false
    @State private var disconnecting = false
    @State private var connection: Connection = .unchecked
    @State private var checkRequest = 0

    private enum Connection {
        case unchecked, checking, connected(Date), failed(String)
    }

    private var service: Substack { Substack(workspace: workspace) }

    var body: some View {
        GroupBox("Substack") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    GridRow {
                        connectionStatus
                            .frame(maxWidth: .infinity, alignment: .leading)
                        connectionActions
                            .gridColumnAlignment(.trailing)
                    }
                    GridRow {
                        publicationPicker
                        SetupHelpLink("Substack setup and troubleshooting", topic: "substack")
                    }
                }
                if case let .failed(message) = connection {
                    Text(message).font(.callout).foregroundStyle(palette.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(workspace.substackBusy)
        }
        .task(id: checkRequest) { await verifyConnection() }
        .onChange(of: service.selected?.id) { checkRequest += 1 }
        .sheet(isPresented: $signingIn) {
            SubstackSignIn(workspace: workspace) { connection = .connected(.now) }
        }
        .confirmationDialog("Disconnect Substack?", isPresented: $disconnecting) {
            Button("Disconnect", role: .destructive) {
                Task {
                    do {
                        try await service.disconnect()
                        connection = .unchecked
                    }
                    catch { workspace.error = error.localizedDescription }
                }
            }
        } message: {
            Text("This clears the Inkspring sign-in on this Mac. Your saved newsletters and their Substack links are kept.")
        }
    }

    private var publicationPicker: some View {
        HStack(spacing: 10) {
            if !service.publications.isEmpty {
                Text("Publication").foregroundStyle(palette.muted)
                StudioChoicePicker(title: "Publication", selection: Binding(get: { service.selected?.id ?? "" }, set: { id in
                    workspace.perform { try service.select(id) }
                }), options: service.publications.map(\.id),
                   label: { id in service.publications.first(where: { $0.id == id })?.name ?? "Choose a publication" })
            }
        }
    }

    private var connectionActions: some View {
        HStack(spacing: 8) {
            if !service.accountName.isEmpty {
                Button("Test connection") { checkRequest += 1 }
                    .disabled(isChecking)
            }
            Button(service.accountName.isEmpty ? "Sign in…" : "Sign in again…") { signingIn = true }
            if !service.accountName.isEmpty { Button("Disconnect…") { disconnecting = true } }
        }
    }

    private var isChecking: Bool {
        if case .checking = connection { return true }
        return false
    }

    @ViewBuilder private var connectionStatus: some View {
        if service.accountName.isEmpty {
            Label("Not connected", systemImage: "minus.circle").foregroundStyle(palette.muted)
        } else {
            switch connection {
            case .unchecked:
                Text("Connection not verified").foregroundStyle(palette.muted)
            case .checking:
                ProgressView("Checking connection…").controlSize(.small)
            case .connected(let checkedAt):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Connected as \(service.accountName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(palette.success)
                    Text("Verified at \(checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(palette.muted)
                }
            case .failed:
                Label("Connection needs attention", systemImage: "exclamationmark.circle").foregroundStyle(palette.danger)
            }
        }
    }

    private func verifyConnection() async {
        guard !service.accountName.isEmpty else {
            connection = .unchecked
            return
        }
        connection = .checking
        do {
            try await service.checkConnection()
            if !Task.isCancelled { connection = .connected(.now) }
        } catch {
            if !Task.isCancelled { connection = .failed(error.localizedDescription) }
        }
    }
}

private struct SubstackSignIn: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let connected: () -> Void
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
                            connected()
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
    let workspace: Workspace
    let record: WorkspaceRecord
    let hasEdits: Bool
    let updated: (WorkspaceRecord) -> Void
    let report: (String?) -> Void

    let reviewSend: (Bool) -> Void

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
                        Button("Review & publish…") { reviewSend(false) }
                            .disabled(hasEdits)
                        Button("Choose a time…") { reviewSend(true) }
                            .disabled(hasEdits)
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
        .confirmationDialog("Cancel the send in Substack?", isPresented: $cancelling) {
            Button("Cancel schedule", role: .destructive) { run { try await service.cancel(record.id) } }
        }
        .confirmationDialog("Did you check the outcome in Substack?", isPresented: $acknowledging) {
            Button("I checked Substack") { run { try await service.acknowledge(record.id) } }
        } message: {
            Text("Check your drafts, scheduled posts, and published posts before continuing.")
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

struct NewsletterSendPage: View {
    @Environment(\.studioPalette) private var palette
    let record: WorkspaceRecord
    let workspace: Workspace
    let scheduling: Bool
    let close: () -> Void
    let completed: (WorkspaceRecord) -> Void
    @State private var date = Date.now.addingTimeInterval(3600)
    @State private var review: SubstackReview?
    @State private var working = false
    @State private var confirmingCancellation = false
    @State private var message: String?

    private var service: Substack { Substack(workspace: workspace) }
    private var item: WorkspaceRecord? { workspace.records.first { $0.id == record.id && $0.kind == "newsletter" } }
    private var isScheduled: Bool { item?["state"] == "scheduled" }
    private var busy: Bool { working || workspace.substackBusy }
    private var canSend: Bool { item.map { ["draft", "synced"].contains($0["state"]) } ?? false }
    private var hasText: Bool { item.map { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
    private var needsSync: Bool {
        guard let item else { return false }
        return item["remoteId"].isEmpty || item["state"] != "synced"
            || item.fields["syncedRevision"] as? Int != item.fields["revision"] as? Int
    }

    var body: some View {
        StudioEditorPage(title: scheduling ? "Choose a newsletter time" : "Review newsletter send") {
            Button("Back", systemImage: "chevron.left", action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            if let review {
                Button(review.scheduledAt == nil ? "Publish newsletter" : "Schedule newsletter") {
                    self.review = nil
                    run {
                        completed(try await service.commit(review))
                        close()
                    }
                }
                .modifier(PrimaryActionStyle())
                .disabled(busy)
            } else if canSend, service.selected != nil {
                if needsSync {
                    Button("Save to Substack") { run { _ = try await service.sync(record.id) } }
                        .modifier(PrimaryActionStyle())
                        .disabled(!hasText || busy)
                } else {
                    Button(scheduling ? "Review schedule" : "Review newsletter") { prepare() }
                        .modifier(PrimaryActionStyle())
                        .disabled(busy)
                }
            }
        } content: {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item?.title ?? record.title).font(InkspringTypography.editorial(24))
                    if let review {
                        LabeledContent("Publication", value: review.publication.name)
                        LabeledContent("Audience", value: Substack.audienceLabel(review.audience))
                        LabeledContent("Email subscribers", value: review.sendEmail ? "Yes" : "No")
                        if let scheduled = review.scheduledAt {
                            LabeledContent("Scheduled", value: scheduled.formatted(date: .long, time: .shortened))
                        }
                        Button(scheduling ? "Change time" : "Back to details") { self.review = nil }
                    } else {
                        if let publication = service.selected {
                            LabeledContent("Publication", value: publication.name)
                        } else {
                            Text("Connect Substack and choose a publication in Settings → Connections.")
                                .foregroundStyle(palette.muted)
                        }
                        if scheduling {
                            StudioDateTimePicker(selection: $date, includesFiveMinuteShortcut: true)
                                .disabled(busy || isScheduled)
                        }
                        if isScheduled {
                            Text("Cancel the current schedule before choosing a different time.")
                                .foregroundStyle(palette.muted)
                            Button("Cancel current schedule…", role: .destructive) { confirmingCancellation = true }
                                .disabled(busy || service.selected == nil)
                        } else if !canSend {
                            Text("Check the newsletter’s status in Substack before continuing.")
                                .foregroundStyle(palette.muted)
                        } else if !hasText {
                            Text("Add newsletter text before sending.").foregroundStyle(palette.muted)
                        } else if needsSync, service.selected != nil {
                            Text("Save the draft to Substack before reviewing the send.")
                                .foregroundStyle(palette.muted)
                        }
                    }
                    if let message { Text(message).foregroundStyle(palette.danger).textSelection(.enabled) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .studioPage()
            }
        }
        .onAppear {
            if let date = scheduleDate(record["scheduledAt"]) { self.date = date }
        }
        .confirmationDialog("Cancel the current newsletter schedule?", isPresented: $confirmingCancellation) {
            Button("Cancel schedule", role: .destructive) { run { _ = try await service.cancel(record.id) } }
        } message: {
            Text("The newsletter stays saved as a draft on Substack. Choose and confirm a new time to reschedule it.")
        }
    }

    private func prepare() {
        let minute = PostScheduling.startOfMinute(date)
        run { review = try await service.prepare(record.id, at: scheduling ? minute : nil) }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}
