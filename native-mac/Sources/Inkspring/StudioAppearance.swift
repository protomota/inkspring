import SwiftUI
#if os(macOS)
import InkspringSchedule
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct XArticleChoice: Identifiable {
    let id: String
    let title: String
}

struct StudioXPostEditor: View {
    @Environment(\.studioPalette) private var palette
    @Binding var text: String
    @Binding var format: String
    var articles: [XArticleChoice] = []
    var openingLimit = 280
    @State private var editingPart: Int?

    private var posts: [String] {
        format == "post" ? [text] : XThreadText.parts(in: text)
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) { controls }
        #else
        if let index = editingPart, posts.indices.contains(index) {
            MobileXReplyEditor(text: part(index), identifier: "x.postText.\(index)", count: XThreadText.weight(posts[index]), back: { editingPart = nil })
                .id(index)
        } else { ScrollView { VStack(alignment: .leading, spacing: 16) { controls }.padding(12) } }
        #endif
    }

    @ViewBuilder private var controls: some View {
            Picker("X post type", selection: Binding(get: { format }, set: changeFormat)) {
                ForEach(XPostStyle.allCases) { style in
                    Text(style.title).tag(style.rawValue)
                        .disabled(posts.contains { XReplyArticle($0).reference != nil } &&
                                  (style.rawValue == "post" || (style.rawValue == "followup" && posts.count > 2)))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("x.postType")
            ForEach(posts.indices, id: \.self) { index in
                let title = index == 0 ? "Opening post" : "Follow-up reply \(index)"
                #if os(iOS)
                Button { editingPart = index } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(part(index).wrappedValue.isEmpty ? "Write this post…" : part(index).wrappedValue)
                            .font(.body).lineLimit(3).foregroundStyle(palette.text)
                        counter(posts[index], limit: index == 0 ? openingLimit : 280)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.buttonStyle(.plain)
                .accessibilityIdentifier("x.editPost.\(index)")
                #else
                MacReplyWritingField(title: title, text: part(index),
                    identifier: "x.postText.\(index)", count: counter(posts[index], limit: index == 0 ? openingLimit : 280))
                #endif
                if index > 0 {
                    let link = XReplyArticle(posts[index])
                    if !articles.isEmpty || link.reference != nil {
                        Menu {
                            ForEach(articles) { article in
                                Button(article.title + " · " + article.id) { setArticle(article.id, at: index) }
                            }
                            if link.reference != nil { Button("Unlink article") { setArticle(nil, at: index) } }
                        } label: {
                            Label(link.reference.map { ref in articles.first { $0.id == ref }?.title ?? ref } ?? "Link X article", systemImage: "link")
                        }
                    }
                    Button("Remove reply", role: .destructive) { remove(index) }
                }
            }
            Button("Add follow-up reply", systemImage: "plus") {
                let parts = posts + [""]
                text = parts.joined(separator: XThreadText.separator)
                format = parts.count == 2 ? "followup" : "thread"
            }
            .disabled(posts.count >= XThreadText.limit || posts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
            .accessibilityIdentifier("x.addReply")
    }

    private func counter(_ post: String, limit: Int) -> some View {
        let weight = XThreadText.weight(post)
        return Text("\(weight)/\(limit)").font(.caption).foregroundStyle(weight > limit ? palette.danger : palette.muted)
    }

    private func part(_ index: Int) -> Binding<String> {
        Binding(get: { posts.indices.contains(index) ? XReplyArticle(posts[index]).copy : "" }, set: { value in
            var values = posts
            guard values.indices.contains(index) else { return }
            values[index] = XReplyArticle.attach(XReplyArticle(values[index]).reference, to: value)
            text = format == "post" ? value : values.joined(separator: XThreadText.separator)
        })
    }

    private func setArticle(_ reference: String?, at index: Int) {
        var values = posts
        guard values.indices.contains(index) else { return }
        values[index] = XReplyArticle.attach(reference, to: XReplyArticle(values[index]).copy)
        text = values.joined(separator: XThreadText.separator)
    }

    private func changeFormat(_ value: String) {
        guard value != format else { return }
        var values = format == "post" ? [XThreadText.singlePost(text)] : posts
        if value == "post" {
            text = values.joined(separator: "\n")
        } else {
            if value == "followup", values.count > 2 { values = [values[0], values.dropFirst().joined(separator: "\n")] }
            while values.count < (value == "followup" ? 2 : 3) { values.append("") }
            text = values.joined(separator: XThreadText.separator)
        }
        format = value
    }

    private func remove(_ index: Int) {
        var values = posts
        guard values.indices.contains(index) else { return }
        values.remove(at: index)
        text = values.joined(separator: XThreadText.separator)
        format = values.count == 1 ? "post" : values.count == 2 ? "followup" : "thread"
    }
}

struct StudioCopyReference: View {
    @Environment(\.studioPalette) private var palette
    let reference: String
    @State private var copiedReference: String?

    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(reference, forType: .string) else { return }
            #else
            UIPasteboard.general.string = reference
            #endif
            copiedReference = reference
        } label: {
            Label {
                Text(reference).monospaced()
            } icon: {
                Image(systemName: copiedReference == reference ? "checkmark" : "doc.on.doc")
            }
        }
        #if os(macOS)
        .buttonStyle(StudioActionStyle())
        #else
        .buttonStyle(.bordered)
        .tint(palette.accent)
        #endif
        .accessibilityLabel(copiedReference == reference ? "Copied \(reference)" : "Copy ID \(reference)")
        .accessibilityIdentifier("content.copyID")
        #if os(macOS)
        .help("Copy ID \(reference)")
        #endif
    }
}

