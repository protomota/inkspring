import SwiftUI
import InkspringSchedule

struct PostArticlePicker: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let projectID: String
    @Binding var articleID: String
    let openArticle: (WorkspaceRecord) -> Void
    var createArticle: (() -> Void)? = nil
    var xReplyArticles: [WorkspaceRecord] = []
    var allowsChanges = true
    var publishTogether: (() -> Void)? = nil

    var body: some View {
        let articles = workspace.records.filter {
            $0.projectID == projectID && $0.isXArticle
        }
        let defaultArticle = articleID.isEmpty && Set(xReplyArticles.map(\.id)).count == 1
            ? xReplyArticles.first : nil
        let selected = articles.first { $0.id == articleID } ?? defaultArticle
        VStack(alignment: .leading, spacing: 6) {
            Label("X article", systemImage: "doc.richtext")
                .font(.callout.weight(.semibold))
            if let selected {
                Button(selected.title, systemImage: "arrow.up.right") { openArticle(selected) }
                    .accessibilityIdentifier("postArticle.open")
                Text("Attached to this X post").font(.caption).foregroundStyle(palette.muted)
            } else if !articleID.isEmpty {
                Text("Linked article unavailable").font(.caption).foregroundStyle(palette.muted)
            }
            ForEach(xReplyArticles.filter { $0.id != selected?.id }) { article in
                Button("In reply · " + article.title, systemImage: "arrow.turn.down.right") { openArticle(article) }
            }
            if allowsChanges {
                if defaultArticle == nil && (!articles.isEmpty || !articleID.isEmpty) {
                    Picker("Attach an X article", selection: $articleID) {
                        Text("None").tag("")
                        if !articleID.isEmpty && selected == nil { Text("Unavailable article").tag(articleID) }
                        ForEach(articles) { article in Text(article.title).tag(article.id) }
                    }
                    .accessibilityIdentifier("xArticle.picker")
                }
                if selected == nil, xReplyArticles.isEmpty, let createArticle {
                    Button("Create linked article", systemImage: "doc.badge.plus", action: createArticle)
                        .accessibilityIdentifier("xArticle.createLinked")
                } else if selected == nil, articles.isEmpty {
                    Text("Create an X article in this project to attach it here.")
                        .font(.caption).foregroundStyle(palette.muted)
                }
            }
            if let publishTogether {
                Button("Review post and article…", systemImage: "paperplane", action: publishTogether)
                    .accessibilityIdentifier("postArticle.reviewPair")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .studioSurface(StudioRadius.control, fill: palette.well)
    }
}

extension Workspace {
    func xReplyArticles(for draft: WorkspaceRecord, body: String) -> [WorkspaceRecord] {
        guard draft["platform"] == "x", ["followup", "thread"].contains(draft["format"]) else { return [] }
        let posts = XThreadText.posts(in: body)
        let links = try? XPostArticleLinks(draft: draft, posts: posts, records: records)
        let articleIDs = Set(links?.replies.values.map(\.id) ?? [])
        return records.filter { articleIDs.contains($0.id) }
    }
}
