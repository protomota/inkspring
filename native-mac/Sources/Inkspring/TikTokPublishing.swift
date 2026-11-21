import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TikTokCreator {
    static let privacyLabels = [
        "PUBLIC_TO_EVERYONE": "Everyone", "MUTUAL_FOLLOW_FRIENDS": "Friends",
        "FOLLOWER_OF_CREATOR": "Followers", "SELF_ONLY": "Only me"
    ]

    let username: String
    let name: String
    let privacy: [String]
    let commentDisabled: Bool
    let duetDisabled: Bool
    let stitchDisabled: Bool
    let maxDuration: Double
    let usesManagedMedia: Bool
}

struct TikTokReviewOptions: Codable {
    var privacy = ""
    var title = ""
    var caption = ""
    var comment = false
    var duet = false
    var stitch = false
    var aiGenerated = false
    var yourBrand = false
    var branded = false
    var consent = false
    var coverTimestampMS: Int?

    var fingerprintFields: [String] {
        var fields = [privacy, title, caption] + [comment, duet, stitch, aiGenerated, yourBrand, branded, consent].map { String($0) }
        if let coverTimestampMS { fields.append(String(coverTimestampMS)) }
        return fields
    }

    func validate(creator: TikTokCreator, video: TikTokVideo?) throws {
        guard consent, creator.privacy.contains(privacy), !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              caption.utf16.count <= (video == nil ? 4000 : 2200), video != nil || title.utf16.count <= 90,
              !branded || privacy != "SELF_ONLY",
              !comment || !creator.commentDisabled,
              video == nil || (!duet || !creator.duetDisabled) && (!stitch || !creator.stitchDisabled) else {
            throw WorkspaceError("Check the caption, privacy, interaction settings and consent before publishing to TikTok.")
        }
        if let video, creator.maxDuration <= 0 || video.duration > creator.maxDuration {
            throw WorkspaceError("This video exceeds the duration limit for the connected TikTok account.")
        }
        if let coverTimestampMS, video.map({ coverTimestampMS >= 0 && Double(coverTimestampMS) / 1000 < $0.duration }) != true {
            throw WorkspaceError("Choose a cover frame within the attached TikTok video.")
        }
    }
}

struct TikTokVideo: Sendable {
    let size: Int64
    let hash: String
    let duration: Double
    let type: String
    let modified: Date?

    static func coverTimestamp(for draft: WorkspaceRecord) throws -> Int? {
        let raw = draft["tiktokCoverTime"].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let time = Double(raw), let duration = (draft.fields["video"] as? [String: Any])?["duration"] as? Double,
              time.isFinite, time >= 0, time < duration, time <= 600 else {
            throw WorkspaceError("Enter a cover frame in seconds within the attached TikTok video.")
        }
        return Int((time * 1000).rounded())
    }

    static func inspect(_ url: URL) async throws -> Self {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard let type = VideoMetadata.types[url.pathExtension.lowercased()],
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, (1...4 * 1024 * 1024 * 1024).contains(size) else {
            throw WorkspaceError("Choose an MP4, MOV, or WebM video up to 4 GB.")
        }
        let metadata = try await VideoMetadata.inspect(url)
        guard (23...60).contains(metadata.frameRate) else {
            throw WorkspaceError("TikTok requires 23–60 frames per second.")
        }
        let digest = try await Task.detached(priority: .utility) { try fileDigest(url) }.value
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard digest.size == size, after.fileSize == size,
              after.contentModificationDate == attributes.contentModificationDate else {
            throw WorkspaceError("The video changed. Attach it again.")
        }
        return Self(size: digest.size, hash: digest.hash, duration: metadata.duration, type: type,
                    modified: after.contentModificationDate)
    }

    var ranges: [Range<Int64>] {
        let step = min(size, 32 * 1024 * 1024)
        let count = Int(size / step)
        return (0..<count).map { index in
            let start = Int64(index) * step
            return start..<(index == count - 1 ? size : start + step)
        }
    }
}

extension SocialPublisher {
    func tikTokCreator() async throws -> TikTokCreator {
        try await tikTokCreator(account: authorize(.tiktok))
    }

    func tikTokCreator(account: ManagedSocialAccount) async throws -> TikTokCreator {
        let data = try await tikTokAPI("creator_info/query/", account: account, fields: [:])
        let privacy = (data["privacy_level_options"] as? [String] ?? []).filter { TikTokCreator.privacyLabels[$0] != nil }
        guard !privacy.isEmpty else { throw WorkspaceError("TikTok did not return publishing options for this account.") }
        return TikTokCreator(username: data["creator_username"] as? String ?? account.username,
                             name: data["creator_nickname"] as? String ?? account.name,
                             privacy: privacy, commentDisabled: data["comment_disabled"] as? Bool == true,
                             duetDisabled: data["duet_disabled"] as? Bool == true, stitchDisabled: data["stitch_disabled"] as? Bool == true,
                             maxDuration: data["max_video_post_duration_sec"] as? Double ?? 0, usesManagedMedia: account.ownApp != true)
    }

