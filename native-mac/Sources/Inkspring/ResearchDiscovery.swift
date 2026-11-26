import Foundation

enum ResearchPlatform: String, CaseIterable, Identifiable {
    case x, news, instagram, linkedin
    var id: Self { self }
    var title: String { platformName(rawValue) }
}

enum ResearchDraft {
    static func post(from source: WorkspaceRecord, platform: String, hook: String = "", angle: String = "") -> WorkspaceRecord {
        var draft = WorkspaceRecord.new("draft", projectID: source.projectID)
        draft["title"] = source.title
        draft["platform"] = platform
        if platform == "instagram" { draft["format"] = "image" }
        let direction = [hook.isEmpty ? "" : "Original hook: " + hook, angle].filter { !$0.isEmpty }.joined(separator: "\n")
        draft["brief"] = direction.isEmpty ? "Write an original post inspired by this reference: " + source.title : direction
        draft.fields["sourceIds"] = [source.id]
        return draft
    }

    static func reply(to source: [String: Any], projectID: String) throws -> WorkspaceRecord {
        guard let address = source["url"] as? String, let url = XQuoteComposer.postURL(address),
              let body = source["text"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError("Choose an X post with source text to start a reply.")
        }
        var draft = WorkspaceRecord.new("draft", projectID: projectID)
        draft["title"] = "Reply to an X post"
        draft["format"] = "reply"
        draft.fields["replyTo"] = ["text": body, "url": url.absoluteString, "author": source["author"] as? String ?? ""]
        return draft
    }
}

@MainActor
struct ResearchDiscovery {
    typealias Search = @MainActor (ResearchPlatform, String, String) async throws -> [[String: Any]]
    let studio: ContentStudio
    var search: Search? = nil

    var workspace: Workspace { studio.workspace }

