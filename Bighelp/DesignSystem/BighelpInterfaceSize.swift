import Observation
import UIKit
import SwiftUI

/// Settings › Appearance › Text and buttons: text size in steps on top of the
/// device's own text size. The Mac starts larger: its text styles are smaller
/// than iPhone's while its window sits farther away.
enum BighelpTextSize: Int, CaseIterable, Identifiable, Sendable {
    case small = -1
    case standard = 0
    case large = 1
    case larger = 2
    case largest = 3

    var id: Self { self }

    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .standard: String(localized: "Default")
        case .large: String(localized: "Large")
        case .larger: String(localized: "Larger")
        case .largest: String(localized: "Largest")
        }
    }

    static var platformDefault: Self { .standard }

    /// The Mac's text styles are fixed (Dynamic Type doesn't reach them), so its
    /// text is the iPhone size times this. Default gives 16pt body text.
    var macFactor: CGFloat {
        switch self {
        case .small: 0.82
        case .standard: 0.94
        case .large: 1.03
        case .larger: 1.12
        case .largest: 1.22
        }
    }
}

/// Settings › Appearance › Text and buttons: how big buttons, avatars and the
/// message box are. Every control sized from `BighelpTokens` follows it.
enum BighelpButtonSize: Int, CaseIterable, Identifiable, Sendable {
    case standard = 0
    case large = 1
    case larger = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: String(localized: "Default")
        case .large: String(localized: "Large")
        case .larger: String(localized: "Larger")
        }
    }

    var scale: CGFloat {
        switch self {
        case .standard: 1
        case .large: 1.15
        case .larger: 1.3
        }
    }

    static var platformDefault: Self { .standard }
}

/// The saved text and button sizes. Observable, so every view that reads a
/// token redraws when they change; saved on this device.
@Observable
final class BighelpInterfaceSize: @unchecked Sendable {
    static let shared = BighelpInterfaceSize()

    static let textSizeKey = "bighelp.appearance.text-size"
    static let buttonSizeKey = "bighelp.appearance.button-size"

    @ObservationIgnored private let defaults: UserDefaults

    var textSize: BighelpTextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Self.textSizeKey) }
    }

    var buttonSize: BighelpButtonSize {
        didSet { defaults.set(buttonSize.rawValue, forKey: Self.buttonSizeKey) }
    }

    var buttonScale: CGFloat { buttonSize.scale }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `integer(forKey:)` also reads launch arguments, which arrive as text.
        func saved(_ key: String) -> Int? { defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key) }
        textSize = saved(Self.textSizeKey).flatMap(BighelpTextSize.init(rawValue:)) ?? .platformDefault
        buttonSize = saved(Self.buttonSizeKey).flatMap(BighelpButtonSize.init(rawValue:)) ?? .platformDefault
    }

    func reset() {
        textSize = .platformDefault
        buttonSize = .platformDefault
    }

    /// ⌘+ and ⌘− in the View menu.
    func stepText(by delta: Int) {
        let next = textSize.rawValue + delta
        if let size = BighelpTextSize(rawValue: next) { textSize = size }
    }
}

extension DynamicTypeSize {
    /// `steps` sizes up or down, staying out of the accessibility sizes unless
    /// the device already uses one.
    func stepped(by steps: Int) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        let ceiling = isAccessibilitySize ? all.count - 1 : (all.firstIndex(of: .xxxLarge) ?? all.count - 1)
        return all[min(max(index + steps, 0), max(ceiling, index))]
    }
}

/// Applies the saved text size to everything under it, sheets included.
struct BighelpTextSizing: ViewModifier {
    @Environment(\.dynamicTypeSize) private var systemSize

    func body(content: Content) -> some View {
        content.dynamicTypeSize(systemSize.stepped(by: BighelpInterfaceSize.shared.textSize.rawValue))
    }
}

extension Font {
    /// A text style at bighelp's text size. iPhone and iPad follow Dynamic Type
    /// (stepped by `BighelpTextSizing`); the Mac gets the iPhone size times the
    /// chosen text size. Use instead of `.caption`, `.body` and the rest.
    static func bighelp(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font {
        #if targetEnvironment(macCatalyst)
        .system(size: style.macPointSize, weight: weight ?? style.defaultWeight, design: design ?? .default)
        #else
        .system(style, design: design, weight: weight)
        #endif
    }
}

extension Font.TextStyle {
    /// iPhone's size for the style at the default text size.
    var iPhonePointSize: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }

    var defaultWeight: Font.Weight { self == .headline ? .semibold : .regular }

    /// The Mac's size for the style at the chosen text size (reading it redraws on change).
    var macPointSize: CGFloat {
        (iPhonePointSize * BighelpInterfaceSize.shared.textSize.macFactor * 2).rounded() / 2
    }
}

extension UIFont {
    /// UIKit's `preferredFont(forTextStyle:)` at bighelp's text size: the Mac's
    /// text styles are fixed, so it gets the iPhone size times the chosen size.
    static func bighelp(_ style: UIFont.TextStyle, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        #if targetEnvironment(macCatalyst)
        let iPhoneSize: CGFloat = switch style {
        case .largeTitle: 34
        case .title1: 28
        case .title2: 22
        case .title3: 20
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption1: 12
        case .caption2: 11
        default: 17
        }
        let size = (iPhoneSize * BighelpInterfaceSize.shared.textSize.macFactor * 2).rounded() / 2
        return .systemFont(ofSize: size, weight: style == .headline ? .semibold : .regular)
        #else
        return .preferredFont(forTextStyle: style, compatibleWith: traits)
        #endif
    }
}
