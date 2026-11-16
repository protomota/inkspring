import Foundation

struct WorkspaceBackup {
    let records: [WorkspaceRecord]
    let preferences: [String: Any]
    let media: [Media]
    let stagingDirectory: URL?
    var isLegacy = false

    struct RestorePlan: Equatable {
        let preservedIDs: Set<String>
        let replacements: [String: String]
    }

    func restorePlan(over current: [WorkspaceRecord]) throws -> RestorePlan {
        let local = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let deliveryStates = ["publishing", "published", "uncertain", "partial"]
        let protectedDrafts = Set(current.filter {
            $0.kind == "publication" && deliveryStates.contains($0["status"])
        }.map { $0["draftId"] })
        var preserved = Set<String>()
        var replacements: [String: String] = [:]
        for incoming in records {
            guard let existing = local[incoming.id] else { continue }
            guard incoming.kind == existing.kind else {
                throw WorkspaceError("A backup ID conflicts with a different type of local record.")
            }
            let keep = switch existing.kind {
            case "publication":
                existing["status"] == "published" || incoming["status"] != "published" || existing["draftId"] != incoming["draftId"]
            case "newsletter": !existing["remoteId"].isEmpty
            case "draft": ["posting", "posted"].contains(existing.scheduleStatus) || protectedDrafts.contains(existing.id)
            default: false
            }
            if keep { preserved.insert(existing.id) }
            else { replacements[existing.id] = existing["updatedAt"] }
        }
        return RestorePlan(preservedIDs: preserved, replacements: replacements)
    }

    struct Media: Codable {
        let kind: String
        let file: String?
        let id: String?
        let entry: String
        let size: Int64
        let sha256: String

