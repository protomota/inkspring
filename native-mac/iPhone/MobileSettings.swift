import SwiftUI

struct MobileSettingsView: View {
    @Binding var theme: StudioTheme
    let library: MobileLibrary
    let openSetup: () -> Void

    @Environment(\.studioPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var generationStatus: String?
    @Environment(\.mobileWideLayout) private var wideLayout

    private var settingsBackground: Color {
        palette.theme == .light ? Color(.sRGB, red: 237.0 / 255, green: 240.0 / 255, blue: 243.0 / 255) : palette.canvas
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach([StudioTheme.paper, .graphite, .light, .system]) { choice in
                        themeRow(choice)
                    }
                } header: {
                    Text("Appearance").foregroundStyle(palette.muted)
                }
                .listRowBackground(palette.card)

                Section {
                    Button(action: openSetup) { supportRow("Getting started", icon: "desktopcomputer", external: false) }
                        .accessibilityIdentifier("settings.gettingStarted")
                }.listRowBackground(palette.card)

                syncSection

                Section {
                    if let code = library.syncErrorCode {
                        LabeledContent("Error code", value: code)
                            .textSelection(.enabled)
                    }
                    ShareLink(item: syncDiagnostics) {
                        supportRow("Share Sync Diagnostics", icon: "square.and.arrow.up", external: false)
                    }
                    .accessibilityIdentifier("settings.shareSyncDiagnostics")
                } header: {
                    Text("Diagnostics").foregroundStyle(palette.muted)
                } footer: {
                    Text("Includes sync status and timestamps. Your drafts, notes, and account details are not included.")
                        .foregroundStyle(palette.muted)
                }
                .listRowBackground(palette.card)

                Section {
                    InkspringTechnicalSupportButton()
                    Link(destination: InkspringCommunity.websiteHelp) {
                        supportRow("Setup and Troubleshooting", icon: "book")
                    }
                } header: {
                    Text("Support").foregroundStyle(palette.muted)
                } footer: {
                    Text("Free personal help with Inkspring on Mac, iPhone, and iPad, including desktop setup and MCP connections.")
                        .foregroundStyle(palette.muted)
                }
                .listRowBackground(palette.card)

                Section {
                    ShareLink(item: InkspringCommunity.website) {
                        supportRow("Share Inkspring", icon: "square.and.arrow.up", external: false)
                    }
                    Link(destination: InkspringCommunity.feedback) {
                        supportRow("Send Feedback", icon: "bubble.left.and.bubble.right")
                    }
                    Link(destination: InkspringCommunity.apps) {
                        supportRow("More Free Apps by Protomota", icon: "arrow.up.forward.app")
                    }
                } header: {
                    Text("Support Inkspring").foregroundStyle(palette.muted)
                }
                .listRowBackground(palette.card)

                Section {
                    HStack(alignment: .center, spacing: 14) {
                        Image("InkspringBrand")
                            .resizable().scaledToFit().frame(width: 52, height: 52)
                            .clipShape(.rect(cornerRadius: 12))
                            .shadow(color: palette.colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12), radius: 6, y: 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inkspring").font(.headline).foregroundStyle(palette.text)
                            Text("Your private writing studio.")
                                .font(.subheadline).foregroundStyle(palette.muted)
                        }
                    }
                    .padding(.vertical, 6)
                    Text("Version \(appVersion) (\(appBuild))")
                        .foregroundStyle(palette.muted)
                        .accessibilityIdentifier("settingsAppVersion")
                    protomotaProductPill
                } header: {
                    Text("About").foregroundStyle(palette.muted)
                }
                .listRowBackground(palette.card)

                Section("Product updates") {
                    Link(destination: InkspringCommunity.newsletter) {
                        supportRow("Protomota newsletter", icon: "envelope")
                    }
                }
                .listRowBackground(palette.card)

