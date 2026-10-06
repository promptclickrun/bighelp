import Foundation
import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }
}

struct BighelpThemeID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    static let bighelp = BighelpThemeID(rawValue: "loopdy")
}

enum BighelpThemeTypeface: String, Codable, Equatable, Sendable {
    case system
    case monospaced
    case rounded
    case serif
}

enum BighelpThemeIconStyle: String, Codable, Equatable, Sendable {
    case soft
    case technical
    case crisp
}

enum BighelpIconRenderingMode: Equatable, Sendable {
    case hierarchical
    case monochrome
}

enum BighelpIconSymbolVariant: Equatable, Sendable {
    case filled
    case outline
}

enum BighelpIconGlyphWeight: Equatable, Sendable {
    case regular
    case semibold
}

enum BighelpIconInnerWell: Equatable, Sendable {
    case tintedCircle
    case outlinedRoundedRectangle
    case none
}

struct BighelpIconPresentation: Equatable, Sendable {
    let renderingMode: BighelpIconRenderingMode
    let symbolVariant: BighelpIconSymbolVariant
    let glyphWeight: BighelpIconGlyphWeight
    let innerWell: BighelpIconInnerWell

    static func resolve(style: BighelpThemeIconStyle) -> BighelpIconPresentation {
        switch style {
        case .soft:
            BighelpIconPresentation(
                renderingMode: .hierarchical,
                symbolVariant: .filled,
                glyphWeight: .semibold,
                innerWell: .tintedCircle
            )
        case .technical:
            BighelpIconPresentation(
                renderingMode: .monochrome,
                symbolVariant: .outline,
                glyphWeight: .regular,
                innerWell: .outlinedRoundedRectangle
            )
        case .crisp:
            BighelpIconPresentation(
                renderingMode: .monochrome,
                symbolVariant: .outline,
                glyphWeight: .semibold,
                innerWell: .none
            )
        }
    }
}

struct BighelpThemeTypography: Codable, Equatable, Sendable {
    let displayFontNames: [String]
    let bodyFontNames: [String]
    let emphasizedBodyFontNames: [String]
    let codeFontNames: [String]
    let brandFontNames: [String]

    // Empty candidates select Apple's system font, preserving Dynamic Type.
    static let bighelp = BighelpThemeTypography(
        displayFontNames: [], bodyFontNames: [], emphasizedBodyFontNames: [],
        codeFontNames: [], brandFontNames: []
    )
}

struct BighelpTheme: Codable, Equatable, Sendable {
    let themeID: BighelpThemeID
    let typeface: BighelpThemeTypeface
    let typography: BighelpThemeTypography
    let iconStyle: BighelpThemeIconStyle
    let cornerScale: CGFloat
    let backgroundAccentHexes: [String]
    let canvasHex: String
    let surfaceHex: String
    let raisedSurfaceHex: String
    let primaryTextHex: String
    let secondaryTextHex: String
    let tertiaryTextHex: String
    let borderHex: String
    let separatorHex: String
    let actionHex: String
    let actionForegroundHex: String
    let actionGlowHex: String
    let elevationShadowHex: String
    let actionGlowOpacity: Double
    let cardShadowOpacity: Double
    let navigationShadowOpacity: Double
    let successHex: String
    let warningHex: String
    let dangerHex: String
    let informationHex: String
    let focusHex: String
    // Raw theme definitions remain exact, Codable design documents. Only
    // values returned by `resolve` opt into the shared live visual system.
    private var resolvesLiveSemantics = false
    /// Vision Pro: how strongly the theme color tints the window's glass. Set
    /// from Settings › Colors › Transparency; never part of a theme document.
    var visionCanvasOpacity = BighelpVisionGlass.canvasOpacity(forTransparency: BighelpVisionGlass.defaultTransparency)
    /// Vision Pro in light mode: grey text over a see-through window needs to be darker.
    var visionIsLight = false
    /// The bubble color picked in Settings › Appearance, before any contrast
    /// adjustment; nil is bighelp's own. Never part of a theme document.
    var chosenBubbleHex: String?

    private enum CodingKeys: String, CodingKey {
        case themeID
        case typeface
        case typography
        case iconStyle
        case cornerScale
        case backgroundAccentHexes
        case canvasHex
        case surfaceHex
        case raisedSurfaceHex
        case primaryTextHex
        case secondaryTextHex
        case tertiaryTextHex
        case borderHex
        case separatorHex
        case actionHex
        case actionForegroundHex
        case actionGlowHex
        case elevationShadowHex
        case actionGlowOpacity
        case cardShadowOpacity
        case navigationShadowOpacity
        case successHex
        case warningHex
        case dangerHex
        case informationHex
        case focusHex
    }

