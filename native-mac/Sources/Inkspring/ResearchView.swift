import SwiftUI

struct ResearchView: View {
    private struct SearchRequest: Equatable {
        let tab: String
        var refresh: UUID?
    }

    let workspace: Workspace
    let add: () -> Void
    let edit: (WorkspaceRecord) -> Void
    let editProject: () -> Void
    let openDraft: (WorkspaceRecord) -> Void
    let openSettings: (String) -> Void
    let openConnections: () -> Void
    @State private var request = SearchRequest(tab: RecentResearch.platform)
    @State private var destination = "x"
    @State private var searching = false
    @State private var searchError: String?
    @State private var showsReferenceHelp = false
    @State private var referenceSearch = ""
    @State private var recentTopic = ""
    @State private var selectedBriefID: String?

    private var tab: String { request.tab }
    private var platform: ResearchPlatform { ResearchPlatform(rawValue: tab) ?? .x }
    private var isRecent: Bool { tab == RecentResearch.platform }
    private var hasApify: Bool { ProviderKey.apify.isSaved }
    private var hasX: Bool { ProviderKey.x.isSaved || workspace.socialAccounts.hasSavedAccount(.x) }
    private var canSearch: Bool {
        switch ResearchPlatform(rawValue: tab) {
        case .x: hasX || hasApify
        case .instagram, .linkedin: hasApify
        case .news, nil: true
        }
    }
    private var canSynthesize: Bool {
        switch StudioWritingConnection(settings: workspace.settings) {
        case .agent: workspace.agentConnected
        case .api: WritingProviders(settings: workspace.settings).writingProvider.isSaved
        }
    }
    private var topicKey: String { "researchTopic:" + workspace.projectID }
    private var feed: WorkspaceRecord? { workspace.items("discovery").first { $0["platform"] == platform.rawValue } }
    private var items: [[String: Any]] { feed?.fields["items"] as? [[String: Any]] ?? [] }
    private var recentBriefs: [WorkspaceRecord] {
        workspace.items("discovery").filter { $0["platform"] == RecentResearch.platform }
            .sorted { $0["searchedAt"] > $1["searchedAt"] }
    }
    private var recentBrief: WorkspaceRecord? { recentBriefs.first { $0.id == selectedBriefID } ?? recentBriefs.first }
    private var savedTopic: String? {
        (workspace.settings[topicKey] as? String) ?? recentBriefs.first?.title
    }
    private var topics: [String] {
        var seen = Set<String>()
        return ((feed?.fields["topics"] as? [String] ?? []) + items.compactMap { $0["topic"] as? String })
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var references: [WorkspaceRecord] {
        let query = referenceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.sources.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.body.localizedStandardContains(query)
        }
    }

