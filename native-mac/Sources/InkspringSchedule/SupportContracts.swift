import Foundation

struct InkspringSupportConfiguration: Decodable {
    let nativeConfigured: Bool?
    let paidSupportConfigured: Bool?
    let supportProductID: String?

    var canSignIn: Bool { nativeConfigured == true }
    var canPurchaseTicket: Bool {
        canSignIn && paidSupportConfigured == true
            && supportProductID == "com.protomota.inkspring.support.ticket"
    }
}

struct InkspringSupportPurchase: Decodable, Identifiable {
    let id: String
    let provider: String
    let status: String
    let used: Bool?
    let appId: String?
}
struct InkspringSupportTicket: Decodable, Identifiable {
    let id: String
    let reference: String
    let subject: String
    let topic: String
    let status: String
    let purchase: InkspringSupportPurchase?
    let appId: String?

    var canReply: Bool { status != "resolved" && (purchase?.status ?? "paid") == "paid" }
}

enum InkspringSupportURLs {
    private static let origin = "https://protomota.com"
    static let help = URL(string: origin + "/support?app=inkspring")!
    static let macSignIn = URL(string: origin + "/support/mac")!
    static let privacy = origin + "/privacy"

    static func api(_ path: String) -> URL? {
        guard var parts = URLComponents(string: origin + "/api/support/" + path) else { return nil }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "app", value: "inkspring")]
        return parts.url
    }
}

struct InkspringSupportMessage: Decodable, Identifiable {
    let id: String
    let ticketId: String
    let senderRole: String
    let body: String
    let createdAt: String
}
struct InkspringSupportAccount: Decodable {
    struct User: Decodable { let id: String; let email: String; let isStaff: Bool }
    let user: User
    let tickets: [InkspringSupportTicket]
    let purchases: [InkspringSupportPurchase]
    let nextOffset: Int?
}
