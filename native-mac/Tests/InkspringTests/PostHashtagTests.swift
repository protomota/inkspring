import Testing
@testable import Inkspring

@Test func captionHashtagsPreserveCopyAndRespectPlatform() {
    let caption = "We help people find work with AI.\n\nRead more at https://example.com/story#section"
    for platform in ["instagram", "tiktok", "linkedin"] {
        let composed = PostHashtags.addSuggestions(to: caption, platform: platform)
        let separated = PostHashtags.split(composed)
        #expect(separated.caption == caption)
        #expect(separated.hashtags.starts(with: ["#FutureOfWork", "#AI"]))
        #expect(PostHashtags.addSuggestions(to: composed, platform: platform) == composed)
    }
    #expect(PostHashtags.addSuggestions(to: caption, platform: "x") == caption)
    #expect(PostHashtags.addSuggestions(to: caption, platform: "reddit") == caption)
    #expect(PostHashtags.parse("#AI, ai, #Café, career_change") == ["#AI", "#Café", "#career_change"])
    #expect(PostHashtags.join(caption, with: []) == caption)
    #expect(PostHashtags.split("I learned about #AI today.").hashtags.isEmpty)

    let longCaption = "We help people find work with AI. " + String(repeating: "X", count: 2155)
    #expect(PostHashtags.addSuggestions(to: longCaption, platform: "tiktok", format: "video").utf16.count <= 2200)
}
