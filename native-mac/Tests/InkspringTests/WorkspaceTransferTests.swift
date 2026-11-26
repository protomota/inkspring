import Foundation
import Testing
@testable import Inkspring

@Test func sqlitePreservesElectronFields() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "workspace.sqlite")
    let project = WorkspaceRecord.new("project")
    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    draft["title"] = "Test post"
    draft.fields["futureField"] = ["content": "Keep this field"]
    let database = try WorkspaceDatabase(url: url)
    try database.transaction {
        try database.put(project)
        try database.put(draft)
    }
    let reopened = try WorkspaceDatabase(url: url)
    let records = try reopened.records()
    #expect(records.first?.id == draft.id)
    #expect(records.first?.projectID == project.id)
    #expect((records.first?.fields["futureField"] as? [String: String])?["content"] == "Keep this field")
    #expect(throws: WorkspaceError.self) {
        try database.transaction {
            try database.put(WorkspaceRecord.new("idea", projectID: project.id))
            try database.put(WorkspaceRecord(kind: "newsletter", fields: draft.fields))
        }
    }
    #expect(try reopened.records().count == 2)
}

@Test func zipPreservesMediaAndResetsRestoredSchedules() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let images = directory.appending(path: "images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let filename = "8ce78386-33d1-42d6-990d-ffbb1d3b50f2.png"
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR1sAAAAASUVORK5CYII="))
    try png.write(to: images.appending(path: filename))
    var project = WorkspaceRecord.new("project")
    project["name"] = "Test project"
    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    draft["title"] = "Image post"
    draft["format"] = "image"
    draft.fields["image"] = ["file": filename, "origin": "Attached"]
    draft.fields["schedule"] = ["status": "queued", "slotAt": "2027-01-01T12:00:00.000Z"]
    draft.fields["nested"] = ["access_token": "fixture-only", "label": "Kept"]
    let videoURL = directory.appending(path: "unused.mp4")
    let videoBytes = Data("unattached video fixture".utf8)
    try videoBytes.write(to: videoURL)
    let digest = try fileDigest(videoURL)
    var video = WorkspaceRecord.new("local-video")
    video["name"] = "Unused video"
    video["path"] = videoURL.path
    video["hash"] = digest.hash
    video.fields["size"] = digest.size
    let archive = directory.appending(path: "backup.zip")
    try WorkspaceBackup.export(records: [draft, project, video],
                               preferences: ["provider": "openai", "autoPost": true, StudioTheme.preferenceKey: "graphite"],
                               directory: directory, to: archive)
    let (backup, files) = try WorkspaceBackup.stage(archive, in: directory)
    #expect(backup.preferences["provider"] as? String == "openai")
    #expect(backup.preferences["autoPost"] == nil)
    #expect(StudioTheme(preference: backup.preferences[StudioTheme.preferenceKey]) == .graphite)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: try #require(files["data.json"]))) as? [String: Any]
    #expect((manifest?["preferences"] as? [String: Any])?[StudioTheme.preferenceKey] == nil)
    let restored = backup.restored(try #require(backup.records.first { $0.id == draft.id }))
    #expect(restored.scheduleStatus == "ready")
    #expect(restored.schedule["originalSlotAt"] as? String == "2027-01-01T12:00:00.000Z")
    #expect((restored.fields["nested"] as? [String: String]) == ["label": "Kept"])
    let entry = try #require(files["media/images/" + filename])
    #expect(try Data(contentsOf: entry) == png)
    #expect(backup.records.contains { $0.id == video.id && $0.kind == "local-video" })
    let videoEntry = try #require(files["media/videos/" + video.id + ".mp4"])
    #expect(try Data(contentsOf: videoEntry) == videoBytes)
}

@Test func zipRejectsUnrecognizedEntries() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appending(path: "input")
    try Data("content".utf8).write(to: input)
    let archive = directory.appending(path: "backup.zip")
    try ZipArchive.write(to: archive, files: [("../data.json", input, 7)])
    #expect(throws: WorkspaceError.self) { try WorkspaceBackup.stage(archive, in: directory) }
}

