import CoreFoundation
import Foundation

struct AnalyticsReport {
    enum Metric: String, CaseIterable, Identifiable {
        case engagement, likes, replies, shares, views, score
        var id: String { rawValue }

        func label(for platform: SocialPlatform) -> String {
            switch self {
            case .engagement: "Interactions"
            case .likes: "Likes"
            case .replies: platform == .x ? "Replies" : "Comments"
            case .shares: "Shares"
            case .views: "Views"
            case .score: "Net score"
            }
        }
    }

    struct Followers: Identifiable {
        let at: Date
        let count: Int
        let accountPosts: Int?
        var id: Date { at }
    }

    struct Activity: Identifiable {
        let day: Date
        let count: Int
        var id: Date { day }
    }

    struct Post: Identifiable {
        let record: WorkspaceRecord
        let publishedAt: Date
        var id: String { record.id }
        var observedAt: Date? { scheduleDate(record["observedAt"]) }

        func value(_ metric: Metric) -> Double? {
            if metric == .engagement {
                return AnalyticsReport.sum([.likes, .replies, .shares].compactMap(value))
            }
            let values = record.fields["metrics"] as? [String: Any]
            return AnalyticsReport.integerMetric(values?[metric.rawValue], signed: metric == .score).map(Double.init)
        }
    }

    let latestFollowers: Followers?
    let followers: [Followers]
    let growth: Double?
    let posts: [Post]
    let oldestPostAt: Date?
    let activity: [Activity]
    let confirmedCount: Int
    let replyCount: Int

    init(records: [WorkspaceRecord], platform: SocialPlatform, accountID: String?, days: Int, sort: Metric,
         now: Date = .now) {
        let cutoff = days == 0 ? Date.distantPast : now.addingTimeInterval(-Double(days) * 86_400)
        let selected = records.filter {
            $0["platform"] == platform.rawValue && $0["accountId"] == accountID
        }
        var observed: [Date: Followers] = [:]
        for record in selected where record.kind == "analytics-day" {
            for key in ["first", "last"] {
                guard let snapshot = record.fields[key] as? [String: Any], let raw = snapshot["at"] as? String,
                      let date = scheduleDate(raw), let count = Self.integerMetric(snapshot["followers"]) else { continue }
                observed[date] = Followers(at: date, count: count, accountPosts: Self.integerMetric(snapshot["accountPosts"]))
            }
        }
        let history = observed.values.sorted { $0.at < $1.at }
        latestFollowers = history.last
        followers = history.filter { $0.at >= cutoff }
        if followers.count > 1, let first = followers.first, let last = followers.last {
            growth = Double(last.count) - Double(first.count)
        } else {
            growth = nil
        }

        posts = selected.compactMap { row in
            guard row.kind == "analytics-post", let date = scheduleDate(row["publishedAt"]), date >= cutoff else { return nil }
            return Post(record: row, publishedAt: date)
        }.sorted { a, b in
            let left = a.value(sort) ?? -.infinity
            let right = b.value(sort) ?? -.infinity
            if left != right { return left > right }
            return a.publishedAt == b.publishedAt ? a.id < b.id : a.publishedAt > b.publishedAt
        }
        oldestPostAt = posts.map(\.publishedAt).min()

        let receipts = Self.receipts(selected).values.filter { $0.date >= cutoff }
        confirmedCount = receipts.count
        replyCount = receipts.filter(\.reply).count
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        activity = Dictionary(grouping: receipts) { utc.startOfDay(for: $0.date) }
            .map { Activity(day: $0.key, count: $0.value.count) }.sorted { $0.day < $1.day }
    }

    func total(_ metric: Metric) -> (value: Double?, covered: Int) {
        let values = posts.compactMap { $0.value(metric) }
        return (Self.sum(values), values.count)
    }

    static func allConfirmed(_ records: [WorkspaceRecord]) -> Int { receipts(records).count }

    static func integerMetric(_ raw: Any?, signed: Bool = false) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        let maximum = 9_007_199_254_740_991.0
        guard ((signed ? -maximum : 0)...maximum).contains(value) else { return nil }
        return Int(exactly: value)
    }

    private struct Receipt: Hashable {
        let platform: String
        let account: String
        let post: String
    }

    private static func receipts(_ records: [WorkspaceRecord]) -> [Receipt: (date: Date, reply: Bool)] {
        var confirmed: [Receipt: (date: Date, reply: Bool)] = [:]
        for row in records where row.kind == "publication" {
            let fallback = scheduleDate(row["publishedAt"]) ?? scheduleDate(row["createdAt"])
            var steps = row.fields["steps"] as? [[String: Any]] ?? []
            if steps.isEmpty && row["status"] == "published" { steps = [["id": row.id]] }
            for step in steps {
                guard let post = step["id"] as? String, !post.isEmpty,
                      let date = (step["at"] as? String).flatMap(scheduleDate) ?? fallback else { continue }
                let key = Receipt(platform: row["platform"], account: row["accountId"], post: post)
                if let existing = confirmed[key] {
                    confirmed[key] = (min(date, existing.date), existing.reply || !row["replyToId"].isEmpty)
                } else {
                    confirmed[key] = (date, !row["replyToId"].isEmpty)
                }
            }
        }
        return confirmed
    }

    private static func sum(_ values: [Double]) -> Double? {
        let sum = values.reduce(0, +)
        return !values.isEmpty && sum.isFinite ? sum : nil
    }
}
