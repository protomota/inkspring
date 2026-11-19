import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import InkspringSchedule

struct StudioEditorPage<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PageHeading(title: title, titleSize: 30)
                Spacer()
                actions()
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            StudioRule()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PostInlineEditor: View {
    @Environment(\.studioPalette) private var palette
    let record: WorkspaceRecord
    let workspace: Workspace
    let back: () -> Void
    let saved: () -> Void
    let onDirty: (Bool) -> Void
    @State private var title = ""
    @State private var markdown = ""
    @State private var format = ""
    @State private var showingHistory = false
    @State private var message: String?
    @State private var writingAssistantOpen = false
    @State private var baseline: WorkspaceRecord?

    private var current: WorkspaceRecord { workspace.records.first { $0.id == record.id } ?? record }
    private var dirty: Bool {
        let base = baseline ?? record
        return title != base.title || markdown != base.body || format != base["format"]
    }

    var body: some View {
        if showingHistory {
            ContentRevisionHistoryPage(record: record, workspace: workspace, back: { showingHistory = false }) { _ in saved() }
        } else {
            editorContent
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Back", systemImage: "chevron.left", action: back)
                    .help("Back to the post")
                    .keyboardShortcut(.cancelAction)
                if let reference = record.referenceID {
                    StudioCopyReference(reference: reference)
                }
                Spacer()
                Button("Ask AI", systemImage: "bubble.left.and.text.bubble.right") { writingAssistantOpen.toggle() }
                    .disabled(!current.acceptsRevisionComments).accessibilityIdentifier("writing.tools")
                Button("Revision history", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                    .disabled(dirty)
                Button("Save", action: save)
                    .modifier(PrimaryActionStyle())
                    .keyboardShortcut("s")
                    .disabled(!dirty)
            }
            if writingAssistantOpen {
                ScrollView {
                StudioWritingAssistant(agent: StudioWritingConnection(settings: workspace.settings) == .agent ? StudioChatAgent.selected.rawValue : WritingProviders(settings: workspace.settings).writingProvider.rawValue,
                    requests: current.comments.enumerated().map { index, comment in
                        StudioWritingRequest(id: comment["revisionRequestID"] as? String ?? "saved-\(index)", text: comment["text"] as? String ?? "",
                            state: current.appliedRevisionCommentIDs.contains(comment["revisionRequestID"] as? String ?? "") ? "Applied" : "Waiting for Mac")
                    }, reply: current["notesReply"], error: current["writingRequestError"].isEmpty ? nil : current["writingRequestError"]) { prompt in
                        if dirty {
                            try workspace.updatePostText(baseline ?? record, title: title, text: markdown, format: format)
                            baseline = current
                        }
                        try workspace.addComment(to: current, text: prompt, revisionRequestID: UUID().uuidString.lowercased())
                        Task { await workspace.runDraftRevisionComments() }
                    }
                    .padding(14).studioSurface(fill: palette.well)
                }.frame(maxHeight: 240)
            }
            DraftTitleField(title: $title)
            StudioProofreadAction(document: .init(title: title, body: markdown),
                                  check: { try await ContentStudio.proofread($0, workspace: workspace) }) {
                title = $0.title
                markdown = $0.body
            }
            DraftPostText(workspace: workspace, record: record, text: $markdown, format: $format, label: "Markdown", minHeight: 100)
                .frame(maxHeight: .infinity)
            if ["queued", "due"].contains(record.scheduleStatus) {
                Text("Saving changes moves this post to Ready to schedule.").foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(palette.danger) }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .onAppear { title = current.title; markdown = current.body; format = current["format"]; baseline = current }
        .onChange(of: current["updatedAt"]) {
            guard !dirty else { return }
            title = current.title; markdown = current.body; format = current["format"]; baseline = current
        }
        .onChange(of: dirty) { _, changed in onDirty(changed) }
    }

    private func save() {
        do {
            try workspace.updatePostText(baseline ?? record, title: title, text: markdown, format: format)
            saved()
        } catch {
            message = error.localizedDescription
        }
    }
}

struct RecordEditor: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var newsletterField: NewsletterField?
    @State var record: WorkspaceRecord
    let workspace: Workspace
    let saved: (WorkspaceRecord) -> Void
    let closeRecord: () -> Void
    let closeNewsletter: () -> Void
    let newsletterDirtyChanged: (Bool) -> Void
    let newsletterSaveBeforeLeaving: ((() -> Bool)?) -> Void
    let reviewNewsletter: (WorkspaceRecord, Bool, @escaping (WorkspaceRecord) -> Void) -> Void
    private let original: WorkspaceRecord
    @State private var newsletterBase: WorkspaceRecord
    @State private var newsletterSaveError: String?
    @State private var message: String?
    @State private var newsletterMode = "Source"
    @State private var newsletterFindRequest = 0
    @State private var writingAssistantOpen = false
    @State private var newsletterInspectorOpen = false
    @State private var showingHistory = false
    @State private var newsletterBrief = ""
    @State private var newsletterAssistantOpen = false
    @State private var newsletterIdeaOutline = false
    @State private var newsletterSources: Set<String> = []
    @State private var newsletterWriting: Task<Void, Never>?
    @State private var showsCoverGenerator = false
    @State private var coverPrompt = ""

    private enum NewsletterField: Hashable { case title, subtitle }

    init(record: WorkspaceRecord, workspace: Workspace, newsletterIdea: WorkspaceRecord? = nil,
         closeRecord: @escaping () -> Void = {},
         closeNewsletter: @escaping () -> Void = {},
         newsletterDirtyChanged: @escaping (Bool) -> Void = { _ in },
         newsletterSaveBeforeLeaving: @escaping ((() -> Bool)?) -> Void = { _ in },
         reviewNewsletter: @escaping (WorkspaceRecord, Bool, @escaping (WorkspaceRecord) -> Void) -> Void = { _, _, _ in },
         saved: @escaping (WorkspaceRecord) -> Void) {
        _record = State(initialValue: record)
        _newsletterBase = State(initialValue: record)
        original = record
        if record.kind == "newsletter", !["draft", "synced"].contains(record["state"]) {
            _newsletterMode = State(initialValue: "Preview")
        }
        self.workspace = workspace
        self.saved = saved
        self.closeRecord = closeRecord
        self.closeNewsletter = closeNewsletter
        self.newsletterDirtyChanged = newsletterDirtyChanged
        self.newsletterSaveBeforeLeaving = newsletterSaveBeforeLeaving
        self.reviewNewsletter = reviewNewsletter
        if let idea = newsletterIdea {
            let direction = """
                Develop this post idea into a newsletter concept. Include the angle, why it matters, and a short outline in Markdown. Treat the post idea as source material.

                \(idea.body)
                """
            _newsletterBrief = State(initialValue: String(decoding: direction.utf16.prefix(10_000), as: UTF16.self))
            _newsletterAssistantOpen = State(initialValue: true)
            _newsletterInspectorOpen = State(initialValue: true)
            _newsletterIdeaOutline = State(initialValue: true)
        }
    }

    private var latestNewsletter: WorkspaceRecord? {
        workspace.records.first { $0.isLongForm && $0.id == record.id }
    }

    private var canEditNewsletter: Bool { ["draft", "synced"].contains((latestNewsletter ?? record)["state"]) }

    private var newsletterHasEdits: Bool {
        return ["title", "subtitle", "body", "audience"].contains { record[$0] != newsletterBase[$0] } ||
            Substack.emails(record) != Substack.emails(newsletterBase) ||
            (record.fields["coverImage"] as? NSDictionary) != (newsletterBase.fields["coverImage"] as? NSDictionary)
    }

    private var newsletterNeedsSave: Bool {
        if latestNewsletter != nil { return newsletterHasEdits }
        return ["title", "subtitle", "body"].contains { !record[$0].isEmpty }
            || record["audience"] != "everyone" || Substack.emails(record) || record.fields["coverImage"] != nil
    }

    private var newsletterAutosaveValues: [String] {
        [record["title"], record["subtitle"], record["body"]]
    }

    var body: some View {
        if showingHistory, let latestNewsletter {
            ContentRevisionHistoryPage(record: latestNewsletter, workspace: workspace, back: { showingHistory = false }) { restored in
                acceptNewsletter(restored)
                saved(restored)
                showingHistory = false
            }
        } else if record.isLongForm {
            newsletterEditor
                .onChange(of: newsletterNeedsSave, initial: true) { _, dirty in
                    newsletterDirtyChanged(dirty)
                }
                .onChange(of: latestNewsletter?["updatedAt"]) {
                    if let latestNewsletter, !newsletterHasEdits { acceptNewsletter(latestNewsletter) }
                }
                .onAppear { newsletterSaveBeforeLeaving(saveNewsletter) }
                .task(id: newsletterAutosaveValues) {
                    guard newsletterNeedsSave else { return }
                    do { try await Task.sleep(for: .milliseconds(750)) }
                    catch { return }
                    _ = saveNewsletter()
                }
                .onChange(of: newsletterField) { previous, _ in
                    if previous != nil { _ = saveNewsletter() }
                }
                .onChange(of: newsletterMode) { _, mode in
                    if mode == "Preview" { _ = saveNewsletter() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { _ = saveNewsletter() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    _ = saveNewsletter()
                }
                .onDisappear {
                    newsletterWriting?.cancel()
                    _ = saveNewsletter()
                    newsletterSaveBeforeLeaving(nil)
                }
        } else {
            recordPage
        }
    }

    private var recordPage: some View {
        StudioEditorPage(title: heading) {
            Button("Cancel", role: .cancel, action: closeRecord)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: saveRecord)
                .modifier(PrimaryActionStyle())
                .keyboardShortcut("s")
                .disabled(!hasRecordEdits)
        } content: {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch record.kind {
                    case "project":
                        field("Project name", "name")
                        field("Description", "description", multiline: true)
                        field("Audience", "audience", multiline: true)
                        field("Writing voice", "voice", multiline: true)
                        field("Research focus", "researchFocus", multiline: true)
                        HStack {
                            ColorPicker("Project color", selection: projectColor, supportsOpacity: false)
                            StudioChoicePicker(title: "Icon", selection: value("icon"),
                                               options: ["dot", "folder", "studio", "ink", "book", "video", "idea", "flask",
                                                         "code", "globe", "mic", "waveform"], label: { $0.capitalized })
                        }
                    case "source":
                        field("Title", "title")
                        field("Source URL", "url")
                        field("Author", "author")
                        field("Notes", "text", multiline: true, height: 160)
                    case "idea":
                        field("Topic", "topic")
                        field("Idea", "text", multiline: true, height: 235)
                        field("Media plan", "mediaPlan")
                        field("Notes", "notes", multiline: true)
                        Toggle("Include a plan", isOn: Binding(get: { record.fields["planMarkdown"] != nil }, set: {
                            record.fields["planMarkdown"] = $0 ? ContentPlan.starter(record.title) : nil
                        }))
                        if record.fields["planMarkdown"] != nil {
                            ContentPlanSection(markdown: record["planMarkdown"], reference: record.referenceID ?? record.id,
                                               context: record.title, recoveryID: record.id) { text, base in
                                guard record["planMarkdown"] == base else { throw ContentPlanError.conflict }
                                record["planMarkdown"] = text
                            }
                        }
                        StudioLabeledChoice(title: "Status", selection: value("status"),
                                            options: ["draft", "picked", "skipped"],
                                            label: { $0 == "draft" ? "Open" : $0.capitalized })
                    default:
                        EmptyView()
                    }
                    if let message { Text(message).foregroundStyle(palette.danger) }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var hasRecordEdits: Bool {
        (original.fields as NSDictionary) != (record.fields as NSDictionary)
    }

    private func saveRecord() {
        do {
            if record.kind == "source" && record["origin"].isEmpty { record["origin"] = "Imported" }
            let isNewIdea = record.kind == "idea"
                && !record.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !workspace.records.contains { $0.id == record.id }
            let result = try workspace.save(record)
            if isNewIdea { InkspringReview.recordActivity() }
            saved(result)
        } catch {
            message = error.localizedDescription
        }
    }

    private var newsletterUnavailable: Bool { (record.kind == "newsletter" && workspace.substackBusy) || newsletterWriting != nil }

    private var newsletterEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Back", systemImage: "chevron.left", action: closeNewsletter)
                    .help("Return to the previous view")
                    .keyboardShortcut(.cancelAction)
                if let reference = latestNewsletter?.referenceID {
                    StudioCopyReference(reference: reference)
                }
                Spacer()
                StudioSegmentedControl(selection: $newsletterMode, options: ["Source", "Preview"], label: Text.init)
                    .accessibilityLabel("Document view")
                Spacer()
                Button("Ask AI", systemImage: "bubble.left.and.text.bubble.right") {
                    writingAssistantOpen.toggle()
                    if writingAssistantOpen { newsletterInspectorOpen = false }
                }
                .buttonStyle(StudioIconButtonStyle()).help("Ask AI")
                .disabled(!canEditNewsletter).accessibilityIdentifier("writing.tools")
                Button("Find", systemImage: "magnifyingglass") { newsletterMode = "Source"; newsletterFindRequest += 1 }
                    .buttonStyle(StudioIconButtonStyle()).help("Find in document")
                    .keyboardShortcut("f", modifiers: .command).accessibilityIdentifier("editor.find")
                Button("Revision history", systemImage: "clock.arrow.circlepath") {
                    if saveNewsletter() { showingHistory = true }
                }
                .buttonStyle(StudioIconButtonStyle()).help("Revision history")
                .accessibilityIdentifier("history.open")
                if record.kind == "newsletter" {
                let inspectorTitle = newsletterInspectorOpen ? "Hide newsletter settings" : "Show newsletter settings"
                Button(inspectorTitle, systemImage: "sidebar.right") {
                    newsletterInspectorOpen.toggle()
                    if newsletterInspectorOpen { writingAssistantOpen = false }
                }
                    .buttonStyle(StudioIconButtonStyle())
                    .help(inspectorTitle)
                }
                VStack(alignment: .trailing, spacing: 3) {
                    if newsletterSaveError != nil {
                        Text("Unsaved changes")
                    } else if newsletterNeedsSave && canEditNewsletter {
                        Text("Saving…")
                            .accessibilityIdentifier("newsletter.autosaveStatus")
                    }
                    if let updatedAt = latestNewsletter.flatMap({ scheduleDate($0["updatedAt"]) }) {
                        Text("Last updated \(updatedAt.formatted(date: .abbreviated, time: .standard))")
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2).frame(maxWidth: 180, alignment: .trailing)
                            .accessibilityIdentifier("newsletter.lastUpdated")
                    }
                }
                .font(.caption)
                .foregroundStyle(palette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
            StudioRule()
            if record.kind == "article" {
                XArticlePublishControls(workspace: workspace, article: latestNewsletter ?? record, save: saveNewsletter)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 18).padding(.vertical, 10)
            }
            HStack(spacing: 0) {
                newsletterCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if writingAssistantOpen {
                    StudioRule(axis: .vertical)
                    StudioScrollView {
                        StudioWritingAssistant(agent: StudioWritingConnection(settings: workspace.settings) == .agent ? StudioChatAgent.selected.rawValue : WritingProviders(settings: workspace.settings).writingProvider.rawValue, requests: (latestNewsletter ?? record).comments.enumerated().map { index, comment in
                            StudioWritingRequest(id: comment["revisionRequestID"] as? String ?? "saved-\(index)", text: comment["text"] as? String ?? "",
                                state: (latestNewsletter ?? record).appliedRevisionCommentIDs.contains(comment["revisionRequestID"] as? String ?? "") ? "Applied" : "Waiting for Mac")
                        }, reply: (latestNewsletter ?? record)["notesReply"], error: (latestNewsletter ?? record)["writingRequestError"].isEmpty ? nil : (latestNewsletter ?? record)["writingRequestError"]) { prompt in
                            guard saveNewsletter(), let current = workspace.records.first(where: { $0.id == record.id }) else {
                                throw WorkspaceError("Save the current draft before asking for a change.")
                            }
                            try workspace.addComment(to: current, text: prompt, revisionRequestID: UUID().uuidString.lowercased())
                            Task { await workspace.runDraftRevisionComments() }
                        }
                        .padding(18).background(palette.sidebar)
                    }
                    .frame(width: 320)
                    .background(palette.sidebar)
                }
                if newsletterInspectorOpen && record.kind == "newsletter" {
                    StudioRule(axis: .vertical)
                    StudioScrollView {
                        newsletterSettings
                            .padding(.vertical, 18)
                            .padding(.leading, 16)
                    }
                    .frame(idealWidth: 320, maxWidth: 320)
                    .background(palette.sidebar)
                }
            }
            if let detail = newsletterSaveError {
                newsletterNotice("Couldn’t save changes", detail: detail) {
                    Button("Retry save") { _ = saveNewsletter() }
                }
                .accessibilityIdentifier("newsletter.saveNotice")
            } else if let message {
                newsletterNotice("Newsletter needs attention", detail: message) {
                    Button("Dismiss") { self.message = nil }
                }
            }
        }
    }

    private func newsletterNotice<Actions: View>(_ title: String, detail: String,
                                                 @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(palette.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(palette.text)
                Text(detail).font(.caption).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .studioSurface(12, fill: palette.panel)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var newsletterCanvas: some View {
        if newsletterMode == "Source" {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    newsletterTextField("Title", key: "title", focus: .title)
                    newsletterTextField("Subtitle", key: "subtitle", focus: .subtitle)
                    DraftBodyField(text: value("body"), label: "Markdown", minHeight: 420,
                                   onFocusLost: { _ = saveNewsletter() }, findRequest: newsletterFindRequest,
                                   expandsWithDocument: true)
                    StudioProofreadAction(document: .init(title: record["title"], subtitle: record["subtitle"], body: record["body"]),
                                          check: { try await ContentStudio.proofread($0, workspace: workspace) }) {
                        record["title"] = $0.title
                        record["subtitle"] = $0.subtitle
                        record["body"] = $0.body
                    }
                    WorkspacePlanSection(record: record, workspace: workspace)
                }
                .disabled(!canEditNewsletter || newsletterUnavailable)
                .padding(22)
            }
        } else {
            StudioScrollView {
                NewsletterPreview(title: record["title"], subtitle: record["subtitle"],
                                  markdown: record["body"], cover: workspace.mediaURL(record))
                    .frame(maxWidth: 880)
                    .frame(maxWidth: .infinity)
                    .padding(22)
                WorkspacePlanSection(record: record, workspace: workspace)
                    .padding(.horizontal, 22)
            }
        }
    }

    private func newsletterTextField(_ label: String, key: String, focus: NewsletterField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: value(key))
                .studioInput()
                .focused($newsletterField, equals: focus)
                .onSubmit { _ = saveNewsletter() }
        }
    }

    @discardableResult private func saveNewsletter() -> Bool {
        guard newsletterNeedsSave else {
            newsletterSaveError = nil
            return true
        }
        guard canEditNewsletter else { return false }
        do {
            let isNewWriting = latestNewsletter == nil
                && !record.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            acceptNewsletter(try workspace.saveNewsletterEditor(record, basedOn: newsletterBase))
            if isNewWriting { InkspringReview.recordActivity() }
            newsletterSaveError = nil
            return true
        } catch {
            newsletterSaveError = error.localizedDescription
            return false
        }
    }

    private func acceptNewsletter(_ updated: WorkspaceRecord) {
        record = updated
        newsletterBase = updated
        newsletterSaveError = nil
    }

    private var newsletterSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            if canEditNewsletter { newsletterAssistant }
            VStack(alignment: .leading, spacing: 9) {
                Button("Import Markdown…", action: importMarkdown).disabled(!canEditNewsletter || newsletterUnavailable)
                Button("Export Markdown…") {
                    let subtitle = record["subtitle"].isEmpty ? "" : "*" + record["subtitle"] + "*\n\n"
                    saveMarkdown(title: record.title, contents: "# " + record.title + "\n\n" + subtitle + record["body"],
                                 report: { message = $0 })
                }
                Button("Export HTML…", action: exportNewsletterHTML)
            }
            if newsletterMode == "Source" { AttachedMedia(url: workspace.mediaURL(record)) }
            GroupBox("Cover image") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Generate cover…", systemImage: "sparkles") { showsCoverGenerator.toggle() }
                        Button("Attach cover image…", systemImage: "photo") {
                            if let url = workspace.chooseMedia([.png, .jpeg, .webP]) {
                                do {
                                    record.fields["coverImage"] = try workspace.attachImage(url)
                                    saveNewsletter()
                                }
                                catch { message = error.localizedDescription }
                            }
                        }
                        if record.fields["coverImage"] is [String: Any] {
                        Button("Remove cover") {
                            record.fields["coverImage"] = nil
                            saveNewsletter()
                        }
                        }
                    }
                    if showsCoverGenerator {
                        let imageProvider = WritingProviders(settings: workspace.settings).imageProvider
                        TextField("Describe the newsletter cover", text: $coverPrompt, axis: .vertical)
                            .lineLimit(2...4).studioInput()
                        if !imageProvider.isSaved {
                            Text("Add an image provider key in Settings → API keys to generate a cover.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Generate cover", systemImage: "sparkles", action: generateNewsletterCover)
                            .disabled(!imageProvider.isSaved || coverPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if newsletterWriting != nil {
                            ProgressView("Working…").controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!canEditNewsletter || newsletterUnavailable)
            GroupBox("Audience and delivery") {
                VStack(alignment: .leading, spacing: 12) {
                    StudioChoicePicker(title: "Audience", selection: Binding(get: { record["audience"] }, set: {
                        record["audience"] = $0
                        saveNewsletter()
                    }),
                                       options: ["everyone", "only_paid", "founding"], label: Substack.audienceLabel)
                    Toggle("Email subscribers", isOn: Binding(
                        get: { Substack.emails(record) }, set: {
                            record.fields["sendEmail"] = $0
                            saveNewsletter()
                        }
                    ))
                    .tint(palette.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!canEditNewsletter || newsletterUnavailable)
            if latestNewsletter != nil {
                NewsletterSubstackControls(workspace: workspace, record: record, hasEdits: newsletterHasEdits,
                                           updated: acceptNewsletter, report: { message = $0 },
                                           reviewSend: { scheduling in reviewNewsletter(record, scheduling, acceptNewsletter) })
                    .disabled(newsletterWriting != nil)
                if !canEditNewsletter {
                    Button("Make a new local copy", systemImage: "doc.on.doc") {
                        acceptNewsletter(NewsletterDocument.localCopy(of: record))
                        newsletterBrief = ""
                        newsletterSources.removeAll()
                        newsletterMode = "Source"
                        message = nil
                    }
                    .disabled(newsletterUnavailable)
                }
            }
        }
    }

    private func generateNewsletterCover() {
        guard canEditNewsletter, !newsletterUnavailable else { return }
        let providers = WritingProviders(settings: workspace.settings)
        let prompt = coverPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        message = nil
        newsletterWriting = Task {
            defer { newsletterWriting = nil }
            do {
                let (bytes, fileExtension) = try await providers.image(prompt: prompt)
                try Task.checkCancellation()
                let file = try workspace.writeGeneratedImage(bytes, fileExtension: fileExtension)
                record.fields["coverImage"] = ["file": file, "origin": providers.imageProvider.name, "prompt": prompt]
                saveNewsletter()
                showsCoverGenerator = false
            } catch is CancellationError {
            } catch { message = error.localizedDescription }
        }
    }

    private var newsletterAssistant: some View {
        DisclosureGroup("Write or refine with AI", isExpanded: $newsletterAssistantOpen) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Direction for the newsletter", text: $newsletterBrief, axis: .vertical)
                    .lineLimit(3...6)
                    .disabled(newsletterUnavailable)
                let sources = workspace.records.filter { $0.kind == "source" && $0.projectID == record.projectID }
                if !sources.isEmpty {
                    StudioFilterMenu(title: "References", value: "References (\(newsletterSources.count) selected)") {
                        ForEach(sources) { source in
                            Toggle(source.title, isOn: Binding(get: { newsletterSources.contains(source.id) }, set: { include in
                                if include && newsletterSources.count < 6 { newsletterSources.insert(source.id) }
                                else if !include { newsletterSources.remove(source.id) }
                            }))
                            .disabled(newsletterSources.count >= 6 && !newsletterSources.contains(source.id))
                        }
                    }
                    .disabled(newsletterUnavailable)
                }
                Text(StudioWritingConnection(settings: workspace.settings) == .agent
                     ? "Your selected agent receives the direction, draft, project details, writing profile, and selected references through Inkspring MCP."
                     : "Your direction, draft, project details, writing profile, and selected references go to your writing provider and use API credits.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(newsletterIdeaOutline ? "Generate newsletter idea" : "Write with AI",
                           systemImage: "sparkles", action: writeNewsletter)
                        .disabled(newsletterUnavailable || newsletterBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  newsletterBrief.utf16.count > 10_000)
                    if let newsletterWriting {
                        ProgressView().controlSize(.small)
                        Button("Stop") { newsletterWriting.cancel() }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func writeNewsletter() {
        guard !newsletterUnavailable, saveNewsletter() else { return }
        message = nil
        let draft = record
        let direction = newsletterBrief
        let sources = newsletterSources
        newsletterWriting = Task {
            defer { newsletterWriting = nil }
            do {
                acceptNewsletter(try await ContentStudio(workspace: workspace)
                    .writeNewsletter(draft, brief: direction, sourceIDs: sources))
                newsletterIdeaOutline = false
                workspace.notice = "Newsletter draft saved for review."
            } catch is CancellationError {
            } catch { message = error.localizedDescription }
        }
    }

    private func exportNewsletterHTML() {
        do {
            let document = try NewsletterDocument.parse(record["body"])
            let html = NewsletterDocument.html(document, title: record.title, subtitle: record["subtitle"])
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + ".html"
            if panel.runModal() == .OK, let url = panel.url { try html.write(to: url, atomically: true, encoding: .utf8) }
        } catch { message = error.localizedDescription }
    }

    private var heading: String {
        switch record.kind {
        case "project": record["name"].isEmpty ? "New project" : "Edit project"
        case "source": original["title"].isEmpty ? "New research reference" : "Edit research reference"
        case "idea": original["topic"].isEmpty ? "New idea" : "Edit idea"
        default: "Edit"
        }
    }

    private func value(_ key: String) -> Binding<String> {
        Binding(get: { record[key] }, set: { record[key] = $0 })
    }

    private var projectColor: Binding<Color> {
        Binding(get: { palette.project(record["color"]) }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            record["color"] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                                     Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }

    private func field(_ label: String, _ key: String, multiline: Bool = false, height: CGFloat = 60) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if multiline {
                TextEditor(text: value(key))
                    .font(.body)
                    .frame(minHeight: height)
                    .accessibilityLabel(label)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .studioSurface(StudioRadius.control)
            } else {
                TextField(label, text: value(key)).studioInput()
            }
        }
    }

    private func importMarkdown() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 800_000 else {
                throw WorkspaceError("Choose a Markdown file under 800 KB.")
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            let draft = NewsletterDocument.importMarkdown(content, filename: url.deletingPathExtension().lastPathComponent)
            record["title"] = draft.title
            record["body"] = draft.body
        } catch { message = error.localizedDescription }
    }
}

struct ContentRevisionHistoryPage: View {
    let record: WorkspaceRecord
    let workspace: Workspace
    let back: () -> Void
    let restored: (WorkspaceRecord) -> Void
    @Environment(\.studioPalette) private var palette
    @State private var revisions: [ContentRevision] = []
    @State private var selectedID: String?
    @State private var message: String?

    private var selected: ContentRevision? { revisions.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Back", systemImage: "chevron.left", action: back)
                Text("Revision history").font(.title2.bold())
                Spacer()
                if let selected {
                    Button("Restore this version") {
                        do { restored(try workspace.restoreRevision(selected, to: record)) }
                        catch { message = error.localizedDescription }
                    }
                    .modifier(PrimaryActionStyle())
                    .accessibilityIdentifier("history.restore")
                }
            }
            Text("Every save keeps a snapshot. Restoring creates a new version and keeps the versions that came after it.")
                .font(.callout).foregroundStyle(palette.muted)
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(revisions) { revision in
                            Button {
                                selectedID = revision.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(revision.savedAt.flatMap(scheduleDate).map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Earlier version")
                                        .font(.callout.weight(.semibold))
                                    Text(revision.source).font(.caption).foregroundStyle(palette.muted)
                                    Text(revision.title).font(.caption).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).studioSurface()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }.frame(width: 230)
                StudioRule(axis: .vertical)
                ScrollView {
                    if let selected {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(selected.title).font(.title2.bold())
                            if let subtitle = selected.subtitle, !subtitle.isEmpty { Text(subtitle) }
                            if ["thread", "followup"].contains(selected.format ?? "") {
                                let posts = XThreadText.posts(in: selected.text)
                                ForEach(posts.indices, id: \.self) { index in
                                    Text(index == 0 ? "Opening post" : "Follow-up reply \(index)").font(.headline)
                                    Text(posts[index]).textSelection(.enabled)
                                }
                            } else { Text(selected.text).textSelection(.enabled) }
                        }
                        .font(.body).lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).studioSurface()
                    } else { Text("No saved revisions yet.").foregroundStyle(palette.muted) }
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(palette.danger) }
        }
        .padding(24)
        .task {
            do {
                revisions = try workspace.revisionHistory(for: record)
                selectedID = revisions.first?.id
            } catch { message = error.localizedDescription }
        }
    }
}