@Test func electronZipInteroperability() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let input = environment["INKSPRING_ELECTRON_FIXTURE"],
          let output = environment["INKSPRING_SWIFT_FIXTURE"] else { return }
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (backup, files) = try WorkspaceBackup.stage(URL(fileURLWithPath: input), in: directory)
    let draft = try #require(backup.records.first { $0.kind == "draft" })
    #expect(draft.title == "Electron parity draft")
    #expect(backup.restored(draft).scheduleStatus == "ready")
    let images = directory.appending(path: "images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    for item in backup.media where item.kind == "image" {
        try FileManager.default.copyItem(at: try #require(files[item.entry]),
                                         to: images.appending(path: try #require(item.file)))
    }
    try WorkspaceBackup.export(records: backup.records.reversed(), preferences: backup.preferences,
                               directory: directory, to: URL(fileURLWithPath: output))
}

private func temporaryWorkspace() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "inkspring-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@Test func backupOnlyReportsUploadedWhenICloudConfirmsTheZIP() async throws {
    #expect(ICloudBackup.uploadStatus(inDrive: false, available: true, ubiquitous: false,
                                     uploaded: false, excluded: false, error: nil) == nil)
    #expect(ICloudBackup.uploadStatus(inDrive: true, available: true, ubiquitous: false,
                                     uploaded: true, excluded: false, error: nil) == .waiting)
    #expect(ICloudBackup.uploadStatus(inDrive: true, available: true, ubiquitous: true,
                                     uploaded: true, excluded: false, error: nil) == .uploaded)
    #expect(ICloudBackup.uploadStatus(inDrive: true, available: true, ubiquitous: true,
                                     uploaded: true, excluded: true, error: nil) == .excluded)
    #expect(ICloudBackup.uploadStatus(inDrive: true, available: true, ubiquitous: true,
                                     uploaded: false, excluded: false, error: "Quota reached") == .failed("Quota reached"))
    #expect(ICloudBackup.uploadStatus(inDrive: true, available: false, ubiquitous: false,
                                     uploaded: false, excluded: false, error: nil) == .unavailable)
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "local.zip")
    try Data("fixture".utf8).write(to: file)
    #expect(ICloudBackup.uploadStatus(of: file) == nil)
    try await ICloudBackup.downloadIfNeeded(file)
    #expect(try Data(contentsOf: file) == Data("fixture".utf8))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["INKSPRING_ICLOUD_QA_FOLDER"] != nil,
               "Requires a disposable iCloud QA folder for the live upload and restore."))
