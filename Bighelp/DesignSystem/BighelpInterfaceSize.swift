import Observation
import UIKit
import SwiftUI

/// Settings › Appearance › Text and buttons: text size in steps on top of the
/// device's own text size. The Mac starts larger: its text styles are smaller
/// than iPhone's while its window sits farther away.
///
/// The raw value is what's saved, so it never changes: Default is one step under
/// the device's size (#729), and Medium, the device's own size, was Default before.
enum BighelpTextSize: Int, CaseIterable, Identifiable, Sendable {
    case small = -2
    case standard = -1
    case medium = 0
    case large = 1
    case larger = 2
    case largest = 3

    var id: Self { self }

    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .standard: String(localized: "Default")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        case .larger: String(localized: "Larger")
        case .largest: String(localized: "Largest")
        }
    }

    static var platformDefault: Self { .standard }

    /// The Mac's text styles are fixed (Dynamic Type doesn't reach them), so its
    /// text is the iPhone size times this. Default gives 15pt body text, one step
    /// like the iPhone's from Medium's 16pt. Small is the factor Small had before #729.
    var macFactor: CGFloat {
        switch self {
        case .small: 0.82
        case .standard: 0.88
        case .medium: 0.94
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
    /// Set once the Mac has moved a Small saved before #729 (`moveMacSmallSavedBefore729`).
    static let macSmallMovedKey = "bighelp.appearance.text-size.mac-small-moved"

    @ObservationIgnored private let defaults: UserDefaults

    var textSize: BighelpTextSize {
        didSet {
            defaults.set(textSize.rawValue, forKey: Self.textSizeKey)
            picksTextSize = true
        }
    }

    /// Whether the person picked a text size here. Until then, and again after Reset,
    /// accessibility sizes don't take the default's step down (`dynamicTypeSize(onTopOf:)`).
    private(set) var picksTextSize: Bool

    var buttonSize: BighelpButtonSize {
        didSet { defaults.set(buttonSize.rawValue, forKey: Self.buttonSizeKey) }
    }

    var buttonScale: CGFloat { buttonSize.scale }

    init(defaults: UserDefaults = .standard, isMac: Bool = BighelpPlatform.isMac) {
        self.defaults = defaults
        if isMac { Self.moveMacSmallSavedBefore729(in: defaults) }
        // `integer(forKey:)` also reads launch arguments, which arrive as text.
        func saved(_ key: String) -> Int? { defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key) }
        let savedText = saved(Self.textSizeKey).flatMap(BighelpTextSize.init(rawValue:))
        textSize = savedText ?? .platformDefault
        picksTextSize = savedText != nil
        buttonSize = saved(Self.buttonSizeKey).flatMap(BighelpButtonSize.init(rawValue:)) ?? .platformDefault
    }

    /// Before #729 the Mac's Small was raw -1 at factor 0.82; -1 is Default now (0.88), and
    /// 0.82 is raw -2. Moves that saved Small once, so its text keeps its size; a -1 saved
    /// after it is the new Default. iPhone and iPad keep -1: there it's still one Dynamic
    /// Type step under the device's size.
    private static func moveMacSmallSavedBefore729(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: macSmallMovedKey) else { return }
        if defaults.object(forKey: textSizeKey) != nil,
           defaults.integer(forKey: textSizeKey) == BighelpTextSize.standard.rawValue {
            defaults.set(BighelpTextSize.small.rawValue, forKey: textSizeKey)
        }
        defaults.set(true, forKey: macSmallMovedKey)
    }

    /// The device's text size stepped by the chosen one. Out of the box the step down is
    /// for regular sizes only: an accessibility size stays, with its layouts. A size
    /// picked here applies at any device size. `sizedAbove` is the size a view above
    /// already chose: when it came through, it stays, so nothing takes two steps.
    func dynamicTypeSize(onTopOf system: DynamicTypeSize, sizedAbove: DynamicTypeSize? = nil) -> DynamicTypeSize {
        if sizedAbove == system { return system }
        if !picksTextSize, system.isAccessibilitySize { return system }
        return system.stepped(by: textSize.rawValue)
    }

    func reset() {
        resetText()
        buttonSize = .platformDefault
    }

    /// Back to the size out of the box, as if never picked. ⌘0 in the View menu.
    func resetText() {
        textSize = .platformDefault
        defaults.removeObject(forKey: Self.textSizeKey)
        picksTextSize = false
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

/// Applies the saved text size to everything under it. iOS starts a sheet or cover again
/// from the device's own size, so `bighelpPresentedAppearance` applies it there too.
struct BighelpTextSizing: ViewModifier {
    @Environment(\.dynamicTypeSize) private var systemSize
    @Environment(\.bighelpTextSizedTo) private var sizedAbove

    func body(content: Content) -> some View {
        let size = BighelpInterfaceSize.shared.dynamicTypeSize(onTopOf: systemSize, sizedAbove: sizedAbove)
        content.dynamicTypeSize(size).environment(\.bighelpTextSizedTo, size)
    }
}

extension EnvironmentValues {
    /// The size `BighelpTextSizing` chose above this view.
    @Entry var bighelpTextSizedTo: DynamicTypeSize? = nil
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
