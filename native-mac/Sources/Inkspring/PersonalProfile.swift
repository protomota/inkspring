import Foundation

enum PersonalProfile {
    static let sampleLimit = 16_000
    static let textLimits = ["voice": 2000, "imageStyle": 2000, "interests": 2000, "avoid": 2000, "samples": sampleLimit]
    static let sourceNames = ["x", "news", "instagram", "linkedin"]

    static func normalized(_ input: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, limit) in textLimits {
            let value = input[key] ?? ""
            guard let value = value as? String, value.utf16.count <= limit else {
                throw WorkspaceError("Profile field \(key) must use up to \(limit) characters.")
            }
            result[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let tags = (input["hashtags"] ?? [String]()) as? [String], tags.count <= 30,
              let sources = (input["researchSources"] ?? ["x", "news"]) as? [String],
              sources.allSatisfy(sourceNames.contains) else {
            throw WorkspaceError("Choose supported sources and up to 30 hashtags.")
        }
        var normalizedTags: [String] = []
        for value in tags {
            var tag = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if tag.hasPrefix("#") { tag.removeFirst() }
            guard tag.range(of: #"\A[\p{L}\p{N}_]{1,32}\z"#, options: .regularExpression) != nil else {
                throw WorkspaceError("Use 1–32 letters, numbers or underscores per hashtag.")
            }
            if !normalizedTags.contains(tag) { normalizedTags.append(tag) }
        }
        result["hashtags"] = normalizedTags
        result["researchSources"] = sourceNames.filter(sources.contains)
        return result
    }

    static func publishedDrafts(in records: [WorkspaceRecord]) -> [WorkspaceRecord] {
        let published = Set(records.filter { $0.kind == "publication" && $0["status"] == "published" }.map { $0["draftId"] })
        return Array(records.filter {
            $0.kind == "draft" && $0.fields["sample"] as? Bool != true &&
                ($0.scheduleStatus == "posted" || published.contains($0.id)) &&
                !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.prefix(40))
    }

    static func samples(appending drafts: [WorkspaceRecord], to existing: String) throws -> String {
        let sections = [existing] + drafts.map { String(decoding: $0.body.utf16.prefix(4000), as: UTF16.self) }
        let combined = sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard combined.utf16.count <= sampleLimit else {
            throw WorkspaceError("Choose fewer posts. Writing samples can use up to 16,000 characters.")
        }
        return combined
    }
}