enum StudioTheme: String, CaseIterable, Identifiable {
    case graphite
    case paper = "warm-paper"
    case light = "native-light"
    case system

    static let preferenceKey = "theme"
    static let defaultPreference: Self = .paper
    var id: Self { self }

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .paper: "Warm Paper"
        case .light: "Native Light"
        case .system: "Match System"
        }
    }

    init(preference: Any?) {
        self = (preference as? String).flatMap(Self.init(rawValue:)) ?? Self.defaultPreference
    }

    func resolve(for colorScheme: ColorScheme) -> Self {
        self == .system ? (colorScheme == .dark ? .graphite : .light) : self
    }
}

/// OpenTalon's appearance colors, with Inkspring's editorial type kept in InkspringTypography.
struct StudioPalette {
    let theme: StudioTheme
    var dark: Bool { theme == .graphite }
    var colorScheme: ColorScheme { dark ? .dark : .light }

    var canvas: Color { shade(0xf5f2ec, 0x141518, 0xfafbfc) }
    var sidebar: Color { shade(0xeae3d9, 0x101114, 0xeef0f3) }
    var card: Color { shade(0xfffdf9, 0x202125, 0xffffff) }
    var panel: Color { shade(0xfaf7f1, 0x191a1e, 0xffffff) }
    var text: Color { shade(0x2b2723, 0xf1f1f3, 0x1b1d21) }
    var muted: Color { shade(0x746b61, 0xa8aab0, 0x6c717a) }
    var disabledText: Color { shade(0x61574e, 0xa8aab0, 0x606570) }
    var scrollThumb: Color { shade(0x927969, 0x767985, 0x76818f) }
    var line: Color { shade(0xded7cc, 0x303136, 0xe0e3e8) }
    var well: Color { shade(0xece6dc, 0x18191d, 0xf0f2f5) }
    var control: Color { theme == .paper ? well : card }
    var hover: Color { shade(0xe4dacd, 0x24252b, 0xe4e7ec) }
    var active: Color { shade(0xe7cdbb, 0x303139, 0xdde1e7) }
    var accent: Color { shade(0xb9603a, 0xe4e5ea, 0x202328) }
    // Match OpenTalon's action colors for native themes.
    var iconAccent: Color { shade(0xb9603a, 0x61d9e3, 0x056370) }
    var primaryAction: Color { shade(0xa94d28, 0x61d9e3, 0x056370) }
    var accentText: Color { shade(0xfffdf9, 0x1e1f25, 0xffffff) }
    var danger: Color { shade(0xb44036, 0xf18d85, 0xba413a) }
    var success: Color { shade(0x356641, 0x87c697, 0x246b45) }

    private func shade(_ paper: UInt32, _ graphite: UInt32, _ light: UInt32) -> Color {
        Color(studioRGB: theme == .paper ? paper : dark ? graphite : light)
    }

    func project(_ hex: String) -> Color {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return accent }
        return Color(studioRGB: rgb)
    }
}

private extension Color {
    init(studioRGB rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

private struct StudioPaletteKey: EnvironmentKey {
    static let defaultValue = StudioPalette(theme: .paper)
}

extension EnvironmentValues {
    var studioPalette: StudioPalette {
        get { self[StudioPaletteKey.self] }
        set { self[StudioPaletteKey.self] = newValue }
    }
}

struct StudioNewIdeaButton: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let action: () -> Void

    var body: some View {
        Button(action: action) { surface }
            .buttonStyle(.plain)
            .accessibilityLabel("Draft a new idea")
            .accessibilityIdentifier("idea.new")
    }

    @ViewBuilder private var surface: some View {
        let icon = Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.primaryAction)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        if #available(macOS 26, iOS 26, *), !reduceTransparency {
            icon.glassEffect(.regular.tint(palette.primaryAction.opacity(0.38)).interactive(), in: .circle)
        } else {
            icon.background(palette.primaryAction.opacity(0.12), in: Circle())
                .overlay { Circle().strokeBorder(palette.primaryAction.opacity(0.35)).allowsHitTesting(false) }
        }
    }
}

enum StudioRadius {
    static let row: CGFloat = 8
    static let control: CGFloat = 10
    static let card: CGFloat = 14
}

struct PlatformMark: View {
    let name: String
    var fallback = "link"

    private static func assetURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name.lowercased(), withExtension: "png", subdirectory: "PlatformIcons")
    }

    static func image(_ name: String) -> Image? {
        if name.lowercased() == "x-article" { return image("x") }
        if name.lowercased() == "youtube" { return Image(systemName: "play.rectangle.fill") }
#if os(macOS)
        guard let url = assetURL(name), let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = true
        return Image(nsImage: image)
#else
        return bitmap(name).map { Image(uiImage: $0).renderingMode(.template) }
#endif
    }

#if os(iOS)
    static func bitmap(_ name: String) -> UIImage? {
        assetURL(name).flatMap { UIImage(contentsOfFile: $0.path) }
    }
