import SwiftUI

/// When the agent setup banner may show. "Later" hides it for a week; "Don't show again" hides it for good.
enum AgentGuideInvitationSchedule {
    static let dismissedKey = "inkspringAgentGuideInvitationSeen"
    static let snoozedUntilKey = "inkspringAgentGuideInvitationSnoozedUntil"
    static let laterInterval: TimeInterval = 7 * 24 * 60 * 60

    static func isVisible(dismissed: Bool, snoozedUntil: Double, now: Date = .now) -> Bool {
        !dismissed && now.timeIntervalSince1970 >= snoozedUntil
    }

    static func later(from now: Date = .now) -> Double {
        now.timeIntervalSince1970 + laterInterval
    }
}

struct AgentGuideInvitation: View {
    @Environment(\.studioPalette) private var palette
    let open: () -> Void
    let later: () -> Void
    let dismissForever: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(palette.iconAccent)
                .accessibilityHidden(true)
            Text("Bring your AI agent into your writing workspace.")
                .font(InkspringTypography.interface(14))
            Button("Don’t show again", action: dismissForever)
                .buttonStyle(.plain)
                .font(InkspringTypography.interface(12))
                .foregroundStyle(palette.muted)
                .padding(.leading, 10)
                .accessibilityIdentifier("agentInvitation.dontShowAgain")
            Spacer()
            Button("Later", action: later)
                .buttonStyle(StudioActionStyle())
                .accessibilityIdentifier("agentInvitation.later")
            Button("Set up AI agents", action: open).buttonStyle(StudioActionStyle(prominent: true))
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(palette.panel)
        .overlay(alignment: .bottom) { StudioRule() }
    }
}

struct AgentConnectionGuide: View {
    enum Step: Int, CaseIterable {
        case access, client, verify

        var name: String {
            switch self {
            case .access: "Workspace access"
            case .client: "Connect a client"
            case .verify: "Try it out"
            }
        }

        var heading: String {
            switch self {
            case .access: "Choose what your agent can do"
            case .client: "Connect your writing workspace"
            case .verify: "Ask about your projects"
            }
        }
    }

    let workspace: Workspace
    @Environment(\.studioPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .access
    @State private var copied = false
    private let sample = "List my Inkspring projects."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI agent setup").font(InkspringTypography.interface(15).weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 28).padding(.vertical, 18)
            StudioRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Step \(step.rawValue + 1) of 3  ·  \(step.name)").foregroundStyle(palette.muted)
                    Text(step.heading).font(InkspringTypography.interface(27).weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    switch step {
                    case .access:
                        Text("MCP connects an AI client to this Mac so you can ask about drafts or save a new idea. Your AI provider may receive content your agent reads.")
                        AgentSettings(workspace: workspace, section: .access)
                    case .client:
                        Text("Use the client you’ll write in. Open a fresh session after saving the connection, and approve the connector there if prompted.")
                        AgentSettings(workspace: workspace, section: .client)
                        if !workspace.agentAccessEnabled {
                            Text("To use the connector, turn on workspace access in the previous step.").foregroundStyle(palette.muted)
                        }
                    case .verify:
                        Text("Test the local connector first. Then ask your AI client this question to check the whole connection.")
                        AgentSettings(workspace: workspace, section: .test)
                        StudioRule()
                        Text(sample).font(InkspringTypography.interface(18).weight(.medium)).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy question", systemImage: "doc.on.doc") {
                            copy(sample)
                            copied = true
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            StudioRule()
            HStack {
                if step != .access {
                    Button("Back") { step = step == .verify ? .client : .access }
                }
                Spacer()
                Button(step == .verify ? "Done" : "Continue") {
                    switch step {
                    case .access: step = .client
                    case .client: step = .verify
                    case .verify: dismiss()
                    }
                }
                .buttonStyle(StudioActionStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 580, height: 550)
        .background(palette.canvas)
        .studioAppearance(palette)
    }
}
