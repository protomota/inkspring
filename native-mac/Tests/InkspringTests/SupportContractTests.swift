import Foundation
import Testing
@testable import InkspringSchedule

@Test func supportSignInAndPurchaseReadinessStaySeparateAndRequireTheExactProduct() throws {
    let decoder = JSONDecoder()
    for (payload, signIn, purchase) in [
        (#"{}"#, false, false),
        (#"{"nativeConfigured":false,"paidSupportConfigured":true,"supportProductID":"com.protomota.inkspring.support.ticket"}"#, false, false),
        (#"{"nativeConfigured":true,"paidSupportConfigured":false,"supportProductID":"com.protomota.inkspring.support.ticket"}"#, true, false),
        (#"{"nativeConfigured":true,"paidSupportConfigured":true,"supportProductID":"com.protomota.inkspring.support.ticket"}"#, true, true),
        (#"{"nativeConfigured":true,"paidSupportConfigured":true,"supportProductID":"com.protomota.jotley.support.ticket"}"#, true, false)
    ] {
        let configuration = try decoder.decode(InkspringSupportConfiguration.self, from: Data(payload.utf8))
        #expect(configuration.canSignIn == signIn)
        #expect(configuration.canPurchaseTicket == purchase)
    }
}

@Test func supportRequestsStayOnTheSharedBackendAndSelectInkspring() throws {
    for route in ["configuration", "auth/native", "me", "apple/claim", "tickets", "reply", "messages?ticket=example&before=2026-11-15"] {
        let url = try #require(InkspringSupportURLs.api(route))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https")
        #expect(parts.host == "protomota.com")
        #expect(parts.path.hasPrefix("/api/support/"))
        #expect(parts.queryItems?.filter { $0.name == "app" }.map(\.value) == ["inkspring"])
    }
    let messagesURL = try #require(InkspringSupportURLs.api("messages?ticket=example"))
    let messages = try #require(URLComponents(url: messagesURL, resolvingAgainstBaseURL: false))
    #expect(messages.queryItems?.first { $0.name == "ticket" }?.value == "example")
    #expect(InkspringSupportURLs.help.absoluteString == "https://protomota.com/support?app=inkspring")
}

@Test func supportAccountKeepsVerifiedIdentityAndPurchaseOwnership() throws {
    let data = Data(#"{"user":{"id":"owner","email":"customer@privaterelay.appleid.com","is_staff":false},"tickets":[{"id":"ticket","reference":"IS-123","subject":"Mac setup","topic":"MCP setup","status":"open","app_id":"inkspring","purchase":{"id":"credit","provider":"app_store","status":"paid","used":true,"app_id":"inkspring"}}],"purchases":[{"id":"credit","provider":"app_store","status":"paid","used":true,"app_id":"inkspring"}],"next_offset":null}"#.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let account = try decoder.decode(InkspringSupportAccount.self, from: data)
    #expect(account.user.email == "customer@privaterelay.appleid.com")
    #expect(!account.user.isStaff)
    #expect(account.tickets.first?.purchase?.id == account.purchases.first?.id)
    #expect(account.tickets.first?.appId == "inkspring")
    #expect(account.purchases.first?.used == true)
    #expect(account.tickets.first?.canReply == true)
}

@Test func resolvedAndRefundedTicketsCannotAcceptReplies() throws {
    for (status, payment, expected) in [("open", "paid", true), ("resolved", "paid", false), ("open", "refunded", false)] {
        let purchase = InkspringSupportPurchase(id: "purchase", provider: "app_store", status: payment, used: true, appId: "inkspring")
        let ticket = InkspringSupportTicket(id: "ticket", reference: "IS-123", subject: "Setup", topic: "MCP setup", status: status, purchase: purchase, appId: "inkspring")
        #expect(ticket.canReply == expected)
    }
    let free = InkspringSupportTicket(id: "bug", reference: "IS-456", subject: "Bug", topic: "MCP setup", status: "open", purchase: nil, appId: "inkspring")
    #expect(free.canReply)
}

@Test func supportMessagePreservesReplyAndTicketIdentity() throws {
    let data = Data(#"{"id":"message","ticket_id":"ticket","sender_role":"support","body":"Try this step.\nThen reopen Inkspring.","created_at":"2026-11-15T12:00:00.123Z"}"#.utf8)
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let message = try decoder.decode(InkspringSupportMessage.self, from: data)
    #expect(message.ticketId == "ticket")
    #expect(message.senderRole == "support")
    #expect(message.body == "Try this step.\nThen reopen Inkspring.")
}