#endif

    static func markScale(for name: String) -> CGFloat {
        switch name.lowercased() {
        case "claude-mark": 1.5 // The asset includes transparent padding around the starburst.
        case "gemini": 1.15 // Match the visual weight of the OpenAI mark.
        default: 1
        }
    }

    var body: some View {
        (Self.image(name) ?? Image(systemName: fallback))
            .resizable().scaledToFit()
            .frame(width: 14, height: 14)
            .scaleEffect(Self.markScale(for: name))
            // Align the base of the LinkedIn wordmark with the adjacent text.
            .offset(y: name.lowercased() == "linkedin" ? -3 : 0)
            .accessibilityHidden(true)
    }
}

struct StudioPlatformLabel: View {
    let name: String
    let title: String
    var iconOffset: CGFloat = 0

    var body: some View {
        Label { Text(title) } icon: {
            PlatformMark(name: name, fallback: name == "news" ? "newspaper" : "link")
                .offset(y: iconOffset)
        }
    }
}

struct StudioIconLabelStyle: LabelStyle {
    @Environment(\.studioPalette) private var palette
    var inverted = false
    var muted = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(muted ? palette.disabledText : inverted ? palette.accentText : palette.iconAccent)
            configuration.title
                .foregroundStyle(muted ? palette.disabledText : inverted ? palette.accentText : palette.text)
        }
    }
}

struct StudioExternalArrow: View {
    @Environment(\.studioPalette) private var palette

    var body: some View {
        Image(systemName: "arrow.up.right")
            .font(.caption.weight(.medium))
            .foregroundStyle(palette.iconAccent)
            .accessibilityHidden(true)
    }
}

struct StudioLinkOutLabel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 7) {
            content()
            StudioExternalArrow()
        }
        .accessibilityElement(children: .combine)
    }
}

struct StudioExternalLink: View {
    let title: String
    let destination: URL

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            StudioLinkOutLabel { Text(title) }
        }
    }
}

extension View {
#if os(macOS)
    func studioAppearance(_ palette: StudioPalette) -> some View {
        self
            .font(InkspringTypography.interface(14))
            .foregroundStyle(palette.text, palette.muted)
            .tint(palette.accent)
            .labelStyle(StudioIconLabelStyle())
            .buttonStyle(StudioActionStyle())
            .toggleStyle(StudioToggleStyle())
            .menuStyle(.borderlessButton)
            .groupBoxStyle(StudioGroupStyle())
            .environment(\.studioPalette, palette)
            .environment(\.colorScheme, palette.colorScheme)
    }

    func studioPage() -> some View {
        self
            .frame(maxWidth: 1344, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    func studioGlassControl(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(StudioControlGlass(tint: tint, interactive: interactive))
    }

    func studioInput() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(StudioControlGlass(interactive: false, isInput: true))
    }
#endif

    func studioSurface(_ radius: CGFloat = StudioRadius.card, fill: Color? = nil) -> some View {
        modifier(StudioSurface(radius: radius, fill: fill))
    }

    func studioPaperControl<S: InsettableShape>(in shape: S, fill: Color) -> some View {
        modifier(StudioPaperControl(shape: shape, fill: fill))
    }
}

private struct StudioPaperControl<S: InsettableShape>: ViewModifier {
    @Environment(\.studioPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let fill: Color

    func body(content: Content) -> some View {
        content.background {
            shape.fill(fill)
                .overlay {
                    if !reduceTransparency {
                        shape.fill(.linearGradient(colors: [palette.card.opacity(0.20), .clear],
                                                   startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay { shape.strokeBorder(palette.line) }
        }
    }
}

private struct StudioSurface: ViewModifier {
    @Environment(\.studioPalette) private var palette
    let radius: CGFloat
    let fill: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill ?? palette.card, in: shape)
            .overlay { shape.strokeBorder(palette.line).allowsHitTesting(false) }
    }
}

#if os(macOS)
struct StudioRule: View {
    @Environment(\.studioPalette) private var palette
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(palette.line)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
struct StudioActionStyle: ButtonStyle {
    static let standardHeight: CGFloat = 30
    @Environment(\.studioPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var prominent = false
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let emphasized = prominent && !destructive
        let usesAccent = emphasized && enabled
        configuration.label
            .labelStyle(StudioIconLabelStyle(inverted: usesAccent, muted: !enabled))
            .font(InkspringTypography.interface(13).weight(emphasized ? .semibold : .medium))
            .padding(.horizontal, fillsWidth ? 14 : emphasized ? 15 : 12)
            .frame(maxWidth: fillsWidth ? .infinity : nil,
                   minHeight: fillsWidth ? 36 : prominent ? 35 : Self.standardHeight, alignment: .leading)
            .fixedSize(horizontal: !fillsWidth, vertical: false)
            .foregroundStyle(!enabled ? palette.disabledText : usesAccent ? palette.accentText : destructive ? palette.danger : palette.text)
            .modifier(StudioActionSurface(
                tint: usesAccent ? palette.primaryAction : nil,
                fill: !enabled ? palette.well : usesAccent ? palette.primaryAction : configuration.isPressed ? palette.hover : palette.control,
                line: palette.line, interactive: enabled, reduceTransparency: reduceTransparency || !enabled
            ))
            .contentShape(Capsule())
            .opacity(enabled && configuration.isPressed ? 0.82 : 1)
    }
}

struct StudioIconButtonStyle: ButtonStyle {
    @Environment(\.studioPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    var size: CGFloat = StudioActionStyle.standardHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(enabled ? palette.iconAccent : palette.disabledText)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: size, height: size)
            .fixedSize()
            .studioGlassControl()
            .contentShape(Circle())
            .opacity(enabled && configuration.isPressed ? 0.82 : 1)
    }
}

struct StudioMoreMenu<Actions: View>: View {
    let title: String
    var size: CGFloat = StudioActionStyle.standardHeight
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Menu(content: actions) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(StudioIconButtonStyle(size: size))
        .fixedSize()
        .accessibilityLabel(title)
        .help(title)
    }
}

struct StudioSearchField: View {
    @Environment(\.studioPalette) private var palette
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.iconAccent)
                .accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(title).foregroundStyle(palette.muted))
                .textFieldStyle(.plain)
                .foregroundStyle(palette.text)
        }
        .font(InkspringTypography.interface(13))
        .padding(.horizontal, 12)
        .frame(minHeight: StudioActionStyle.standardHeight)
        .modifier(StudioControlGlass(interactive: false, isInput: true))
        .overlay { Capsule().strokeBorder(palette.muted.opacity(0.32)).allowsHitTesting(false) }
    }
}