        func validate() throws {
            let validPath = switch kind {
            case "image": file.map { entry == "media/images/" + $0 } ?? false
            case "video": id.map { entry.hasPrefix("media/videos/" + $0 + ".") } ?? false
            default: false
            }
            guard validPath, ZipArchive.safe(entry), (1...ZipArchive.mediaLimit).contains(size),
                  sha256.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
                throw WorkspaceError("The backup has an invalid media manifest.")
            }
        }
    }

    private static let supportedKinds: Set<String> = [
        "project", "draft", "source", "idea", "newsletter", "publication", "personal-inbox",
        "discovery", "research-feedback", "brief-run", "idea-queue-state", "reply-inbox",
        "analytics-day", "analytics-post", "analytics-state", "r2-object", "local-video"
    ]

    private static let safePreferences: Set<String> = [
        StudioWritingConnection.preferenceKey, "provider", "imageProvider", "anthropicModel", "openaiModel", "geminiModel",
        "openaiImageModel", "geminiImageModel", "anthropicWorkspaceId", "personalProfile",
        "personalSetupDismissed", "ideaQueueTarget"
    ]

    private static let secretFields: Set<String> = [
        "apikey", "accesstoken", "refreshtoken", "idtoken", "clientsecret", "secretaccesskey",
        "accesskeyid", "password", "authorization", "cookie", "cookies", "session", "sessionkey",
        "token", "credentials", "privatekey", "signingkey", "codeverifier", "oauthstate", "uploadurl",
        "presignedurl", "proto", "constructor", "prototype"
    ]

    static func stage(_ url: URL, in directory: URL) throws -> (backup: Self, files: [String: URL]) {
        if url.pathExtension.lowercased() == "json" {
            return (try stageLegacy(url), [:])
        }
        let staging = try temporaryDirectory(in: directory)
        do {
            let files = try ZipArchive.extract(from: url, to: staging)
            guard let manifest = files["data.json"],
                  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
                  object["app"] as? String == "inkspring-desktop", object["version"] as? Int == 2,
                  let rows = object["records"] as? [[String: Any]], rows.count <= 100_000,
                  let preferences = object["preferences"] as? [String: Any],
                  Set(preferences.keys).isSubset(of: safePreferences),
                  let entries = object["media"] as? [[String: Any]], entries.count <= 10_000 else {
                throw WorkspaceError("Choose an Inkspring workspace ZIP backup (version 2).")
            }
            let records = try rows.map { row in
                guard let kind = row["kind"] as? String, let fields = row["value"] as? [String: Any] else {
                    throw WorkspaceError("The backup contains an invalid workspace record.")
                }
                return try sanitized(WorkspaceRecord(kind: kind, fields: fields))
            }
            let media = try JSONDecoder().decode([Media].self, from: JSONSerialization.data(withJSONObject: entries))
            try validate(records, media: media)
            guard files.count == media.count + 1 else { throw WorkspaceError("The ZIP does not match its media manifest.") }
            for item in media {
                guard let file = files[item.entry],
                      try fileDigest(file) == (item.sha256, item.size) else {
                    throw WorkspaceError("A backup media file is missing or damaged.")
                }
            }
            var cleanPreferences = try clean(preferences) as? [String: Any] ?? [:]
            if let rawTheme = object[StudioTheme.preferenceKey] as? String, let theme = StudioTheme(rawValue: rawTheme) {
                cleanPreferences[StudioTheme.preferenceKey] = theme.rawValue
            }
            return (Self(records: records, preferences: cleanPreferences, media: media, stagingDirectory: staging), files)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func stageLegacy(_ url: URL) throws -> Self {
        let limit = 20_000_000
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= limit else {
            throw WorkspaceError("Choose a regular JSON backup file under 20 MB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw WorkspaceError("Choose an older JSON backup under 20 MB.") }
        guard let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              data["version"] as? Int == 1,
              data["app"] == nil || data["app"] as? String == "inkspring-desktop" else {
            throw WorkspaceError("Choose an Inkspring workspace JSON backup (version 1).")
        }
        var records: [WorkspaceRecord] = []
        for (field, kind, required) in [("projects", "project", true), ("drafts", "draft", true),
                                       ("sources", "source", true), ("ideas", "idea", false),
                                       ("newsletters", "newsletter", false), ("publications", "publication", false)] {
            if !required, data[field] == nil { continue }
            guard let rows = data[field] as? [[String: Any]], rows.count <= 10_000 else {
                throw WorkspaceError("The older backup has an invalid \(field) list.")
            }
            for fields in rows {
                var row = try sanitized(WorkspaceRecord(kind: kind, fields: fields))
                let titleKey = kind == "project" ? "name" : kind == "idea" ? "topic" : "title"
                guard kind == "project" || !row.projectID.isEmpty,
                      kind == "publication" || !row[titleKey].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkspaceError("An older backup record is missing a project or title.")
                }
                for key in ["image", "video", "coverImage", "videoThumbnail"] { row.fields.removeValue(forKey: key) }
                if kind == "draft", row["format"] == "carousel" {
                    let slides = (row.fields.removeValue(forKey: "slides") as? [[String: Any]] ?? []).map { slide in
                        ["title", "body"].compactMap { slide[$0] as? String }
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            .joined(separator: "\n")
                    }
                    row["content"] = String(([row["content"]] + slides).filter { !$0.isEmpty }
                        .joined(separator: "\n\n").prefix(40_000))
                    row["format"] = "post"
                }
                if kind == "newsletter" {
                    for key in ["remoteId", "publication", "editUrl", "publicUrl", "postUrl", "remoteFingerprint",
                                "syncedRevision", "scheduledAt", "publishedAt", "requestedAction", "requestedAt", "error"] {
                        row.fields.removeValue(forKey: key)
                    }
                    row["state"] = "draft"
                    row.fields["revision"] = 1
                    if row["audience"].isEmpty { row["audience"] = "everyone" }
                }
                records.append(row)
            }
        }
        try validate(records, media: [])
        let drafts = Dictionary(uniqueKeysWithValues: records.filter { $0.kind == "draft" }.map { ($0.id, $0.projectID) })
        guard records.filter({ $0.kind == "publication" }).allSatisfy({ drafts[$0["draftId"]] == $0.projectID }) else {
            throw WorkspaceError("An older backup receipt references a missing post.")
        }
        var preferences: [String: Any] = [:]
        if let profile = data["personalProfile"] {
            guard let fields = try clean(profile) as? [String: Any] else { throw WorkspaceError("Invalid writing profile in backup.") }
            preferences["personalProfile"] = try PersonalProfile.normalized(fields)
        }
        return Self(records: records, preferences: preferences, media: [], stagingDirectory: nil, isLegacy: true)
    }

    static func export(records: [WorkspaceRecord], preferences: [String: Any], directory: URL, to url: URL,
                       stagingParent: URL? = nil) throws {
        let staging = try temporaryDirectory(in: stagingParent ?? directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let records = records.filter { $0.kind != "tiktok-consent" }
        let rows = try records.reversed().map(sanitized)
        let portablePreferences = try clean(preferences.filter { safePreferences.contains($0.key) })
        var media: [Media] = []
        var files: [(path: String, file: URL, size: Int64)] = []
        let images = directory.appending(path: "images")
        if FileManager.default.fileExists(atPath: images.path) {
            for file in try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil) {
                let entry = "media/images/" + file.lastPathComponent
                guard ZipArchive.safe(entry) else { continue }
                let digest = try regularFileDigest(file)
                media.append(Media(kind: "image", file: file.lastPathComponent, id: nil, entry: entry,
                                   size: digest.size, sha256: digest.hash))
                files.append((entry, file, digest.size))
            }
        }
        for video in records where video.kind == "local-video" {
            guard !video["path"].isEmpty else { throw WorkspaceError("A saved video is unavailable.") }
            let file = URL(fileURLWithPath: video["path"])
            let entry = "media/videos/\(video.id).\(file.pathExtension.lowercased())"
            let digest = try regularFileDigest(file)
            guard digest.hash == video["hash"], digest.size == video.fields["size"] as? Int64 else {
                throw WorkspaceError("A video changed after it was attached. Attach it again before backing up.")
            }
            media.append(Media(kind: "video", file: nil, id: video.id, entry: entry,
                               size: digest.size, sha256: digest.hash))
            files.append((entry, file, digest.size))
        }
        try validate(rows, media: media)
        let manifest = staging.appending(path: "data.json")
        var contents: [String: Any] = [
            "app": "inkspring-desktop", "version": 2, "exportedAt": WorkspaceRecord.timestamp,
            "records": rows.map { ["kind": $0.kind, "value": $0.fields] }, "preferences": portablePreferences,
            "media": try JSONSerialization.jsonObject(with: JSONEncoder().encode(media))
        ]
        // Older importers ignore extra manifest fields and reject unknown preference keys.
        if let rawTheme = preferences[StudioTheme.preferenceKey] as? String, let theme = StudioTheme(rawValue: rawTheme) {
            contents[StudioTheme.preferenceKey] = theme.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: contents)
        guard data.count <= ZipArchive.jsonLimit else { throw WorkspaceError("Workspace data exceeds the 100 MB backup limit.") }
        try data.write(to: manifest)
        let temporary = url.deletingLastPathComponent().appending(path: ".inkspring-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try ZipArchive.write(to: temporary, files: [("data.json", manifest, Int64(data.count))] + files)
        for (item, file) in zip(media, files) {
            guard try regularFileDigest(file.file) == (item.sha256, item.size) else {
                throw WorkspaceError("A media file changed during backup. Try again.")
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    func restored(_ record: WorkspaceRecord) -> WorkspaceRecord {
        var record = record
        switch record.kind {
        case "draft" where ["queued", "posting", "due"].contains(record.scheduleStatus):
            var schedule = record.schedule
            schedule["originalSlotAt"] = schedule["originalSlotAt"] ?? schedule["slotAt"]
            schedule["slotAt"] = ""
            schedule["status"] = "ready"
            schedule["error"] = "Restored from backup. Review this post and choose a new time."
            record.fields["schedule"] = schedule
        case "newsletter":
            record.fields["restoreSendEmail"] = record.fields["restoreSendEmail"] ?? record.fields["sendEmail"]
            record.fields["sendEmail"] = false
            if !record["remoteId"].isEmpty {
                record.fields["restorePreviousState"] = record.fields["restorePreviousState"] ?? record.fields["state"]
                record["state"] = "uncertain"
                record["error"] = "Check Substack before syncing or sending. An existing remote schedule may still run there."
            } else {
                record["state"] = "draft"
                record.fields["scheduledAt"] = nil
            }
        case "publication" where record["status"] != "published":
            record["status"] = "uncertain"
            record["error"] = "Restored receipt. Check the platform before another publishing attempt."
        default:
            break
        }
        return record
    }

    private static func validate(_ records: [WorkspaceRecord], media: [Media]) throws {
        let projects = Set(records.filter { $0.kind == "project" }.map(\.id))
        var ids: Set<String> = []
        guard records.count <= 100_000, media.count <= 10_000 else {
            throw WorkspaceError("This backup has too many records or files.")
        }
        for row in records {
            guard supportedKinds.contains(row.kind), !row.id.isEmpty, row.id.utf16.count <= 500,
                  !row.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  ids.insert(row.id).inserted, row.projectID.isEmpty || projects.contains(row.projectID) else {
                throw WorkspaceError("The backup contains an invalid or duplicate record.")
            }
        }
        var paths: Set<String> = []
        var images: Set<String> = []
        var videos: Set<String> = []
        var size: Int64 = 0
        for item in media {
            try item.validate()
            guard paths.insert(item.entry).inserted else { throw WorkspaceError("The backup repeats a media path.") }
            if let file = item.file, item.kind == "image" { images.insert(file) }
            if let id = item.id, item.kind == "video", !videos.insert(id).inserted {
                throw WorkspaceError("The backup repeats a video.")
            }
            size += item.size
            guard size <= ZipArchive.totalLimit - ZipArchive.jsonLimit else {
                throw WorkspaceError("This backup exceeds 64 GB of media.")
            }
        }
        let videoRecords = Set(records.filter { $0.kind == "local-video" }.map(\.id))
        for row in records {
            if row.kind == "draft" || row.kind == "newsletter" {
                for key in row.kind == "draft" ? ["image", "videoThumbnail"] : ["coverImage"] {
                    if let image = row.fields[key] as? [String: Any],
                       !images.contains(image["file"] as? String ?? "") {
                        throw WorkspaceError("A workspace image is missing from the backup.")
                    }
                }
            }
            if row.kind == "draft", let video = row.fields["video"] as? [String: Any] {
                let id = video["id"] as? String ?? ""
                guard videos.contains(id), videoRecords.contains(id) else {
                    throw WorkspaceError("A draft video is missing from the backup.")
                }
            }
            if row.kind == "local-video", !videos.contains(row.id) {
                throw WorkspaceError("A workspace video is missing from the backup.")
            }
        }
    }

    private static func sanitized(_ input: WorkspaceRecord) throws -> WorkspaceRecord {
        var record = WorkspaceRecord(kind: input.kind, fields: try clean(input.fields) as? [String: Any] ?? [:])
        if record.kind == "local-video" {
            record.fields["path"] = nil
            record.fields["mtime"] = nil
        }
        if record.kind == "publication" {
            record.fields["containers"] = []
            record.fields["containerId"] = nil
        }
        return record
    }

    private static func clean(_ input: Any, depth: Int = 0) throws -> Any {
        guard depth <= 40 else { throw WorkspaceError("This backup contains excessively nested data.") }
        if let values = input as? [Any] { return try values.map { try clean($0, depth: depth + 1) } }
        if let object = input as? [String: Any] {
            return try object.filter {
                let key = $0.key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                return !secretFields.contains(key)
            }.mapValues { try clean($0, depth: depth + 1) }
        }
        return input
    }

    private static func regularFileDigest(_ file: URL) throws -> (hash: String, size: Int64) {
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw WorkspaceError("Backups require regular image and video files.")
        }
        return try fileDigest(file)
    }

    private static func temporaryDirectory(in directory: URL) throws -> URL {
        let folder = directory.appending(path: ".transfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        return folder
    }
}
