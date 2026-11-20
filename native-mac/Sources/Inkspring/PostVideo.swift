import CryptoKit
import Foundation

extension WorkspaceRecord {
    var needsNativePostVideo: Bool {
        ["x", "linkedin", "instagram"].contains(self["platform"]) && (fields["video"] != nil || self["format"] == "video")
    }
}

struct PostVideo: Equatable {
    let url: URL
    let name: String
    let size: Int64
    let hash: String

    static func forDraft(_ draft: WorkspaceRecord, in records: [WorkspaceRecord]) throws -> Self? {
        guard draft.needsNativePostVideo else { return nil }
        let attachment = draft.fields["video"] as? [String: Any]
        guard let id = attachment?["id"] as? String,
              let file = records.first(where: { $0.kind == "local-video" && $0.id == id }),
              !file["path"].isEmpty else {
            throw WorkspaceError("Attach the video file before scheduling or publishing this post.")
        }
        let url = URL(fileURLWithPath: file["path"])
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard let size = file.fields["size"] as? Int, size > 0, values?.fileSize == size,
              values?.isRegularFile == true, values?.isSymbolicLink != true,
              file["hash"].range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
            throw WorkspaceError("The attached video is missing or has changed. Attach it again before publishing.")
        }
        guard file["type"] == "video/mp4", url.pathExtension.lowercased() == "mp4" else {
            throw WorkspaceError("Attach an H.264 MP4.")
        }
        if draft["platform"] == "x" {
            guard let duration = file.fields["duration"] as? Double, duration <= 140, size <= 512_000_000 else {
                throw WorkspaceError("Choose an X video up to 2 minutes 20 seconds and 512 MB.")
            }
        }
        if draft["platform"] == "instagram" {
            guard let duration = file.fields["duration"] as? Double, (3...600).contains(duration), size <= 1_000_000_000 else {
                throw WorkspaceError("Choose an Instagram Reel from 3 seconds to 10 minutes and up to 1 GB.")
            }
        }
        return Self(url: url, name: file["name"], size: Int64(size), hash: file["hash"])
    }
}

@MainActor
struct PostVideoUpload {
    let transport: SocialTransport

    func toX(_ video: PostVideo, token: String) async throws -> String {
        let base = URL(string: "https://api.x.com/2/media/upload")!
        let (value, _) = try await transport.request(base.appending(path: "initialize"), token: token, method: "POST",
            json: ["total_bytes": video.size, "media_type": "video/mp4", "media_category": "tweet_video"])
        guard let id = (value["data"] as? [String: Any])?["id"] as? String,
              id.range(of: #"\A[0-9]{1,19}\z"#, options: .regularExpression) != nil else {
            throw WorkspaceError("X didn’t confirm a video upload ID.")
        }
        let reader = try VideoReader(video)
        let upload = base.appending(path: id)
        let chunkSize: Int64 = 4 * 1024 * 1024
        for (index, offset) in stride(from: 0, to: video.size, by: Int(chunkSize)).enumerated() {
            try Task.checkCancellation()
            let bytes = try reader.read(Int(min(chunkSize, video.size - offset)))
            let (acknowledgment, _) = try await transport.request(upload.appending(path: "append"), token: token, method: "POST",
                json: ["segment_index": index, "media": bytes.base64EncodedString()], timeout: 120)
            guard (acknowledgment["errors"] as? [Any])?.isEmpty != false else {
                throw WorkspaceError("X rejected part of the video upload.")
            }
        }
        try reader.verify()
        let (finalized, _) = try await transport.request(upload.appending(path: "finalize"), token: token, method: "POST")
        let statusURL = base.appending(queryItems: [URLQueryItem(name: "media_id", value: id)])
        var data = finalized["data"] as? [String: Any]
        let deadline = Date.now.addingTimeInterval(240)
        repeat {
            guard data?["id"] as? String == id else { throw WorkspaceError("X couldn’t confirm the uploaded video.") }
            let processing = data?["processing_info"] as? [String: Any]
            switch processing?["state"] as? String {
            case "succeeded": return id
            case "failed": throw WorkspaceError("X rejected the video during processing.")
            case nil where (data?["video"] as? [String: Any])?["video_type"] as? String == "video/mp4": return id
            default: break
            }
            let delay = min(60, max(1, processing?["check_after_secs"] as? Int ?? 2))
            try await Task.sleep(for: .seconds(delay))
            let (status, _) = try await transport.request(statusURL, token: token)
            data = status["data"] as? [String: Any]
        } while Date.now < deadline
        throw WorkspaceError("X is still processing the video. Review the post and try again.")
    }

