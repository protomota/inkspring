import AppKit
import AVKit
import SwiftUI
import WebKit

enum WorkspacePage: String, CaseIterable, Identifiable {
    case ideas = "Post ideas", schedule = "Schedule", workspace = "Workspace"
    case research = "Research", replies = "Replies", analytics = "Analytics"
    case newsletters = "Newsletters", studio = "Writing studio", library = "Library"
    case connections = "Connections", trash = "Trash", about = "About Inkspring", settings = "Settings"

    var id: Self { self }

    var icon: String {
        switch self {
        case .ideas: "newspaper"
        case .schedule: "calendar.badge.clock"
        case .workspace: "folder"
        case .research: "antenna.radiowaves.left.and.right"
        case .replies: "bubble.left.and.bubble.right"
        case .analytics: "chart.bar.xaxis"
        case .newsletters: "envelope"
        case .studio: "pencil.and.outline"
        case .library: "square.stack"
        case .connections: "link"
        case .trash: "trash"
        case .about: "info.circle"
        case .settings: "gearshape"
        }
    }
}

struct WorkspaceWindow: View {
    @Bindable var workspace: Workspace
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(InkspringReview.activityKey) private var completedWriting = 0
    @State private var page: WorkspacePage = .workspace
    @State private var editor: WorkspaceRecord?
    @State private var newsletterIdea: WorkspaceRecord?
    @State private var studioDraft: WorkspaceRecord?
    @State private var scheduleFocus: String?
    @State private var pendingNavigation: (() -> Void)?
    @State private var studioDirty = false
    @State private var showsSidebar = true
    @State private var previewExpanded = false
    @State private var showsAgentChat = false
    @State private var agentChat = StudioAgentChat()
    @State private var settingsSection = "Appearance"
    @State private var librarySearchRequest = 0
    @State private var showsSupportReminder = false

    private var theme: StudioTheme { StudioTheme(preference: workspace.settings[StudioTheme.preferenceKey]) }
    private var palette: StudioPalette { StudioPalette(theme: theme.resolve(for: systemScheme)) }
    private var canShowSupportReminder: Bool {
        scenePhase == .active && !DailyBackup.usesTestWorkspace &&
        completedWriting >= InkspringReview.milestone &&
        workspace.startupError == nil && !workspace.substackBusy &&
        [.workspace, .library, .ideas, .newsletters].contains(page) &&
        editor == nil && !studioDirty && !previewExpanded && !showsAgentChat &&
        pendingNavigation == nil && workspace.error == nil && workspace.scheduleReminderDraftID == nil
    }