                Section {
                    Label(generationStatus ?? "On-device idea generation is available.",
                          systemImage: "sparkles")
                } header: {
                    Text("Apple Intelligence").foregroundStyle(palette.muted)
                }
                .listRowBackground(palette.card)
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 700)
            .mobileCanvas(background: settingsBackground)
            .mobilePageTitle("Settings", wide: wideLayout, background: settingsBackground)
            .toolbar(wideLayout ? .hidden : .visible, for: .tabBar)
        }
        .onAppear { generationStatus = MobileIdeasView.generationAvailabilityMessage }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { generationStatus = MobileIdeasView.generationAvailabilityMessage }
        }
    }

    private func supportRow(_ title: String, icon: String, external: Bool = true) -> some View {
        HStack {
            Label {
                Text(title).foregroundStyle(palette.text)
            } icon: {
                Image(systemName: icon).foregroundStyle(palette.iconAccent)
            }
            Spacer(minLength: 12)
            if external {
                StudioExternalArrow()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var protomotaProductPill: some View {
        Link(destination: URL(string: "https://protomota.com/")!) {
            HStack(spacing: 8) {
                Image("ProtomotaLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text("A Protomota Product")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.medium))
                    .accessibilityHidden(true)
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .frame(minHeight: 44)
            .foregroundStyle(.white)
            .background(.black, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.14)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.protomotaProduct")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var syncDiagnostics: String {
        var lines = [
            "Inkspring \(appVersion) (\(appBuild))",
            "Apple Account: \(library.accountStatus)",
            "Mac workspace: \(workspaceStatus)",
            "Last check: \(timestamp(library.lastCheck))",
            "Last iCloud response: \(timestamp(library.lastCloudContact))",
            "Mac snapshot: \(timestamp(library.snapshot?.updatedAt))"
        ]
        if let status = library.newsletterSyncSummary { lines.append("Newsletter sync: \(status)") }
        if let code = library.syncErrorCode { lines.append("Error code: \(code)") }
        return lines.joined(separator: "\n")
    }

    private var syncSection: some View {
        Section {
            LabeledContent("Apple Account", value: library.accountStatus)
                .accessibilityIdentifier("settings.libraryStatus")
            LabeledContent("Mac workspace", value: workspaceStatus)
            if let status = library.newsletterSyncSummary {
                LabeledContent("Newsletter sync", value: status)
                    .accessibilityIdentifier("settings.newsletterSync")
            }
            LabeledContent("Last check", value: timestamp(library.lastCheck))
            LabeledContent("Last iCloud response", value: timestamp(library.lastCloudContact))
            if let snapshot = library.snapshot {
                LabeledContent("Mac snapshot", value: timestamp(snapshot.updatedAt))
            }
            if let error = library.error {
                Text(error).foregroundStyle(palette.muted)
            } else if library.remoteWorkspaceFound == false {
                Text("iCloud has no workspace from your Mac yet. Open Inkspring on your Mac and check Settings → Storage & backups.")
                    .foregroundStyle(palette.muted)
            }
            Button {
                Task { await library.refresh() }
            } label: {
                if library.busy {
                    ProgressView {
                        Text("Checking iCloud…").foregroundStyle(palette.text)
                    }
                } else {
                    Label {
                        Text("Check Now").foregroundStyle(palette.text)
                    } icon: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(palette.iconAccent)
                    }
                }
            }
            .disabled(library.busy)
            .accessibilityIdentifier("settings.checkSync")
        } header: {
            Text("iCloud Sync").foregroundStyle(palette.muted)
        }
        .listRowBackground(palette.card)
    }

    private var workspaceStatus: String {
        switch library.remoteWorkspaceFound {
        case true?: "Found"
        case false?: "Waiting for Mac"
        case nil: "Not checked"
        }
    }

    private func timestamp(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "—"
    }

    private func themeRow(_ choice: StudioTheme) -> some View {
        Button {
            theme = choice
        } label: {
            HStack(spacing: 13) {
                themePreview(choice)
                    .accessibilityHidden(true)
                Text(choice.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                if theme == choice {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.iconAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(theme == choice ? .isSelected : [])
        .accessibilityIdentifier("theme.\(choice.rawValue)")
    }

    @ViewBuilder private func themePreview(_ choice: StudioTheme) -> some View {
        if choice == .system {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(palette.text)
                .frame(width: 58, height: 35)
                .studioSurface(6, fill: palette.well)
        } else {
            let swatch = StudioPalette(theme: choice)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(swatch.iconAccent).frame(width: 19, height: 3)
                RoundedRectangle(cornerRadius: 3)
                    .fill(swatch.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(swatch.line)
                    }
            }
            .padding(6)
            .frame(width: 58, height: 35)
            .background(swatch.canvas, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(swatch.line) }
        }
    }
}

extension View {
    func mobileCanvas(background: Color? = nil) -> some View {
        modifier(MobileCanvas(background: background))
    }
}

private struct MobileCanvas: ViewModifier {
    @Environment(\.studioPalette) private var palette
    let background: Color?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { (background ?? palette.canvas).ignoresSafeArea() }
    }
}
