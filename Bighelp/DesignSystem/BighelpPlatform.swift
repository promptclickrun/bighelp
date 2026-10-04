import SwiftUI
import UIKit

// Small differences between iPhone/iPad and Vision Pro, kept in one place.

extension View {
    /// Vision Pro's keyboard floats apart from the window, so scrolling
    /// never needs to put it away there. `immediately`: any scroll puts it
    /// away, for search results under a bottom search bar.
    @ViewBuilder
    func dismissesKeyboardOnScroll(_ dismisses: Bool, immediately: Bool = false) -> some View {
        #if os(visionOS)
        self
        #else
        scrollDismissesKeyboard(dismisses ? (immediately ? .immediately : .interactively) : .never)
        #endif
    }
}

/// Taps and confirmations you can feel. Vision Pro has no haptics, so these
/// do nothing there.
@MainActor
enum BighelpHaptics {
    static func success() {
        #if !os(visionOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func tap(rigid: Bool = false) {
        #if !os(visionOS)
        UIImpactFeedbackGenerator(style: rigid ? .rigid : .light).impactOccurred()
        #endif
    }
}

extension View {
    /// A text button in a toolbar's leading spot (Cancel, Done). The Mac squeezes
    /// it into a round button ("C…"); its natural width keeps the label whole.
    @ViewBuilder
    func bighelpToolbarText() -> some View {
        #if targetEnvironment(macCatalyst)
        fixedSize()
        #else
        self
        #endif
    }
}

enum BighelpPlatform {
    /// The Mac app (Mac Catalyst, "Optimize for Mac").
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// Vision Pro puts the tabs in a strip beside the window instead of a
    /// bar along its bottom edge, next to the system's move and close controls.
    static var usesTabOrnament: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }
}

#if os(visionOS)
/// Vision Pro draws navigation titles and toolbar buttons white, which vanish on
/// a light window. Give them the app's ink in light mode, white in dark. Titles
/// take it from here; toolbar buttons from the app's `foregroundStyle`.
@MainActor
enum BighelpVisionChrome {
    static let ink = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .white
            : UIColor(red: 0.13, green: 0.11, blue: 0.18, alpha: 1)
    }

    static func useReadableNavigationColors() {
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.foregroundColor: ink]
        bar.titleTextAttributes = [.foregroundColor: ink]
        bar.tintColor = ink
    }
}
#endif

/// Vision Pro: text and toolbar buttons in fixed colors for the app's light or
/// dark look. Left to the system they're white or see-through, made for dark
/// glass; and adaptive colors don't help, because text fields and sheet
/// toolbars resolve them as if the window were dark even when it's light.
struct BighelpVisionInk: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if os(visionOS)
        // One level: grey text and field hints derive from it. Setting the lower
        // levels too makes visionOS draw hints and dividers white on white.
        content.foregroundStyle(colorScheme == .light ? Color(red: 0.13, green: 0.11, blue: 0.18) : .white)
        #else
        content
        #endif
    }
}

extension View {
    /// A segmented picker that stays readable on Vision Pro. Its labels are
    /// always white there and its track is see-through, so on a light row they
    /// vanish; it sits on a dark capsule instead, in both modes.
    func bighelpSegmentedPicker() -> some View {
        #if os(visionOS)
        pickerStyle(.segmented)
            .environment(\.colorScheme, .dark)
            .background(Color(white: 0.16), in: Capsule())
        #else
        pickerStyle(.segmented)
        #endif
    }
}

extension Text {
    /// A text field's hint ("Name"). Vision Pro draws the system hint near white,
    /// which vanishes on a light window; elsewhere it stays the system's.
    func bighelpFieldHint(_ theme: BighelpTheme) -> Text {
        #if os(visionOS)
        foregroundStyle(theme.tertiaryText)
        #else
        self
        #endif
    }
}
