import FoundationModels
import SwiftUI

@available(iOS 26, *)
@Generable
private struct OnDeviceIdeas {
    @Guide(description: "Three distinct, practical post ideas.")
    var ideas: [Idea]

    @Generable
    struct Idea {
        @Guide(description: "Short title, under 100 characters.")
        var title: String
        @Guide(description: "A specific angle in one or two sentences. Avoid inventing facts, sources, or statistics.")
        var angle: String
    }
}

private struct SuggestedIdea: Identifiable {
    let id = UUID()
    let title: String
    let angle: String
}

struct MobileIdeasView: View {
    @Environment(\.mobileWideLayout) private var wideLayout
    private enum Field { case topic, title, angle }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.studioPalette) private var palette
    @State private var projectID: String?
    @FocusState private var focusedField: Field?
    @State private var title = ""
    @State private var bodyText = ""
    @State private var topic = ""
    @State private var suggestions: [SuggestedIdea] = []
    @State private var availabilityMessage: String?
    @State private var generating = false
    @State private var message: String?
    let library: MobileLibrary
    let isSelected: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What would you like ideas about?", text: $topic, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .topic)
                    Button("Generate ideas", systemImage: "sparkles") { Task { await generate() } }
                        .disabled(generating || availabilityMessage != nil || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if generating { ProgressView("Thinking on this device…") }
                    ForEach(suggestions) { idea in
                        Button {
                            title = String(idea.title.prefix(100))
                            bodyText = idea.angle
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(idea.title).font(.headline)
                                Text(idea.angle).foregroundStyle(.secondary)
                                Text("Use this idea").font(.footnote).foregroundStyle(.tint)
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text(availabilityMessage ?? "Ideas are generated on this device. Review and edit them before saving.")
                }
                .listRowBackground(palette.card)

                Section("Save an idea") {
                    if let projects = library.snapshot?.projects, projects.count > 1 {
                        Picker("Project", selection: $projectID) {
                            Text("Default project").tag(String?.none)
                            ForEach(projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                    }
                    TextField("Title", text: $title).focused($focusedField, equals: .title)
                    TextField("Angle or notes", text: $bodyText, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focusedField, equals: .angle)
                    Button("Save idea", systemImage: "plus") { saveIdea() }
                        .disabled(!canSave)
                }
                .listRowBackground(palette.card)

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
                                    Label("Saved · iCloud sync pending", systemImage: "icloud")
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
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 680)
            .mobileCanvas()
            .mobilePageTitle("New ideas", wide: wideLayout, background: palette.canvas)
            .toolbar(wideLayout ? .hidden : .visible, for: .tabBar)
            .refreshable {
                checkAvailability()
                await library.refresh()
            }
            .alert("Inkspring", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .onAppear(perform: checkAvailability)
        .modifier(InkspringRatingPrompt(isIdle: isSelected && focusedField == nil && !generating
                                         && message == nil && !library.busy))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { checkAvailability() }
        }
    }

    private var canSave: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...140).contains(cleanTitle.utf16.count) && (1...2000).contains(cleanText.utf16.count)
    }

    private func checkAvailability() {
        availabilityMessage = Self.generationAvailabilityMessage
    }

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
        let subject = String(topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !subject.isEmpty else { return }
        focusedField = nil
        generating = true
        defer { generating = false }
        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
                Brainstorm three distinct social post ideas about the user's topic. Write in the user's language.
                Suggest practical angles that the writer could develop. Do not make factual claims or invent citations.
                """)
            let response = try await session.respond(to: subject, generating: OnDeviceIdeas.self)
            suggestions = response.content.ideas.prefix(3).compactMap { idea in
                let title = idea.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let angle = idea.angle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !angle.isEmpty else { return nil }
                return SuggestedIdea(title: String(title.prefix(100)), angle: String(angle.prefix(500)))
            }
            if suggestions.isEmpty { message = "No ideas came back. Try a more specific topic." }
        } catch {
            checkAvailability()
            message = "Apple Intelligence couldn’t generate ideas for this topic. Try rephrasing it, or write an idea below."
        }
    }

    private func saveIdea() {
        guard canSave else { return }
        do {
            try library.saveIdea(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 text: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                                 projectID: projectID)
            focusedField = nil
            title = ""
            bodyText = ""
            InkspringReview.recordActivity()
        } catch { message = error.localizedDescription }
    }
}
