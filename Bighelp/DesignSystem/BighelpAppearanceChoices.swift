import SwiftUI
import UIKit

/// A theme in Settings › Appearance › Themes: a light and a dark page, picked separately. Classic and
/// Warm are bighelp's own pages (Paper and Black, Cream and Graphite) and keep your bubble color; the
/// others bring their own accent and agent message color. Their palettes are ported from T3 Code
/// (github.com/pingdotgg/t3code, MIT License, Copyright 2026 T3 Tools Inc.), under names of our own.
enum BighelpThemePreset: String, CaseIterable, Identifiable, Sendable {
    case classic, warm, steel, berry, moss, harbor, clay, violet

    var id: String { rawValue }

    var name: String {
        switch self {
        case .classic: String(localized: "Classic")
        case .warm: String(localized: "Warm")
        case .steel: String(localized: "Steel")
        case .berry: String(localized: "Berry")
        case .moss: String(localized: "Moss")
        case .harbor: String(localized: "Harbor")
        case .clay: String(localized: "Clay")
        case .violet: String(localized: "Violet")
        }
    }

    var light: BighelpLightBackground {
        switch self {
        case .classic: .paper
        case .warm: .cream
        case .steel: .steel
        case .berry: .berry
        case .moss: .moss
        case .harbor: .harbor
        case .clay: .clay
        case .violet: .violet
        }
    }

    var dark: BighelpDarkBackground {
        switch self {
        case .classic: .black
        case .warm: .graphite
        case .steel: .steel
        case .berry: .berry
        case .moss: .moss
        case .harbor: .harbor
        case .clay: .clay
        case .violet: .violet
        }
    }

    /// Nil for bighelp's own pages, which have no accent or message color of their own.
    func palette(dark: Bool) -> BighelpPresetPalette? {
        switch self {
        case .classic, .warm: nil
        case .steel: dark ? .steelDark : .steelLight
        case .berry: dark ? .berryDark : .berryLight
        case .moss: dark ? .mossDark : .mossLight
        case .harbor: dark ? .harborDark : .harborLight
        case .clay: dark ? .clayDark : .clayLight
        case .violet: dark ? .violetDark : .violetLight
        }
    }

    /// The bubble color this theme brings, if it has one.
    func accentHex(dark: Bool) -> String? { palette(dark: dark)?.accent }
}

/// One mode of a ported theme, as sRGB hex. `Scripts/theme-presets.py` writes the values
/// (`BighelpThemePresetPalettes.swift`).
struct BighelpPresetPalette: Equatable, Sendable {
    let canvas: String
    let surface: String
    let surfaceRaised: String
    let text: String
    let textMuted: String
    let border: String
    let accent: String
    let messageSurface: String

    /// The palette as a page: statuses come from bighelp's own page for the mode.
    func neutral(dark: Bool) -> BighelpTheme {
        let base: BighelpTheme = dark ? .blackDark : .paperLight
        // Some themes draw cards in the page color and lift only raised ones; cards need to show.
        let cards = surface == canvas ? surfaceRaised : surface
        var theme = BighelpTheme(
            canvasHex: canvas, surfaceHex: cards, raisedSurfaceHex: surfaceRaised == canvas ? surface : surfaceRaised,
            primaryTextHex: text, secondaryTextHex: textMuted,
            tertiaryTextHex: Self.mix(textMuted, canvas, by: 0.2),
            borderHex: border, separatorHex: Self.mix(border, canvas, by: 0.35),
            actionHex: accent, actionForegroundHex: base.actionForegroundHex, actionGlowHex: accent,
            elevationShadowHex: base.elevationShadowHex, actionGlowOpacity: base.actionGlowOpacity,
            cardShadowOpacity: base.cardShadowOpacity, navigationShadowOpacity: base.navigationShadowOpacity,
            successHex: base.successHex, warningHex: base.warningHex, dangerHex: base.dangerHex,
            informationHex: base.informationHex, focusHex: accent)
        theme.messageSurfaceHex = messageSurface
        return theme
    }

    private static func mix(_ first: String, _ second: String, by amount: Double) -> String {
        let a = UInt64(first, radix: 16) ?? 0, b = UInt64(second, radix: 16) ?? 0
        return [16, 8, 0].map { shift -> String in
            let x = Double((a >> UInt64(shift)) & 0xFF), y = Double((b >> UInt64(shift)) & 0xFF)
            return String(format: "%02X", Int((x + (y - x) * amount).rounded()))
        }.joined()
    }
}

