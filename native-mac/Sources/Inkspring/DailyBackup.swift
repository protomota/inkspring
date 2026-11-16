import Darwin
import Foundation
import ServiceManagement

struct DailyBackup {
    static let enabledKey = "dailyBackupEnabled"
    static let folderKey = "dailyBackupFolder"
    static let bookmarkKey = "dailyBackupBookmark"
    static let lastSuccessKey = "dailyBackupLastSuccess"
    static let lastFileKey = "dailyBackupLastFile"
    static let lastErrorKey = "dailyBackupLastError"
    static let registrationKey = "dailyBackupRegistration"
    private static let attemptKey = "dailyBackupLastAttempt"
    private static let agentPlist = "com.protomota.inkspring.native.daily-backup.plist"

    static var service: SMAppService {
        .agent(plistName: agentPlist)
    }

    static var usesTestWorkspace: Bool {
        ProcessInfo.processInfo.environment["INKSPRING_NATIVE_WORKSPACE"] != nil
    }

    static func directory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["INKSPRING_NATIVE_WORKSPACE"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        return support.appending(path: "Inkspring Native", directoryHint: .isDirectory)
    }

    static func registrationVersion(in bundle: Bundle = .main) throws -> String? {
        guard bundle.bundleIdentifier == "com.protomota.inkspring.native", let program = bundle.executableURL else { return nil }
        let plist = bundle.bundleURL.appending(path: "Contents/Library/LaunchAgents/").appending(path: agentPlist)
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        return try fileDigest(program).hash + ":" + fileDigest(plist).hash
    }

    @MainActor
    @discardableResult
    static func refreshRegistration(in directory: URL) async throws -> Bool {
        guard !usesTestWorkspace, let version = try registrationVersion() else { return false }
        let databaseURL = directory.appending(path: "workspace.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return false }
        let lock = open(directory.appending(path: ".daily-backup-registration.lock").path,
                        O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw WorkspaceError("Couldn’t lock the backup helper registration.") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return false }
            throw WorkspaceError("Couldn’t lock the backup helper registration.")
        }
        let database = try WorkspaceDatabase(url: databaseURL)
        let settings = try database.settings()
        guard settings[enabledKey] as? Bool == true else { return false }
        let helper = service
        let previousVersion = settings[registrationKey] as? String
        switch helper.status {
        case .enabled:
            guard previousVersion != version else { return false }
            if previousVersion == nil { try database.set(registrationKey, to: "") }
            try await helper.unregister()
        case .notRegistered:
            guard previousVersion != nil else { return false }
        default:
            return false
        }
        guard try database.settings()[enabledKey] as? Bool == true else { return false }
        try helper.register()
        try database.set(registrationKey, to: version)
        return true
    }

    /// Both launchd and the foreground app can trigger this. A per-workspace lock
    /// serializes checks and prevents a second writer from producing a duplicate ZIP.
    @discardableResult
    static func run(in directory: URL, now: Date = .now, requested: Bool = false) throws -> URL? {
        let databaseURL = directory.appending(path: "workspace.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            if requested { throw WorkspaceError("Open a workspace before backing it up.") }
            return nil
        }
        let lock = open(directory.appending(path: ".daily-backup.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw WorkspaceError("Couldn’t lock the daily backup.") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK {
                if requested { throw WorkspaceError("Inkspring is already backing up this workspace.") }
                return nil
            }
            throw WorkspaceError("Couldn’t lock the daily backup.")
        }

        let database = try WorkspaceDatabase(url: databaseURL)
        let settings = try database.settings()
        guard requested || settings[enabledKey] as? Bool == true else { return nil }
        guard let path = settings[folderKey] as? String, !path.isEmpty else {
            if requested { throw WorkspaceError("Choose a backup folder in Settings.") }
            return nil
        }
        if !requested {
            let lastSuccess = (settings[lastSuccessKey] as? String).flatMap(scheduleDate)
            if let lastSuccess, Calendar.current.isDate(lastSuccess, inSameDayAs: now),
               let lastFile = settings[lastFileKey] as? String, FileManager.default.fileExists(atPath: lastFile) {
                return nil
            }
            let lastAttempt = (settings[attemptKey] as? String).flatMap(scheduleDate)
            if let lastAttempt, (0..<3600).contains(now.timeIntervalSince(lastAttempt)) { return nil }
        }

        let timestamp = workspaceTimestamp(now)
        try database.set(attemptKey, to: timestamp)
        do {
            let folder = try backupFolder(settings: settings, path: path)
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw WorkspaceError("Reconnect the daily backup folder or choose another folder in Settings.")
            }
            let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
            let date = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            let name = "Inkspring Daily \(date)-\(UUID().uuidString.prefix(8)).zip"
            let destination = folder.appending(path: name)
            let snapshot = try database.snapshot()
            try WorkspaceBackup.export(records: snapshot.records, preferences: snapshot.settings,
                                       directory: directory, to: destination)
            try database.transaction {
                try database.set(lastSuccessKey, to: timestamp)
                try database.set(lastFileKey, to: destination.path)
                try database.set(lastErrorKey, to: "")
            }
            return destination
        } catch {
            try? database.set(lastErrorKey, to: error.localizedDescription)
            throw error
        }
    }

    static func chooseFolder(_ url: URL, database: WorkspaceDatabase) throws {
        let bookmark = (try? url.bookmarkData(options: .withSecurityScope))
            ?? (try? url.bookmarkData(options: .minimalBookmark))
        try database.transaction {
            try database.set(folderKey, to: url.path)
            try database.set(bookmarkKey, to: bookmark?.base64EncodedString() ?? "")
            try database.set(lastSuccessKey, to: "")
            try database.set(lastFileKey, to: "")
            try database.set(attemptKey, to: "")
            try database.set(lastErrorKey, to: "")
        }
    }

    private static func backupFolder(settings: [String: Any], path: String) throws -> URL {
        if let encoded = settings[bookmarkKey] as? String, let bookmark = Data(base64Encoded: encoded), !bookmark.isEmpty {
            var stale = false
            if let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                     bookmarkDataIsStale: &stale), !stale {
                return folder
            }
            if let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                     bookmarkDataIsStale: &stale), !stale {
                return folder
            }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