    init(
        themeID: BighelpThemeID = .bighelp,
        typeface: BighelpThemeTypeface = .system,
        typography: BighelpThemeTypography = .bighelp,
        iconStyle: BighelpThemeIconStyle = .crisp,
        cornerScale: CGFloat = 1,
        backgroundAccentHexes: [String] = ["FF5A4F", "FFB326", "ED4672"],
        canvasHex: String,
        surfaceHex: String,
        raisedSurfaceHex: String,
        primaryTextHex: String,
        secondaryTextHex: String,
        tertiaryTextHex: String,
        borderHex: String,
        separatorHex: String,
        actionHex: String,
        actionForegroundHex: String,
        actionGlowHex: String,
        elevationShadowHex: String,
        actionGlowOpacity: Double,
        cardShadowOpacity: Double,
        navigationShadowOpacity: Double,
        successHex: String,
        warningHex: String,
        dangerHex: String,
        informationHex: String,
        focusHex: String
    ) {
        self.themeID = themeID
        self.typeface = typeface
        self.typography = typography
        self.iconStyle = iconStyle
        self.cornerScale = cornerScale
        self.backgroundAccentHexes = backgroundAccentHexes
        self.canvasHex = canvasHex
        self.surfaceHex = surfaceHex
        self.raisedSurfaceHex = raisedSurfaceHex
        self.primaryTextHex = primaryTextHex
        self.secondaryTextHex = secondaryTextHex
        self.tertiaryTextHex = tertiaryTextHex
        self.borderHex = borderHex
        self.separatorHex = separatorHex
        self.actionHex = actionHex
        self.actionForegroundHex = actionForegroundHex
        self.actionGlowHex = actionGlowHex
        self.elevationShadowHex = elevationShadowHex
        self.actionGlowOpacity = actionGlowOpacity
        self.cardShadowOpacity = cardShadowOpacity
        self.navigationShadowOpacity = navigationShadowOpacity
        self.successHex = successHex
        self.warningHex = warningHex
        self.dangerHex = dangerHex
        self.informationHex = informationHex
        self.focusHex = focusHex
    }

    /// Live chrome uses the Ember neutrals (cream by day, "after dark" at night)
    /// carried in the resolved hexes. Raw partner/custom definitions remain
    /// directly renderable by theme editors and import/export flows.
    private var usesNativeSystemPalette: Bool { false }

