import FoundationModels
import SwiftUI

struct MobileIdeasView: View {
    @Environment(\.mobileWideLayout) private var wideLayout
    private enum Field { case title, angle }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.studioPalette) private var palette
    @State private var projectID: String?
    @FocusState private var focusedField: Field?
    @State private var title = ""
    @State private var includesPlan = false
    @State private var bodyText = ""
    @State private var suggestions: [PostIdeaText] = []
    @State private var availabilityMessage: String?
    @State private var generating = false
    @State private var message: String?
    @State private var savedIdeaID: String?
    let library: MobileLibrary
    let isSelected: Bool
    let onSaved: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(library: MobileLibrary, isSelected: Bool, initialProject: String? = nil, onSaved: ((String) -> Void)? = nil) {
        self.library = library
        self.isSelected = isSelected
        self.onSaved = onSaved
        _projectID = State(initialValue: initialProject)
    }

    var body: some View {
        NavigationStack {
            ideaForm
            .frame(maxWidth: 680)
            .mobileCanvas()
            .mobilePageTitle(onSaved == nil ? "New ideas" : "Draft a new idea",
                             wide: wideLayout && onSaved == nil, background: palette.canvas)
            .toolbar(wideLayout ? .hidden : .visible, for: .tabBar)
            .toolbar {
                if onSaved != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
            .refreshable {
                checkAvailability()
                await library.refresh()
            }
            .navigationDestination(item: $savedIdeaID) { id in
                if let snapshot = library.snapshot, let item = library.visibleItems.first(where: { $0.id == id }) {
                    MobileReviewDetail(item: item, library: library, workspaceID: snapshot.workspaceID)
                } else if let idea = library.pendingIdeas.first(where: { $0.id.uuidString.lowercased() == id }) {
                    Form {
                        Section {
                            Text(idea.title).font(.headline)
                            Text(idea.text).textSelection(.enabled)
                        } footer: {
                            Text("Saved on this device. Connect your Mac to create platform drafts from this idea.")
                        }
                        .listRowBackground(palette.card)
                    }
                    .scrollContentBackground(.hidden)
                    .mobileCanvas()
                    .navigationTitle("Idea")
                }
            }
            .alert("Inkspring", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .onAppear(perform: checkAvailability)
        .onChange(of: editorText) { suggestions = [] }
        .modifier(InkspringRatingPrompt(isIdle: isSelected && focusedField == nil && !generating
                                         && message == nil && !library.busy))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { checkAvailability() }
        }
    }

    private var ideaForm: some View {
        ScrollViewReader { scroll in
            Form {
                captureForm
                if !suggestions.isEmpty {
                    Section("Suggested ideas") {
                        ForEach(suggestions, id: \.self) { idea in
                            Button {
                                title = idea.title
                                bodyText = idea.body
                                focusedField = nil
                                suggestions = []
                                withAnimation { scroll.scrollTo(Field.title, anchor: .top) }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(idea.title).font(.headline)
                                    Text(idea.body).foregroundStyle(.secondary)
                                    Label("Use this idea", systemImage: "arrow.up.left")
                                        .font(.footnote).foregroundStyle(.tint)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("idea.suggestion")
                        }
                    }
                    .listRowBackground(palette.card)
                }
                if onSaved == nil { recentlySaved }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder private var recentlySaved: some View {
        if !library.pendingIdeas.isEmpty {
            Section("Recently saved") {
                ForEach(library.pendingIdeas) { idea in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(idea.title).font(.headline)
                        Text(idea.text).textSelection(.enabled)
                        if let error = idea.error {
                            Label(error, systemImage: "exclamationmark.icloud")
                        } else if library.snapshot?.pending.contains(where: { $0.id == idea.id }) == true {
                            Label("Saved to iCloud", systemImage: "checkmark")
                        } else {
                            Label(library.snapshot == nil ? "Saved on this device" : "Saved · iCloud sync pending", systemImage: "icloud")
                        }
                    }
                    .font(.footnote)
                    .padding(.vertical, 3)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Skip", systemImage: "trash") {
                            do { try library.skipPendingIdea(idea) }
                            catch { message = error.localizedDescription }
                        }.tint(palette.iconAccent)
                    }
                    .contextMenu {
                        Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = idea.text }
                        Button("Skip idea", systemImage: "trash") {
                            do { try library.skipPendingIdea(idea) }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
            }
            .listRowBackground(palette.card)
        }
    }

    private var captureForm: some View {
        Section {
            if let projects = library.snapshot?.projects, projects.count > 1 {
                Picker("Project", selection: $projectID) {
                    Text("Default project").tag(String?.none)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
            }
            TextField("Title", text: $title, prompt: Text("Give the idea a working title"))
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit { focusedField = .angle }
                .accessibilityIdentifier("idea.new.title")
                .id(Field.title)
            TextField("Angle or notes", text: $bodyText,
                      prompt: Text("What do you want to say, and why does it matter?"), axis: .vertical)
                .lineLimit(3...8)
                .focused($focusedField, equals: .angle)
                .accessibilityIdentifier("idea.new.angle")
            Button {
                focusedField = nil
                Task { await generate() }
            } label: {
                Label("Generate ideas", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(generating || availabilityMessage != nil || editorText.isEmpty)
            if generating { ProgressView("Thinking on this device…") }
            StudioProofreadAction(document: .init(title: title, body: bodyText),
                                  unavailable: MobileProofreading.availabilityMessage,
                                  begin: { focusedField = nil }, reviewInSheet: true,
                                  check: MobileProofreading.check) { title = $0.title; bodyText = $0.body }
            if library.snapshot?.supportsContentPlans == true {
                Toggle("Include a plan", isOn: $includesPlan)
            }
            Button("Save idea", systemImage: "plus") { saveIdea() }
                .disabled(!editorText.canSaveOnMobile)
        } header: {
            Text("Save an idea")
        } footer: {
            Text(availabilityMessage ?? "Apple Intelligence rewrites your notes on this device. Review and edit your selection before saving.")
        }
        .listRowBackground(palette.card)
    }

    private var editorText: PostIdeaText {
        PostIdeaText(title: title, body: bodyText)
    }

    private func checkAvailability() {
#if DEBUG
        if Self.usesSuggestionFixture {
            availabilityMessage = nil
            return
        }
#endif
        availabilityMessage = Self.generationAvailabilityMessage
    }

#if DEBUG
    private static var usesSuggestionFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--idea-suggestions-fixture")
    }
#endif

    static var generationAvailabilityMessage: String? {
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This device doesn’t support Apple Intelligence. You can still write and save ideas."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to generate ideas."
            case .unavailable(.modelNotReady): return "Apple Intelligence is getting ready. Try again when the model finishes downloading."
            case .unavailable: return "Apple Intelligence is unavailable. You can still write and save ideas."
            }
        } else {
            return "Idea generation needs Apple Intelligence on iOS or iPadOS 26 or later. You can still write and save ideas."
        }
    }

    private func generate() async {
        checkAvailability()
        guard #available(iOS 26, *), availabilityMessage == nil, !generating else { return }
        let source = editorText
        guard !source.isEmpty else { return }
        suggestions = []
        generating = true
        defer { generating = false }
        do {
            let generated = try await generateSuggestions(for: source)
            guard editorText == source else { return }
            suggestions = generated
            if generated.isEmpty {
                message = "No usable ideas came back. Try again or keep editing your notes."
            }
        } catch {
            checkAvailability()
            message = "Apple Intelligence couldn’t generate ideas from these notes. Try again or keep editing."
        }
    }

    @available(iOS 26, *)
    private func generateSuggestions(for source: PostIdeaText) async throws -> [PostIdeaText] {
#if DEBUG
        if Self.usesSuggestionFixture {
            return [
                PostIdeaText(title: "Private chats sent to the wrong people", body: source.body),
                PostIdeaText(title: "Classic Facebook", body: "Classic Facebook. " + source.body)
            ]
        }
#endif
        return try await PostIdeaWriting.onDeviceSuggestions(for: source)
    }

    private func saveIdea() {
        let idea = editorText
        guard idea.canSaveOnMobile else { return }
        do {
            let id = try library.saveIdea(title: idea.title, text: idea.body,
                                 projectID: projectID, plan: includesPlan ? ContentPlan.starter(idea.title) : nil)
            focusedField = nil
            title = ""
            bodyText = ""
            includesPlan = false
            InkspringReview.recordActivity()
            if let onSaved { onSaved(id) }
            else { savedIdeaID = id }
        } catch { message = error.localizedDescription }
    }
}
