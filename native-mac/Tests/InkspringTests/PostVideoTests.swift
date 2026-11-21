import Foundation
import InkspringSchedule
import Testing
@testable import Inkspring

@Test(arguments: [SocialPlatform.x, .linkedin], [true, false])
@MainActor func scheduledVideoPostsRequireAProcessedAttachment(platform: SocialPlatform, succeeds: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    let file = root.appending(path: "fixture.mp4")
    let bytes = Data((0..<16).map(UInt8.init))
    try bytes.write(to: file)
    var media = WorkspaceRecord.new("local-video")
    media["name"] = file.lastPathComponent
    media["path"] = file.path
    media["hash"] = try fileDigest(file).hash
    media["type"] = "video/mp4"
    media.fields["size"] = bytes.count
    media.fields["duration"] = 98.3
    media = try workspace.save(media)
    let account = ManagedSocialAccount(
        session: ManagedSocialSession(accessToken: "fixture", refreshToken: nil, managedTicket: nil,
                                      expiresAt: 2_000_000_000_000, scopes: "tweet.write media.write w_member_social"),
        id: "test", name: "Fixture", username: "fixture")
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["platform"] = platform.rawValue
    draft["format"] = platform == .x ? "thread" : "post"
    draft["content"] = "Here is the video."
    if platform == .x {
        var article = WorkspaceRecord.new("article", projectID: workspace.projectID)
        article["title"] = "Fixture article"
        article["body"] = "The full story."
        article = try workspace.save(article)
        let reference = try #require(article.referenceID)
        draft["content"] = ["Here is the video.", XReplyArticle.attach(reference, to: "A follow-up.")]
            .joined(separator: XThreadText.separator)
    } else {
        draft["content"] += "\n\nhttps://newsletter.example.com/p/fixture"
    }
    draft.setDraftMedia(["id": media.id], as: .video)
    draft = try workspace.save(draft)
    let slot = PostScheduling.fiveMinutesFromNow()
    draft = try workspace.scheduleDraft(draft, at: slot, linkedInAccount: account, customTime: true)
    try workspace.set("autoPost", to: true)

    var chunks: [Data] = []
    var posts = 0
    var articleRequests = 0
    var statusChecked = false
    let videoURN = "urn:li:video:fixture"
    let owner = "urn:li:person:test"
    let transport = SocialTransport { request in
        let url = try #require(request.url)
        let method = try #require(request.httpMethod)
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var payload: [String: Any] = [:]
        var headers: [String: String] = [:]
        switch (url.path, method, url.query()) {
        case ("/2/media/upload/initialize", "POST", _):
            #expect(json?["total_bytes"] as? Int == bytes.count)
            #expect(json?["media_category"] as? String == "tweet_video")
            payload = ["data": ["id": "123"]]
        case ("/2/media/upload/123/append", "POST", _):
            #expect(json?["segment_index"] as? Int == 0)
            let encoded = try #require(json?["media"] as? String)
            chunks.append(try #require(Data(base64Encoded: encoded)))
        case ("/2/media/upload/123/finalize", "POST", _):
            #expect(chunks == [bytes])
            payload = ["data": ["id": "123", "processing_info": ["state": "pending", "check_after_secs": 1]]]
        case ("/2/media/upload", "GET", "media_id=123"):
            statusChecked = true
            payload = ["data": ["id": "123", "processing_info": ["state": succeeds ? "succeeded" : "failed"]]]
        case ("/2/articles/draft", "POST", _):
            #expect(succeeds && statusChecked)
            articleRequests += 1
            payload = ["data": ["id": "321"]]
        case ("/2/articles/321/publish", "POST", _):
            #expect(succeeds && statusChecked)
            articleRequests += 1
            payload = ["data": ["post_id": "789"]]
        case ("/rest/videos", "POST", "action=initializeUpload"):
            let initRequest = try #require(json?["initializeUploadRequest"] as? [String: Any])
            #expect(initRequest["owner"] as? String == owner)
            #expect(initRequest["fileSizeBytes"] as? Int == bytes.count)
            payload = ["value": ["video": videoURN, "uploadToken": "", "uploadInstructions": [
                ["firstByte": 0, "lastByte": 7, "uploadUrl": "https://www.linkedin.com/dms-uploads/one"],
                ["firstByte": 8, "lastByte": 31, "uploadUrl": "https://www.linkedin.com/dms-uploads/two"]
            ]]]
        case ("/dms-uploads/one", "PUT", _), ("/dms-uploads/two", "PUT", _):
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            chunks.append(try #require(request.httpBody))
            headers["ETag"] = "\"part-\(chunks.count)\""
        case ("/rest/videos", "POST", "action=finalizeUpload"):
            #expect(chunks.reduce(into: Data()) { $0.append($1) } == bytes)
            let finalize = try #require(json?["finalizeUploadRequest"] as? [String: Any])
            #expect(finalize["uploadedPartIds"] as? [String] == ["part-1", "part-2"])
        case ("/rest/videos/urn:li:video:fixture", "GET", _):
            statusChecked = true
            payload = ["id": videoURN, "owner": owner, "status": succeeds ? "AVAILABLE" : "PROCESSING_FAILED"]
        case ("/2/tweets", "POST", _):
            #expect(succeeds && statusChecked)
            if posts == 0 {
                let media = json?["media"] as? [String: [String]]
                #expect(media?["media_ids"] == ["123"])
            } else {
                #expect(json?["media"] == nil)
                #expect((json?["reply"] as? [String: String])?["in_reply_to_tweet_id"] == "456")
                #expect((json?["text"] as? String)?.hasSuffix("https://x.com/i/web/status/789") == true)
            }
            posts += 1
            payload = ["data": ["id": posts == 1 ? "456" : "457"]]
        case ("/rest/posts", "POST", _):
            #expect(succeeds && statusChecked)
            let content = json?["content"] as? [String: [String: String]]
            #expect(content?["media"]?["id"] == videoURN)
            #expect(content?["article"] == nil)
            #expect(json?["commentary"] as? String == "Here is the video.\n\nhttps://newsletter.example.com/p/fixture")
            posts += 1
            headers["x-restli-id"] = "urn:li:share:456"
        default: throw WorkspaceError("Unexpected video fixture request.")
        }
        return (try JSONSerialization.data(withJSONObject: payload),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)))
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in account })
    await workspace.runDuePosts(publisher: publisher, now: slot.addingTimeInterval(-1))
    #expect(chunks.isEmpty)
    await workspace.runDuePosts(publisher: publisher, now: slot)
    await workspace.runDuePosts(publisher: publisher, now: slot.addingTimeInterval(10))
    #expect(statusChecked)
    #expect(workspace.drafts.first { $0.id == draft.id }?.scheduleStatus == (succeeds ? "posted" : "failed"))
    let receipt = workspace.records.first { $0.kind == "publication" && $0["draftId"] == draft.id }
    if succeeds {
        #expect(posts == (platform == .x ? 2 : 1))
        #expect(articleRequests == (platform == .x ? 2 : 0))
        #expect(receipt?["status"] == "published")
        let steps = receipt?.fields["steps"] as? [[String: String]]
        #expect(steps?.first?["videoId"] == (platform == .x ? "123" : videoURN))
    } else {
        #expect(posts == 0)
        #expect(articleRequests == 0)
        #expect(receipt?["status"] == (platform == .x ? nil : "failed"))
    }
}