    var body: some View {
        Group {
            if let message = workspace.startupError {
                ContentUnavailableView("Couldn’t open your studio", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            } else {
                HStack(spacing: 0) {
                    if showsSidebar && !previewExpanded {
                        sidebar.frame(width: 244)
                        StudioRule(axis: .vertical)
                    }
                    VStack(spacing: 0) {
                        if !previewExpanded { workspaceBar }
                        content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(palette.canvas)
        .studioAppearance(palette)
        .preferredColorScheme(theme == .system ? nil : palette.colorScheme)
        .modifier(InkspringRatingPrompt(isIdle: [.workspace, .library, .ideas, .newsletters].contains(page)
                                         && editor == nil && pendingNavigation == nil && workspace.error == nil))
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .navigation) { leadingToolbar }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { leadingToolbar }
            }
            if previewExpanded {
                ToolbarItem(placement: .primaryAction) {
                    Button("New draft", systemImage: "square.and.pencil") { navigate { newDraft() } }
                        .keyboardShortcut("n")
                }
            }
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { quickControls }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { quickControls }
            }
        }
        .onChange(of: page) { _, _ in setPreviewExpanded(false) }
        .task(id: canShowSupportReminder) {
            guard canShowSupportReminder else { return }
            // Let existing sheets and the App Store review prompt take precedence.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard canShowSupportReminder, NSApp.isActive,
                  let window = NSApp.keyWindow, !window.isSheet, window.attachedSheet == nil,
                  InkspringSupportReminder.claim() else { return }
            showsSupportReminder = true
        }
        .sheet(isPresented: $showsSupportReminder) {
            InkspringSupportSheet(isReminder: true)
                .studioAppearance(palette)
        }
        .onChange(of: workspace.projectID) { _, _ in
            setPreviewExpanded(false)
            agentChat = StudioAgentChat()
        }
        .onChange(of: workspace.scheduleReminderDraftID, initial: true) { _, id in
            guard let id else { return }
            workspace.scheduleReminderDraftID = nil
            navigate {
                scheduleFocus = id
                page = .schedule
            }
        }
        .sheet(item: $editor, onDismiss: { newsletterIdea = nil }) { record in
            RecordEditor(record: record, workspace: workspace, newsletterIdea: newsletterIdea) { saved in
                if saved.kind == "project" {
                    workspace.selectProject(saved.id)
                    page = .workspace
                }
            }
            .background(palette.canvas)
            .studioAppearance(palette)
        }
        .sheet(isPresented: $showsAgentChat) {
            StudioAgentChatView(workspace: workspace, chat: agentChat) {
                showsAgentChat = false
                navigate {
                    settingsSection = "AI agents"
                    page = .settings
                }
            }
            .background(palette.canvas)
            .studioAppearance(palette)
        }
        .alert("Inkspring", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK", role: .cancel) { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
        .confirmationDialog("Keep your latest changes?", isPresented: Binding(
            get: { pendingNavigation != nil }, set: { if !$0 { pendingNavigation = nil } }
        ), titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) {
                let action = pendingNavigation
                pendingNavigation = nil
                studioDirty = false
                action?()
            }
            Button("Keep editing", role: .cancel) { pendingNavigation = nil }
        } message: {
            Text("This draft has unsaved changes.")
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice = workspace.notice {
                Button {
                    workspace.notice = nil
                } label: {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .padding(12)
                        .modifier(StatusGlass())
                }
                .buttonStyle(.plain)
                .padding(18)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled { workspace.notice = nil }
                }
            }
        }
    }

    private var sidebarToggle: some View {
        let title = previewExpanded ? "Exit full-window preview" : showsSidebar ? "Hide sidebar" : "Show sidebar"
        return Button(title, systemImage: "sidebar.left") {
            if previewExpanded { setPreviewExpanded(false) }
            else { showsSidebar.toggle() }
        }
        .buttonStyle(StudioIconButtonStyle())
        .labelStyle(.iconOnly)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(title)
    }

    private var leadingToolbar: some View {
        HStack(spacing: 12) {
            sidebarToggle
            Text("Inkspring")
                .font(InkspringTypography.interface(12).weight(.bold))
                .foregroundStyle(palette.text)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var quickControls: some View {
        HStack(spacing: 12) {
            Button("Workspace", systemImage: "square.grid.2x2") {
                navigate { page = .workspace; setPreviewExpanded(false) }
            }
            .help("Workspace")
            Button("Search drafts", systemImage: "magnifyingglass") {
                navigate {
                    page = .library
                    setPreviewExpanded(false)
                    librarySearchRequest += 1
                }
            }
            .disabled(workspace.project == nil)
            .help("Search drafts")
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Settings", systemImage: "gearshape") {
                navigate { page = .settings }
            }
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(StudioIconButtonStyle())
        .foregroundStyle(palette.muted)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(spacing: 8) {
                sidebarDraftButton("New draft", symbol: "plus", prominent: true) { navigate { newDraft() } }
                    .keyboardShortcut("n")
                sidebarDraftButton("Reply to a post", symbol: "arrowshape.turn.up.left") { navigate { newDraft(reply: true) } }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 15)
            ForEach(WorkspacePage.allCases.filter { $0 != .about && $0 != .settings }) { item in
                navButton(item)
            }
            HStack {
                Text("Projects").font(InkspringTypography.interface(12)).foregroundStyle(palette.muted)
                Spacer()
                Button { navigate { editor = .new("project") } } label: { Image(systemName: "plus") }
                    .buttonStyle(StudioIconButtonStyle())
                    .accessibilityLabel("Create a project")
                    .help("New project")
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 4)
            StudioScrollView(track: palette.sidebar) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.projects) { project in
                        Button {
                            navigate {
                                workspace.selectProject(project.id)
                                studioDraft = nil
                                page = .workspace
                            }
                        } label: {
                            HStack(spacing: 10) {
                                ProjectMark(project: project, size: 12)
                                Text(project.title).lineLimit(1)
                                Spacer()
                                if project.fields["sample"] as? Bool == true {
                                    Text("Sample").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                        }
                        .foregroundStyle(project.id == workspace.projectID ? palette.text : palette.muted)
                        .buttonStyle(StudioRowStyle(selected: project.id == workspace.projectID))
                        .accessibilityAddTraits(project.id == workspace.projectID ? .isSelected : [])
                    }
                }
            }
            .frame(minHeight: 32, maxHeight: .infinity)
            StudioRule().padding(.vertical, 6)
            navButton(.about)
            navButton(.settings).keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 16)
        .background(palette.sidebar)
    }

