import Charts
import SwiftUI

struct AnalyticsView: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let openConnections: () -> Void
    @State private var platform: SocialPlatform = .x
    @State private var accountSelection = ""
    @State private var interval = 30
    @State private var sort: AnalyticsReport.Metric = .engagement
    @State private var warnings: [String] = []

    private var analytics: AccountAnalytics { AccountAnalytics(workspace: workspace) }
    private var accounts: [SocialPlatform: ManagedSocialAccount] {
        var accounts: [SocialPlatform: ManagedSocialAccount] = [:]
        for platform in SocialPlatform.allCases { accounts[platform] = analytics.account(platform) }
        return accounts
    }

    private var savedAccountIDs: [String] {
        Set(workspace.records.filter {
            ($0.kind.hasPrefix("analytics-") || $0.kind == "publication") && $0["platform"] == platform.rawValue
        }.map { $0["accountId"] }.filter { !$0.isEmpty }).sorted()
    }

    var body: some View {
        let connected = accounts
        let current = connected[platform]
        let ids = ([current?.id].compactMap { $0 } + savedAccountIDs.filter { $0 != current?.id })
        let accountID = ids.contains(accountSelection) ? accountSelection : ids.first
        let refreshAccount = current.flatMap { $0.id == accountID ? $0 : nil }
        let state = accountID.flatMap { analytics.state(platform, accountID: $0) }
        let capabilities = refreshAccount.map { analytics.capabilities(platform, account: $0) }
        let canRefresh = capabilities.map { $0.followers || $0.posts } ?? false
        let busy = workspace.refreshingAnalytics.contains(platform)
        let report = AnalyticsReport(records: workspace.records, platform: platform, accountID: accountID,
                                     days: interval, sort: sort)
        StudioScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    PageHeading(title: "Watch your work grow.",
                                subtitle: "Track your audience and see how published posts perform.")
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(busy || !canRefresh)
                }
                HStack(spacing: 18) {
                    Label("\(connected.count) connected accounts", systemImage: "person.2")
                    Label("\(AnalyticsReport.allConfirmed(workspace.records)) confirmed posts", systemImage: "checkmark.circle")
                }
                .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 12) {
                    StudioTabs(selection: $platform, tabs: SocialPlatform.allCases, label: { $0.name }, platform: { $0.rawValue })
                    Spacer()
                    StudioChoicePicker(title: "Show", selection: $interval, options: [7, 30, 90, 0],
                                       label: { $0 == 0 ? "All time" : "\($0) days" })
                }
                if let accountID {
                    if ids.count > 1 {
                        StudioChoicePicker(title: "Account",
                                           selection: Binding(get: { accountID }, set: { accountSelection = $0 }),
                                           options: ids, label: { accountName($0, connected: current, distinguish: true) })
                    } else {
                        Text(accountName(accountID, connected: current, distinguish: false)).font(.headline)
                    }
                }
                if refreshAccount != nil {
                    Toggle("Save a daily snapshot while Inkspring is open", isOn: Binding(get: {
                        analytics.automatic(platform)
                    }, set: { enabled in
                        workspace.perform { try analytics.setAutomatic(enabled, platform: platform) }
                    }))
                    .disabled(!canRefresh || busy)
                }
                if !canRefresh {
                    HStack {
                        Text(refreshAccount == nil ? "Connect \(platform.name) to refresh analytics." :
                                "This connection needs analytics read permission to refresh.")
                            .foregroundStyle(.secondary)
                        Button("Open Connections", action: openConnections)
                    }
                }
                ForEach(refreshWarnings(state), id: \.self) { Text($0).foregroundStyle(.secondary) }
                overview(report, state: state)
                if !report.posts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The date range filters publication dates. Engagement totals use each post’s lifetime counts at its last refresh.")
                        if let count = report.latestFollowers?.accountPosts {
                            Text("The platform reports \(count.formatted()) \(platform == .tiktok ? "public videos" : "posts") on this profile.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                followerChart(report)
                activityChart(report)
                rankedPosts(report)
                if refreshAccount != nil, capabilities?.posts == true, let state, !state["cursor"].isEmpty {
                    Button("Load older posts") { Task { await refresh(older: true) } }.disabled(busy)
                }
            }
            .studioPage()
        }
        .onChange(of: platform) { _, value in
            accountSelection = ""
            warnings = []
            sort = value == .reddit ? .score : .engagement
        }
        .onChange(of: accountSelection) { _, _ in warnings = [] }
    }

    private func refreshWarnings(_ state: WorkspaceRecord?) -> [String] {
        let saved = [state?["profileError"], state?["postsError"]].compactMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        return (warnings + saved).filter { seen.insert($0).inserted }
    }

    private func overview(_ report: AnalyticsReport, state: WorkspaceRecord?) -> some View {
        let likes = report.total(.likes)
        let replies = report.total(.replies)
        let importCount = report.posts.isEmpty && (state?["postsAt"] ?? "").isEmpty ? nil : report.posts.count.formatted()
        let firstDate = report.oldestPostAt?.formatted(date: .abbreviated, time: .omitted)
        let lastSnapshot = report.latestFollowers?.at.formatted(date: .abbreviated, time: .omitted)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 95)), count: 4), spacing: 12) {
            metric("Followers", report.latestFollowers?.count.formatted(),
                   detail: report.growth.map { value in
                       (value >= 0 ? "+" : "") + formatted(value) + " in range"
                   } ?? lastSnapshot.map { "Saved \($0)" } ?? "Awaiting first snapshot")
            metric("Imported posts", importCount, detail: firstDate.map { "Oldest \($0)" } ?? "In selected range")
            metric("Likes", likes.value.map(formatted), detail: coverage(likes.covered, of: report.posts.count))
            metric(AnalyticsReport.Metric.replies.label(for: platform), replies.value.map(formatted),
                   detail: coverage(replies.covered, of: report.posts.count))
        }
    }

    private func metric(_ label: String, _ value: String?, detail: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func followerChart(_ report: AnalyticsReport) -> some View {
        GroupBox("Follower growth") {
            if report.followers.isEmpty {
                ContentUnavailableView("No saved observations in this range", systemImage: "chart.line.uptrend.xyaxis")
            } else if report.followers.count == 1, let baseline = report.followers.first {
                LabeledContent("First snapshot", value: "\(baseline.count.formatted()) on \(baseline.at.formatted(date: .abbreviated, time: .omitted))")
            } else {
                Chart(report.followers) { point in
                    LineMark(x: .value("Date", point.at), y: .value("Followers", point.count))
                        .foregroundStyle(palette.accent)
                    PointMark(x: .value("Date", point.at), y: .value("Followers", point.count))
                        .foregroundStyle(palette.accent)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 190)
                DisclosureGroup("Saved follower counts") {
                    ForEach(report.followers.reversed()) { point in
                        LabeledContent(point.at.formatted(date: .abbreviated, time: .shortened), value: point.count.formatted())
                            .font(.callout)
                    }
                }
                Text("The line connects saved snapshots. Days between snapshots have no observation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityChart(_ report: AnalyticsReport) -> some View {
        GroupBox("Published with Inkspring") {
            if report.activity.isEmpty {
                Text("No confirmed posts in this range.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart(report.activity) { day in
                    BarMark(x: .value("Date", day.day, unit: .day), y: .value("Posts", day.count))
                        .foregroundStyle(palette.accent)
                }
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .frame(height: 145)
                Text("\(report.confirmedCount) confirmed posts · \(report.replyCount) replies · UTC")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rankedPosts(_ report: AnalyticsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top posts").font(.headline)
                Spacer()
                StudioChoicePicker(title: "Rank by", selection: $sort,
                                   options: AnalyticsReport.Metric.allCases.filter { $0 != .score || platform == .reddit },
                                   label: { $0.label(for: platform) })
            }
            if report.posts.isEmpty { Text("No imported posts in this range.").foregroundStyle(.secondary) }
            ForEach(report.posts.prefix(50)) { post in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(post.publishedAt, format: .dateTime.month(.abbreviated).day().year())
                        Spacer()
                        if let observed = post.observedAt {
                            Text("Metrics refreshed \(observed.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(post.record.body.isEmpty ? "Media post" : post.record.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        let metrics: [AnalyticsReport.Metric] = platform == .reddit ? [.score, .replies] : [.likes, .replies, .shares, .views]
                        ForEach(metrics) { metric in
                            Text(metric.label(for: platform) + " " + (post.value(metric).map(formatted) ?? "—"))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let link = URL(string: post.record["url"]), link.scheme == "https", link.host != nil,
                       link.user == nil, link.password == nil {
                        StudioExternalLink("View on \(platform.name)", destination: link).font(.caption)
                    }
                }
                Divider()
            }
            if report.posts.count > 50 {
                Text("Showing the top 50 of \(report.posts.count) imported posts.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func accountName(_ id: String, connected: ManagedSocialAccount?, distinguish: Bool) -> String {
        if let connected, connected.id == id { return connected.username.isEmpty ? connected.name : connected.username }
        if let receipt = workspace.records.first(where: {
            $0.kind == "publication" && $0["platform"] == platform.rawValue && $0["accountId"] == id && !$0["accountName"].isEmpty
        }) {
            return receipt["accountName"]
        }
        return "Saved \(platform.name) account" + (distinguish ? " · " + id.suffix(4) : "")
    }

    private func coverage(_ count: Int, of total: Int) -> String { "\(count) of \(total) posts" }

    private func formatted(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }

    private func refresh(older: Bool = false) async {
        let selected = platform
        let selection = accountSelection
        do {
            let messages = try await analytics.refresh(selected, older: older)
            if selected == platform, selection == accountSelection { warnings = messages }
        } catch { workspace.error = error.localizedDescription }
    }
}
