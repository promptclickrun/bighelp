import SwiftUI
import UIKit

/// Light mode's page color.
enum BighelpLightBackground: String, CaseIterable, Identifiable, Sendable {
    case cream, paper

    var id: String { rawValue }
    var name: String { self == .cream ? String(localized: "Cream") : String(localized: "Paper") }
    var detail: String { self == .cream ? String(localized: "Warm and soft") : String(localized: "Clean, bright white") }
    var neutral: BighelpTheme { self == .cream ? .light : .paperLight }
}

/// Dark mode's page color.
enum BighelpDarkBackground: String, CaseIterable, Identifiable, Sendable {
    case graphite, black

    var id: String { rawValue }
    var name: String { self == .graphite ? String(localized: "Graphite") : String(localized: "Black") }
    var detail: String { self == .graphite ? String(localized: "Soft charcoal, easy on the eyes") : String(localized: "True black, saves battery on OLED") }
    var neutral: BighelpTheme { self == .graphite ? .graphiteDark : .blackDark }
}

/// Your chat bubble (and button) color. Lavender is bighelp's own, which
/// shifts lighter after dark; the rest keep their hue and adjust for contrast.
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
