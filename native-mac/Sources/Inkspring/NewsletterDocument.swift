import CCMark
import Foundation

@MainActor
enum NewsletterDocument {
    private static let registered: Void = { cmark_gfm_core_extensions_ensure_registered() }()

    static func localCopy(of newsletter: WorkspaceRecord) -> WorkspaceRecord {
        var draft = WorkspaceRecord.new("newsletter", projectID: newsletter.projectID)
        let suffix = " (copy)"
        var remaining = 300 - suffix.utf16.count
        let title = newsletter.title.prefix { character in
            remaining -= String(character).utf16.count
            return remaining >= 0
        }
        draft["title"] = String(title) + suffix
        for key in ["subtitle", "body", "audience", "sendEmail", "coverImage"] {
            if let value = newsletter.fields[key] { draft.fields[key] = value }
        }
        return draft
    }

    static func importMarkdown(_ source: String, filename: String) -> (title: String, body: String) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let clean = normalized.hasPrefix("\u{feff}") ? String(normalized.dropFirst()) : normalized
        let lines = clean.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix("# "), !first.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = first.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = lines.count == 2 ? lines[1].drop(while: \.isNewline) : ""
            return (title, String(body))
        }
        return (filename, clean)
    }

    static func parse(_ markdown: String) throws -> [String: Any] {
        guard markdown.utf16.count <= 200_000, !markdown.contains("\0"), let parser = cmark_parser_new(0) else {
            throw WorkspaceError("Use Markdown with up to 200,000 characters.")
        }
        _ = registered
        defer { cmark_parser_free(parser) }
        if let extensionPointer = cmark_find_syntax_extension("strikethrough") {
            _ = cmark_parser_attach_syntax_extension(parser, extensionPointer)
        }
        markdown.withCString { cmark_parser_feed(parser, $0, markdown.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { throw WorkspaceError("This Markdown could not be parsed.") }
        defer { cmark_node_free(root) }
        return ["type": "doc", "attrs": ["schemaVersion": "v1"], "content": try children(root).map { try block($0, depth: 1) }]
    }

    private static func children(_ node: OpaquePointer) -> [OpaquePointer] {
        var results: [OpaquePointer] = []
        var next = cmark_node_first_child(node)
        while let child = next {
            results.append(child)
            next = cmark_node_next(child)
        }
        return results
    }

    private static func type(_ node: OpaquePointer) -> String {
        cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
    }

    private static func literal(_ node: OpaquePointer) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    private static func link(_ node: OpaquePointer) -> String? {
        guard let pointer = cmark_node_get_url(node), let url = URL(string: String(cString: pointer)),
              ["https", "mailto"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
              url.scheme != "https" || url.host != nil else { return nil }
        return url.absoluteString
    }

    private static func block(_ node: OpaquePointer, depth: Int) throws -> [String: Any] {
        guard depth <= 32 else { throw WorkspaceError("Simplify the newsletter’s nested Markdown.") }
        let kind = type(node)
        if kind == "code_block" {
            let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
            let language: Any = info.split(whereSeparator: \.isWhitespace).first.map { String($0.prefix(50)) } as Any? ?? NSNull()
            let text = literal(node)
            var block: [String: Any] = ["type": "code_block", "attrs": ["language": language]]
            if !text.isEmpty { block["content"] = [["type": "text", "text": text]] }
            return block
        }
        if kind == "thematic_break" { return ["type": "horizontal_rule"] }
        if kind == "html_block" { return ["type": "paragraph", "content": [["type": "text", "text": literal(node).trimmingCharacters(in: .newlines)]]] }
        let descendants = children(node)
        if kind == "paragraph" || kind == "heading" {
            if descendants.count == 1, let image = descendants.first, type(image) == "image", let src = link(image) {
                let alt = try inline(children(image), marks: [], depth: depth + 1).compactMap { $0["text"] as? String }.joined()
                return ["type": "captionedImage", "content": [
                    ["type": "image2", "attrs": ["src": src, "alt": alt.isEmpty ? NSNull() : alt as Any]]
                ]]
            }
            var block: [String: Any] = ["type": kind, "content": try inline(descendants, marks: [], depth: depth + 1)]
            if kind == "heading" { block["attrs"] = ["level": Int(cmark_node_get_heading_level(node))] }
            return block
        }
        let name: String
        var attributes: [String: Int]?
        switch kind {
        case "block_quote": name = "blockquote"
        case "item": name = "listItem"
        case "list":
            if cmark_node_get_list_type(node) == 2 {
                name = "orderedList"
                let start = Int(cmark_node_get_list_start(node))
                attributes = ["start": start, "order": start]
            } else { name = "bulletList" }
        default: throw WorkspaceError("A Markdown block could not be converted. Check the newsletter source.")
        }
        var block: [String: Any] = ["type": name, "content": try descendants.map { try self.block($0, depth: depth + 1) }]
        if let attributes { block["attrs"] = attributes }
        return block
    }

    private static func inline(_ nodes: [OpaquePointer], marks: [[String: Any]], depth: Int) throws -> [[String: Any]] {
        guard depth <= 32 else { throw WorkspaceError("Simplify the newsletter’s nested formatting.") }
        var result: [[String: Any]] = []
        for node in nodes {
            let kind = type(node)
            switch kind {
            case "text", "html_inline", "code", "softbreak", "image":
                let value: String
                var formatting = marks
                if kind == "softbreak" { value = " " }
                else if kind == "image" {
                    let alt = try inline(children(node), marks: [], depth: depth + 1).compactMap { $0["text"] as? String }.joined()
                    value = alt.isEmpty ? "Image" : alt
                    if let url = link(node) { formatting.append(["type": "link", "attrs": ["href": url]]) }
                } else {
                    value = literal(node)
                    if kind == "code" { formatting.append(["type": "code"]) }
                }
                if !value.isEmpty {
                    var text: [String: Any] = ["type": "text", "text": value]
                    if !formatting.isEmpty { text["marks"] = formatting }
                    result.append(text)
                }
            case "linebreak": result.append(["type": "hard_break"])
            case "strong", "emph", "strikethrough", "link":
                var next = marks
                if kind == "link" {
                    if let url = link(node) { next.append(["type": "link", "attrs": ["href": url]]) }
                } else {
                    next.append(["type": kind == "emph" ? "em" : kind])
                }
                result += try inline(children(node), marks: next, depth: depth + 1)
            default: throw WorkspaceError("A Markdown formatting element could not be converted.")
            }
        }
        return result
    }

    static func canonical(_ value: Any) throws -> String {
        if let object = value as? [String: Any] {
            return "{" + (try object.keys.sorted().map { key in try canonical(key) + ":" + canonical(object[key] ?? NSNull()) }).joined(separator: ",") + "}"
        }
        if let array = value as? [Any] { return "[" + (try array.map(canonical)).joined(separator: ",") + "]" }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func html(_ document: [String: Any], title: String, subtitle: String) -> String {
        let introduction = "<h1>" + escape(title) + "</h1>" + (subtitle.isEmpty ? "" : "<p><em>" + escape(subtitle) + "</em></p>")
        return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>" + escape(title)
            + "</title></head><body>" + introduction + render(document) + "</body></html>"
    }

    private static func render(_ node: [String: Any]) -> String {
        let kind = node["type"] as? String ?? ""
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        if kind == "text" {
            var text = escape(node["text"] as? String ?? "")
            for mark in node["marks"] as? [[String: Any]] ?? [] {
                let kind = mark["type"] as? String ?? ""
                if kind == "link", let address = (mark["attrs"] as? [String: String])?["href"] {
                    text = "<a href=\"" + escape(address) + "\">" + text + "</a>"
                } else if let tag = ["strong": "strong", "em": "em", "code": "code", "strikethrough": "s"][kind] {
                    text = "<" + tag + ">" + text + "</" + tag + ">"
                }
            }
            return text
        }
        let body = (node["content"] as? [[String: Any]] ?? []).map(render).joined()
        if kind == "hard_break" { return "<br>" }
        if kind == "horizontal_rule" { return "<hr>" }
        if kind == "code_block" {
            return "<figure><figcaption>" + escape(attrs["language"] as? String ?? "Code") + "</figcaption><pre><code>" + body + "</code></pre></figure>"
        }
        if kind == "image2", let source = attrs["src"] as? String {
            return "<p><a href=\"" + escape(source) + "\">Image: " + escape(attrs["alt"] as? String ?? source) + "</a></p>"
        }
        let level = min(6, max(1, attrs["level"] as? Int ?? 2))
        guard let tag = ["doc": "article", "paragraph": "p", "heading": "h\(level)", "blockquote": "blockquote",
                         "bulletList": "ul", "orderedList": "ol", "listItem": "li", "captionedImage": "figure"][kind] else { return body }
        let attributes = tag == "ol" && (attrs["start"] as? Int ?? 1) != 1 ? " start=\"\(attrs["start"] as? Int ?? 1)\"" : ""
        return "<" + tag + attributes + ">" + body + "</" + tag + ">"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
