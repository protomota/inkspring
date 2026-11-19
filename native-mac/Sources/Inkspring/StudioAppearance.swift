import SwiftUI
#if os(macOS)
import InkspringSchedule
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct StudioXPostEditor: View {
    @Environment(\.studioPalette) private var palette
    @Binding var text: String
    @Binding var format: String
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
                ForEach(XPostStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("x.postType")
            ForEach(posts.indices, id: \.self) { index in
                let title = index == 0 ? "Opening post" : "Follow-up reply \(index)"
                #if os(iOS)
                Button { editingPart = index } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(posts[index].isEmpty ? "Write this post…" : posts[index])
                            .font(.body).lineLimit(3).foregroundStyle(palette.text)
                        counter(posts[index])
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.buttonStyle(.plain)
                .accessibilityIdentifier("x.editPost.\(index)")
                #else
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.callout.weight(.semibold))
                        Spacer()
                        counter(posts[index])
                    }
                    MacReplyWritingField(text: part(index))
                        .font(InkspringTypography.interface(16)).lineSpacing(4)
                        .scrollContentBackground(.hidden).frame(minHeight: 110)
                        .padding(10).studioSurface()
                        .accessibilityIdentifier("x.postText.\(index)")
                }
                #endif
                if index > 0 { Button("Remove reply", role: .destructive) { remove(index) } }
            }
            if format != "post" {
                Button("Add follow-up reply", systemImage: "plus") {
                    format = "thread"
                    text = (posts + [""]).joined(separator: XThreadText.separator)
                }
                .disabled(posts.count >= XThreadText.limit || posts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                .accessibilityIdentifier("x.addReply")
            }
    }

    private func counter(_ post: String) -> some View {
        let weight = XThreadText.weight(post)
        return Text("\(weight)/280").font(.caption).foregroundStyle(weight > 280 ? palette.danger : palette.muted)
    }

    private func part(_ index: Int) -> Binding<String> {
        Binding(get: { posts.indices.contains(index) ? posts[index] : "" }, set: { value in
            var values = posts
            guard values.indices.contains(index) else { return }
            values[index] = value
            text = format == "post" ? value : values.joined(separator: XThreadText.separator)
        })
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

    var body: some View {
        (Self.image(name) ?? Image(systemName: fallback))
            .resizable().scaledToFit()
            .frame(width: 14, height: 14)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DatePicker("Date", selection: $selection,
                       in: Calendar.current.startOfDay(for: .now)...,
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
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
            if let date = Calendar.current.date(bySetting: component, value: value, of: selection) {
                selection = date
            }
        })
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: hour))!
        return date.formatted(.dateTime.hour())
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
struct MacWritingTextView: NSViewRepresentable {
    @Binding var text: String
    var findRequest = 0
    var focusRequest = 0
    var monospaced = false
    var onFocusLost: (() -> Void)? = nil
    @Environment(\.studioPalette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        let font: NSFont = monospaced ? .monospacedSystemFont(ofSize: 14, weight: .regular) : .systemFont(ofSize: 16)
        if view.font != font { view.font = font }
        view.textColor = NSColor(palette.text)
        view.insertionPointColor = NSColor(palette.iconAccent)
        if view.string != text, !view.hasMarkedText() {
            let selection = view.selectedRange()
            let origin = scroll.contentView.bounds.origin
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            scroll.contentView.scroll(to: origin)
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
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacWritingTextView
        var findRequest = 0
        var focusRequest = 0
        init(_ parent: MacWritingTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusLost?() }
    }
}
#endif

#if os(macOS)
private struct MacReplyWritingField: View {
    @Binding var text: String
    @State private var findRequest = 0
    var body: some View {
        VStack {
            HStack { Spacer(); Button("Find", systemImage: "magnifyingglass") { findRequest += 1 } }
            MacWritingTextView(text: $text, findRequest: findRequest)
        }
    }
}
#endif

#if os(iOS)
struct MobileWritingTools: View {
    @Binding var title: String
    @Binding var text: String
    @State private var presented = false
    @Environment(\.studioPalette) private var palette
    var body: some View {
        Button("Writing tools", systemImage: "text.badge.checkmark") { presented = true }
            .accessibilityIdentifier("writing.tools")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("Proofread").font(.headline); Spacer(); Button("Done") { presented = false } }
                    StudioProofreadAction(document: .init(title: title, body: text), unavailable: MobileProofreading.availabilityMessage,
                        check: MobileProofreading.check) { title = $0.title; text = $0.body }
                }.padding(20).frame(minWidth: 280, idealWidth: 360).background(palette.canvas)
            }
    }
}
#endif
