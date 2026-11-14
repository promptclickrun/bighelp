import SwiftUI
import UIKit

/// The Bighelp identity, the lifter: a coral helper holding a box overhead. The box turns
/// into what he's doing (a brain, a magnifying glass, a check). He lives in chrome and
/// loaders, never as a chat participant. His motions are `BighelpLifterMotion`.
enum BighelpBrand {
    static let appName = "Bighelp"

    /// The lifter, the app icon's background, accents.
    static let coral = Color(hex: "FF5A36")
    /// The box and text on dark pages.
    static let cream = Color(hex: "FFF6EC")
    /// The box on light pages, the lifter's eyes.
    static let ink = Color(hex: "1A1420")
    /// Dark surfaces.
    static let night = Color(hex: "0E0E10")
}

extension Color {
    /// Ink for text on a filled accent: white on the deep violet used by day,
    /// the brand's ink on the pale lavender used after dark. Every accent that passes
    /// the theme's canvas-contrast contract reads correctly with this rule.
    static let bighelpActionInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x1A / 255, green: 0x14 / 255, blue: 0x20 / 255, alpha: 1)
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

/// The wordmark, as the kit's horizontal lockup: the lifter, then "Bighelp" in the kit's
/// outlined Bricolage Grotesque, ink by day and cream after dark. `height` is the lockup's
/// full height, the lifter's included. Pass a motion to play it once in the lifter's place
/// (the welcome, Settings' easter egg); without one the lifter is still.
struct BighelpWordmark: View {
    var height: CGFloat = 36
    var motion: BighelpLifterMotion?
    var playback: BighelpLifterPlayback = .once
    var onFinish: (() -> Void)?

    @BighelpThemeReader private var theme

    /// The kit's lockup in its own units: 608.7 by 192. The lifter's 200-unit artboard starts
    /// at (-16, -8) and the letters, 444.7 by 148.8, at (156, 30).
    private enum Kit {
        static let size = CGSize(width: 608.7, height: 192)
        static let mark = CGPoint(x: -16, y: -8)
        static let markSide: CGFloat = 200
        static let letters = CGRect(x: 156, y: 30, width: 444.7, height: 148.8)
    }

    var body: some View {
        let unit = height / Kit.size.height
        Color.clear
            .frame(width: Kit.size.width * unit, height: height)
            .overlay(alignment: .topLeading) {
                BighelpLifterView(motion: motion ?? .idle, size: Kit.markSide * unit, playback: playback,
                                  isPaused: motion == nil, onFinish: onFinish)
                    .offset(x: Kit.mark.x * unit, y: Kit.mark.y * unit)
            }
            .overlay(alignment: .topLeading) {
                Image("BighelpWordmark")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(theme.isDarkPalette ? BighelpBrand.cream : BighelpBrand.ink)
                    .frame(width: Kit.letters.width * unit, height: Kit.letters.height * unit)
                    .offset(x: Kit.letters.minX * unit, y: Kit.letters.minY * unit)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BighelpBrand.appName)
    }
}

#Preview("Lifter") {
    VStack(spacing: 24) {
        BighelpWordmark(height: 48)
        BighelpWordmark(height: 72, motion: .success)
        BighelpLifterMark(size: 96)
    }
    .padding()
    .background(BighelpBrand.cream)
}