    func tiktok(_ plan: SocialPublishPlan, account: ManagedSocialAccount,
                receipt: inout WorkspaceRecord) async throws -> [String: String] {
        guard let review = plan.tiktok, let creator = plan.creator else { throw WorkspaceError("Review the TikTok post first.") }
        try review.validate(creator: creator, video: plan.video)
        var hosted: (url: URL, key: String)?
        var settled = true
        do {
            if receipt["containerId"].isEmpty {
                var info: [String: Any] = [
                    "title": plan.video == nil ? review.title : review.caption, "privacy_level": review.privacy,
                    "disable_comment": !review.comment, "brand_content_toggle": review.branded,
                    "brand_organic_toggle": review.yourBrand
                ]
                if let video = plan.video, let file = plan.image {
                    info["disable_duet"] = !review.duet
                    info["disable_stitch"] = !review.stitch
                    info["is_aigc"] = review.aiGenerated
                    if let cover = review.coverTimestampMS { info["video_cover_timestamp_ms"] = cover }
                    let chunks = video.ranges
                    let opened = try FileHandle(forReadingFrom: file)
                    defer { try? opened.close() }
                    let values: [String: Any] = [
                        "post_info": info, "source_info": ["source": "FILE_UPLOAD", "video_size": video.size,
                                                         "chunk_size": chunks[0].count, "total_chunk_count": chunks.count]
                    ]
                    let result = try await tikTokAPI("video/init/", account: account, fields: values, publishes: true)
                    let id = try tikTokPublishID(result)
                    receipt["containerId"] = id
                    receipt.fields["containers"] = [id]
                    try workspace.updatePublication(receipt)
                    guard let raw = result["upload_url"] as? String, let url = URL(string: raw), url.scheme == "https",
                          url.host?.hasSuffix(".tiktokapis.com") == true, url.user == nil, url.password == nil, url.port == nil else {
                        throw SocialRequestError("TikTok returned an unexpected upload address. Check Publishing history.", uncertain: true)
                    }
                    settled = false
                    for chunk in chunks {
                        let current = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        guard current.fileSize == Int(video.size), current.contentModificationDate == video.modified,
                              let bytes = try opened.read(upToCount: chunk.count), bytes.count == chunk.count else {
                            throw SocialRequestError("The video changed during upload. Check TikTok before retrying.", uncertain: true)
                        }
                        let (_, response) = try await transport.request(url, method: "PUT", body: bytes, headers: [
                            "Content-Type": video.type, "Content-Length": String(bytes.count),
                            "Content-Range": "bytes \(chunk.lowerBound)-\(chunk.upperBound - 1)/\(video.size)"
                        ], publishes: true, expectsJSON: false, timeout: 300)
                        guard response.statusCode == (chunk.upperBound == video.size ? 201 : 206) else {
                            throw SocialRequestError("TikTok didn’t confirm the video upload. Check Publishing history.", uncertain: true)
                        }
                        receipt.fields["uploadProgress"] = Int(chunk.upperBound * 100 / video.size)
                        try workspace.updatePublication(receipt)
                    }
                } else {
                    var photoURL = plan.publicImage
                    if let file = plan.image, creator.usesManagedMedia {
                        hosted = try await hostTikTokPhoto(file, expectedHash: plan.imageHash, token: account.session.accessToken)
                        photoURL = hosted?.url
                    }
                    guard let photoURL else { throw WorkspaceError("Choose a photo or enter its verified public URL.") }
                    info["description"] = review.caption
                    info["auto_add_music"] = true
                    // Once init is sent, the temporary URL may still be in use even
                    // when the platform has not returned a publish ID.
                    settled = false
                    let data = try await tikTokAPI("content/init/", account: account, fields: [
                        "media_type": "PHOTO", "post_mode": "DIRECT_POST", "post_info": info,
                        "source_info": ["source": "PULL_FROM_URL", "photo_images": [photoURL.absoluteString], "photo_cover_index": 0]
                    ], publishes: true)
                    let id = try tikTokPublishID(data)
                    receipt["containerId"] = id
                    receipt.fields["containers"] = [id]
                    try workspace.updatePublication(receipt)
                }
            }
            let id = receipt["containerId"]
            for attempt in 0..<40 {
                let data = try await tikTokAPI("status/fetch/", account: account, fields: ["publish_id": id])
                switch data["status"] as? String {
                case "PUBLISH_COMPLETE":
                    settled = true
                    if let hosted { await removeHostedPhoto(hosted) }
                    let ids = data["publicaly_available_post_id"] as? [Any] ?? data["publicly_available_post_id"] as? [Any] ?? []
                    let postID = ids.first as? String ?? (ids.first as? NSNumber)?.stringValue ?? ""
                    let username = creator.username.range(of: #"\A[A-Za-z0-9_.]{1,100}\z"#, options: .regularExpression) != nil
                    let numeric = postID.range(of: #"\A[0-9]{1,25}\z"#, options: .regularExpression) != nil
                    let kind = plan.video == nil ? "photo" : "video"
                    let link = username && numeric ? "https://www.tiktok.com/@\(creator.username)/\(kind)/\(postID)" : ""
                    return ["id": id, "url": link, "at": WorkspaceRecord.timestamp]
                case "FAILED":
                    settled = true
                    receipt["containerId"] = ""
                    receipt.fields["containers"] = [String]()
                    throw WorkspaceError("TikTok couldn’t publish this post. Review the media and posting settings.")
                default:
                    if attempt < 39 { try await Task.sleep(for: .seconds(3)) }
                }
            }
            throw WorkspaceError("TikTok is still processing the post. Review it again later to check the same attempt.")
        } catch {
            if let hosted, settled { await removeHostedPhoto(hosted) }
            throw error
        }
    }

    private func tikTokAPI(_ path: String, account: ManagedSocialAccount, fields: [String: Any],
                           publishes: Bool = false) async throws -> [String: Any] {
        let url = URL(string: "https://open.tiktokapis.com/v2/post/publish/" + path)!
        let result: [String: Any]
        do {
            (result, _) = try await transport.request(url, token: account.session.accessToken, method: "POST",
                                                       json: fields, headers: ["Content-Type": "application/json; charset=UTF-8"],
                                                       publishes: publishes)
        } catch let error as SocialRequestError {
            guard let code = error.providerCode, code != "ok" else { throw error }
            throw SocialRequestError(tikTokFailureMessage(code), uncertain: error.uncertain, statusCode: error.statusCode,
                                     providerCode: code)
        }
        if let error = result["error"] as? [String: Any], let code = error["code"] as? String, code != "ok" {
            throw SocialRequestError(tikTokFailureMessage(code), providerCode: code)
        }
        guard let data = result["data"] as? [String: Any] else {
            throw SocialRequestError("TikTok did not confirm the request.", uncertain: publishes)
        }
        return data
    }

    private func tikTokFailureMessage(_ code: String) -> String {
        switch code {
        case "unaudited_client_can_only_post_to_private_accounts":
            "TikTok requires a Direct Post audit for this developer app before it can publish publicly."
        case "access_token_invalid", "scope_not_authorized":
            "Reconnect TikTok in Connections and allow video publishing."
        case "privacy_level_option_mismatch":
            "TikTok no longer offers the chosen audience. Open the review and choose an available audience."
        case "spam_risk_too_many_posts":
            "TikTok reports that this account reached its daily posting limit."
        case "spam_risk_user_banned_from_posting":
            "TikTok reports that this account is restricted from publishing."
        case "reached_active_user_cap":
            "TikTok reports that this developer app reached its daily limit for creators."
        case "rate_limit_exceeded":
            "TikTok reached its request limit. Wait before retrying."
        case "url_ownership_unverified":
            "TikTok requires this developer app to verify the media hosting domain."
        default:
            "TikTok declined the request. Check account permissions and posting options."
        }
    }

    private func tikTokPublishID(_ data: [String: Any]) throws -> String {
        guard let id = data["publish_id"] as? String, (1...64).contains(id.utf8.count) else {
            throw SocialRequestError("TikTok did not return a publish ID. Check the account.", uncertain: true)
        }
        return id
    }

    private func hostTikTokPhoto(_ url: URL, expectedHash: String?, token: String) async throws -> (url: URL, key: String) {
        let input = try Data(contentsOf: url)
        guard (1...20_000_000).contains(input.count),
              SHA256.hash(data: input).map({ String(format: "%02x", $0) }).joined() == expectedHash,
              let source = CGImageSourceCreateWithData(input as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1080
              ] as CFDictionary) else { throw WorkspaceError("Choose a photo Inkspring can read.") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw WorkspaceError("Couldn’t prepare the TikTok photo.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.87] as CFDictionary)
        guard CGImageDestinationFinalize(destination), (100...4_000_000).contains(bytes.length) else {
            throw WorkspaceError("Choose a smaller TikTok photo.")
        }
        let (result, _) = try await transport.request(URL(string: "https://inkspring.ai/api/desktop/media")!,
                                                       token: token, method: "POST", body: bytes as Data,
                                                       headers: ["Content-Type": "image/jpeg"])
        guard let raw = result["url"] as? String, let hosted = URL(string: raw), hosted.scheme == "https",
              hosted.host == "inkspring.ai", hosted.user == nil, hosted.password == nil, hosted.port == nil,
              hosted.path.hasPrefix("/tiktok-media/"), let key = result["deleteKey"] as? String, (1...200).contains(key.utf8.count) else {
            throw WorkspaceError("The TikTok photo host returned an unexpected address.")
        }
        return (hosted, key)
    }

    private func removeHostedPhoto(_ hosted: (url: URL, key: String)) async {
        _ = try? await transport.request(URL(string: "https://inkspring.ai/api/desktop/media/delete")!,
                                         method: "POST", json: ["url": hosted.url.absoluteString, "deleteKey": hosted.key])
    }
}