    var canvas: Color {
        #if os(visionOS)
        // Vision Pro windows are glass. The tint keeps the theme's text
        // readable; how much of the room shows through is the person's call.
        Color(hex: canvasHex).opacity(visionCanvasOpacity)
        #else
        usesNativeSystemPalette ? Color(uiColor: .systemBackground) : Color(hex: canvasHex)
        #endif
    }
    var surface: Color {
        usesNativeSystemPalette ? Color(uiColor: .secondarySystemBackground) : Color(hex: surfaceHex)
    }
    var raisedSurface: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemBackground) : Color(hex: raisedSurfaceHex)
    }
    var primaryText: Color {
        usesNativeSystemPalette ? Color(uiColor: .label) : Color(hex: primaryTextHex)
    }
    var secondaryText: Color {
        #if os(visionOS)
        if visionIsLight { return Color(hex: secondaryTextHex).mix(with: Color(hex: primaryTextHex), by: 0.45) }
        #endif
        return usesNativeSystemPalette ? Color(uiColor: .secondaryLabel) : Color(hex: secondaryTextHex)
    }
    var tertiaryText: Color {
        #if os(visionOS)
        if visionIsLight { return Color(hex: tertiaryTextHex).mix(with: Color(hex: primaryTextHex), by: 0.5) }
        #endif
        return usesNativeSystemPalette ? Color(uiColor: .tertiaryLabel) : Color(hex: tertiaryTextHex)
    }
    var border: Color {
        usesNativeSystemPalette ? Color(uiColor: .separator) : Color(hex: borderHex)
    }
    var separator: Color {
        usesNativeSystemPalette ? Color(uiColor: .separator) : Color(hex: separatorHex)
    }
    var action: Color { Color(hex: actionHex) }
    var actionForeground: Color {
        guard resolvesLiveSemantics, themeID != .bighelp else { return Color(hex: actionForegroundHex) }
        let accent = liveActionUIColor
        return Color(uiColor: UIColor { traits in
            let resolvedAccent = accent.resolvedColor(with: traits)
            return Self.readableForeground(against: resolvedAccent)
        })
    }
    /// Outgoing messages always use white ink. Keep that policy separate from
    /// action/link ink, which must remain readable on neutral native surfaces.
    /// The authored accent is darkened only when its white-text contrast needs it;
    /// stored theme documents and the shared action API remain unchanged.
    var outgoingMessageForeground: Color { .white }
    var outgoingMessageBackground: Color {
        if themeID == .bighelp {
            // Lavender is bighelp's own purple; any other pick is darkened only as white text needs.
            guard let chosenBubbleHex else { return Color(hex: Self.emberOutgoingHex) }
            return accessibleOutgoingMessageBackground(accent: Self.uiColor(hex: chosenBubbleHex))
        }
        return accessibleOutgoingMessageBackground(
            accent: resolvesLiveSemantics ? liveActionUIColor : Self.uiColor(hex: actionHex)
        )
    }

    private func accessibleOutgoingMessageBackground(accent: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            Self.whiteTextBubbleBackground(
                accent.resolvedColor(with: traits),
                minimumContrast: 4.6
            )
        })
    }
    var actionGlow: Color { Color(hex: actionGlowHex) }

    /// Agent replies sit on a see-through neutral: a shade darker than the background by day and a
    /// shade lighter at night. It takes on the background behind it, so no theme clashes with it.
    var incomingMessageBackground: Color {
        Color(white: isDarkPalette ? 1 : 0, opacity: incomingMessageOpacity)
    }

    /// The same neutral laid over the background, for colors that are mixed from it (loaders).
    var incomingMessageSolid: Color {
        BighelpLoaderColor.mix(Color(hex: canvasHex), Color(white: isDarkPalette ? 1 : 0), by: incomingMessageOpacity)
    }

    private var incomingMessageOpacity: Double { isDarkPalette ? 0.11 : 0.055 }

    var isDarkPalette: Bool {
        let value = UInt64(canvasHex, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.4
    }

    static let emberOutgoingHex = "7B52E0"
    var elevationShadow: Color { Color(hex: elevationShadowHex) }
    var success: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemGreen) : Color(hex: successHex)
    }
    var warning: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemOrange) : Color(hex: warningHex)
    }
    var danger: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemRed) : Color(hex: dangerHex)
    }
    var information: Color {
        usesNativeSystemPalette ? Color(uiColor: .systemBlue) : Color(hex: informationHex)
    }
    var focus: Color {
        resolvesLiveSemantics ? action : Color(hex: focusHex)
    }
    var backgroundAccents: [Color] {
        resolvesLiveSemantics
            ? [surface, raisedSurface]
            : backgroundAccentHexes.map(Color.init(hex:))
    }

    var cardBackground: Color { surface }
    var navigationBackground: Color { raisedSurface }
    var statusBackground: Color { raisedSurface }

    private var liveActionUIColor: UIColor { Self.uiColor(hex: actionHex) }

    private static func uiColor(hex: String) -> UIColor {
        let value = UInt64(hex, radix: 16) ?? 0
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func whiteTextBubbleBackground(
        _ accent: UIColor,
        minimumContrast: CGFloat
    ) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        guard accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return UIColor(red: 0, green: 0.32, blue: 0.68, alpha: 1)
        }

        func whiteContrast(scale: CGFloat) -> CGFloat {
            let luminance = 0.2126 * linearChannel(red * scale)
                + 0.7152 * linearChannel(green * scale)
                + 0.0722 * linearChannel(blue * scale)
            return 1.05 / (luminance + 0.05)
        }

        guard whiteContrast(scale: 1) < minimumContrast else { return accent }
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<14 {
            let midpoint = (lower + upper) / 2
            if whiteContrast(scale: midpoint) >= minimumContrast {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return UIColor(red: red * lower, green: green * lower, blue: blue * lower, alpha: alpha)
    }

    private static func readableForeground(against background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            return .label
        }
        let luminance = 0.2126 * linearChannel(red)
            + 0.7152 * linearChannel(green)
            + 0.0722 * linearChannel(blue)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast ? .white : .black
    }

    private static func linearChannel(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045
            ? channel / 12.92
            : CGFloat(pow(Double((channel + 0.055) / 1.055), 2.4))
    }

    static let light = BighelpTheme(
        canvasHex: "FFF9F5",
        surfaceHex: "FFFFFF",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "1C1A19",
        secondaryTextHex: "6F6762",
        tertiaryTextHex: "8F8781",
        borderHex: "E9E1DB",
        separatorHex: "EDE6E0",
        actionHex: "7B52E0",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "7B52E0",
        elevationShadowHex: "1C1A19",
        actionGlowOpacity: 0.30,
        cardShadowOpacity: 0.06,
        navigationShadowOpacity: 0.12,
        successHex: "1E7A4E",
        warningHex: "A85D00",
        dangerHex: "D33F42",
        informationHex: "1769AA",
        focusHex: "9A6BFF"
    )

    static let lightHighContrast = BighelpTheme(
        canvasHex: "FFFFFF",
        surfaceHex: "FFFFFF",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "000000",
        secondaryTextHex: "3F3A36",
        tertiaryTextHex: "514B47",
        borderHex: "6F6660",
        separatorHex: "8A817B",
        actionHex: "5E36C7",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "5E36C7",
        elevationShadowHex: "1B1917",
        actionGlowOpacity: 0.35,
        cardShadowOpacity: 0.12,
        navigationShadowOpacity: 0.20,
        successHex: "0E572B",
        warningHex: "7A4200",
        dangerHex: "8F1710",
        informationHex: "0D568D",
        focusHex: "5E36C7"
    )

    static let dark = BighelpTheme(
        canvasHex: "121110",
        surfaceHex: "1E1C1B",
        raisedSurfaceHex: "292624",
        primaryTextHex: "F5F2EF",
        secondaryTextHex: "A39B95",
        tertiaryTextHex: "857D77",
        borderHex: "33302E",
        separatorHex: "292624",
        actionHex: "C9B6FF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "9A6BFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.35,
        cardShadowOpacity: 0.20,
        navigationShadowOpacity: 0.30,
        successHex: "5BC98A",
        warningHex: "F3B24F",
        dangerHex: "FF8A7A",
        informationHex: "69B7ED",
        focusHex: "C9B6FF"
    )

    /// Light "Paper": white pages and cool neutral grays.
    static let paperLight = BighelpTheme(
        canvasHex: "FFFFFF",
        surfaceHex: "F4F4F6",
        raisedSurfaceHex: "FFFFFF",
        primaryTextHex: "1C1C1E",
        secondaryTextHex: "6C6C72",
        tertiaryTextHex: "8C8C92",
        borderHex: "E3E3E8",
        separatorHex: "EBEBEF",
        actionHex: "7B52E0",
        actionForegroundHex: "FFFFFF",
        actionGlowHex: "7B52E0",
        elevationShadowHex: "1C1C1E",
        actionGlowOpacity: 0.28,
        cardShadowOpacity: 0.06,
        navigationShadowOpacity: 0.12,
        successHex: "1E7A4E",
        warningHex: "A85D00",
        dangerHex: "D33F42",
        informationHex: "1769AA",
        focusHex: "9A6BFF"
    )

    /// Dark "Graphite": a soft, washed charcoal instead of pure black.
    static let graphiteDark = BighelpTheme(
        canvasHex: "1C1C1F",
        surfaceHex: "27272B",
        raisedSurfaceHex: "313136",
        primaryTextHex: "F4F4F6",
        secondaryTextHex: "A3A3AA",
        tertiaryTextHex: "85858C",
        borderHex: "3B3B41",
        separatorHex: "2E2E33",
        actionHex: "C9B6FF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "9A6BFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.35,
        cardShadowOpacity: 0.22,
        navigationShadowOpacity: 0.30,
        successHex: "5BC98A",
        warningHex: "F3B24F",
        dangerHex: "FF8A7A",
        informationHex: "69B7ED",
        focusHex: "C9B6FF"
    )

    /// Dark "Black": true black pages for OLED screens.
    static let blackDark = BighelpTheme(
        canvasHex: "000000",
        surfaceHex: "151516",
        raisedSurfaceHex: "1F1F21",
        primaryTextHex: "F5F5F7",
        secondaryTextHex: "A1A1A6",
        tertiaryTextHex: "838388",
        borderHex: "2E2E31",
        separatorHex: "1E1E20",
        actionHex: "C9B6FF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "9A6BFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.38,
        cardShadowOpacity: 0.30,
        navigationShadowOpacity: 0.38,
        successHex: "5BC98A",
        warningHex: "F3B24F",
        dangerHex: "FF8A7A",
        informationHex: "69B7ED",
        focusHex: "C9B6FF"
    )

    static let darkHighContrast = BighelpTheme(
        canvasHex: "000000",
        surfaceHex: "1C1A19",
        raisedSurfaceHex: "292624",
        primaryTextHex: "FFFFFF",
        secondaryTextHex: "E5DED9",
        tertiaryTextHex: "CFC6C0",
        borderHex: "B8AEA7",
        separatorHex: "817871",
        actionHex: "DCCFFF",
        actionForegroundHex: "1C1A19",
        actionGlowHex: "DCCFFF",
        elevationShadowHex: "000000",
        actionGlowOpacity: 0.40,
        cardShadowOpacity: 0.32,
        navigationShadowOpacity: 0.45,
        successHex: "82E39E",
        warningHex: "FFD06D",
        dangerHex: "FF9B93",
        informationHex: "8FD0FF",
        focusHex: "DCCFFF"
    )

    static func resolve(
        appearance: AppAppearance,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> BighelpTheme {
        resolve(
            definition: BighelpThemeRegistry.ember,
            appearance: appearance,
            colorScheme: colorScheme,
            contrast: contrast
        )
    }

    /// Projects a stored theme into the one live native visual language. The
    /// selected light/dark action ink is the sole palette variation; canvas,
    /// cards, labels, type, symbols, geometry, and statuses come from iOS.
    private func resolvedForLivePresentation(
        neutral: BighelpTheme,
        resolvedActionHex: String,
        actionForegroundHex foregroundOverride: String? = nil
    ) -> BighelpTheme {
        // Ember declares its action ink: white on violet by day, ink on lavender after dark.
        let resolvedActionForegroundHex = foregroundOverride ?? (themeID == .bighelp
            ? actionForegroundHex
            : Self.readableForegroundHex(against: resolvedActionHex))
        var resolved = BighelpTheme(
            themeID: themeID,
            typeface: .system,
            typography: .bighelp,
            iconStyle: .crisp,
            cornerScale: 1,
            backgroundAccentHexes: neutral.backgroundAccentHexes,
            canvasHex: neutral.canvasHex,
            surfaceHex: neutral.surfaceHex,
            raisedSurfaceHex: neutral.raisedSurfaceHex,
            primaryTextHex: neutral.primaryTextHex,
            secondaryTextHex: neutral.secondaryTextHex,
            tertiaryTextHex: neutral.tertiaryTextHex,
            borderHex: neutral.borderHex,
            separatorHex: neutral.separatorHex,
            actionHex: resolvedActionHex,
            actionForegroundHex: resolvedActionForegroundHex,
            actionGlowHex: resolvedActionHex,
            elevationShadowHex: neutral.elevationShadowHex,
            actionGlowOpacity: neutral.actionGlowOpacity,
            cardShadowOpacity: neutral.cardShadowOpacity,
            navigationShadowOpacity: neutral.navigationShadowOpacity,
            successHex: neutral.successHex,
            warningHex: neutral.warningHex,
            dangerHex: neutral.dangerHex,
            informationHex: neutral.informationHex,
            focusHex: resolvedActionHex
        )
        resolved.resolvesLiveSemantics = true
        return resolved
    }

    /// Preserve the authored hue while keeping custom action/link ink visible
    /// on the native canvas, cards and incoming bubbles in either appearance,
    /// and on the chosen page color (Cream/Paper, Graphite/Black).
    private static func readableAccentHex(_ hex: String, isDark: Bool, increasedContrast: Bool,
                                          on neutral: BighelpTheme) -> String {
        let value = UInt64(hex, radix: 16) ?? 0
        let channels = [CGFloat((value >> 16) & 0xFF) / 255,
                        CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255]
        func luminance(_ components: [CGFloat]) -> CGFloat {
            0.2126 * linearChannel(components[0]) + 0.7152 * linearChannel(components[1])
                + 0.0722 * linearChannel(components[2])
        }
        let backgrounds = [UIUserInterfaceLevel.base, .elevated].flatMap { level in
            let traits = UITraitCollection {
                $0.userInterfaceStyle = isDark ? .dark : .light
                $0.accessibilityContrast = increasedContrast ? .high : .normal
                $0.userInterfaceLevel = level
            }
            return [UIColor.systemBackground, .secondarySystemBackground, .systemGray5].map { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
                color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: nil)
                return luminance([red, green, blue])
            }
        } + [neutral.canvasHex, neutral.surfaceHex, neutral.raisedSurfaceHex].map { surface in
            let value = UInt64(surface, radix: 16) ?? 0
            return luminance([CGFloat((value >> 16) & 0xFF) / 255,
                              CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255])
        }
        func leastContrast(_ components: [CGFloat]) -> CGFloat {
            let ink = luminance(components)
            return backgrounds.map { (max(ink, $0) + 0.05) / (min(ink, $0) + 0.05) }.min() ?? 1
        }
        guard leastContrast(channels) < 4.5 else { return hex }
        let target: CGFloat = isDark ? 1 : 0
        func mixed(_ amount: CGFloat) -> [CGFloat] {
            channels.map { (($0 + (target - $0) * amount) * 255).rounded() / 255 }
        }
        var lower: CGFloat = 0, upper: CGFloat = 1
        for _ in 0..<12 {
            let midpoint = (lower + upper) / 2
            if leastContrast(mixed(midpoint)) >= 4.6 { upper = midpoint } else { lower = midpoint }
        }
        let result = mixed(upper)
        return String(format: "%02X%02X%02X", Int((result[0] * 255).rounded()),
                      Int((result[1] * 255).rounded()), Int((result[2] * 255).rounded()))
    }

    private static func readableForegroundHex(against backgroundHex: String) -> String {
        let value = UInt64(backgroundHex, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        let luminance = 0.2126 * linearChannel(red)
            + 0.7152 * linearChannel(green)
            + 0.0722 * linearChannel(blue)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast ? "FFFFFF" : "000000"
    }
}

