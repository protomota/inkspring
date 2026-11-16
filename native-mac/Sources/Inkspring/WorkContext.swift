import CSQLite
import Darwin
import Foundation

struct WorkReference: Sendable {
    enum Origin: String, Sendable {
        case git = "Git commit"
        case claude = "Claude Code recap"
        case codex = "Codex recap"
        case notes = "Obsidian notes"
    }

    let title: String
    var text: String
    let origin: Origin
    let at: Date

    init(_ title: String, _ text: String, _ origin: Origin, _ at: Date) {
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(750))
        self.origin = origin
        self.at = at
    }
}

struct WorkContext {
    struct Result: Sendable {
        var items: [WorkReference] = []
        var unavailable: [String] = []
    }

    private let cutoff: Date
    private let claudeRoot: URL
    private let codexRoot: URL

    init(now: Date = .now, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cutoff = now.addingTimeInterval(-48 * 60 * 60)
        claudeRoot = home.appending(path: "Library/Application Support/Claude/claude-code-sessions")
        codexRoot = home.appending(path: ".codex")
    }

    func collect(code: URL?, notes: URL?, limit: Int = 36) -> Result {
        var result = Result()
        func add(_ name: String, _ scan: () throws -> [WorkReference]) {
            do { result.items += try scan() }
            catch { result.unavailable.append(name) }
        }
        if let code {
            let folder = code.resolvingSymlinksInPath().standardizedFileURL
            add("Git") { try git(folder) }
            add("Claude") { try claude(folder) }
            add("Codex") { try codex(folder) }
        }
        if let notes {
            add("Obsidian notes") {
                let vault = try ObsidianVault(notes.path)
                return try vault.list(query: "").notes.compactMap { row -> (String, Date)? in
                    guard let id = row["id"] as? String, let value = row["modifiedAt"] as? String,
                          let date = scheduleDate(value), date >= cutoff else { return nil }
                    return (id, date)
                }.prefix(8).compactMap { id, date in
                    guard let note = try? vault.preview([id]).notes.first,
                          let title = note["title"], let text = note["text"] else { return nil }
                    return WorkReference(title, text, .notes, date)
                }
            }
        }
        result.items = Array(result.items.filter { !$0.title.isEmpty && !$0.text.isEmpty }
            .sorted { $0.at > $1.at }.prefix(limit))
        return result
    }

