import CryptoKit
import Foundation

@MainActor
struct AccountAnalytics {
    let workspace: Workspace
    var transport = SocialTransport()
    var accountOverride: ManagedSocialAccount? = nil

    func account(_ platform: SocialPlatform) -> ManagedSocialAccount? {
        accountOverride ?? (try? workspace.socialAccounts.savedAccount(platform))
    }

    func capabilities(_ platform: SocialPlatform, account: ManagedSocialAccount) -> (followers: Bool, posts: Bool) {
        let scopes = Set((account.session.scopes ?? "").split { $0.isWhitespace || $0 == "," })
        return switch platform {
        case .x: (scopes.contains("users.read"), scopes.contains("tweet.read"))
        case .instagram: (scopes.contains("instagram_business_basic"), scopes.contains("instagram_business_basic"))
        case .tiktok: (scopes.contains("user.info.stats"), scopes.contains("video.list"))
        case .linkedin: (scopes.contains("r_member_profileAnalytics"), false)
        case .reddit: (false, scopes.contains("read") && account.username.range(of: #"\A[A-Za-z0-9_-]{1,30}\z"#, options: .regularExpression) != nil)
        }
    }

    func accountKey(_ platform: SocialPlatform, id: String) -> String {
        SHA256.hash(data: Data((platform.rawValue + ":" + id).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func state(_ platform: SocialPlatform, account: ManagedSocialAccount) -> WorkspaceRecord? {
        state(platform, accountID: account.id)
    }

    func state(_ platform: SocialPlatform, accountID: String) -> WorkspaceRecord? {
        let id = "analytics-state-" + accountKey(platform, id: accountID)
        return workspace.records.first { $0.kind == "analytics-state" && $0.id == id }
    }

    func automatic(_ platform: SocialPlatform) -> Bool {
        let all = workspace.settings["analyticsAutomatic"] as? [String: [String: Any]] ?? [:]
        guard let item = all[platform.rawValue], let account = account(platform) else { return false }
        return item["enabled"] as? Bool == true && item["session"] as? String == account.connectionKey
    }

    func setAutomatic(_ enabled: Bool, platform: SocialPlatform) throws {
        try workspace.withChanges {
            var all = workspace.settings["analyticsAutomatic"] as? [String: [String: Any]] ?? [:]
            if enabled {
                guard let account = account(platform) else { throw WorkspaceError("Connect the account first.") }
                let available = capabilities(platform, account: account)
                guard available.followers || available.posts else { throw WorkspaceError("This account needs analytics read permission.") }
                all[platform.rawValue] = ["enabled": true, "session": account.connectionKey]
            } else {
                all[platform.rawValue] = ["enabled": false]
            }
            try workspace.set("analyticsAutomatic", to: all)
        }
    }

    func poll(now: Date = .now) async {
        for platform in SocialPlatform.allCases where automatic(platform) {
            if Task.isCancelled { return }
            guard let account = account(platform),
                  now.timeIntervalSince(attempt(state(platform, account: account))) >= 86_400 else { continue }
            _ = try? await refresh(platform, now: now)
        }
    }

    @discardableResult
    func refresh(_ platform: SocialPlatform, older: Bool = false, now: Date = .now) async throws -> [String] {
        guard !workspace.refreshingAnalytics.contains(platform) else { return [] }
        guard let initial = account(platform) else { throw WorkspaceError("Connect \(platform.name) first.") }
        let available = capabilities(platform, account: initial)
        guard available.followers || available.posts else { throw WorkspaceError("This account needs analytics read permission.") }
        let key = accountKey(platform, id: initial.id)
        let prior = state(platform, account: initial)
        let cursor = prior?["cursor"] ?? ""
        if older && cursor.isEmpty { return [] }
        if !older, now.timeIntervalSince(attempt(prior)) < 60 { return [] }
        workspace.refreshingAnalytics.insert(platform)
        defer { workspace.refreshingAnalytics.remove(platform) }
        var next = prior ?? WorkspaceRecord.new("analytics-state")
        next["id"] = "analytics-state-" + key
        next["platform"] = platform.rawValue
        next["accountId"] = initial.id
        next["accountKey"] = key
        next["lastAttemptAt"] = workspaceTimestamp(now)
        if !older { next["lastLatestAttemptAt"] = workspaceTimestamp(now) }
        try workspace.saveAnalyticsRows([next])

        let authorized: ManagedSocialAccount
        if let accountOverride { authorized = accountOverride }
        else { authorized = try await workspace.socialAccounts.authorized(platform) }
        guard authorized.connectionKey == initial.connectionKey else { throw WorkspaceError("The account changed. Refresh again.") }
        var warnings: [String] = []
        let timestamp = workspaceTimestamp(now)
        if available.followers && !older {
            do {
                var metrics = try await profile(platform, account: authorized)
                metrics["at"] = timestamp
                guard account(platform)?.connectionKey == initial.connectionKey else {
                    throw WorkspaceError("The account changed during analytics refresh.")
                }
                let id = "analytics-day-" + key + "-" + String(timestamp.prefix(10))
                var day = workspace.records.first { $0.kind == "analytics-day" && $0.id == id } ?? WorkspaceRecord.new("analytics-day")
                day["id"] = id
                day["platform"] = platform.rawValue
                day["accountId"] = initial.id
                day["accountKey"] = key
                day.fields["first"] = day.fields["first"] ?? metrics
                day.fields["last"] = metrics
                next["profileAt"] = timestamp
                next["profileError"] = ""
                try workspace.saveAnalyticsRows([day, next])
            } catch {
                warnings.append("Follower counts were unavailable. Previously saved observations were kept.")
                next["profileError"] = warnings.last ?? ""
            }
        }
        if available.posts {
            do {
                let page = try await posts(platform, account: authorized, cursor: older ? cursor : "")
                guard account(platform)?.connectionKey == initial.connectionKey else {
                    throw WorkspaceError("The account changed during analytics refresh.")
                }
                let posts = page.0.map { fields -> WorkspaceRecord in
                    let id = fields["postId"] as? String ?? ""
                    var post = WorkspaceRecord(kind: "analytics-post", fields: fields)
                    post["id"] = "analytics-post-" + key + "-" + accountKey(platform, id: id)
                    post["accountKey"] = key
                    post["accountId"] = initial.id
                    post["platform"] = platform.rawValue
                    post["observedAt"] = timestamp
                    return post
                }
                next["cursor"] = page.1
                next["postsAt"] = timestamp
                next["postsError"] = ""
                try workspace.saveAnalyticsRows(posts + [next])
            } catch {
                warnings.append("Post metrics were unavailable. Previously saved observations were kept.")
                next["postsError"] = warnings.last ?? ""
            }
        }
        guard account(platform)?.connectionKey == initial.connectionKey else { throw WorkspaceError("The account changed during analytics refresh.") }
        try workspace.saveAnalyticsRows([next])
        return warnings
    }

    private func attempt(_ state: WorkspaceRecord?) -> Date {
        if let number = state?.fields["lastLatestAttemptAt"] as? Double {
            return Date(timeIntervalSince1970: number / 1000)
        }
        return scheduleDate(state?["lastLatestAttemptAt"] ?? "") ?? .distantPast
    }

    private func profile(_ platform: SocialPlatform, account: ManagedSocialAccount) async throws -> [String: Any] {
        let url: URL
        let metricKey: String
        switch platform {
        case .x:
            url = URL(string: "https://api.x.com/2/users/")!.appending(path: account.id)
                .appending(queryItems: [.init(name: "user.fields", value: "public_metrics")])
            metricKey = "followers_count"
        case .instagram:
            url = URL(string: "https://graph.instagram.com/v25.0/")!.appending(path: account.id)
                .appending(queryItems: [.init(name: "fields", value: "id,followers_count,follows_count,media_count")])
            metricKey = "followers_count"
        case .tiktok:
            url = URL(string: "https://open.tiktokapis.com/v2/user/info/?fields=open_id,follower_count,following_count,likes_count,video_count")!
            metricKey = "follower_count"
        case .linkedin:
            url = URL(string: "https://api.linkedin.com/rest/memberFollowersCount?q=me")!
            metricKey = "memberFollowersCount"
        case .reddit: throw WorkspaceError("Reddit doesn’t provide follower counts for this connection.")
        }
        let (value, _) = try await transport.request(url, token: account.session.accessToken,
                                                      headers: platform == .linkedin ? LinkedInPages.headers : [:])
        let data = value["data"] as? [String: Any] ?? [:]
        let metrics: [String: Any]
        switch platform {
        case .x:
            guard data["id"] as? String == account.id, value["errors"] == nil else { throw WorkspaceError("Incomplete X profile.") }
            metrics = data["public_metrics"] as? [String: Any] ?? [:]
        case .instagram:
            guard value["id"] as? String == account.id else { throw WorkspaceError("Incomplete Instagram profile.") }
            metrics = value
        case .tiktok:
            let user = data["user"] as? [String: Any] ?? [:]
            guard user["open_id"] as? String == account.id else { throw WorkspaceError("Incomplete TikTok profile.") }
            metrics = user
        default: metrics = (value["elements"] as? [[String: Any]])?.first ?? [:]
        }
        guard let count = AnalyticsReport.integerMetric(metrics[metricKey]) else { throw WorkspaceError("Follower count unavailable.") }
        var observation: [String: Any] = ["followers": count]
        observation["following"] = AnalyticsReport.integerMetric(metrics["following_count"] ?? metrics["follows_count"])
        observation["accountPosts"] = AnalyticsReport.integerMetric(metrics["tweet_count"] ?? metrics["post_count"] ?? metrics["media_count"] ?? metrics["video_count"])
        observation["totalLikes"] = AnalyticsReport.integerMetric(metrics["likes_count"])
        return observation
    }

    private func posts(_ platform: SocialPlatform, account: ManagedSocialAccount,
                       cursor: String) async throws -> ([[String: Any]], String) {
        let url: URL
        let params: [String: Any]?
        var headers: [String: String] = [:]
        switch platform {
        case .x:
            var query: [URLQueryItem] = [.init(name: "max_results", value: "25"), .init(name: "exclude", value: "retweets"),
                                         .init(name: "tweet.fields", value: "created_at,public_metrics")]
            if !cursor.isEmpty { query.append(.init(name: "pagination_token", value: cursor)) }
            url = URL(string: "https://api.x.com/2/users/")!.appending(path: account.id).appending(path: "tweets").appending(queryItems: query)
            params = nil
        case .instagram:
            var query: [URLQueryItem] = [.init(name: "fields", value: "id,caption,timestamp,permalink,like_count,comments_count"), .init(name: "limit", value: "25")]
            if !cursor.isEmpty { query.append(.init(name: "after", value: cursor)) }
            url = URL(string: "https://graph.instagram.com/v25.0/")!.appending(path: account.id).appending(path: "media").appending(queryItems: query)
            params = nil
        case .tiktok:
            url = URL(string: "https://open.tiktokapis.com/v2/video/list/?fields=id,title,video_description,create_time,share_url,like_count,comment_count,share_count,view_count")!
            if !cursor.isEmpty {
                guard let value = Int64(cursor), value >= 0 else { throw WorkspaceError("Invalid TikTok analytics cursor.") }
                params = ["max_count": 20, "cursor": value]
            } else { params = ["max_count": 20] }
        case .reddit:
            var query: [URLQueryItem] = [.init(name: "limit", value: "25"), .init(name: "raw_json", value: "1")]
            if !cursor.isEmpty { query.append(.init(name: "after", value: cursor)) }
            url = URL(string: "https://oauth.reddit.com/user/")!.appending(path: account.username).appending(path: "submitted").appending(queryItems: query)
            params = nil
            headers["User-Agent"] = "desktop:com.protomota.inkspring:v1.0 (Inkspring; https://inkspring.ai)"
        case .linkedin: return ([], "")
        }
        let (value, _) = try await transport.request(url, token: account.session.accessToken, method: params == nil ? "GET" : "POST", json: params, headers: headers)
        let data = value["data"] as? [String: Any] ?? [:]
        let meta = value["meta"] as? [String: Any] ?? [:]
        let paging = value["paging"] as? [String: Any] ?? [:]
        let raw: [[String: Any]]?
        let next: String
        switch platform {
        case .x:
            guard value["errors"] == nil else { throw WorkspaceError("Incomplete X analytics page.") }
            raw = value["data"] as? [[String: Any]] ?? (meta["result_count"] as? Int == 0 ? [] : nil)
            next = meta["next_token"] as? String ?? ""
        case .instagram:
            raw = value["data"] as? [[String: Any]]
            next = paging["next"] is String ? (paging["cursors"] as? [String: Any])?["after"] as? String ?? "" : ""
        case .tiktok:
            raw = data["videos"] as? [[String: Any]]
            next = data["has_more"] as? Bool == true ? (data["cursor"] as? NSNumber)?.stringValue ?? "" : ""
        default:
            raw = try (data["children"] as? [[String: Any]])?.map { child in
                guard child["kind"] as? String == "t3", let post = child["data"] as? [String: Any],
                      (post["author"] as? String)?.caseInsensitiveCompare(account.username) == .orderedSame else {
                    throw WorkspaceError("Incomplete Reddit analytics page.")
                }
                return post
            }
            next = data["after"] as? String ?? ""
        }
        guard let raw, raw.count <= 25, next.utf8.count <= 4000 else { throw WorkspaceError("Incomplete analytics page.") }
        return (try raw.map { try post($0, platform: platform) }, next)
    }

    private func post(_ row: [String: Any], platform: SocialPlatform) throws -> [String: Any] {
        let rawID = platform == .reddit ? row["name"] : row["id"]
        let id = rawID as? String ?? (rawID as? NSNumber)?.stringValue ?? ""
        let date: Date?
        if let text = row["created_at"] as? String ?? row["timestamp"] as? String { date = scheduleDate(text) }
        else if let seconds = row["create_time"] as? Double ?? row["created_utc"] as? Double, seconds.isFinite,
                (0...9_000_000_000).contains(seconds) { date = Date(timeIntervalSince1970: seconds) }
        else { date = nil }
        guard !id.isEmpty, id.utf8.count <= 100, let date else { throw WorkspaceError("Incomplete analytics post.") }
        let x = row["public_metrics"] as? [String: Any] ?? [:]
        var metrics: [String: Any] = [:]
        metrics["likes"] = AnalyticsReport.integerMetric(x["like_count"] ?? row["like_count"])
        metrics["replies"] = AnalyticsReport.integerMetric(x["reply_count"] ?? row["comments_count"] ?? row["comment_count"] ?? row["num_comments"])
        if platform == .x {
            let shares = [x["retweet_count"] ?? x["repost_count"], x["quote_count"]].compactMap {
                AnalyticsReport.integerMetric($0)
            }
            if !shares.isEmpty { metrics["shares"] = AnalyticsReport.integerMetric(shares.reduce(0, +)) }
        } else {
            metrics["shares"] = AnalyticsReport.integerMetric(row["share_count"])
        }
        metrics["views"] = AnalyticsReport.integerMetric(x["impression_count"] ?? row["view_count"])
        if platform == .reddit { metrics["score"] = AnalyticsReport.integerMetric(row["score"], signed: true) }
        let content = row["text"] as? String ?? row["caption"] as? String ?? row["video_description"] as? String ?? row["title"] as? String ?? ""
        let address = switch platform {
        case .x: "https://x.com/i/web/status/" + id
        case .reddit: "https://www.reddit.com" + (row["permalink"] as? String ?? "")
        default: row["permalink"] as? String ?? row["share_url"] as? String ?? ""
        }
        let hosts = ["x.com", "instagram.com", "www.instagram.com", "tiktok.com", "www.tiktok.com", "www.reddit.com"]
        let link = URL(string: address).flatMap { $0.scheme == "https" && hosts.contains($0.host ?? "") && $0.user == nil && $0.password == nil ? $0.absoluteString : nil } ?? ""
        return ["postId": id, "publishedAt": workspaceTimestamp(date), "content": String(content.prefix(5000)), "url": link, "metrics": metrics]
    }
}
