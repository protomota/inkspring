import Foundation

@MainActor
struct ReplyInbox {
    let workspace: Workspace
    var transport = SocialTransport()
    var accountOverride: ManagedSocialAccount? = nil

    private func savedAccount() throws -> ManagedSocialAccount? {
        if let accountOverride { return accountOverride }
        return try workspace.socialAccounts.savedAccount(.x)
    }

    private func canRead(_ account: ManagedSocialAccount) -> Bool {
        (account.session.scopes ?? "").split { $0.isWhitespace || $0 == "," }.contains("tweet.read")
    }

    private func state(_ account: ManagedSocialAccount) -> [String: Any] {
        let states = workspace.settings["replyInboxSync"] as? [String: [String: Any]] ?? [:]
        return states[account.connectionKey] ?? [:]
    }

    var monitoring: Bool {
        guard let account = try? savedAccount(), canRead(account),
              let setting = workspace.settings["replyMonitoringX"] as? [String: Any] else { return false }
        return setting["enabled"] as? Bool == true && setting["session"] as? String == account.connectionKey
    }

    var hasOlder: Bool {
        guard let account = try? savedAccount() else { return false }
        return !(state(account)["historyCursor"] as? String ?? "").isEmpty
    }

    var lastChecked: Date? {
        guard let account = try? savedAccount() else { return nil }
        return (state(account)["lastSuccessAt"] as? String).flatMap(scheduleDate)
    }

    var rows: [WorkspaceRecord] {
        let account = try? savedAccount()
        let published = Set(workspace.records.filter {
            $0.kind == "publication" && $0["platform"] == "x" && $0["status"] == "published" && $0["accountId"] == account?.id
        }.map { $0["replyToId"] })
        return workspace.records.filter { $0.kind == "reply-inbox" && (account == nil || $0["accountId"] == account?.id) }
            .map { value in
                var row = value
                if published.contains(row["postId"]) { row["status"] = "replied" }
                return row
            }
            .map { row in (row: row, date: scheduleDate(row["createdAt"]) ?? .distantPast) }
            .sorted { $0.date > $1.date }
            .map(\.row)
    }

    func setMonitoring(_ enabled: Bool) throws {
        if enabled {
            guard let account = try savedAccount(), canRead(account) else {
                throw WorkspaceError("Connect X with read permission before enabling monitoring.")
            }
            try workspace.set("replyMonitoringX", to: ["enabled": true, "session": account.connectionKey])
        } else {
            try workspace.set("replyMonitoringX", to: ["enabled": false])
        }
    }

    func poll(now: Date = .now) async {
        guard monitoring, let account = try? savedAccount() else { return }
        let attempt = (state(account)["lastAttemptAt"] as? String).flatMap(scheduleDate) ?? .distantPast
        guard now.timeIntervalSince(attempt) >= 300 else { return }
        do { _ = try await refresh(now: now) }
        catch { workspace.notice = error.localizedDescription }
    }