@MainActor func liveICloudBackupRoundTripsSyntheticWorkspace() async throws {
    guard let folder = ProcessInfo.processInfo.environment["INKSPRING_ICLOUD_QA_FOLDER"] else { return }
    let cloudFolder = URL(fileURLWithPath: folder, isDirectory: true)
    #expect(cloudFolder.lastPathComponent.hasPrefix("Inkspring QA Backup."))
    guard cloudFolder.lastPathComponent.hasPrefix("Inkspring QA Backup.") else {
        throw WorkspaceError("Use a disposable iCloud Drive folder for this test.")
    }
    let root = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root.appending(path: "source"))
    let source = try #require(workspace.directory)
    let filename = "8ce78386-33d1-42d6-990d-ffbb1d3b50f2.png"
    let bytes = Data("Synthetic Inkspring iCloud test attachment".utf8)
    let images = source.appending(path: "images", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try bytes.write(to: images.appending(path: filename))
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["title"] = "Synthetic iCloud backup test"
    draft["content"] = "Restore verification for a disposable workspace."
    draft["format"] = "image"
    draft.fields["image"] = ["file": filename]
    try workspace.save(draft)
    try workspace.set(DailyBackup.folderKey, to: cloudFolder.path)
    let archive = try #require(try DailyBackup.run(in: source, requested: true))
    print("Created the synthetic backup ZIP.")
    let deadline = ContinuousClock.now + .seconds(90)
    var lastError: String?
    while true {
        let file = URL(fileURLWithPath: archive.path)
        let status = ICloudBackup.uploadStatus(of: file)
        if status == .uploaded { break }
        if case let .failed(message) = status {
            if let metadata = try? file.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey]),
               let error = metadata.ubiquitousItemUploadingError {
                lastError = "\(error.domain) \(error.code): \(message)"
            } else {
                lastError = message
            }
        }
        guard ContinuousClock.now < deadline else {
            throw WorkspaceError(lastError ?? "iCloud did not confirm the synthetic ZIP upload.")
        }
        try await Task.sleep(for: .seconds(2))
    }
    print("iCloud Drive confirmed the upload.")

    try FileManager.default.evictUbiquitousItem(at: archive)
    let evicted = URL(fileURLWithPath: archive.path)
    let status = try evicted.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
    #expect(status == .notDownloaded)
    guard status == .notDownloaded else { throw WorkspaceError("The synthetic ZIP never became iCloud-only.") }
    try await ICloudBackup.downloadIfNeeded(evicted)
    print("Inkspring downloaded the iCloud-only ZIP.")

    let restored = Workspace(directory: root.appending(path: "restored"))
    let (backup, files) = try WorkspaceBackup.stage(archive, in: #require(restored.directory))
    try restored.apply(backup, files: files)
    let copy = try #require(restored.records.first { $0.id == draft.id })
    #expect(copy.body == draft.body)
    #expect(try Data(contentsOf: #require(restored.mediaURL(copy))) == bytes)
    #expect(restored.settings["autoPost"] as? Bool == false)
    print("Restored the synthetic draft and verified its attachment bytes.")
}

@Test @MainActor func workspaceFolderImportPreservesTheSourceAndPausesRestoredSchedules() throws {
    let root = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = Workspace(directory: root.appending(path: "Source"))
    let destination = Workspace(directory: root.appending(path: "Native"))
    let sourceURL = try #require(source.directory)
    let destinationURL = try #require(destination.directory)
    let images = sourceURL.appending(path: "images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let filename = "8ce78386-33d1-42d6-990d-ffbb1d3b50f2.png"
    let image = Data("synthetic imported image".utf8)
    try image.write(to: images.appending(path: filename))
    var draft = WorkspaceRecord.new("draft", projectID: source.projectID)
    draft["title"] = "Source draft"
    draft["content"] = "Import this draft and its attachment."
    draft["format"] = "image"
    draft.fields["image"] = ["file": filename]
    draft.fields["schedule"] = ["status": "queued", "slotAt": "2027-01-01T12:00:00Z"]
    try source.save(draft)
    try source.set("provider", to: "gemini")
    try source.set("mcpEnabled", to: true)
    try source.set("autoPost", to: true)
    let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: sourceURL.path))
    #expect(throws: WorkspaceError.self) { try WorkspaceMigration.prepareImport(from: sourceURL, into: sourceURL) }

    let archive = try WorkspaceMigration.prepareImport(from: sourceURL, into: destinationURL)
    let (backup, media) = try WorkspaceBackup.stage(archive, in: destinationURL)
    let plan = try backup.restorePlan(over: destination.records)
    #expect(!destination.records.contains { $0.id == draft.id })
    try destination.apply(backup, files: media, reviewedPlan: plan)
    let imported = try #require(destination.records.first { $0.id == draft.id })
    #expect(imported.body == draft.body)
    #expect(imported.scheduleStatus == "ready")
    #expect(try Data(contentsOf: #require(destination.mediaURL(imported))) == image)
    #expect(destination.settings["provider"] as? String == "gemini")
    #expect(destination.settings["mcpEnabled"] as? Bool == false)
    #expect(destination.settings["autoPost"] as? Bool == false)

    try source.reload()
    #expect(source.records.first { $0.id == draft.id }?.scheduleStatus == "queued")
    #expect(source.settings["mcpEnabled"] as? Bool == true)
    #expect(source.settings["autoPost"] as? Bool == true)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: sourceURL.path)) == filesBefore)
}

