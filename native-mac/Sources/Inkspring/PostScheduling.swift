import Foundation
import InkspringSchedule

struct ScheduleListing {
    enum Section: String, CaseIterable, Identifiable {
        case ready = "Ready to schedule"
        case scheduled = "Scheduled"
        case history = "Published"

        var id: Self { self }
    }

    private let sections: [Section: [WorkspaceRecord]]

    init(records: [WorkspaceRecord], projectID: String? = nil, channel: String? = nil) {
        let matching = records.filter { item in
            (item.kind == "draft" || item.kind == "newsletter") &&
                (projectID == nil || item.projectID == projectID) &&
                (channel == nil || Self.channel(of: item) == channel)
        }
        let grouped = Dictionary(grouping: matching) { Self.section(for: $0) }
        sections = Dictionary(uniqueKeysWithValues: Section.allCases.map { section in
            let sorted = (grouped[section] ?? []).sorted { first, second in
                let fallback: Date = section == .scheduled ? .distantFuture : .distantPast
                let left = Self.date(for: first, in: section) ?? fallback
                let right = Self.date(for: second, in: section) ?? fallback
                if left == right { return first.id < second.id }
                return section == .scheduled ? left < right : left > right
            }
            return (section, sorted)
        })
    }

    subscript(section: Section) -> [WorkspaceRecord] { sections[section] ?? [] }

    static func channel(of item: WorkspaceRecord) -> String {
        item.kind == "newsletter" ? "substack" : item["platform"]
    }

    static func section(for item: WorkspaceRecord) -> Section? {
        if item.kind == "newsletter" {
            switch item["state"] {
            case "scheduled", "releasing": return .scheduled
            case "uncertain": return item["scheduledAt"].isEmpty ? .history : .scheduled
            case "published": return .history
            case "draft", "synced", "syncing": return .ready
            default: return nil
            }
        }
        guard item.kind == "draft" else { return nil }
        switch item.scheduleStatus {
        case "queued", "due", "posting": return .scheduled
        case "posted", "skipped": return .history
        case "ready", "failed", "removed", "manual": return .ready
        default: return nil
        }
    }

    static func date(for item: WorkspaceRecord, in section: Section) -> Date? {
        if item.kind == "newsletter" {
            if section == .scheduled { return scheduleDate(item["scheduledAt"]) ?? scheduleDate(item["requestedAt"]) }
            return scheduleDate(item["publishedAt"]) ?? scheduleDate(item["updatedAt"])
        }
        if section == .scheduled { return (item.schedule["slotAt"] as? String).flatMap(scheduleDate) }
        let key = section == .ready ? "pickedAt" : item.scheduleStatus == "posted" ? "postedAt" : "skippedAt"
        return (item.schedule[key] as? String).flatMap(scheduleDate) ?? scheduleDate(item["updatedAt"])
    }
}