/// Light mode's page: one of the Themes. The raw names are what's saved, so Cream and Paper never
/// change; Paper is Classic's.
enum BighelpLightBackground: String, CaseIterable, Identifiable, Sendable {
    case cream, paper, steel, berry, moss, harbor, clay, violet

    var id: String { rawValue }
    var preset: BighelpThemePreset { BighelpThemePreset.allCases.first { $0.light == self } ?? .classic }
    var name: String {
        switch self {
        case .cream: String(localized: "Cream")
        case .paper: String(localized: "Paper")
        default: preset.name
        }
    }
    var detail: String { self == .cream ? String(localized: "Warm and soft") : String(localized: "Clean, bright white") }
    var neutral: BighelpTheme {
        switch self {
        case .cream: .light
        case .paper: .paperLight
        default: preset.palette(dark: false)?.neutral(dark: false) ?? .paperLight
        }
    }
}

/// Dark mode's page: one of the Themes. Graphite and Black keep their saved names; Black is Classic's.
enum BighelpDarkBackground: String, CaseIterable, Identifiable, Sendable {
    case graphite, black, steel, berry, moss, harbor, clay, violet

    var id: String { rawValue }
    var preset: BighelpThemePreset { BighelpThemePreset.allCases.first { $0.dark == self } ?? .classic }
    var name: String {
        switch self {
        case .graphite: String(localized: "Graphite")
        case .black: String(localized: "Black")
        default: preset.name
        }
    }
    var detail: String { self == .graphite ? String(localized: "Soft charcoal, easy on the eyes") : String(localized: "True black, saves battery on OLED") }
    var neutral: BighelpTheme {
        switch self {
        case .graphite: .graphiteDark
        case .black: .blackDark
        default: preset.palette(dark: true)?.neutral(dark: true) ?? .blackDark
        }
    }
}

/// Your chat bubble (and button) color. Ink is the default. Lavender is bighelp's own violet,
/// which shifts lighter after dark; the rest keep their hue and adjust for contrast.
enum BighelpBubbleColor: String, CaseIterable, Identifiable, Sendable {
    // Ink (`graphite`, the default) first. The raw names are what's saved, so they never change.
    case graphite, lavender, grape, ocean, sky, teal, mint, lime, sunflower, tangerine, coral, rose

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lavender: String(localized: "Lavender")
        case .grape: String(localized: "Grape")
        case .ocean: String(localized: "Ocean")
        case .sky: String(localized: "Sky")
        case .teal: String(localized: "Teal")
        case .mint: String(localized: "Mint")
        case .lime: String(localized: "Lime")
        case .sunflower: String(localized: "Sunflower")
        case .tangerine: String(localized: "Tangerine")
        case .coral: String(localized: "Coral")
        case .rose: String(localized: "Rose")
        case .graphite: String(localized: "Ink")
        }
    }

    /// Nil for Lavender: bighelp's built-in violet/lavender pair is used as is.
    var hex: String? {
        switch self {
        case .lavender: nil
        case .grape: "8E44CF"
        case .ocean: "2F6FEB"
        case .sky: "2BA3E8"
        case .teal: "0E9E97"
        case .mint: "22A565"
        case .lime: "6BA30F"
        case .sunflower: "D99A00"
        case .tangerine: "F2711C"
        case .coral: "F0524F"
        case .rose: "E0457B"
        case .graphite: "3A3A3F"
        }
    }

    /// What the swatch shows: Ink's black, Lavender's daytime violet.
    var swatchHex: String { self == .graphite ? "111111" : hex ?? "7B52E0" }
}

/// A bubble color you pick yourself, kept as six-digit hex ("0E7C66"). Like
/// the others it keeps its hue and adjusts only as far as contrast needs.
enum BighelpCustomBubbleColor {
    static func validated(_ value: String?) -> String? {
        guard var hex = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.uppercased()
    }

    /// The picker's color in sRGB; wide-gamut values are clamped.
    static func hex(from color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil)
        return [red, green, blue]
            .map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .joined()
    }
}
