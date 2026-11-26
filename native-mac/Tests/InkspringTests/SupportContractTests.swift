import Foundation
import Testing
@testable import InkspringSchedule

@Test func supportSignInReadinessComesFromTheBackend() throws {
    let decoder = JSONDecoder()
    for (payload, signIn) in [(#"{}"#, false), (#"{"nativeConfigured":false}"#, false), (#"{"nativeConfigured":true}"#, true)] {
        let configuration = try decoder.decode(InkspringSupportConfiguration.self, from: Data(payload.utf8))
        #expect(configuration.canSignIn == signIn)
    }
}

@Test func supportRequestsStayOnTheSharedBackendAndSelectInkspring() throws {
    for route in ["configuration", "auth/native", "me", "tickets/free", "reply", "messages?ticket=example&before=2026-11-15"] {
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

@Test func supportAccountKeepsVerifiedIdentity() throws {
    let data = Data(#"{"user":{"id":"owner","email":"customer@privaterelay.appleid.com","is_staff":false},"tickets":[{"id":"ticket","reference":"IS-123","subject":"Mac setup","topic":"MCP setup","status":"open","app_id":"inkspring"}],"next_offset":null}"#.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let account = try decoder.decode(InkspringSupportAccount.self, from: data)
    #expect(account.user.email == "customer@privaterelay.appleid.com")
    #expect(!account.user.isStaff)
    #expect(account.tickets.first?.appId == "inkspring")
    #expect(account.tickets.first?.canReply == true)
}

@Test func resolvedTicketsCannotAcceptReplies() throws {
    for (status, expected) in [("open", true), ("resolved", false)] {
        let ticket = InkspringSupportTicket(id: "ticket", reference: "IS-123", subject: "Setup", topic: "MCP setup", status: status, appId: "inkspring")
        #expect(ticket.canReply == expected)
    }
}

@Test func supportMessagePreservesReplyAndTicketIdentity() throws {
    let data = Data(#"{"id":"message","ticket_id":"ticket","sender_role":"support","body":"Try this step.\nThen reopen Inkspring.","created_at":"2026-11-15T12:00:00.123Z"}"#.utf8)
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let message = try decoder.decode(InkspringSupportMessage.self, from: data)
    #expect(message.ticketId == "ticket")
    #expect(message.senderRole == "support")
    #expect(message.body == "Try this step.\nThen reopen Inkspring.")
}