enum PublishedPostFeed {
    static func entries(in records: [WorkspaceRecord], projectID: String? = nil,
                        channel: String? = nil) -> [CompanionPublication] {
        let projects = Dictionary(records.filter { $0.kind == "project" }.map { ($0.id, $0.title) },
                                  uniquingKeysWith: { first, _ in first })
        var entries: [String: CompanionPublication] = [:]
        for receipt in records where receipt.kind == "publication"
            && (projectID == nil || receipt.projectID == projectID) {
            let platform = receipt["platform"]
            guard !platform.isEmpty, channel == nil || channel == platform else { continue }
            let steps = receipt.fields["steps"] as? [[String: Any]] ?? []
            let complete = receipt["status"] == "published"
            guard complete || !steps.isEmpty && ["partial", "publishing", "uncertain"].contains(receipt["status"]),
                  let date = scheduleDate(receipt["publishedAt"])
                    ?? (steps.first?["at"] as? String).flatMap(scheduleDate)
                    ?? scheduleDate(receipt["updatedAt"]) else { continue }
            let id = receipt["draftId"].isEmpty ? receipt.id : receipt["draftId"]
            let links = steps.compactMap { ($0["url"] as? String).flatMap(CompanionPublication.postURL) }
            if let existing = entries[id] {
                if !existing.incomplete && !complete { continue }
                if existing.incomplete == !complete && existing.publishedAt >= date { continue }
            }
            entries[id] = CompanionPublication(id: id, title: receipt.title, project: projects[receipt.projectID] ?? "Inkspring",
                                                channel: platform, publishedAt: date, links: links, incomplete: !complete)
        }
        for item in records where projectID == nil || item.projectID == projectID {
            let platform = ScheduleListing.channel(of: item)
            guard channel == nil || channel == platform else { continue }
            let date: Date?
            let address: String
            if item.kind == "newsletter", item["state"] == "published" {
                date = scheduleDate(item["publishedAt"]) ?? scheduleDate(item["updatedAt"])
                address = item["postUrl"]
            } else if item.kind == "draft", item.scheduleStatus == "posted" {
                date = ScheduleListing.date(for: item, in: .history)
                address = item.schedule["url"] as? String ?? ""
            } else if item.kind == "article", item.isPublishedContent {
                date = scheduleDate(item["articlePublishedAt"]) ?? scheduleDate(item["updatedAt"])
                address = item["articleURL"]
            } else { continue }
            guard let date else { continue }
            let link = CompanionPublication.postURL(address)
            if let existing = entries[item.id], !existing.links.isEmpty || link == nil { continue }
            entries[item.id] = CompanionPublication(id: item.id, title: item.title, project: projects[item.projectID] ?? "Inkspring",
                                                     channel: platform, publishedAt: date, links: link.map { [$0] } ?? [])
        }
        return entries.values.sorted { first, second in
            first.publishedAt == second.publishedAt ? first.id < second.id : first.publishedAt > second.publishedAt
        }
    }
}

enum PostScheduling {
    struct PostingHour: Identifiable {
        let start: Date
        let end: Date
        let post: WorkspaceRecord?

        var id: Date { start }
    }

    private static let xHours = [9, 11, 13, 15, 17]
    private static let visibleStates = ["queued", "due", "posting", "posted"]
    static let leadTime: TimeInterval = 120

    static func fiveMinutesFromNow(_ now: Date = .now) -> Date {
        let target = now.addingTimeInterval(5 * 60)
        return Date(timeIntervalSince1970: ceil(target.timeIntervalSince1970 / 60) * 60)
    }

    static func startOfMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    static func xPostingHours(on day: Date, in records: [WorkspaceRecord],
                              calendar: Calendar = .current) -> [PostingHour] {
        let draft = WorkspaceRecord(kind: "draft", fields: ["platform": "x"])
        return xHours.compactMap { hour in
            guard let time = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                  let interval = calendar.dateInterval(of: .hour, for: time) else { return nil }
            let post = occupyingPost(time, for: draft, in: records, calendar: calendar, linkedInPersonalURN: nil)
            return PostingHour(start: interval.start, end: interval.end, post: post)
        }
    }

    static func proposedTimes(for draft: WorkspaceRecord, in records: [WorkspaceRecord],
                              now: Date = .now, calendar: Calendar = .current, linkedInPersonalURN: String? = nil,
                              window: CompanionPostingWindow? = nil) -> [Date] {
        let hours = window.map { Array($0.hours) } ?? {
            switch draft["platform"] {
            case "linkedin": [9]
            case "instagram": [13]
            default: xHours
            }
        }()
        var dates: [Date] = []
        for offset in 0..<60 {
            guard dates.count < 8, let day = calendar.date(byAdding: .day, value: offset, to: now) else { break }
            if draft["platform"] == "linkedin" && calendar.isDateInWeekend(day) { continue }
            for hour in hours where dates.count < 8 {
                if let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                   date > now.addingTimeInterval(leadTime),
                   isFree(date, for: draft, in: records, calendar: calendar, linkedInPersonalURN: linkedInPersonalURN) { dates.append(date) }
            }
        }
        return dates
    }

    static func isFree(_ time: Date, for draft: WorkspaceRecord, in records: [WorkspaceRecord],
                       calendar: Calendar = .current, linkedInPersonalURN: String? = nil, customTime: Bool = false) -> Bool {
        occupyingPost(time, for: draft, in: records, calendar: calendar, linkedInPersonalURN: linkedInPersonalURN,
                      customTime: customTime) == nil
    }

