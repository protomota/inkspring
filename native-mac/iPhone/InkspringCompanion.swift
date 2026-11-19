import CloudKit
import SwiftUI

@main
struct InkspringCompanion: App {
    var body: some Scene {
        WindowGroup { MobileHome() }
    }
}

private struct MobileHome: View {
    private enum Tab: CaseIterable {
        case review, ideas, schedule, settings
        var title: String {
            switch self {
            case .review: "Review"
            case .ideas: "New ideas"
            case .schedule: "Schedule"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .review: "tray"
            case .ideas: "lightbulb"
            case .schedule: "calendar"
            case .settings: "gearshape"
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("inkspring.mobile.theme") private var theme = StudioTheme.defaultPreference
    @State private var library = MobileLibrary()
    @State private var tips = MobileTipStore()
    @StateObject private var technicalSupport = InkspringSupportStore()
    @State private var tab = Self.startingTab

    @AppStorage("inkspring.mobile.completedWelcome", store: MobileLibrary.preferences) private var completedWelcome = MobileHome.previouslyUsed
    @State private var reviewingSetup = false

    private static let previouslyUsed: Bool = {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--library-fixture") { return true }
        if ProcessInfo.processInfo.arguments.contains("--unpaired-fixture") { return false }
#endif
        return ["inkspring.mobile.libraryOutbox.v1", "inkspring.mobile.localIdeas.v1", "inkspring.mobile.draftSort"]
            .contains { UserDefaults.standard.object(forKey: $0) != nil }
    }()

    private func finishWelcome(_ destination: Tab) {
        tab = destination
        completedWelcome = true
        reviewingSetup = false
    }

    private static var startingTab: Tab {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ideas-fixture") { return .ideas }
        if arguments.contains("--schedule-fixture") { return .schedule }
#endif
        return .review
    }

    var body: some View {
        let palette = StudioPalette(theme: theme.resolve(for: colorScheme))
        Group {
            if !completedWelcome || reviewingSetup {
                MobileWelcomeView(connected: library.snapshot != nil, replay: reviewingSetup,
                                  write: { finishWelcome(.ideas) },
                                  enter: { finishWelcome(reviewingSetup ? tab : .review) })
            } else {
                mainLayout(palette: palette)
            }
        }
        .environment(\.studioPalette, palette)
        .labelStyle(StudioIconLabelStyle())
        .environment(tips)
        .environmentObject(technicalSupport)
        .task(id: technicalSupport.verifiedSupportPurchaseID) {
            if let purchase = technicalSupport.verifiedSupportPurchaseID {
                tips.recordVerifiedSupport(purchase)
            }
        }
        .task { await tips.observeTransactions() }
        .task { await tips.recoverPurchases() }
        .preferredColorScheme(theme == .system ? nil : palette.colorScheme)
        .tint(palette.accent)
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            library.accountChanged()
            Task { await library.refresh() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await library.refresh()
                do { try await Task.sleep(for: .seconds(25)) }
                catch { return }
            }
        }
    }

    private func mainLayout(palette: StudioPalette) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 800 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Inkspring").font(.headline).padding(.horizontal, 12).padding(.bottom, 18)
                        ForEach(Tab.allCases, id: \.self) { destination in
                            Button { tab = destination } label: {
                                Label {
                                    Text(destination.title)
                                } icon: {
                                    Image(systemName: destination.icon)
                                        .foregroundStyle(navigationIconColor(for: destination, palette: palette))
                                }
                                    .font(.body.weight(tab == destination ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(tab == destination ? palette.well : .clear, in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(tab == destination ? .isSelected : [])
                        }
                        Spacer()
                    }
                    .padding(16).padding(.top, 20)
                    .frame(width: 205)
                    .background(palette.card)
                    Divider()
                }
                compactTabs(palette: palette)
                    .environment(\.mobileWideLayout, geometry.size.width >= 800)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func compactTabs(palette: StudioPalette) -> some View {
        TabView(selection: $tab) {
            MobileReviewView(library: library, isSelected: tab == .review, writeIdea: { tab = .ideas },
                             openSetup: { reviewingSetup = true }, openSettings: { tab = .settings })
                .tabItem { tabLabel(.review, palette: palette) }
                .tag(Tab.review)
            MobileIdeasView(library: library, isSelected: tab == .ideas)
                .tabItem { tabLabel(.ideas, palette: palette) }
                .tag(Tab.ideas)
            CompanionScheduleView(library: library, isSelected: tab == .schedule)
                .tabItem { tabLabel(.schedule, palette: palette) }
                .tag(Tab.schedule)
            MobileSettingsView(theme: $theme, library: library, openSetup: { reviewingSetup = true })
                .tabItem { tabLabel(.settings, palette: palette) }
                .tag(Tab.settings)
        }
    }

    private func navigationIconColor(for destination: Tab, palette: StudioPalette) -> Color {
        if tab == destination { return palette.iconAccent }
        return palette.dark ? .white : .black
    }

    private func tabLabel(_ destination: Tab, palette: StudioPalette) -> some View {
        Label {
            Text(destination.title)
        } icon: {
            if let symbol = UIImage(systemName: destination.icon) {
                let color = navigationIconColor(for: destination, palette: palette)
                Image(uiImage: symbol.withTintColor(UIColor(color), renderingMode: .alwaysOriginal))
            }
        }
    }
}

private struct MobileWelcomeView: View {
    @Environment(\.studioPalette) private var palette
    let connected: Bool
    let replay: Bool
    let write: () -> Void
    let enter: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Image("InkspringBrand").resizable().scaledToFit().frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 15)).shadow(color: .black.opacity(0.13), radius: 5, y: 2)
                        .accessibilityHidden(true)
                    Text("Welcome to Inkspring").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Save an idea here as soon as it comes to you. Connect Inkspring on your Mac to edit posts and newsletters, work on scripts, and schedule posts on the go.")
                        .foregroundStyle(palette.muted)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label("Set up your Mac", systemImage: "desktopcomputer").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Open Inkspring on a Mac signed in to the same Apple Account as this device.")
                    Link("Get Inkspring for Mac ↗", destination: URL(string: "https://inkspring.ai/download")!)
                        .font(.subheadline.weight(.semibold))
                    Divider()
                    Text("In Inkspring on your Mac, open **Settings** and choose **Storage & backups → iPhone and iPad**. Turn on **schedule sync**, then **library sync**.")
                    Text("Keep your Mac awake with Inkspring open for the first sync and when you want scheduled posts to go out.")
                        .font(.subheadline).foregroundStyle(palette.muted)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.card, in: .rect(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(palette.line) }
                VStack(spacing: 8) {
                    Button(action: connected || replay ? enter : write) {
                        Text(replay ? "Done" : connected ? "Open my workspace" : "Write my first idea")
                            .font(.headline).foregroundStyle(palette.accentText).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
                        .accessibilityIdentifier("welcome.primary")
                    if !replay {
                        Button(connected ? "Write an idea" : "Continue to workspace", action: connected ? write : enter)
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                }
            }.foregroundStyle(palette.text).frame(maxWidth: 500).padding(24)
                .frame(maxWidth: .infinity)
        }.background(palette.canvas.ignoresSafeArea())
    }
}

private struct CompanionScheduleView: View {
    let library: MobileLibrary
    let isSelected: Bool
    @Environment(\.mobileWideLayout) private var wideLayout
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.studioPalette) private var palette
    @State private var state = CompanionScheduleViewState()
    @State private var cloudStore: CloudScheduleStore?
    @State private var candidate: CompanionPost?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if state.schedule != nil || !library.pendingSchedules.isEmpty {
                    let days = Dictionary(grouping: (state.schedule?.posts ?? []).sorted { $0.scheduledAt < $1.scheduledAt }) {
                        Calendar.current.startOfDay(for: $0.scheduledAt)
                    }
                    List {
                        if state.error != nil, state.schedule != nil {
                            Section {
                                Label("Showing the last synced schedule. Cancellation is available when iCloud reconnects.",
                                      systemImage: "exclamationmark.icloud").foregroundStyle(.secondary)
                                    .listRowBackground(palette.card)
                            }
                        }
                        if !library.pendingSchedules.isEmpty {
                            Section("Scheduling requests") {
                                ForEach(library.pendingSchedules) { request in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(request.item.title).font(.headline)
                                        Text(request.hour, format: .dateTime.month(.abbreviated).day().hour())
                                        Label(request.error ?? "Waiting for your Mac",
                                              systemImage: request.error == nil ? "clock" : "exclamationmark.icloud")
                                    }
                                    .font(.subheadline)
                                    .listRowBackground(palette.card)
                                }
                            }
                        }
                        if days.isEmpty, library.pendingSchedules.isEmpty {
                            ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                                                   description: Text("Open a draft in Review to choose a posting day and hour."))
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(days.keys.sorted(), id: \.self) { day in
                                Section {
                                    ForEach(days[day] ?? []) { post in
                                        row(post).listRowBackground(palette.card)
                                    }
                                } header: {
                                    Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                                }
                            }
                            if let schedule = state.schedule {
                                Text("Synced from your Mac \(schedule.updatedAt.formatted(.relative(presentation: .named))).")
                                    .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                } else if state.loading {
                    ProgressView("Checking iCloud…")
                } else {
                    ContentUnavailableView {
                        Label("Schedule unavailable", systemImage: "calendar.badge.clock")
                    } description: {
                        Text(state.error ?? "Turn on schedule sync in Inkspring on your Mac. Use the same Apple Account on both devices.")
                    } actions: {
                        Button("Check again") { Task { await refresh() } }.buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: 760)
            .mobileCanvas()
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(wideLayout ? .inline : .automatic)
            .toolbar(wideLayout ? .hidden : .visible, for: .tabBar)
            .refreshable { await refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(state.busy)
                }
            }
            .confirmationDialog("Cancel this scheduled post?", isPresented: Binding(
                get: { candidate != nil }, set: { if !$0 { candidate = nil } }
            ), titleVisibility: .visible, presenting: candidate) { post in
                Button("Cancel scheduled post", role: .destructive) {
                    Task { await cancel(post) }
                }
                Button("Keep post", role: .cancel) {}
            } message: { post in
                Text("“\(post.title)” stays in Inkspring on your Mac so you can edit or schedule it again.")
            }
            .alert("Inkspring", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .task {
            await refresh()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--schedule-offline-fixture") {
                await refresh()
            }
#endif
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !state.loading, !state.busy { Task { await refresh() } }
        }
        .onChange(of: isSelected) { _, selected in
            if selected { Task { await refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            state = CompanionScheduleViewState()
            candidate = nil
            message = nil
            Task { await refresh() }
        }
    }

    private func row(_ post: CompanionPost) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                StudioPlatformLabel(name: post.channel, title: post.channel).font(.subheadline.weight(.semibold))
                Spacer()
                if post.state != .queued {
                    Text(stateLabel(post.state)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(post.title).font(.headline)
            Text(post.project).font(.subheadline).foregroundStyle(.secondary)
            Text(post.scheduledAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                .font(.subheadline).foregroundStyle(.secondary)
            if post.canCancel && [.queued, .review].contains(post.state) {
                Button("Cancel schedule", role: .destructive) { candidate = post }
                    .buttonStyle(.bordered)
                    .disabled(!state.canCancel)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 6)
    }

    private func stateLabel(_ state: CompanionPost.State) -> String {
        switch state {
        case .queued: "Scheduled"
        case .review: "Needs review"
        case .cancelled: "Cancelled"
        case .sending: "Sending"
        }
    }

    private func refresh() async {
        guard let token = state.begin(.refresh) else { return }
        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--schedule-fixture") {
                if state.schedule != nil, ProcessInfo.processInfo.arguments.contains("--schedule-offline-fixture") {
                    throw CompanionScheduleError.cloudTemporarilyUnavailable
                }
                let snapshot = state.schedule ?? Self.fixture
                guard state.confirmAccount("fixture", for: token) else { return }
                state.complete(snapshot, for: token)
                return
            }
#endif
            let store = cloud()
            let account = try await store.accountKey()
            let sameAccount = state.account == account
            guard state.confirmAccount(account, for: token) else { return }
            if !sameAccount { candidate = nil }
            let snapshot = try await store.load(confirmedAccount: account)
            state.complete(snapshot, for: token)
        } catch {
            state.fail(error.localizedDescription, keepSchedule: temporary(error), for: token)
        }
    }

    private func cancel(_ post: CompanionPost) async {
        guard let schedule = state.schedule, let account = state.account,
              let token = state.begin(.cancel) else { return }
        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--schedule-fixture") {
                var fixture = schedule
                try fixture.cancel(post)
                state.complete(fixture, for: token)
                return
            }
#endif
            let updated = try await cloud().update(workspaceID: schedule.workspaceID, expectedAccount: account) { try $0.cancel(post) }
            state.complete(updated, for: token)
        } catch {
            guard state.isCurrent(token) else { return }
            state.fail(error.localizedDescription, keepSchedule: temporary(error), for: token)
            message = error.localizedDescription
            await refresh()
        }
    }

