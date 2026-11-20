import AppKit
import AVKit
import SwiftUI
import InkspringSchedule
import WebKit

enum WorkspacePage: String, CaseIterable, Identifiable {
    case ideas = "Post ideas", schedule = "Schedule", published = "Published", workspace = "Workspace"
    case research = "Research", replies = "Replies", analytics = "Analytics"
    case studio = "Writing studio", library = "Library"
    case connections = "Connections", trash = "Trash", about = "About Inkspring", settings = "Settings"

    var id: Self { self }

    var icon: String {
        switch self {
        case .ideas: "newspaper"
        case .schedule: "calendar.badge.clock"
        case .published: "paperplane"
        case .workspace: "folder"
        case .research: "antenna.radiowaves.left.and.right"
        case .replies: "bubble.left.and.bubble.right"
        case .analytics: "chart.bar.xaxis"
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
    private enum EditorRoute {
        case record(WorkspaceRecord)
        case ideaAction(WorkspaceRecord, IdeaAction)
        case scheduledRevision(WorkspaceRecord, (WorkspaceRecord) -> Void)
        case scheduleTime(WorkspaceRecord, () -> Void)
        case publication(WorkspaceRecord, Date?, (WorkspaceRecord) -> Void)
        case newsletterSend(WorkspaceRecord, Bool, (WorkspaceRecord) -> Void)
    }

    @Bindable var workspace: Workspace
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(InkspringReview.activityKey) private var completedWriting = 0
    @State private var page: WorkspacePage = .workspace
    @State private var editor: EditorRoute?
    @State private var postBeingEdited: WorkspaceRecord?
    @State private var newsletterIdea: WorkspaceRecord?
    @State private var newsletterDraft: WorkspaceRecord?
    @State private var linkedInArticlePostID: String?
    @State private var returnedDocumentID: String?
    @State private var newsletterBackPage: WorkspacePage?
    @State private var saveNewsletterBeforeLeaving: (() -> Bool)?
    @State private var studioDraft: WorkspaceRecord?
    @State private var scheduleFocus: String?
    @State private var scheduleTab = ScheduleListing.Section.scheduled
    @State private var pendingNavigation: (() -> Void)?
    @State private var studioDirty = false
    @State private var showsSidebar = true
    @State private var previewExpanded = false
    @State private var showsAgentChat = false
    @State private var showsOnDeviceAssistant = false
    @State private var agentChat = StudioAgentChat()
    @State private var settingsSection = "Appearance"
    @State private var librarySearchRequest = 0
    @State private var showsSupportReminder = false

    private var theme: StudioTheme { StudioTheme(preference: workspace.settings[StudioTheme.preferenceKey]) }
    private var palette: StudioPalette { StudioPalette(theme: theme.resolve(for: systemScheme)) }
    private var isEditingNewsletter: Bool { newsletterDraft != nil }
    private var selectedPage: WorkspacePage { page == .schedule && scheduleTab == .history ? .published : page }
    private var showsEditorPage: Bool {
        if case .newsletterSend = editor { return false }
        return editor != nil
    }

    private var canShowSupportReminder: Bool {
        scenePhase == .active && !DailyBackup.usesTestWorkspace &&
        completedWriting >= InkspringReview.milestone &&
        workspace.startupError == nil && !workspace.substackBusy &&
        [.workspace, .library, .ideas].contains(page) &&
        editor == nil && postBeingEdited == nil && !isEditingNewsletter && !studioDirty && !previewExpanded && !showsAgentChat &&
        pendingNavigation == nil && workspace.error == nil && workspace.scheduleReminderDraftID == nil
    }

    var body: some View {
        Group {
            if let message = workspace.startupError {
                ContentUnavailableView("Couldn’t open your studio", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            } else {
                HStack(spacing: 0) {
                    if showsSidebar && !previewExpanded && !showsEditorPage {
                        sidebar.frame(width: 244).disabled(editor != nil)
                        StudioRule(axis: .vertical)
                    }
                    VStack(spacing: 0) {
                        if !previewExpanded && !showsEditorPage { workspaceBar.disabled(editor != nil) }
                        ZStack {
                            content
                                .opacity(editor == nil ? 1 : 0)
                                .disabled(editor != nil)
                                .accessibilityHidden(editor != nil)
                            if let editor { editorPage(editor) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(palette.canvas)
        .studioAppearance(palette)
        .preferredColorScheme(theme == .system ? nil : palette.colorScheme)
        .modifier(InkspringRatingPrompt(isIdle: [.workspace, .library, .ideas].contains(page)
                                         && editor == nil && postBeingEdited == nil && !isEditingNewsletter
                                         && pendingNavigation == nil && workspace.error == nil))
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .navigation) { leadingToolbar }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { leadingToolbar }
            }
            if previewExpanded && editor == nil {
                ToolbarItem(placement: .primaryAction) {
                    WorkspaceDraftMenu(create: createDraft)
                }
            }
            if editor == nil {
                if #available(macOS 26, *) {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) { quickControls }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { quickControls }
                }
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
            if id != nil { openScheduleReminder() }
        }
        .onChange(of: editor == nil) { _, isClosed in
            if isClosed { openScheduleReminder() }
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
            if !showsEditorPage { sidebarToggle }
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
                WorkspaceDraftMenu(fillsWidth: true, create: createDraft)
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
                Button { navigate { add("project") } } label: { Image(systemName: "plus") }
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
            if selectedPage != item || isEditingNewsletter || showsOnDeviceAssistant {
                navigate {
                    if item == .studio, studioDraft == nil { newDraft() }
                    else if item == .schedule || item == .published {
                        scheduleTab = item == .published ? .history : .scheduled
                        page = .schedule
                    }
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
            .foregroundStyle(selectedPage == item ? palette.text : palette.muted)
        }
        .buttonStyle(StudioRowStyle(selected: selectedPage == item, indicator: true))
        .accessibilityAddTraits(selectedPage == item ? .isSelected : [])
    }

    private func count(for item: WorkspacePage) -> Int? {
        switch item {
        case .ideas: workspace.ideas.filter { $0["status"] == "draft" }.count
        case .schedule: workspace.records.filter { ScheduleListing.section(for: $0) == .scheduled }.count
        case .library: workspace.workspaceDrafts.count
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
            Text(selectedPage.rawValue)
            if let newsletterDraft, let type = WorkspaceDraftType(record: newsletterDraft) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Text(type.name)
            }
            Spacer()
            if !showsSidebar {
                WorkspaceDraftMenu(create: createDraft)
            }
            Button("Ask Inkspring", systemImage: "sparkles") { navigate { showsOnDeviceAssistant = true } }
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
        if showsOnDeviceAssistant {
            InkspringAssistantChat(workspaceID: workspace.directory?.path ?? "workspace", items: { workspace.assistantContents },
                                   execute: workspace.executeAssistant, open: { id in
                guard let item = workspace.records.first(where: { $0.id == id }) else { return }
                showsOnDeviceAssistant = false
                if item.kind == "project" { workspace.selectProject(item.id) }
                else { workspace.selectProject(item.projectID); open(item) }
            }, back: { showsOnDeviceAssistant = false }, readPlan: { id in
                workspace.records.first { $0.id == id && ["draft", "idea", "newsletter"].contains($0.kind) }?["planMarkdown"]
            }, applyPlan: { id, text, base in
                let saved = try workspace.savePlan(itemID: id, markdown: text, base: base)
                return .init(message: "Plan saved on this Mac for \(saved.referenceID ?? saved.id).", itemID: id)
            }, loadHistory: {
                (workspace.settings["onDeviceAssistantHistory"] as? String).flatMap { Data(base64Encoded: $0) }
            }, saveHistory: { data in try workspace.set("onDeviceAssistantHistory", to: data.base64EncodedString()) })
        } else { pageContent }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .workspace, .library:
            ZStack {
                PostBrowser(workspace: workspace, library: page == .library, edit: editPost, openInStudio: open,
                            openArticle: openPostArticle,
                            reviewPair: { reviewPublication($0, at: nil) { _ in } },
                            returnedDocumentID: returnedDocumentID, postBeingEdited: postBeingEdited, back: { navigate() }, finishedEditing: {
                                postBeingEdited = nil
                                studioDirty = false
                            }, editDirtyChanged: { studioDirty = $0 }, selectPost: navigate,
                            showSchedule: showSchedule,
                            editProject: { open(workspace.project ?? .new("project")) },
                            compose: createDraft, expanded: previewExpanded,
                            searchRequest: page == .library ? librarySearchRequest : 0,
                            togglePreview: { setPreviewExpanded(!previewExpanded) })
                    .id("\(workspace.projectID)-\(page.rawValue)")
                    .opacity(isEditingNewsletter ? 0 : 1)
                    .disabled(isEditingNewsletter)
                    .accessibilityHidden(isEditingNewsletter)
                if let newsletterDraft {
                    RecordEditor(record: newsletterDraft, workspace: workspace, newsletterIdea: newsletterIdea,
                                 closeNewsletter: backFromNewsletter,
                                 newsletterDirtyChanged: { studioDirty = $0 },
                                 newsletterSaveBeforeLeaving: { saveNewsletterBeforeLeaving = $0 },
                                 reviewNewsletter: reviewNewsletter, openRelatedPost: { post in navigate { open(post) } },
                                 linkedInPostID: linkedInArticlePostID,
                                 saved: { _ in })
                        .id(newsletterDraft.id)
                }
            }
        case .ideas:
            IdeaQueueView(workspace: workspace, add: { add("idea") }, edit: open, openDraft: open,
                          openNewsletter: draftNewsletter, showAction: { editor = .ideaAction($0, $1) })
                .id(workspace.projectID)
        case .research:
            ResearchView(workspace: workspace, add: { add("source") }, edit: open,
                         editProject: { if let project = workspace.project { open(project) } }, openDraft: open)
                .id(workspace.projectID)
        case .schedule, .published:
            ScheduleView(workspace: workspace, open: open, focusDraftID: $scheduleFocus, tab: $scheduleTab,
                         revise: { editor = .scheduledRevision($0, $1) }, reviewPublication: reviewPublication,
                         chooseTime: { editor = .scheduleTime($0, $1) }, reviewNewsletter: reviewNewsletter)
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
                            }, reviewPublication: reviewPublication, isActive: editor == nil,
                            openArticle: openPostArticle)
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

    @ViewBuilder private func editorPage(_ route: EditorRoute) -> some View {
        switch route {
        case .record(let record):
            RecordEditor(record: record, workspace: workspace, closeRecord: closeEditor) { saved in
                editor = nil
                if saved.kind == "project" {
                    workspace.selectProject(saved.id)
                    page = .workspace
                }
            }
            .id(record.id)
        case .ideaAction(let idea, let action):
            IdeaActionPage(idea: idea, action: action, workspace: workspace, close: closeEditor) { drafts in
                let noun = drafts.count == 1 ? "draft" : "drafts"
                workspace.notice = "Created \(drafts.count) \(noun)"
            }
            .id(idea.id)
        case .scheduledRevision(let draft, let saved):
            ScheduledDraftRevision(draft: draft, workspace: workspace, saved: saved, close: closeEditor)
                .id(draft.id)
        case .scheduleTime(let draft, let scheduled):
            ScheduleTimePage(draft: draft, workspace: workspace, close: closeEditor, scheduled: scheduled,
                             reviewPublication: reviewPublication)
                .id(draft.id)
        case .publication(let draft, let slot, let completed):
            PublicationReview(draft: draft, workspace: workspace, scheduleAt: slot, completed: completed, close: closeEditor)
                .id(draft.id)
        case .newsletterSend(let draft, let scheduling, let completed):
            NewsletterSendPage(record: draft, workspace: workspace, scheduling: scheduling, close: closeEditor,
                               completed: completed)
                .id(draft.id)
        }
    }

    private func closeEditor() { editor = nil }

    private func openScheduleReminder() {
        guard editor == nil, let id = workspace.scheduleReminderDraftID else { return }
        workspace.scheduleReminderDraftID = nil
        navigate {
            scheduleFocus = id
            page = .schedule
        }
    }

    private func reviewPublication(_ draft: WorkspaceRecord, at date: Date?,
                                   completed: @escaping (WorkspaceRecord) -> Void) {
        if date == nil, let article = workspace.pendingLinkedInArticle(for: draft) {
            openPostArticle(article, from: draft)
            return
        }
        editor = .publication(draft, date, completed)
    }

    private func reviewNewsletter(_ draft: WorkspaceRecord, scheduling: Bool,
                                  completed: @escaping (WorkspaceRecord) -> Void) {
        editor = .newsletterSend(draft, scheduling, completed)
    }

    private func backFromNewsletter() {
        let destination = newsletterBackPage ?? .workspace
        let documentID = linkedInArticlePostID ?? newsletterDraft?.id
        let parent = linkedInArticlePostID.flatMap { id in workspace.drafts.first { $0.id == id } }
        navigate {
            returnedDocumentID = documentID
            if destination == .studio, let parent { studioDraft = parent }
            page = destination
        }
    }

    private func editPost(_ record: WorkspaceRecord) {
        guard record.id != postBeingEdited?.id else { return }
        navigate {
            if record.kind == "draft" {
                setPreviewExpanded(false)
                postBeingEdited = record
            } else {
                open(record)
            }
        }
    }

    private func add(_ kind: String) {
        if kind == "project" || workspace.project == nil {
            open(.new("project"))
            return
        }
        open(.new(kind, projectID: workspace.projectID))
    }

    private func createDraft(_ type: WorkspaceDraftType) {
        navigate {
            guard let project = workspace.project else { add("project"); return }
            if type == .linkedInArticle {
                var post = WorkspaceDraftType.post.makeRecord(projectID: project.id)
                post["platform"] = "linkedin"
                post["format"] = "post"
                open(post)
            } else {
                open(type.makeRecord(projectID: project.id))
            }
        }
    }

    private func openPostArticle(_ article: WorkspaceRecord, from post: WorkspaceRecord) {
        if article.isPublishedContent {
            open(article)
            return
        }
        navigate {
            open(article)
            linkedInArticlePostID = post.id
        }
    }

    private func newDraft(reply: Bool = false) {
        guard let project = workspace.project else { add("project"); return }
        var draft = WorkspaceRecord.new("draft", projectID: project.id)
        if reply { draft["format"] = "reply" }
        open(draft)
    }

    private func draftReply(_ item: WorkspaceRecord) {
        guard workspace.project != nil else { add("project"); return }
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
        if record.isPublishedContent {
            if let url = PublishedPostFeed.entries(in: workspace.records, projectID: record.projectID)
                .first(where: { $0.id == record.id })?.links.first {
                NSWorkspace.shared.open(url)
            } else {
                scheduleTab = .history
                page = .schedule
            }
            return
        }
        if ["draft", "newsletter", "script", "article"].contains(record.kind), record.projectID != workspace.projectID,
           workspace.projects.contains(where: { $0.id == record.projectID }) {
            workspace.selectProject(record.projectID)
        }
        if record.kind == "draft" {
            studioDraft = record
            page = .studio
        } else if record.isLongForm {
            returnedDocumentID = nil
            newsletterBackPage = page
            newsletterDraft = record
            setPreviewExpanded(false)
            if page != .library { page = .workspace }
        } else {
            editor = .record(record)
        }
    }

    private func navigate(_ action: @escaping () -> Void = {}) {
        let leave = {
            showsOnDeviceAssistant = false
            postBeingEdited = nil
            if isEditingNewsletter {
                newsletterDraft = nil
                linkedInArticlePostID = nil
                newsletterIdea = nil
                newsletterBackPage = nil
            }
            action()
        }
        if isEditingNewsletter, let saveNewsletterBeforeLeaving {
            guard saveNewsletterBeforeLeaving() else { return }
            studioDirty = false
            leave()
        } else if studioDirty {
            pendingNavigation = leave
        } else {
            leave()
        }
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
        let platform = record.kind == "newsletter" ? "substack" : record["platform"]
        VStack(alignment: .leading, spacing: 9) {
            if !platform.isEmpty {
                StudioPlatformLabel(name: platform, title: record.kind == "article" ? WorkspaceDraftType(record: record)?.name ?? "X article" : platformName(platform))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.title).font(.headline)
            if !record.body.isEmpty {
                Text(preview)
                    .font(InkspringTypography.interface(17))
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

    private var preview: AttributedString {
        guard record.isLongForm,
              let markdown = try? AttributedString(markdown: record.body,
                  options: .init(failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return AttributedString(record.body)
        }
        var result = AttributedString()
        var previousBlock: Int?
        for run in markdown.runs {
            let block = run.presentationIntent?.components.first?.identity
            if !result.characters.isEmpty, block != previousBlock {
                result.append(AttributedString("\n"))
            }
            var text = AttributedString(markdown[run.range])
            text.presentationIntent = nil
            // Keep the card's click action instead of opening a preview link.
            if text.link != nil { text.underlineStyle = .single }
            text.link = nil
            result.append(text)
            previousBlock = block
        }
        return result
    }
}

func platformName(_ value: String) -> String {
    ["youtube": "YouTube", "x": "X", "linkedin": "LinkedIn", "instagram": "Instagram", "reddit": "Reddit", "tiktok": "TikTok"][value]
        ?? value.capitalized
}

enum WorkspaceDraftType: String, CaseIterable {
    case post = "draft", newsletter, article, linkedInArticle = "linkedin-article", script

    init?(record: WorkspaceRecord) {
        self.init(rawValue: record.isLinkedInArticle ? "linkedin-article" : record.kind)
    }

    func makeRecord(projectID: String) -> WorkspaceRecord {
        var record = WorkspaceRecord.new(self == .linkedInArticle ? "article" : rawValue, projectID: projectID)
        if self == .linkedInArticle { record["platform"] = "linkedin" }
        return record
    }

    var name: String {
        switch self {
        case .post: "Social post"
        case .newsletter: "Newsletter"
        case .article: "X article"
        case .linkedInArticle: "LinkedIn article"
        case .script: "YouTube script"
        }
    }

    var symbol: String {
        switch self {
        case .post: "text.bubble"
        case .newsletter: "envelope"
        case .article, .linkedInArticle: "doc.richtext"
        case .script: "play.rectangle"
        }
    }
}

private struct WorkspaceDraftMenu: View {
    var fillsWidth = false
    let create: (WorkspaceDraftType) -> Void

    var body: some View {
        Menu {
            ForEach(WorkspaceDraftType.allCases, id: \.self) { type in
                if type == .post {
                    Button(type == .linkedInArticle ? "LinkedIn post with article" : type.name,
                           systemImage: type.symbol) { create(type) }
                        .keyboardShortcut("n")
                } else {
                    Button(type.name, systemImage: type.symbol) { create(type) }
                }
            }
        } label: {
            HStack {
                Label("New draft", systemImage: "plus")
                if fillsWidth { Spacer() }
                Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(StudioActionStyle(prominent: true, fillsWidth: fillsWidth))
        .accessibilityLabel("New draft")
    }
}

enum PostBrowserFilter: String, CaseIterable {
    case all = "All drafts"
    case working = "In progress"
    case ideas = "Post ideas"
    case scheduling = "Ready to schedule"
    case sharing = "Ready to share"

    func matches(_ record: WorkspaceRecord, platform: String?, search: String, library: Bool) -> Bool {
        guard self == .ideas ? record.kind == "idea" : WorkspaceDraftType(record: record) != nil else { return false }
        if let platform {
            let suggestions = record.fields["suggestedPlatforms"] as? [String] ?? []
            let platforms = self == .ideas ? (suggestions.isEmpty ? ["x"] : suggestions) : [ScheduleListing.channel(of: record)]
            guard platforms.contains(platform) else { return false }
        }
        let matchingStatus = switch self {
        case .all: true
        case .working: record.isLongForm ? ["draft", "synced"].contains(record["state"]) : record["status"] == "draft" && (library || record.schedule.isEmpty)
        case .ideas: record["status"] == "draft"
        case .scheduling: ScheduleListing.section(for: record) == .ready
        case .sharing: record["status"] == "ready"
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchingStatus && (query.isEmpty || [record.referenceID ?? "", record.title, record.body, record["subtitle"], WorkspaceDraftType(record: record)?.name ?? "", platformName(ScheduleListing.channel(of: record))]
            .contains { $0.localizedCaseInsensitiveContains(query) })
    }
}

struct PostBrowser: View {
    private enum DraftSort: String, CaseIterable {
        case lastUpdated = "Last updated"
        case oldestUpdate = "Oldest update"
        case title = "Title A–Z"

        func sorted(_ records: [WorkspaceRecord]) -> [WorkspaceRecord] {
            if self == .title {
                return records.map { (record: $0, title: $0.title) }
                    .sorted { lhs, rhs in
                        let order = lhs.title.localizedStandardCompare(rhs.title)
                        return order == .orderedSame ? lhs.record.id > rhs.record.id : order == .orderedAscending
                    }
                    .map(\.record)
            }
            return records.map { (record: $0, date: scheduleDate($0["updatedAt"])) }
                .sorted { lhs, rhs in
                    if lhs.date == rhs.date { return lhs.record.id > rhs.record.id }
                    guard let lhsDate = lhs.date else { return false }
                    guard let rhsDate = rhs.date else { return true }
                    return self == .lastUpdated ? lhsDate > rhsDate : lhsDate < rhsDate
                }
                .map(\.record)
        }
    }

    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let library: Bool
    let edit: (WorkspaceRecord) -> Void
    let openInStudio: (WorkspaceRecord) -> Void
    let openArticle: (WorkspaceRecord, WorkspaceRecord) -> Void
    let reviewPair: (WorkspaceRecord) -> Void
    let returnedDocumentID: String?
    let postBeingEdited: WorkspaceRecord?
    let back: () -> Void
    let finishedEditing: () -> Void
    let editDirtyChanged: (Bool) -> Void
    let selectPost: (@escaping () -> Void) -> Void
    let showSchedule: (WorkspaceRecord) -> Void
    let editProject: () -> Void
    let compose: (WorkspaceDraftType) -> Void
    let expanded: Bool
    let searchRequest: Int
    let togglePreview: () -> Void
    @State private var selection: String?
    @State private var type: WorkspaceDraftType?
    @State private var filter = PostBrowserFilter.all
    @State private var platform: String?
    @State private var search = ""
    @AppStorage("inkspring.mac.draftSort") private var draftSort = DraftSort.lastUpdated
    @FocusState private var searchFocused: Bool

    private var statuses: [PostBrowserFilter] {
        if library { return type == nil || type == .post ? [.all, .working, .sharing] : [.all, .working] }
        if type == .script || type == .article || type == .linkedInArticle { return [.all, .working] }
        return [.all, .working, .scheduling]
    }

    private func records(for filter: PostBrowserFilter, query: String = "") -> [WorkspaceRecord] {
        let rows = (filter == .ideas ? workspace.ideas : workspace.workspaceDrafts).filter {
            (type == nil || WorkspaceDraftType(record: $0) == type) && filter.matches($0, platform: platform, search: query, library: library)
        }
        return type == nil ? LinkedInArticleShare.groupedDrafts(rows) : rows
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
        let matchingRecords = records(for: filter, query: search)
        let rows = draftSort.sorted(matchingRecords)
        let selected = rows.first { $0.id == selection }
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
                    WorkspaceDraftMenu(create: compose)
                }
                .padding(.bottom, 18)
                StudioTabs(selection: Binding(get: { type }, set: { newType in
                    selectPost {
                        type = newType
                        filter = .all
                        platform = nil
                        selection = nil
                    }
                }), tabs: [nil] + WorkspaceDraftType.allCases.map(Optional.some),
                           label: { $0.map { $0.name + "s" } ?? "All drafts" },
                           count: { format in
                               if let format { return workspace.workspaceDrafts.filter { WorkspaceDraftType(record: $0) == format }.count }
                               return LinkedInArticleShare.groupedDrafts(workspace.workspaceDrafts).count
                           })
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if !expanded {
                        postList(rows, selected: postBeingEdited?.id ?? selected?.id)
                            .padding(.trailing, 16)
                            .frame(width: min(max(210, geometry.size.width * 0.29), 330))
                            .frame(maxHeight: .infinity)
                        StudioRule(axis: .vertical)
                    }
                    Group {
                        if let postBeingEdited {
                            PostInlineEditor(record: postBeingEdited, workspace: workspace, back: back,
                                             saved: finishedEditing, onDirty: editDirtyChanged,
                                             openArticle: openArticle)
                                .id(postBeingEdited.id)
                        } else if let selected {
                            if selected.isLongForm, let format = WorkspaceDraftType(record: selected) {
                                longFormPreview(selected, type: format)
                                    .id(selected.id)
                            } else {
                                PostPreview(record: selected, workspace: workspace, edit: edit, openInStudio: openInStudio,
                                        openArticle: openArticle, reviewPair: reviewPair, showSchedule: showSchedule,
                                        expanded: expanded, togglePreview: togglePreview)
                                    .id(selected.id)
                            }
                        } else {
                            VStack {
                                ContentUnavailableView("No matching drafts", systemImage: "doc.text")
                                if expanded {
                                    Button("Exit full-window preview", action: togglePreview).keyboardShortcut(.cancelAction)
                                } else if filter == .all && search.isEmpty && platform == nil {
                                    Button("New " + (type?.name.lowercased() ?? "social post"), systemImage: "plus") { compose(type ?? .post) }
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
        .onChange(of: returnedDocumentID) { _, id in
            guard let id, let record = workspace.workspaceDrafts.first(where: { $0.id == id }) else { return }
            if !rows.contains(where: { $0.id == id }) {
                type = WorkspaceDraftType(record: record)
                filter = .all
                platform = nil
                search = ""
            }
            selection = id
        }
        .onChange(of: postBeingEdited?.id) { _, id in
            if let id { selection = id }
        }
        .onChange(of: searchRequest, initial: true) { _, request in
            if request > 0 {
                Task { @MainActor in
                    await Task.yield()
                    searchFocused = true
                }
            }
        }
    }

    private func postList(_ rows: [WorkspaceRecord], selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioSearchField(title: filter == .ideas ? "Search ideas" : "Search drafts", text: $search)
                .focused($searchFocused)
                .padding(.top, 16)

            StudioFilterMenu(title: "Filter drafts", value: filter == .all ? "All statuses" : filter.rawValue) {
                ForEach(statuses, id: \.self) { status in
                    Button {
                        selectPost { filter = status; selection = nil }
                    } label: {
                        if filter == status { Label(status == .all ? "All statuses" : status.rawValue, systemImage: "checkmark") }
                        else { Text(status == .all ? "All statuses" : status.rawValue) }
                    }
                }
                if !library && type == nil {
                    Divider()
                    Button("Post ideas", systemImage: "lightbulb") {
                        selectPost { filter = .ideas; platform = nil; selection = nil }
                    }
                }
            }
            HStack(spacing: 8) {
                if type == nil || type == .post {
                    let channels = SocialPlatform.allCases.map(\.rawValue) + (type == nil && filter != .ideas ? ["substack", "youtube"] : [])
                    StudioChoicePicker(title: "Filter by platform", selection: $platform,
                                       options: [nil] + channels.map(Optional.some),
                                       label: { $0.map(platformName) ?? "All platforms" },
                                       icon: { $0.flatMap(PlatformMark.image) })
                }
                StudioFilterMenu(title: "Sort drafts", value: "Sort") {
                    Picker("Sort drafts", selection: $draftSort) {
                        ForEach(DraftSort.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .accessibilityValue(draftSort.rawValue)
            }
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
                        Button {
                            if postBeingEdited?.id != row.id { selectPost { selection = row.id } }
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: postBrowserIcon(row))
                                    .foregroundStyle(palette.iconAccent)
                                    .frame(width: 15)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title).font(InkspringTypography.interface(13).weight(.medium)).lineLimit(2)
                                    Group {
                                        if row.isLongForm, let type = WorkspaceDraftType(record: row) { Text(type.name + " · " + row["state"].capitalized) }
                                        else if row["platform"].isEmpty { Text(postBrowserStatus(row)) }
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
                                .disabled(["posting", "posted"].contains(row.scheduleStatus))
                            Button("Copy text", systemImage: "doc.on.doc") { copy(row.body) }
                            if !row.isLongForm {
                                Button(row.kind == "idea" ? "Skip idea" : "Move to Trash", systemImage: "trash") {
                                    workspace.perform { try workspace.trashLibraryItem(row) }
                                }
                            }
                        }
                    }
                    if !rows.isEmpty { StudioRule().padding(.horizontal, 8) }
                }
            }
        }
    }

    private func longFormPreview(_ record: WorkspaceRecord, type: WorkspaceDraftType) -> some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    StudioPlatformLabel(name: ScheduleListing.channel(of: record), title: type.name)
                    Spacer()
                    Button(expanded ? "Exit full-window preview" : "Full-window preview",
                           systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           action: togglePreview)
                        .labelStyle(.iconOnly)
                        .buttonStyle(StudioIconButtonStyle())
                        .keyboardShortcut(expanded ? .cancelAction : nil)
                }
                HStack {
                    if let reference = record.referenceID { StudioCopyReference(reference: reference) }
                    if let updated = scheduleDate(record["updatedAt"]) {
                        Text("Last updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(palette.muted)
                    }
                }
                StudioRule()
                HStack {
                    Button(["draft", "synced"].contains(record["state"]) ? "Edit draft" : "Open document",
                           systemImage: "square.and.pencil") { edit(record) }
                    Button("Copy", systemImage: "doc.on.doc") { copy(record.body) }
                }
                NewsletterPreview(title: record.title, subtitle: record["subtitle"], markdown: record.body,
                                  cover: workspace.mediaURL(record))
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
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
        if record.isLongForm, let type = WorkspaceDraftType(record: record) { return type.symbol }
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
    let openInStudio: (WorkspaceRecord) -> Void
    let openArticle: (WorkspaceRecord, WorkspaceRecord) -> Void
    let reviewPair: (WorkspaceRecord) -> Void
    let showSchedule: (WorkspaceRecord) -> Void
    let expanded: Bool
    let togglePreview: () -> Void
    @State private var comment = ""
    @State private var outlineID: String?

    var body: some View {
        if outlineID == record.id, let current = workspace.records.first(where: { $0.id == record.id }) {
            WorkspaceOutline(record: current, workspace: workspace) { outlineID = nil }
        } else {
            preview
        }
    }

    private var preview: some View {
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
                        if let reference = record.referenceID {
                            StudioCopyReference(reference: reference)
                        }
                        if record.kind == "draft", let updatedAt = scheduleDate(record["updatedAt"]) {
                            Text("Last updated \(updatedAt.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .accessibilityIdentifier("post.lastUpdated")
                        }
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
                HStack(alignment: .top, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { previewActions }
                        VStack(alignment: .leading, spacing: 8) { previewActions }
                    }
                    Spacer(minLength: 8)
                    previewMoreActions
                }
                postArticleControls
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
                        if record["platform"] == "x", ["followup", "thread"].contains(record["format"]) {
                            let posts = XThreadText.posts(in: record.body)
                            ForEach(posts.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(index == 0 ? "Opening post" : "Follow-up reply \(index)", systemImage: index == 0 ? "text.bubble" : "arrow.turn.down.right")
                                            .font(.callout.weight(.semibold)).foregroundStyle(palette.iconAccent)
                                        Spacer()
                                        Button("Edit", systemImage: "pencil") { edit(record) }
                                    }
                                    let link = XReplyArticle(posts[index])
                                    if !link.copy.isEmpty { Text(link.copy).font(InkspringTypography.interface(17)).lineSpacing(5).textSelection(.enabled) }
                                    if let ref = link.reference {
                                        if let article = workspace.records.first(where: { $0.projectID == record.projectID && $0.isXArticle && $0.referenceID == ref }) {
                                            if let url = CompanionPublication.postURL(article["articleURL"]) {
                                                StudioExternalLink("Open X article · " + article.title, destination: url)
                                            } else {
                                                Button("X article · " + article.title, systemImage: "doc.text") { edit(article) }
                                                Text("Publish the article first to include its X link.").font(.caption).foregroundStyle(palette.muted)
                                            }
                                        } else { Text("Linked X article unavailable · " + ref).font(.caption) }
                                    }
                                }
                                if index < posts.count - 1 { StudioRule() }
                            }
                        } else {
                            Text(record.body).font(InkspringTypography.interface(17)).lineSpacing(5).textSelection(.enabled)
                        }
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
    }

    @ViewBuilder private var postArticleControls: some View {
        if record.kind == "draft", let platform = SocialPlatform(rawValue: record["platform"]),
           [.linkedin, .x].contains(platform), record.fields["manualQuote"] as? Bool != true {
            let key = platform == .x ? "xArticleID" : "linkedinArticleID"
            let allowsChanges = !["queued", "due", "posting", "posted", "uncertain"].contains(record.scheduleStatus)
            let replies = workspace.xReplyArticles(for: record, body: record.body)
            if allowsChanges || !record[key].isEmpty || !replies.isEmpty {
                let canCreate = !record.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record["format"] != "reply"
                let create: (() -> Void)? = canCreate ? { createLinkedArticle() } : nil
                let hasUnpublishedArticle = workspace.pendingLinkedInArticle(for: record) != nil ||
                    platform == .x && (replies.contains { $0["state"] != "published" } || workspace.records.contains {
                        $0.isXArticle && $0.projectID == record.projectID && $0.id == record[key] && $0["state"] != "published"
                    })
                let canPublishTogether = platform == .x || !record.needsNativePostVideo
                let publish: (() -> Void)? = canCreate && allowsChanges && hasUnpublishedArticle && canPublishTogether
                    ? { reviewPair(record) } : nil
                PostArticlePicker(workspace: workspace, projectID: record.projectID, platform: platform,
                                  articleID: articleBinding(key), openArticle: { openArticle($0, record) }, createArticle: create,
                                  xReplyArticles: replies, allowsChanges: allowsChanges, publishTogether: publish,
                                  requiresVideo: record.needsNativePostVideo)
            }
        }
    }

    private func articleBinding(_ key: String) -> Binding<String> {
        Binding(get: { record[key] }, set: { id in
            workspace.perform {
                var updated = record
                updated[key] = id
                try workspace.save(updated)
            }
        })
    }

    private func createLinkedArticle() {
        workspace.perform {
            let article = try workspace.linkedArticleDraft(from: record)
            openArticle(article, record)
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
            Button(record.kind == "idea" ? "Edit idea" : "Edit post", systemImage: "pencil") {
                edit(record)
            }
            if record.kind == "draft" {
                Button("Open in studio", systemImage: "arrow.up.right") { openInStudio(record) }
            }
        }
    }

    private var previewMoreActions: some View {
        StudioFilterMenu(title: "More actions", value: "More actions") {
            Button("Copy text", systemImage: "doc.on.doc") { copy(record.body) }
            Button(record["planMarkdown"].isEmpty ? "Add private outline" : "View private outline",
                   systemImage: "list.bullet.clipboard") { outlineID = record.id }
                .help("Open notes for this draft. They stay in Inkspring when you publish.")
            Divider()
            Button(record.kind == "idea" ? "Skip idea" : "Move to Trash", systemImage: "trash") {
                workspace.perform { try workspace.trashLibraryItem(record) }
            }
            .disabled(["posting", "posted", "uncertain"].contains(record.scheduleStatus))
        }
        .help("Copy the text, open private draft notes, or move this item to Trash.")
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
