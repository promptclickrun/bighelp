import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// Settings › Appearance › Themes: each preset reads well, fills the settings people already had,
/// and light and dark are picked separately.
@MainActor
struct ThemePresetTests {
    private func resolve(_ context: BighelpAppearanceContext, dark: Bool,
                         contrast: ColorSchemeContrast = .standard) -> BighelpTheme {
        BighelpTheme.resolve(appearance: context, colorScheme: dark ? .dark : .light, contrast: contrast)
    }

    private func context(_ preset: BighelpThemePreset, dark: Bool, followsTheme: Bool = true,
                         bubble: BighelpBubbleColor? = nil) -> BighelpAppearanceContext {
        BighelpAppearanceContext(appearance: dark ? .dark : .light, lightBackground: preset.light,
                                 darkBackground: preset.dark, bubbleColor: bubble, bubbleFollowsTheme: followsTheme)
    }

    @Test(arguments: BighelpThemePreset.allCases, [false, true])
    func everyPresetGivesReadableTextAndAccent(preset: BighelpThemePreset, dark: Bool) {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            let theme = resolve(context(preset, dark: dark), dark: dark, contrast: contrast)
            let label = "\(preset) \(dark ? "dark" : "light") \(contrast)"
            var pages = [theme.canvasHex, theme.surfaceHex, theme.raisedSurfaceHex]
            if let message = theme.messageSurfaceHex { pages.append(message) }
            for page in pages {
                #expect(Self.contrast(theme.primaryTextHex, page) >= 4.5, "body text on \(page), \(label)")
                #expect(Self.contrast(theme.actionHex, page) >= 4.5, "accent on \(page), \(label)")
            }
            #expect(Self.contrast(theme.secondaryTextHex, theme.canvasHex) >= 4.5, "muted text, \(label)")
            #expect(Self.contrast(theme.actionForegroundHex, theme.actionHex) >= 4.5, "button text, \(label)")
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let bubble = UIColor(theme.outgoingMessageBackground).resolvedColor(with: traits)
            #expect(Self.contrast(UIColor.white, bubble) >= 4.5, "white text in your bubble, \(label)")
        }
    }

    @Test func aPresetSetsThePageTextMessagesAndAccentTogether() {
        let light = resolve(context(.moss, dark: false), dark: false)
        let palette = BighelpPresetPalette.mossLight
        #expect(light.canvasHex == palette.canvas)
        #expect(light.primaryTextHex == palette.text)
        #expect(light.secondaryTextHex == palette.textMuted)
        #expect(light.borderHex == palette.border)
        #expect(light.messageSurfaceHex == palette.messageSurface)
        #expect(light.surfaceHex != light.canvasHex, "Cards stand out from the page")
        #expect(Self.hueDistance(Self.color(light.actionHex), Self.color(palette.accent)) < 0.03)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let bubble = UIColor(light.outgoingMessageBackground).resolvedColor(with: traits)
        #expect(Self.hueDistance(bubble, Self.color(palette.accent)) < 0.03, "Your bubbles take the theme's accent")
    }

    @Test func classicAndWarmAreTheOldPagesAndKeepYourBubbleColor() {
        #expect(BighelpThemePreset.classic.light == .paper && BighelpThemePreset.classic.dark == .black)
        #expect(BighelpThemePreset.warm.light == .cream && BighelpThemePreset.warm.dark == .graphite)
        for dark in [false, true] {
            let old = BighelpAppearanceContext(appearance: dark ? .dark : .light, lightBackground: .cream,
                                               darkBackground: .graphite, bubbleColor: .teal)
            let followed = context(.warm, dark: dark, followsTheme: true, bubble: .teal)
            #expect(resolve(followed, dark: dark) == resolve(old, dark: dark),
                    "Warm has no accent of its own, so Theme leaves your teal")
            #expect(resolve(old, dark: dark).messageSurfaceHex == nil, "bighelp's own see-through agent messages")
        }
    }

    @Test func lightAndDarkCanComeFromDifferentPresets() {
        let mixed = BighelpAppearanceContext(appearance: .system, lightBackground: .moss, darkBackground: .violet,
                                             bubbleFollowsTheme: true)
        #expect(resolve(mixed, dark: false).canvasHex == BighelpPresetPalette.mossLight.canvas)
        #expect(resolve(mixed, dark: true).canvasHex == BighelpPresetPalette.violetDark.canvas)
        #expect(mixed.bubbleHex(dark: false) == BighelpPresetPalette.mossLight.accent)
        #expect(mixed.bubbleHex(dark: true) == BighelpPresetPalette.violetDark.accent)
        // Classic by day keeps your own color there; the dark theme still brings its accent.
        let half = BighelpAppearanceContext(appearance: .system, lightBackground: .paper, darkBackground: .violet,
                                            bubbleColor: .rose, bubbleFollowsTheme: true)
        #expect(half.bubbleHex(dark: false) == BighelpBubbleColor.rose.hex)
        #expect(half.bubbleHex(dark: true) == BighelpPresetPalette.violetDark.accent)
        #expect(!half.usesInk(dark: false) && !half.usesInk(dark: true))
    }

    @Test func highContrastKeepsItsOwnNeutralsOverAPreset() {
        for dark in [false, true] {
            let preset = resolve(context(.berry, dark: dark), dark: dark, contrast: .increased)
            let classic = resolve(context(.classic, dark: dark), dark: dark, contrast: .increased)
            #expect(preset.canvasHex == classic.canvasHex)
            #expect(preset.primaryTextHex == classic.primaryTextHex)
            #expect(preset.messageSurfaceHex == nil)
        }
    }

    @Test func pickingAThemeFillsTheExistingSettings() {
        let suiteName = "theme-presets-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.pickBubbleColor(.ocean)
        settings.pickTheme(.moss, dark: false)
        #expect(settings.lightBackground == .moss && settings.darkBackground == .black)
        #expect(settings.bubbleFollowsTheme && settings.bubbleColorName == String(localized: "Theme"))
        #expect(settings.bubbleColor == .ocean, "Your own color stays for modes whose theme has no accent")
        settings.pickTheme(.violet, dark: true)
        #expect(settings.darkBackground == .violet && settings.lightBackground == .moss)

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.lightBackground == .moss && restored.darkBackground == .violet)
        #expect(restored.bubbleFollowsTheme)
        #expect(restored.appearanceContext.bubbleHex(dark: true) == BighelpPresetPalette.violetDark.accent)

        restored.pickBubbleColor(.rose)
        #expect(!restored.bubbleFollowsTheme, "A bubble color replaces the theme's")
        restored.pickTheme(.harbor, dark: false)
        restored.customBubbleHex = "#0E7C66"
        #expect(!restored.bubbleFollowsTheme, "So does a custom color")
        restored.pickTheme(.warm, dark: false)
        #expect(!restored.bubbleFollowsTheme, "Warm has no accent, so it leaves the bubbles alone")
    }

    @Test func choicesSavedBeforeThemesStayAsTheyWere() {
        let suiteName = "theme-presets-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("cream", forKey: "loopdy.appearance.lightBackground")
        defaults.set("graphite", forKey: "loopdy.appearance.darkBackground")
        defaults.set("tangerine", forKey: "loopdy.appearance.bubbleColor")
        let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("loopdy.appearance") }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.lightBackground == .cream && settings.darkBackground == .graphite)
        #expect(settings.lightBackground.preset == .warm && settings.darkBackground.preset == .warm)
        #expect(settings.bubbleColor == .tangerine && !settings.bubbleFollowsTheme)
        #expect(UserDefaults(suiteName: suiteName)?.string(forKey: ChatLayoutPreferences.agentMessageStyleKey) == nil,
                "Agent messages keep their bubble")
        let after = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("loopdy.appearance") }
        #expect(NSDictionary(dictionary: before).isEqual(to: after), "Opening the app rewrites nothing")
        for dark in [false, true] {
            let theme = resolve(settings.appearanceContext, dark: dark)
            #expect(theme.canvasHex == (dark ? "1C1C1F" : "FFF9F5"))
            #expect(theme.messageSurfaceHex == nil)
        }
        // Nothing saved is Classic: Paper and Black.
        let fresh = SettingsStore(defaults: UserDefaults(suiteName: suiteName + "-fresh")!)
        defer { defaults.removePersistentDomain(forName: suiteName + "-fresh") }
        #expect(fresh.lightBackground.preset == .classic && fresh.darkBackground.preset == .classic)
    }

    /// On the page an agent reply has no bubble: no fill, no padding across, the lane's full width.
    /// Your own messages, interim replies and the bubble look stay as they were.
    @Test func agentRepliesOnThePageDropOnlyTheirBubble() {
        typealias Layout = BighelpV3MessagePresentation
        for density in ChatDensity.allCases {
            let page = Layout.contentInsets(role: .assistant, density: density, agentStyle: .page, isInterim: false)
            #expect(page.leading == 0 && page.trailing == 0)
            #expect(!Layout.drawsBubble(role: .assistant, agentStyle: .page, isInterim: false))
            #expect(Layout.maximumWidthFraction(role: .assistant, hasRichContent: false, agentStyle: .page) == 1)
            #expect(Layout.maximumWidthFraction(role: .assistant, hasRichContent: true, agentStyle: .page) == 1)

            let bubble = Layout.contentInsets(role: .assistant, density: density, agentStyle: .bubble, isInterim: false)
            #expect(bubble.leading == density.bubbleHorizontalPadding && bubble.top == density.bubbleVerticalPadding)
            #expect(Layout.drawsBubble(role: .assistant, agentStyle: .bubble, isInterim: false))
            #expect(Layout.maximumWidthFraction(role: .assistant, hasRichContent: false, agentStyle: .bubble)
                    == Layout.incomingMaximumWidthFraction)

            for style in ChatAgentMessageStyle.allCases {
                #expect(Layout.drawsBubble(role: .human, agentStyle: style, isInterim: false), "Yours keep a bubble")
                #expect(Layout.contentInsets(role: .human, density: density, agentStyle: style, isInterim: false)
                        == bubble)
                #expect(Layout.maximumWidthFraction(role: .human, hasRichContent: false, agentStyle: style)
                        == Layout.outgoingMaximumWidthFraction)
                #expect(Layout.contentInsets(role: .assistant, density: density, agentStyle: style, isInterim: true)
                        == EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 0), "Interim replies keep their look")
            }
        }
    }

    /// A hold on a message reaches the strips around its text (the 2026-10-31 probe: the text view's
    /// own menu is never asked). A reply on the page keeps them, thin, so holding it still opens its menu.
    @Test func everyMessageKeepsItsHoldStrips() {
        typealias Layout = BighelpV3MessagePresentation
        #expect(Layout.menuEdgeThickness(role: .assistant, agentStyle: .page) == BighelpTokens.space4)
        #expect(Layout.menuEdgeThickness(role: .assistant, agentStyle: .bubble) == BighelpTokens.space16)
        for style in ChatAgentMessageStyle.allCases {
            #expect(Layout.menuEdgeThickness(role: .human, agentStyle: style) == BighelpTokens.space16)
        }
    }

    @Test func agentMessageStyleIsSavedAndStartsAsBubble() {
        #expect(ChatAgentMessageStyle(rawValue: "bubble") == .bubble && ChatAgentMessageStyle(rawValue: "page") == .page)
        #expect(ChatCanvasRowContext().agentStyle == .bubble)
        // The timeline draws every row again when it changes, as it does for density.
        #expect(ChatCanvasRowContext(agentStyle: .page) != ChatCanvasRowContext())
    }

    @Test func everyPresetHasBothModes() {
        for preset in BighelpThemePreset.allCases {
            #expect(preset.light.preset == preset && preset.dark.preset == preset, "\(preset)")
        }
        #expect(Set(BighelpThemePreset.allCases.map(\.light)).count == BighelpLightBackground.allCases.count)
        #expect(Set(BighelpThemePreset.allCases.map(\.dark)).count == BighelpDarkBackground.allCases.count)
    }

    // MARK: Helpers

    private static func color(_ hex: String) -> UIColor { UIColor(Color(hex: hex)) }

    private static func luminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func contrast(_ first: String, _ second: String) -> CGFloat {
        contrast(color(first), color(second))
    }

    private static func hueDistance(_ a: UIColor, _ b: UIColor) -> CGFloat {
        var (ha, hb): (CGFloat, CGFloat) = (0, 0)
        a.getHue(&ha, saturation: nil, brightness: nil, alpha: nil)
        b.getHue(&hb, saturation: nil, brightness: nil, alpha: nil)
        let distance = abs(ha - hb)
        return min(distance, 1 - distance)
    }
}