@Test @MainActor func videoAttachmentValidatesAndPreservesMediaMetadata() async throws {
    guard let fixture = ProcessInfo.processInfo.environment["INKSPRING_VIDEO_FIXTURE"] else { return }
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory.appending(path: "workspace"))
    let invalid = directory.appending(path: "broken.mp4")
    try Data("not a playable video".utf8).write(to: invalid)
    await #expect(throws: WorkspaceError.self) { _ = try await workspace.attachVideo(invalid) }
    #expect(!workspace.records.contains { $0.kind == "local-video" })

    let source = URL(fileURLWithPath: fixture)
    let media = try await workspace.attachVideo(source)
    let record = try #require(workspace.records.first { $0.kind == "local-video" })
    #expect(media["id"] as? String == record.id)
    #expect(record["type"] == "video/mp4")
    #expect(record.fields["width"] as? Int == 640)
    #expect(record.fields["height"] as? Int == 360)
    #expect(record.fields["duration"] as? Double == 1)
    let copy = URL(fileURLWithPath: record["path"])
    #expect(copy != source)
    #expect(try fileDigest(copy) == fileDigest(source))
    let attachment = try await TikTokVideo.inspect(copy)
    #expect(attachment.duration == 1)
    #expect(attachment.hash == record["hash"])
}

@Test @MainActor func draftKeepsOnePreviewAttachmentWhenPublicationFormatChanges() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    var project = WorkspaceRecord.new("project")
    project["name"] = "Preview attachments"
    project = try workspace.save(project)
    let videoURL = directory.appending(path: "preview.mp4")
    var video = WorkspaceRecord.new("local-video")
    video["name"] = "Preview"
    video["path"] = videoURL.path
    video = try workspace.save(video)
    let image = UUID().uuidString.lowercased() + ".png"
    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    draft["title"] = "Media preview"
    draft["platform"] = "reddit"
    draft.fields["video"] = ["id": video.id]
    draft.fields["image"] = ["file": image]
    #expect(throws: WorkspaceError.self) { try workspace.save(draft) }
    draft.setDraftMedia(["id": video.id], as: .video)
    draft.fields["videoThumbnail"] = ["file": image]
    draft.prepareDraftForSave()
    draft = try workspace.save(draft)

    try workspace.reload()
    let reopened = try #require(workspace.records.first { $0.id == draft.id })
    #expect(workspace.videoURL(reopened) == videoURL)
    #expect(workspace.imageURL(reopened) == nil)
    #expect(workspace.videoThumbnailURL(reopened)?.lastPathComponent == image)
    draft["format"] = "video"
    #expect(workspace.mediaURL(draft) == videoURL)
    draft.setDraftMedia(["file": image], as: .image)
    #expect(draft.fields["videoThumbnail"] == nil)
    #expect(workspace.videoURL(draft) == nil)
    #expect(workspace.imageURL(draft)?.lastPathComponent == image)
}

@Test @MainActor func importedMediaInstructionsBecomeAReaderFacingDraftTitle() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    var project = WorkspaceRecord.new("project")
    project["name"] = "Demo"
    project = try workspace.save(project)

    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    let file = "Jotley-Marketing-v12-MCP-portrait-social-1080x1920p30.mp4"
    let headline = "Your meeting notes, now readable by Claude Code and Codex."
    let attachment = ["id": "sample-video", "name": file]
    draft["title"] = "Jotley MCP video, portrait (attach \(file))"
    draft["content"] = "\(headline) Jotley transcribes on your device."
    draft.fields["video"] = attachment

    #expect(draft.title == headline)
    let saved = try workspace.save(draft)
    #expect(saved["title"] == headline)
    #expect(saved.fields["video"] as? [String: String] == attachment)

    var edited = saved
    edited["title"] = "Read your meeting notes with an agent"
    #expect(try workspace.save(edited)["title"] == edited["title"])
}

