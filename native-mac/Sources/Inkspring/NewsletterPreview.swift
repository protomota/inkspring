import SwiftUI

struct NewsletterPreview: View {
    let title: String
    let subtitle: String
    let markdown: String
    let cover: URL?
    @State private var blocks: [[String: Any]] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            AttachedMedia(url: cover)
            Text(title.isEmpty ? "Your newsletter title" : title)
                .font(InkspringTypography.editorial(32, relativeTo: .title))
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(InkspringTypography.interface(19))
                    .lineSpacing(5)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    NewsletterPreviewBlock(node: block)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .studioSurface()
        .task(id: markdown) {
            do {
                try await Task.sleep(for: .milliseconds(180))
                blocks = try NewsletterDocument.parse(markdown)["content"] as? [[String: Any]] ?? []
                error = nil
            } catch is CancellationError {
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }
}

private struct NewsletterPreviewBlock: View {
    @Environment(\.studioPalette) private var palette
    let node: [String: Any]

    private var children: [[String: Any]] { node["content"] as? [[String: Any]] ?? [] }
    private var attributes: [String: Any] { node["attrs"] as? [String: Any] ?? [:] }

    var body: some View {
        switch node["type"] as? String {
        case "heading":
            let level = attributes["level"] as? Int ?? 1
            Text(inline)
                .font(InkspringTypography.editorial(level == 1 ? 28 : level == 2 ? 23 : 19, relativeTo: .headline))
                .accessibilityAddTraits(.isHeader)
        case "paragraph":
            Text(inline)
                .font(InkspringTypography.interface(17))
                .lineSpacing(5)
        case "blockquote":
            blockChildren
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(palette.line).frame(width: 2) }
        case "bulletList", "orderedList":
            let start = attributes["start"] as? Int
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(start.map { "\($0 + index)." } ?? "•").foregroundStyle(.secondary)
                        NewsletterPreviewBlock(node: child)
                    }
                }
            }
        case "listItem":
            blockChildren
        case "code_block":
            VStack(alignment: .leading, spacing: 6) {
                Text(attributes["language"] as? String ?? "Code").font(.caption)
                ScrollView(.horizontal) {
                    Text(inline).font(.system(.body, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioSurface(StudioRadius.control, fill: palette.well)
        case "horizontal_rule":
            Divider()
        case "captionedImage":
            blockChildren
        case "image2":
            if let src = attributes["src"] as? String, let url = URL(string: src), url.scheme == "https" {
                Link(destination: url) {
                    StudioLinkOutLabel { Label(attributes["alt"] as? String ?? "Newsletter image", systemImage: "photo") }
                }
            }
        default:
            EmptyView()
        }
    }

    private var blockChildren: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                NewsletterPreviewBlock(node: child)
            }
        }
    }

    private var inline: AttributedString {
        var result = AttributedString()
        for node in children {
            if node["type"] as? String == "hard_break" {
                result.append(AttributedString("\n"))
                continue
            }
            guard let text = node["text"] as? String else { continue }
            var span = AttributedString(text)
            var intent: InlinePresentationIntent = []
            for mark in node["marks"] as? [[String: Any]] ?? [] {
                switch mark["type"] as? String {
                case "strong": intent.insert(.stronglyEmphasized)
                case "em": intent.insert(.emphasized)
                case "strikethrough": intent.insert(.strikethrough)
                case "code": span.font = .system(.body, design: .monospaced)
                case "link":
                    if let attributes = mark["attrs"] as? [String: Any], let href = attributes["href"] as? String {
                        span.link = URL(string: href)
                    }
                default: break
                }
            }
            if !intent.isEmpty { span.inlinePresentationIntent = intent }
            result.append(span)
        }
        return result
    }
}
