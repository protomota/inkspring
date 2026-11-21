import Testing
@testable import Inkspring

@Test func postNowUsesThePublishedReceiptAndScheduledPostsKeepTheirTime() throws {
    var draft = WorkspaceRecord.new("draft")
    draft["platform"] = "linkedin"
    draft["content"] = "Read the manifesto."
    #expect(draft.offersPostNow)

    draft.fields["schedule"] = ["status": "posting"]
    #expect(ScheduleListing.section(for: draft) == nil)
    #expect(!draft.offersPostNow)
    #expect(PostResultNotice(draft) == nil)

    var receipt = WorkspaceRecord.new("publication")
    receipt["draftId"] = draft.id
    receipt["platform"] = "linkedin"
    receipt["status"] = "uncertain"
    #expect(PostResultNotice(receipt) == nil)
    receipt["status"] = "published"
    let published = try #require(PostResultNotice(receipt))
    #expect(published.draftID == draft.id)
    #expect(published.message == "Published on LinkedIn")

    draft.fields["schedule"] = ["status": "queued", "slotAt": "2026-11-22T20:00:00Z"]
    let scheduled = try #require(PostResultNotice(draft))
    #expect(scheduled.draftID == draft.id)
    #expect(scheduled.message == "Post scheduled")
    draft.fields["schedule"] = ["status": "posting", "slotAt": "2026-11-22T20:00:00Z"]
    #expect(ScheduleListing.section(for: draft) == .scheduled)
}