    private static func occupyingPost(_ time: Date, for draft: WorkspaceRecord, in records: [WorkspaceRecord],
                                      calendar: Calendar, linkedInPersonalURN: String?, customTime: Bool = false) -> WorkspaceRecord? {
        let platform = draft["platform"]
        let interval: Calendar.Component
        if customTime && ["x", "linkedin"].contains(platform) {
            interval = .minute
        } else {
            interval = ["x", "tiktok"].contains(platform) ? .hour : .day
        }
        let urn = (draft.fields["linkedinDestination"] as? [String: Any])?["urn"] as? String ?? linkedInPersonalURN
        return records.first { other in
            guard other.kind == "draft", other.id != draft.id, other["platform"] == platform,
                  visibleStates.contains(other.scheduleStatus),
                  let value = (other.schedule["postedAt"] as? String).flatMap(scheduleDate)
                    ?? (other.schedule["slotAt"] as? String).flatMap(scheduleDate) else { return false }
            if platform == "linkedin" {
                let otherURN = (other.fields["linkedinDestination"] as? [String: Any])?["urn"] as? String ?? linkedInPersonalURN
                if let urn, let otherURN, urn != otherURN { return false }
            }
            return calendar.isDate(time, equalTo: value, toGranularity: interval)
        }
    }

    static func parseLocalHour(_ value: String) -> Date? {
        if let exact = scheduleDate(value) { return exact }
        guard value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}\z"#,
                          options: .regularExpression) != nil else { return nil }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let date = parser.date(from: value), parser.string(from: date) == value else { return nil }
        return date
    }

    static func date(hour: Date, minute: Int?, now: Date = .now, calendar: Calendar = .current) throws -> Date {
        guard let start = calendar.dateInterval(of: .hour, for: hour)?.start,
              minute == nil || (0...59).contains(minute ?? 0) else {
            throw WorkspaceError("Choose a posting minute from 00 through 59.")
        }
        let options = minute.map { [$0] } ?? (7...55).filter { $0 % 5 != 0 }
        let available = options.compactMap { calendar.date(byAdding: .minute, value: $0, to: start) }
            .filter { $0 > now.addingTimeInterval(leadTime) }
        guard let result = available.randomElement() else { throw WorkspaceError("Choose a posting time in the future.") }
        return result
    }
}

extension Workspace {
    func postingWindow(for platform: String) -> CompanionPostingWindow {
        let values = settings["postingWindows"] as? [String: [String: Int]] ?? [:]
        let value = values[platform]
        return CompanionPostingWindow(firstHour: value?["firstHour"] ?? 9, lastHour: value?["lastHour"] ?? 17)
    }

    func postingMinute(for platform: String) -> Int {
        let values = settings["postingWindows"] as? [String: [String: Int]] ?? [:]
        let minute = values[platform]?["minute"] ?? -1
        return (-1...59).contains(minute) ? minute : -1
    }

    func setPostingPreferences(for platform: String, window: CompanionPostingWindow, minute: Int) throws {
        try withChanges {
            var values = settings["postingWindows"] as? [String: [String: Int]] ?? [:]
            values[platform] = ["firstHour": window.firstHour, "lastHour": window.lastHour, "minute": minute]
            try set("postingWindows", to: values)
        }
    }

    func preferredPostingDate(for platform: String, hour: Date, minute: Int) throws -> Date {
        guard postingWindow(for: platform).hours.contains(Calendar.current.component(.hour, from: hour)) else {
            throw WorkspaceError("Choose an hour within this platform’s preferred posting hours in Mac Settings.")
        }
        return try PostScheduling.date(hour: hour, minute: minute < 0 ? nil : minute)
    }
}