private struct StudioControlGlass: ViewModifier {
    @Environment(\.studioPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var tint: Color?
    var interactive = true
    var isInput = false

    func body(content: Content) -> some View {
        let base = isInput && palette.theme == .paper ? palette.panel : palette.control
        return content.modifier(StudioActionSurface(tint: enabled ? tint : nil, fill: enabled ? tint ?? base : palette.well,
                                             line: palette.line, interactive: interactive && enabled,
                                             reduceTransparency: reduceTransparency || !enabled))
    }
}

private struct StudioActionSurface: ViewModifier {
    @Environment(\.studioPalette) private var palette
    let tint: Color?
    let fill: Color
    let line: Color
    let interactive: Bool
    let reduceTransparency: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if palette.theme == .paper {
            content.studioPaperControl(in: Capsule(), fill: fill)
        } else if #available(macOS 26, *), !reduceTransparency {
            if let tint {
                // Keep the button's color behind its label when an inactive window clears glass tint.
                content
                    .background(tint, in: Capsule())
                    .glassEffect(.regular.interactive(interactive), in: .capsule)
            } else {
                content.glassEffect(.regular.interactive(interactive), in: .capsule)
            }
        } else {
            content.background(fill, in: Capsule())
                .overlay { Capsule().strokeBorder(line).allowsHitTesting(false) }
        }
    }
}

