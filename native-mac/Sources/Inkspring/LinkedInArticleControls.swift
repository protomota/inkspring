import AppKit
import SwiftUI

struct LinkedInArticleControls: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let article: WorkspaceRecord
    let save: () -> Bool
    let openPost: (WorkspaceRecord) -> Void
    @State private var publishedURL = ""
    @State private var message: String?
    @State private var error: String?

    private var current: WorkspaceRecord {
        workspace.records.first { $0.isLinkedInArticle && $0.id == article.id } ?? article
    }

    private var post: WorkspaceRecord? {
        workspace.records.first {
            $0.kind == "draft" && $0["platform"] == "linkedin" && $0.projectID == current.projectID
                && $0["linkedinArticleID"] == current.id && $0.scheduleStatus != "posted"
        }
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
            Text("Publish the article on LinkedIn, then paste its public link here to use in your feed post.")
                .font(.caption).foregroundStyle(palette.muted)
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
                    perform { openPost(try workspace.linkedInShareDraft(for: current.id)) }
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

struct LinkedInArticlePicker: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let projectID: String
    @Binding var articleID: String
    let openArticle: (WorkspaceRecord) -> Void
    var createArticle: (() -> Void)? = nil

    var body: some View {
        let articles = workspace.records.filter { $0.isLinkedInArticle && $0.projectID == projectID }
        let selected = articles.first { $0.id == articleID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("LinkedIn article", selection: $articleID) {
                    Text("None").tag("")
                    if !articleID.isEmpty && selected == nil { Text("Unavailable article").tag(articleID) }
                    ForEach(articles) { article in Text(article.title).tag(article.id) }
                }
                .accessibilityIdentifier("linkedinArticle.picker")
                if let selected {
                    Button("Open article", systemImage: "doc.richtext") { openArticle(selected) }
                } else if let createArticle {
                    Button("Create article from post", systemImage: "doc.badge.plus", action: createArticle)
                        .accessibilityIdentifier("linkedinArticle.convertPost")
                }
            }
            if let selected, let url = LinkedInArticleShare.publishedURL(selected["articleURL"]) {
                StudioExternalLink("Published article link", destination: url)
            } else if !articleID.isEmpty {
                Text(selected == nil ? "Choose an available article or remove the link." :
                    "Add the published article link before scheduling or publishing this post.")
                    .font(.caption).foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .studioSurface(StudioRadius.control, fill: palette.well)
    }
}
