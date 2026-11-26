import Foundation

public enum ContentPlan {
    public static let limit = 100_000
    public static func validate(_ markdown: String) throws {
        guard markdown.utf16.count <= limit, !markdown.contains("\0") else { throw ContentPlanError.invalid }
    }
    public static func decode(_ data: Data) throws -> String {
        guard data.count <= limit * 4, let text = String(data: data, encoding: .utf8) else { throw ContentPlanError.invalid }
        try validate(text)
        return text
    }
    public static func filename(_ reference: String) -> String {
        let clean = reference.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return String((clean.isEmpty ? "CONTENT" : clean).prefix(80)) + "-plan.md"
    }
    public static func requested(in request: String) -> Bool {
        request.range(of: #"(?i)\b(?:with|include|including|add)\s+(?:a\s+)?plan\b"#, options: .regularExpression) != nil
    }
    public static func starter(_ title: String) -> String {
        "# \(title)\n\n## Goal\n\n\n## Steps\n\n- [ ] Develop the angle.\n- [ ] Write the draft.\n- [ ] Review and verify.\n"
    }
}

public enum ContentPlanError: LocalizedError {
    case invalid, conflict
    public var errorDescription: String? {
        switch self {
        case .invalid: "Choose UTF-8 Markdown with up to 100,000 characters."
        case .conflict: "The saved plan changed. Your draft is kept. Compare the latest saved plan before saving again."
        }
    }
}

public enum CompanionContentOperation: String, Codable, Sendable {
    case savePlan, createDraft, createNewsletter, createProject, moveProject, setTitle
}