private struct StudioToggleStyle: ToggleStyle {
    @Environment(\.studioPalette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(!enabled ? palette.disabledText : configuration.isOn ? palette.iconAccent : palette.muted)
                configuration.label
            }
        }
        .buttonStyle(StudioActionStyle())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct StudioRowStyle: ButtonStyle {
    @Environment(\.studioPalette) private var palette
    var selected = false
    var indicator = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected, indicator: indicator, palette: palette)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let indicator: Bool
        let palette: StudioPalette
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(selected ? palette.active : hovering || configuration.isPressed ? palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: StudioRadius.row, style: .continuous))
                .overlay(alignment: .leading) {
                    if selected && indicator {
                        Capsule().fill(palette.accent).frame(width: 2, height: 17)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

struct StudioGroupStyle: GroupBoxStyle {
    @Environment(\.studioPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(InkspringTypography.interface(14).weight(.semibold))
                .foregroundStyle(palette.text)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .studioSurface()
    }
}

struct StudioFilterMenu<Choices: View>: View {
    @Environment(\.studioPalette) private var palette
    let title: String
    let value: String
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        Menu(content: choices) {
            HStack(spacing: 8) {
                Text(value).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(palette.muted)
                    .accessibilityHidden(true)
            }
            .font(InkspringTypography.interface(13))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .frame(minHeight: StudioActionStyle.standardHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(palette.text)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .frame(minHeight: StudioActionStyle.standardHeight)
        .studioGlassControl()
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct StudioChoicePicker<Value: Hashable>: View {
    @Environment(\.studioPalette) private var palette
    @State private var showingChoices = false
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var icon: ((Value) -> Image?)? = nil

    var body: some View {
        if let icon {
            Button { showingChoices.toggle() } label: {
                HStack(spacing: 7) {
                    choiceLabel(selection, icon: icon(selection))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.muted)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(label(selection))
            .popover(isPresented: $showingChoices, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection = option
                            showingChoices = false
                        } label: {
                            HStack(spacing: 8) {
                                choiceLabel(option, icon: icon(option))
                                Spacer(minLength: 12)
                                if selection == option {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.iconAccent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(StudioRowStyle(selected: selection == option))
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                    }
                }
                .font(InkspringTypography.interface(13))
                .padding(6)
                .frame(minWidth: 126)
                .fixedSize(horizontal: true, vertical: false)
                .background(palette.card, in: RoundedRectangle(cornerRadius: StudioRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: StudioRadius.control)
                        .strokeBorder(palette.scrollThumb.opacity(0.55))
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(palette.dark ? 0.5 : 0.24), radius: 8, x: 0, y: 4)
                .padding(8)
                .studioAppearance(palette)
            }
        } else {
            StudioFilterMenu(title: title, value: label(selection)) {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in Text(label(option)).tag(option) }
                }
                .pickerStyle(.inline)
            }
        }
    }

    private func choiceLabel(_ option: Value, icon: Image?) -> some View {
        HStack(spacing: 7) {
            if let icon {
                icon.resizable().scaledToFit().frame(width: 14, height: 14)
                    .foregroundStyle(palette.iconAccent)
                    .accessibilityHidden(true)
            }
            Text(label(option))
        }
    }
}

struct StudioLabeledChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var icon: ((Value) -> Image?)? = nil

    var body: some View {
        HStack {
            Text(title).accessibilityHidden(true)
            Spacer(minLength: 12)
            StudioChoicePicker(title: title, selection: $selection, options: options, label: label, icon: icon)
        }
    }
}

struct StudioSegmentedControl<Value: Hashable, SegmentLabel: View>: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight
    @Binding var selection: Value
    let options: [Value]
    @ViewBuilder let label: (Value) -> SegmentLabel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    label(option)
                        .font(InkspringTypography.interface(13).weight(selection == option ? .semibold : .medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 28)
                        .background {
                            if selection == option {
                                Capsule().fill(palette.active)
                                    .overlay { Capsule().strokeBorder(palette.muted.opacity(0.45)) }
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(3)
        .studioGlassControl(interactive: false)
        .fixedSize()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
    }
}

struct StudioDateTimePicker: View {
    @Binding var selection: Date
    var includesMinute = true
    var includesFiveMinuteShortcut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if includesFiveMinuteShortcut {
                Button("In 5 minutes", systemImage: "clock") { selection = PostScheduling.fiveMinutesFromNow() }
                    .help("Select a time at least five minutes from now, rounded up to the next minute.")
            }
            StudioScheduleCalendar(selection: $selection)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .studioSurface()
            StudioLabeledChoice(title: "Hour", selection: component(.hour), options: Array(0..<24), label: hourLabel)
            if includesMinute {
                StudioLabeledChoice(title: "Minute", selection: component(.minute), options: Array(0..<60),
                                    label: { String(format: "%02d", $0) })
            }
            Text("Time zone: \(TimeZone.current.identifier)")
                .font(InkspringTypography.interface(11))
                .foregroundStyle(.secondary)
        }
    }

    private func component(_ component: Calendar.Component) -> Binding<Int> {
        Binding(get: { Calendar.current.component(component, from: selection) }, set: { value in
            let calendar = Calendar.current
            var parts = calendar.dateComponents([.hour, .minute], from: selection)
            if component == .hour { parts.hour = value } else { parts.minute = value }
            if let date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0,
                                        of: selection, matchingPolicy: .strict),
               calendar.isDate(date, inSameDayAs: selection) {
                selection = date
            }
        })
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: hour))!
        return date.formatted(.dateTime.hour())
    }
}

private struct StudioScheduleCalendar: View {
    @Environment(\.studioPalette) private var palette
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Binding var selection: Date
    @State private var shownDate: Date?
    @FocusState private var focusedDay: Date?

    private var month: DateInterval? { calendar.dateInterval(of: .month, for: shownDate ?? selection) }
    private var today: Date { calendar.startOfDay(for: .now) }

    var body: some View {
        if let month {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(month.start.formatted(.dateTime.month(.wide).year().locale(locale)))
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    monthButton("Previous month", icon: "chevron.left") { moveMonth(-1) }
                        .disabled(month.contains(today))
                    monthButton("Today", icon: "circle") { choose(today) }
                    monthButton("Next month", icon: "chevron.right") { moveMonth(1) }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(27), spacing: 3), count: 7), spacing: 2) {
                    let weekdays = calendar.veryShortStandaloneWeekdaySymbols
                    ForEach(0..<7, id: \.self) { offset in
                        Text(weekdays[(calendar.firstWeekday - 1 + offset) % 7])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.muted)
                            .accessibilityHidden(true)
                    }
                    let firstColumn = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
                    ForEach(0..<firstColumn, id: \.self) { _ in
                        Color.clear.frame(height: 21).accessibilityHidden(true)
                    }
                    ForEach(Array(calendar.range(of: .day, in: .month, for: month.start) ?? 1..<1), id: \.self) { number in
                        if let date = calendar.date(byAdding: .day, value: number - 1, to: month.start) {
                            dayButton(number, date: date)
                        }
                    }
                }
            }
            .frame(width: 207)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Date")
            .onChange(of: selection) { shownDate = selection }
        }
    }

    private func monthButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.iconAccent)
                .frame(width: 20, height: 19)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func dayButton(_ number: Int, date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selection)
        return Button { choose(date) } label: {
            Text(number.formatted(.number.locale(locale)))
                .font(.caption.monospacedDigit().weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.accentText : date < today ? palette.muted : palette.text)
                .frame(width: 27, height: 21)
                .background(selected ? palette.primaryAction : .clear, in: .rect(cornerRadius: 5))
                .overlay {
                    if !selected && date == today {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(palette.primaryAction)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(date < today)
        .focused($focusedDay, equals: date)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onKeyPress(.leftArrow) { moveFocus(from: date, by: -1) }
        .onKeyPress(.rightArrow) { moveFocus(from: date, by: 1) }
        .onKeyPress(.upArrow) { moveFocus(from: date, by: -7) }
        .onKeyPress(.downArrow) { moveFocus(from: date, by: 7) }
    }

    private func moveMonth(_ offset: Int) {
        guard let month else { return }
        shownDate = calendar.date(byAdding: .month, value: offset, to: month.start)
    }

    private func moveFocus(from date: Date, by offset: Int) -> KeyPress.Result {
        if let target = calendar.date(byAdding: .day, value: offset, to: date), target >= today {
            shownDate = target
            focusedDay = target
        }
        return .handled
    }

    private func choose(_ date: Date) {
        let time = calendar.dateComponents([.hour, .minute], from: selection)
        if let selected = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: date),
           calendar.isDate(selected, inSameDayAs: date) {
            selection = selected
            shownDate = selected
        }
    }
}