extension Workspace {
    func runDuePosts(publisher override: SocialPublisher? = nil, now: Date = .now,
                     notify: @MainActor (ScheduleReminder) async -> Void = ScheduleNotifications.deliver) async {
        guard !runningDuePosts, settings["autoPost"] as? Bool == true else { return }
        runningDuePosts = true
        defer { runningDuePosts = false }
        let publisher = override ?? SocialPublisher(workspace: self)
        func remind(_ draft: WorkspaceRecord, _ reason: ScheduleReminder.Reason) async {
            if settings[ScheduleNotifications.settingKey] as? Bool == true {
                await notify(ScheduleReminder(draft, reason: reason))
            }
        }
        let due = records.compactMap { draft -> (WorkspaceRecord, Date)? in
            guard draft.kind == "draft", draft.scheduleStatus == "queued",
                  let slot = (draft.schedule["slotAt"] as? String).flatMap(scheduleDate), slot <= now else { return nil }
            return (draft, slot)
        }.sorted { $0.1 < $1.1 }
        for (draft, slot) in due {
            if Task.isCancelled { return }
            guard settings["autoPost"] as? Bool == true else { return }
            let platform = draft["platform"]
            if ["instagram", "reddit"].contains(platform) {
                if (try? updateDueDraft(draft, state: "due", error: "This post is ready for review and publishing.")) == true {
                    await remind(draft, .review)
                }
                continue
            }
            if now.timeIntervalSince(slot) > 10_800 {
                if (try? updateDueDraft(draft, state: "failed", error: "Inkspring missed the posting time. Schedule again or review to publish now.")) == true {
                    await remind(draft, .check)
                }
                continue
            }
            do {
                if platform == "x" {
                    let posts = ["followup", "thread"].contains(draft["format"]) ? XThreadText.posts(in: draft.body) : [draft.body]
                    let links = try XPostArticleLinks(draft: draft, posts: posts, records: records)
                    if links.articles.contains(where: { $0["state"] != "published" }),
                       let pair = try await publisher.reviewXArticlePost(draft) {
                        _ = try await publisher.publishXArticlePost(pair, automatic: true)
                        continue
                    }
                }
                if platform == "linkedin",
                   LinkedInDestination(fields: draft.fields["linkedinDestination"] as? [String: Any]) == nil {
                    throw WorkspaceError("Choose a LinkedIn destination and schedule this post again.")
                }
                var options = SocialPublishOptions()
                var expectedAccount: String?
                if platform == "tiktok" {
                    guard let consent = records.first(where: {
                        $0.kind == "tiktok-consent" && $0["draftId"] == draft.id && $0["draftRevision"] == draft["updatedAt"]
                            && $0["slotAt"] == draft.schedule["slotAt"] as? String
                    }), let raw = consent.fields["options"] else {
                        throw WorkspaceError("Review this TikTok post and choose a time again.")
                    }
                    let data = try JSONSerialization.data(withJSONObject: raw)
                    options.tiktok = try JSONDecoder().decode(TikTokReviewOptions.self, from: data)
                    options.imageURL = consent["imageURL"]
                    expectedAccount = consent["accountId"]
                }
                let review = try await publisher.review(draft, options: options)
                if let expectedAccount, review.accountID != expectedAccount {
                    throw WorkspaceError("The TikTok account changed. Review and schedule again.")
                }
                guard settings["autoPost"] as? Bool == true else { return }
                _ = try await publisher.publish(review, automatic: true)
            } catch is CompanionScheduleError {
                continue
            } catch is PublicationLeaseBusy {
                continue
            } catch {
                if settings["autoPost"] as? Bool != true { return }
                let changed = (try? updateDueDraft(draft, state: "failed", error: error.localizedDescription)) == true
                let failedDuringSend = records.contains { row in
                    row.kind == "draft" && row.id == draft.id && row.scheduleStatus == "failed"
                        && row.schedule["slotAt"] as? String == draft.schedule["slotAt"] as? String
                }
                if changed || failedDuringSend { await remind(draft, .check) }
            }
        }
    }

    private func updateDueDraft(_ input: WorkspaceRecord, state: String, error: String) throws -> Bool {
        try reload()
        guard var draft = records.first(where: { $0.id == input.id && $0.kind == "draft" }),
              draft.scheduleStatus == "queued", draft["updatedAt"] == input["updatedAt"] else { return false }
        var schedule = draft.schedule
        schedule["status"] = state
        schedule["error"] = error
        draft.fields["schedule"] = schedule
        try save(draft)
        return true
    }
}