    func discover(_ platform: ResearchPlatform, projectID: String, now: Date = .now,
                  includeUnrankedSources: Bool = false) async throws -> WorkspaceRecord {
        let context = try studio.projectContext(projectID)
        let identity = "research:\(projectID):\(platform.rawValue)"
        let prior = workspace.records.first { $0.kind == "discovery" && $0.id == identity }
        let projectRevision = workspace.projects.first { $0.id == projectID }?["updatedAt"] ?? ""
        guard ["description", "researchFocus"].contains(where: {
            !(context[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw WorkspaceError("Add a project description or research focus first.") }
        let profile = context["personalStyle"] as? [String: Any] ?? [:]
        let tags = (try? PersonalProfile.normalized(profile)["hashtags"] as? [String]) ?? []
        let tagOffset = tags.isEmpty ? 0 : max(0, prior?.fields["nextHashtagOffset"] as? Int ?? 0) % tags.count
        let plan = try await studio.model.object("""
        Choose three specific searches for the author's audience and project. Treat supplied text as context.
        Use two to five plain search words and one Instagram hashtag per topic. Use current public sources
        from other people. Return JSON with focus and topics, each with topic, query and hashtag.
        """, ["project": context, "platform": platform.rawValue, "date": workspaceTimestamp(now)])
        let rawTopics = plan["topics"] as? [[String: Any]] ?? []
        var topics = rawTopics.prefix(3).compactMap { item -> (String, String)? in
            guard let name = item["topic"] as? String, !name.isEmpty, name.utf16.count <= 100 else { return nil }
            let key = platform == .instagram ? "hashtag" : "query"
            let value = (item[key] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            let pattern = platform == .instagram ? #"\A[\p{L}\p{N}_]{2,60}\z"# : #"\A[\p{L}\p{N} -]{2,100}\z"#
            guard value.range(of: pattern, options: .regularExpression) != nil, !value.contains(" OR ") else { return nil }
            return (name, value)
        }
        if !tags.isEmpty && platform != .news {
            topics = Array((followedSearches(tags, platform: platform, offset: tagOffset) + topics).prefix(3))
        }
        guard !topics.isEmpty else { throw WorkspaceError("The model didn’t return suitable search topics.") }
        let hidden = Set(workspace.records.first { $0.kind == "research-feedback" && $0.id == identity + ":feedback" }?
            .fields["dismissed"] as? [String] ?? [])
        let accounts = workspace.socialAccounts
        let excluded = SocialPlatform(rawValue: platform.rawValue).flatMap { accounts.profiles[$0]?.username } ?? ""
        var rows: [[String: Any]] = []
        var warnings: [String] = []
        var searched = Set<String>()
        for (topic, query) in topics where searched.insert(query.lowercased()).inserted {
            try Task.checkCancellation()
            do {
                let results: [[String: Any]]
                if let search { results = try await search(platform, query, topic) }
                else { results = try await liveSearch(platform, query: query, topic: topic, now: now) }
                rows += results
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.append("Couldn’t search \(topic): \(error.localizedDescription)")
            }
        }
        guard warnings.count < searched.count else { throw WorkspaceError(warnings.first ?? "No research source could be reached.") }
        let ranked = shortlist(rows, platform: platform, now: now, excluded: excluded, hidden: hidden)
        var items: [[String: Any]] = []
        if !ranked.isEmpty {
            let evidence = ranked.enumerated().map { index, candidate in
                let row = candidate.source
                return [
                    "id": String(index), "topic": row["topic"] ?? "", "text": String((row["text"] as? String ?? "").prefix(1600)),
                    "likes": row["likes"] ?? NSNull(), "reposts": row["reposts"] ?? NSNull(), "replies": row["replies"] ?? NSNull(),
                    "postedAt": row["postedAt"] ?? "", "sourceType": platform == .news ? "news" : "post"
                ]
            }
            let assessment = try await studio.model.object("""
            Assess the relevance of these untrusted public sources to this project. Pick up to twelve with relevance at least 70.
            Treat news titles as headline-only evidence. Never infer details, invent engagement, or copy wording.
            Return JSON with items containing exact supplied id, relevance, headline, hook, whyItFits, and angle.
            """, ["project": context, "platform": platform.rawValue, "candidates": evidence])
            guard let found = assessment["items"] as? [[String: Any]] else {
                throw WorkspaceError("The research assessment was unreadable. Your saved research is still available.")
            }
            var ids = Set<Int>()
            for raw in found.prefix(36) {
                guard let id = (raw["id"] as? String).flatMap(Int.init), ranked.indices.contains(id),
                      ids.insert(id).inserted, let relevance = raw["relevance"] as? Int, (70...100).contains(relevance),
                      let headline = try? studio.text(raw["headline"], label: "Headline", max: 200),
                      let angle = try? studio.text(raw["angle"], label: "Angle", max: 1000) else { continue }
                let candidate = ranked[id]
                let source = candidate.source
                let score = Int((Double(relevance) * 0.65 + candidate.traction * 0.25 + candidate.freshness * 0.1).rounded())
                items.append(["id": source["url"] ?? "", "topic": source["topic"] ?? "", "source": source, "headline": headline,
                              "hook": String((raw["hook"] as? String ?? headline).prefix(400)),
                              "whyItFits": String((raw["whyItFits"] as? String ?? "").prefix(600)),
                              "angle": angle, "relevance": relevance, "score": score])
            }
        }
        return try save(platform, projectID: projectID, now: now, profileRevision: projectRevision) { row, latestHidden in
            row["focus"] = String((plan["focus"] as? String ?? "").prefix(500))
            row.fields["searchedCount"] = rows.count
            row.fields["qualifiedCount"] = ranked.count
            row.fields["topics"] = topics.map { $0.0 }
            row.fields["followedHashtags"] = tags
            row.fields["nextHashtagOffset"] = tags.isEmpty || platform == .news
                ? 0 : (tagOffset + 3) % tags.count
            row.fields["warnings"] = warnings
            let visible = items.filter { !latestHidden.contains($0["id"] as? String ?? "") }
            row.fields["items"] = includeUnrankedSources && visible.isEmpty
                ? sourceItems(ranked.filter { !latestHidden.contains($0.source["url"] as? String ?? "") })
                : diversify(visible)
        }
    }

    func browse(_ platform: ResearchPlatform, projectID: String, topic: String, note: String = "", now: Date = .now)
        async throws -> WorkspaceRecord {
        guard let project = workspace.projects.first(where: { $0.id == projectID }) else {
            throw WorkspaceError("Choose an existing project.")
        }
        let query = platform == .instagram ? String(topic.filter { $0.isLetter || $0.isNumber }.prefix(60)) : topic
        let rows: [[String: Any]]
        if let search { rows = try await search(platform, query, topic) }
        else { rows = try await liveSearch(platform, query: query, topic: topic, now: now) }
        let account = SocialPlatform(rawValue: platform.rawValue)
        let excluded = account.flatMap { workspace.socialAccounts.profiles[$0]?.username } ?? ""
        return try save(platform, projectID: projectID, now: now, profileRevision: project["updatedAt"]) { row, hidden in
            let ranked = shortlist(rows, platform: platform, now: now, excluded: excluded, hidden: hidden)
            row["focus"] = note
            row.fields["searchedCount"] = rows.count
            row.fields["qualifiedCount"] = ranked.count
            row.fields["topics"] = [topic]
            row.fields["warnings"] = []
            row.fields["items"] = sourceItems(ranked)
        }
    }

    private func sourceItems(_ ranked: [Candidate]) -> [[String: Any]] {
        ranked.prefix(12).map {
            ["id": $0.source["url"] ?? "", "topic": $0.source["topic"] ?? "",
             "source": $0.source, "headline": $0.source["title"] ?? ""]
        }
    }

    private func save(_ platform: ResearchPlatform, projectID: String, now: Date, profileRevision: String,
                      update: (inout WorkspaceRecord, Set<String>) -> Void) throws -> WorkspaceRecord {
        try Task.checkCancellation()
        let identity = "research:\(projectID):\(platform.rawValue)"
        return try studio.persist {
            let hidden = Set(workspace.records.first { $0.kind == "research-feedback" && $0.id == identity + ":feedback" }?
                .fields["dismissed"] as? [String] ?? [])
            var row = workspace.records.first { $0.kind == "discovery" && $0.id == identity }
                ?? WorkspaceRecord.new("discovery", projectID: projectID)
            if let latest = scheduleDate(row["searchedAt"]), latest > now { return row }
            row["id"] = identity
            row["title"] = platform.title
            row["platform"] = platform.rawValue
            row["profileUpdatedAt"] = profileRevision
            row["searchedAt"] = workspaceTimestamp(now)
            update(&row, hidden)
            return try workspace.save(row)
        }
    }

    func refreshIdeas(projectID: String, withResearch: Bool, automatic: Bool = false) async throws -> ContentStudio.RefreshResult {
        var warnings: [String] = []
        if withResearch {
            let profile = workspace.settings["personalProfile"] as? [String: Any] ?? [:]
            let sources = (try? PersonalProfile.normalized(profile)["researchSources"] as? [String]) ?? ["x", "news"]
            for platform in sources.compactMap(ResearchPlatform.init(rawValue:)) {
                try Task.checkCancellation()
                if automatic {
                    try workspace.reload()
                    let target = IdeaQueuePlan.target(workspace.settings["ideaQueueTarget"])
                    let open = workspace.records.filter {
                        $0.isPendingPostIdea && $0.projectID == projectID
                    }.count
                    if workspace.settings["ideaQueueAutomatic"] as? Bool != true || open >= target { break }
                }
                let prior = workspace.records.first {
                    $0.kind == "discovery" && $0.projectID == projectID && $0["platform"] == platform.rawValue
                }
                let revision = workspace.projects.first { $0.id == projectID }?["updatedAt"]
                if let prior, let date = scheduleDate(prior["searchedAt"]), Date.now.timeIntervalSince(date) < 3600,
                   prior["profileUpdatedAt"].isEmpty || prior["profileUpdatedAt"] == revision { continue }
                let hasXConnection = platform == .x && (ProviderKey.x.isSaved || (try? workspace.socialAccounts.savedAccount(.x)) != nil)
                if search == nil && platform != .news && !ProviderKey.apify.isSaved && !hasXConnection {
                    warnings.append(platform == .x ? "Connect X or add an Apify key for X research." : "\(platform.title) research needs an Apify key.")
                    continue
                }
                do { _ = try await discover(platform, projectID: projectID) }
                catch { warnings.append(error.localizedDescription) }
            }
        }
        return try await studio.refresh(projectID: projectID, warnings: warnings, automatic: automatic)
    }

    private func followedSearches(_ tags: [String], platform: ResearchPlatform, offset: Int) -> [(String, String)] {
        if platform == .x {
            return stride(from: 0, to: tags.count, by: 10).map { start in
                let group = tags.dropFirst(start).prefix(10).map { "#" + $0 }
                return (group.joined(separator: ", "), "(" + group.joined(separator: " OR ") + ")")
            }
        }
        return (0..<min(3, tags.count)).map { index in
            let tag = tags[(offset + index) % tags.count]
            return ("#" + tag, platform == .instagram ? tag : "#" + tag)
        }
    }

    private struct Candidate {
        let source: [String: Any]
        let traction: Double
        let freshness: Double
        var rank: Double { traction + freshness * 0.3 }
    }

    private func shortlist(_ rows: [[String: Any]], platform: ResearchPlatform, now: Date,
                           excluded: String, hidden: Set<String>) -> [Candidate] {
        var urls = Set<String>()
        var bodies = Set<String>()
        let ownName = authorKey(excluded)
        let minimumLength = platform == .news ? 10 : 40
        let qualified: [Candidate] = rows.compactMap { item in
            guard let url = item["url"] as? String, !hidden.contains(url),
                  let body = item["text"] as? String,
                  let date = (item["postedAt"] as? String).flatMap(scheduleDate),
                  item["isReply"] as? Bool != true, item["isRepost"] as? Bool != true,
                  ownName.isEmpty || authorKey(item["author"] as? String ?? "") != ownName else { return nil }
            let age = now.timeIntervalSince(date)
            guard (-300...604_800).contains(age), body.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumLength else {
                return nil
            }
            let normalized = body.lowercased()
                .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let likes = Double(Self.metric(item["likes"]) ?? 0)
            let reposts = Double(Self.metric(item["reposts"]) ?? 0)
            let replies = Double(Self.metric(item["replies"]) ?? 0)
            let interactions = likes + 2 * (reposts + replies)
            guard platform == .news || interactions >= 10 else { return nil }
            guard !normalized.isEmpty, !urls.contains(url), bodies.insert(normalized).inserted else { return nil }
            urls.insert(url)
            let traction = platform == .news ? 0 : min(100, log1p(interactions) * 13)
            let freshness = 100 / (1 + max(1, age / 3600) / 48)
            return Candidate(source: item, traction: traction, freshness: freshness)
        }
        return Array(qualified.sorted { $0.rank > $1.rank }.prefix(36))
    }

    private func diversify(_ items: [[String: Any]]) -> [[String: Any]] {
        var authors: [String: Int] = [:]
        var topics: [String: Int] = [:]
        let ordered = items.sorted { ($0["score"] as? Int ?? 0) > ($1["score"] as? Int ?? 0) }
        return Array(ordered.filter { item in
            let source = item["source"] as? [String: Any]
            let author = authorKey(source?["author"] as? String ?? "")
            let topic = item["topic"] as? String ?? ""
            guard authors[author, default: 0] < 2, topics[topic, default: 0] < 5 else { return false }
            authors[author, default: 0] += 1
            topics[topic, default: 0] += 1
            return true
        }.prefix(12))
    }

    private func authorKey(_ author: String) -> String {
        author.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))).lowercased()
    }

    private static func metric(_ raw: Any?) -> Int? {
        let count = raw as? Int ?? (raw as? String).flatMap(Int.init)
        return count.flatMap { $0 >= 0 ? $0 : nil }
    }

    func liveSearch(_ platform: ResearchPlatform, query: String, topic: String, days: Int = 7, now: Date = .now,
                    preferApify: Bool = false) async throws -> [[String: Any]] {
        if platform == .news { return try await NewsSearch.fetch(query: query, topic: topic, days: days) }
        let transport = SocialTransport()
        if platform == .x, !preferApify, let token = try await workspace.socialAccounts.xReadToken() {
            let url = URL(string: "https://api.x.com/2/tweets/search/recent")!.appending(queryItems: [
                .init(name: "query", value: query + " -is:retweet -is:reply"), .init(name: "sort_order", value: "relevancy"),
                .init(name: "max_results", value: "20"), .init(name: "expansions", value: "author_id"),
                .init(name: "tweet.fields", value: "author_id,public_metrics,created_at,note_tweet,referenced_tweets"),
                .init(name: "user.fields", value: "username,public_metrics")
            ])
            let (value, _) = try await transport.request(url, token: token)
            if value["data"] == nil, (value["meta"] as? [String: Any])?["result_count"] as? Int != 0 {
                throw WorkspaceError("X returned an unreadable search result.")
            }
            let users = ((value["includes"] as? [String: Any])?["users"] as? [[String: Any]]) ?? []
            return (value["data"] as? [[String: Any]] ?? []).prefix(20).compactMap { row in
                guard let id = row["id"] as? String, id.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil else { return nil }
                let body = (row["note_tweet"] as? [String: Any])?["text"] as? String ?? row["text"] as? String
                let author = users.first { $0["id"] as? String == row["author_id"] as? String }?["username"]
                let metrics = row["public_metrics"] as? [String: Any] ?? [:]
                let refs = row["referenced_tweets"] as? [[String: Any]] ?? []
                return item(body, url: "https://x.com/i/web/status/" + id, author: author, origin: "X · Direct API",
                            date: row["created_at"], topic: topic, likes: metrics["like_count"], shares: metrics["retweet_count"],
                            replies: metrics["reply_count"], reply: refs.contains { $0["type"] as? String == "replied_to" },
                            repost: refs.contains { $0["type"] as? String == "retweeted" })
            }
        }
        let actor: String
        let payload: [String: Any]
        switch platform {
        case .x:
            actor = "apidojo~twitter-scraper-lite"
            let since = String(workspaceTimestamp(now.addingTimeInterval(-Double(days) * 86_400)).prefix(10))
            payload = ["maxItems": 20, "sort": "Top", "searchTerms": [query + " since:" + since + " -filter:retweets -filter:replies"]]
        case .instagram:
            actor = "apify~instagram-hashtag-scraper"
            payload = ["hashtags": [query], "resultsType": "posts", "resultsLimit": 20]
        case .linkedin:
            actor = "harvestapi~linkedin-post-search"
            payload = ["searchQueries": [query], "maxPosts": 20, "postedLimit": "week", "sortBy": "relevance",
                       "scrapeComments": false, "scrapeReactions": false]
        case .news:
            return []
        }
        let url = URL(string: "https://api.apify.com/v2/acts/\(actor)/run-sync-get-dataset-items?timeout=120")!
        let (result, _) = try await transport.request(url, token: ProviderKey.apify.read(), method: "POST",
                                                       json: payload, timeout: 130, acceptsArray: true)
        guard let rows = result["items"] as? [[String: Any]], !rows.contains(where: { $0["error"] != nil }) else {
            throw WorkspaceError("Apify couldn’t return search posts. Check the actor and its API access.")
        }
        return rows.prefix(20).compactMap { row in
            let engagement = row["engagement"] as? [String: Any] ?? [:]
            let author = row["author"] as? [String: Any] ?? [:]
            let date = row["postedAt"] as? [String: Any] ?? [:]
            let fallback: String?
            if platform == .x, let id = row["id"] as? String { fallback = "https://x.com/i/web/status/" + id }
            else if platform == .instagram, let id = row["shortCode"] as? String { fallback = "https://www.instagram.com/p/" + id + "/" }
            else { fallback = nil }
            guard let raw = row["linkedinUrl"] as? String ?? row["url"] as? String ?? fallback,
                  let url = Self.canonical(raw, platform: platform) else { return nil }
            return item(row["content"] ?? row["fullText"] ?? row["text"] ?? row["caption"], url: url,
                        author: (platform == .x ? author["userName"] : author["name"]) ?? author["publicIdentifier"] ?? row["ownerUsername"],
                        origin: platform.title + " · Apify",
                        date: date["date"] ?? date["timestamp"] ?? row["createdAt"] ?? row["timestamp"] ?? row["takenAt"],
                        topic: topic, likes: engagement["likes"] ?? row["likeCount"] ?? row["likesCount"],
                        shares: engagement["shares"] ?? row["retweetCount"], replies: engagement["comments"] ?? row["replyCount"] ?? row["commentsCount"],
                        reply: row["isReply"] as? Bool == true || platform == .linkedin && (row["type"] as? String).map { $0 != "post" } == true,
                        repost: row["isRetweet"] as? Bool == true || row["isRepost"] as? Bool == true)
        }
    }

    private func item(_ raw: Any?, url: String, author: Any?, origin: String, date: Any?, topic: String,
                      likes: Any?, shares: Any?, replies: Any?, reply: Bool, repost: Bool) -> [String: Any]? {
        guard let raw = raw as? String, !raw.isEmpty, let time = Self.parseDate(date) else { return nil }
        var fields: [String: Any] = ["title": String(raw.prefix(100)), "text": String(raw.prefix(7500)), "url": url,
                                    "author": String((author as? String ?? "").prefix(150)), "origin": origin, "topic": topic,
                                    "postedAt": workspaceTimestamp(time), "isReply": reply, "isRepost": repost]
        fields["likes"] = Self.metric(likes)
        fields["reposts"] = Self.metric(shares)
        fields["replies"] = Self.metric(replies)
        return fields
    }

    private static func parseDate(_ input: Any?) -> Date? {
        if let number = input as? Double, number.isFinite { return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number) }
        guard let text = input as? String else { return nil }
        if let date = scheduleDate(text) { return date }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE MMM dd HH:mm:ss Z yyyy", "EEE, dd MMM yyyy HH:mm:ss z"] {
            parser.dateFormat = format
            if let date = parser.date(from: text) { return date }
        }
        return nil
    }

    private static func canonical(_ value: String, platform: ResearchPlatform) -> String? {
        guard value.utf8.count <= 3000, let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil, let host = url.host()?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch platform {
        case .x:
            guard ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].contains(host),
                  parts.dropLast().last == "status", let id = parts.last,
                  id.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil else { return nil }
            return "https://x.com/i/web/status/" + id
        case .instagram:
            guard ["instagram.com", "www.instagram.com"].contains(host), parts.count == 2, ["p", "reel", "tv"].contains(parts[0]),
                  parts[1].range(of: #"\A[A-Za-z0-9_-]{1,100}\z"#, options: .regularExpression) != nil else { return nil }
            return "https://www.instagram.com/p/" + parts[1] + "/"
        case .linkedin:
            guard ["linkedin.com", "www.linkedin.com"].contains(host),
                  url.path.range(of: #"\A/(?:posts/[^/]+|feed/update/urn:li:(?:activity|share|ugcPost):[0-9]+)/?\z"#,
                                 options: .regularExpression) != nil else { return nil }
            return "https://www.linkedin.com" + url.path
        case .news: return nil
        }
    }
}

