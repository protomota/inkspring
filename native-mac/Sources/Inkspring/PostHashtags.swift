import Foundation
import NaturalLanguage

enum PostHashtags {
    private static let token = #"[\p{L}\p{M}\p{N}_]+"#
    private static let trailing = try! NSRegularExpression(pattern: "(?:\\A|\\n\\n|\\n)(#\(token)(?:[ \\t]+#\(token))*)[ \\t\\n]*\\z")

    static func separateField(on platform: String) -> Bool { ["instagram", "tiktok"].contains(platform) }

    static func automatic(on platform: String) -> Bool { separateField(on: platform) || platform == "linkedin" }

    static func split(_ text: String) -> (caption: String, hashtags: [String]) {
        guard let match = trailing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let tags = Range(match.range(at: 1), in: text) else {
            return (text, [])
        }
        return (String(text[..<whole.lowerBound]), parse(String(text[tags])))
    }

    static func parse(_ input: String) -> [String] {
        var seen = Set<String>()
        return input.split { $0.isWhitespace || $0 == "," }.compactMap { raw in
            let word = raw.hasPrefix("#") ? raw.dropFirst() : raw
            guard word.range(of: "\\A\(token)\\z", options: .regularExpression) != nil,
                  seen.insert(word.lowercased()).inserted else { return nil }
            return "#" + word
        }
    }

    static func join(_ caption: String, with hashtags: [String]) -> String {
        guard !hashtags.isEmpty else { return caption }
        let line = hashtags.joined(separator: " ")
        return caption.isEmpty ? line : caption + "\n\n" + line
    }

    static func addSuggestions(to caption: String, platform: String, format: String = "post") -> String {
        join(caption, with: suggestions(for: caption, platform: platform, format: format))
    }

    static func suggestions(for caption: String, platform: String, format: String) -> [String] {
        guard automatic(on: platform),
              caption.range(of: "(?<![\\p{L}\\p{N}/])#\(token)", options: .regularExpression) == nil else { return [] }
        let copy = String(caption.prefix(1400))
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        let words = copy.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 3 else { return [] }

        let text = " " + words.joined(separator: " ") + " "
        let topics = [
            ("FutureOfWork", ["future of work", "find work", "ways of working"]),
            ("CareerChange", ["career change", "changing careers", "job search"]),
            ("AI", ["ai", "artificial intelligence"]),
            ("IndieDev", ["indie developer", "indie dev", "build apps"]),
            ("Robotics", ["robots", "robot", "robotics"]),
            ("OpenSource", ["open source"]),
            ("SoftwareDevelopment", ["software development", "programming", "coding"]),
        ]
        var tags = topics.filter { _, terms in terms.contains { text.contains(" \($0) ") } }.map { "#" + $0.0 }
        let count = platform == "linkedin" ? 2 : 4
        if tags.count < count {
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = copy
            tagger.enumerateTags(in: copy.startIndex..<copy.endIndex, unit: .word, scheme: .lexicalClass,
                                 options: [.omitPunctuation, .omitWhitespace]) { tag, range in
                let word = copy[range]
                if tag == .noun, (4...32).contains(word.count), word.allSatisfy(\.isLetter) {
                    let candidate = "#" + word.prefix(1).uppercased() + word.dropFirst()
                    if !tags.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                        tags.append(candidate)
                    }
                }
                return tags.count < count
            }
        }
        let limit = platform == "linkedin" ? 3000 : platform == "tiktok" && format == "image" ? 4000 : 2200
        var result: [String] = []
        for tag in tags.prefix(count) {
            let next = result + [tag]
            guard join(caption, with: next).utf16.count <= limit else { break }
            result = next
        }
        return result
    }
}