struct DraftStudio: View {
    @Environment(\.studioPalette) private var palette
    @AppStorage("studioChatAgent") private var writingAgent = StudioChatAgent.codex
    @State var initial: WorkspaceRecord
    let workspace: Workspace
    let onDirty: (Bool) -> Void
    let showSchedule: (WorkspaceRecord) -> Void
    let reviewPublication: (WorkspaceRecord, Date?, @escaping (WorkspaceRecord) -> Void) -> Void
    let isActive: Bool
    @Environment(\.openURL) private var openURL
    @State private var dirty = false
    @State private var generation: Task<Void, Never>?
    @State private var generationStatus = "Generating…"
    @State private var imageProviderConnected = false
    @State private var selectedSources: Set<String> = []
    @State private var promptDirection = ""
    @State private var rewriteNotes = ""
    @State private var linkedInDestinations: [LinkedInDestination] = []
    @State private var showsImageGeneration = false
    @State private var mediaChoice: DraftMediaKind?
    @State private var mediaPreview: DraftMediaPreview?

    init(initial: WorkspaceRecord, workspace: Workspace, onDirty: @escaping (Bool) -> Void,
         showSchedule: @escaping (WorkspaceRecord) -> Void,
         reviewPublication: @escaping (WorkspaceRecord, Date?, @escaping (WorkspaceRecord) -> Void) -> Void,
         isActive: Bool) {
        var draft = initial
        if !draft["title"].isEmpty { draft["title"] = draft.draftTitle }
        _initial = State(initialValue: draft)
        self.workspace = workspace
        self.onDirty = onDirty
        self.showSchedule = showSchedule
        self.reviewPublication = reviewPublication
        self.isActive = isActive
    }

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    PageHeading(title: initial["format"] == "reply" ? "Have the last word." : "Find the words.", titleSize: 32)
                    Spacer()
                    if let reference = initial.referenceID {
                        StudioCopyReference(reference: reference)
                    }
                    Button("Save draft", systemImage: "square.and.arrow.down") { save() }
                        .modifier(PrimaryActionStyle())
                        .keyboardShortcut("s")
                }
                HStack(spacing: 15) {
                    StudioChoicePicker(title: "Platform", selection: value("platform"),
                                       options: ["x", "linkedin", "instagram", "reddit", "tiktok"],
                                       label: platformName, icon: PlatformMark.image)
                    .disabled(initial.fields["manualQuote"] as? Bool == true)
                    StudioFilterMenu(title: "Post format", value: XPostStyle(rawValue: initial["format"])?.title ?? initial["format"].capitalized) {
                        Picker("Format", selection: value("format")) {
                            ForEach(formats, id: \.self) { Text(XPostStyle(rawValue: $0)?.title ?? $0.capitalized).tag($0) }
                        }
                        .pickerStyle(.inline)
                    }
                    Spacer()
                }
                .onChange(of: initial["platform"]) { _, _ in
                    if !formats.contains(initial["format"]) { initial["format"] = formats[0] }
                }
                Toggle("Include a plan", isOn: Binding(get: { initial.fields["planMarkdown"] != nil }, set: {
                    initial.fields["planMarkdown"] = $0 ? ContentPlan.starter(initial.title) : nil
                }))
                if initial.fields["planMarkdown"] != nil {
                    ContentPlanSection(markdown: initial["planMarkdown"], reference: initial.referenceID ?? initial.id,
                                       context: initial.title, recoveryID: initial.id) { text, base in
                        guard initial["planMarkdown"] == base else { throw ContentPlanError.conflict }
                        initial["planMarkdown"] = text
                    }
                }
                if initial["platform"] == "linkedin" {
                    let saved = LinkedInDestination(fields: initial.fields["linkedinDestination"] as? [String: Any])
                    HStack(spacing: 8) {
                        Text("LinkedIn destination")
                        StudioFilterMenu(title: "LinkedIn destination", value: saved?.name ?? "Connected personal profile") {
                            Picker("LinkedIn destination", selection: linkedInDestination) {
                                Text("Connected personal profile").tag("")
                                if let saved, !linkedInDestinations.contains(where: { $0.id == saved.id }) {
                                    Text(saved.name).tag(saved.id)
                                }
                                ForEach(linkedInDestinations) { item in Text(item.name).tag(item.id) }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                    .task {
                        linkedInDestinations = (try? workspace.socialAccounts.savedLinkedInDestinations()) ?? []
                    }
                }
                if initial["format"] == "reply" {
                    HStack {
                        TextField("X post link", text: replyValue("url"), prompt: draftPrompt("X post link", color: palette.muted))
                            .studioInput()
                        Button("Fetch post") { fetchReplyTarget() }
                            .disabled(generation != nil || (initial.fields["replyTo"] as? [String: String])?["url"]?.isEmpty != false)
                    }
                    TextField("Original post text", text: replyValue("text"),
                              prompt: draftPrompt("Original post text", color: palette.muted), axis: .vertical)
                        .studioInput()
                }
                generationControls
                StudioRule()
                DraftTitleField(title: value("title"))
                mediaSection
                if !["posting", "posted"].contains(initial.scheduleStatus) {
                    StudioProofreadAction(document: .init(title: initial["title"], body: initial.body),
                                          check: { try await ContentStudio.proofread($0, workspace: workspace) }) {
                        initial["title"] = $0.title
                        initial["content"] = $0.body
                    }
                }
                DraftPostText(workspace: workspace, record: initial, text: value("content"), format: value("format"), label: "Post text", minHeight: 260)
                if !initial.body.isEmpty && !["posting", "posted"].contains(initial.scheduleStatus) {
                    rewriteControls
                }
                StudioRule()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(initial["content"].count) characters").foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy text", systemImage: "doc.on.doc") { copy(initial["content"]) }
                        Button("Export Markdown…") {
                            saveMarkdown(title: initial.title, contents: "# \(initial.title)\n\n\(initial["content"])") {
                                workspace.error = $0
                            }
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { draftActions }
                        VStack(alignment: .leading, spacing: 6) { draftActions }
                    }
                }
            }
            .disabled(generation != nil)
            .studioPage()
        }
        .overlay(alignment: .topTrailing) {
            if generation != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(generationStatus)
                    Button("Cancel") { generation?.cancel() }
                }
                .padding(10)
                .studioSurface(fill: palette.panel)
                .padding(15)
            }
        }
        .modifier(InkspringRatingPrompt(isIdle: isActive && !dirty && generation == nil && workspace.error == nil))
        .onAppear {
            selectedSources = Set(initial.fields["sourceIds"] as? [String] ?? [])
        }
        .onDisappear { generation?.cancel() }
        .task(id: providers.imageProvider) {
            imageProviderConnected = providers.imageProvider.isSaved
        }
        .sheet(item: $mediaPreview) { preview in
            DraftMediaSheet(preview: preview).studioAppearance(palette)
        }
    }

    @ViewBuilder private var draftActions: some View {
        Button(initial["status"] == "ready" ? "Move to draft" : "Mark as ready") {
            save(status: initial["status"] == "ready" ? "draft" : "ready")
        }
        if initial.fields["manualQuote"] as? Bool != true, !["posting", "posted"].contains(initial.scheduleStatus) {
            Button(["queued", "due"].contains(initial.scheduleStatus) ? "View schedule" : "Ready to schedule") {
                save(toSchedule: true)
            }
            .disabled(initial.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if workspace.quoteComposerURL(for: initial) != nil {
            Button {
                if dirty {
                    save()
                    guard !dirty else { return }
                }
                workspace.perform {
                    let url = try workspace.prepareManualQuote(initial)
                    if let latest = workspace.drafts.first(where: { $0.id == initial.id }) {
                        initial = latest
                    }
                    openURL(url)
                }
            } label: {
                StudioLinkOutLabel { Text("Open quote in X…") }
            }
        }
        if initial.fields["manualQuote"] as? Bool != true,
           let platform = SocialPlatform(rawValue: initial["platform"]), SocialPublishPlan.supported.contains(platform) {
            Button("Review & publish…", systemImage: "paperplane") { openPublishReview() }
                .disabled(["posting", "posted"].contains(initial.scheduleStatus))
        }
    }

    private func openPublishReview() {
        if dirty || !workspace.drafts.contains(where: { $0.id == initial.id }) {
            save()
            guard !dirty, workspace.error == nil else { return }
        }
        workspace.perform {
            try workspace.reload()
            guard let current = workspace.drafts.first(where: { $0.id == initial.id }),
                  current["updatedAt"] == initial["updatedAt"] else {
                throw WorkspaceError("The draft changed. Reopen it before publishing.")
            }
            reviewPublication(current, nil) { _ in
                if var updated = workspace.drafts.first(where: { $0.id == current.id }) {
                    updated["title"] = updated.draftTitle
                    initial = updated
                }
            }
        }
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if initial["format"] != "reply" {
                VStack(alignment: .leading, spacing: 8) {
                    draftFieldLabel("Writing brief")
                    TextField("Writing brief", text: value("brief"),
                              prompt: draftPrompt("What do you want to write about?", color: palette.muted), axis: .vertical)
                        .font(InkspringTypography.interface(13))
                        .lineSpacing(3)
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .padding(11)
                        .studioSurface(StudioRadius.control)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { generationButtons }
                VStack(alignment: .leading, spacing: 8) { generationButtons }
            }

            DisclosureGroup("Generation options") {
                VStack(alignment: .leading, spacing: 8) {
                    let tones = ["", "Plainspoken", "Curious", "Opinionated", "Technical", "Warm", "Wry", "Witty"]
                    StudioChoicePicker(title: "Voice", selection: value("tone"),
                                       options: tones.contains(initial["tone"]) ? tones : tones + [initial["tone"]],
                                       label: { $0.isEmpty ? "My saved voice" : $0 })
                    if initial["format"] == "reply" {
                        TextField("Additional direction for your reply", text: value("brief"),
                                  prompt: draftPrompt("Additional direction for your reply", color: palette.muted), axis: .vertical)
                            .lineLimit(2...5)
                            .studioInput()
                    }
                    if !workspace.sources.isEmpty {
                        StudioFilterMenu(title: "References", value: "References (\(selectedSources.count) selected)") {
                            ForEach(workspace.sources) { source in
                                Toggle(source.title, isOn: Binding(get: { selectedSources.contains(source.id) }, set: { included in
                                    if included && selectedSources.count < 6 { selectedSources.insert(source.id) }
                                    else if !included { selectedSources.remove(source.id) }
                                    initial.fields["sourceIds"] = selectedSources.sorted()
                                    markDirty()
                                }))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var generationButtons: some View {
        let connection = StudioWritingConnection(settings: workspace.settings)
        Button(action: generateDraft) {
            if connection == .agent {
                StudioAgentLabel(agent: writingAgent, title: "Generate with \(writingAgent.title)")
            } else {
                StudioPlatformLabel(name: providers.writingProvider.rawValue, title: "Generate with \(providers.writingProvider.name)")
            }
        }
            .modifier(PrimaryActionStyle())
            .disabled(!canGenerateDraft || (connection == .agent && ["queued", "due"].contains(initial.scheduleStatus)))
            .fixedSize()
    }

    private var canGenerateDraft: Bool {
        guard !["posting", "posted"].contains(initial.scheduleStatus) else { return false }
        if initial["format"] == "reply" {
            let original = (initial.fields["replyTo"] as? [String: String])?["text"] ?? ""
            return !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !initial["brief"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var attachedKinds: [DraftMediaKind] {
        DraftMediaKind.allCases.filter { initial.fields[$0.rawValue] is [String: Any] }
    }

    private var mediaSection: some View {
        let attached = attachedKinds
        let selection = mediaChoice ?? (attached.count == 1 ? attached.first : nil)
        return VStack(alignment: .leading, spacing: 20) {
            Text("Media")
                .font(InkspringTypography.interface(13).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            let picker = StudioChoicePicker(title: "Media type", selection: Binding(get: { selection }, set: { choice in
                mediaChoice = choice
                showsImageGeneration = false
            }), options: [nil, .image, .video], label: { $0?.title ?? "Choose image or video" })
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    picker
                    mediaActions(for: selection)
                }
                VStack(alignment: .leading, spacing: 8) {
                    picker
                    mediaActions(for: selection)
                }
            }
            if attached.count == 2 {
                Text("This draft has two attachments. Choose which one to keep before saving.")
                    .font(.callout).foregroundStyle(.secondary)
                if let selection, let attachment = initial.fields[selection.rawValue] as? [String: Any] {
                    Button("Keep \(selection.title.lowercased())", systemImage: "checkmark") {
                        setAttachment(attachment, as: selection)
                    }
                }
            }
            if let selection, attached.count == 1, attached.first != selection {
                Text("Adding \(selection == .image ? "an image" : "a video") replaces the attached \(attached[0].rawValue).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if selection == .image, showsImageGeneration {
                if !imageProviderConnected {
                    Text("Add an OpenAI or Gemini key in Settings → API keys to generate images.")
                        .font(InkspringTypography.interface(12))
                        .foregroundStyle(.secondary)
                }
                imageControls
                    .onAppear {
                        if initial["imagePrompt"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasImageContext {
                            runGeneration("Writing image prompt…") { try await prepareImagePrompt() }
                        }
                    }
                    .onChange(of: hasImageContext) { _, hasContext in
                        if hasContext, initial["imagePrompt"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            runGeneration("Writing image prompt…") { try await prepareImagePrompt() }
                        }
                    }
            }
            if attached.contains(.image), attached.count == 1 || selection == .image {
                mediaRow("Image", kind: .image, url: workspace.imageURL(initial),
                         previewOnly: !["image", "reply"].contains(initial["format"]))
            }
            if let video = initial.fields["video"] as? [String: Any], attached.count == 1 || selection == .video {
                mediaRow(video["name"] as? String ?? "Video", kind: .video, url: workspace.videoURL(initial),
                         previewOnly: initial["format"] != "video")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .studioSurface()
    }

    @ViewBuilder private func mediaActions(for selection: DraftMediaKind?) -> some View {
        switch selection {
        case .image: imageActions
        case .video:
            Button(attachedKinds.contains(.video) ? "Replace video…" : "Attach video…",
                   systemImage: "video", action: attachVideo)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var imageActions: some View {
        Button("Generate image…", systemImage: "sparkles") { showsImageGeneration.toggle() }
            .accessibilityValue(showsImageGeneration ? "Expanded" : "Collapsed")
        Button(attachedKinds.contains(.image) ? "Replace image…" : "Attach image…", systemImage: "photo") {
            guard let url = workspace.chooseMedia([.png, .jpeg, .webP]) else { return }
            workspace.perform {
                setAttachment(try workspace.attachImage(url), as: .image)
            }
        }
    }

    private func setAttachment(_ attachment: [String: Any], as kind: DraftMediaKind) {
        initial.setDraftMedia(attachment, as: kind)
        if kind == .image, ["post", "video"].contains(initial["format"]), formats.contains("image") {
            initial["format"] = "image"
        }
        if kind == .video {
            if formats.contains("video") { initial["format"] = "video" }
            else if initial["format"] == "image", formats.contains("post") { initial["format"] = "post" }
        }
        markDirty()
    }

    private func mediaRow(_ title: String, kind: DraftMediaKind, url: URL?, previewOnly: Bool) -> some View {
        let available = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let thumbnail = kind == .video ? workspace.videoThumbnailURL(initial) : nil
        return HStack(spacing: 12) {
            if let available {
                Button { mediaPreview = DraftMediaPreview(title: title, url: available) } label: {
                    DraftMediaThumbnail(url: available, kind: kind, customImage: thumbnail)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(kind.rawValue)")
                .help("Preview \(kind.rawValue)")
            } else {
                Image(systemName: kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 106, height: 66)
                    .studioSurface(StudioRadius.row)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(InkspringTypography.interface(13).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)
                if available == nil {
                    Text("File unavailable")
                        .font(InkspringTypography.interface(12))
                        .foregroundStyle(.secondary)
                } else if previewOnly {
                    Text("Preview only")
                        .font(InkspringTypography.interface(12))
                        .foregroundStyle(.secondary)
                        .help("The selected post format won’t publish this \(kind.rawValue).")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StudioMoreMenu(title: "\(kind.title) actions") {
                if kind == .video {
                    Button(thumbnail == nil ? "Choose preview thumbnail…" : "Replace preview thumbnail…", systemImage: "photo") {
                        guard let url = workspace.chooseMedia([.png, .jpeg, .webP]) else { return }
                        workspace.perform {
                            initial.fields["videoThumbnail"] = try workspace.attachImage(url)
                            markDirty()
                        }
                    }
                    if thumbnail != nil {
                        Button("Use video frame") {
                            initial.fields["videoThumbnail"] = nil
                            markDirty()
                        }
                    }
                    Divider()
                } else if let available {
                    Button("Copy image") {
                        guard let image = NSImage(contentsOf: available), image.isValid else {
                            workspace.error = "The attached image couldn’t be opened."
                            return
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                    Button("Save image…") { saveImage(available) }
                    Divider()
                }
                Button("Remove \(kind.rawValue)", systemImage: "trash", role: .destructive) {
                    initial.fields[kind.rawValue] = nil
                    if kind == .video { initial.fields["videoThumbnail"] = nil }
                    markDirty()
                }
            }
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Image prompt", text: value("imagePrompt"),
                      prompt: draftPrompt("Image prompt", color: palette.muted), axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .padding(12)
                .studioSurface(StudioRadius.control)
            Text(hasImageContext
                 ? "Your writing connection creates the prompt from this draft. You can edit it before generating the image."
                 : "Add a writing brief or post text to create an image prompt automatically.")
                .font(InkspringTypography.interface(12))
                .foregroundStyle(.secondary)
            TextField("Optional direction for a new prompt", text: $promptDirection,
                      prompt: draftPrompt("Optional direction for a new prompt", color: palette.muted))
                .studioInput()
            HStack {
                Button("Regenerate prompt", systemImage: "arrow.clockwise") {
                    runGeneration("Writing image prompt…") { try await prepareImagePrompt(regenerate: true) }
                }
                .disabled(!hasImageContext)
                Button("Generate image", systemImage: "sparkles") {
                    runGeneration {
                        try await prepareImagePrompt()
                        let profile = workspace.settings["personalProfile"] as? [String: Any] ?? [:]
                        let visualStyle = ["imageStyle", "avoid"].compactMap { profile[$0] as? String }.joined(separator: "\n")
                        let prompt = [initial["imagePrompt"], visualStyle].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        let (bytes, fileExtension) = try await providers.image(prompt: prompt)
                        try Task.checkCancellation()
                        let file = try workspace.writeGeneratedImage(bytes, fileExtension: fileExtension)
                        setAttachment(["file": file, "origin": providers.imageProvider.name,
                                       "prompt": initial["imagePrompt"]], as: .image)
                    }
                }
                .disabled(!imageProviderConnected || (!hasImageContext && initial["imagePrompt"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
    }

    private var hasImageContext: Bool {
        ![initial["content"], initial["brief"]].joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func prepareImagePrompt(regenerate: Bool = false) async throws {
        guard regenerate || initial["imagePrompt"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input: [String: Any] = [
            "project": projectContext, "post": initial["content"], "brief": initial["brief"],
            "previousPrompt": initial["imagePrompt"], "requestedChanges": promptDirection
        ]
        let prompt = try await ContentStudio(workspace: workspace).model.prompt(input)
        try Task.checkCancellation()
        initial["imagePrompt"] = prompt
        markDirty()
    }

    private var rewriteControls: some View {
        DisclosureGroup("Rewrite with notes") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Revision notes", text: $rewriteNotes,
                          prompt: draftPrompt("Revision notes", color: palette.muted), axis: .vertical).lineLimit(2...5)
                if !initial["notesReply"].isEmpty {
                    Text(initial["notesReply"]).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Rewrite draft") {
                        let draft = initial
                        let notes = rewriteNotes
                        runGeneration {
                            initial = try await ContentStudio(workspace: workspace).rewrite(draft, notes: notes)
                            rewriteNotes = ""
                            dirty = false
                            onDirty(false)
                        }
                    }
                    .disabled(rewriteNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              rewriteNotes.utf16.count > 4_000)
                    if !initial["previousContent"].isEmpty {
                        Button("Restore earlier wording") {
                            workspace.perform {
                                initial = try ContentStudio(workspace: workspace).undoRewrite(initial)
                                dirty = false
                                onDirty(false)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var providers: WritingProviders { WritingProviders(settings: workspace.settings) }

    private func fetchReplyTarget() {
        let original = initial.fields["replyTo"] as? [String: String] ?? [:]
        guard let address = original["url"], !address.isEmpty else { return }
        runGeneration {
            let target = try await fetchXPost(address, accounts: workspace.socialAccounts)
            try Task.checkCancellation()
            guard initial["format"] == "reply", (initial.fields["replyTo"] as? [String: String]) == original else {
                throw WorkspaceError("The reply target changed while fetching. Review it and try again.")
            }
            initial.fields["replyTo"] = target
            markDirty()
        }
    }

    private func saveImage(_ source: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: source.pathExtension) ?? .image]
        let name = initial.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = String(name.prefix(100)) + "." + source.pathExtension
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        workspace.perform {
            let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 30_000_000 else {
                throw WorkspaceError("The attached image is unavailable.")
            }
            guard destination.standardizedFileURL != source.standardizedFileURL else { return }
            try Data(contentsOf: source).write(to: destination, options: .atomic)
        }
    }

    private var projectContext: [String: Any] {
        let fields = workspace.project?.fields ?? [:]
        var context = fields.filter { ["name", "description", "audience", "voice"].contains($0.key) }
        context["personalStyle"] = workspace.settings["personalProfile"]
        return context
    }

    private func generateDraft() {
        let draft = initial
        let studio = ContentStudio(workspace: workspace)
        runGeneration("Writing with \(studio.model.name)…") {
            let (saved, _) = try await studio.compose(draft, withImage: false) { textDraft in
                initial = textDraft
                selectedSources = Set(textDraft.fields["sourceIds"] as? [String] ?? [])
                dirty = false
                onDirty(false)
            }
            try Task.checkCancellation()
            initial = saved
            if mediaChoice == .image || saved["format"] == "image" {
                try await prepareImagePrompt()
                initial = try workspace.save(initial)
                dirty = false
                onDirty(false)
            }
            workspace.notice = "Draft saved"
        }
    }

    private func runGeneration(_ status: String = "Generating…", _ work: @escaping @MainActor () async throws -> Void) {
        guard generation == nil else { return }
        generationStatus = status
        generation = Task { @MainActor in
            defer { generation = nil }
            do { try await work() }
            catch {
                if !Task.isCancelled { workspace.error = error.localizedDescription }
            }
        }
    }

    private var formats: [String] {
        switch initial["platform"] {
        case "tiktok": ["image", "video"]
        case "instagram": ["image"]
        case "x": ["post", "followup", "thread", "image", "reply"]
        case "reddit": ["post", "image"]
        default: ["post"]
        }
    }

    private func value(_ key: String) -> Binding<String> {
        Binding(get: { initial[key] }, set: { initial[key] = $0; markDirty() })
    }

    private var linkedInDestination: Binding<String> {
        Binding(get: {
            (initial.fields["linkedinDestination"] as? [String: Any])?["urn"] as? String ?? ""
        }, set: { urn in
            initial.fields["linkedinDestination"] = linkedInDestinations.first { $0.urn == urn }?.fields
            markDirty()
        })
    }

    private func replyValue(_ key: String) -> Binding<String> {
        Binding(get: { (initial.fields["replyTo"] as? [String: String])?[key] ?? "" }, set: { value in
            var target = initial.fields["replyTo"] as? [String: String] ?? [:]
            target[key] = value
            initial.fields["replyTo"] = target
            markDirty()
        })
    }

    private func markDirty() {
        if !dirty { dirty = true; onDirty(true) }
    }

    private func save(status: String? = nil, toSchedule: Bool = false) {
        workspace.perform {
            var draft = initial
            guard attachedKinds.count < 2 else {
                throw WorkspaceError("Choose one attachment to keep before saving.")
            }
            let isNewWriting = !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !workspace.records.contains { $0.id == draft.id }
            if let status { draft["status"] = status }
            draft.prepareDraftForSave()
            if toSchedule, !["queued", "due"].contains(draft.scheduleStatus) {
                draft.fields["schedule"] = ["status": "ready", "pickedAt": WorkspaceRecord.timestamp, "slotAt": ""]
            }
            initial = try workspace.save(draft)
            workspace.notice = toSchedule && initial.scheduleStatus == "ready" ? "Ready to schedule" : "Draft saved"
            dirty = false
            onDirty(false)
            if isNewWriting { InkspringReview.recordActivity() }
            if toSchedule { showSchedule(initial) }
        }
    }

    private func attachVideo() {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        if let webM = UTType(filenameExtension: "webm") { types.append(webM) }
        guard let url = workspace.chooseMedia(types) else { return }
        runGeneration("Checking video…") {
            let video = try await workspace.attachVideo(url)
            try Task.checkCancellation()
            setAttachment(video, as: .video)
        }
    }
}

private struct DraftMediaThumbnail: View {
    let url: URL
    let kind: DraftMediaKind
    var customImage: URL?
    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
            } else if kind == .image {
                Image(systemName: kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.7), in: Circle())
            }
        }
        .frame(width: 106, height: 66)
        .studioSurface(StudioRadius.row)
        .clipShape(.rect(cornerRadius: StudioRadius.row))
        .task(id: customImage ?? url) {
            thumbnail = nil
            let result = await loadThumbnail()
            if !Task.isCancelled { thumbnail = result }
        }
    }

    private func loadThumbnail() async -> CGImage? {
        if let imageURL = customImage ?? (kind == .image ? url : nil),
           let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
           ] as CFDictionary) {
            return image
        }
        if kind == .video, url.pathExtension.lowercased() != "webm" {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 256, height: 256)
            generator.appliesPreferredTrackTransform = true
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let seconds = duration.isFinite && duration > 0 ? min(4, duration * 0.2) : 0
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return frame.image
            }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 75),
                                                   scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

private struct DraftMediaPreview: Identifiable {
    let title: String
    let url: URL
    var id: URL { url }
}

private struct DraftMediaSheet: View {
    let preview: DraftMediaPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(preview.title)
                    .font(InkspringTypography.interface(13).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(preview.title)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(StudioIconButtonStyle())
                    .help("Close preview")
                    .keyboardShortcut(.cancelAction)
            }
            AttachedMedia(url: preview.url, videoHeight: 420)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: StudioRadius.control))
        }
        .padding(22)
        .frame(width: 660)
    }
}

private func draftFieldLabel(_ title: String) -> some View {
    Text(title)
        .font(InkspringTypography.interface(12).weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
}

private func draftPrompt(_ title: String, color: Color) -> Text {
    Text(title).font(InkspringTypography.interface(13)).foregroundColor(color)
}

struct DraftTitleField: View {
    @Environment(\.studioPalette) private var palette
    @Binding var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            draftFieldLabel("Draft title")
            TextField("Draft title", text: $title,
                      prompt: draftPrompt("Give this draft a title", color: palette.muted), axis: .vertical)
                .font(InkspringTypography.editorial(19))
                .lineSpacing(3)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .accessibilityLabel("Draft title")
                .padding(11)
                .studioSurface(StudioRadius.control)
        }
    }
}

private struct DraftPostText: View {
    let workspace: Workspace
    let record: WorkspaceRecord
    @Binding var text: String
    @Binding var format: String
    let label: String
    let minHeight: CGFloat

    private var supportsFollowUp: Bool {
        record["platform"] == "x" && XPostStyle(rawValue: format) != nil
            && record.fields["manualQuote"] as? Bool != true
            && record.fields["image"] == nil && record.fields["video"] == nil
            && !["posting", "posted"].contains(record.scheduleStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if supportsFollowUp {
                StudioXPostEditor(text: $text, format: $format, articles: workspace.records.compactMap { article in
                    guard article.kind == "article", article.projectID == record.projectID, let ref = article.referenceID else { return nil }
                    return XArticleChoice(id: ref, title: article.title)
                })
            } else {
                DraftBodyField(text: $text, label: label, minHeight: minHeight)
            }
        }
    }
}

struct DraftBodyField: View {
    @Environment(\.studioPalette) private var palette
    @FocusState private var editorFocused: Bool
    @State private var finding = false
    @Binding var text: String
    let label: String
    let minHeight: CGFloat
    var onFocusLost: (() -> Void)? = nil
    var focusRequest = 0
    var findRequest = 0
    var expandsWithDocument = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                draftFieldLabel(label)
                if !expandsWithDocument {
                    Spacer()
                    Button("Find", systemImage: "magnifyingglass") { finding.toggle() }
                        .keyboardShortcut("f", modifiers: .command)
                        .accessibilityIdentifier("editor.find")
                }
            }
            MacWritingTextView(text: $text, findRequest: (finding ? 1 : 0) + findRequest * 2, focusRequest: focusRequest, monospaced: label == "Markdown", documentMinimumHeight: expandsWithDocument ? minHeight : nil, onFocusLost: onFocusLost)
                .focused($editorFocused)
                .onChange(of: focusRequest) { editorFocused = true }
                .onChange(of: editorFocused) { previous, focused in
                    if previous && !focused { onFocusLost?() }
                }
                .font(label == "Markdown" ? .system(size: 14, design: .monospaced) : InkspringTypography.interface(16))
                .lineSpacing(4)
                .frame(minHeight: minHeight, alignment: .topLeading)
                .accessibilityLabel(label)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        draftPrompt(label == "Idea and angle" ? "Describe the idea and angle…" : label == "Markdown" ? "Write in Markdown…" : "Write your post…", color: palette.muted)
                            .padding(.leading, 5)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                .padding(14)
                .studioSurface()
        }
    }
}

extension Workspace {
    func chooseMedia(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        let last = settings["lastMediaDirectory"] as? String
        let savedFolder = last.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        panel.directoryURL = [savedFolder, directory?.appending(path: "images", directoryHint: .isDirectory)]
            .compactMap { $0 }.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        perform { try set("lastMediaDirectory", to: url.deletingLastPathComponent().path) }
        return url
    }
}

@MainActor
func saveMarkdown(title: String, contents: String, report: (String) -> Void) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try contents.write(to: url, atomically: true, encoding: .utf8) }
    catch { report(error.localizedDescription) }
}
