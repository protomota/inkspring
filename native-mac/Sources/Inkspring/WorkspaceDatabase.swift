import CSQLite
import Foundation

struct WorkspaceError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct WorkspaceRecord: Identifiable {
    let kind: String
    var fields: [String: Any]

    var id: String { self["id"] }
    var projectID: String { self["projectId"] }

    var title: String {
        let key = switch kind {
        case "project": "name"
        case "idea": "topic"
        case "reply-inbox": "author"
        default: "title"
        }
        let value = self[key]
        if kind == "draft" {
            return draftTitle.isEmpty ? "Untitled" : draftTitle
        }
        return value.isEmpty ? "Untitled" : value
    }

    var draftTitle: String {
        let stored = self["title"].trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentNote = #"(?i)\s*\(attach\s+(?:https?://[^\r\n]+|[^\r\n]+\.(?:mp4|mov|webm|png|jpe?g|webp))\)\s*$"#
        let mediaFile = #"(?i)^[^\s]+\.(?:mp4|mov|webm|png|jpe?g|webp)(?:[?#]\S*)?$"#
        let urlOnly = #"(?i)^https?://\S+$"#
        let titleWithoutNote = stored.replacingOccurrences(of: attachmentNote, with: "", options: .regularExpression)
        let attachedVideoName = (fields["video"] as? [String: Any])?["name"] as? String
        let isMediaReference = stored == attachedVideoName
            || stored.range(of: mediaFile, options: .regularExpression) != nil
            || stored.range(of: urlOnly, options: .regularExpression) != nil
        if !stored.isEmpty, titleWithoutNote == stored, !isMediaReference { return stored }

        for line in body.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.range(of: urlOnly, options: .regularExpression) == nil,
                  text.range(of: mediaFile, options: .regularExpression) == nil else { continue }
            let sentence = (text as NSString).range(of: #"[.!?](?=\s|$)"#, options: .regularExpression)
            let opening = sentence.location == NSNotFound ? text : (text as NSString).substring(to: NSMaxRange(sentence))
            if opening.count <= 100 { return opening }
            let words = opening.prefix(101).split(whereSeparator: \.isWhitespace)
            let shortened = words.dropLast().joined(separator: " ")
            return shortened.isEmpty ? String(opening.prefix(100)) : shortened
        }
        return isMediaReference ? "" : titleWithoutNote
    }

    var body: String {
        self[["source", "idea", "reply-inbox"].contains(kind) ? "text" : kind == "newsletter" ? "body" : "content"]
    }

    var schedule: [String: Any] { fields["schedule"] as? [String: Any] ?? [:] }
    var scheduleStatus: String { schedule["status"] as? String ?? "" }
    var comments: [[String: Any]] { fields["reviewComments"] as? [[String: Any]] ?? [] }
    var draftVersions: [String: String] { fields["versions"] as? [String: String] ?? [:] }
    var isPendingPostIdea: Bool { kind == "idea" && self["status"] == "draft" && draftVersions.isEmpty }

    mutating func setDraftMedia(_ attachment: [String: Any], as kind: DraftMediaKind) {
        if kind == .image || (fields["video"] as? [String: Any])?["id"] as? String != attachment["id"] as? String {
            fields["videoThumbnail"] = nil
        }
        fields[kind.rawValue] = attachment
        fields[kind == .image ? "video" : "image"] = nil
    }

    mutating func prepareDraftForSave() {
        self["title"] = draftTitle
        if self["format"] != "reply" { fields["replyTo"] = nil }
        if self["platform"] != "linkedin" { fields["linkedinDestination"] = nil }
        fields["sample"] = false
    }

    subscript(key: String) -> String {
        get { fields[key] as? String ?? "" }
        set { fields[key] = newValue }
    }

    static var timestamp: String { workspaceTimestamp(.now) }

    mutating func markUpdated(after previous: String? = nil) {
        let last = scheduleDate(previous ?? self["updatedAt"])
        let now = Date.now
        // The portable timestamp format has millisecond precision. Two writes
        // in the same millisecond still need distinct optimistic revisions.
        let next = last.map { max(now, $0.addingTimeInterval(0.002)) } ?? now
        self["updatedAt"] = workspaceTimestamp(next)
    }

    static func new(_ kind: String, projectID: String = "") -> Self {
        let now = timestamp
        var fields: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "createdAt": now,
            "updatedAt": now
        ]
        if !projectID.isEmpty { fields["projectId"] = projectID }
        switch kind {
        case "project":
            fields["color"] = "#C4613C"
            fields["icon"] = "dot"
        case "draft":
            fields["platform"] = "x"
            fields["format"] = "post"
            fields["status"] = "draft"
        case "idea":
            fields["kind"] = "work"
            fields["status"] = "draft"
            fields["date"] = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            fields["suggestedPlatforms"] = ["x"]
        case "newsletter":
            fields["state"] = "draft"
            fields["sendEmail"] = false
            fields["audience"] = "everyone"
        default:
            break
        }
        return Self(kind: kind, fields: fields)
    }
}