    @discardableResult
    func refresh(older: Bool = false, now: Date = .now) async throws -> Int {
        guard !workspace.refreshingReplies else { return 0 }
        try workspace.reload()
        guard let initial = try savedAccount(), canRead(initial), validID(initial.id) else {
            throw WorkspaceError("Connect X with read permission in Connections.")
        }
        let sync = state(initial)
        let since = sync["sinceId"] as? String ?? ""
        let cursor = sync[older ? "historyCursor" : "recentCursor"] as? String ?? ""
        if older && cursor.isEmpty { return 0 }
        workspace.refreshingReplies = true
        defer { workspace.refreshingReplies = false }
        let attempt = workspaceTimestamp(now)
        try workspace.saveReplyPage([], session: initial.connectionKey,
                                    state: sync.merging(["lastAttemptAt": attempt]) { _, new in new })
        let account: ManagedSocialAccount
        if let accountOverride { account = accountOverride }
        else { account = try await workspace.socialAccounts.authorized(.x) }
        guard account.connectionKey == initial.connectionKey else { throw WorkspaceError("The X connection changed. Refresh again.") }
        let base = URL(string: "https://api.x.com/2/users/")!.appending(path: account.id).appending(path: "mentions")
        var query: [URLQueryItem] = [
            .init(name: "max_results", value: "25"),
            .init(name: "tweet.fields", value: "author_id,created_at,conversation_id,in_reply_to_user_id,referenced_tweets"),
            .init(name: "expansions", value: "author_id,referenced_tweets.id,referenced_tweets.id.author_id"),
            .init(name: "user.fields", value: "name,username")
        ]
        if !older && validID(since) { query.append(.init(name: "since_id", value: since)) }
        if !cursor.isEmpty { query.append(.init(name: "pagination_token", value: cursor)) }
        let (value, _) = try await transport.request(base.appending(queryItems: query), token: account.session.accessToken)
        let meta = value["meta"] as? [String: Any] ?? [:]
        let rows = value["data"] as? [[String: Any]] ?? []
        guard (value["data"] is [[String: Any]] || value["data"] == nil && meta["result_count"] as? Int == 0),
              rows.count <= 25,
              rows.allSatisfy({ validID($0["id"] as? String ?? "") && validID($0["author_id"] as? String ?? "") && $0["text"] is String }) else {
            throw WorkspaceError("X returned an incomplete reply page. Refresh again.")
        }
        let includes = value["includes"] as? [String: Any] ?? [:]
        let users = includes["users"] as? [[String: Any]] ?? []
        let parents = includes["tweets"] as? [[String: Any]] ?? []
        let errors = value["errors"] as? [[String: Any]] ?? []
        if !errors.isEmpty {
            let ids = Set(rows.compactMap { $0["id"] as? String })
            let related = Set(rows.flatMap { row -> [String] in
                let links = row["referenced_tweets"] as? [[String: Any]] ?? []
                return [row["author_id"] as? String ?? ""] + links.compactMap { $0["id"] as? String }
            } + parents.compactMap { $0["author_id"] as? String })
            guard !rows.isEmpty, meta["result_count"] as? Int == rows.count, errors.allSatisfy({
                let resource = $0["resource_id"] as? String ?? $0["value"] as? String ?? ""
                return related.contains(resource) && !ids.contains(resource)
            }) else { throw WorkspaceError("X returned an incomplete reply page. Refresh again.") }
        }
        guard try savedAccount()?.connectionKey == initial.connectionKey else {
            throw WorkspaceError("The X connection changed before replies could be saved.")
        }
        let mapped = rows.compactMap { row -> WorkspaceRecord? in
            let id = row["id"] as? String ?? ""
            let authorID = row["author_id"] as? String ?? ""
            guard authorID != account.id else { return nil }
            let author = users.first { $0["id"] as? String == authorID }
            var item = WorkspaceRecord.new("reply-inbox")
            item["id"] = "reply-x-\(account.id)-\(id)"
            item["accountId"] = account.id
            item["postId"] = id
            item["platform"] = "x"
            item["author"] = String((author?["username"] as? String ?? author?["name"] as? String ?? "X member").prefix(150))
            item["text"] = String((row["text"] as? String ?? "").prefix(12_500))
            item["url"] = "https://x.com/i/web/status/" + id
            item["kind"] = row["in_reply_to_user_id"] as? String == account.id ? "reply" : "mention"
            item["createdAt"] = (row["created_at"] as? String).flatMap(scheduleDate).map(workspaceTimestamp) ?? attempt
            let references = row["referenced_tweets"] as? [[String: Any]] ?? []
            if let parentID = references.first(where: { $0["type"] as? String == "replied_to" })?["id"] as? String, validID(parentID),
               let parent = parents.first(where: { $0["id"] as? String == parentID })?["text"] as? String {
                item.fields["parent"] = ["text": String(parent.prefix(20_000)), "url": "https://x.com/i/web/status/" + parentID]
            }
            return item
        }
        let next = String((meta["next_token"] as? String ?? "").prefix(4000))
        let possibleIDs = [since, sync["recentHighId"] as? String ?? "", meta["newest_id"] as? String ?? ""] + rows.compactMap { $0["id"] as? String }
        let newest = possibleIDs.filter(validID).max { $0.count == $1.count ? $0 < $1 : $0.count < $1.count } ?? ""
        var updated = sync
        updated["lastAttemptAt"] = attempt
        updated["lastSuccessAt"] = attempt
        if older {
            updated["historyCursor"] = next
        } else if since.isEmpty {
            updated["sinceId"] = newest
            updated["historyCursor"] = next
        } else {
            updated["recentCursor"] = next
            updated["recentHighId"] = next.isEmpty ? "" : newest
            updated["sinceId"] = next.isEmpty ? newest : since
        }
        return try workspace.saveReplyPage(mapped, session: account.connectionKey, state: updated)
    }

    private func validID(_ text: String) -> Bool {
        text.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil
    }
}