@Test @MainActor func webMVideoRemainsWebMThroughAttachmentAndRestore() async throws {
    guard let fixture = ProcessInfo.processInfo.environment["INKSPRING_WEBM_FIXTURE"] else { return }
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = URL(fileURLWithPath: fixture)
    let workspace = Workspace(directory: directory.appending(path: "workspace"))
    let truncated = directory.appending(path: "truncated.webm")
    try Data(contentsOf: source).prefix(64).write(to: truncated)
    await #expect(throws: WorkspaceError.self) { _ = try await workspace.attachVideo(truncated) }
    #expect(!workspace.records.contains { $0.kind == "local-video" })

    let media = try await workspace.attachVideo(source)
    let record = try #require(workspace.records.first { $0.id == media["id"] as? String })
    #expect(record["type"] == "video/webm")
    #expect(record.fields["width"] as? Int == 640)
    #expect(record.fields["height"] as? Int == 360)
    #expect(record.fields["duration"] as? Double == 1)
    let video = try await TikTokVideo.inspect(URL(fileURLWithPath: record["path"]))
    #expect(video.duration == 1)
    #expect(video.hash == record["hash"])
    if let highRateFixture = ProcessInfo.processInfo.environment["INKSPRING_WEBM_60FPS_FIXTURE"] {
        let highRateURL = URL(fileURLWithPath: highRateFixture)
        #expect(try await VideoMetadata.inspect(highRateURL).frameRate == 60)
        #expect(try await TikTokVideo.inspect(highRateURL).type == "video/webm")
    }
    let archive = directory.appending(path: "backup.zip")
    try workspace.exportBackup(to: archive)

    let restored = Workspace(directory: directory.appending(path: "restored"))
    let (backup, files) = try WorkspaceBackup.stage(archive, in: #require(restored.directory))
    try restored.apply(backup, files: files)
    let restoredVideo = try #require(restored.records.first { $0.id == record.id })
    let restoredURL = URL(fileURLWithPath: restoredVideo["path"])
    #expect(restoredURL.pathExtension == "webm")
    #expect(try fileDigest(restoredURL) == fileDigest(source))
}

@Test @MainActor func dailyBackupIsIdempotentAndRestoresIntoNewWorkspace() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = Workspace(directory: directory.appending(path: "source"))
    let sourceDirectory = try #require(source.directory)
    let project = try #require(source.project)
    let file = "8ce78386-33d1-42d6-990d-ffbb1d3b50f2.png"
    let image = Data("synthetic attachment bytes".utf8)
    let images = sourceDirectory.appending(path: "images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
    try image.write(to: images.appending(path: file))
    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    draft["title"] = "Daily backup fixture"
    draft["content"] = "Restore me"
    draft["format"] = "image"
    draft.fields["image"] = ["file": file, "origin": "Attached"]
    draft.fields["schedule"] = ["status": "queued", "slotAt": "2027-01-01T12:00:00Z"]
    try source.save(draft)

    let backups = directory.appending(path: "backups")
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
    try source.set(DailyBackup.folderKey, to: backups.path)
    try source.set(DailyBackup.enabledKey, to: true)
    let day = try #require(scheduleDate("2027-01-01T12:00:00Z"))
    try DailyBackup.run(in: sourceDirectory, now: day)
    try DailyBackup.run(in: sourceDirectory, now: day.addingTimeInterval(7200))
    let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let archive = try #require(files.first)
    #expect(archive.pathExtension == "zip")
    let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)

    let restored = Workspace(directory: directory.appending(path: "restored"))
    let (backup, staged) = try WorkspaceBackup.stage(archive, in: try #require(restored.directory))
    try restored.apply(backup, files: staged)
    try restored.apply(backup, files: staged)
    let result = try #require(restored.records.first { $0.id == draft.id })
    #expect(result.body == "Restore me")
    #expect(result.scheduleStatus == "ready")
    #expect(try Data(contentsOf: #require(restored.mediaURL(result))) == image)
    #expect(restored.settings[DailyBackup.enabledKey] == nil)

    try DailyBackup.run(in: sourceDirectory, now: day.addingTimeInterval(86_400))
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 2)
}