struct StudioTabs<Value: Hashable>: View {
    @Environment(\.studioPalette) private var palette
    @Binding var selection: Value
    let tabs: [Value]
    let label: (Value) -> String
    var count: ((Value) -> Int)? = nil
    var platform: ((Value) -> String)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.self) { tab in
                    Button { selection = tab } label: {
                        HStack(spacing: 6) {
                            if let platform {
                                PlatformMark(name: platform(tab), fallback: "newspaper")
                                    .foregroundStyle(palette.iconAccent)
                            }
                            Text(label(tab)).fontWeight(selection == tab ? .semibold : .regular)
                            if let count {
                                Text(count(tab).formatted())
                                    .font(InkspringTypography.interface(11).monospacedDigit())
                                    .foregroundStyle(palette.muted)
                            }
                        }
                        .font(InkspringTypography.interface(13))
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 29)
                        .studioGlassControl(tint: selection == tab ? palette.accent.opacity(0.2) : nil)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 5)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) { StudioRule().opacity(0.6) }
    }
}
#endif

#if os(iOS)
struct MobileWritingTextView: UIViewRepresentable {
    @Binding var text: String
    var identifier: String
    var findRequest = 0
    var autofocus = true
    var monospaced = false
    var onFocusLost: (() -> Void)? = nil
    @Environment(\.studioPalette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isFindInteractionEnabled = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 24, right: 12)
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.text = text
        if autofocus { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = identifier == "newsletter.markdown" ? "Markdown" : "Post text"
        let font = monospaced ? UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular)) : .preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        view.textColor = UIColor(palette.text)
        view.tintColor = UIColor(palette.iconAccent)
        // SwiftUI recomputes on autosave/sync. Never assign identical text: UIKit would reset selection.
        if view.text != text, view.markedTextRange == nil {
            let selection = view.selectedRange
            let offset = view.contentOffset
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            view.setContentOffset(offset, animated: false)
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileWritingTextView
        var findRequest = 0
        init(_ parent: MobileWritingTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocusLost?() }
    }
}
#endif

#if os(iOS)
private struct MobileXReplyEditor: View {
    @Binding var text: String
    let identifier: String
    let count: Int
    let back: () -> Void
    @State private var findRequest = 0
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Back to thread", systemImage: "chevron.left", action: back).accessibilityIdentifier("x.backToThread")
                Spacer()
                Text("\(count)/280").font(.caption)
            }.padding(.horizontal, 12)
            MobileWritingTextView(text: $text, identifier: identifier, findRequest: findRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Find", systemImage: "magnifyingglass") { findRequest += 1 }.accessibilityIdentifier("editor.find")
        } }
    }
}
#endif

#if os(macOS)
// The page owns scrolling, so keyboard navigation and Find must reveal their range in that page.
private final class MacDocumentTextView: NSTextView {
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        let length = (string as NSString).length
        guard let document = enclosingScrollView?.documentView, let layout = layoutManager,
              let container = textContainer, range.location <= length, length > 0 else { return }
        let character = NSRange(location: min(range.location, length - 1), length: 1)
        layout.ensureLayout(forCharacterRange: character)
        let glyph = layout.glyphRange(forCharacterRange: character, actualCharacterRange: nil)
        var line = layout.boundingRect(forGlyphRange: glyph, in: container)
        if range.location == length, !layout.extraLineFragmentRect.isEmpty { line = layout.extraLineFragmentRect }
        let target = convert(line.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), to: document)
        let visible = document.visibleRect
        if target.minY < visible.minY || target.maxY > visible.maxY {
            document.scroll(NSPoint(x: visible.minX, y: max(0, target.midY - visible.height / 2)))
        }
    }
}

struct MacWritingTextView: NSViewRepresentable {
    @Binding var text: String
    var findRequest = 0
    var focusRequest = 0
    var monospaced = false
    var documentMinimumHeight: CGFloat?
    var textInsets = NSSize(width: 8, height: 10)
    var lineSpacing: CGFloat = 0
    var onFocusLost: (() -> Void)? = nil
    @Environment(\.studioPalette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let root: NSView
        let view: NSTextView
        if documentMinimumHeight != nil {
            view = MacDocumentTextView(usingTextLayoutManager: false)
            view.isHorizontallyResizable = false
            view.isVerticallyResizable = true
            view.textContainer?.widthTracksTextView = true
            root = view
        } else {
            let scroll = NSTextView.scrollableTextView()
            scroll.drawsBackground = false
            view = scroll.documentView as! NSTextView
            root = scroll
        }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false
        view.textContainerInset = textInsets
        if lineSpacing > 0 {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            view.defaultParagraphStyle = style
        }
        replaceText(in: view)
        return root
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let documentMinimumHeight, let width = proposal.width, width.isFinite, width > 0,
              let view = nsView as? NSTextView, let storage = view.textStorage else { return nil }
        // SwiftUI may probe several widths. Measure those without rewrapping the live editor.
        let measure = context.coordinator.measurement
        if measure.textStorage !== storage { storage.addLayoutManager(measure) }
        guard let container = measure.textContainers.first else { return nil }
        let inset = view.textContainerInset
        container.containerSize = NSSize(width: max(1, width - inset.width * 2), height: .greatestFiniteMagnitude)
        measure.ensureLayout(for: container)
        let bottom = max(measure.usedRect(for: container).maxY, measure.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: max(documentMinimumHeight, ceil(bottom + inset.height * 2)))
    }

