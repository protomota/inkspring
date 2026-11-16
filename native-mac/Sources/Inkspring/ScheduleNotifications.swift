import Foundation
import UserNotifications

struct ScheduleReminder: Equatable, Sendable {
    enum Reason: String, Sendable { case review, check }

    let draftID: String
    let slot: String
    let channel: String
    let reason: Reason

    init(_ draft: WorkspaceRecord, reason: Reason) {
        draftID = draft.id
        slot = draft.schedule["slotAt"] as? String ?? ""
        channel = platformName(draft["platform"])
        self.reason = reason
    }

    var identifier: String { "schedule:\(draftID):\(slot):\(reason.rawValue)" }

    var title: String {
        reason == .review ? "Review your \(channel) post" : "Check your \(channel) post"
    }

    var message: String {
        switch reason {
        case .review: "Open Inkspring to review the scheduled post."
        case .check: "Open Inkspring to check the result before trying again."
        }
    }
}

enum ScheduleNotifications {
    static let settingKey = "scheduleNotificationsEnabled"
    static let draftKey = "scheduleDraftID"

    static func requestPermission() async throws {
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) else {
            throw WorkspaceError("Allow notifications for Inkspring in System Settings → Notifications.")
        }
    }

    static func deliver(_ reminder: ScheduleReminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.message
        content.userInfo = [draftKey: reminder.draftID]
        let request = UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension Workspace {
    func setScheduleNotifications(_ enabled: Bool) async {
        do {
            if enabled { try await ScheduleNotifications.requestPermission() }
            try set(ScheduleNotifications.settingKey, to: enabled)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