@Test @MainActor func backupRetriesAfterAnUnavailableFolderAndCanRunOnDemand() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory.appending(path: "source"))
    let source = try #require(workspace.directory)
    let destination = directory.appending(path: "backups")
    let start = try #require(scheduleDate("2027-01-01T12:00:00Z"))
    try workspace.set(DailyBackup.folderKey, to: destination.path)
    try workspace.set(DailyBackup.enabledKey, to: true)

    #expect(throws: (any Error).self) { try DailyBackup.run(in: source, now: start) }
    try workspace.reload()
    #expect(!(workspace.settings[DailyBackup.lastErrorKey] as? String ?? "").isEmpty)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    #expect(try DailyBackup.run(in: source, now: start.addingTimeInterval(600)) == nil)
    let retried = try #require(try DailyBackup.run(in: source, now: start.addingTimeInterval(7200)))
    #expect(FileManager.default.fileExists(atPath: retried.path))
    try FileManager.default.removeItem(at: retried)
    let replacement = try #require(try DailyBackup.run(in: source, now: start.addingTimeInterval(14_400)))
    #expect(FileManager.default.fileExists(atPath: replacement.path))

    try workspace.set(DailyBackup.enabledKey, to: false)
    let requested = try #require(try DailyBackup.run(in: source, now: start.addingTimeInterval(14_401), requested: true))
    #expect(requested != replacement)
    let (archive, _) = try WorkspaceBackup.stage(requested, in: source)
    #expect(archive.records.count == workspace.records.count)
    try workspace.reload()
    #expect(workspace.settings[DailyBackup.lastErrorKey] as? String == "")
    #expect(workspace.settings[DailyBackup.lastFileKey] as? String == requested.path)
    #expect(workspace.settings[DailyBackup.enabledKey] as? Bool == false)
}

@Test @MainActor func restoringAnOlderBackupKeepsPublishingHistoryAndSubstackLinks() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    let project = try #require(workspace.project)
    var draft = WorkspaceRecord.new("draft", projectID: project.id)
    draft["title"] = "Published after the backup"
    draft["content"] = "Published wording"
    draft.fields["schedule"] = ["status": "posted", "url": "https://x.com/i/web/status/123"]
    draft = try workspace.save(draft)
    var receipt = WorkspaceRecord.new("publication", projectID: project.id)
    receipt["draftId"] = draft.id
    receipt["title"] = draft.title
    receipt["status"] = "published"
    receipt.fields["steps"] = [["id": "123", "url": "https://x.com/i/web/status/123"]]
    receipt = try workspace.save(receipt)
    var newsletter = WorkspaceRecord.new("newsletter", projectID: project.id)
    newsletter["title"] = "Newsletter linked after the backup"
    newsletter["state"] = "scheduled"
    newsletter["remoteId"] = "321"
    let otherConnection = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try otherConnection.put(newsletter)

    var olderDraft = draft
    olderDraft["content"] = "Earlier wording"
    olderDraft.fields["schedule"] = ["status": "queued", "slotAt": "2027-01-01T12:00:00Z"]
    var olderReceipt = receipt
    olderReceipt["status"] = "uncertain"
    olderReceipt.fields["steps"] = []
    var olderNewsletter = newsletter
    olderNewsletter["remoteId"] = ""
    olderNewsletter["state"] = "draft"
    var ordinary = WorkspaceRecord.new("draft", projectID: project.id)
    ordinary["title"] = "Editable draft"
    ordinary["content"] = "Current text"
    ordinary = try workspace.save(ordinary)
    var olderOrdinary = ordinary
    olderOrdinary["content"] = "Restored text"
    let archive = directory.appending(path: "earlier.zip")
    try WorkspaceBackup.export(records: [project, olderDraft, olderReceipt, olderNewsletter, olderOrdinary],
                               preferences: [:], directory: directory, to: archive)
    let (backup, files) = try WorkspaceBackup.stage(archive, in: directory)
    let reviewed = try backup.restorePlan(over: workspace.records)
    #expect(reviewed.preservedIDs == [draft.id, receipt.id, newsletter.id])
    ordinary["content"] = "Changed after review"
    ordinary = try workspace.save(ordinary)
    #expect(throws: WorkspaceError.self) { try workspace.apply(backup, files: files, reviewedPlan: reviewed) }
    #expect(workspace.drafts.first { $0.id == ordinary.id }?.body == "Changed after review")
    let current = try backup.restorePlan(over: workspace.records)
    try workspace.apply(backup, files: files, reviewedPlan: current)
    #expect(workspace.drafts.first { $0.id == draft.id }?.body == "Published wording")
    #expect(workspace.drafts.first { $0.id == draft.id }?.scheduleStatus == "posted")
    #expect(workspace.records.first { $0.id == receipt.id }?["status"] == "published")
    #expect(workspace.records.first { $0.id == newsletter.id }?["state"] == "scheduled")
    #expect(workspace.records.first { $0.id == newsletter.id }?["remoteId"] == "321")
    let restored = try #require(workspace.drafts.first { $0.id == ordinary.id })
    #expect(restored.body == "Restored text")
    #expect(restored["updatedAt"] != ordinary["updatedAt"])
    try workspace.apply(backup, files: files)
    #expect(workspace.drafts.first { $0.id == ordinary.id }?["updatedAt"] == restored["updatedAt"])
    #expect(workspace.settings["autoPost"] as? Bool == false)
}

