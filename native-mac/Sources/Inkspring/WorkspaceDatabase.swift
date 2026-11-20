import CSQLite
import Foundation
import CryptoKit
import InkspringSchedule

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
    var referenceID: String? { self["referenceId"].isEmpty ? nil : self["referenceId"] }
    var isLongForm: Bool { ["newsletter", "script", "article"].contains(kind) }

    func matchesID(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return id == key || referenceID == key.uppercased()
    }

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
        self[["source", "idea", "reply-inbox"].contains(kind) ? "text" : isLongForm ? "body" : "content"]
    }

    var schedule: [String: Any] { fields["schedule"] as? [String: Any] ?? [:] }
    var scheduleStatus: String { schedule["status"] as? String ?? "" }
    var comments: [[String: Any]] { fields["reviewComments"] as? [[String: Any]] ?? [] }
    var draftVersions: [String: String] { fields["versions"] as? [String: String] ?? [:] }
    var isPendingPostIdea: Bool { kind == "idea" && self["status"] == "draft" && draftVersions.isEmpty }

    mutating func setDraftMedia(_ attachment: [String: Any], as kind: DraftMediaKind) {
        if kind == .image || (fields["video"] as? [String: Any])?["id"] as? String != attachment["id"] as? String {
            fields["videoThumbnail"] = nil
            fields["tiktokCoverTime"] = nil
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
        case "script", "article":
            fields["platform"] = kind == "article" ? "x" : "youtube"
            fields["state"] = "draft"
            fields["body"] = ""
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
                CREATE TABLE IF NOT EXISTS content_revisions (
                    id TEXT NOT NULL, record_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(record_id, id)
                );
                CREATE INDEX IF NOT EXISTS content_revisions_item ON content_revisions(record_id);
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS agent_chats (
                    id TEXT PRIMARY KEY, project_id TEXT NOT NULL, updated REAL NOT NULL, payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS agent_chats_project ON agent_chats(project_id, updated DESC);
                CREATE TABLE IF NOT EXISTS content_identifiers (
                    record_id TEXT PRIMARY KEY NOT NULL, reference TEXT UNIQUE NOT NULL
                );
                CREATE INDEX IF NOT EXISTS content_identifiers_number ON content_identifiers(
                    substr(reference, 1, 3), CAST(substr(reference, 5) AS INTEGER) DESC
                ) WHERE length(reference) > 3;
                """)
            try backfillContentIdentifiers()
            for record in try records() where ["draft", "newsletter", "script", "article"].contains(record.kind) {
                try archiveRevision(record)
            }
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
        try statement("""
            SELECT kind, payload, reference FROM records
            LEFT JOIN content_identifiers ON records.id = record_id ORDER BY records.rowid DESC
            """) { statement in
            var records: [WorkspaceRecord] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return records
                case SQLITE_ROW:
                    let kind = String(cString: sqlite3_column_text(statement, 0))
                    let json = String(cString: sqlite3_column_text(statement, 1))
                    guard var fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                          let id = fields["id"] as? String, !id.isEmpty else {
                        throw WorkspaceError("The workspace contains an invalid \(kind) record.")
                    }
                    if let reference = sqlite3_column_text(statement, 2) {
                        fields[kind == "project" ? "projectKey" : "referenceId"] = String(cString: reference)
                    }
                    records.append(WorkspaceRecord(kind: kind, fields: fields))
                default: throw databaseError
                }
            }
        }
    }

    @discardableResult
    func put(_ input: WorkspaceRecord) throws -> WorkspaceRecord {
        guard ["project", "draft", "newsletter", "script", "article"].contains(input.kind) else {
            try writeRecord(input)
            return input
        }
        return try transaction {
            var record = input
            if record.kind == "project" {
                record["projectKey"] = try projectKey(id: record.id, name: record["name"], preferred: record["projectKey"])
            } else {
                record["referenceId"] = try contentReference(for: record)
            }
            try writeRecord(record)
            return record
        }
    }

    private func writeRecord(_ input: WorkspaceRecord) throws {
        var record = input
        if ["draft", "newsletter", "script", "article"].contains(record.kind) {
            if let imported = record.fields.removeValue(forKey: "_revisionHistory") {
                let snapshots = try JSONDecoder().decode([ContentRevision].self, from: JSONSerialization.data(withJSONObject: imported))
                for snapshot in snapshots { try storeRevision(snapshot, recordID: record.id) }
            }
            let old: WorkspaceRecord? = try statement("SELECT payload FROM records WHERE id = ? AND kind = ?", [record.id, record.kind]) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                let fields = try JSONSerialization.jsonObject(with: Data(String(cString: sqlite3_column_text(statement, 0)).utf8)) as? [String: Any] ?? [:]
                return WorkspaceRecord(kind: record.kind, fields: fields)
            }
            if let old { try archiveRevision(old) }
            try archiveRevision(record)
        }
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

    private func archiveRevision(_ record: WorkspaceRecord) throws {
        if record.kind == "draft", !record["previousContent"].isEmpty, record["previousContent"] != record.body {
            let data = try JSONEncoder().encode([record.id, record["previousContent"]])
            let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try storeRevision(.init(id: id, savedAt: nil, title: record.title, text: record["previousContent"],
                format: record["format"], source: "Recovered earlier agent revision"), recordID: record.id)
        }
        let fields = [record.id, record["updatedAt"], record.title, record.body, record["format"], record["subtitle"]]
        let data = try JSONEncoder().encode(fields)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try storeRevision(.init(id: id, savedAt: record["updatedAt"], title: record.title, text: record.body,
            format: record.kind == "draft" ? record["format"] : nil,
            subtitle: record.isLongForm ? record["subtitle"] : nil, source: "Mac"), recordID: record.id)
    }

    func storeRevision(_ revision: ContentRevision, recordID: String) throws {
        guard revision.valid else { throw WorkspaceError("This saved revision is invalid.") }
        let payload = String(decoding: try JSONEncoder().encode(revision), as: UTF8.self)
        try statement("INSERT OR IGNORE INTO content_revisions (id, record_id, payload) VALUES (?, ?, ?)", [revision.id, recordID, payload]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
        }
    }

    func revisionHistory(recordID: String) throws -> [ContentRevision] {
        try statement("SELECT payload FROM content_revisions WHERE record_id = ? ORDER BY rowid DESC", [recordID]) { statement in
            var result: [ContentRevision] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return result.sorted { ($0.savedAt ?? "") > ($1.savedAt ?? "") }
                case SQLITE_ROW:
                    let data = Data(String(cString: sqlite3_column_text(statement, 0)).utf8)
                    result.append(try JSONDecoder().decode(ContentRevision.self, from: data))
                default: throw databaseError
                }
            }
        }
    }

    private func backfillContentIdentifiers() throws {
        let needsBackfill = try statement("""
            SELECT 1 FROM records LEFT JOIN content_identifiers ON records.id = record_id
            WHERE records.kind IN ('project', 'draft', 'newsletter', 'script', 'article') AND record_id IS NULL LIMIT 1
            """) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return false
            case SQLITE_ROW: return true
            default: throw databaseError
            }
        }
        guard needsBackfill else { return }
        try transaction {
            let rows = try records().sorted { ($0["createdAt"], $0.id) < ($1["createdAt"], $1.id) }
            for row in rows.filter({ $0.kind == "project" }) + rows.filter({ ["draft", "newsletter", "script", "article"].contains($0.kind) }) {
                if try identifier(for: row.id) == nil { try put(row) }
            }
        }
    }

    private func identifier(for id: String) throws -> String? {
        try statement("SELECT reference FROM content_identifiers WHERE record_id = ?", [id]) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return nil
            case SQLITE_ROW: return String(cString: sqlite3_column_text(statement, 0))
            default: throw databaseError
            }
        }
    }

    private func reserve(_ reference: String, for id: String) throws -> Bool {
        try statement("""
            INSERT INTO content_identifiers (record_id, reference) VALUES (?, ?)
            ON CONFLICT(reference) DO NOTHING
            """, [id, reference]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
            return sqlite3_changes(handle) == 1
        }
    }

    private func projectKey(id: String, name: String, preferred: String = "") throws -> String {
        if let existing = try identifier(for: id) { return existing }
        if preferred.range(of: #"\A[A-Z]{3}\z"#, options: .regularExpression) != nil,
           try reserve(preferred, for: id) { return preferred }

        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let cleaned = name.decomposedStringWithCompatibilityMapping.uppercased().filter { letters.contains($0) }
        let stem = String(cleaned.prefix(3)).padding(toLength: 3, withPad: "X", startingAt: 0)
        let occupied: Set<String> = try statement("SELECT reference FROM content_identifiers WHERE length(reference) = 3") { statement in
            var keys: Set<String> = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return keys
                case SQLITE_ROW: keys.insert(String(cString: sqlite3_column_text(statement, 0)))
                default: throw databaseError
                }
            }
        }
        let nearby = [stem] + letters.map { String(stem.prefix(2)) + String($0) }
        let key = nearby.first { !occupied.contains($0) } ?? (0..<(26 * 26 * 26)).lazy.map { index in
            String([letters[index / 676], letters[index / 26 % 26], letters[index % 26]])
        }.first { !occupied.contains($0) }
        guard let key, try reserve(key, for: id) else {
            throw WorkspaceError("No project IDs are available.")
        }
        return key
    }

    private func contentReference(for record: WorkspaceRecord) throws -> String {
        if let existing = try identifier(for: record.id), existing.contains("-") { return existing }

        let preferred = record.referenceID ?? ""
        if preferred.range(of: #"\A[A-Z]{3}-[0-9]{3,15}\z"#, options: .regularExpression) != nil,
           let number = Int64(preferred.dropFirst(4)), number > 0,
           preferred == formatReference(prefix: String(preferred.prefix(3)), number: number),
           try reserve(preferred, for: record.id) { return preferred }
        let project = try projectKey(id: record.projectID, name: "Inkspring")
        // Reservations survive deletion, so a pasted ID can never resolve to a new item.
        let number: Int64 = try statement("""
            SELECT CAST(substr(reference, 5) AS INTEGER) FROM content_identifiers
            WHERE substr(reference, 1, 3) = ? AND length(reference) > 3
            ORDER BY CAST(substr(reference, 5) AS INTEGER) DESC LIMIT 1
            """, [project]) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return 1
            case SQLITE_ROW: return sqlite3_column_int64(statement, 0) + 1
            default: throw databaseError
            }
        }
        let reference = formatReference(prefix: project, number: number)
        guard try reserve(reference, for: record.id) else {
            throw WorkspaceError("Could not assign a unique post or newsletter ID.")
        }
        return reference
    }

    private func formatReference(prefix: String, number: Int64) -> String {
        let digits = String(number)
        return prefix + "-" + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }

    func remove(_ id: String, kind: String) throws {
        try statement("DELETE FROM records WHERE id = ? AND kind = ?", [id, kind]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
        }
        try statement("DELETE FROM content_revisions WHERE record_id = ?", [id]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
        }
    }

    func agentChats(projectID: String) throws -> [StudioAgentConversation] {
        try statement("SELECT payload FROM agent_chats WHERE project_id = ? ORDER BY updated DESC, rowid DESC", [projectID]) { statement in
            let decoder = JSONDecoder()
            var chats: [StudioAgentConversation] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return chats
                case SQLITE_ROW:
                    let payload = String(cString: sqlite3_column_text(statement, 0))
                    chats.append(try decoder.decode(StudioAgentConversation.self, from: Data(payload.utf8)))
                default: throw databaseError
                }
            }
        }
    }

    @discardableResult
    func saveAgentChat(_ chat: StudioAgentConversation, projectID: String, isNew: Bool) throws -> Bool {
        let payload = String(decoding: try JSONEncoder().encode(chat), as: UTF8.self)
        let sql = isNew
            ? "INSERT INTO agent_chats (payload, updated, id, project_id) VALUES (?, ?, ?, ?)"
            : "UPDATE agent_chats SET payload = ?, updated = ? WHERE id = ? AND project_id = ?"
        return try statement(sql, [payload, String(chat.updatedAt.timeIntervalSince1970), chat.id.uuidString, projectID]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError }
            return sqlite3_changes(handle) == 1
        }
    }

    func hasAgentChats() throws -> Bool {
        try statement("SELECT EXISTS(SELECT 1 FROM agent_chats)") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    func deleteAgentChats(projectID: String, chatID: UUID?) throws {
        let sql = chatID == nil ? "DELETE FROM agent_chats" : "DELETE FROM agent_chats WHERE project_id = ? AND id = ?"
        let values = chatID.map { [projectID, $0.uuidString] } ?? []
        try statement(sql, values) { statement in
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
            var rows = try records()
            for index in rows.indices where ["draft", "newsletter", "script", "article"].contains(rows[index].kind) {
                rows[index].fields["_revisionHistory"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(revisionHistory(recordID: rows[index].id)))
            }
            let snapshot = (rows, try settings())
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
