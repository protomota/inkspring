import AppKit
import Foundation
import SwiftUI
import UserNotifications

@main
enum InkspringMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--daily-backup"] {
            do {
                try DailyBackup.run(in: DailyBackup.directory())
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        } else if CommandLine.arguments.dropFirst() == ["--refresh-daily-backup-registration"] {
            Task { @MainActor in
                do {
                    let updated = try await DailyBackup.refreshRegistration(in: DailyBackup.directory())
                    print(updated ? "Daily backup helper re-registered." : "No change to the daily backup registration.")
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        } else if CommandLine.arguments.dropFirst() == ["--mcp"] ||
                    (CommandLine.arguments.count == 3 && ["--mcp-chat", "--mcp-write"].contains(CommandLine.arguments[1])) {
            do {
                let directory = try DailyBackup.directory()
                guard FileManager.default.fileExists(atPath: directory.appending(path: "workspace.sqlite").path) else {
                    throw WorkspaceError("Open Inkspring before connecting your agent.")
                }
                let workspace = Workspace(directory: directory)
                if let error = workspace.startupError { throw WorkspaceError(error) }
                Task { @MainActor in
                    let chat = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--mcp-chat"
                    let writing = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--mcp-write"
                    await AgentMCP(workspace: workspace, chatProjectID: chat ? CommandLine.arguments[2] : nil,
                                   generationContext: writing ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil).run()
                    exit(EXIT_SUCCESS)
                }
                dispatchMain()
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        } else if CommandLine.arguments.dropFirst().first == "--stage-workspace" {
            let arguments = Array(CommandLine.arguments.dropFirst(2))
            guard arguments.count == 2, arguments.allSatisfy({ $0.hasPrefix("/") }) else {
                FileHandle.standardError.write(Data("Provide absolute source and destination directories.\n".utf8))
                exit(EXIT_FAILURE)
            }
            do {
                let report = try WorkspaceMigration.stage(
                    from: URL(fileURLWithPath: arguments[0], isDirectory: true),
                    to: URL(fileURLWithPath: arguments[1], isDirectory: true)
                )
                print("Migrated \(report.records) records, \(report.images) images and \(report.videos) videos.")
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        } else {
            InkspringTypography.registerFonts()
            InkspringApp.main()
        }
    }
}

struct InkspringApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceLifecycle.self) private var lifecycle
    @Environment(\.openWindow) private var openWindow

    private var workspace: Workspace { lifecycle.workspace }

    var body: some Scene {
        Window("Inkspring", id: "workspace") {
            WorkspaceWindow(workspace: workspace)
                .frame(minWidth: 870, minHeight: 660)
                .background(WindowTitleHider().allowsHitTesting(false))
                .onAppear { lifecycle.showWorkspace = { openWindow(id: "workspace") } }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 810)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Get App Help") { NSWorkspace.shared.open(InkspringCommunity.support) }
                Button("Setup and Troubleshooting") { NSWorkspace.shared.open(InkspringCommunity.websiteHelp) }
                Button("Send Feedback") { NSWorkspace.shared.open(InkspringCommunity.feedback) }
            }
            CommandGroup(after: .appInfo) {
                if lifecycle.updates.isConfigured {
                    Button("Check for Updates…", action: lifecycle.updates.check)
                        .disabled(!lifecycle.updates.canCheck)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Export Backup…") { workspace.exportBackup() }
                Button("Import / Restore…") { Task { await workspace.restoreBackup() } }
                    .disabled(workspace.restoringBackup || workspace.importingWorkspaceFolder)
                Button("Import Workspace Folder…") { Task { await workspace.importWorkspaceFolder() } }
                    .disabled(workspace.restoringBackup || workspace.importingWorkspaceFolder)
            }
        }
    }
}

private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.window?.titleVisibility = .hidden }

    final class TitleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
}

@MainActor
final class WorkspaceLifecycle: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let workspace = Workspace()
    let updates = InkspringUpdates()
    private var tasks: [Task<Void, Never>] = []
    private var scheduledActivity: NSObjectProtocol?
    var showWorkspace: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates.start()
        workspace.recoverInterruptedPublications()
        workspace.recoverInterruptedNewsletters()
        let workspace = workspace
        repeatEvery(.seconds(2)) { workspace.refreshAfterExternalWrite() }
        repeatEvery(.seconds(900)) { await workspace.checkDailyBackup() }
        guard !DailyBackup.usesTestWorkspace else { return }
        UNUserNotificationCenter.current().delegate = self
        tasks.append(Task { await workspace.refreshDailyBackupRegistration() })
        repeatEvery(.seconds(30)) { await workspace.syncCompanion() }
        repeatEvery(.seconds(25)) { await workspace.syncCompanionLibrary() }
        repeatEvery(.seconds(300)) { await workspace.runDraftRevisionComments() }
        repeatEvery(.seconds(60)) { workspace.recoverInterruptedPublications() }
        repeatEvery(.seconds(10)) { [weak self] in
            self?.updateScheduledActivity()
            await workspace.runDuePosts()
            self?.updateScheduledActivity()
        }
        repeatEvery(.seconds(60)) {
            await workspace.refreshDueSubstackNewsletters()
            await workspace.refreshScheduledWork()
            await workspace.refillIdeaQueueIfNeeded()
        }
        repeatEvery(.seconds(60)) { await ReplyInbox(workspace: workspace).poll() }
        repeatEvery(.seconds(60)) { await AccountAnalytics(workspace: workspace).poll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let draftID = response.notification.request.content.userInfo[ScheduleNotifications.draftKey] as? String else { return }
        await MainActor.run {
            workspace.scheduleReminderDraftID = draftID
            showWorkspace?()
            NSApp.activate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        if let scheduledActivity { ProcessInfo.processInfo.endActivity(scheduledActivity) }
        scheduledActivity = nil
    }

    private func repeatEvery(_ delay: Duration, action: @escaping @MainActor () async -> Void) {
        tasks.append(Task { @MainActor in
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: delay)
            }
        })
    }

    private func updateScheduledActivity() {
        let soon = Date.now.addingTimeInterval(3 * 3600)
        let needed = workspace.settings["autoPost"] as? Bool == true && workspace.records.contains {
            $0.kind == "draft" && $0.scheduleStatus == "queued" && !["instagram", "reddit"].contains($0["platform"]) &&
                ($0.schedule["slotAt"] as? String).flatMap(scheduleDate).map { $0 <= soon } == true
        }
        if needed && scheduledActivity == nil {
            scheduledActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                      reason: "Check upcoming Inkspring posts")
        } else if !needed, let activity = scheduledActivity {
            ProcessInfo.processInfo.endActivity(activity)
            scheduledActivity = nil
        }
    }
}
