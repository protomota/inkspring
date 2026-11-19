import Testing
@testable import Inkspring

@Test @MainActor func proofreadingKeepsFormattingAndRejectsUnmatchedEdits() async throws {
    let original = ProofreadDocument(title: "A newletter", body: """
        👋 We has a plan. [Read it](https://example.com/has) or use `we has`.
        Repeated phrase. Repeated phrase.

        ```text
        We has a template.
        ```
        """)
    let review = try await ProofreadReview.check(original, chunkSize: 500) { excerpt in
        if excerpt == original.title {
            return [.init(original: "newletter", replacement: "newsletter", reason: "Spelling")]
        }
        return [
            .init(original: "We has a plan.", replacement: "We have a plan.", reason: "Subject–verb agreement"),
            .init(original: "has a plan", replacement: "have a plan", reason: "Overlapping correction"),
            .init(original: "we has", replacement: "we have", reason: "Inline code"),
            .init(original: "We has a template.", replacement: "We have a template.", reason: "Fenced code"),
            .init(original: "https://example.com/has", replacement: "https://example.com/have", reason: "URL"),
            .init(original: "Repeated phrase.", replacement: "Repeated sentence.", reason: "Ambiguous excerpt"),
            .init(original: "Missing phrase", replacement: "No match", reason: "Unmatched excerpt"),
        ]
    }
    #expect(review.original == original)
    #expect(review.corrected.title == "A newsletter")
    #expect(review.corrected.body == original.body.replacingOccurrences(of: "We has a plan.", with: "We have a plan."))
    #expect(review.edits.count == 2)
    #expect(review.skipped == 6)
}

@Test @MainActor func proofreadingChecksTheEndOfLongTextAndPreservesSeparation() async throws {
    let beginning = String(repeating: "We work.\n\n", count: 90)
    let original = ProofreadDocument(body: beginning + "We workd today.")
    var checked = ""
    let review = try await ProofreadReview.check(original, chunkSize: 80) { excerpt in
        #expect(excerpt.count <= 80)
        checked += excerpt
        if excerpt.contains("workd") {
            return [.init(original: "workd", replacement: "worked", reason: "Spelling")]
        }
        return []
    }
    #expect(checked == original.body)
    #expect(review.corrected.body == beginning + "We worked today.")
}
