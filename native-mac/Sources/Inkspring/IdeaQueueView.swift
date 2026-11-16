import SwiftUI

struct IdeaQueueView: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let add: () -> Void
    let edit: (WorkspaceRecord) -> Void
    let openDraft: (WorkspaceRecord) -> Void
    let openNewsletter: (WorkspaceRecord) -> Void

    @State private var filter = "draft"
    @State private var selection: IdeaActionRequest?
    @State private var busy = false
    @State private var message: String?

    private var ideas: [WorkspaceRecord] {
        workspace.ideas.filter { matches($0, filter) }
    }

    private func matches(_ idea: WorkspaceRecord, _ tab: String) -> Bool {
        idea["status"] == tab || tab == "picked" && !idea.draftVersions.isEmpty
    }

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    PageHeading(title: "Post ideas", subtitle: "Develop an angle, then turn it into a post when it’s ready.")
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Refresh ideas", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(busy || workspace.project == nil)
                    Button("New idea", systemImage: "plus", action: add)
                        .modifier(PrimaryActionStyle())
                }
                StudioTabs(selection: $filter, tabs: ["draft", "picked"], label: tabLabel,
                           count: { status in workspace.ideas.filter { matches($0, status) }.count })
                if let message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
                if ideas.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "newspaper")
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 15)], alignment: .leading, spacing: 15) {
                        ForEach(ideas) { idea in
                            ideaCard(idea)
                        }
                    }
                }
            }
            .studioPage()
        }
        .sheet(item: $selection) { request in
            IdeaActionSheet(idea: request.idea, action: request.action, workspace: workspace) { drafts in
                let noun = drafts.count == 1 ? "draft" : "drafts"
                workspace.notice = "Created \(drafts.count) \(noun)"
            }
            .studioAppearance(palette)
        }
    }

    private func tabLabel(_ status: String) -> String {
        switch status {
        case "draft": "Open"
        case "picked": "Drafted"
        default: "Skipped"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case "draft": "No open ideas"
        case "picked": "No ideas turned into drafts yet"
        default: "No skipped ideas"
        }
    }

    private func ideaCard(_ idea: WorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(idea.title)
                .font(InkspringTypography.editorial(23, relativeTo: .title2))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(idea.body)
                .font(InkspringTypography.interface(14))
                .lineSpacing(3)
                .lineLimit(5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 3)
            StudioRule()
            switch filter == "picked" ? "picked" : idea["status"] {
            case "draft":
                HStack(spacing: 7) {
                    Button("Draft from idea…", systemImage: "square.and.pencil") {
                        selection = IdeaActionRequest(idea: idea, action: .draft)
                    }
                        .modifier(PrimaryActionStyle())
                        .disabled(["x", "linkedin", "instagram"].allSatisfy { idea.draftVersions[$0] != nil })
                    Button("Give feedback…") { selection = IdeaActionRequest(idea: idea, action: .feedback) }
                    Spacer(minLength: 0)
                    StudioMoreMenu(title: "More actions for \(idea.title)", size: 35) {
                        newsletterButton(idea)
                        Button("Edit idea…") { edit(idea) }
                        Button("Skip idea") { change(idea, to: "skipped") }
                    }
                }
            case "skipped":
                HStack {
                    Button("Restore to Open", systemImage: "arrow.uturn.backward") { change(idea, to: "draft") }
                    Button("Edit idea…") { edit(idea) }
                }
            default:
                linkedDrafts(idea)
                if idea["status"] == "picked" {
                    Button("Reopen idea") { change(idea, to: "draft") }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .studioSurface()
    }

    @ViewBuilder private func linkedDrafts(_ idea: WorkspaceRecord) -> some View {
        let links = idea.fields["versions"] as? [String: String] ?? [:]
        let drafts = links.keys.sorted().compactMap { platform in
            workspace.drafts.first { $0.id == links[platform] }
        }
        if drafts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("No linked drafts in this workspace").font(.caption).foregroundStyle(.secondary)
                newsletterButton(idea)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { draftButtons(drafts); newsletterButton(idea) }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) { draftButtons(drafts) }
                    newsletterButton(idea)
                }
                VStack(alignment: .leading, spacing: 9) {
                    draftButtons(drafts)
                    newsletterButton(idea)
                }
            }
        }
    }

    private func draftButtons(_ drafts: [WorkspaceRecord]) -> some View {
        ForEach(drafts) { draft in
            Button("Open \(platformName(draft["platform"])) draft", systemImage: "arrow.up.right") {
                openDraft(draft)
            }
            .fixedSize()
        }
    }

    private func newsletterButton(_ idea: WorkspaceRecord) -> some View {
        Button("Draft newsletter…", systemImage: "envelope") { openNewsletter(idea) }
            .fixedSize()
    }

    private func change(_ idea: WorkspaceRecord, to state: String) {
        workspace.perform {
            if state == "skipped" { try workspace.trashLibraryItem(idea); return }
            var idea = idea
            idea["status"] = state
            idea["skippedAt"] = state == "skipped" ? WorkspaceRecord.timestamp : ""
            try workspace.save(idea)
        }
    }

    private func refresh() async {
        guard !busy, let project = workspace.project else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await ResearchDiscovery(studio: ContentStudio(workspace: workspace))
                .refreshIdeas(projectID: project.id, withResearch: true)
            guard project.id == workspace.projectID else { return }
            let summary = "\(result.written) new ideas · \(result.open.count) open"
            message = ([summary] + result.warnings).joined(separator: "\n")
            filter = "draft"
        } catch { workspace.error = error.localizedDescription }
    }
}

enum IdeaAction {
    case draft, feedback

