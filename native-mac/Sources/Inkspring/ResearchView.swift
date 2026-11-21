import SwiftUI

struct ResearchView: View {
    let workspace: Workspace
    let add: () -> Void
    let edit: (WorkspaceRecord) -> Void
    let editProject: () -> Void
    let openDraft: (WorkspaceRecord) -> Void
    @State private var platform: ResearchPlatform = .x
    @State private var destination = "x"
    @State private var searching = false
    @State private var referenceSearch = ""

    private var feed: WorkspaceRecord? { workspace.items("discovery").first { $0["platform"] == platform.rawValue } }
    private var items: [[String: Any]] { feed?.fields["items"] as? [[String: Any]] ?? [] }
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
                    if searching { ProgressView().controlSize(.small) }
                    if workspace.writingToolsAvailable {
                        Button(feed == nil ? "Find topics" : "Refresh topics", systemImage: feed == nil ? "magnifyingglass" : "arrow.clockwise") {
                            Task { await find() }
                        }
                        .disabled(searching || workspace.project == nil)
                        .modifier(PrimaryActionStyle())
                    }
                }
                StudioTabs(selection: $platform, tabs: ResearchPlatform.allCases, label: { $0.title }, platform: { $0.rawValue })
                    .disabled(searching)
                    .onChange(of: platform) { _, platform in destination = platform == .news ? "x" : platform.rawValue }
                HStack {
                    if let project = workspace.project {
                        Button("Edit research focus", action: editProject)
                        if let updated = feed?["profileUpdatedAt"], !updated.isEmpty, updated != project["updatedAt"] {
                            Text("Refresh to use the updated project focus.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !items.isEmpty {
                        StudioChoicePicker(title: "Write for", selection: $destination,
                                           options: ["x", "linkedin", "instagram", "reddit"], label: platformName,
                                           icon: PlatformMark.image)
                    }
                }
                if let feed {
                    if !feed["focus"].isEmpty { Text(feed["focus"]).foregroundStyle(.secondary) }
                    if let date = scheduleDate(feed["searchedAt"]) {
                        Text("Last searched \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(feed.fields["warnings"] as? [String] ?? [], id: \.self) { Text($0).foregroundStyle(.secondary) }
                    if items.isEmpty { Text("No matching sources passed review.").foregroundStyle(.secondary) }
                    ForEach(topics, id: \.self) { topic in
                        let matching = items.filter { $0["topic"] as? String == topic }
                        if !matching.isEmpty {
                            Text(topic).font(.headline)
                            recommendations(matching, feed: feed)
                        }
                    }
                    recommendations(items.filter { ($0["topic"] as? String ?? "").isEmpty }, feed: feed)
                }
                StudioRule()
                HStack {
                    Text("Saved references").font(InkspringTypography.editorial(25, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    StudioSearchField(title: "Search saved references", text: $referenceSearch)
                        .frame(maxWidth: 240)
                    Button("Add reference", systemImage: "plus", action: add)
                }
                if references.isEmpty {
                    Text(referenceSearch.isEmpty ? "No saved references" : "No matching references").foregroundStyle(.secondary)
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
            .studioPage()
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
        let canReply = platform == .x && XQuoteComposer.postURL(address) != nil
        return GroupBox(item["headline"] as? String ?? "Research idea") {
            VStack(alignment: .leading, spacing: 7) {
                if let hook = item["hook"] as? String, !hook.isEmpty { Text(hook).font(.headline) }
                if let angle = item["angle"] as? String { Text(angle).textSelection(.enabled) }
                if let fit = item["whyItFits"] as? String, !fit.isEmpty { Text(fit).foregroundStyle(.secondary) }
                if let evidence = source["text"] as? String {
                    DisclosureGroup(platform == .news ? "Read headline" : "Read source post") {
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
                    Button("Write from this angle") { save(source, recommendation: item) }
                    Button("Dismiss") {
                        workspace.perform { try workspace.dismissResearch(item["id"] as? String ?? "", from: feed.id) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceDetails(_ source: [String: Any]) -> some View {
        HStack(spacing: 10) {
            if let author = source["author"] as? String, !author.isEmpty { Text(author) }
            if let date = (source["postedAt"] as? String).flatMap(scheduleDate) {
                Text(date.formatted(date: .abbreviated, time: .shortened))
            }
            if platform != .news {
                if let likes = source["likes"] as? Int { Text("\(likes.formatted()) likes") }
                if let reposts = source["reposts"] as? Int { Text("\(reposts.formatted()) reposts") }
                if let replies = source["replies"] as? Int {
                    Text("\(replies.formatted()) \(platform == .x ? "replies" : "comments")")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func find() async {
        guard !searching, let project = workspace.project else { return }
        searching = true
        defer { searching = false }
        do {
            _ = try await ResearchDiscovery(studio: ContentStudio(workspace: workspace)).discover(platform, projectID: project.id)
        } catch { workspace.error = error.localizedDescription }
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
