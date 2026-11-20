import AppKit
import InkspringSchedule
import SwiftUI

struct LinkedInArticleControls: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let article: WorkspaceRecord
    var preferredPostID: String?
    let save: () -> Bool
    let openPost: (WorkspaceRecord) -> Void
    @State private var publishedURL = ""
    @State private var message: String?
    @State private var error: String?

    private var current: WorkspaceRecord {
        workspace.records.first { $0.isLinkedInArticle && $0.id == article.id } ?? article
    }

    private var post: WorkspaceRecord? {
        let posts = workspace.records.filter {
            $0.kind == "draft" && $0["platform"] == "linkedin" && $0.projectID == current.projectID
                && $0["linkedinArticleID"] == current.id
        }
        return posts.first { $0.id == preferredPostID }
            ?? posts.first { $0.matchesID(current["sourceContentID"]) }
            ?? posts.first { $0.scheduleStatus != "posted" }
            ?? posts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StudioPlatformLabel(name: "linkedin", title: "LinkedIn article")
                Spacer()
                if let url = LinkedInArticleShare.publishedURL(current["articleURL"]) {
                    StudioExternalLink("View article", destination: url)
                }
            }
            if let post, current["articleURL"].isEmpty {
                Label(post.title, systemImage: "text.bubble").font(.callout.weight(.semibold))
                Text("Paste the title and article in LinkedIn’s editor. Click Next, paste the feed post into “Tell your network what your article is about,” then click Publish once.")
                    .font(.callout).foregroundStyle(palette.muted)
            } else {
                Text("A published article link can be attached to a LinkedIn feed post.")
                    .font(.caption).foregroundStyle(palette.muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { copyButtons }
                VStack(alignment: .leading, spacing: 8) { copyButtons }
            }
            HStack(alignment: .center, spacing: 8) {
                TextField("Published article URL", text: $publishedURL, prompt: Text("https://www.linkedin.com/pulse/…"))
                    .studioInput()
                    .accessibilityIdentifier("linkedinArticle.url")
                    .onSubmit(saveURL)
                Button("Save link", systemImage: "link", action: saveURL)
                    .disabled(publishedURL.trimmingCharacters(in: .whitespacesAndNewlines) == current["articleURL"])
                    .accessibilityIdentifier("linkedinArticle.saveURL")
            }
            HStack {
                Button(post == nil ? "Create linked post" : "Open linked post", systemImage: "text.bubble") {
                    guard save() else { return }
                    perform {
                        if let post { openPost(post) }
                        else { openPost(try workspace.linkedInShareDraft(for: current.id)) }
                    }
                }
                .accessibilityIdentifier("linkedinArticle.sharePost")
                if let reference = post?.referenceID { StudioCopyReference(reference: reference) }
                Spacer(minLength: 4)
                if let message { Text(message).font(.caption).foregroundStyle(palette.success) }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(palette.danger)
                    .accessibilityIdentifier("linkedinArticle.error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .studioSurface()
        .onChange(of: current["articleURL"], initial: true) { previous, updated in
            if publishedURL == previous || publishedURL.isEmpty { publishedURL = updated }
        }
    }

    @ViewBuilder private var copyButtons: some View {
        Button("Copy title", systemImage: "doc.on.doc") {
            guard save() else { return }
            perform {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(current.title, forType: .string)
                message = "Title copied"
            }
        }
        Button("Copy article", systemImage: "text.document") {
            guard save() else { return }
            perform {
                let body = current.body
                let document = try NewsletterDocument.parse(body)
                let html = NewsletterDocument.html(document, title: current.title, subtitle: "", includeHeading: false)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(body, forType: .string)
                NSPasteboard.general.setString(html, forType: .html)
                message = "Article copied"
            }
        }
        .disabled(article.body.isEmpty && current.body.isEmpty)
        .accessibilityIdentifier("linkedinArticle.copyBody")
        if let post {
            Button("Copy feed post", systemImage: "text.bubble") {
                copy(post.body)
                message = "Feed post copied"
            }
            .disabled(post.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("linkedinArticle.copyPost")
        }
        StudioExternalLink("Open LinkedIn editor", destination: LinkedInArticleShare.editorURL)
    }

    private func saveURL() {
        guard save() else { return }
        perform {
            let updated = try workspace.saveLinkedInArticleURL(publishedURL, article: current)
            publishedURL = updated["articleURL"]
            message = publishedURL.isEmpty ? "Link removed" : "Link saved"
        }
    }

    private func perform(_ action: () throws -> Void) {
        message = nil
        error = nil
        do { try action() }
        catch { self.error = error.localizedDescription }
    }
}

struct PostArticlePicker: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let projectID: String
    var platform: SocialPlatform = .linkedin
    @Binding var articleID: String
    let openArticle: (WorkspaceRecord) -> Void
    var createArticle: (() -> Void)? = nil
    var xReplyArticles: [WorkspaceRecord] = []
    var allowsChanges = true
    var publishTogether: (() -> Void)? = nil

    var body: some View {
        let articles = workspace.records.filter {
            $0.projectID == projectID && (platform == .x ? $0.isXArticle : $0.isLinkedInArticle)
        }
        let selected = articles.first { $0.id == articleID }
        VStack(alignment: .leading, spacing: 6) {
            Label(platform == .x ? "X article" : "LinkedIn article", systemImage: "doc.richtext")
                .font(.callout.weight(.semibold))
            if let selected {
                Button(selected.title, systemImage: "arrow.up.right") { openArticle(selected) }
                    .accessibilityIdentifier("postArticle.open")
            } else if !articleID.isEmpty {
                Text("Linked article unavailable").font(.caption).foregroundStyle(palette.muted)
            }
            ForEach(xReplyArticles.filter { $0.id != selected?.id }) { article in
                Button("In reply · " + article.title, systemImage: "arrow.turn.down.right") { openArticle(article) }
            }
            if allowsChanges {
                if !articles.isEmpty || !articleID.isEmpty {
                    Picker(platform == .x ? "Attach to opening post" : "Attach article", selection: $articleID) {
                        Text("None").tag("")
                        if !articleID.isEmpty && selected == nil { Text("Unavailable article").tag(articleID) }
                        ForEach(articles) { article in Text(article.title).tag(article.id) }
                    }
                    .accessibilityIdentifier(platform == .x ? "xArticle.picker" : "linkedinArticle.picker")
                }
                if selected == nil, xReplyArticles.isEmpty, let createArticle {
                    Button("Create linked article", systemImage: "doc.badge.plus", action: createArticle)
                        .accessibilityIdentifier(platform == .x ? "xArticle.createLinked" : "linkedinArticle.convertPost")
                } else if platform == .x, selected == nil, articles.isEmpty {
                    Text("Create an X article in this project to attach it here.")
                        .font(.caption).foregroundStyle(palette.muted)
                }
            }
            if let selected, platform == .linkedin {
                if let url = LinkedInArticleShare.publishedURL(selected["articleURL"]) {
                    StudioExternalLink("Published article link", destination: url)
                } else if publishTogether == nil {
                    Text("Open the article to publish it together with this feed post.")
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