    func toLinkedIn(_ video: PostVideo, owner: String, token: String) async throws -> String {
        let base = URL(string: "https://api.linkedin.com/rest/videos")!
        let headers = LinkedInPages.headers
        let initialize = base.appending(queryItems: [URLQueryItem(name: "action", value: "initializeUpload")])
        let (document, _) = try await transport.request(initialize, token: token, method: "POST",
            json: ["initializeUploadRequest": ["owner": owner, "fileSizeBytes": video.size,
                                               "uploadCaptions": false, "uploadThumbnail": false]], headers: headers)
        guard let value = document["value"] as? [String: Any], let urn = value["video"] as? String,
              urn.range(of: #"\Aurn:li:video:[A-Za-z0-9_-]{1,200}\z"#, options: .regularExpression) != nil,
              let uploadToken = value["uploadToken"] as? String,
              let instructions = value["uploadInstructions"] as? [[String: Any]], !instructions.isEmpty else {
            throw WorkspaceError("LinkedIn didn’t confirm the video upload instructions.")
        }
        let reader = try VideoReader(video)
        var offset: Int64 = 0
        var parts: [String] = []
        for instruction in instructions {
            try Task.checkCancellation()
            guard let first = instruction["firstByte"] as? Int64, first == offset, first < video.size,
                  let last = instruction["lastByte"] as? Int64, last >= first, last - first < 8 * 1024 * 1024,
                  let address = instruction["uploadUrl"] as? String, let url = URL(string: address),
                  url.host == "www.linkedin.com", url.port == nil, url.path.hasPrefix("/dms-uploads/") else {
                throw WorkspaceError("LinkedIn returned invalid video upload instructions.")
            }
            let end = min(last, video.size - 1)
            let bytes = try reader.read(Int(end - first + 1))
            let (_, response) = try await transport.request(url, method: "PUT", body: bytes,
                headers: ["Content-Type": "application/octet-stream"], expectsJSON: false, timeout: 120)
            guard let tag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                  !tag.isEmpty else {
                throw WorkspaceError("LinkedIn couldn’t confirm a video upload part.")
            }
            parts.append(tag)
            offset = end + 1
        }
        try reader.verify()
        let finalize = base.appending(queryItems: [URLQueryItem(name: "action", value: "finalizeUpload")])
        _ = try await transport.request(finalize, token: token, method: "POST",
            json: ["finalizeUploadRequest": ["video": urn, "uploadToken": uploadToken, "uploadedPartIds": parts]], headers: headers)
        let encoded = urn.replacingOccurrences(of: ":", with: "%3A")
        let statusURL = URL(string: base.absoluteString + "/" + encoded)!
        let deadline = Date.now.addingTimeInterval(240)
        repeat {
            let (status, _) = try await transport.request(statusURL, token: token, headers: headers)
            guard status["id"] as? String == urn, status["owner"] as? String == owner else {
                throw WorkspaceError("LinkedIn couldn’t confirm the uploaded video and its owner.")
            }
            switch status["status"] as? String {
            case "AVAILABLE": return urn
            case "PROCESSING_FAILED": throw WorkspaceError("LinkedIn rejected the video during processing.")
            case "PROCESSING", "WAITING_UPLOAD": try await Task.sleep(for: .seconds(3))
            default: throw WorkspaceError("LinkedIn returned an unknown video status.")
            }
        } while Date.now < deadline
        throw WorkspaceError("LinkedIn is still processing the video. Review the post and try again.")
    }
}

private final class VideoReader {
    private let video: PostVideo
    private let handle: FileHandle
    private var digest = SHA256()
    private var size: Int64 = 0

    init(_ video: PostVideo) throws {
        self.video = video
        handle = try FileHandle(forReadingFrom: video.url)
    }

    deinit { try? handle.close() }

    func read(_ count: Int) throws -> Data {
        guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
            throw WorkspaceError("The video changed during upload. Attach it again before publishing.")
        }
        size += Int64(bytes.count)
        digest.update(data: bytes)
        return bytes
    }

    func verify() throws {
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == video.size, hash == video.hash, try handle.read(upToCount: 1)?.isEmpty != false else {
            throw WorkspaceError("The video changed during upload. Attach it again before publishing.")
        }
    }
}
