import InkspringSchedule
import ServiceManagement
import SwiftUI

struct WorkspaceSettings: View {
    let workspace: Workspace
    @Environment(\.studioPalette) private var palette
    @State private var section: String
    private let sections = [
        ("Appearance", "circle.lefthalf.filled"),
        ("Voice & projects", "text.quote"),
        ("Ideas & sources", "lightbulb"),
        ("Preferred schedules", "calendar"),
        ("AI models", "sparkles"),
        ("AI agents", "bubble.left.and.text.bubble.right"),
        ("API keys", "key"),
        ("Connections", "link"),
        ("Storage & backups", "externaldrive"),
        ("Support", "questionmark.circle")
    ]

    init(workspace: Workspace, initialSection: String = "Appearance") {
        self.workspace = workspace
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "Settings")
                .padding(.top, 24)
                .padding(.horizontal, 24)
            HStack(alignment: .top, spacing: 0) {
                sectionList
                    .frame(width: 164)
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                StudioRule(axis: .vertical)
                settingsContent.id(section)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: 1120, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(sections, id: \.0) { title, icon in
                Button { section = title } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .foregroundStyle(palette.iconAccent)
                            .frame(width: 17)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(InkspringTypography.interface(13).weight(section == title ? .semibold : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(section == title ? palette.text : palette.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioRowStyle(selected: section == title, indicator: true))
                .accessibilityAddTraits(section == title ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private var settingsContent: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if section != "Appearance" {
                    Text(section)
                        .font(InkspringTypography.editorial(26, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                }
                switch section {
                case "Appearance": StudioThemeSettings(workspace: workspace)
                case "AI models": ModelPreferences(workspace: workspace)
                case "Preferred schedules": preferredSchedules
                case "API keys":
                    SetupHelpLink("API key setup and troubleshooting", topic: "api-keys")
                    Text("OpenAI and Gemini keys enable image generation. Anthropic, OpenAI, and Gemini keys also support optional API writing. Apify and X keys fetch public research and posts.")
                        .foregroundStyle(.secondary)
                    ForEach(ProviderKey.allCases) { ProviderKeyRow(provider: $0, workspace: workspace) }
                case "Ideas & sources":
                    GroupBox("Automatic idea refill") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Refill ideas while Inkspring is open", isOn: Binding(get: {
                                workspace.settings["ideaQueueAutomatic"] as? Bool == true
                            }, set: { enabled in
                                workspace.perform { try workspace.set("ideaQueueAutomatic", to: enabled) }
                            }))
                            StudioLabeledChoice(title: "Target number of open ideas", selection: Binding(
                                get: { IdeaQueuePlan.target(workspace.settings["ideaQueueTarget"]) },
                                set: { value in workspace.perform { try workspace.set("ideaQueueTarget", to: value) } }
                            ), options: IdeaQueuePlan.targets, label: { $0.formatted() })
                            Text("Refill pauses at your target. You can keep adding ideas yourself.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    VaultSettings(workspace: workspace)
                    WorkSourceSettings(workspace: workspace)
                case "Storage & backups":
                    BackupControls(workspace: workspace)
                    CompanionSyncSettings(workspace: workspace)
                    R2Settings(workspace: workspace)
                case "Connections":
                    SetupHelpLink("Connection setup and troubleshooting", topic: "connections")
                    GroupBox("LinkedIn") {
                        DeveloperConnectionSettings(workspace: workspace, platform: .linkedin, initiallyExpanded: true)
                    }
                    .task { workspace.perform { try workspace.socialAccounts.loadSavedConnections() } }
                case "AI agents":
                    AgentSettings(workspace: workspace)
                case "Support":
                    InkspringSupport()
                default:
                    PersonalProfileSettings(workspace: workspace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }

    private var preferredSchedules: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set the hours and default posting minute for each platform. iPhone and iPad use these hours in your Mac’s time zone.")
                .foregroundStyle(.secondary)
            ForEach(SocialPlatform.allCases) { platform in
                let key = platform.rawValue
                let window = workspace.postingWindow(for: key)
                let minute = workspace.postingMinute(for: key)
                VStack(alignment: .leading, spacing: 10) {
                    StudioPlatformLabel(name: key, title: platform.name).font(.headline)
                    StudioLabeledChoice(title: "First posting hour", selection: Binding(
                        get: { window.firstHour },
                        set: { updateSchedule(key, window: CompanionPostingWindow(firstHour: $0, lastHour: window.lastHour), minute: minute) }
                    ), options: Array(0...23), label: postingHourLabel)
                    StudioLabeledChoice(title: "Last posting hour", selection: Binding(
                        get: { window.lastHour },
                        set: { updateSchedule(key, window: CompanionPostingWindow(firstHour: window.firstHour, lastHour: $0), minute: minute) }
                    ), options: Array(window.firstHour...23), label: postingHourLabel)
                    StudioLabeledChoice(title: "Posting minute", selection: Binding(
                        get: { minute },
                        set: { updateSchedule(key, window: window, minute: $0) }
                    ), options: Array(-1...59), label: { $0 < 0 ? "Choose automatically" : String(format: ":%02d", $0) })
                }
                .padding(14)
                .studioSurface()
            }
        }
    }

    private func postingHourLabel(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?
            .formatted(date: .omitted, time: .shortened) ?? String(format: "%02d:00", hour)
    }

    private func updateSchedule(_ platform: String, window: CompanionPostingWindow, minute: Int) {
        workspace.perform { try workspace.setPostingPreferences(for: platform, window: window, minute: minute) }
    }
}

private struct StudioThemeSettings: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace

    private var selection: StudioTheme { StudioTheme(preference: workspace.settings[StudioTheme.preferenceKey]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Appearance")
                    .font(InkspringTypography.editorial(26, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader)
                Text("Choose how Inkspring looks on this Mac.").foregroundStyle(palette.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                ForEach([StudioTheme.graphite, .paper, .light]) { theme in
                    choice(theme)
                }
            }
            Toggle("Follow macOS light/dark appearance", isOn: Binding(
                get: { selection == .system },
                set: { choose($0 ? .system : .light) }
            ))

        }
        .frame(maxWidth: 725, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    private func choice(_ theme: StudioTheme) -> some View {
        let swatch = StudioPalette(theme: theme)
        let active = selection == theme
        return Button { choose(theme) } label: {
            VStack(alignment: .leading, spacing: 10) {
                themePreview(swatch)
                HStack {
                    Text(theme.title).fontWeight(.semibold)
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.iconAccent)
                        .opacity(active ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioSurface(fill: active ? palette.active : palette.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func themePreview(_ swatch: StudioPalette) -> some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(swatch.iconAccent).frame(width: 20, height: 3)
                Capsule().fill(swatch.muted).frame(width: 16, height: 2)
                Capsule().fill(swatch.muted).frame(width: 11, height: 2)
            }
            .frame(width: 40, height: 66)
            .background(swatch.sidebar)

            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(swatch.text).frame(width: 42, height: 4)
                Rectangle().fill(swatch.line).frame(height: 1)
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(swatch.active).frame(height: 8)
                        RoundedRectangle(cornerRadius: 2).fill(swatch.well).frame(height: 6)
                    }
                    .frame(width: 25)
                    RoundedRectangle(cornerRadius: 3).fill(swatch.card)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(swatch.line))
                }
            }
            .padding(.trailing, 7)
            .padding(.vertical, 9)
        }
        .frame(height: 66)
        .background(swatch.canvas)
        .clipShape(.rect(cornerRadius: StudioRadius.row))
        .accessibilityHidden(true)
    }

    private func choose(_ theme: StudioTheme) {
        guard selection != theme else { return }
        workspace.perform { try workspace.set(StudioTheme.preferenceKey, to: theme.rawValue) }
    }
}

struct ProviderKeyRow: View {
    let provider: ProviderKey
    let workspace: Workspace
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        GroupBox {
            HStack {
                SecureField(saved ? "Replace key" : "API key", text: $key).studioInput()
                Button("Save key") {
                    workspace.perform {
                        try provider.save(key)
                        key = ""
                        saved = true
                    }
                }
                .disabled(key.isEmpty)
                if saved {
                    Button("Remove") {
                        workspace.perform {
                            try provider.remove()
                            saved = false
                        }
                    }
                }
                StudioExternalLink("Get a key", destination: provider.managementURL)
                SetupHelpLink("Setup help", topic: "key-" + provider.rawValue,
                              description: "\(provider.name) API key setup and troubleshooting")
            }
        } label: {
            Label {
                Text(saved ? "\(provider.name) · saved in Keychain" : provider.name)
            } icon: {
                PlatformMark(name: provider.rawValue, fallback: "square.stack.3d.up")
            }
        }
        .onAppear { saved = provider.isSaved }
    }
}

struct ModelPreferences: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    @AppStorage("studioChatAgent") private var agent = StudioChatAgent.codex
    private let catalog = ProviderCatalog.bundled
    @State private var checking = false
    @State private var checkMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let connection = StudioWritingConnection(settings: workspace.settings)
            StudioLabeledChoice(title: "Writing connection", selection: Binding(get: { connection }, set: { value in
                workspace.perform { try workspace.set(StudioWritingConnection.preferenceKey, to: value.rawValue) }
            }), options: [.agent, .api], label: { $0 == .agent ? "Connected agent (MCP)" : "Provider API key" })
            if connection == .agent {
                StudioLabeledChoice(title: "Writing agent", selection: $agent,
                                    options: [.claude, .codex], label: { $0.title },
                                    icon: { StudioAgentMark.menuImage($0, palette: palette) })
                Text("Uses your agent’s signed-in session. Enable access in Settings → AI agents.")
                    .font(.caption).foregroundStyle(.secondary)
                SetupHelpLink("Writing agent setup and troubleshooting", topic: "writing-agent")
            } else {
                SetupHelpLink("API key setup and troubleshooting", topic: "api-keys")
                StudioLabeledChoice(title: "Writing provider", selection: setting("provider"),
                                    options: ["anthropic", "openai", "gemini"], label: { ProviderKey(rawValue: $0)?.name ?? $0 },
                                    icon: PlatformMark.image)
                let provider = WritingProviders(settings: workspace.settings).writingProvider
                let models = switch provider {
                case .openai: catalog?.openai
                case .gemini: catalog?.gemini
                default: catalog?.anthropic
                }
                modelPicker("Writing model", key: provider.rawValue + "Model", models: models ?? [])
                if provider == .anthropic {
                    HStack {
                        StudioAgentMark(agent: .claude)
                        TextField("Claude workspace ID (optional)", text: setting("anthropicWorkspaceId")).studioInput()
                    }
                }
            }
            HStack {
                Button("Test writing connection") { Task { await checkWritingConnection() } }
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
            if let checkMessage { Text(checkMessage).font(.caption).foregroundStyle(.secondary) }
            StudioRule()
            StudioLabeledChoice(title: "Image provider", selection: setting("imageProvider"),
                                options: ["openai", "gemini"], label: { $0 == "openai" ? "OpenAI" : "Gemini" },
                                icon: PlatformMark.image)
            Text("Generating image files uses an OpenAI or Gemini API key. Writing the image prompt uses your writing connection.")
                .font(.caption).foregroundStyle(.secondary)
            let gemini = setting("imageProvider").wrappedValue == "gemini"
            modelPicker("Image model", key: gemini ? "geminiImageModel" : "openaiImageModel",
                        models: (gemini ? catalog?.geminiImage : catalog?.openaiImage) ?? [],
                        providerIcon: gemini ? "gemini" : "openai")
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func checkWritingConnection() async {
        guard !checking else { return }
        checking = true
        checkMessage = nil
        defer { checking = false }
        do {
            if StudioWritingConnection(settings: workspace.settings) == .agent {
                let model = ContentStudio(workspace: workspace).model
                let response = try await model.object("Return exactly the JSON object {\"ok\": true}.", [:])
                guard response["ok"] as? Bool == true else {
                    throw WorkspaceError("The agent returned an unexpected connection check response.")
                }
                checkMessage = "\(model.name) completed the writing check through Inkspring MCP."
            } else {
                let providers = WritingProviders(settings: workspace.settings)
                try await providers.checkWritingConnection()
                checkMessage = "\(providers.writingProvider.name) accepted the key for \(providers.writingModel)."
            }
        } catch {
            checkMessage = error.localizedDescription
        }
    }

    private func setting(_ key: String) -> Binding<String> {
        Binding(get: { workspace.settings[key] as? String ?? catalog?.defaults[key] ?? "" },
                set: { value in workspace.perform { try workspace.set(key, to: value) } })
    }

    private func modelPicker(_ label: String, key: String, models: [ProviderCatalog.Model],
                             providerIcon: String? = nil) -> some View {
        let current = setting(key)
        let ids = models.map(\.id)
        return StudioLabeledChoice(title: label, selection: current,
                                   options: ids.contains(current.wrappedValue) ? ids : [current.wrappedValue] + ids,
                                   label: { id in models.first(where: { $0.id == id })?.name ?? (id.isEmpty ? "Default" : id) },
                                   icon: { id in
                                       if let providerIcon { return PlatformMark.image(providerIcon) }
                                       return id.hasPrefix("claude-") ? StudioAgentMark.menuImage(.claude, palette: palette) : nil
                                   })
    }
}

struct PersonalProfileSettings: View {
    let workspace: Workspace
    @State private var profile: [String: Any] = [:]
    @State private var savedProfile: [String: Any] = [:]
    @State private var hashtags = ""
    @State private var learning: Task<Void, Never>?
    @State private var showingHistory = false
    @State private var history: [WorkspaceRecord] = []
    @State private var selectedSamples: Set<String> = []
    @State private var sampleError: String?
    @State private var reviewedSuggestion: WorkspaceRecord?
    @State private var needsSave = false

    private var hasSamples: Bool {
        !(profile["samples"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasChanges: Bool {
        needsSave || reviewedSuggestion != nil || NSDictionary(dictionary: profile) != NSDictionary(dictionary: savedProfile)
            || hashtags != (savedProfile["hashtags"] as? [String] ?? []).joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
            VStack(alignment: .leading, spacing: 12) {
            Text("Personal profile").font(.headline)
            TextField("Writing style", text: field("voice"), axis: .vertical).studioInput()
            TextField("Visual style", text: field("imageStyle"), axis: .vertical).studioInput()
            TextField("Interests", text: field("interests"), axis: .vertical).studioInput()
            TextField("What to avoid", text: field("avoid"), axis: .vertical).studioInput()
            TextField("Writing samples", text: field("samples"), axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .padding(12)
                .studioSurface(StudioRadius.control)
            HStack {
                Button("Choose from published drafts…") {
                    history = PersonalProfile.publishedDrafts(in: workspace.records)
                    selectedSamples = []
                    sampleError = nil
                    showingHistory = true
                }
                Button("Suggest my voice", systemImage: "sparkles", action: learnVoice)
                    .disabled(!hasSamples)
                if learning != nil { ProgressView().controlSize(.small) }
            }
            Text(hasSamples
                 ? "Your selected writing connection uses these samples to suggest a profile for you to review."
                 : "Paste a writing sample or choose a published draft to enable Suggest my voice.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Hashtags, separated by commas", text: $hashtags).studioInput()
            }
            }
            GroupBox("Research sources for post ideas") {
                VStack(alignment: .leading, spacing: 10) {
                Text("Choose which feeds Inkspring can use when suggesting post ideas.")
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 8) {
                ForEach(PersonalProfile.sourceNames, id: \.self) { source in
                    Toggle(isOn: Binding(get: {
                        (profile["researchSources"] as? [String] ?? ["x", "news"]).contains(source)
                    }, set: { enabled in
                        var sources = Set(profile["researchSources"] as? [String] ?? ["x", "news"])
                        if enabled { sources.insert(source) } else { sources.remove(source) }
                        profile["researchSources"] = Array(sources)
                    })) {
                        Label { Text(platformName(source)) } icon: { PlatformMark(name: source, fallback: "newspaper") }
                    }
                }
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(reviewedSuggestion == nil ? "Save profile" : "Save reviewed profile", action: save)
                    .modifier(PrimaryActionStyle())
                    .disabled(!hasChanges)
                if hasChanges { Button("Reload saved profile", action: reload) }
            }
            if let reviewedSuggestion {
                Text("Review the suggested profile from \(reviewedSuggestion["origin"].isEmpty ? "your agent" : reviewedSuggestion["origin"]).")
                    .font(.caption).foregroundStyle(.secondary)
            } else if needsSave {
                Text("Review the suggested voice, interests, and things to avoid, then save your profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SuggestionInbox(workspace: workspace, reviewProfile: loadSuggestion) { item in
                if reviewedSuggestion?.id == item.id { reviewedSuggestion = nil }
            }
        }
        .disabled(learning != nil)
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear(perform: reload)
        .onDisappear { learning?.cancel() }
        .sheet(isPresented: $showingHistory) { samplePicker }
    }

    private var samplePicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose writing samples").font(.title2)
            if history.isEmpty {
                ContentUnavailableView("No published drafts", systemImage: "text.document",
                                       description: Text("You can paste your own examples in Writing samples."))
                    .frame(maxWidth: .infinity)
            } else {
                StudioScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(history) { draft in
                            Toggle(isOn: Binding(get: { selectedSamples.contains(draft.id) }, set: { selected in
                                if selected { selectedSamples.insert(draft.id) } else { selectedSamples.remove(draft.id) }
                                sampleError = nil
                            })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.title + " · " + platformName(draft["platform"])).font(.headline)
                                    Text(draft.body).lineLimit(5).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            }
            if let sampleError { Text(sampleError).foregroundStyle(.red) }
            HStack {
                Button("Cancel", role: .cancel) { showingHistory = false }
                Spacer()
                Button("Add selected examples") {
                    do {
                        profile["samples"] = try PersonalProfile.samples(appending: history.filter { selectedSamples.contains($0.id) },
                                                                          to: profile["samples"] as? String ?? "")
                        showingHistory = false
                    } catch { sampleError = error.localizedDescription }
                }
                .disabled(selectedSamples.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private func learnVoice() {
        guard learning == nil else { return }
        let samples = profile["samples"] as? String ?? ""
        let studio = ContentStudio(workspace: workspace)
        learning = Task { @MainActor in
            defer { learning = nil }
            do {
                let suggestion = try await studio.learnWritingStyle(from: samples)
                try Task.checkCancellation()
                for (key, value) in suggestion { profile[key] = value }
                needsSave = true
            } catch {
                if !Task.isCancelled { workspace.error = error.localizedDescription }
            }
        }
    }

    private func save() {
        workspace.perform {
            var draft = profile
            draft["hashtags"] = hashtags.split(separator: ",").map(String.init)
            try workspace.savePersonalProfile(draft, replacing: savedProfile, suggestionID: reviewedSuggestion?.id)
            reload()
            workspace.notice = "Profile saved"
        }
    }

    private func loadSuggestion(_ item: WorkspaceRecord) {
        guard let proposal = item.fields["profile"] as? [String: Any] else { return }
        profile = proposal
        hashtags = (proposal["hashtags"] as? [String] ?? []).joined(separator: ", ")
        reviewedSuggestion = item
        needsSave = false
    }

    private func reload() {
        profile = workspace.settings["personalProfile"] as? [String: Any] ?? [:]
        savedProfile = profile
        hashtags = (profile["hashtags"] as? [String] ?? []).joined(separator: ", ")
        reviewedSuggestion = nil
        needsSave = false
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(get: { profile[key] as? String ?? "" }, set: { profile[key] = $0 })
    }
}

private struct SuggestionInbox: View {
    let workspace: Workspace
    let reviewProfile: (WorkspaceRecord) -> Void
    let dismissed: (WorkspaceRecord) -> Void

    var body: some View {
        let pending = workspace.records.filter { $0.kind == "personal-inbox" && $0["status"] == "pending" }
        if !pending.isEmpty {
            Divider()
            Text("Ideas from your agent").font(.headline)
            ForEach(pending) { suggestion in
                GroupBox(suggestion["kind"] == "profile" ? "Profile suggestion" : suggestion.title) {
                    VStack(alignment: .leading, spacing: 8) {
                        if suggestion["kind"] == "profile", let profile = suggestion.fields["profile"] as? [String: Any] {
                            ForEach(PersonalProfile.textLimits.keys.sorted(), id: \.self) { key in
                                if let value = profile[key] as? String, !value.isEmpty {
                                    LabeledContent(key == "imageStyle" ? "Visual style" : key.capitalized) { Text(value) }
                                }
                            }
                        } else {
                            Text(suggestion["summary"]).textSelection(.enabled)
                        }
                        HStack {
                            if suggestion["kind"] == "profile" {
                                Button("Review suggested profile") { reviewProfile(suggestion) }
                            } else {
                                Button("Accept") { review(suggestion, accept: true) }
                            }
                            Button("Dismiss") { review(suggestion, accept: false) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func review(_ item: WorkspaceRecord, accept: Bool) {
        workspace.perform {
            try workspace.reviewSuggestion(item.id, accept: accept)
            if !accept { dismissed(item) }
        }
    }
}

struct WorkspaceConnections: View {
    @Environment(\.studioPalette) private var palette

    private enum ConnectionCheck {
        case verified(String)
        case failed(String)
    }

    let workspace: Workspace
    @State private var disconnecting: SocialPlatform?
    @State private var loading = false
    @State private var testing: SocialPlatform?
    @State private var connectionChecks: [SocialPlatform: ConnectionCheck] = [:]

    private var accounts: ManagedSocialAccounts { workspace.socialAccounts }

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PageHeading(title: "Your channels. Your call.",
                                subtitle: "Manage the accounts Inkspring can use for publishing and analytics.")
                    Spacer()
                    SetupHelpLink("Connection help", topic: "connections")
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(loading || accounts.connecting != nil || testing != nil)
                }
                ForEach(SocialPlatform.allCases) { platform in
                    GroupBox {
                        HStack {
                            if let profile = accounts.profiles[platform] {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                                        Text("Connected").fontWeight(.semibold)
                                    }
                                    .foregroundStyle(palette.success)
                                    Text(profile.displayName).foregroundStyle(palette.muted)
                                }
                                Spacer()
                                if testing == platform || accounts.connecting == platform { ProgressView().controlSize(.small) }
                                Button("Test connection") { Task { await testConnection(platform) } }
                                    .disabled(testing != nil || accounts.connecting != nil)
                                Button("Reconnect…") { Task { await connect(platform, developerApp: profile.usesDeveloperApp) } }
                                    .disabled(accounts.connecting != nil || testing != nil)
                                Button("Disconnect…") { disconnecting = platform }
                                    .disabled(accounts.connecting != nil || testing != nil)
                            } else if platform == .linkedin {
                                let sharedSignIn = accounts.availability.contains(.linkedin)
                                let canConnect = sharedSignIn || accounts.developerAppIDs[.linkedin] != nil
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(canConnect ? "Connect your LinkedIn profile" : "Set up LinkedIn posting")
                                        .fontWeight(.semibold)
                                    Text(canConnect
                                         ? "Sign in to LinkedIn and give Inkspring permission to publish as you."
                                         : "Save your developer app credentials below, then sign in to your LinkedIn profile.")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if accounts.connecting == platform { ProgressView().controlSize(.small) }
                                if canConnect {
                                    Button("Connect LinkedIn…") {
                                        Task { await connect(.linkedin, developerApp: !sharedSignIn) }
                                    }
                                    .help("Open LinkedIn to sign in and approve publishing access for your profile.")
                                    .disabled(accounts.connecting != nil || loading || testing != nil)
                                }
                            } else {
                                Text(accounts.availability.contains(platform) ? "Sign in with Inkspring" : "Shared sign-in unavailable")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if accounts.connecting == platform { ProgressView().controlSize(.small) }
                                Button("Connect…") { Task { await connect(platform) } }
                                    .disabled(accounts.connecting != nil || loading || !accounts.availability.contains(platform))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let check = connectionChecks[platform] {
                            switch check {
                            case let .verified(name):
                                Label("Verified account \(name)", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            case let .failed(message):
                                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            }
                        }
                        DeveloperConnectionSettings(
                            workspace: workspace, platform: platform,
                            showsConnectButton: platform != .linkedin || accounts.availability.contains(.linkedin)
                                || accounts.profiles[.linkedin] != nil
                        )
                            .padding(.top, 7)
                        if platform == .linkedin && accounts.profiles[.linkedin] != nil {
                            Button("Refresh LinkedIn company pages") {
                                Task {
                                    do { try await accounts.refreshLinkedInPages() }
                                    catch { workspace.error = error.localizedDescription }
                                }
                            }
                            ForEach(accounts.linkedInDestinations) { page in
                                Text(page.name).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Label { Text(platform.name) } icon: { PlatformMark(name: platform.rawValue) }
                    }
                }
                SubstackConnectionSettings(workspace: workspace)
                PublishingHistory(workspace: workspace)
            }
            .studioPage()
        }
        .task { await load() }
        .onChange(of: accounts.profiles) { old, new in
            for platform in SocialPlatform.allCases where old[platform] != new[platform] {
                connectionChecks[platform] = nil
            }
        }
        .confirmationDialog("Disconnect this social account?", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }
        )) {
            Button("Disconnect", role: .destructive) {
                guard let platform = disconnecting else { return }
                workspace.perform { try accounts.disconnect(platform) }
                disconnecting = nil
            }
        }
    }

    private func connect(_ platform: SocialPlatform, developerApp: Bool = false) async {
        connectionChecks[platform] = nil
        do { try await accounts.connect(platform, developerApp: developerApp) }
        catch is CancellationError {}
        catch { workspace.error = error.localizedDescription }
    }

    private func testConnection(_ platform: SocialPlatform) async {
        guard testing == nil else { return }
        testing = platform
        connectionChecks[platform] = nil
        defer { testing = nil }
        do {
            let profile = try await accounts.testConnection(platform)
            if platform == .tiktok {
                let creator = try await SocialPublisher(workspace: workspace).tikTokCreator()
                let directPost = creator.privacy.contains("PUBLIC_TO_EVERYONE")
                    ? "Direct Post allows Everyone"
                    : "Direct Post has no Everyone option"
                connectionChecks[platform] = .verified(profile.displayName + " · " + directPost)
            } else {
                connectionChecks[platform] = .verified(profile.displayName)
            }
        } catch is CancellationError {
        } catch {
            if accounts.profiles[platform] != nil { connectionChecks[platform] = .failed(error.localizedDescription) }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { try await accounts.load() }
        catch { workspace.error = error.localizedDescription }
    }
}

struct AboutInkspring: View {
    @Environment(\.studioPalette) private var palette

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead
                InkspringSupportButton()
                InkspringSupportCards()
                VStack(spacing: 16) {
                    StudioRule()
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            siteLinks
                            Spacer(minLength: 24)
                            copyright
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                siteLinks
                                VStack(alignment: .leading, spacing: 8) {
                                    ProtomotaProductPill()
                                    projectLinks
                                }
                            }
                            copyright
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: 980)
            .studioPage()
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 24) {
                InkspringBrandIcon(width: 100, height: 88, radius: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Inkspring")
                        .font(InkspringTypography.editorial(48, relativeTo: .largeTitle))
                        .accessibilityAddTraits(.isHeader)
                    Text("Your private studio for research and writing.")
                        .font(InkspringTypography.interface(15))
                        .foregroundStyle(palette.muted)
                }
            }
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                Text("Version \(version) (\(build))")
                    .font(InkspringTypography.interface(12).weight(.medium))
                    .foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(25)
        .studioSurface(22, fill: palette.panel)
    }

    private var siteLinks: some View {
        HStack(spacing: 12) {
            ProtomotaProductPill()
            projectLinks
        }
    }

    private var projectLinks: some View {
        HStack(spacing: 8) {
            Link(destination: URL(string: "https://inkspring.ai/")!) {
                StudioLinkOutLabel { Label("Inkspring website", systemImage: "globe") }
            }
            Link(destination: URL(string: "https://github.com/protomota/inkspring")!) {
                StudioLinkOutLabel { Label("View source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
        }
    }

    private var copyright: some View { InkspringCopyright() }
}

private struct InkspringBrandIcon: View {
    @Environment(\.studioPalette) private var palette
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .renderingMode(.original)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: radius))
                .shadow(color: palette.dark ? .white.opacity(0.14) : .black.opacity(0.18),
                        radius: palette.dark ? 10 : 8, x: 0, y: palette.dark ? 0 : 4)
                .accessibilityHidden(true)
        }
    }
}

private struct ProtomotaProductPill: View {
    var body: some View {
        Link(destination: URL(string: "https://protomota.com/")!) {
            HStack(spacing: 8) {
                if let url = Bundle.main.url(forResource: "protomota-logo", withExtension: "png"),
                   let logo = NSImage(contentsOf: url) {
                    Image(nsImage: logo)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .clipShape(.rect(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                Text("A Protomota Product")
                    .font(InkspringTypography.interface(13).weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.medium))
                    .accessibilityHidden(true)
            }
            .fixedSize()
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(.black, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.14)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Visit protomota.com")
    }
}

private struct InkspringCopyright: View {
    @Environment(\.studioPalette) private var palette

    var body: some View {
        Text("© 2026 Protomota")
            .font(InkspringTypography.interface(12))
            .foregroundStyle(palette.muted)
    }
}

private struct InkspringSupport: View {
    @Environment(\.studioPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                InkspringBrandIcon(width: 66, height: 58, radius: 15)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inkspring")
                        .font(InkspringTypography.editorial(30, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                    Text("A private studio for research and writing.")
                        .font(InkspringTypography.interface(13))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .studioSurface(18, fill: palette.panel)

            InkspringSupportButton()
            InkspringSupportCards()

            StudioRule()
            ViewThatFits(in: .horizontal) {
                HStack {
                    ProtomotaProductPill()
                    Spacer(minLength: 12)
                    InkspringCopyright().fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    ProtomotaProductPill()
                    InkspringCopyright()
                }
            }
        }
    }
}

private struct InkspringSupportCards: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Link(destination: InkspringCommunity.support) {
                StudioLinkOutLabel { Label("Get App Help", systemImage: "questionmark.circle") }
            }
            Link(destination: InkspringCommunity.websiteHelp) {
                StudioLinkOutLabel { Label("Setup and Troubleshooting", systemImage: "book") }
            }
            Text("Get personal help with Inkspring on Mac, iPhone, and iPad, including desktop setup, iCloud sync, and MCP connections.")
                .font(.callout)
                .foregroundStyle(palette.muted)
            communityCards
        }
    }

    private var communityCards: some View {
        SupportCardLayout {
            card("Support Inkspring", detail: "Leave an optional tip to support development.",
                 symbol: "cup.and.saucer", action: "Buy me a coffee", url: InkspringCommunity.tips, tracked: .tip)
            card("Feedback", detail: "Tell us what works and what could be better.",
                 symbol: "bubble.left.and.bubble.right", action: "Send Feedback", url: InkspringCommunity.feedback, tracked: .feedback)
            card("Protomota newsletter", detail: "Get new releases and notes from the studio.",
                 symbol: "envelope", action: "Get product updates", url: InkspringCommunity.newsletter)
        }
    }

    private func card(_ title: String, detail: String, symbol: String, action: String, url: URL,
                      tracked: InkspringSupportReminder.Action? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.iconAccent)
                .frame(width: 36, height: 36)
                .background(palette.well, in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            Text(title)
                .font(InkspringTypography.interface(14).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(InkspringTypography.interface(13))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button {
                if let tracked { InkspringSupportReminder.record(tracked) }
                openURL(url)
            } label: {
                StudioLinkOutLabel { Text(action) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 172, maxHeight: .infinity, alignment: .topLeading)
        .studioSurface(18)
    }
}

private struct InkspringSupportButton: View {
    @Environment(\.studioPalette) private var palette
    @State private var isPresented = false

    var body: some View {
        Button("Tip, share, or send feedback", systemImage: "heart") { isPresented = true }
            .sheet(isPresented: $isPresented) {
                InkspringSupportSheet(isReminder: false)
                    .studioAppearance(palette)
            }
    }
}

struct InkspringSupportSheet: View {
    let isReminder: Bool
    @Environment(\.studioPalette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @AppStorage(InkspringSupportReminder.actionsKey) private var clicks = ""
    @AppStorage(InkspringSupportReminder.optedOutKey) private var optedOut = false
    @State private var sharePicker = InkspringSupportSharePicker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                InkspringBrandIcon(width: 66, height: 58, radius: 15)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free software.\nSupported by people.")
                        .font(InkspringTypography.editorial(26, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                    Text("Help more people discover Inkspring and tell us what we can improve.")
                        .foregroundStyle(palette.muted)
                }
            }
            VStack(spacing: 8) {
                Button { visit(.tip, url: InkspringCommunity.tips) } label: {
                    row("Buy me a coffee", detail: "Leave an optional tip", symbol: "cup.and.saucer", action: .tip)
                }
                Button { visit(.feedback, url: InkspringCommunity.feedback) } label: {
                    row("Send feedback", detail: "Tell us what’s working and what could be better",
                        symbol: "bubble.left.and.bubble.right", action: .feedback)
                }
                Button {
                    sharePicker.show {
                        if InkspringSupportReminder.record(.share), isReminder { dismiss() }
                    }
                } label: {
                    row("Share Inkspring", detail: "Send someone a link to the app",
                        symbol: "square.and.arrow.up", action: .share)
                }
                .background(InkspringShareAnchor(view: sharePicker.anchor).allowsHitTesting(false))
                Button { visit(.support, url: InkspringCommunity.support) } label: {
                    row("Open a Support Ticket", detail: "Get help or follow replies for Mac, iPhone, and iPad",
                        symbol: "headphones", action: .support)
                }
                Button { visit(.apps, url: InkspringCommunity.apps) } label: {
                    row("More Free Apps by Protomota", detail: "Explore more free apps from our studio",
                        symbol: "arrow.up.forward.app", action: .apps)
                }
            }
            .buttonStyle(SupportActionRowStyle())
            Text("Checkmarks show which buttons you’ve opened.")
                .font(.caption)
                .foregroundStyle(palette.muted)
            StudioRule()
            HStack {
                if isReminder {
                    Button("Don’t remind me again") {
                        optedOut = true
                        dismiss()
                    }
                }
                Spacer()
                Button(isReminder ? "Later" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(palette.canvas)
    }

    private func visit(_ action: InkspringSupportReminder.Action, url: URL) {
        let finished = InkspringSupportReminder.record(action)
        openURL(url)
        if finished, isReminder { dismiss() }
    }

    private func row(_ title: String, detail: String, symbol: String,
                     action: InkspringSupportReminder.Action) -> some View {
        let clicked = InkspringSupportReminder.clicked(clicks).contains(action)
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(palette.iconAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: clicked ? "checkmark.circle.fill" : "arrow.up.right")
                .foregroundStyle(palette.iconAccent)
                .accessibilityLabel(clicked ? "Previously opened" : "Open")
        }
        .padding(12)
        .contentShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct SupportActionRowStyle: ButtonStyle {
    @Environment(\.studioPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        if palette.theme == .paper {
            configuration.label.studioPaperControl(in: RoundedRectangle(cornerRadius: 12),
                                                   fill: configuration.isPressed ? palette.hover : palette.control)
        } else {
            configuration.label.studioSurface(12, fill: configuration.isPressed ? palette.hover : palette.card)
        }
    }
}

private struct InkspringShareAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class InkspringSupportSharePicker: NSObject, NSSharingServicePickerDelegate {
    let anchor = NSView()
    private var picker: NSSharingServicePicker?
    private var finished: (() -> Void)?

    func show(finished: @escaping () -> Void) {
        guard picker == nil, anchor.window != nil else { return }
        let picker = NSSharingServicePicker(items: [InkspringCommunity.website])
        self.picker = picker
        self.finished = finished
        picker.delegate = self
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        Task { @MainActor in self.complete() }
    }

    private func complete() {
        let completion = finished
        finished = nil
        picker = nil
        completion?()
    }
}

private struct SupportCardLayout: Layout {
    private let gap: CGFloat = 14
    private let minimumCardWidth: CGFloat = 190

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 3 * minimumCardWidth + 2 * gap
        let metrics = measure(width: width, subviews: subviews)
        let rows = metrics.inRow ? 1 : subviews.count
        return CGSize(width: width, height: metrics.height * CGFloat(rows) + gap * CGFloat(max(0, rows - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = measure(width: bounds.width, subviews: subviews)
        for (index, card) in subviews.enumerated() {
            let x = metrics.inRow ? CGFloat(index) * (metrics.width + gap) : 0
            let y = metrics.inRow ? 0 : CGFloat(index) * (metrics.height + gap)
            card.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: metrics.width, height: metrics.height))
        }
    }

    private func measure(width: CGFloat, subviews: Subviews) -> (width: CGFloat, height: CGFloat, inRow: Bool) {
        let count = CGFloat(subviews.count)
        let gutters = gap * max(0, count - 1)
        let inRow = width >= minimumCardWidth * count + gutters
        let cardWidth = inRow ? (width - gutters) / max(1, count) : width
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height }.max() ?? 0
        return (cardWidth, height, inRow)
    }
}

struct BackupControls: View {
    let workspace: Workspace
    @State private var backgroundStatus: SMAppService.Status = .notRegistered
    @State private var backingUp = false
    @State private var cloudStatus: ICloudBackup.UploadStatus?

    private var dailyEnabled: Bool { workspace.settings[DailyBackup.enabledKey] as? Bool == true }
    private var folder: String { workspace.settings[DailyBackup.folderKey] as? String ?? "" }
    private var lastError: String { workspace.settings[DailyBackup.lastErrorKey] as? String ?? "" }
    private var lastBackupPath: String { workspace.settings[DailyBackup.lastFileKey] as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            manual
            daily
        }
        .onAppear(perform: refreshStatus)
        .onChange(of: workspace.settings[DailyBackup.registrationKey] as? String) { _, _ in refreshStatus() }
        .task(id: lastBackupPath) { await checkCloudStatus(path: lastBackupPath) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
            Task { await workspace.checkDailyBackup() }
        }
    }

    private var manual: some View {
        GroupBox("Workspace backup") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save your projects, writing, research, and local media in a ZIP. Restore it on any Mac running Inkspring.")
                HStack {
                    Button("Export Backup…", systemImage: "square.and.arrow.up") { workspace.exportBackup() }
                    Button("Import / Restore…", systemImage: "square.and.arrow.down") {
                        Task { await workspace.restoreBackup() }
                    }
                    .disabled(workspace.restoringBackup || workspace.importingWorkspaceFolder)
                    if workspace.restoringBackup { ProgressView().controlSize(.small).accessibilityLabel("Preparing backup restore") }
                }
                HStack {
                    Button("Import Workspace Folder…", systemImage: "folder") {
                        Task { await workspace.importWorkspaceFolder() }
                    }
                    .disabled(workspace.importingWorkspaceFolder || workspace.restoringBackup)
                    if workspace.importingWorkspaceFolder {
                        ProgressView().controlSize(.small).accessibilityLabel("Preparing workspace import")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
        }
    }

    private var daily: some View {
        GroupBox("Daily backups") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Back up once a day", isOn: Binding(get: { dailyEnabled }, set: {
                    workspace.setDailyBackupEnabled($0)
                    refreshStatus()
                }))
                .disabled(folder.isEmpty)
                HStack {
                    Text(folder.isEmpty ? "Choose where to save daily ZIP files." : folder)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose folder…") { workspace.chooseDailyBackupFolder() }
                }
                if FileManager.default.fileExists(atPath: ICloudBackup.drive.path) {
                    Button("Choose iCloud Drive…", systemImage: "icloud") {
                        workspace.chooseDailyBackupFolder(startingAt: ICloudBackup.drive)
                    }
                }
                if dailyEnabled && backgroundStatus == .enabled {
                    Text("Runs at 3:00 a.m. while you’re signed in. Inkspring retries later if the backup folder was unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if dailyEnabled {
                    Text("Inkspring checks for a daily backup while it’s open. Allow Inkspring in Login Items to run backups while it’s closed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !DailyBackup.usesTestWorkspace {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                HStack {
                    Button("Back Up Now", systemImage: "arrow.clockwise") {
                        backingUp = true
                        Task {
                            await workspace.checkDailyBackup(requested: true)
                            backingUp = false
                        }
                    }
                    .disabled(folder.isEmpty || backingUp)
                    if backingUp { ProgressView().controlSize(.small) }
                }
                if let value = workspace.settings[DailyBackup.lastSuccessKey] as? String,
                   let date = scheduleDate(value) {
                    HStack {
                        Text("Last backup \(date.formatted(date: .abbreviated, time: .shortened))")
                        if !lastBackupPath.isEmpty {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastBackupPath)])
                            }
                        }
                    }
                    .font(.callout)
                }
                if let cloudStatus { uploadLabel(cloudStatus) }
                if !lastError.isEmpty {
                    Label(lastError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if dailyEnabled, let error = workspace.backupRegistrationError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
        }
    }

    private func refreshStatus() {
        guard !DailyBackup.usesTestWorkspace else { return }
        backgroundStatus = DailyBackup.service.status
    }

    private func checkCloudStatus(path: String) async {
        cloudStatus = nil
        guard !path.isEmpty else { return }
        let file = URL(fileURLWithPath: path)
        while !Task.isCancelled {
            let status = await Task.detached(priority: .utility) { ICloudBackup.uploadStatus(of: file) }.value
            guard !Task.isCancelled else { return }
            cloudStatus = status
            if status == nil { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    @ViewBuilder private func uploadLabel(_ status: ICloudBackup.UploadStatus) -> some View {
        switch status {
        case .uploaded:
            Label("Uploaded to iCloud Drive", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
        case .waiting:
            Label("Waiting for iCloud Drive to upload", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
        case .unavailable:
            Label("The iCloud Drive backup is unavailable", systemImage: "exclamationmark.icloud").foregroundStyle(.secondary)
        case .excluded:
            Label("This ZIP is excluded from iCloud sync", systemImage: "exclamationmark.icloud").foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.icloud").foregroundStyle(.red)
        }
    }
}


private struct DeveloperConnectionSettings: View {
    let workspace: Workspace
    let platform: SocialPlatform
    let showsConnectButton: Bool
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var pages = false
    @State private var expanded = false

    private var accounts: ManagedSocialAccounts { workspace.socialAccounts }

    init(workspace: Workspace, platform: SocialPlatform, initiallyExpanded: Bool = false, showsConnectButton: Bool = true) {
        self.workspace = workspace
        self.platform = platform
        self.showsConnectButton = showsConnectButton
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if platform == .linkedin {
                if accounts.connecting == .linkedin {
                    Text("Finish signing in on LinkedIn. Click Allow if asked, then choose Return to Inkspring.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                SetupHelpLink("LinkedIn setup guide", topic: "connect-linkedin")
            }
            DisclosureGroup(platform == .linkedin ? "LinkedIn developer app credentials" : "Use your own developer app",
                            isExpanded: $expanded) {
                developerAppFields
                    .padding(.top, 7)
            }
        }
        .onChange(of: expanded, initial: true) { _, open in
            if open {
                clientID = accounts.developerAppIDs[platform] ?? ""
                pages = platform == .linkedin && accounts.developerPages
            } else {
                clientSecret = ""
            }
        }
        .onChange(of: accounts.developerAppIDs[platform]) { old, new in
            if expanded && (clientID.isEmpty || clientID == old) {
                clientID = new ?? ""
                pages = platform == .linkedin && accounts.developerPages
            }
        }
    }

    private var developerAppFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if platform == .linkedin {
                Text("Your Client ID and secret identify your developer app. You’ll approve access to your profile separately on LinkedIn.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                StudioExternalLink("Open LinkedIn My Apps", destination: platform.developerConsole)
            } else {
                SetupHelpLink("\(platform.name) setup and troubleshooting", topic: "connect-" + platform.rawValue)
            }
            LabeledContent("Authorized redirect URL") {
                Text(platform.developerCallback.absoluteString).textSelection(.enabled)
                Button("Copy") { copy(platform.developerCallback.absoluteString) }
            }
            TextField(platform == .tiktok ? "Client key" : "Client ID", text: $clientID)
                .studioInput()
            if platform != .reddit {
                SecureField(platform.needsClientSecret ? "Client secret" : "Client secret (optional)", text: $clientSecret)
                    .studioInput()
            }
            if platform == .linkedin {
                Toggle("Request company Page access", isOn: $pages)
                    .help("Requires LinkedIn Community Management approval and a role on the Page.")
                Text("For a personal profile, leave company Page access off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Save developer app") {
                    workspace.perform {
                        try accounts.saveDeveloperApp(platform, input: DeveloperOAuthConfiguration(
                            clientID: clientID, clientSecret: clientSecret, linkedInPages: pages
                        ))
                        clientSecret = ""
                        workspace.notice = "Developer app saved"
                    }
                }
                .disabled(clientID.isEmpty || accounts.connecting != nil)
                if showsConnectButton {
                    Button(platform == .linkedin ? "Connect LinkedIn with this app…" : "Connect developer app…") {
                        Task {
                            do { try await accounts.connect(platform, developerApp: true) }
                            catch is CancellationError {}
                            catch { workspace.error = error.localizedDescription }
                        }
                    }
                    .disabled(accounts.developerAppIDs[platform] == nil || accounts.connecting != nil)
                }
            }
        }
    }
}