struct BighelpThemeDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: BighelpThemeID
    let name: String
    let summary: String
    let light: BighelpTheme
    let lightHighContrast: BighelpTheme
    let dark: BighelpTheme
    let darkHighContrast: BighelpTheme
}

/// bighelp's one look. Your bubble color and light and dark backgrounds
/// (Settings › Appearance) are applied on top of it.
enum BighelpThemeRegistry {
    static let ember = BighelpThemeDefinition(
        id: .bighelp,
        name: "Ember",
        summary: "Warm cream by day, after dark at night, with lavender actions.",
        light: .light,
        lightHighContrast: .lightHighContrast,
        dark: .dark,
        darkHighContrast: .darkHighContrast
    )
}

struct BighelpAppearanceContext: Equatable, Sendable {
    let appearance: AppAppearance
    var lightBackground: BighelpLightBackground = .cream
    var darkBackground: BighelpDarkBackground = .graphite
    /// Your bubbles and buttons. Nil is bighelp's own lavender.
    var bubbleColor: BighelpBubbleColor?
    /// A color you picked yourself; wins over `bubbleColor`.
    var customBubbleHex: String?
    /// The color your bubbles start from, or nil for bighelp's own.
    var bubbleHex: String? { customBubbleHex ?? bubbleColor?.hex }
    /// Vision Pro: 0 is a solid window, 1 shows the room through the glass.
    var windowTransparency = BighelpVisionGlass.defaultTransparency