    var body: some View {
        StudioScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    PageHeading(title: "Worth your attention.",
                                subtitle: "Find relevant posts and news, and save sources for your drafts.")
                    Spacer()
                }
                StudioTabs(selection: Binding(get: { tab }, set: { if tab != $0 { request = SearchRequest(tab: $0) } }),
                           tabs: [RecentResearch.platform] + ResearchPlatform.allCases.map(\.rawValue),
                           label: { ResearchPlatform(rawValue: $0)?.title ?? RecentResearch.title }, platform: { $0 })
                    .onChange(of: tab) { _, tab in destination = ["instagram", "linkedin"].contains(tab) ? tab : "x" }
                if searching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for recent sources…").foregroundStyle(.secondary)
                    }
                }
                if let searchError {
                    Label(searchError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                if isRecent { recentResearch }
                else { platformResearch }
                StudioRule()
                savedReferences
            }
            .studioPage()
        }
        .task(id: request) { [request] in await load(request) }
    }

    @ViewBuilder private var recentResearch: some View {
        HStack {
            StudioSearchField(title: "Research a topic", text: $recentTopic)
                .onSubmit { if !searching { refresh() } }
                .disabled(searching)
            refreshButton
        }
        recentSetup
        if let brief = recentBrief {
            let evidence = brief.fields["items"] as? [[String: Any]] ?? []
            let findings = brief.fields["findings"] as? [[String: Any]] ?? []
            HStack(alignment: .firstTextBaseline) {
                Text(brief.title).font(InkspringTypography.editorial(25, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if recentBriefs.count > 1 {
                    Menu("Saved briefs") {
                        ForEach(recentBriefs) { report in
                            Button(report.title) {
                                selectedBriefID = report.id
                                recentTopic = report.title
                                workspace.perform { try workspace.set(topicKey, to: report.title) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            if let start = scheduleDate(brief["windowStart"]), let end = scheduleDate(brief["searchedAt"]) {
                Text("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            recentCoverage(brief)
            if !brief["focus"].isEmpty { Text(brief["focus"]).foregroundStyle(.secondary) }
            if evidence.isEmpty {
                Text("No dated sources matched this topic. Try a shorter or broader topic, then select Refresh topics.")
                    .foregroundStyle(.secondary)
                recentFallback
            } else {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    recentFinding(finding, evidence: evidence)
                }
                HStack {
                    Text("Sources (\(evidence.count))").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    writeDestination
                }
                recommendations(evidence, feed: brief)
            }
        } else {
            recentFallback
        }
    }

    @ViewBuilder private var recentFallback: some View {
        if let cached = workspace.items("discovery").filter({ $0.id != recentBrief?.id })
            .sorted(by: { $0["searchedAt"] > $1["searchedAt"] })
            .first(where: { !datedItems($0).isEmpty }) {
            let platform = cached["platform"]
            let label = ResearchPlatform(rawValue: platform)?.title ?? cached.title
            Text(platform == RecentResearch.starterPlatform ? "Browse recent technology sources" : "Previous results · " + label)
                .font(.headline)
            recommendations(Array(datedItems(cached).prefix(3)), feed: cached)
        }
    }

    private func datedItems(_ record: WorkspaceRecord) -> [[String: Any]] {
        let now = Date.now
        return (record.fields["items"] as? [[String: Any]] ?? []).filter { item in
            guard let source = item["source"] as? [String: Any],
                  let published = (source["postedAt"] as? String).flatMap(scheduleDate) else { return false }
            return (0...RecentResearch.duration).contains(now.timeIntervalSince(published))
        }
    }

    private var refreshButton: some View {
        Button("Refresh topics", systemImage: "arrow.clockwise", action: refresh)
            .modifier(PrimaryActionStyle())
            .disabled(searching || !canSearch || workspace.project == nil)
    }

    private var recentSetup: some View {
        DisclosureGroup("Research sources and setup") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Google News, Hacker News and GitHub load automatically without API keys. Refresh topics includes your connected sources.")
                Text("For Reddit and YouTube, add an Apify token. X works with Apify, a connected X account, or an X Bearer Token with Recent Search access.")
                setupActions(includeX: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
        }
    }

    private var platformSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(platform == .x ? "Connect X to load posts" : "Add an Apify token to load \(platform.title) posts")
                .font(.headline)
            Text(platform == .x
                 ? "In Connections, connect your X account. You can also save an X Bearer Token with Recent Search access or an Apify token in Settings → API keys."
                 : "Create an API token in Apify, then paste it into the Apify field in Settings → API keys and select Save key. Return here to load topics.")
                .foregroundStyle(.secondary)
            setupActions(includeX: platform == .x)
        }
    }

    @ViewBuilder private func setupActions(includeX: Bool) -> some View {
        HStack {
            Button("Open API keys") { openSettings("API keys") }
            SetupHelpLink("Apify setup", topic: "key-apify")
            if includeX {
                Button("Open Connections", action: openConnections)
                SetupHelpLink("X token setup", topic: "key-x")
            }
        }
    }

    private func recentCoverage(_ brief: WorkspaceRecord) -> some View {
        let rows = brief.fields["coverage"] as? [[String: Any]] ?? []
        let labels = rows.compactMap { row -> String? in
            guard let platform = row["platform"] as? String, let status = row["status"] as? String else { return nil }
            let count = row["count"] as? Int ?? 0
            return switch status {
            case "searched": "\(platform) (\(count))"
            case "imported": "\(platform) (\(count) imported)"
            case "7-day search": "\(platform) (\(count) · 7-day search)"
            case "unavailable": "\(platform) (setup needed)"
            case "failed": "\(platform) (couldn’t load)"
            default: "\(platform) (\(status))"
            }
        }
        let failed = rows.filter { $0["status"] as? String == "failed" }.compactMap { $0["platform"] as? String }
        return VStack(alignment: .leading, spacing: 5) {
            Text(labels.joined(separator: "  ·  ")).font(.caption)
            if !failed.isEmpty {
                Text("Couldn’t load \(failed.joined(separator: ", ")). If a connected source keeps failing, check its token and access in Settings → API keys, then refresh.")
                    .font(.callout)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func recentFinding(_ finding: [String: Any], evidence: [[String: Any]]) -> some View {
        let addresses = finding["sourceURLs"] as? [String] ?? []
        return VStack(alignment: .leading, spacing: 5) {
            Text(finding["title"] as? String ?? "").font(.headline)
            Text(finding["text"] as? String ?? "").textSelection(.enabled)
            ForEach(addresses, id: \.self) { address in
                if let url = sourceURL(address), let item = evidence.first(where: { $0["id"] as? String == address }),
                   let source = item["source"] as? [String: Any], let title = source["title"] as? String {
                    StudioExternalLink("\(source["origin"] as? String ?? "Source") · \(title)", destination: url)
                        .lineLimit(1)
                }
            }
        }
    }

    private var writeDestination: some View {
        StudioChoicePicker(title: "Write for", selection: $destination,
                           options: ["x", "linkedin", "instagram", "reddit"], label: platformName, icon: PlatformMark.image)
    }

    @ViewBuilder private var platformResearch: some View {
        HStack {
            if let project = workspace.project {
                Button("Edit research focus", action: editProject)
                if let updated = feed?["profileUpdatedAt"], !updated.isEmpty, updated != project["updatedAt"] {
                    Text("Refresh to use the updated project focus.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !items.isEmpty { writeDestination }
            refreshButton
        }
        if !canSearch || searchError != nil && platform != .news { platformSetup }
        if let feed {
            if !feed["focus"].isEmpty { Text(feed["focus"]).foregroundStyle(.secondary) }
            if let date = scheduleDate(feed["searchedAt"]) {
                Text("Last searched \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(feed.fields["warnings"] as? [String] ?? [], id: \.self) { Text($0).foregroundStyle(.secondary) }
            if items.isEmpty && !searching {
                Text("No matching sources. Edit your research focus for a broader topic, then select Refresh topics.")
                    .foregroundStyle(.secondary)
            }
            ForEach(topics, id: \.self) { topic in
                let matching = items.filter { $0["topic"] as? String == topic }
                if !matching.isEmpty {
                    Text(topic).font(.headline)
                    recommendations(matching, feed: feed)
                }
            }
            recommendations(items.filter { ($0["topic"] as? String ?? "").isEmpty }, feed: feed)
        }
    }

    @ViewBuilder private var savedReferences: some View {
        HStack {
            Text("Saved references").font(InkspringTypography.editorial(25, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            Button { showsReferenceHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(StudioIconButtonStyle())
            .accessibilityLabel("What are saved references?")
            .help("Keep a source in this project to reopen it or start a draft from it.")
            .popover(isPresented: $showsReferenceHelp, arrowEdge: .bottom) {
                Text("Select Save reference on a research result to keep it in this project, or select Add reference to save your own link or note. Use Write from reference to start a draft with the source attached.")
                    .frame(width: 285, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
            Spacer()
            StudioSearchField(title: "Search saved references", text: $referenceSearch)
                .frame(maxWidth: 240)
            Button("Add reference", systemImage: "plus", action: add)
        }
        if references.isEmpty {
            Text(referenceSearch.isEmpty ? "Save a result you want to use later, or add your own link or note." : "No matching references.")
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(references) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { edit(source) } label: { RecordCard(record: source) }.buttonStyle(.plain)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { referenceActions(source) }
                            VStack(alignment: .leading, spacing: 6) { referenceActions(source) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func referenceActions(_ source: WorkspaceRecord) -> some View {
        Button("Write from reference") { openDraft(ResearchDraft.post(from: source, platform: "x")) }
            .modifier(PrimaryActionStyle())
        if let url = sourceURL(source["url"]) { StudioExternalLink("Open source", destination: url) }
    }

    private func recommendations(_ items: [[String: Any]], feed: WorkspaceRecord) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in recommendation(item, feed: feed) }
    }

    private func recommendation(_ item: [String: Any], feed: WorkspaceRecord) -> some View {
        let source = item["source"] as? [String: Any] ?? [:]
        let address = source["url"] as? String ?? ""
        let saved = !address.isEmpty && workspace.sources.contains { $0["url"] == address }
        let canReply = (isRecent || platform == .x) && XQuoteComposer.postURL(address) != nil
        let angle = item["angle"] as? String ?? ""
        return GroupBox(item["headline"] as? String ?? "Research idea") {
            VStack(alignment: .leading, spacing: 7) {
                if let hook = item["hook"] as? String, !hook.isEmpty { Text(hook).font(.headline) }
                if !angle.isEmpty { Text(angle).textSelection(.enabled) }
                if let fit = item["whyItFits"] as? String, !fit.isEmpty { Text(fit).foregroundStyle(.secondary) }
                if let evidence = source["text"] as? String {
                    DisclosureGroup(isRecent ? "Read source excerpt" : platform == .news ? "Read headline" : "Read source post") {
                        Text(evidence).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                sourceDetails(source)
                HStack {
                    if let url = sourceURL(address) { StudioExternalLink("Open source", destination: url) }
                    if canReply {
                        Button("Reply to source") {
                            workspace.perform { openDraft(try ResearchDraft.reply(to: source, projectID: workspace.projectID)) }
                        }
                    }
                    Spacer()
                    Button(saved ? "Saved" : "Save reference") { save(source) }
                        .disabled(saved)
                    Button(angle.isEmpty ? "Write from source" : "Write from this angle") { save(source, recommendation: item) }
                    if !isRecent {
                        Button("Dismiss") {
                            workspace.perform { try workspace.dismissResearch(item["id"] as? String ?? "", from: feed.id) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceDetails(_ source: [String: Any]) -> some View {
        HStack(spacing: 10) {
            if isRecent, let origin = source["origin"] as? String { Text(origin) }
            if let author = source["author"] as? String, !author.isEmpty { Text(author) }
            if let day = source["publishedDay"] as? String {
                Text(day)
            } else if let date = (source["postedAt"] as? String).flatMap(scheduleDate) {
                Text(date.formatted(date: .abbreviated, time: .shortened))
            }
            if isRecent || platform != .news {
                if let likes = source["likes"] as? Int {
                    let metric = switch (source["origin"] as? String ?? "").lowercased() {
                    case "reddit": "upvotes"
                    case "hacker news": "points"
                    case "github": "reactions"
                    default: "likes"
                    }
                    Text("\(likes.formatted()) \(metric)")
                }
                if let reposts = source["reposts"] as? Int { Text("\(reposts.formatted()) reposts") }
                if let replies = source["replies"] as? Int {
                    Text("\(replies.formatted()) replies")
                }
                if let views = source["views"] as? Int { Text("\(views.formatted()) views") }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func refresh() {
        request.refresh = UUID()
    }

    private func load(_ action: SearchRequest) async {
        guard !Task.isCancelled, request == action else { return }
        searching = false
        searchError = nil
        guard let project = workspace.project, canSearch else { return }
        let refresh = action.refresh != nil
        if action.tab == RecentResearch.platform {
            let entered = recentTopic.trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = (refresh && !entered.isEmpty ? entered : savedTopic) ?? RecentResearch.topic(in: project["researchFocus"])
            recentTopic = topic
            let cached = recentBriefs.first { $0.title.localizedCaseInsensitiveCompare(topic) == .orderedSame }
            selectedBriefID = cached?.id
            if !refresh, RecentResearch.fresh(cached), let cached, !datedItems(cached).isEmpty { return }
            await loadRecent(action, topic: topic, projectID: project.id, cached: cached, refresh: refresh)
        } else if let platform = ResearchPlatform(rawValue: action.tab) {
            if !refresh, RecentResearch.fresh(feed), feed?["profileUpdatedAt"] == project["updatedAt"], !items.isEmpty { return }
            await loadPlatform(action, platform: platform, project: project)
        }
    }

    private func loadRecent(_ action: SearchRequest, topic: String, projectID: String, cached: WorkspaceRecord?, refresh: Bool) async {
        searching = true
        defer { if request == action { searching = false } }
        do {
            if refresh, (1...180).contains(topic.utf16.count) { try workspace.set(topicKey, to: topic) }
            let research = RecentResearch(studio: ContentStudio(workspace: workspace))
            let coverage = cached?.fields["coverage"] as? [[String: Any]] ?? []
            let includedConnectedSources = coverage.contains {
                ["X", "Reddit", "YouTube"].contains($0["platform"] as? String ?? "")
            }
            let sources = refresh || includedConnectedSources ? Set(RecentResearchSource.allCases) : RecentResearch.publicSources
            let brief = try await research.run(topic: topic, projectID: projectID, sources: sources,
                                               synthesize: refresh && canSynthesize)
            guard !Task.isCancelled, request == action else { return }
            selectedBriefID = brief.id
            if datedItems(brief).isEmpty, !refresh, topic != RecentResearch.starterTopic {
                let starter = workspace.items("discovery").first { $0["platform"] == RecentResearch.starterPlatform }
                if !RecentResearch.fresh(starter) {
                    _ = try await research.run(topic: RecentResearch.starterTopic, projectID: projectID,
                                               sources: RecentResearch.publicSources, synthesize: false, starter: true)
                }
            }
        } catch {
            if !Task.isCancelled, request == action { searchError = error.localizedDescription }
        }
    }

    private func loadPlatform(_ action: SearchRequest, platform: ResearchPlatform, project: WorkspaceRecord) async {
        searching = true
        defer { if request == action { searching = false } }
        let discovery = ResearchDiscovery(studio: ContentStudio(workspace: workspace))
        let topic = RecentResearch.topic(in: savedTopic ?? project["researchFocus"])
        do {
            if canSynthesize {
                do {
                    _ = try await discovery.discover(platform, projectID: project.id, includeUnrankedSources: true)
                    return
                } catch {
                    try Task.checkCancellation()
                    _ = try await discovery.browse(platform, projectID: project.id, topic: topic,
                                                  note: "Showing recent sources. Writing suggestions couldn’t load. Check your writing connection in Settings.")
                }
            } else {
                _ = try await discovery.browse(platform, projectID: project.id, topic: topic)
            }
        } catch {
            if !Task.isCancelled, request == action {
                searchError = "Couldn’t refresh \(platform.title). \(error.localizedDescription) Try Refresh topics again."
            }
        }
    }

    private func save(_ evidence: [String: Any], recommendation: [String: Any]? = nil) {
        workspace.perform {
            let source = try workspace.saveResearchReference(evidence, projectID: workspace.projectID)
            if let recommendation {
                openDraft(ResearchDraft.post(from: source, platform: destination, hook: recommendation["hook"] as? String ?? "",
                                             angle: recommendation["angle"] as? String ?? ""))
            } else {
                workspace.notice = "Reference saved"
            }
        }
    }

    private func sourceURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
