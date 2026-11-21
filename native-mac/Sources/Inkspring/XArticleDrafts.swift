import Foundation
import InkspringSchedule

extension WorkspaceRecord {
    var isXArticle: Bool { kind == "article" && (self["platform"] == "x" || self["platform"].isEmpty) }
}

extension Workspace {
    func linkedArticleDraft(from expected: WorkspaceRecord) throws -> WorkspaceRecord {
        try withChanges {
            guard var post = records.first(where: { $0.kind == "draft" && $0.id == expected.id }),
                  post["updatedAt"] == expected["updatedAt"], post["platform"] == "x",
                  post["format"] != "reply",
                  !post.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !["posting", "posted", "uncertain"].contains(post.scheduleStatus) else {
                throw WorkspaceError("Save the current X post text before creating an article.")
            }
            if let article = records.first(where: {
                $0.id == post["xArticleID"] && $0.projectID == post.projectID && $0.isXArticle
            }) {
                return article
            }
            var article = WorkspaceRecord.new("article", projectID: post.projectID)
            article["title"] = post.title
            article["body"] = ["followup", "thread"].contains(post["format"])
                ? XThreadText.posts(in: post.body).first ?? post.body : post.body
            article["sourceContentID"] = post.referenceID ?? post.id
            article = try save(article)
            post["xArticleID"] = article.id
            try save(post)
            return article
        }
    }
}