    init(
        appearance: AppAppearance,
        lightBackground: BighelpLightBackground = .cream,
        darkBackground: BighelpDarkBackground = .graphite,
        bubbleColor: BighelpBubbleColor? = nil,
        customBubbleHex: String? = nil,
        windowTransparency: Double = BighelpVisionGlass.defaultTransparency
    ) {
        self.appearance = appearance
        self.lightBackground = lightBackground
        self.darkBackground = darkBackground
        self.bubbleColor = bubbleColor
        self.customBubbleHex = BighelpCustomBubbleColor.validated(customBubbleHex)
        self.windowTransparency = windowTransparency
    }
}

extension BighelpTheme {
    static func resolve(
        appearance context: BighelpAppearanceContext,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> BighelpTheme {
        let definition = BighelpThemeRegistry.ember
        let dark = context.appearance == .dark || (context.appearance == .system && colorScheme == .dark)
        let selected = switch (dark, contrast) {
        case (false, .standard): definition.light
        case (false, .increased): definition.lightHighContrast
        case (true, .standard): definition.dark
        case (true, .increased): definition.darkHighContrast
        @unknown default: dark ? definition.dark : definition.light
        }
        var theme = selected.resolvedForLivePresentation(
            colorScheme: dark ? .dark : .light, contrast: contrast,
            lightBackground: context.lightBackground, darkBackground: context.darkBackground,
            bubbleColor: context.bubbleColor, customBubbleHex: context.customBubbleHex)
        theme.chosenBubbleHex = context.bubbleHex
        theme.visionCanvasOpacity = BighelpVisionGlass.canvasOpacity(forTransparency: context.windowTransparency,
                                                                     dark: dark)
        theme.visionIsLight = !dark
        return theme
    }

    static func resolve(
        definition: BighelpThemeDefinition,
        appearance: AppAppearance,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> BighelpTheme {
        let dark = appearance == .dark || (appearance == .system && colorScheme == .dark)
        let selected = switch (dark, contrast) {
        case (false, .standard): definition.light
        case (false, .increased): definition.lightHighContrast
        case (true, .standard): definition.dark
        case (true, .increased): definition.darkHighContrast
        @unknown default: dark ? definition.dark : definition.light
        }
        return selected.resolvedForLivePresentation(colorScheme: dark ? .dark : .light, contrast: contrast)
    }

    /// Used by live settings samples after selecting an explicit document palette.
    /// The stored document itself is never rewritten.
    func resolvedForLivePresentation(
        colorScheme: ColorScheme, contrast: ColorSchemeContrast,
        lightBackground: BighelpLightBackground = .cream, darkBackground: BighelpDarkBackground = .graphite,
        bubbleColor: BighelpBubbleColor? = nil, customBubbleHex: String? = nil
    ) -> BighelpTheme {
        let dark = colorScheme == .dark
        let neutralDefinition = BighelpThemeRegistry.ember
        let neutral = switch (dark, contrast) {
        case (false, .standard): lightBackground.neutral
        case (false, .increased): neutralDefinition.lightHighContrast
        case (true, .standard): darkBackground.neutral
        case (true, .increased): neutralDefinition.darkHighContrast
        @unknown default: dark ? darkBackground.neutral : lightBackground.neutral
        }
        let increased = contrast == .increased
        if let bubbleHex = customBubbleHex ?? bubbleColor?.hex {
            let action = Self.readableAccentHex(bubbleHex, isDark: dark, increasedContrast: increased, on: neutral)
            return resolvedForLivePresentation(neutral: neutral, resolvedActionHex: action,
                                               actionForegroundHex: Self.readableForegroundHex(against: action))
        }
        if bubbleColor == .lavender {
            // bighelp's own lavender: violet by day, lighter after dark.
            let ember = increased ? (dark ? BighelpTheme.darkHighContrast : BighelpTheme.lightHighContrast) : neutral
            return resolvedForLivePresentation(neutral: neutral, resolvedActionHex: ember.actionHex,
                                               actionForegroundHex: ember.actionForegroundHex)
        }
        return resolvedForLivePresentation(
            neutral: neutral,
            resolvedActionHex: themeID == .bighelp
                ? actionHex
                : Self.readableAccentHex(actionHex, isDark: dark, increasedContrast: increased, on: neutral)
        )
    }
}

extension EnvironmentValues {
    /// Shared opt-in contract for signed-in and signed-out presentation.
    @Entry var bighelpUIV2Enabled: Bool = false
    @Entry var bighelpUIV3Enabled: Bool = false

    @Entry var appAppearance = BighelpAppearanceContext(appearance: .system)
}

enum BighelpFontRole: Sendable {
    case display
    case screenTitle
    case sectionTitle
    case body
    case label
    case metadata
    case code
    case brand

    fileprivate var textStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .screenTitle: .title2
        case .sectionTitle, .brand: .title3
        case .body: .body
        case .label: .subheadline
        case .metadata: .caption
        case .code: .callout
        }
    }