enum DraftMediaKind: String, CaseIterable {
    case image, video

    var title: String { rawValue.capitalized }
    var symbol: String { self == .image ? "photo" : "video" }
}

final class WorkspaceDatabase {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw WorkspaceError("Could not open the Inkspring workspace.")
        }
        handle = database
        sqlite3_busy_timeout(handle, 5000)
        do {
            try execute("""
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS records (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, project_id TEXT, payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS records_kind ON records(kind);
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    private var databaseError: WorkspaceError {
        WorkspaceError(String(cString: sqlite3_errmsg(handle)))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError }
    }

    private func statement<T>(_ sql: String, _ values: [String?] = [],
                              run: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared else { throw databaseError }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = value.map { sqlite3_bind_text(prepared, index, $0, -1, transient) }
                ?? sqlite3_bind_null(prepared, index)
            guard result == SQLITE_OK else { throw databaseError }
        }
        return try run(prepared)
    }

    func records() throws -> [WorkspaceRecord] {
        try statement("SELECT kind, payload FROM records ORDER BY rowid DESC") { statement in
            var records: [WorkspaceRecord] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return records
                case SQLITE_ROW:
                    let kind = String(cString: sqlite3_column_text(statement, 0))
                    let json = String(cString: sqlite3_column_text(statement, 1))
                    guard let fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                          let id = fields["id"] as? String, !id.isEmpty else {
                        throw WorkspaceError("The workspace contains an invalid \(kind) record.")
                    }
                    records.append(WorkspaceRecord(kind: kind, fields: fields))
                default: throw databaseError
                }
            }
        }
    }

    func put(_ record: WorkspaceRecord) throws {
        let payload = try JSONSerialization.data(withJSONObject: record.fields)
        try statement("""
            INSERT INTO records (id, kind, project_id, payload) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, payload = excluded.payload
            WHERE records.kind = excluded.kind
            """, [record.id, record.kind, record.projectID.isEmpty ? nil : record.projectID,
                  String(decoding: payload, as: UTF8.self)]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
            guard sqlite3_changes(handle) == 1 else {
                throw WorkspaceError("This record ID belongs to another type of workspace item.")
            }
        }
    }

    func remove(_ id: String, kind: String) throws {
        try statement("DELETE FROM records WHERE id = ? AND kind = ?", [id, kind]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
        }
    }

    func settings() throws -> [String: Any] {
        try statement("SELECT key, value FROM settings") { statement in
            var settings: [String: Any] = [:]
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return settings
                case SQLITE_ROW:
                    let key = String(cString: sqlite3_column_text(statement, 0))
                    let json = String(cString: sqlite3_column_text(statement, 1))
                    settings[key] = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
                default: throw databaseError
                }
            }
        }
    }

    func set(_ key: String, to value: Any) throws {
        let payload = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        try statement("""
            INSERT INTO settings (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [key, String(decoding: payload, as: UTF8.self)]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
        }
    }

    func transaction<T>(_ changes: () throws -> T) throws -> T {
        if sqlite3_get_autocommit(handle) == 0 { return try changes() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try changes()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

extension WorkspaceDatabase {
    func snapshot() throws -> (records: [WorkspaceRecord], settings: [String: Any]) {
        try execute("BEGIN")
        do {
            let snapshot = (try records(), try settings())
            try execute("COMMIT")
            return snapshot
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

func workspaceTimestamp(_ date: Date) -> String {
    date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

extension WorkspaceDatabase {
    static func copy(from source: URL, to destination: URL) throws {
        var sourceDatabase: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDatabase, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let sourceDatabase else {
            if let sourceDatabase { sqlite3_close(sourceDatabase) }
            throw WorkspaceError("Couldn’t read the source workspace database.")
        }
        defer { sqlite3_close(sourceDatabase) }
        sqlite3_busy_timeout(sourceDatabase, 5000)
        let destination = try WorkspaceDatabase(url: destination)
        guard let backup = sqlite3_backup_init(destination.handle, "main", sourceDatabase, "main") else {
            throw destination.databaseError
        }
        var status = sqlite3_backup_step(backup, -1)
        for _ in 0..<40 where status == SQLITE_BUSY || status == SQLITE_LOCKED {
            sqlite3_sleep(125)
            status = sqlite3_backup_step(backup, -1)
        }
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw destination.databaseError }
    }
}

extension WorkspaceDatabase {
    func dataVersion() throws -> Int32 {
        try statement("PRAGMA data_version") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError }
            return sqlite3_column_int(statement, 0)
        }
    }
}