    private func git(_ folder: URL) throws -> [WorkReference] {
        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        child.arguments = ["--no-optional-locks", "-C", folder.path, "log",
                           "--since=" + workspaceTimestamp(cutoff), "--no-merges", "-n", "12",
                           "--format=%aI%x1f%s", "--", "."]
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let output = pipe.fileHandleForReading
        let descriptor = output.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw WorkspaceError("Couldn’t read recent Git activity.")
        }
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            try? output.close()
        }
        let deadline = ContinuousClock.now + .seconds(3)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline, data.count <= 64_000 {
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                child.waitUntilExit()
                guard child.terminationStatus == 0 else { break }
                return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                    let values = line.split(separator: "\u{1f}", maxSplits: 1)
                    guard values.count == 2, let date = scheduleDate(String(values[0])), date >= cutoff else { return nil }
                    return WorkReference(String(values[1]), String(values[1]), .git, date)
                }
            } else if errno == EAGAIN || errno == EINTR {
                Thread.sleep(forTimeInterval: 0.02)
            } else { break }
        }
        throw WorkspaceError("Couldn’t read recent Git activity.")
    }

    private func claude(_ folder: URL) throws -> [WorkReference] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: claudeRoot, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles]) else {
            throw WorkspaceError("Couldn’t read Claude recaps.")
        }
        var items: [WorkReference] = []
        var scanned = 0
        while let file = files.nextObject() as? URL, scanned < 1500 {
            scanned += 1
            guard let attributes = try? file.resourceValues(forKeys: keys) else { continue }
            if attributes.isSymbolicLink == true || files.level > 3 {
                files.skipDescendants()
                continue
            }
            guard attributes.isRegularFile == true, file.lastPathComponent.hasPrefix("local_"), file.pathExtension == "json",
                  (attributes.fileSize ?? Int.max) <= 2 * 1024 * 1024,
                  (attributes.contentModificationDate ?? .distantPast) >= cutoff,
                  let bytes = try? Self.readRegular(file, limit: 2 * 1024 * 1024),
                  let session = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let cwd = session["cwd"] as? String, Self.contains(cwd, in: folder),
                  let timestamp = session["lastActivityAt"] as? Double, timestamp.isFinite,
                  let title = session["title"] as? String else { continue }
            let date = Date(timeIntervalSince1970: timestamp / 1000)
            let recap = (session["turnWrapUp"] as? [String: Any])?["description"] as? String
                ?? (session["postTurnSummary"] as? [String: Any])?["status_detail"] as? String
            if let recap, date >= cutoff { items.append(WorkReference(title, recap, .claude, date)) }
        }
        return Array(items.sorted { $0.at > $1.at }.prefix(12))
    }

    private func codex(_ folder: URL) throws -> [WorkReference] {
        let files = try FileManager.default.contentsOfDirectory(at: codexRoot, includingPropertiesForKeys: nil)
        let states = files.compactMap { url -> (URL, Int)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"), let number = Int(name.dropFirst(6)) else { return nil }
            return (url, number)
        }
        guard let file = states.max(by: { $0.1 < $1.1 })?.0 else { return [] }
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db else {
            throw WorkspaceError("Couldn’t open Codex’s local history.")
        }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        let sql = """
            SELECT title, cwd, rollout_path, updated_at FROM threads
            WHERE (cwd = ? OR instr(cwd, ?) = 1) AND updated_at >= ?
            ORDER BY updated_at DESC LIMIT 12
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WorkspaceError("Couldn’t read Codex’s local history.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let prefix = folder.path == "/" ? "/" : folder.path + "/"
        sqlite3_bind_text(statement, 1, folder.path, -1, transient)
        sqlite3_bind_text(statement, 2, prefix, -1, transient)
        sqlite3_bind_int64(statement, 3, Int64(cutoff.timeIntervalSince1970))
        let root = codexRoot.resolvingSymlinksInPath().standardizedFileURL
        var items: [WorkReference] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return items
            case SQLITE_ROW:
                guard let title = sqlite3_column_text(statement, 0), let cwd = sqlite3_column_text(statement, 1),
                      let path = sqlite3_column_text(statement, 2), Self.contains(String(cString: cwd), in: folder),
                      let recap = Self.codexRecap(String(cString: path), root: root) else { continue }
                let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)))
                items.append(WorkReference(String(cString: title), recap, .codex, date))
            default: throw WorkspaceError("Couldn’t read Codex’s local history.")
            }
        }
    }

    private static func codexRecap(_ path: String, root: URL) -> String? {
        guard contains(path, in: root) else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard contains(file.path, in: root), let bytes = try? readRegular(file, limit: 192_000, tail: true) else { return nil }
        for line in bytes.split(separator: 10).reversed() {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let payload = row["payload"] as? [String: Any] else { continue }
            if row["type"] as? String == "event_msg", payload["type"] as? String == "task_complete",
               let text = payload["last_agent_message"] as? String { return text }
            if row["type"] as? String == "response_item", payload["role"] as? String == "assistant",
               payload["channel"] as? String == "final", let parts = payload["content"] as? [[String: Any]] {
                return parts.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        }
        return nil
    }

    private static func contains(_ path: String, in folder: URL) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.pathComponents.starts(with: folder.pathComponents)
    }

    private static func readRegular(_ url: URL, limit: Int, tail: Bool = false) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError("Couldn’t open a work recap.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              tail || info.st_size <= limit else { throw WorkspaceError("A work recap is unavailable or too large.") }
        if tail { try handle.seek(toOffset: UInt64(max(0, info.st_size - Int64(limit)))) }
        return try handle.read(upToCount: limit) ?? Data()
    }
}
