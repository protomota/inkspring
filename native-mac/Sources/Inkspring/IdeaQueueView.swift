import SwiftUI
import InkspringSchedule

struct IdeaQueueView: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let add: () -> Void
    let edit: (WorkspaceRecord) -> Void
    let openDraft: (WorkspaceRecord) -> Void
    let openNewsletter: (WorkspaceRecord) -> Void
    let showAction: (WorkspaceRecord, IdeaAction) -> Void

    @State private var filter = "draft"
    @State private var busy = false
    @State private var message: String?

    private let cardSpacing: CGFloat = 20

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
                    if workspace.writingToolsAvailable {
                        Button("Refresh ideas", systemImage: "arrow.clockwise") { Task { await refresh() } }
                            .disabled(busy || workspace.project == nil)
                    }
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: cardSpacing)],
                              alignment: .leading, spacing: cardSpacing) {
                        ForEach(ideas) { idea in
                            ideaCard(idea)
                        }
                    }
                }
            }
            .studioPage()
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
            IdeaExcerpt(title: idea.title, text: idea.body)
            Spacer(minLength: 3)
            StudioRule()
            switch filter == "picked" ? "picked" : idea["status"] {
            case "draft":
                draftActions(idea)
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
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioSurface()
    }

    private func draftActions(_ idea: WorkspaceRecord) -> some View {
        let draft = Button("Draft from idea…", systemImage: "square.and.pencil") {
            showAction(idea, .draft)
        }
        .modifier(PrimaryActionStyle())
        .disabled(["x", "linkedin", "instagram"].allSatisfy { idea.draftVersions[$0] != nil })
        let feedback = Button("Give feedback…") {
            showAction(idea, .feedback)
        }
        let more = StudioMoreMenu(title: "More actions for \(idea.title)", size: 35) {
            newsletterButton(idea)
            Button("Edit idea…") { edit(idea) }
            Button("Skip idea") { change(idea, to: "skipped") }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                if workspace.writingToolsAvailable {
                    draft
                    feedback
                }
                Spacer(minLength: 0)
                more
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if workspace.writingToolsAvailable { draft }
                    Spacer(minLength: 0)
                    more
                }
                if workspace.writingToolsAvailable { feedback }
            }
        }
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

private struct IdeaExcerpt: View {
    @Environment(\.studioPalette) private var palette
    let title: String
    let text: String
    @State private var expanded = false
    @State private var visibleHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            excerpt(limited: !expanded)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { visibleHeight = $0 }
                .background(alignment: .topLeading) {
                    if !expanded {
                        excerpt(limited: false)
                            .hidden()
                            .accessibilityHidden(true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullHeight = $0 }
                    }
                }
            if expanded || fullHeight > visibleHeight + 1 {
                Button(expanded ? "Show less" : "Show more",
                       systemImage: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(InkspringTypography.interface(13).weight(.medium))
                    .foregroundStyle(palette.accent)
                    .padding(.vertical, 4)
                    .accessibilityHint(expanded ? "Collapse this idea" : "Read the complete idea")
            }
        }
    }

    private func excerpt(limited: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(InkspringTypography.editorial(23, relativeTo: .title2))
                .lineLimit(limited ? 2 : nil)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(InkspringTypography.interface(14))
                .lineSpacing(3)
                .lineLimit(limited ? 5 : nil)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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

struct MacSavedIdeaPage: View {
    let idea: WorkspaceRecord
    let close: () -> Void
    let edit: () -> Void
    let draft: () -> Void
    let media: (String) -> Void

    var body: some View {
        StudioEditorPage(title: "Post idea") {
            Button("Done", action: close)
                .keyboardShortcut(.cancelAction)
        } content: {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(idea.title).font(InkspringTypography.editorial(32, relativeTo: .title))
                        .accessibilityAddTraits(.isHeader)
                    Text(idea.body).lineSpacing(3).textSelection(.enabled)
                    Button("Edit idea", systemImage: "pencil", action: edit)
                    if idea["status"] == "draft" {
                        Button("Draft from post idea", systemImage: "square.and.pencil", action: draft)
                            .modifier(PrimaryActionStyle())
                        Menu("Create media draft", systemImage: "photo.on.rectangle") {
                            Button("TikTok video") { media("tiktok") }
                            Button("Instagram post") { media("instagram") }
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .studioPage()
            }
        }
    }
}

struct MacQuickXPage: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let close: () -> Void
    let review: (String) -> Void
    @State private var text = ""

    private var post: String { XThreadText.singlePost(text) }
    private var valid: Bool { XThreadText.validSinglePost(post) }

    var body: some View {
        StudioEditorPage(title: "Quick X post") {
            Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            Button("Review on X") { review(post) }
                .modifier(PrimaryActionStyle()).disabled(!valid)
        } content: {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Your post", text: $text, prompt: Text("Write the one thing you want to say."), axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(4...10)
                        .padding(12).studioSurface()
                        .accessibilityIdentifier("quickX.text")
                    Text("\(XThreadText.weight(post)) / 280").font(.caption).foregroundStyle(palette.muted)
                    StudioProofreadAction(document: .init(title: "", body: text),
                                          unavailable: workspace.agentConnected ? nil : "Connect a writing agent to proofread.",
                                          reviewInSheet: true,
                                          check: { try await ContentStudio.proofread($0, workspace: workspace) }) { text = $0.body }
                }
                .frame(maxWidth: 650, alignment: .leading)
                .studioPage()
            }
        }
    }
}

struct IdeaActionPage: View {
    @State var idea: WorkspaceRecord
    let action: IdeaAction
    let workspace: Workspace
    let close: () -> Void
    let completed: ([WorkspaceRecord]) -> Void

    @Environment(\.studioPalette) private var palette
    @State private var chosen: Set<String> = []
    @State private var xFormat = "post"
    @State private var notes = ""
    @State private var progress: String?
    @State private var failure: Error?

    private var busy: Bool { progress != nil }
    private var linked: [String: String] {
        idea.draftVersions.merging(idea.fields["mobileWritingVersions"] as? [String: String] ?? [:]) { current, _ in current }
    }
    private var createLabel: String {
        switch chosen.count {
        case 0: "Create drafts"
        case 1: "Create 1 draft"
        default: "Create \(chosen.count) drafts"
        }
    }

    var body: some View {
        StudioEditorPage(title: action.title) {
            Button(action == .feedback ? "Done" : "Cancel", role: .cancel, action: close)
                .disabled(busy)
                .keyboardShortcut(.cancelAction)
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
        } content: {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    ideaPreview
                    switch action {
                    case .draft: platformChoices
                    case .feedback: feedbackEditor
                    }
                    feedbackStatus
                }
                .frame(maxWidth: 920, alignment: .leading)
                .studioPage()
            }
        }
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(CompanionLibrary.ideaDraftPlatforms, id: \.self) { platform in
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
            if chosen.contains("x"), linked["x"] == nil {
                Picker("X post type", selection: $xFormat) {
                    ForEach(XPostStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(busy)
                .accessibilityIdentifier("idea.xPostType")
            }
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

    private var feedbackStatus: some View {
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
        }
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
                    .pick(idea, platforms: platforms, manualQuote: manualQuote, xFormat: xFormat)
                completed(drafts)
                close()
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
