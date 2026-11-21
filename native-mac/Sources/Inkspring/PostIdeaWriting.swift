import Foundation
import FoundationModels

struct PostIdeaText: Hashable {
    let title: String
    let body: String

    init(title: String, body: String) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { title.isEmpty && body.isEmpty }

    var canSaveOnMobile: Bool {
        (1...140).contains(title.utf16.count) && (1...2000).contains(body.utf16.count)
    }
}

enum PostIdeaWriting {
    static let shapingInstructions = """
    Treat the author's working title and notes as source material. Rewrite their actual point as an editable post idea in their language and voice.
    Each idea body must stand on its own. Carry over the central claim or question, the concrete details that make it specific \
    (such as who did what and to whom), and the author's reaction or conclusion. Put those details in the body itself.
    A new angle can change the hook, emphasis, or structure while keeping the same message. Write the idea itself in the author's voice, \
    rather than telling the author to explore a broad theme or offering advice they didn't ask for.
    Clean up obvious dictation errors. Match the source's level of certainty, attribution, and point of view. \
    Every statement in the rewrite should correspond to something the author said. Omit any new cause, outcome, speculation, or reaction.
    """

    static let draftingInstructions = """
    Carry the approved idea's central message, relevant concrete details, and the author's stance into the draft itself. \
    Adapt wording and structure for the format while keeping the author's meaning and level of certainty.
    """

    @available(macOS 26, iOS 26, *)
    static func onDeviceSuggestions(for source: PostIdeaText) async throws -> [PostIdeaText] {
        let session = LanguageModelSession(instructions: """
            \(shapingInstructions)
            Write three concise rewrites of the same idea. Use a different opening in each. Stop once you've restated the author's point.
            """)
        let response = try await session.respond(to: """
            Working title:
            \(source.title)

            Author's notes:
            \(source.body)
            """, generating: OnDeviceIdeas.self, options: GenerationOptions(temperature: 0.25))
        var suggestions: [PostIdeaText] = []
        for idea in response.content.ideas {
            let suggestion = PostIdeaText(title: idea.title, body: idea.body)
            guard suggestion.canSaveOnMobile, !suggestions.contains(suggestion) else { continue }
            suggestions.append(suggestion)
            if suggestions.count == 3 { break }
        }
        return suggestions
    }
}

@available(macOS 26, iOS 26, *)
@Generable
private struct OnDeviceIdeas {
    @Guide(description: "Three rewrites of the same post idea with different openings.")
    var ideas: [Idea]

    @Generable
    struct Idea {
        @Guide(description: "Specific working title under 140 characters.")
        var title: String
        @Guide(description: "One short paragraph with the author's point, concrete details, any uncertainty, and the author's own reaction.")
        var body: String
    }
}
