import Foundation

enum ICloudBackup {
    enum UploadStatus: Equatable, Sendable {
        case waiting, uploaded, unavailable, excluded, failed(String)
    }

    static var drive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    static func uploadStatus(of url: URL) -> UploadStatus? {
        let root = drive.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let metadata = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                                          .ubiquitousItemIsExcludedFromSyncKey, .ubiquitousItemUploadingErrorKey])
        return uploadStatus(inDrive: path.starts(with: root), available: metadata != nil,
                            ubiquitous: metadata?.isUbiquitousItem == true,
                            uploaded: metadata?.ubiquitousItemIsUploaded == true,
                            excluded: metadata?.ubiquitousItemIsExcludedFromSync == true,
                            error: metadata?.ubiquitousItemUploadingError?.localizedDescription)
    }

    static func uploadStatus(inDrive: Bool, available: Bool, ubiquitous: Bool, uploaded: Bool,
                             excluded: Bool, error: String?) -> UploadStatus? {
        guard inDrive || ubiquitous else { return nil }
        guard available else { return .unavailable }
        if excluded { return .excluded }
        if let error { return .failed(error) }
        return ubiquitous && uploaded ? .uploaded : .waiting
    }

    static func downloadIfNeeded(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey]
        guard (try? url.resourceValues(forKeys: keys).ubiquitousItemDownloadingStatus) == .notDownloaded else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let freshURL = URL(fileURLWithPath: url.path)
            let status = try freshURL.resourceValues(forKeys: keys)
            if let error = status.ubiquitousItemDownloadingError { throw error }
            if status.ubiquitousItemDownloadingStatus == .current { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw WorkspaceError("iCloud hasn’t finished downloading this backup. Check its status in Finder and try again.")
    }
}