    func updateNSView(_ root: NSView, context: Context) {
        context.coordinator.parent = self
        let scroll = root as? NSScrollView
        guard let view = (root as? NSTextView) ?? (scroll?.documentView as? NSTextView) else { return }
        let font: NSFont = monospaced ? .monospacedSystemFont(ofSize: 14, weight: .regular) : .systemFont(ofSize: 16)
        if view.font != font { view.font = font }
        view.textColor = NSColor(palette.text)
        view.insertionPointColor = NSColor(palette.iconAccent)
        if view.string != text, !view.hasMarkedText() {
            let selection = view.selectedRange()
            let origin = scroll?.contentView.bounds.origin
            replaceText(in: view)
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            if let origin { scroll?.contentView.scroll(to: origin) }
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            view.window?.makeFirstResponder(view)
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                let action = NSMenuItem()
                action.tag = NSTextFinder.Action.showFindInterface.rawValue
                view.performFindPanelAction(action)
            }
        }
    }

    private func replaceText(in view: NSTextView) {
        view.string = text
        guard lineSpacing > 0, let style = view.defaultParagraphStyle, let storage = view.textStorage else { return }
        storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        view.typingAttributes[.paragraphStyle] = style
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        lazy var measurement: NSLayoutManager = {
            let layout = NSLayoutManager()
            layout.addTextContainer(NSTextContainer())
            return layout
        }()
        var parent: MacWritingTextView
        var findRequest = 0
        var focusRequest = 0
        init(_ parent: MacWritingTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? MacDocumentTextView,
                  view.enclosingScrollView?.isFindBarVisible == true,
                  view.selectedRange().length > 0 else { return }
            view.scrollRangeToVisible(view.selectedRange())
        }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusLost?() }
    }
}
#endif

#if os(macOS)
private struct MacReplyWritingField<Count: View>: View {
    let title: String
    @Binding var text: String
    let identifier: String
    let count: Count
    @State private var findRequest = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                count
                Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Find in \(title.lowercased())")
                    .accessibilityLabel("Find in \(title.lowercased())")
            }
            MacWritingTextView(text: $text, findRequest: findRequest, documentMinimumHeight: 41,
                               textInsets: NSSize(width: 14, height: 10), lineSpacing: 4)
                .studioSurface()
                .accessibilityIdentifier(identifier)
        }
    }
}
#endif

enum StudioRevisionRequestCopy {
    static let heading = "Revision requests"
    static let field = "Revision request"
    static let add = "Add revision request"
    static let send = "Send revision request"
    static let actedOn = "Acted on"
    static let ideaExample = "For example, focus this idea on one concrete claim."
    static let draftExample = "For example, tighten the opening and keep the source links."
}

struct StudioWritingRequest: Identifiable {
    let id: String
    let text: String
    var state: String
    var date: String?
    var withdraw: (@MainActor () throws -> Void)?

    init(id: String, text: String, state: String, date: String? = nil) {
        self.id = id
        self.text = text
        self.state = state
        self.date = date
    }

    init(_ request: CompanionLibrary.RevisionRequest) {
        let state = switch request.state {
        case .actedOn: StudioRevisionRequestCopy.actedOn
        case .pending: "Waiting for your Mac to revise"
        case .waitingForEditable: "Waiting for an editable item"
        case .savedNote: "Saved note"
        }
        self.init(id: request.id, text: request.text, state: state, date: request.date)
    }
}

struct StudioRevisionRequestRow: View {
    @Environment(\.studioPalette) private var palette
    let request: StudioWritingRequest

    @State private var withdrawalError: String?