    fileprivate var size: CGFloat {
        switch self {
        case .display: 34
        case .screenTitle: 22
        case .sectionTitle, .brand: 20
        case .body: 17
        case .label: 15
        case .metadata: 12
        case .code: 16
        }
    }

    /// The Mac's size at the chosen text size (its text styles are fixed).
    fileprivate var macSize: CGFloat {
        (size * BighelpInterfaceSize.shared.textSize.macFactor * 2).rounded() / 2
    }

    fileprivate var weight: Font.Weight {
        switch self {
        case .display, .screenTitle: .bold
        case .sectionTitle, .label, .brand: .semibold
        case .body, .metadata, .code: .regular
        }
    }

    fileprivate var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .display: .largeTitle
        case .screenTitle: .title2
        case .sectionTitle, .brand: .title3
        case .body: .body
        case .label: .subheadline
        case .metadata: .caption1
        case .code: .callout
        }
    }

    fileprivate var uiWeight: UIFont.Weight {
        switch self {
        case .display, .screenTitle: .bold
        case .sectionTitle, .label, .brand: .semibold
        case .body, .metadata, .code: .regular
        }
    }

    fileprivate var isReflectiveHeading: Bool {
        switch self {
        case .display, .screenTitle, .sectionTitle:
            true
        case .body, .label, .metadata, .code, .brand:
            false
        }
    }
}

