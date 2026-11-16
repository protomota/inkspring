import AVFoundation
import CryptoKit
import Foundation

func fileDigest(_ url: URL, limit: Int64 = 4 * 1024 * 1024 * 1024) throws -> (hash: String, size: Int64) {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var digest = SHA256()
    var size: Int64 = 0
    while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        size += Int64(chunk.count)
        guard size <= limit else { throw WorkspaceError("This file exceeds the allowed size.") }
        digest.update(data: chunk)
    }
    return (digest.finalize().map { String(format: "%02x", $0) }.joined(), size)
}

struct VideoMetadata: Sendable {
    static let types = ["mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"]
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Float

    static func inspect(_ url: URL) async throws -> Self {
        if url.pathExtension.lowercased() == "webm" {
            return try await Task.detached(priority: .utility) { try WebMMetadata.inspect(url) }.value
        }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, (0...600).contains(duration), duration > 0,
                  let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw WorkspaceError("Choose a playable video of up to ten minutes.")
            }
            let (dimensions, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let size = CGRect(origin: .zero, size: dimensions).applying(transform).size
            guard [size.width, size.height].allSatisfy({ (360...4096).contains($0) }) else {
                throw WorkspaceError("Video width and height must each be between 360 and 4,096 pixels.")
            }
            return Self(duration: duration, width: Int(size.width.rounded()), height: Int(size.height.rounded()), frameRate: fps)
        } catch let error as WorkspaceError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw WorkspaceError("This video couldn’t be opened. Try an H.264 MP4 or MOV file.")
        }
    }
}

extension Workspace {
    func attachVideo(_ source: URL) async throws -> [String: Any] {
        guard let directory else { throw WorkspaceError("The workspace is unavailable.") }
        let fileExtension = source.pathExtension.lowercased()
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard let type = VideoMetadata.types[fileExtension],
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, (1...4 * 1024 * 1024 * 1024).contains(size) else {
            throw WorkspaceError("Choose a local MP4, MOV, or WebM video up to 4 GB.")
        }
        let metadata = try await VideoMetadata.inspect(source)
        try Task.checkCancellation()
        let videos = directory.appending(path: "videos", directoryHint: .isDirectory)
        let originalModification = attributes.contentModificationDate
        let (target, hash) = try await Task.detached(priority: .utility) {
            try storeVideo(source, in: videos, expectedSize: size, modification: originalModification)
        }.value
        try Task.checkCancellation()
        var record = WorkspaceRecord.new("local-video")
        record["name"] = source.lastPathComponent
        record["path"] = target.path
        record["hash"] = hash
        record["type"] = type
        record.fields["size"] = size
        record.fields["duration"] = metadata.duration
        record.fields["width"] = metadata.width
        record.fields["height"] = metadata.height
        record.fields["mtime"] = try target.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate.map { $0.timeIntervalSince1970 * 1000 }
        try save(record)
        return ["id": record.id, "name": record["name"], "size": size, "duration": metadata.duration,
                "width": metadata.width, "height": metadata.height]
    }
}

private func storeVideo(_ source: URL, in directory: URL, expectedSize: Int, modification: Date?) throws -> (URL, String) {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let media = try fileDigest(source)
    let target = directory.appending(path: media.hash + "." + source.pathExtension.lowercased())
    let current = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard media.size == expectedSize, current.fileSize == expectedSize, current.contentModificationDate == modification else {
        throw WorkspaceError("The video changed while it was being attached.")
    }
    if manager.fileExists(atPath: target.path) {
        guard try fileDigest(target) == media else { throw WorkspaceError("An attached video file has changed.") }
    } else {
        let temporary = directory.appending(path: ".attach-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        guard try fileDigest(temporary) == media else { throw WorkspaceError("The video changed while it was being attached.") }
        do {
            try manager.linkItem(at: temporary, to: target)
        } catch CocoaError.fileWriteFileExists {
            guard try fileDigest(target) == media else { throw WorkspaceError("An attached video file has changed.") }
        }
    }
    return (target, media.hash)
}
