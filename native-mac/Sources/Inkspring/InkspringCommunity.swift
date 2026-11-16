import Foundation
import StoreKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum InkspringCommunity {
    static let website = URL(string: "https://inkspring.ai/")!
    static let apps = URL(string: "https://protomota.com/apps")!
    static let support = URL(string: "https://protomota.com/support?app=inkspring")!
    static let websiteHelp = URL(string: "https://inkspring.ai/help")!
    static let feedback = URL(string: "https://protomota.com/apps?app=inkspring#feedback")!
    static let appStoreReview = URL(string: "https://apps.apple.com/app/id6834006000?action=write-review")!
    static let newsletter = URL(string: "https://newsletter.protomota.com/")!
    static let tips = URL(string: "https://buymeacoffee.com/protomotalab")!
}

#if os(macOS)
@MainActor
enum InkspringSupportReminder {
    enum Action: String, CaseIterable, Identifiable {
        case tip, feedback, share, support, apps
        var id: Self { self }
    }

    static let actionsKey = "inkspring.community.supportActions"
    static let presentedKey = "inkspring.community.supportPresentedAt"
    static let optedOutKey = "inkspring.community.supportOptedOut"
    static let interval: TimeInterval = 7 * 24 * 60 * 60

    static func clicked(_ values: String) -> Set<Action> {
        Set(values.split(separator: ",").compactMap { Action(rawValue: String($0)) })
    }

    @discardableResult
    static func record(_ action: Action, in defaults: UserDefaults = .standard) -> Bool {
        var actions = clicked(defaults.string(forKey: actionsKey) ?? "")
        actions.insert(action)
        defaults.set(actions.map(\.rawValue).sorted().joined(separator: ","), forKey: actionsKey)
        return actions.count == Action.allCases.count
    }

    static func claim(now: Date = .now, in defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: optedOutKey),
              defaults.integer(forKey: InkspringReview.activityKey) >= InkspringReview.milestone,
              clicked(defaults.string(forKey: actionsKey) ?? "").count < Action.allCases.count else { return false }
        let last = defaults.double(forKey: presentedKey)
        guard last == 0 || now.timeIntervalSince1970 - last >= interval else { return false }
        defaults.set(now.timeIntervalSince1970, forKey: presentedKey)
        return true
    }
}
#endif

@MainActor
enum InkspringReview {
    static let milestone = 5
    static let activityKey = "inkspring.community.completedWriting"
    #if os(macOS)
    // The old Mac flag tracked a web feedback dialog, not an App Store request.
    static let requestedKey = "inkspring.community.appStoreReviewRequested"
    #else
    static let requestedKey = "inkspring.community.reviewRequested"
    #endif

    static func recordActivity(in defaults: UserDefaults = .standard) {
        let count = defaults.integer(forKey: activityKey)
        guard count < milestone else { return }
        defaults.set(count + 1, forKey: activityKey)
    }

    static func claimRequest(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.integer(forKey: activityKey) >= milestone,
              !defaults.bool(forKey: requestedKey) else { return false }
        defaults.set(true, forKey: requestedKey)
        return true
    }
}

struct InkspringRatingPrompt: ViewModifier {
    let isIdle: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @AppStorage(InkspringReview.activityKey) private var completedActivities = 0
    @AppStorage(InkspringReview.requestedKey) private var requested = false

    private var canRequest: Bool {
        isIdle && scenePhase == .active && completedActivities >= InkspringReview.milestone && !requested
    }

    func body(content: Content) -> some View {
        content.task(id: canRequest) {
            guard canRequest else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            #if !DEBUG
            // The native sheet rates an App Store app. TestFlight and direct Mac
            // downloads should not consume the prompt for a later Store install.
            guard case .verified(let transaction) = try? await AppTransaction.shared,
                  transaction.environment == .production else { return }
            #endif
            #if os(macOS)
            guard NSApp.isActive, let window = NSApp.keyWindow, !window.isSheet,
                  window.attachedSheet == nil else { return }
            #endif
            guard !Task.isCancelled, canRequest, InkspringReview.claimRequest() else { return }
            requestReview()
        }
    }
}