    private func sidebarDraftButton(_ title: String, symbol: String, prominent: Bool = false,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
            }
        }
        .buttonStyle(StudioActionStyle(prominent: prominent, fillsWidth: true))
    }

    private func navButton(_ item: WorkspacePage) -> some View {
        Button {
            if page != item {
                navigate {
                    if item == .studio, studioDraft == nil { newDraft() }
                    else { page = item }
                }
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon).frame(width: 18)
                    .foregroundStyle(palette.iconAccent)
                Text(item.rawValue)
                Spacer()
                if let count = count(for: item), count > 0 {
                    Text(count.formatted()).font(InkspringTypography.interface(11).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.line))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .foregroundStyle(page == item ? palette.text : palette.muted)
        }
        .buttonStyle(StudioRowStyle(selected: page == item, indicator: true))
        .accessibilityAddTraits(page == item ? .isSelected : [])
    }

    private func count(for item: WorkspacePage) -> Int? {
        switch item {
        case .ideas: workspace.ideas.filter { $0["status"] == "draft" }.count
        case .schedule: workspace.records.filter { ScheduleListing.section(for: $0) == .scheduled }.count
        case .library: workspace.drafts.count
        case .trash: workspace.trashedRecords.count
        case .replies: workspace.records.filter { $0.kind == "reply-inbox" && $0["status"] == "unread" }.count
        default: nil
        }
    }

    private var workspaceTitle: String {
        if [.settings, .connections, .analytics, .about, .schedule].contains(page) { return "Your studio" }
        return workspace.project?.title ?? "Your workspace"
    }

    private var workspaceBar: some View {
        HStack(spacing: 9) {
            Text(workspaceTitle).fontWeight(.medium).foregroundStyle(palette.text)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            Text(page == .workspace ? "Posts" : page.rawValue)
            Spacer()
            if !showsSidebar {
                Button("New draft", systemImage: "plus") { navigate { newDraft() } }
                    .keyboardShortcut("n")
            }
            Button("Ask my agent", systemImage: "bubble.left.and.text.bubble.right") { showsAgentChat = true }
                .disabled(workspace.project == nil)
                .foregroundStyle(palette.text)
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        .font(InkspringTypography.interface(12))
        .foregroundStyle(palette.muted)
        .lineLimit(1)
        .frame(height: 47)
        .padding(.horizontal, 36)
        .background(palette.canvas)
        .overlay(alignment: .bottom) { StudioRule() }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .workspace, .library:
            PostBrowser(workspace: workspace, library: page == .library, edit: open,
                        showSchedule: showSchedule,
                        editProject: { editor = workspace.project ?? .new("project") },
                        compose: { navigate { newDraft() } }, expanded: previewExpanded,
                        searchRequest: page == .library ? librarySearchRequest : 0,
                        togglePreview: { setPreviewExpanded(!previewExpanded) })
                .id("\(workspace.projectID)-\(page.rawValue)")
        case .ideas:
            IdeaQueueView(workspace: workspace, add: { add("idea") }, edit: open, openDraft: open,
                          openNewsletter: draftNewsletter)
                .id(workspace.projectID)
        case .research:
            ResearchView(workspace: workspace, add: { add("source") }, edit: open,
                         editProject: { editor = workspace.project }, openDraft: open)
                .id(workspace.projectID)
        case .newsletters:
            RecordCollection(title: "Newsletters", symbol: page.icon, rows: workspace.items("newsletter"),
                             workspace: workspace, action: "New newsletter", add: { add("newsletter") }, edit: open)
        case .schedule:
            ScheduleView(workspace: workspace, open: open, focusDraftID: $scheduleFocus)
        case .replies:
            RepliesView(workspace: workspace, openDraft: draftReply)
        case .analytics:
            AnalyticsView(workspace: workspace, openConnections: { page = .connections })
        case .studio:
            if let studioDraft {
                DraftStudio(initial: studioDraft, workspace: workspace, onDirty: { studioDirty = $0 },
                            showSchedule: { draft in
                                studioDirty = false
                                showSchedule(draft)
                            })
                    .id(studioDraft.id)
            }
        case .settings:
            WorkspaceSettings(workspace: workspace, initialSection: settingsSection)
                .id(settingsSection)
        case .connections:
            WorkspaceConnections(workspace: workspace)
        case .trash:
            WorkspaceTrash(workspace: workspace)
        case .about:
            AboutInkspring()
        }
    }

    private func add(_ kind: String) {
        editor = workspace.project == nil ? .new("project") : .new(kind, projectID: workspace.projectID)
    }

    private func newDraft(reply: Bool = false) {
        guard let project = workspace.project else { editor = .new("project"); return }
        var draft = WorkspaceRecord.new("draft", projectID: project.id)
        if reply { draft["format"] = "reply" }
        open(draft)
    }

    private func draftReply(_ item: WorkspaceRecord) {
        guard workspace.project != nil else { editor = .new("project"); return }
        workspace.perform {
            let draft = try workspace.makeReplyDraft(item.id, projectID: workspace.projectID)
            if draft.projectID != workspace.projectID { workspace.selectProject(draft.projectID) }
            open(draft)
        }
    }

    private func showSchedule(_ draft: WorkspaceRecord) {
        scheduleFocus = draft.id
        page = .schedule
    }

    private func setPreviewExpanded(_ expanded: Bool) {
        previewExpanded = expanded
    }

    private func draftNewsletter(from idea: WorkspaceRecord) {
        var draft = WorkspaceRecord.new("newsletter", projectID: idea.projectID)
        draft["title"] = String(idea["topic"].prefix(300))
        newsletterIdea = idea
        open(draft)
    }

    private func open(_ record: WorkspaceRecord) {
        if ["draft", "newsletter"].contains(record.kind), record.projectID != workspace.projectID,
           workspace.projects.contains(where: { $0.id == record.projectID }) {
            workspace.selectProject(record.projectID)
        }
        if record.kind == "draft" {
            studioDraft = record
            page = .studio
        } else {
            editor = record
        }
    }

    private func navigate(_ action: @escaping () -> Void) {
        if studioDirty { pendingNavigation = action } else { action() }
    }
}

