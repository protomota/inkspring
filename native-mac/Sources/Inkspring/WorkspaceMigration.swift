import Foundation

struct WorkspaceMigration {
    struct Report {
        let records: Int
        let images: Int
        let videos: Int
    }

    static func prepareImport(from source: URL, into workspace: URL) throws -> URL {
        let database = source.appending(path: "workspace.sqlite")
        let attributes = try? database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.resolvingSymlinksInPath().standardizedFileURL != workspace.resolvingSymlinksInPath().standardizedFileURL,
              attributes?.isRegularFile == true, attributes?.isSymbolicLink != true else {
            throw WorkspaceError("Choose an Inkspring workspace folder containing workspace.sqlite.")
        }
        let staging = workspace.appending(path: ".workspace-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let snapshotFile = staging.appending(path: "workspace.sqlite")
            try WorkspaceDatabase.copy(from: database, to: snapshotFile)
            let snapshot = try WorkspaceDatabase(url: snapshotFile).snapshot()
            let archive = staging.appending(path: "Workspace.zip")
            try WorkspaceBackup.export(records: snapshot.records, preferences: snapshot.settings,
                                       directory: source, to: archive, stagingParent: staging)
            return archive
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    static func stage(from source: URL, to destination: URL) throws -> Report {
        let manager = FileManager.default
        let sourceDatabase = source.appending(path: "workspace.sqlite")
        guard source.standardizedFileURL != destination.standardizedFileURL,
              manager.fileExists(atPath: sourceDatabase.path),
              !manager.fileExists(atPath: destination.path) else {
            throw WorkspaceError("Choose an existing Inkspring workspace and a new destination folder.")
        }
        let parent = destination.deletingLastPathComponent()
        let stage = parent.appending(path: ".inkspring-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        try WorkspaceDatabase.copy(from: sourceDatabase, to: stage.appending(path: "workspace.sqlite"))
        let result = try copyAttachmentsAndPrepare(source: source, stage: stage, destination: destination)
        try manager.moveItem(at: stage, to: destination)
        return result
    }

    private static func copyAttachmentsAndPrepare(source: URL, stage: URL, destination: URL) throws -> Report {
        let manager = FileManager.default
        let database = try WorkspaceDatabase(url: stage.appending(path: "workspace.sqlite"))
        let records = try database.records()
        let sourceImages = source.appending(path: "images", directoryHint: .isDirectory)
        let images = stage.appending(path: "images", directoryHint: .isDirectory)
        let videos = stage.appending(path: "videos", directoryHint: .isDirectory)
        try manager.createDirectory(at: images, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: videos, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        var copiedImages: Set<String> = []
        if manager.fileExists(atPath: sourceImages.path) {
            for input in try manager.contentsOfDirectory(at: sourceImages, includingPropertiesForKeys: nil) {
                let file = input.lastPathComponent
                guard ZipArchive.safe("media/images/" + file) else { continue }
                _ = try copyChecked(input, to: images.appending(path: file))
                copiedImages.insert(file)
            }
        }
        for row in records where ["draft", "newsletter"].contains(row.kind) {
            for key in row.kind == "draft" ? ["image", "videoThumbnail"] : row.kind == "idea" ? ["image"] : ["coverImage"] {
                if let image = row.fields[key] as? [String: Any],
                   !copiedImages.contains(image["file"] as? String ?? "") {
                    throw WorkspaceError("A source draft references an unavailable image. The source workspace is unchanged.")
                }
            }
        }

        let videoRecords = records.filter { $0.kind == "local-video" }
        let ids = Set(videoRecords.map(\.id))
        for row in records where row.kind == "draft" {
            if let video = row.fields["video"] as? [String: Any],
               !ids.contains(video["id"] as? String ?? "") {
                throw WorkspaceError("A source draft references an unavailable video.")
            }
        }
        var migratedVideos: [WorkspaceRecord] = []
        for record in videoRecords {
            var record = record
            guard record["path"].hasPrefix("/") else { throw WorkspaceError("A local video path is missing.") }
            let input = URL(fileURLWithPath: record["path"])
            let fileExtension = input.pathExtension.lowercased()
            let hash = record["hash"]
            guard ["mp4", "mov", "webm"].contains(fileExtension),
                  hash.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
                throw WorkspaceError("A source video has invalid attachment metadata.")
            }
            let file = hash + "." + fileExtension
            let target = videos.appending(path: file)
            let digest = try manager.fileExists(atPath: target.path)
                ? fileDigest(target) : copyChecked(input, to: target)
            guard digest.hash == hash, digest.size == record.fields["size"] as? Int64 else {
                throw WorkspaceError("A source video changed after it was attached.")
            }
            record["path"] = destination.appending(path: "videos").appending(path: file).path
            record.fields["mtime"] = try target.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate.map { $0.timeIntervalSince1970 * 1000 }
            migratedVideos.append(record)
        }

        try database.transaction {
            for video in migratedVideos { try database.put(video) }
            // Keep existing schedules and receipts for review. Pause automation until
            // the native app's connections and permissions have been configured.
            for key in ["mcpEnabled", "mcpAllowPosting", AgentMCP.credentialPermission,
                        "ideaQueueAutomatic", "autoPost", "dailyBackupEnabled"] {
                try database.set(key, to: false)
            }
            try database.set("analyticsAutomatic", to: [String: Bool]())
            try database.set("replyMonitoringX", to: ["enabled": false])
            let settings = try database.settings()
            if var vault = settings["obsidianVault"] as? [String: Any] {
                vault["allowAgents"] = false
                try database.set("obsidianVault", to: vault)
            }
            try database.set("workspaceMigrationAt", to: WorkspaceRecord.timestamp)
        }
        return Report(records: records.count, images: copiedImages.count, videos: videoRecords.count)
    }

    private static func copyChecked(_ source: URL, to destination: URL) throws -> (hash: String, size: Int64) {
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw WorkspaceError("The migration found a missing or unsupported attachment.")
        }
        let digest = try fileDigest(source)
        try FileManager.default.copyItem(at: source, to: destination)
        guard try fileDigest(destination) == digest else {
            throw WorkspaceError("An attachment changed during migration. Try again after editing finishes.")
        }
        return digest
    }
}
