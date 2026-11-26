import Foundation
import InkspringSchedule

/// Keep link placement independent of the writing provider's output.
enum XIdeaDraft {
    static let linkWritingInstructions = """
    For each distinct URL in ideaLinks, return a linkCallsToAction array entry with url (the exact supplied URL) and text.
    Write one short sentence that tells readers what they will find and what to do, in the author's voice. Use the brief and URL as evidence. Do not make up details about the destination.
    For an app homepage, invite people to try or download the app. For an article or guide, invite people to read it and say what they will learn if that is supported by the brief.
    Keep the text under 180 characters and exclude URLs and Markdown. Inkspring will attach each exact URL to its reply.
    """

    static func links(in text: String) -> [String] {
        matches(in: text).map(\.address)
    }

    static func separate(_ opening: String, replies: [String] = [], suppliedLinks: [String], linkCopy: [[String: String]] = [],
                         long: Bool = false) throws -> (text: String, format: String) {
        let found = matches(in: opening)
        let clean = removingLinks(from: opening, matches: found)
        guard !clean.isEmpty, !clean.contains("\0"), !clean.contains(XThreadText.separator) else {
            throw WorkspaceError("The generated X opening needs some text. Try again with a little more detail.")
        }

        var writtenReplies: [String] = []
        var bareReplyLinks: [String] = []
        for reply in replies {
            let found = matches(in: reply)
            let copy = removingLinks(from: reply, matches: found)
            let label = copy.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            if !found.isEmpty, label.isEmpty || ["link", "links", "source", "sources", "url", "urls"].contains(label) {
                bareReplyLinks += found.map(\.address)
            } else {
                writtenReplies.append(reply)
            }
        }

        var seen = Set(writtenReplies.flatMap { links(in: $0) })
        let missing = (suppliedLinks + found.map(\.address) + bareReplyLinks).filter { seen.insert($0).inserted }
        var actions: [String: String] = [:]
        for entry in linkCopy {
            guard let url = entry["url"], let text = entry["text"], actions[url] == nil else { continue }
            let copy = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard copy.contains(where: \.isLetter), !copy.contains("\0"), !copy.contains("<!--"), links(in: copy).isEmpty,
                  XThreadText.weight(copy + "\n" + url) <= 280 else { continue }
            actions[url] = copy
        }
        var linkReplies: [String] = []
        var previousAction: String?
        for address in missing {
            let action = actions[address] ?? fallbackAction(for: address)
            let section = action + "\n" + address
            let addition = previousAction == action ? "\n" + address : "\n\n" + section
            if let last = linkReplies.last, XThreadText.weight(last + addition) <= 280 {
                linkReplies[linkReplies.count - 1] = last + addition
            } else {
                linkReplies.append(section)
            }
            previousAction = action
        }
        let posts = [clean] + writtenReplies + linkReplies
        let format = posts.count == 1 ? "post" : posts.count == 2 ? "followup" : "thread"
        let body = posts.joined(separator: XThreadText.separator)
        let openingLimit = long ? 25_000 : 280
        let valid = format == "post" ? XThreadText.weight(clean) <= openingLimit
            : XThreadText.valid(body, format: format, openingLimit: openingLimit)
        guard valid, body.utf16.count <= 40_000 else {
            throw WorkspaceError("The generated X post or its replies exceed X’s limits. Try again with a shorter idea or fewer links.")
        }
        return (body, format)
    }

    private static func fallbackAction(for address: String) -> String {
        let url = URLComponents(string: address)
        if ["inkspring.ai", "www.inkspring.ai"].contains(url?.host?.lowercased() ?? ""),
           ["", "/", "/download", "/download/"].contains(url?.path ?? "") {
            return "Download Inkspring for Mac and try it for yourself."
        }
        return "Find more information here:"
    }

    private static func removingLinks(from text: String, matches: [(range: NSRange, address: String)]) -> String {
        guard !matches.isEmpty else { return text }
        let copy = NSMutableString(string: text)
        for match in matches.reversed() { copy.deleteCharacters(in: match.range) }
        return (copy as String)
            .replacingOccurrences(of: #"\[([^\[\]\n]*)\]\(\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\(\)|<>|\[\]|``"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+(?=\n|$)|(?<=\n)[ \t]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(in text: String) -> [(range: NSRange, address: String)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let bounds = Range(match.range, in: text) else { return nil }
            var literal = text[bounds]
            if url.scheme == "mailto", !literal.lowercased().hasPrefix("mailto:") { return nil }
            // The detector includes the closing delimiter of some parenthesized links.
            var extraParentheses = literal.reduce(0) { balance, character in
                balance + (character == ")" ? 1 : character == "(" ? -1 : 0)
            }
            while literal.last == ")", extraParentheses > 0 {
                literal = literal.dropLast()
                extraParentheses -= 1
            }
            let explicitScheme = url.scheme.map { literal.lowercased().hasPrefix($0.lowercased() + ":") } ?? false
            let address = explicitScheme ? String(literal) : "https://" + String(literal)
            return (NSRange(literal.startIndex..<literal.endIndex, in: text), address)
        }
    }
}