private final class NewsSearch: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    private var item: [String: String]?
    private var field: String?
    private var root = false

    @MainActor
    static func fetch(query: String, topic: String, days: Int) async throws -> [[String: Any]] {
        let url = URL(string: "https://news.google.com/rss/search")!.appending(queryItems: [
            .init(name: "q", value: query + " when:\(days)d"), .init(name: "hl", value: "en-US"), .init(name: "gl", value: "US"), .init(name: "ceid", value: "US:en")
        ])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: NoHTTPRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 2_097_152 else {
            throw WorkspaceError("Google News returned an unavailable feed.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw WorkspaceError("The news feed is too large.") }
            data.append(byte)
        }
        let xml = String(decoding: data, as: UTF8.self)
        guard xml.range(of: #"<!DOCTYPE|<!ENTITY"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw WorkspaceError("The news feed uses unsupported XML.")
        }
        let reader = NewsSearch()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.root else { throw WorkspaceError("The news feed was unreadable.") }
        let parserDate = DateFormatter()
        parserDate.locale = Locale(identifier: "en_US_POSIX")
        parserDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return reader.items.prefix(20).compactMap { item in
            guard let raw = item["link"], let url = URL(string: raw), url.scheme == "https", url.host == "news.google.com",
                  url.user == nil, url.password == nil, url.path.hasPrefix("/rss/articles/"),
                  let title = item["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let date = parserDate.date(from: item["pubDate"] ?? "") else { return nil }
            let source = item["source"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = " - " + source
            let headline = !source.isEmpty && title.hasSuffix(suffix) ? String(title.dropLast(suffix.count)) : title
            return ["title": String(headline.prefix(500)), "text": String(headline.prefix(500)), "url": url.absoluteString,
                    "author": String(source.prefix(200)), "origin": "News · Google News RSS", "topic": topic,
                    "sourceType": "news", "postedAt": workspaceTimestamp(date)]
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if name == "rss" { root = true }
        if name == "item", items.count < 50 { item = [:] }
        if item != nil, ["title", "link", "source", "pubDate"].contains(name) { field = name }
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        if let field, (item?[field]?.utf8.count ?? 0) < 6000 { item?[field, default: ""] += String(text.prefix(6000)) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == field { field = nil }
        if name == "item", let item { items.append(item); self.item = nil; field = nil }
    }
}
