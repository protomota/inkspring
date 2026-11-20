import Foundation

extension WorkspaceRecord {
    var isLinkedInArticle: Bool { kind == "article" && self["platform"] == "linkedin" }
    var isXArticle: Bool { kind == "article" && !isLinkedInArticle }
}

struct LinkedInArticleShare: Equatable {
    static let editorURL = URL(string: "https://www.linkedin.com/article/new/")!

    let articleID: String
    let title: String
    let url: URL

    static func publishedURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2_000, var parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), ["www.linkedin.com", "linkedin.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.percentEncodedPath.range(of: #"\A/pulse/[A-Za-z0-9_%-]+/?\z"#, options: .regularExpression) != nil else {
            return nil
        }
        let path = parts.percentEncodedPath.hasSuffix("/") ? parts.percentEncodedPath.dropLast() : parts.percentEncodedPath[...]
        guard let slug = path.dropFirst("/pulse/".count).removingPercentEncoding,
              slug.range(of: #"\A[\p{L}\p{N}\p{M}_-]+\z"#, options: .regularExpression) != nil else { return nil }
        parts.scheme = "https"
        parts.host = "www.linkedin.com"
        parts.path = "/pulse/" + slug + "/"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func resolve(post: WorkspaceRecord, in records: [WorkspaceRecord]) throws -> Self? {
        let id = post["linkedinArticleID"]
        guard !id.isEmpty else { return nil }
        guard let article = records.first(where: {
            $0.isLinkedInArticle && $0.id == id && $0.projectID == post.projectID
        }) else {
            throw WorkspaceError("Choose a LinkedIn article from this project before sharing.")
        }
        guard let url = publishedURL(article["articleURL"]) else {
            throw WorkspaceError("Add the published LinkedIn article link before sharing “\(article.title)”.")
        }
        return Self(articleID: id, title: article.title, url: url)
    }
}

extension Workspace {
    func linkedInArticleDraft(from expected: WorkspaceRecord) throws -> WorkspaceRecord {
        try withChanges {
            guard var post = records.first(where: { $0.kind == "draft" && $0.id == expected.id }),
                  post["updatedAt"] == expected["updatedAt"], post["platform"] == "linkedin",
                  post["format"] == "post", !post.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !["posting", "posted"].contains(post.scheduleStatus) else {
                throw WorkspaceError("Save a LinkedIn draft with post text before creating an article.")
            }
            if let article = records.first(where: { $0.isLinkedInArticle && $0.id == post["linkedinArticleID"] && $0.projectID == post.projectID }) {
                return article
            }
            var article = WorkspaceRecord.new("article", projectID: post.projectID)
            article["platform"] = "linkedin"
            article["title"] = post.title
            article["body"] = post.body
            article["sourceContentID"] = post.referenceID ?? post.id
            article = try save(article)
            post["linkedinArticleID"] = article.id
            try save(post)
            return article
        }
    }

    @discardableResult
    func saveLinkedInArticleURL(_ input: String, article expected: WorkspaceRecord) throws -> WorkspaceRecord {
        try withChanges {
            guard var article = records.first(where: { $0.isLinkedInArticle && $0.id == expected.id }),
                  article["updatedAt"] == expected["updatedAt"] else {
                throw WorkspaceError("The article changed. Open the latest version and try again.")
            }
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = LinkedInArticleShare.publishedURL(text)
            guard text.isEmpty || url != nil else {
                throw WorkspaceError("Paste the published article’s linkedin.com/pulse/ link.")
            }
            let value = url?.absoluteString ?? ""
            if value == article["articleURL"] { return article }
            guard !records.contains(where: {
                $0.kind == "draft" && $0["linkedinArticleID"] == article.id &&
                    ["queued", "due", "posting"].contains($0.scheduleStatus)
            }) else {
                throw WorkspaceError("Unschedule the linked post before changing its article link.")
            }
            article["articleURL"] = value
            return try save(article)
        }
    }

    func linkedInShareDraft(for id: String) throws -> WorkspaceRecord {
        try withChanges {
            guard let article = records.first(where: { $0.isLinkedInArticle && $0.id == id }) else {
                throw WorkspaceError("Save the LinkedIn article before creating its post.")
            }
            if let post = records.first(where: {
                $0.kind == "draft" && $0["platform"] == "linkedin" && $0.projectID == article.projectID &&
                    $0["linkedinArticleID"] == id && $0.scheduleStatus != "posted"
            }) {
                return post
            }
            var post = WorkspaceRecord.new("draft", projectID: article.projectID)
            post["platform"] = "linkedin"
            post["title"] = String(article.title.prefix(100))
            post["linkedinArticleID"] = id
            return try save(post)
        }
    }
}
