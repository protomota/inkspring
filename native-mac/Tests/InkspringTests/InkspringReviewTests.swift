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
    #expect(!InkspringSupportReminder.record(.newsletter, in: defaults))
    #expect(!InkspringSupportReminder.record(.newsletter, in: defaults))
    #expect(!InkspringSupportReminder.record(.feedback, in: defaults))
    #expect(InkspringSupportReminder.claim(now: later, in: defaults))
    #expect(!InkspringSupportReminder.record(.share, in: defaults))
    #expect(!InkspringSupportReminder.record(.support, in: defaults))
    #expect(InkspringSupportReminder.record(.apps, in: defaults))
    #expect(!InkspringSupportReminder.claim(now: later.addingTimeInterval(InkspringSupportReminder.interval), in: defaults))
}

@Test @MainActor func dontShowAgainStopsTheSupportReminderForGood() throws {
    let suite = "InkspringSupportTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for _ in 0..<InkspringReview.milestone { InkspringReview.recordActivity(in: defaults) }
    #expect(InkspringSupportReminder.claim(now: start, in: defaults))
    InkspringSupportReminder.dismissPermanently(in: defaults)
    // A fresh defaults object stands in for a relaunch.
    let relaunched = try #require(UserDefaults(suiteName: suite))
    for weeks in 1...10 {
        #expect(!InkspringSupportReminder.claim(now: start.addingTimeInterval(Double(weeks) * InkspringSupportReminder.interval), in: relaunched))
    }
}

@Test func agentInvitationLaterReturnsAfterAWeekAndDontShowAgainNever() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(AgentGuideInvitationSchedule.isVisible(dismissed: false, snoozedUntil: 0, now: now))
    let snoozed = AgentGuideInvitationSchedule.later(from: now)
    #expect(!AgentGuideInvitationSchedule.isVisible(dismissed: false, snoozedUntil: snoozed, now: now.addingTimeInterval(6 * 24 * 60 * 60)))
    #expect(AgentGuideInvitationSchedule.isVisible(dismissed: false, snoozedUntil: snoozed, now: now.addingTimeInterval(AgentGuideInvitationSchedule.laterInterval)))
    #expect(!AgentGuideInvitationSchedule.isVisible(dismissed: true, snoozedUntil: 0, now: now.addingTimeInterval(365 * 24 * 60 * 60)))
}
