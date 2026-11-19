import AuthenticationServices
import SwiftUI
import StoreKit

struct InkspringTechnicalSupportButton: View {
    @Environment(\.studioPalette) private var palette
    @State private var showingSupport = false
    var body: some View {
        Button { showingSupport = true } label: {
            HStack {
                Label {
                    Text("Open a Support Ticket").foregroundStyle(palette.text)
                } icon: {
                    Image(systemName: "headphones").foregroundStyle(palette.iconAccent)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.iconAccent)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("settingsTechnicalSupport")
        .sheet(isPresented: $showingSupport) { InkspringSupportTicketsView() }
    }
}

struct InkspringSupportTicketsView: View {
    @EnvironmentObject private var store: InkspringSupportStore
    @Environment(\.studioPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var nonce = ""
    private enum RequestPresentation: String, Identifiable {
        case purchased, existing
        var id: Self { self }
    }
    @State private var requestPresentation: RequestPresentation?
    @State private var confirmingDeletion = false
    @State private var submittedTicketID: String?
    @State private var ticketToDelete: InkspringSupportTicket?
    var body: some View {
        NavigationStack {
            Group {
                if let ticket = store.selectedTicket {
                    conversation(ticket)
                } else if store.account != nil {
                    accountView
                } else {
                    signInView
                }
            }
            .navigationTitle("Support")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("supportDone")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await store.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh support")
                    .disabled(store.busy)
                    .accessibilityIdentifier("supportRefresh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = store.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.regularMaterial).accessibilityIdentifier("supportNotice")
                }
            }
        }
        .tint(palette.accent)
        .modifier(InkspringSupporterCelebration())
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 840, minHeight: 650)
        .onDisappear { store.cancelBrowserSignIn() }
        #endif
        .sheet(item: $requestPresentation, onDismiss: { store.requestUnlocked = false }) { presentation in
            newRequest(showCelebration: presentation == .purchased)
        }
        .confirmationDialog("Delete your support account?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Support Account", role: .destructive) { Task { await store.deleteAccount() } }
            Button("Keep My Account", role: .cancel) { }
        } message: {
            Text("This permanently deletes your Protomota support profile, tickets and conversations for all apps. Unused tickets will no longer be available. Your local notes stay on your device. Deletion does not request a refund; unlinked transaction references are retained to reconcile purchases and prevent reuse.")
        }
        .alert("Delete this conversation?", isPresented: Binding(
            get: { ticketToDelete != nil },
            set: { if !$0 { ticketToDelete = nil } }
        ), presenting: ticketToDelete) { ticket in
            Button("Delete conversation", role: .destructive) { Task { await store.deleteConversation(ticket) } }
                .accessibilityIdentifier("supportConfirmDeleteConversation")
            Button("Cancel", role: .cancel) { }
        } message: { ticket in
            Text("“\(ticket.subject)” and its messages will be permanently deleted. Your other tickets will stay in your history. This does not refund or restore the purchase.")
        }
        .onChange(of: store.requestUnlocked) { _, unlocked in
            if unlocked { requestPresentation = .purchased }
        }
        .onChange(of: store.selectedTicketID) { _, id in
            if id != nil && requestPresentation != nil { submittedTicketID = id }
            if id != nil { requestPresentation = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in store.signOut() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        .task {
            await store.load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                if scenePhase == .active { await store.refresh() }
            }
        }
    }
    private var ticketCoverage: Text {
        Text("One ticket covers one Inkspring issue across iPhone, iPad, and Mac. You’ll get help in a private conversation with Protomota Support.")
    }

    private var accountView: some View {
        Form {
            Section {
                Label("Personal help from a real person", systemImage: "person.bubble.left.and.bubble.right")
                    .font(.headline)
                InkspringSupporterBadge()
                ticketCoverage
                if let price = store.ticketPrice {
                    Text("\(price) per ticket · One-time purchase").font(.callout.weight(.semibold))
                }
                Text("Follow-up replies stay in the same ticket.").font(.callout).foregroundStyle(.secondary)
            }
            if let account = store.account {
                Section("Your Apple account") {
                    LabeledContent("Contact email", value: account.user.email).textSelection(.enabled)
                    Text("This verified contact address comes from Apple and cannot be edited in your support request.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sign out") { store.signOut() }.disabled(store.busy)
                    Button("Delete support account", role: .destructive) { confirmingDeletion = true }
                        .disabled(store.busy).accessibilityIdentifier("supportDeleteAccount")
                }
                Section("Open a support request") {
                    if !store.unusedPurchases.isEmpty {
                        Button("Write your support request") { requestPresentation = .existing }
                            .accessibilityIdentifier("supportWriteRequest")
                        Text("You have a purchased ticket available.").font(.caption).foregroundStyle(.secondary)
                    } else if InkspringSupportStore.usesAppStore {
                        Button(store.ticketPrice.map { "Buy one ticket · \($0)" } ?? "Support purchase unavailable") {
                            Task { await store.buyAppStoreTicket() }
                        }
                        .buttonStyle(TechnicalSupportButtonStyle())
                        .disabled(!canBuyTicket)
                        .accessibilityIdentifier("supportBuyAppStoreTicket")
                        if store.ticketPrice == nil && !store.busy {
                            Text("The App Store didn’t return a price. Tap Refresh to check again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Buy one ticket · $9.99") {
                            Task { if let url = await store.macCheckout() { openURL(url) } }
                        }.disabled(!store.canBuy).accessibilityIdentifier("supportBuyMacTicket")
                    }
                    if store.busy { ProgressView("Working…") }
                    if !store.purchasesAvailable && !store.busy {
                        Text("New support purchases are currently unavailable. Your existing tickets and purchased credits remain available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Your support tickets") {
                    if account.tickets.isEmpty {
                        Text("Your requests and conversations will appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(account.tickets) { ticket in
                        Button { Task { await store.open(ticket) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ticket.subject).font(.headline)
                                Text("\(ticket.reference) · \(status(ticket.status))").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("supportTicket-\(ticket.id)")
                    }
                    if account.nextOffset != nil {
                        Button("Load more tickets") { Task { await store.moreTickets() } }.disabled(store.busy)
                    }
                }
            }
            Section {
                Text("All writing features are free. Personal support and tips are optional paid purchases. Bug reports and purchase help do not require a paid ticket.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Your writing stays in your library. Only the text you choose to submit is shared with support.")
                    .font(.caption).foregroundStyle(.secondary)
                StudioExternalLink("Get App Help", destination: InkspringCommunity.support)
                StudioExternalLink("Setup and Troubleshooting", destination: InkspringCommunity.websiteHelp)
                    StudioExternalLink("Send Feedback or Report a Bug", destination: InkspringCommunity.feedback)
                    supportPrivacyLink
            }
            Section("Apple authorization") {
                appleAccountLink
                Text("After deleting your support account, open Apple Account → Sign-In and Security → Sign in with Apple → Inkspring → Stop Using Sign in with Apple to remove Apple’s authorization too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(palette.canvas)
        .accessibilityIdentifier("supportAccountForm")
    }

    private var signInView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "lifepreserver.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(palette.iconAccent)
                        .frame(width: 44, height: 44)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    Text("Personal technical support")
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    ticketCoverage
                        .foregroundStyle(.secondary)
                    if let price = store.ticketPrice {
                        Text("\(price) per ticket · One-time purchase")
                            .font(.callout.weight(.semibold))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in to continue")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Use your Apple account to buy a ticket and follow replies. Hide My Email works too.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if store.available {
                        appleSignInControl
                        if !store.purchasesAvailable {
                            Text("Sign in to follow your existing tickets. New ticket purchases are temporarily unavailable.")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                        }
                    } else if store.busy && !store.configurationLoaded && !store.configurationFailed {
                        ProgressView("Checking support…")
                            .accessibilityIdentifier("supportCheckingConnection")
                    } else {
                        Label(store.configurationFailed ? "Support couldn’t connect" : "Apple sign-in is temporarily unavailable",
                              systemImage: "exclamationmark.circle")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(palette.text)
                            .accessibilityIdentifier("supportConnectionStatus")
                        Text("Try again, or use Get App Help below. Your writing and any purchased tickets are kept.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                        Button("Try again", systemImage: "arrow.clockwise") {
                            Task { await store.load() }
                        }
                        .buttonStyle(TechnicalSupportButtonStyle())
                        .disabled(store.busy)
                        .accessibilityIdentifier("supportRetryConnection")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.primary.opacity(0.12))
                        .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Personal support is optional. Bug reports and purchase help don’t require a paid ticket.")
                        .foregroundStyle(.secondary)
                    Text("Your writing stays in your library. Only what you send in a ticket is shared with support.")
                        .foregroundStyle(.secondary)
                    StudioExternalLink("Get App Help", destination: InkspringCommunity.support)
                StudioExternalLink("Send Feedback or Report a Bug", destination: InkspringCommunity.feedback)
                supportPrivacyLink
                    appleAccountLink
                }
                .font(.callout)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("supportSignInScreen")
    }

    private var supportPrivacyLink: some View {
        supportLink("Support privacy", symbol: "lock.shield", url: InkspringSupportURLs.privacy)
    }

    private var appleAccountLink: some View {
        supportLink("Manage Sign in with Apple", symbol: "apple.logo", url: "https://account.apple.com/account/manage/section/sign-in-and-security")
    }

    private func supportLink(_ title: LocalizedStringKey, symbol: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            StudioLinkOutLabel { Label(title, systemImage: symbol) }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appleSignInControl: some View {
        #if os(macOS) && !STORE_BUILD
        Button { Task { await store.signInInBrowser() } } label: {
            Label(store.busy ? "Connecting…" : "Continue with Apple in Browser", systemImage: "apple.logo")
        }
        .buttonStyle(TechnicalSupportButtonStyle())
        .disabled(!store.available || store.busy)
        .accessibilityIdentifier("supportSignInWithApple")
        #else
        SignInWithAppleButton(.signIn) { request in
            nonce = InkspringSupportStore.nonce()
            request.requestedScopes = [.email]
            request.nonce = InkspringSupportStore.hashedNonce(nonce)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                    store.notice = "Apple sign-in could not finish. Please try again."; return
                }
                Task { await store.signIn(token: token, nonce: nonce) }
            case .failure(let error):
                if (error as? ASAuthorizationError)?.code != .canceled { store.notice = "Apple sign-in could not finish. Please try again." }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .clipShape(Capsule())
        .frame(maxWidth: 340).frame(height: 46)
        .disabled(!store.available || store.busy)
        .accessibilityIdentifier("supportSignInWithApple")
        #endif
    }

    private var canBuyTicket: Bool {
        return store.canBuy
    }
    private func status(_ value: String) -> String {
        switch value {
        case "in_progress": return "In progress"
        case "waiting_for_customer": return "Your reply needed"
        case "resolved": return "Resolved"
        default: return "Waiting for support"
        }
    }
    private func conversation(_ ticket: InkspringSupportTicket) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("All tickets", systemImage: "chevron.left") { store.selectedTicketID = nil }
                        .accessibilityIdentifier("supportAllTickets")
                    Spacer()
                    Menu {
                        if ticket.status != "resolved" {
                            Button("Mark as resolved", systemImage: "checkmark.circle") {
                                Task { await store.resolveTicket(ticket) }
                            }
                        }
                        Button("Delete conversation…", systemImage: "trash", role: .destructive) { ticketToDelete = ticket }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .accessibilityLabel("Ticket actions")
                    .accessibilityIdentifier("supportTicketActions")
                    .disabled(store.busy)
                }
                Text(ticket.subject).font(.title3.bold())
                Text("\(ticket.reference) · \(status(ticket.status))").font(.caption).foregroundStyle(.secondary)
                Label("Private conversation with Inkspring Support", systemImage: "person.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
            if submittedTicketID == ticket.id {
                Label("Your request was sent to Protomota. Check this ticket or your Apple account email for confirmation.",
                      systemImage: "checkmark.circle")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding()
                    .accessibilityIdentifier("supportRequestSent")
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.hasEarlierMessages {
                            Button("Load earlier messages") { Task { await store.earlierMessages() } }.disabled(store.busy)
                        }
                        ForEach(store.messages) { message in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(message.senderRole == "support" ? "Inkspring Support" : "You").font(.caption.bold())
                                Text(message.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.accent.opacity(message.senderRole == "support" ? 0.45 : 0.25)))
                            .frame(maxWidth: .infinity, alignment: message.senderRole == "support" ? .leading : .trailing)
                            .id(message.id)
                        }
                    }.padding()
                }
                .onChange(of: store.messages.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            Divider()
            if ticket.status == "resolved" {
                Label("This ticket is resolved. You can still read the conversation.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("supportResolvedTicket")
            } else {
                replyComposer(ticket)
            }
        }
    }
    private func replyComposer(_ ticket: InkspringSupportTicket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                Text("Reply in this ticket").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { store.replyDrafts[ticket.id] ?? "" }, set: { store.replyDrafts[ticket.id] = String($0.prefix(10000)) }))
                    .frame(minHeight: 70, maxHeight: 110).padding(6)
                    .scrollContentBackground(.hidden)
                    .studioSurface(StudioRadius.control, fill: palette.panel)
                    .disabled(store.busy).accessibilityIdentifier("supportReplyText")
                HStack {
                    Text("Replies stay with this issue.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Send reply", systemImage: "paperplane.fill") { Task { await store.reply() } }
                        .buttonStyle(TechnicalSupportButtonStyle())
                        .disabled(store.busy || (store.replyDrafts[ticket.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ticket.canReply)
                        .accessibilityIdentifier("supportSendReply")
                }
        }.padding()
    }
    @State private var subject = ""
    @State private var topic = "MCP setup"
    @State private var requestBody = ""
    private func newRequest(showCelebration: Bool) -> some View {
        NavigationStack {
            Form {
                if showCelebration {
                    Section { SupportTicketReadyHeader() }
                }
                Section {
                    if let email = store.account?.user.email {
                        LabeledContent("Apple contact email", value: email)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("supportAppleContact")
                    }
                    Text("One ticket covers one Inkspring issue across Mac, iPhone, and iPad, with follow-up replies in this conversation.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Your request") {
                    TextField("Subject", text: $subject).onChange(of: subject) { _, value in subject = String(value.prefix(140)) }
                    Picker("Topic", selection: $topic) {
                        ForEach(["MCP setup", "Writing and publishing", "iCloud sync", "Another Inkspring issue"], id: \.self) { Text($0) }
                    }
                    TextEditor(text: $requestBody).frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .studioSurface(StudioRadius.control, fill: palette.panel)
                        .onChange(of: requestBody) { _, value in requestBody = String(value.prefix(10000)) }
                        .accessibilityIdentifier("supportRequestText")
                    Text("Describe what you tried and what happened. Your device and Inkspring version help too. Drafts, notes, and media are never attached automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Send support request") {
                        Task { await store.openRequest(subject: subject, topic: topic, message: requestBody) }
                    }
                    .disabled(store.busy || store.unusedPurchases.isEmpty || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("supportSubmitRequest")
                }
                if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(palette.canvas).navigationTitle("New support request")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestPresentation = nil }
                        .buttonStyle(.plain)
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 620)
        #endif
    }
}

private struct SupportTicketReadyHeader: View {
    @State private var revealID: UUID?

    var body: some View {
        VStack(spacing: 10) {
            InkspringSupporterEmblem(animationID: revealID)
            Text("Your support ticket is ready").font(.title3.bold())
                .accessibilityIdentifier("supportTicketReady")
            Text("Send your request below. We’ll email confirmation to your Apple account address.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Inkspring Supporter")
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("supportTicketBadge")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .task {
            guard revealID == nil else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            revealID = UUID()
        }
    }
}

private struct TechnicalSupportButtonStyle: ButtonStyle {
    @Environment(\.studioPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .labelStyle(StudioIconLabelStyle(muted: !enabled))
            .foregroundStyle(enabled ? palette.text : palette.disabledText)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .opacity(configuration.isPressed ? 0.75 : 1)
        if palette.theme == .paper {
            label.studioPaperControl(in: Capsule(), fill: enabled && configuration.isPressed ? palette.hover : palette.control)
        } else if #available(iOS 26, *), enabled, !reduceTransparency {
            label.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            label.background(enabled ? palette.control : palette.well, in: Capsule())
                .overlay { Capsule().strokeBorder(palette.line).allowsHitTesting(false) }
        }
    }
}
