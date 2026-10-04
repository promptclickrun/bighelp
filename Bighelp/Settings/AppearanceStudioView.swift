import SwiftUI
import UIKit

/// Settings › Appearance: pick a bubble color and a page color for light and
/// dark mode, with a live preview of both, and the text and button size.
/// Anything else about the look (chat layout, and on Vision Pro transparency)
/// follows below.
@MainActor
struct AppearanceStudioView<Extras: View>: View {
    @Bindable var settings: SettingsStore
    private let extras: Extras
    @Environment(\.colorSchemeContrast) private var contrast

    init(settings: SettingsStore, @ViewBuilder extras: () -> Extras) {
        _settings = Bindable(wrappedValue: settings)
        self.extras = extras()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                preview
                section("Bubble color", caption: "Your messages and buttons") { AppearanceBubbleGrid(settings: settings) }
                section("Light mode", caption: nil) {
                    HStack(spacing: BighelpTokens.space12) {
                        ForEach(BighelpLightBackground.allCases) { choice in
                            backgroundTile(name: choice.name, detail: choice.detail,
                                           theme: theme(.light, light: choice),
                                           isSelected: settings.lightBackground == choice,
                                           identifier: "appearance.light.\(choice.rawValue)") {
                                settings.lightBackground = choice
                            }
                        }
                    }
                }
                section("Dark mode", caption: nil) {
                    HStack(spacing: BighelpTokens.space12) {
                        ForEach(BighelpDarkBackground.allCases) { choice in
                            backgroundTile(name: choice.name, detail: choice.detail,
                                           theme: theme(.dark, dark: choice),
                                           isSelected: settings.darkBackground == choice,
                                           identifier: "appearance.dark.\(choice.rawValue)") {
                                settings.darkBackground = choice
                            }
                        }
                    }
                }
                section("Show", caption: nil) {
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("Automatic").tag(AppAppearance.system)
                        Text("Light").tag(AppAppearance.light)
                        Text("Dark").tag(AppAppearance.dark)
                    }
                    .bighelpSegmentedPicker()
                    .accessibilityIdentifier("appearance.mode")
                }
                section("Text and buttons", caption: nil) { AppearanceSizeControls() }
                section("Bottom menu", caption: nil) {
                    Toggle(isOn: $bottomMenuStartsCollapsed) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fold it").foregroundStyle(currentTheme.primaryText)
                            Text("One button in chats and while you scroll down a page. Tap it, or press and slide to a tab.")
                                .font(.bighelp(.caption))
                                .foregroundStyle(currentTheme.secondaryText)
                        }
                    }
                    .padding(BighelpTokens.space12)
                    .background(currentTheme.surface, in: .rect(cornerRadius: 18))
                    .accessibilityIdentifier("appearance.bottom-menu-collapsed")
                }
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
        .animation(.snappy, value: settings.lightBackground)
        .animation(.snappy, value: settings.darkBackground)
        .accessibilityIdentifier("appearance.studio")
    }

    // MARK: Preview

    /// Both modes at once, so a change reads everywhere it applies.
    private var preview: some View {
        HStack(spacing: BighelpTokens.space12) {
            AppearancePreviewCard(theme: theme(.light), title: "Light")
            AppearancePreviewCard(theme: theme(.dark), title: "Dark")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(settings.bubbleColorName) bubbles, "
            + "\(settings.lightBackground.name) in light mode, \(settings.darkBackground.name) in dark mode")
    }

    // MARK: Backgrounds

    private func backgroundTile(name: String, detail: String, theme: BighelpTheme, isSelected: Bool,
                                identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(theme.incomingMessageBackground).frame(width: 64, height: 14)
                    Capsule().fill(theme.outgoingMessageBackground).frame(width: 52, height: 14)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Capsule().fill(theme.incomingMessageBackground).frame(width: 44, height: 14)
                }
                .padding(BighelpTokens.space12)
                .frame(maxWidth: .infinity)
                .background(theme.canvas, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.border.opacity(0.8), lineWidth: 1))
                HStack(spacing: 4) {
                    Text(name).font(.bighelp(.subheadline).weight(.semibold)).foregroundStyle(currentTheme.primaryText)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(currentTheme.action)
                    }
                }
                Text(detail)
                    .font(.bighelp(.caption))
                    .foregroundStyle(currentTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BighelpTokens.space12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(currentTheme.surface, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? currentTheme.action : .clear, lineWidth: 2))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name). \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, caption: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(currentTheme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                if let caption {
                    Spacer()
                    Text(caption).font(.bighelp(.caption)).foregroundStyle(currentTheme.tertiaryText)
                }
            }
            content()
        }
    }

    /// A theme with today's choices, optionally trying a different background.
    private func theme(_ scheme: ColorScheme, light: BighelpLightBackground? = nil,
                       dark: BighelpDarkBackground? = nil) -> BighelpTheme {
        BighelpTheme.resolve(
            appearance: BighelpAppearanceContext(
                appearance: scheme == .dark ? .dark : .light,
                lightBackground: light ?? settings.lightBackground,
                darkBackground: dark ?? settings.darkBackground,
                bubbleColor: settings.bubbleColor, customBubbleHex: settings.customBubbleHex),
            colorScheme: scheme, contrast: contrast)
    }

    @AppStorage(FloatingTabBar.startsCollapsedKey) private var bottomMenuStartsCollapsed = true
    @BighelpThemeReader private var currentTheme
}

/// A tiny chat on the chosen background, in one mode.
private struct AppearancePreviewCard: View {
    let theme: BighelpTheme
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.bighelp(.caption2).weight(.bold))
                .foregroundStyle(theme.secondaryText)
            bubble("Morning! Want today's plan?", fill: theme.incomingMessageBackground,
                   text: theme.primaryText, alignment: .leading)
            bubble("Yes please ☀️", fill: theme.outgoingMessageBackground, text: theme.outgoingMessageForeground,
                   alignment: .trailing)
            bubble("On it. Three things…", fill: theme.incomingMessageBackground,
                   text: theme.primaryText, alignment: .leading)
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

    private func bubble(_ text: String, fill: Color, text textColor: Color, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11))
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
        settings.customBubbleHex == nil ? settings.bubbleColor ?? .lavender : nil
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space12), count: 4),
                  spacing: BighelpTokens.space16) {
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

    /// Any color: the whole swatch opens the system color picker.
    private var customTile: some View {
        let custom = settings.customBubbleHex
        return Button {
            let start = Color(hex: custom ?? (selectedBubble ?? .lavender).swatchHex)
            colorPicker.present(title: "Custom bubble color", color: UIColor(start)) { picked in
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
