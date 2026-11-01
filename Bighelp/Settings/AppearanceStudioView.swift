import SwiftUI
import UIKit

/// Settings › Appearance: Color scheme, Themes (a light and a dark theme, picked separately), how
/// agent messages sit, the bubble color, with a live preview of both modes, and the text and button
/// size. Anything else about the look (chat layout, and on Vision Pro transparency) follows below.
/// The Color scheme row and the Themes grid follow T3 Code's Appearance screen
/// (github.com/pingdotgg/t3code, MIT License, Copyright 2026 T3 Tools Inc.).
@MainActor
struct AppearanceStudioView<Extras: View>: View {
    @Bindable var settings: SettingsStore
    private let extras: Extras
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(ChatLayoutPreferences.agentMessageStyleKey) private var agentStyle: ChatAgentMessageStyle = .bubble

    init(settings: SettingsStore, @ViewBuilder extras: () -> Extras) {
        _settings = Bindable(wrappedValue: settings)
        self.extras = extras()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                preview
                section(String(localized: "Color scheme"), caption: nil) {
                    AppearanceSchemeRow(appearance: $settings.appearance, light: theme(.light), dark: theme(.dark))
                }
                section(String(localized: "Themes"), caption: String(localized: "Light and dark, picked separately")) {
                    AppearanceThemeGrid(settings: settings) { preset, dark in previewTheme(preset, dark: dark) }
                }
                section(String(localized: "Agent messages"), caption: nil) {
                    Picker("Agent messages", selection: $agentStyle) {
                        ForEach(ChatAgentMessageStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .bighelpSegmentedPicker()
                    .accessibilityIdentifier("appearance.agent-messages")
                }
                section(String(localized: "Bubble color"), caption: String(localized: "Your messages and buttons")) {
                    AppearanceBubbleGrid(settings: settings)
                }
                section(String(localized: "Text and buttons"), caption: nil) { AppearanceSizeControls() }
                VStack(spacing: BighelpTokens.space12) { extras }
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(currentTheme.canvas.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: settings.bubbleColor)
        .animation(.snappy, value: settings.customBubbleHex)
        .animation(.snappy, value: settings.bubbleFollowsTheme)
        .animation(.snappy, value: settings.lightBackground)
        .animation(.snappy, value: settings.darkBackground)
        .animation(.snappy, value: agentStyle)
        .accessibilityIdentifier("appearance.studio")
    }

    // MARK: Preview

    /// Both modes at once, so a change reads everywhere it applies.
    private var preview: some View {
        let light = settings.lightBackground.preset.name, dark = settings.darkBackground.preset.name
        return HStack(spacing: BighelpTokens.space12) {
            AppearancePreviewCard(theme: theme(.light), title: String(localized: "Light"), agentStyle: agentStyle)
            AppearancePreviewCard(theme: theme(.dark), title: String(localized: "Dark"), agentStyle: agentStyle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized:
            "Preview: \(settings.bubbleColorName) bubbles, \(light) in light mode, \(dark) in dark mode"))
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, caption: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle(title)
                    if let caption {
                        Spacer()
                        sectionCaption(caption)
                    }
                }
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    sectionTitle(title)
                    if let caption { sectionCaption(caption) }
                }
            }
            content()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.bighelp(.caption2).weight(.bold))
            .tracking(0.9)
            .foregroundStyle(currentTheme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func sectionCaption(_ caption: String) -> some View {
        Text(caption).font(.bighelp(.caption)).foregroundStyle(currentTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A theme with today's choices.
    private func theme(_ scheme: ColorScheme) -> BighelpTheme {
        BighelpTheme.resolve(appearance: settings.appearanceContext.forcing(scheme),
                             colorScheme: scheme, contrast: contrast)
    }

    /// What a preset looks like in one mode once picked: its page, its agent messages and the bubbles
    /// it would bring. Always the standard look, so the presets stay apart under high contrast.
    private func previewTheme(_ preset: BighelpThemePreset, dark: Bool) -> BighelpTheme {
        var context = settings.appearanceContext.forcing(dark ? .dark : .light)
        if dark { context.darkBackground = preset.dark } else { context.lightBackground = preset.light }
        if preset.accentHex(dark: dark) != nil { context.bubbleFollowsTheme = true }
        return BighelpTheme.resolve(appearance: context, colorScheme: dark ? .dark : .light, contrast: .standard)
    }

    @BighelpThemeReader private var currentTheme
}

/// System, Light and Dark, each a little phone in the chosen themes.
private struct AppearanceSchemeRow: View {
    @Binding var appearance: AppAppearance
    let light: BighelpTheme
    let dark: BighelpTheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space8) { tiles }
            VStack(spacing: BighelpTokens.space8) { tiles }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance.mode")
    }

    @ViewBuilder private var tiles: some View {
        ForEach(AppAppearance.allCases) { choice in
            let isSelected = appearance == choice
            Button { appearance = choice } label: {
                VStack(spacing: BighelpTokens.space8) {
                    sketch(choice)
                    Text(title(choice))
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(currentTheme.primaryText)
                        .fixedSize()
                }
                .padding(.vertical, BighelpTokens.space8)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .background(currentTheme.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? currentTheme.action : .clear, lineWidth: 2))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title(choice))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("appearance.mode.\(choice.rawValue)")
        }
    }

    private func title(_ choice: AppAppearance) -> String {
        switch choice {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    private func sketch(_ choice: AppAppearance) -> some View {
        HStack(spacing: 0) {
            if choice != .dark { phone(light) }
            if choice != .light { phone(dark) }
        }
        .frame(width: 40, height: 58)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(currentTheme.border, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// A page with an agent message, your bubble and another message, cut to the space it gets.
    private func phone(_ theme: BighelpTheme) -> some View {
        Color(hex: theme.canvasHex).overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(theme.incomingMessageSolid).frame(width: 22, height: 5)
                Capsule().fill(theme.outgoingMessageBackground).frame(width: 16, height: 5)
                    .frame(width: 30, alignment: .trailing)
                Capsule().fill(theme.incomingMessageSolid).frame(width: 26, height: 5)
            }
            .padding(.top, 9)
            .padding(.leading, 5)
            .frame(width: 40, alignment: .leading)
        }
        .clipped()
    }

    @BighelpThemeReader private var currentTheme
}

/// The Themes: a card per preset with a light orb and a dark orb. Tapping an orb picks that theme for
/// that mode; the picked orbs carry the accent ring and a sun or a moon.
private struct AppearanceThemeGrid: View {
    @Bindable var settings: SettingsStore
    let preview: (BighelpThemePreset, Bool) -> BighelpTheme
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At the largest text sizes a card gets the whole row, so no name is ever cut.
    private var isWide: Bool { typeSize >= .xxxLarge }

    var body: some View {
        LazyVGrid(columns: isWide
                    ? [GridItem(.flexible())]
                    : [GridItem(.adaptive(minimum: BighelpTokens.scaled(150)), spacing: BighelpTokens.space12)],
                  spacing: BighelpTokens.space12) {
            ForEach(BighelpThemePreset.allCases) { preset in
                card(preset)
            }
        }
    }

    private func card(_ preset: BighelpThemePreset) -> some View {
        let orbs = HStack(spacing: BighelpTokens.space12) {
            orb(preset, dark: false)
            orb(preset, dark: true)
        }
        let name = Text(preset.name)
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(currentTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
        return Group {
            if isWide {
                HStack(spacing: BighelpTokens.space12) {
                    name.frame(maxWidth: .infinity, alignment: .leading)
                    orbs
                }
            } else {
                VStack(spacing: BighelpTokens.space8) {
                    orbs
                    name.multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(BighelpTokens.space12)
        .background(currentTheme.surface, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    private func orb(_ preset: BighelpThemePreset, dark: Bool) -> some View {
        let isSelected = dark ? settings.darkBackground == preset.dark : settings.lightBackground == preset.light
        let mode = dark ? String(localized: "dark") : String(localized: "light")
        let raw = dark ? preset.dark.rawValue : preset.light.rawValue
        return Button {
            settings.pickTheme(preset, dark: dark)
        } label: {
            AppearanceThemeOrb(theme: preview(preset, dark), size: BighelpTokens.hitTarget)
                .padding(4)
                .overlay(Circle().strokeBorder(isSelected ? currentTheme.action : .clear, lineWidth: 2.5))
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: dark ? "moon.fill" : "sun.max.fill")
                            .font(.bighelp(.caption2).weight(.bold))
                            .foregroundStyle(currentTheme.actionForeground)
                            .frame(width: 22, height: 22)
                            .background(currentTheme.action, in: .circle)
                            .overlay(Circle().strokeBorder(currentTheme.surface, lineWidth: 2))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name), \(mode)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("appearance.\(dark ? "dark" : "light").\(raw)")
    }

    @BighelpThemeReader private var currentTheme
}

/// A preset in one mode: its page, with your bubble color and its agent message color on it.
private struct AppearanceThemeOrb: View {
    let theme: BighelpTheme
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(Color(hex: theme.canvasHex))
            Circle().fill(theme.outgoingMessageBackground)
                .frame(width: size * 0.56, height: size * 0.56)
                .offset(x: size * 0.12, y: size * 0.12)
            Circle().fill(theme.incomingMessageSolid)
                .frame(width: size * 0.26, height: size * 0.26)
                .offset(x: size * 0.18, y: size * 0.18)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(Color(hex: theme.borderHex), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// A tiny chat on the chosen background, in one mode.
private struct AppearancePreviewCard: View {
    let theme: BighelpTheme
    let title: String
    let agentStyle: ChatAgentMessageStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.bighelp(.caption2).weight(.bold))
                .foregroundStyle(theme.secondaryText)
            agent(String(localized: "Morning! Want today's plan?"))
            bubble(String(localized: "Yes please ☀️"), fill: theme.outgoingMessageBackground,
                   text: theme.outgoingMessageForeground, alignment: .trailing)
            agent(String(localized: "On it. Three things…"))
            HStack {
                Capsule().fill(theme.surface).frame(height: 22)
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                Circle().fill(theme.action).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.actionForeground))
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity)
        .background(theme.canvas, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.border, lineWidth: 1))
    }

    @ViewBuilder private func agent(_ text: String) -> some View {
        if agentStyle == .page {
            Text(text)
                .font(.bighelp(.caption2))
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            bubble(text, fill: theme.incomingMessageBackground, text: theme.primaryText, alignment: .leading)
        }
    }

    private func bubble(_ text: String, fill: Color, text textColor: Color, alignment: Alignment) -> some View {
        Text(text)
            .font(.bighelp(.caption2))
            .foregroundStyle(textColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(fill, in: .rect(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

extension AppearanceStudioView where Extras == EmptyView {
    init(settings: SettingsStore) {
        self.init(settings: settings) { EmptyView() }
    }
}

/// The bubble colors as round swatches, then Custom for any color. Settings ›
/// Appearance and first-run setup both use it, so the choice looks the same in
/// both places.
struct AppearanceBubbleGrid: View {
    @Bindable var settings: SettingsStore
    @State private var colorPicker = SystemColorPickerAnchor()

    private var selectedBubble: BighelpBubbleColor? {
        settings.customBubbleHex == nil && !settings.themeGivesBubbles ? settings.bubbleColor ?? .graphite : nil
    }

    /// The accents of the picked light and dark themes, where they have one.
    private var themeAccents: (light: String?, dark: String?) {
        (settings.lightBackground.preset.accentHex(dark: false), settings.darkBackground.preset.accentHex(dark: true))
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space12), count: 4),
                  spacing: BighelpTokens.space16) {
            if themeAccents.light != nil || themeAccents.dark != nil { themeTile }
            ForEach(BighelpBubbleColor.allCases) { color in
                let isSelected = selectedBubble == color
                Button {
                    settings.pickBubbleColor(color)
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: color.swatchHex))
                            .frame(width: 44, height: 44)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.bighelp(.subheadline).weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(3)
                            .overlay(Circle().strokeBorder(isSelected ? currentTheme.primaryText : .clear, lineWidth: 2))
                        Text(color.name)
                            .font(.bighelp(.caption).weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(currentTheme.primaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(color.name) bubbles")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("appearance.bubble.\(color.rawValue)")
            }
            customTile
        }
    }

    /// The picked themes' own accents, light and dark: half each.
    private var themeTile: some View {
        let isSelected = settings.themeGivesBubbles
        let fallback = (settings.bubbleColor ?? .graphite).swatchHex
        return Button {
            settings.bubbleFollowsTheme = true
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(LinearGradient(
                        stops: [.init(color: Color(hex: themeAccents.light ?? fallback), location: 0.5),
                                .init(color: Color(hex: themeAccents.dark ?? fallback), location: 0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.bighelp(.subheadline).weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(.circle)
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? currentTheme.primaryText : .clear, lineWidth: 2))
                Text("Theme")
                    .font(.bighelp(.caption).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(currentTheme.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme bubbles")
        .accessibilityHint("Uses each theme's own color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("appearance.bubble.theme")
    }

    /// Any color: the whole swatch opens the system color picker.
    private var customTile: some View {
        let custom = settings.customBubbleHex
        return Button {
            let start = Color(hex: custom ?? (selectedBubble ?? .graphite).swatchHex)
            colorPicker.present(title: String(localized: "Custom bubble color"), color: UIColor(start)) { picked in
                settings.customBubbleHex = BighelpCustomBubbleColor.hex(from: Color(uiColor: picked))
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                  center: .center))
                    if let custom {
                        Circle().fill(Color(hex: custom)).padding(5)
                        Image(systemName: "checkmark")
                            .font(.bighelp(.subheadline).weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .padding(3)
                .overlay(Circle().strokeBorder(custom != nil ? currentTheme.primaryText : .clear, lineWidth: 2))
                Text("Custom")
                    .font(.bighelp(.caption).weight(custom != nil ? .semibold : .regular))
                    .foregroundStyle(currentTheme.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(SystemColorPickerHost(anchor: colorPicker))
        .accessibilityLabel("Custom bubble color")
        .accessibilityAddTraits(custom != nil ? .isSelected : [])
        .accessibilityIdentifier("appearance.bubble.custom")
    }

    @BighelpThemeReader private var currentTheme
}

/// A row on the Appearance page that opens another page.
struct AppearanceStudioRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(currentTheme.primaryText)
                Text(detail)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(currentTheme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(currentTheme.tertiaryText)
        }
        .padding(BighelpTokens.space16)
        .background(currentTheme.surface, in: .rect(cornerRadius: 16))
        .contentShape(.rect)
    }

    @BighelpThemeReader private var currentTheme
}

/// Opens the system color picker from a button. SwiftUI's ColorPicker only
/// opens from its own small color well, so most taps on a swatch missed it.
@MainActor
final class SystemColorPickerAnchor: NSObject, UIColorPickerViewControllerDelegate {
    fileprivate weak var host: UIViewController?
    private var onPick: ((UIColor) -> Void)?

    func present(title: String, color: UIColor, onPick: @escaping (UIColor) -> Void) {
        guard let host, host.presentedViewController == nil else { return }
        self.onPick = onPick
        let picker = UIColorPickerViewController()
        picker.title = title
        picker.supportsAlpha = false
        picker.selectedColor = color
        picker.delegate = self
        if host.traitCollection.horizontalSizeClass == .regular {
            // iPad and Vision Pro: a popover pointing at the swatch.
            picker.modalPresentationStyle = .popover
            picker.popoverPresentationController?.sourceView = host.view
            picker.popoverPresentationController?.sourceRect = host.view.bounds
        }
        #if !os(visionOS)
        if picker.modalPresentationStyle != .popover, let sheet = picker.sheetPresentationController {
            // Tall enough for the color grid and your recent colors, no more.
            sheet.detents = [.custom(identifier: .init("bighelp.colors")) { $0.maximumDetentValue * 0.7 }, .large()]
            sheet.prefersGrabberVisible = true
        }
        #endif
        host.present(picker, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController,
                                   didSelect color: UIColor, continuously: Bool) {
        onPick?(color)
    }
}

/// Where the picker is presented from: the swatch's own spot on screen.
private struct SystemColorPickerHost: UIViewControllerRepresentable {
    let anchor: SystemColorPickerAnchor

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        // Taps belong to the button above it.
        host.view.isUserInteractionEnabled = false
        anchor.host = host
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        anchor.host = host
    }
}