struct PageHeading: View {
    let title: String
    var subtitle: String? = nil
    var titleSize: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(InkspringTypography.editorial(titleSize, relativeTo: .largeTitle))
                .tracking(-titleSize / 35)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(InkspringTypography.interface(14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProjectMark: View {
    @Environment(\.studioPalette) private var palette
    let project: WorkspaceRecord
    var size: CGFloat

    var body: some View {
        let symbols = ["folder": "folder.fill", "studio": "paintpalette.fill", "ink": "drop.fill", "book": "book.fill",
                       "video": "video.fill", "idea": "lightbulb.fill", "flask": "flask.fill", "code": "chevron.left.forwardslash.chevron.right",
                       "globe": "globe", "mic": "mic.fill", "waveform": "waveform"]
        Image(systemName: symbols[project["icon"]] ?? "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(palette.project(project["color"]))
            .frame(width: size + 4, height: size + 4)
            .accessibilityHidden(true)
    }
}

struct RecordCard: View {
    let record: WorkspaceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !record["platform"].isEmpty {
                StudioPlatformLabel(name: record["platform"], title: platformName(record["platform"]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.title).font(.headline)
            if !record.body.isEmpty {
                Text(record.body)
                    .font(InkspringTypography.editorial(17))
                    .lineLimit(5)
                    .foregroundStyle(.secondary)
            }
            if record.fields["sample"] as? Bool == true {
                Text("Sample").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .studioSurface()
    }
}

func platformName(_ value: String) -> String {
    ["x": "X", "linkedin": "LinkedIn", "instagram": "Instagram", "reddit": "Reddit", "tiktok": "TikTok"][value]
        ?? value.capitalized
}

struct RecordCollection: View {
    let title: String
    let symbol: String
    let rows: [WorkspaceRecord]
    let workspace: Workspace
    let action: String?
    let add: () -> Void
    let edit: (WorkspaceRecord) -> Void
    @State private var search = ""

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    PageHeading(title: title == "Newsletters" ? "Room for the whole thought." : title,
                                subtitle: title == "Newsletters" ? "Write Markdown, preview the result, and review before sending." : nil)
                    Spacer()
                    if let action { Button(action, systemImage: "plus", action: add).modifier(PrimaryActionStyle()) }
                }
                if rows.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: symbol)
                } else {
                    StudioSearchField(title: "Search \(title.lowercased())", text: $search)
                        .frame(maxWidth: 300)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 13)], alignment: .leading, spacing: 13) {
                        ForEach(rows.filter(matches)) { record in
                            Button { edit(record) } label: { RecordCard(record: record) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .studioPage()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ item: WorkspaceRecord) -> Bool {
        search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.body.localizedCaseInsensitiveContains(search)
    }
}

enum PostBrowserFilter: String, CaseIterable {
    case all = "All drafts"
    case working = "In progress"
    case ideas = "Post ideas"
    case scheduling = "Ready to schedule"
    case sharing = "Ready to share"

    func matches(_ record: WorkspaceRecord, platform: SocialPlatform?, search: String, library: Bool) -> Bool {
        guard record.kind == (self == .ideas ? "idea" : "draft") else { return false }
        if let platform {
            let suggestions = record.fields["suggestedPlatforms"] as? [String] ?? []
            let platforms = self == .ideas ? (suggestions.isEmpty ? ["x"] : suggestions) : [record["platform"]]
            guard platforms.contains(platform.rawValue) else { return false }
        }
        let matchingStatus = switch self {
        case .all: true
        case .working: record["status"] == "draft" && (library || record.schedule.isEmpty)
        case .ideas: record["status"] == "draft"
        case .scheduling: ScheduleListing.section(for: record) == .ready
        case .sharing: record["status"] == "ready"
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchingStatus && (query.isEmpty || [record.title, record.body, platformName(record["platform"])]
            .contains { $0.localizedCaseInsensitiveContains(query) })
    }
}

struct PostBrowser: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let library: Bool
    let edit: (WorkspaceRecord) -> Void
    let showSchedule: (WorkspaceRecord) -> Void
    let editProject: () -> Void
    let compose: () -> Void
    let expanded: Bool
    let searchRequest: Int
    let togglePreview: () -> Void
    @State private var selection: String?
    @State private var filter = PostBrowserFilter.all
    @State private var platform: SocialPlatform?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var tabs: [PostBrowserFilter] {
        library ? [.all, .working, .sharing] : [.ideas, .all, .working, .scheduling]
    }

    private func records(for filter: PostBrowserFilter, query: String = "") -> [WorkspaceRecord] {
        (filter == .ideas ? workspace.ideas : workspace.drafts).filter {
            filter.matches($0, platform: platform, search: query, library: library)
        }
    }

    var body: some View {
        if workspace.project == nil {
            ContentUnavailableView {
                Label("Create a project to get started", systemImage: "folder")
            } actions: {
                Button("Create a project", systemImage: "plus", action: editProject)
                    .modifier(PrimaryActionStyle())
            }
        } else {
            reader
        }
    }

    private var reader: some View {
        let rows = records(for: filter, query: search)
            .sorted { ($0["updatedAt"], $0.id) > ($1["updatedAt"], $1.id) }
        let selected = rows.first { $0.id == selection }
            ?? (filter == .all && !library ? rows.first { PostBrowserFilter.working.matches($0, platform: nil, search: "", library: false) } : nil)
            ?? rows.first
        return VStack(alignment: .leading, spacing: 0) {
            if !expanded {
                HStack(spacing: 12) {
                    if !library, let project = workspace.project {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            ProjectMark(project: project, size: 17)
                                .padding(6)
                                .studioSurface(StudioRadius.control)
                                .alignmentGuide(.firstTextBaseline) { dimensions in
                                    dimensions[VerticalAlignment.center] + InkspringTypography.editorialCapHeight(32) / 2
                                }
                            PageHeading(title: project.title, titleSize: 32).lineLimit(2)
                        }
                        Button("Edit project", action: editProject)
                    } else {
                        PageHeading(title: "Library", titleSize: 32)
                    }
                    Spacer(minLength: 8)
                    Button("New draft", systemImage: "square.and.pencil", action: compose)
                        .modifier(PrimaryActionStyle())
                }
                .padding(.bottom, 18)
                StudioTabs(selection: $filter, tabs: tabs, label: { $0.rawValue }, count: { records(for: $0).count })
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if !expanded {
                        postList(rows, selected: selected?.id)
                            .padding(.trailing, 16)
                            .frame(width: min(max(190, geometry.size.width * 0.29), 330))
                            .frame(maxHeight: .infinity)
                        StudioRule(axis: .vertical)
                    }
                    Group {
                        if let selected {
                            PostPreview(record: selected, workspace: workspace, edit: edit, showSchedule: showSchedule,
                                        expanded: expanded, togglePreview: togglePreview)
                                .id(selected.id)
                        } else {
                            VStack {
                                ContentUnavailableView("No matching posts", systemImage: "doc.text")
                                if expanded {
                                    Button("Exit full-window preview", action: togglePreview).keyboardShortcut(.cancelAction)
                                } else if filter == .all && search.isEmpty && platform == nil {
                                    Button("Write a draft", systemImage: "plus", action: compose)
                                        .modifier(PrimaryActionStyle())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, expanded ? 0 : 36)
        .padding(.vertical, expanded ? 0 : 26)
        .onChange(of: filter) { _, _ in selection = nil; search = "" }
        .onChange(of: searchRequest, initial: true) { _, request in
            if request > 0 {
                Task { @MainActor in
                    await Task.yield()
                    searchFocused = true
                }
            }
        }
        .onAppear {
            if !library && workspace.drafts.isEmpty && !workspace.ideas.isEmpty { filter = .ideas }
        }
    }

    private func postList(_ rows: [WorkspaceRecord], selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioSearchField(title: filter == .ideas ? "Search ideas" : "Search drafts", text: $search)
            .focused($searchFocused)
            .padding(.top, 16)

            StudioChoicePicker(title: "Filter by platform", selection: $platform,
                               options: [nil] + SocialPlatform.allCases.map(Optional.some),
                               label: { $0?.name ?? "All platforms" },
                               icon: { $0.flatMap { PlatformMark.image($0.rawValue) } })
            .padding(.bottom, 3)

            StudioScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if rows.isEmpty {
                        Text(search.isEmpty ? "Nothing here yet." : "No matches.")
                            .foregroundStyle(palette.muted)
                            .padding(10)
                    }
                    ForEach(rows) { row in
                        StudioRule().padding(.horizontal, 8)
                        Button { selection = row.id } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: postBrowserIcon(row))
                                    .foregroundStyle(palette.iconAccent)
                                    .frame(width: 15)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title).font(InkspringTypography.interface(13).weight(.medium)).lineLimit(2)
                                    Group {
                                        if row["platform"].isEmpty { Text(postBrowserStatus(row)) }
                                        else { StudioPlatformLabel(name: row["platform"], title: postBrowserStatus(row)) }
                                    }
                                    .font(InkspringTypography.interface(11))
                                        .foregroundStyle(palette.muted).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(StudioRowStyle(selected: selected == row.id, indicator: true))
                        .accessibilityAddTraits(selected == row.id ? .isSelected : [])
                        .contextMenu {
                            Button("Edit…", systemImage: "pencil") { edit(row) }
                            Button("Copy text", systemImage: "doc.on.doc") { copy(row.body) }
                            Button(row.kind == "idea" ? "Skip idea" : "Move to Trash", systemImage: "trash") {
                                workspace.perform { try workspace.trashLibraryItem(row) }
                            }
                        }
                    }
                    if !rows.isEmpty { StudioRule().padding(.horizontal, 8) }
                }
            }
        }
    }

    private func postBrowserStatus(_ record: WorkspaceRecord) -> String {
        if record.kind == "idea" { return "Post idea" }
        let status = switch record.scheduleStatus {
        case "queued": "Scheduled"
        case "due": "Time to post"
        case "posting": "Posting"
        case "posted": "Posted"
        case "skipped": "Skipped"
        case "ready", "failed", "removed", "manual": "Ready to schedule"
        default: record["status"] == "ready" ? "Ready to share" : "In progress"
        }
        let attachment = record.fields["video"] is [String: Any] ? " · Video"
            : record.fields["image"] is [String: Any] ? " · Image" : ""
        return "\(platformName(record["platform"])) · \(status)\(attachment)"
    }

    private func postBrowserIcon(_ record: WorkspaceRecord) -> String {
        if record.fields["video"] is [String: Any] { return "play.rectangle" }
        if record.fields["image"] is [String: Any] { return "photo" }
        return record.kind == "idea" ? "sparkles" : "doc.text"
    }
}

struct PostPreview: View {
    @Environment(\.studioPalette) private var palette
    let record: WorkspaceRecord
    let workspace: Workspace
    let edit: (WorkspaceRecord) -> Void
    let showSchedule: (WorkspaceRecord) -> Void
    let expanded: Bool
    let togglePreview: () -> Void
    @State private var comment = ""
    @State private var quickEdit: WorkspaceRecord?

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 9) {
                        Group {
                            if record.kind == "idea" { Label("Post idea", systemImage: "sparkles") }
                            else { StudioPlatformLabel(name: record["platform"], title: platformName(record["platform"])) }
                        }
                            .font(InkspringTypography.interface(12))
                            .foregroundStyle(palette.muted)
                        Text(record.title)
                            .font(InkspringTypography.editorial(24, relativeTo: .title2))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 5)
                    let previewLabel = expanded ? "Exit full-window preview" : "Full-window preview"
                    Button(previewLabel, systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           action: togglePreview)
                        .labelStyle(.iconOnly)
                        .buttonStyle(StudioIconButtonStyle())
                        .help(previewLabel)
                        .keyboardShortcut(expanded ? .cancelAction : nil)
                }
                StudioRule()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { previewActions }
                    VStack(alignment: .leading, spacing: 8) { previewActions }
                }
                if record.fields["video"] is [String: Any] {
                    attachment("Video", icon: "video", url: workspace.videoURL(record))
                }
                if record.fields["image"] is [String: Any] {
                    attachment("Image", icon: "photo", url: workspace.imageURL(record))
                }
                if record.kind == "draft", ScheduleListing.section(for: record) == .ready {
                    Button("Open in Schedule", systemImage: "calendar") { showSchedule(record) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    if let target = record.fields["replyTo"] as? [String: String], let text = target["text"], !text.isEmpty {
                        Text(text).font(.callout).foregroundStyle(.secondary)
                    }
                    if !record.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(record.body)
                            .font(InkspringTypography.editorial(17))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .studioSurface()
                Text("Comments").font(InkspringTypography.editorial(19, relativeTo: .headline))
                ForEach(Array(record.comments.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        if let date = (item["at"] as? String).flatMap(scheduleDate) {
                            Text(date, format: .dateTime.month().day().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item["text"] as? String ?? "").textSelection(.enabled)
                    }
                }
                HStack {
                    TextField("Add a comment", text: $comment, axis: .vertical)
                        .font(InkspringTypography.interface(13))
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .studioSurface(StudioRadius.control)
                    Button("Save comment") {
                        workspace.perform {
                            try workspace.addComment(to: record, text: comment)
                            comment = ""
                            InkspringReview.recordActivity()
                        }
                    }
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, expanded ? 34 : 22)
            .padding(.horizontal, expanded ? 34 : 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $quickEdit) { item in
            QuickPostEdit(record: item, workspace: workspace)
                .background(palette.canvas)
                .studioAppearance(palette)
        }
    }

    private func attachment(_ title: String, icon: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(InkspringTypography.interface(12).weight(.semibold))
                .foregroundStyle(palette.muted)
            if let url {
                AttachedMedia(url: url, videoHeight: expanded ? 420 : 250)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: StudioRadius.control))
            } else {
                Label("Attachment unavailable", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .studioSurface()
    }

    @ViewBuilder private var previewActions: some View {
        if !["posting", "posted"].contains(record.scheduleStatus) {
            Button(record.kind == "idea" ? "Edit idea" : "Edit post", systemImage: "pencil") { quickEdit = record }
            if record.kind == "draft" {
                Button("Open in studio", systemImage: "arrow.up.right") { edit(record) }
            }
        }
        Button("Copy", systemImage: "doc.on.doc") { copy(record.body) }
        Button(record.kind == "idea" ? "Skip idea" : "Move to Trash", systemImage: "trash") {
            workspace.perform { try workspace.trashLibraryItem(record) }
        }
        .disabled(["posting", "posted", "uncertain"].contains(record.scheduleStatus))
    }
}

private struct WorkspaceTrash: View {
    let workspace: Workspace
    @State private var deleting: WorkspaceRecord?
    @Environment(\.studioPalette) private var palette

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "Trash", subtitle: "Restore drafts and ideas, or permanently delete them.")
                if workspace.trashedRecords.isEmpty {
                    ContentUnavailableView("Trash is empty", systemImage: "trash")
                }
                ForEach(workspace.trashedRecords) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(item.kind == "idea" ? "Post idea" : "Draft", systemImage: item.kind == "idea" ? "lightbulb" : "doc.text")
                            .font(.caption).foregroundStyle(palette.muted)
                        Text(item.title).font(.headline)
                        Text(item.body).font(.body).lineLimit(3).foregroundStyle(palette.muted)
                        HStack {
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                workspace.perform { try workspace.restoreLibraryItem(item) }
                            }
                            Button("Delete permanently…", systemImage: "trash", role: .destructive) { deleting = item }
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).studioSurface()
                }
            }.padding(32)
        }
        .confirmationDialog("Delete permanently?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                if let item = deleting { workspace.perform { try workspace.deleteLibraryItem(item) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This cannot be undone. Linked posts and media files are kept.") }
    }
}