    var body: some View {
        let actedOn = request.state == StudioRevisionRequestCopy.actedOn
        VStack(alignment: .leading, spacing: 5) {
            Text(request.text).textSelection(.enabled)
            HStack(spacing: 8) {
                if actedOn {
                    Label(request.state, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(palette.success)
                } else {
                    Text(request.state)
                }
                if let raw = request.date,
                   let date = (try? Date(raw, strategy: .iso8601)) ??
                    (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
            }
            .font(.footnote)
            .foregroundStyle(palette.muted)
            if let withdraw = request.withdraw {
                Button {
                    do { try withdraw(); withdrawalError = nil }
                    catch { withdrawalError = error.localizedDescription }
                } label: {
                    Label("Withdraw request", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.medium)).frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Withdraw revision request: " + request.text)
                .accessibilityIdentifier("revision.withdraw." + request.id)
            }
            if let withdrawalError { Text(withdrawalError).font(.caption).foregroundStyle(palette.danger) }
        }
    }
}

struct StudioWritingAssistant: View {
    let agent: String
    let requests: [StudioWritingRequest]
    var reply: String?
    var error: String?
    let submit: (String) throws -> Void
    @Environment(\.studioPalette) private var palette
    @State private var prompt = ""
    @State private var message: String?
    @State private var composing = false
    private var agentTitle: String {
        switch agent { case "claude", "anthropic": "Claude"; case "codex": "Codex"; case "openai": "OpenAI"; case "gemini", "antigravity": "Gemini"; default: "your agent" }
    }
    private var agentIcon: String { ["claude", "anthropic"].contains(agent) ? "claude-mark" : ["codex", "openai"].contains(agent) ? "openai-mark" : agent == "antigravity" ? "gemini" : agent }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioPlatformLabel(name: agentIcon, title: "Ask \(agentTitle)")
                .font(.headline)
            Text("Your Mac applies the request using its writing connection. Every change is kept in revision history.")
                .font(.caption).foregroundStyle(palette.muted)
            if composing {
                TextField(StudioRevisionRequestCopy.field, text: $prompt,
                          prompt: Text(StudioRevisionRequestCopy.draftExample), axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.plain).padding(10)
                    .studioSurface(StudioRadius.control, fill: palette.well)
                    .accessibilityIdentifier("writing.prompt")
                HStack {
                    Text("\(prompt.utf16.count)/1,000").font(.caption).foregroundStyle(palette.muted)
                    Spacer()
                    Button("Cancel") { composing = false }
                    Button(StudioRevisionRequestCopy.send) { send(prompt) }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.utf16.count > 1_000)
                        .accessibilityIdentifier("writing.send")
                }
            } else {
                Button(StudioRevisionRequestCopy.add, systemImage: "plus") { composing = true }
                    .accessibilityIdentifier("writing.addRevisionRequest")
            }
            HStack {
                Button("Summarize this") { send("Summarize this draft into a concise brief, preserving the key facts and relevant links.") }
                Button("Tighten the writing") { send("Make this draft clearer and more concise while preserving my voice, facts and links.") }
            }.font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(palette.danger).accessibilityIdentifier("writing.error") }
            if let message { Text(message).font(.caption).foregroundStyle(palette.muted).accessibilityIdentifier("writing.status") }
            if !requests.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(requests) { request in
                            StudioRevisionRequestRow(request: request)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10).studioSurface(fill: palette.well)
                        }
                    }
                }.frame(maxHeight: 160)
            }
            if let reply, !reply.isEmpty { Text(reply).font(.callout).accessibilityIdentifier("writing.reply") }
        }
        .foregroundStyle(palette.text)
        .onChange(of: reply) { message = nil }
    }
    private func send(_ text: String) {
        do {
            try submit(text.trimmingCharacters(in: .whitespacesAndNewlines))
            prompt = ""
            composing = false
            message = "Request saved. Your Mac will apply it while Inkspring is open."
        } catch { message = error.localizedDescription }
    }
}

#if os(iOS)
struct MobileWritingTools: View {
    @Binding var title: String
    @Binding var text: String
    @Binding var presented: Bool
    let agent: String
    let providers: [CompanionLibrary.WritingProvider]?
    let requests: [StudioWritingRequest]
    var reply: String?
    var error: String?
    let request: (String, CompanionLibrary.WritingSelection?) throws -> Void
    @State private var tab = "Ask AI"
    @State private var selection: CompanionLibrary.WritingSelection?
    @Environment(\.studioPalette) private var palette
    var body: some View {
        Button("Writing tools", systemImage: "bubble.left.and.text.bubble.right") { presented = true }
            .accessibilityIdentifier("writing.tools")
            .popover(isPresented: $presented) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Writing tools").font(.headline)
                            Spacer()
                            Button("Done") { presented = false }.accessibilityIdentifier("writing.close")
                        }
                        HStack(spacing: 4) {
                            ForEach(["Ask AI", "Proofread"], id: \.self) { option in
                                Button { tab = option } label: {
                                    Text(option).font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .background(tab == option ? palette.active : .clear, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(tab == option ? .isSelected : [])
                            }
                        }
                        .padding(3).background(palette.well, in: Capsule())
                        .overlay { Capsule().strokeBorder(palette.line).allowsHitTesting(false) }
                        .accessibilityLabel("Writing tool")
                        if tab == "Ask AI" {
                            if let providers, !providers.isEmpty {
                                MobileWritingPicker(providers: providers, preferredProvider: agent, selection: $selection)
                            }
                            let writer = MobileWritingPicker.resolved(selection, providers: providers, preferred: agent)
                            StudioWritingAssistant(agent: writer?.provider ?? agent, requests: requests, reply: reply, error: error) {
                                try request($0, writer)
                                selection = nil
                            }
                            .disabled(!MobileWritingPicker.canSend(writer, providers: providers))
                        } else {
                            StudioProofreadAction(document: .init(title: title, body: text), unavailable: MobileProofreading.availabilityMessage,
                                check: MobileProofreading.check) { title = $0.title; text = $0.body }
                        }
                    }.padding(20)
                }.frame(minWidth: 300, idealWidth: 380, minHeight: 350, idealHeight: 520).background(palette.canvas)
            }
    }
}
#endif
