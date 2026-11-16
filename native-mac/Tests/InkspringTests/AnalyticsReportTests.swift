import Foundation
import Testing
@testable import Inkspring

@Test func analyticsReportUsesSavedHistoryAndCountsOnlyConfirmedSteps() throws {
    let now = try #require(scheduleDate("2026-11-11T16:00:00Z"))
    let day = "2026-11-10"
    func record(_ kind: String, _ fields: [String: Any], account: String = "local-account") -> WorkspaceRecord {
        WorkspaceRecord(kind: kind, fields: fields.merging(["platform": "x", "accountId": account]) { current, _ in current })
    }
    let observations = record("analytics-day", [
        "first": ["at": day + "T12:00:00Z", "followers": 100],
        "last": ["at": day + "T16:00:00Z", "followers": 107, "accountPosts": 500]
    ])
    let tracked = record("analytics-post", [
        "id": "tracked", "publishedAt": day + "T13:00:00Z", "observedAt": day + "T17:00:00Z",
        "metrics": ["likes": 12, "replies": 0, "views": true]
    ])
    let noMetrics = record("analytics-post", [
        "id": "missing", "publishedAt": day + "T14:00:00Z", "metrics": [:]
    ])
    let excluded = record("analytics-post", [
        "id": "another", "publishedAt": day + "T15:00:00Z", "metrics": ["likes": 100]
    ], account: "different-account")
    let partial = record("publication", [
        "id": "thread", "status": "uncertain", "replyToId": "100",
        "steps": [["id": "confirmed-step", "at": day + "T14:00:00Z"]]
    ])
    let duplicate = record("publication", [
        "id": "duplicate", "status": "published",
        "steps": [["id": "confirmed-step", "at": day + "T15:00:00Z"]]
    ])
    let unconfirmed = record("publication", ["id": "unconfirmed", "status": "uncertain"])
    let records = [observations, tracked, noMetrics, excluded, partial, duplicate, unconfirmed]
    let report = AnalyticsReport(records: records, platform: .x, accountID: "local-account", days: 7, sort: .engagement, now: now)
    #expect(report.followers.map(\.count) == [100, 107])
    #expect(report.latestFollowers?.accountPosts == 500)
    #expect(report.growth == 7)
    #expect(report.posts.map(\.id) == ["tracked", "missing"])
    #expect(report.oldestPostAt == scheduleDate(day + "T13:00:00Z"))
    #expect(report.posts.first?.observedAt == scheduleDate(day + "T17:00:00Z"))
    #expect(report.total(.replies).value == 0)
    #expect(report.total(.replies).covered == 1)
    #expect(report.total(.views).value == nil)
    #expect(report.confirmedCount == 1)
    #expect(report.replyCount == 1)
    #expect(report.activity.first?.count == 1)
    #expect(AnalyticsReport.allConfirmed(records) == 1)
}

@Test @MainActor func analyticsKeepsUnreportedShareCountsUnknown() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    let account = ManagedSocialAccount(
        session: ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
                                      expiresAt: 2_000_000_000_000, scopes: "tweet.read"),
        id: "100", name: "Fixture", username: "fixture"
    )
    let now = try #require(scheduleDate("2026-11-11T16:00:00Z"))
    let transport = SocialTransport { request in
        let published = "2026-11-10T12:00:00Z"
        let posts: [[String: Any]] = [
            ["id": "1", "text": "No share metrics", "created_at": published, "public_metrics": ["like_count": 4]],
            ["id": "2", "text": "Reported zero", "created_at": published, "public_metrics": ["repost_count": 0]],
            ["id": "3", "text": "Only quotes available", "created_at": published, "public_metrics": ["quote_count": 3, "retweet_count": -1]],
            ["id": "4", "text": "Unusable share total", "created_at": published, "public_metrics": ["quote_count": 9_007_199_254_740_991, "retweet_count": 1]]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["data": posts])
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
    let analytics = AccountAnalytics(workspace: workspace, transport: transport, accountOverride: account)
    #expect(try await analytics.refresh(.x, now: now).isEmpty)
    let report = AnalyticsReport(records: workspace.records, platform: .x, accountID: account.id, days: 7, sort: .shares, now: now)
    #expect(report.posts.count == 4)
    #expect(report.posts.prefix(2).map { $0.record["postId"] } == ["3", "2"])
    #expect(report.total(.shares).value == 3)
    #expect(report.total(.shares).covered == 2)
    #expect(report.posts.allSatisfy { $0.observedAt == now })
}