@Test(arguments: [true, false])
@MainActor func instagramReelWaitsForTheUploadedVideo(succeeds: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(directory: root)
    let file = root.appending(path: "reel.mp4")
    let bytes = Data("video fixture".utf8)
    try bytes.write(to: file)
    var video = WorkspaceRecord.new("local-video")
    video["name"] = file.lastPathComponent
    video["path"] = file.path
    video["hash"] = try fileDigest(file).hash
    video["type"] = "video/mp4"
    video.fields["size"] = bytes.count
    video.fields["duration"] = 98.3
    video = try workspace.save(video)
    var draft = WorkspaceRecord.new("draft", projectID: workspace.projectID)
    draft["platform"] = "instagram"
    draft["format"] = "video"
    draft["content"] = "Here is the Reel."
    draft.setDraftMedia(["id": video.id], as: .video)
    draft = try workspace.save(draft)

    let account = ManagedSocialAccount(
        session: .init(accessToken: "fixture", refreshToken: nil, managedTicket: nil, expiresAt: 2_000_000_000_000, scopes: nil),
        id: "123", name: "Fixture", username: "fixture")
    let profile = R2Profile(configuration: .init(accountId: String(repeating: "a", count: 32), bucket: "media-fixture", jurisdiction: ""),
                            accessKeyId: "TESTKEY", secretAccessKey: "SYNTHETIC")
    var uploaded = false
    var published = false
    let r2 = R2Client(profile: profile) { request, input in
        let file = try #require(input)
        let url = try #require(request.url)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(try Data(contentsOf: file) == bytes)
        uploaded = true
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
    let transport = SocialTransport { request in
        let url = try #require(request.url)
        let result: [String: Any]
        switch url.path {
        case "/v25.0/123/media":
            #expect(uploaded)
            let form = String(decoding: try #require(request.httpBody), as: UTF8.self).removingPercentEncoding
            #expect(form?.contains("media_type=REELS") == true)
            #expect(form?.contains("video_url=https://") == true)
            #expect(form?.contains("image_url=") == false)
            result = ["id": "456"]
        case "/v25.0/456":
            result = ["status_code": succeeds ? "FINISHED" : "ERROR"]
        case "/v25.0/123/media_publish":
            #expect(succeeds)
            published = true
            result = ["id": "789"]
        case "/v25.0/789":
            result = ["permalink": "https://www.instagram.com/reel/test/"]
        default:
            throw WorkspaceError("Unexpected Instagram request.")
        }
        return (try JSONSerialization.data(withJSONObject: result),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
    let publisher = SocialPublisher(workspace: workspace, transport: transport, authorize: { _ in account }, r2Client: { r2 })
    let plan = try await publisher.review(draft)
    if succeeds {
        let receipt = try await publisher.publish(plan)
        #expect(receipt["status"] == "published")
    } else {
        await #expect(throws: WorkspaceError.self) { _ = try await publisher.publish(plan) }
    }
    #expect(published == succeeds)
}
