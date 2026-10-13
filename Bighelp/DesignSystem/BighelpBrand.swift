import SwiftUI
import UIKit

/// The bighelp identity, the Noodle: one continuous stroke writes a lowercase b and kicks
/// out at the bottom left as a chat-bubble tail. It lives in chrome and loaders, never as
/// a chat participant. The kit's motions are `BighelpNoodleMotion`.
enum BighelpBrand {
    static let appName = "bighelp"

    static let ember = Color(hex: "FF8A7A")
    static let ink = Color(hex: "1C1A19")
    static let cream = Color(hex: "F5F2EF")
    static let night = Color(hex: "121110")
}

extension Color {
    /// Ink for text on a filled accent: white on the deep violet used by day,
    /// Ember ink on the pale lavender used after dark. Every accent that passes
    /// the theme's canvas-contrast contract reads correctly with this rule.
    static let bighelpActionInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x1C / 255, green: 0x1A / 255, blue: 0x19 / 255, alpha: 1)
            : .white
    })
}

extension View {
    /// System prominent buttons always draw white labels, which disappear on the
    /// after-dark lavender. This keeps the native shape with the right ink.
    func bighelpProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent).foregroundStyle(Color.bighelpActionInk)
    }
}

/// The wordmark: the mark stands in for the b, then "ighelp" in the kit's outlined
/// Nunito, ink by day and cream after dark. `height` is the kit's full wordmark box.
/// Pass a motion to play it in the b's place (the onboarding writes itself in).
struct BighelpWordmark: View {
    var height: CGFloat = 26
    var motion: BighelpNoodleMotion?
    var playback: BighelpNoodlePlayback = .automatic
    var onFinish: (() -> Void)?

    @BighelpThemeReader private var theme

    /// The kit's wordmark geometry, in its own units: the box is 915 tall, the mark's cell
    /// 726.9 wide (the stroke plus the gap to the i), the letters 2870 wide. The mark's
    /// center sits at (345, 411.1) in its cell and its stroke is 786.2 tall.
    private enum Kit {
        static let height: CGFloat = 915
        static let markCell: CGFloat = 726.9
        static let letters: CGFloat = 2870
        static let markCenter = CGPoint(x: 345, y: 411.1)
        static let markHeight: CGFloat = 786.2
    }

    var body: some View {
        let unit = height / Kit.height
        HStack(spacing: 0) {
            BighelpNoodleView(motion: motion ?? .idle,
                              size: Kit.markHeight * unit * BighelpNoodleAnimation.markBox / 274.4,
                              playback: playback, isPaused: motion == nil, onFinish: onFinish)
                .position(x: Kit.markCenter.x * unit, y: Kit.markCenter.y * unit)
                .frame(width: Kit.markCell * unit, height: height)
            Image("BighelpWordmarkLetters")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(theme.isDarkPalette ? BighelpBrand.cream : BighelpBrand.ink)
                .frame(width: Kit.letters * unit, height: height)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BighelpBrand.appName)
    }
}

/// The brand bar as a leading toolbar item, without a glass capsule on iOS 26.
/// Touch and hold it to switch hosts.
struct BighelpBrandToolbarItem: ToolbarContent {
    var demoHosts: DemoHosts?

    var body: some ToolbarContent {
        #if compiler(>=6.2) && !os(visionOS) // visionOS toolbars have no shared glass.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { BighelpHostSwitcherLockup(demoHosts: demoHosts) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { BighelpHostSwitcherLockup(demoHosts: demoHosts) }
        }
        #else
        ToolbarItem(placement: .topBarLeading) { BighelpHostSwitcherLockup(demoHosts: demoHosts) }
        #endif
    }
}

#Preview("Noodle") {
    VStack(spacing: 24) {
        BighelpWordmark(height: 40)
        BighelpWordmark(height: 52, motion: .reveal)
        BighelpNoodleMark(size: 96)
    }
    .padding()
    .background(BighelpBrand.cream)
}