    private func cloud() -> CloudScheduleStore {
        if let cloudStore { return cloudStore }
        let store = CloudScheduleStore()
        cloudStore = store
        return store
    }

    private func temporary(_ error: Error) -> Bool {
        if (error as? CompanionScheduleError) == .cloudTemporarilyUnavailable { return true }
        guard let cloudError = error as? CKError else { return false }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
                .zoneBusy, .accountTemporarilyUnavailable].contains(cloudError.code)
    }

#if DEBUG
    private static let fixture = CompanionSchedule(workspaceID: UUID(), posts: [
        CompanionPost(id: "fixture-1", revision: "1", title: "A quieter way to draft", project: "Studio",
                      channel: "LinkedIn", scheduledAt: .now.addingTimeInterval(10_800), state: .queued, canCancel: true),
        CompanionPost(id: "fixture-2", revision: "1", title: "This month’s studio notes", project: "Studio",
                      channel: "Substack", scheduledAt: .now.addingTimeInterval(91_000), state: .queued, canCancel: false)
    ])
#endif
}

private struct MobileWideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mobileWideLayout: Bool {
        get { self[MobileWideLayoutKey.self] }
        set { self[MobileWideLayoutKey.self] = newValue }
    }
}

extension View {
    func mobilePageTitle(_ title: String, wide: Bool, background: Color) -> some View {
        self
            .safeAreaInset(edge: .top, spacing: 0) {
                if wide {
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background.ignoresSafeArea(edges: .top))
                }
            }
            .navigationTitle(title)
            .toolbar(wide ? .hidden : .automatic, for: .navigationBar)
    }
}