@Test @MainActor func manualBackupIncludesChangesFromAnotherWorkspaceConnection() throws {
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    let other = Workspace(directory: directory)
    var draft = WorkspaceRecord.new("draft", projectID: other.projectID)
    draft["title"] = "New draft from another connection"
    draft["content"] = "Saved just before export."
    try other.save(draft)
    #expect(!workspace.records.contains { $0.id == draft.id })
    let archive = directory.appending(path: "manual.zip")
    try workspace.exportBackup(to: archive)
    let (backup, _) = try WorkspaceBackup.stage(archive, in: directory)
    #expect(backup.records.first { $0.id == draft.id }?.body == "Saved just before export.")
}

@Test @MainActor func existingDailyBackupRestoresInAnIsolatedWorkspace() throws {
    guard let path = ProcessInfo.processInfo.environment["INKSPRING_DAILY_BACKUP_CHECK"] else { return }
    let directory = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace(directory: directory)
    let (backup, files) = try WorkspaceBackup.stage(URL(fileURLWithPath: path), in: directory)
    try workspace.apply(backup, files: files)
    let restored = Dictionary(uniqueKeysWithValues: workspace.records.map { ($0.id, $0) })
    #expect(backup.records.allSatisfy { row in restored[row.id]?.kind == row.kind && restored[row.id]?.body == row.body })
    #expect(workspace.settings["autoPost"] as? Bool == false)
    #expect(workspace.settings["mcpEnabled"] as? Bool == false)
    #expect(workspace.records.allSatisfy { !["queued", "posting", "due"].contains($0.scheduleStatus) })
    let images = directory.appending(path: "images")
    let restoredImages = FileManager.default.fileExists(atPath: images.path)
        ? try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil) : []
    let imagesByHash = try Dictionary(grouping: restoredImages) { try fileDigest($0).hash }
    for entry in backup.media {
        let name = if entry.kind == "video" {
            entry.id.flatMap { restored[$0]?["path"] }
        } else {
            imagesByHash[entry.sha256]?.first?.path
        }
        let file = URL(fileURLWithPath: try #require(name))
        #expect(try fileDigest(file) == (entry.sha256, entry.size))
    }
}