private struct QuickPostEdit: View {
    let record: WorkspaceRecord
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        let isIdea = record.kind == "idea"
        VStack(alignment: .leading, spacing: 18) {
            Text(isIdea ? "Edit idea" : "Edit post")
                .font(InkspringTypography.editorial(25, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            DraftTitleField(title: $title)
            DraftBodyField(text: $text, label: isIdea ? "Idea and angle" : "Post text", minHeight: 200)
            if ["queued", "due"].contains(record.scheduleStatus) {
                Text("Saving changes moves this post to Ready to schedule.").foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    do {
                        try workspace.updatePostText(record, title: title, text: text)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title == record.title && text == record.body)
            }
        }
        .padding(28)
        .frame(width: 560)
        .onAppear { title = record.title; text = record.body }
    }
}

struct AttachedMedia: View {
    let url: URL?
    var videoHeight: CGFloat = 250

    var body: some View {
        if let url, ["mp4", "mov", "webm"].contains(url.pathExtension.lowercased()) {
            if FileManager.default.fileExists(atPath: url.path) {
                if url.pathExtension.lowercased() == "webm" {
                    AttachedWebMPlayer(url: url).frame(height: videoHeight)
                } else {
                    AttachedVideoPlayer(url: url).frame(height: videoHeight)
                }
            } else {
                Label("Video file is unavailable", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        } else if let url {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 350)
                    .accessibilityLabel("Attached image")
            } else {
                Label("Image file is unavailable", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

private struct AttachedVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let currentURL = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct AttachedWebMPlayer: NSViewRepresentable {
    let url: URL

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var url: URL?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url == url ? .allow : .cancel
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.loadFileURL(url, allowingReadAccessTo: url)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.stopLoading()
        view.navigationDelegate = nil
    }
}

@MainActor
func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct StatusGlass: ViewModifier {
    @Environment(\.studioPalette) private var palette

    @ViewBuilder func body(content: Content) -> some View {
        if palette.theme == .paper {
            content.studioPaperControl(in: Capsule(), fill: palette.control)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

struct PrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(StudioActionStyle(prominent: true))
    }
}