extension BighelpTheme {
    func font(
        _ role: BighelpFontRole,
        weight overrideWeight: Font.Weight? = nil,
        italic: Bool = false
    ) -> Font {
        let weight = overrideWeight ?? role.weight
        let candidates: [String]
        switch role {
        case .display, .screenTitle, .sectionTitle:
            candidates = typography.displayFontNames
        case .label:
            candidates = typography.emphasizedBodyFontNames
        case .body, .metadata:
            candidates = usesEmphasizedFace(weight)
                ? typography.emphasizedBodyFontNames
                : typography.bodyFontNames
        case .code:
            candidates = typography.codeFontNames
        case .brand:
            candidates = typography.brandFontNames
        }

        let resolved: Font
        if let name = BighelpFontCatalog.resolveFontName(candidates: candidates, in: .main) {
            #if targetEnvironment(macCatalyst)
            resolved = Font.custom(name, fixedSize: role.macSize).weight(weight)
            #else
            resolved = Font.custom(name, size: role.size, relativeTo: role.textStyle)
                .weight(weight)
            #endif
        } else {
            let design: Font.Design
            if role == .code {
                design = .monospaced
            } else {
                design = switch typeface {
                case .system: .default
                case .monospaced: .monospaced
                case .rounded: .rounded
                case .serif: .serif
                }
            }
            #if targetEnvironment(macCatalyst)
            resolved = .system(size: role.macSize, weight: weight, design: design)
            #else
            resolved = .system(role.textStyle, design: design, weight: weight)
            #endif
        }
        return italic ? resolved.italic() : resolved
    }