    var title: String {
        switch self {
        case .draft: "Draft from idea"
        case .feedback: "Give feedback"
        }
    }
}

private struct IdeaActionRequest: Identifiable {
    let idea: WorkspaceRecord
    let action: IdeaAction
    var id: String { idea.id }
}

struct IdeaActionSheet: View {
    @State var idea: WorkspaceRecord
    let action: IdeaAction
    let workspace: Workspace
    let completed: ([WorkspaceRecord]) -> Void

    @Environment(\.studioPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var notes = ""
    @State private var progress: String?
    @State private var failure: Error?

    private var busy: Bool { progress != nil }
    private var linked: [String: String] { idea.fields["versions"] as? [String: String] ?? [:] }
    private var createLabel: String {
        switch chosen.count {
        case 0: "Create drafts"
        case 1: "Create 1 draft"
        default: "Create \(chosen.count) drafts"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: action.title)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            StudioRule()
            StudioScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    ideaPreview
                    switch action {
                    case .draft: platformChoices
                    case .feedback: feedbackEditor
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .frame(height: action == .draft ? 285 : 320)
            StudioRule()
            footer
        }
        .frame(width: 550)
        .background(palette.canvas)
        .studioAppearance(palette)
        .interactiveDismissDisabled(busy)
    }

    private var ideaPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(idea.title).font(InkspringTypography.editorial(24, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            Text(idea.body).textSelection(.enabled).lineSpacing(3)
            if !idea["mediaPlan"].isEmpty {
                Label(idea["mediaPlan"], systemImage: "photo")
                    .font(.callout).foregroundStyle(palette.muted)
            }
            if let source = XQuoteComposer.source(in: idea) {
                StudioExternalLink("View source on X", destination: source).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .studioSurface()
    }

    private var platformChoices: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Where should Inkspring write a draft?")
                .font(InkspringTypography.interface(15).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("You’ll get one editable draft per platform you select.")
                .foregroundStyle(palette.muted)
            HStack(spacing: 16) {
                ForEach(["x", "linkedin", "instagram"], id: \.self) { platform in
                    if linked[platform] != nil {
                        StudioPlatformLabel(name: platform, title: platformName(platform) + " drafted")
                            .foregroundStyle(palette.muted)
                    } else {
                        Toggle(isOn: Binding(get: { chosen.contains(platform) }, set: { enabled in
                            if enabled { chosen.insert(platform) } else { chosen.remove(platform) }
                        })) {
                            StudioPlatformLabel(name: platform, title: platformName(platform),
                                                iconOffset: platform == "linkedin" ? 1 : 0)
                        }
                        .disabled(busy)
                    }
                }
            }
            .padding(.vertical, 4)
            if XQuoteComposer.source(in: idea) != nil, linked["x"] == nil {
                Button { write(["x"], manualQuote: true) } label: {
                    StudioPlatformLabel(name: "x", title: "Create X quote draft")
                }
                    .disabled(busy)
                    .help("Draft a quote of the cited X post to finish in X.")
            }
        }
    }

    private var feedbackEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("What should change about this idea?")
                .font(InkspringTypography.interface(15).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Inkspring rewrites the idea using your feedback and saves the revision here.")
                .foregroundStyle(palette.muted)
            TextField("Example: Focus on a decision readers can try themselves", text: $notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...5)
                .padding(9)
                .studioSurface(StudioRadius.control)
                .accessibilityLabel("Feedback on this idea")
                .disabled(busy)
            if !idea["notesReply"].isEmpty {
                Label(idea["notesReply"], systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(palette.muted)
            }
            if !idea["previousText"].isEmpty {
                Button("Restore earlier wording") {
                    do {
                        idea = try ContentStudio(workspace: workspace).undoRewrite(idea)
                        failure = nil
                    } catch { failure = error }
                }
                .disabled(busy)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let failure {
                Group {
                    if let failure = failure as? StudioAgentFailure {
                        StudioAgentLabel(agent: failure.agent, title: failure.localizedDescription)
                    } else {
                        Label(failure.localizedDescription, systemImage: "exclamationmark.circle")
                    }
                }
                    .foregroundStyle(palette.danger)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let progress {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                }
            } else if action == .draft {
                Label("Drafts go to Ready to schedule. You choose when they go out.", systemImage: "calendar")
                    .font(.callout).foregroundStyle(palette.muted)
            }
            HStack {
                Button(action == .feedback ? "Done" : "Cancel", role: .cancel) { dismiss() }
                    .disabled(busy)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                switch action {
                case .draft:
                    Button(createLabel) { write(Array(chosen)) }
                        .modifier(PrimaryActionStyle())
                        .disabled(busy || chosen.isEmpty)
                case .feedback:
                    Button("Apply feedback") { applyFeedback() }
                        .modifier(PrimaryActionStyle())
                        .disabled(busy || notes.utf16.count > 4000 || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    private func applyFeedback() {
        Task {
            await run("Revising the idea…") {
                idea = try await ContentStudio(workspace: workspace).rewrite(idea, notes: notes)
                notes = ""
            }
        }
    }

    private func write(_ platforms: [String], manualQuote: Bool = false) {
        Task {
            await run(platforms.count == 1 ? "Writing your draft…" : "Writing your drafts…") {
                let (_, drafts) = try await ContentStudio(workspace: workspace)
                    .pick(idea, platforms: platforms, manualQuote: manualQuote)
                completed(drafts)
                dismiss()
            }
        }
    }

    private func run(_ status: String, work: () async throws -> Void) async {
        guard !busy else { return }
        progress = status
        failure = nil
        defer { progress = nil }
        do { try await work() } catch { failure = error }
    }
}
