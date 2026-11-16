import Foundation
import Testing
@testable import Inkspring

@MainActor
@Test func appStoreReviewIsEligibleAfterFiveActivitiesAndClaimedOnce() throws {
    let suite = "InkspringReviewTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    for _ in 0..<4 { InkspringReview.recordActivity(in: defaults) }
    #expect(!InkspringReview.claimRequest(in: defaults))
    InkspringReview.recordActivity(in: defaults)
    #expect(InkspringReview.claimRequest(in: defaults))
    InkspringReview.recordActivity(in: defaults)
    #expect(!InkspringReview.claimRequest(in: defaults))
}
@Test @MainActor func supportReminderWaitsForUsageAndStopsAfterAllActions() throws {
    let suite = "InkspringSupportTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let later = start.addingTimeInterval(InkspringSupportReminder.interval)
    #expect(!InkspringSupportReminder.claim(now: start, in: defaults))
    for _ in 0..<InkspringReview.milestone { InkspringReview.recordActivity(in: defaults) }
    #expect(InkspringSupportReminder.claim(now: start, in: defaults))
    #expect(!InkspringSupportReminder.claim(now: later.addingTimeInterval(-1), in: defaults))
    #expect(!InkspringSupportReminder.record(.tip, in: defaults))
    #expect(!InkspringSupportReminder.record(.tip, in: defaults))
    #expect(!InkspringSupportReminder.record(.feedback, in: defaults))
    #expect(InkspringSupportReminder.claim(now: later, in: defaults))
    #expect(!InkspringSupportReminder.record(.share, in: defaults))
    #expect(!InkspringSupportReminder.record(.support, in: defaults))
    #expect(InkspringSupportReminder.record(.apps, in: defaults))
    #expect(!InkspringSupportReminder.claim(now: later.addingTimeInterval(InkspringSupportReminder.interval), in: defaults))
    defaults.removeObject(forKey: InkspringSupportReminder.actionsKey)
    defaults.set(true, forKey: InkspringSupportReminder.optedOutKey)
    #expect(!InkspringSupportReminder.claim(now: later.addingTimeInterval(InkspringSupportReminder.interval), in: defaults))
}