    func uiFont(
        _ role: BighelpFontRole,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        let candidates = fontCandidates(
            for: role,
            usesEmphasizedFace: role.uiWeight >= .semibold
        )
        let metrics = UIFontMetrics(forTextStyle: role.uiTextStyle)
        #if targetEnvironment(macCatalyst)
        // The Mac's text styles are fixed; use the chosen text size directly.
        let size = role.macSize
        func scaled(_ font: UIFont) -> UIFont { font }
        #else
        let size = role.size
        func scaled(_ font: UIFont) -> UIFont { metrics.scaledFont(for: font, compatibleWith: traitCollection) }
        #endif

        if let name = BighelpFontCatalog.resolveFontName(candidates: candidates, in: .main),
           let font = UIFont(name: name, size: size) {
            return scaled(font)
        }

        let baseFont = UIFont.systemFont(ofSize: size, weight: role.uiWeight)
        let design: UIFontDescriptor.SystemDesign? = if role == .code {
            .monospaced
        } else {
            switch typeface {
            case .system: nil
            case .monospaced: .monospaced
            case .rounded: .rounded
            case .serif: .serif
            }
        }
        let designedFont: UIFont
        if let design,
           let descriptor = baseFont.fontDescriptor.withDesign(design) {
            designedFont = UIFont(descriptor: descriptor, size: size)
        } else {
            designedFont = baseFont
        }
        return scaled(designedFont)
    }

    private func fontCandidates(
        for role: BighelpFontRole,
        usesEmphasizedFace: Bool
    ) -> [String] {
        switch role {
        case .display, .screenTitle, .sectionTitle:
            typography.displayFontNames
        case .label:
            typography.emphasizedBodyFontNames
        case .body, .metadata:
            usesEmphasizedFace
                ? typography.emphasizedBodyFontNames
                : typography.bodyFontNames
        case .code:
            typography.codeFontNames
        case .brand:
            typography.brandFontNames
        }
    }

    private func usesEmphasizedFace(_ weight: Font.Weight) -> Bool {
        weight == .medium
            || weight == .semibold
            || weight == .bold
            || weight == .heavy
            || weight == .black
    }
}

private struct BighelpFontModifier: ViewModifier {
    let role: BighelpFontRole
    let weight: Font.Weight?
    let italic: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance

    func body(content: Content) -> some View {
        let theme = BighelpTheme.resolve(
            appearance: appAppearance,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
        content
            .font(theme.font(role, weight: weight, italic: italic))
            .reflectiveVisionMaterial(isEligible: role.isReflectiveHeading)
    }
}

extension View {
    nonisolated func bighelpFont(
        _ role: BighelpFontRole,
        weight: Font.Weight? = nil,
        italic: Bool = false
    ) -> some View {
        modifier(BighelpFontModifier(role: role, weight: weight, italic: italic))
    }
}

private struct BighelpThemePresentationModifier: ViewModifier {
    let theme: BighelpTheme

    // Keep the content at one structural identity while a theme changes.
    // Branching around content destroys in-progress onboarding and form state.
    func body(content: Content) -> some View {
        content
            .fontDesign(fontDesign)
            .symbolRenderingMode(theme.iconStyle == .soft ? .hierarchical : .monochrome)
            .symbolVariant(theme.iconStyle == .soft ? .fill : .none)
    }

    private var fontDesign: Font.Design {
        switch theme.typeface {
        case .system: .default
        case .monospaced: .monospaced
        case .rounded: .rounded
        case .serif: .serif
        }
    }
}

extension View {
    func bighelpThemePresentation(_ theme: BighelpTheme) -> some View {
        font(theme.font(.body))
            .modifier(BighelpThemePresentationModifier(theme: theme))
            .modifier(BighelpV2DefaultsModifier(theme: theme))
    }
}

struct BighelpThemeCanvas: View {
    let theme: BighelpTheme

    var body: some View {
        theme.canvas
            .accessibilityHidden(true)
    }
}

// Some system designs (including SF Rounded) have no italic face. Preserve
// Markdown emphasis with the matching system italic face when UIKit cannot
// provide those traits in the chosen family.
extension UIFont {
    func bighelpApplyingTraits(_ requested: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let traits = fontDescriptor.symbolicTraits.union(requested)
        let candidate = fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: pointSize) } ?? self
        guard requested.contains(.traitItalic), !candidate.fontDescriptor.symbolicTraits.contains(.traitItalic) else {
            return candidate
        }
        let base = traits.contains(.traitMonoSpace)
            ? UIFont.monospacedSystemFont(ofSize: pointSize, weight: traits.contains(.traitBold) ? .bold : .regular)
            : UIFont.systemFont(ofSize: pointSize, weight: traits.contains(.traitBold) ? .bold : .regular)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return candidate }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// Vision Pro windows are glass with the theme's canvas color over it.
enum BighelpVisionGlass {
    /// A little more of the room than a half tint.
    static let defaultTransparency = 0.6

    /// Transparency 0 → nearly solid; 1 → as clear as stays readable. Dark
    /// windows can go almost bare (the system glass blurs and dims the room).
    /// Light windows keep a real tint: dark text on bare glass vanishes in a
    /// dim room.
    static func canvasOpacity(forTransparency transparency: Double, dark: Bool = true) -> Double {
        let clamped = transparency.isFinite ? min(max(transparency, 0), 1) : defaultTransparency
        return dark ? 0.92 - clamped * 0.88 : 0.97 - clamped * 0.52
    }
}
