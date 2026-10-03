import SwiftUI
import UIKit

/// The bighelp identity. Ember is geometry: a perfect coral circle with two eyes
/// gazing slightly up. It never borrows an agent color, never changes state and
/// never appears as a chat participant; it lives only in chrome.
enum EmberBrand {
    static let appName = "bighelp"
    static let company = "LONGVIEW"

    static let ember = Color(hex: "FF8A7A")
    static let emberDeep = Color(hex: "E0685C")
    static let ink = Color(hex: "1C1A19")
    static let cream = Color(hex: "F5F2EF")
    static let lavender = Color(hex: "C9B6FF")
    static let leaf = Color(hex: "1E7A4E")
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

/// The app-icon mark: cream squircle field, coral disc, eyes riding above center.
/// Geometry follows the brand kit's 120-unit artboard.
struct EmberMark: View {
    var size: CGFloat = 28
    /// Drops the cream field for placements that already sit on cream.
    var showsField = true

    var body: some View {
        Canvas { context, canvasSize in
            let unit = canvasSize.width / 120
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)
            }
            if showsField {
                context.fill(
                    Path(roundedRect: rect(4, 4, 112, 112), cornerRadius: 27 * unit, style: .continuous),
                    with: .color(EmberBrand.cream)
                )
            }
            context.fill(Path(ellipseIn: rect(27, 30, 66, 66)), with: .color(EmberBrand.ember))
            context.fill(Path(ellipseIn: rect(37, 43.5, 22, 13)), with: .color(.white.opacity(0.38)))
            context.fill(Path(ellipseIn: rect(43.5, 49, 11, 16)), with: .color(EmberBrand.cream))
            context.fill(Path(ellipseIn: rect(65.5, 49, 11, 16)), with: .color(EmberBrand.cream))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Lowercase SF Pro Rounded wordmark that always ends with the coral period.
struct EmberWordmark: View {
    var size: CGFloat = 19

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (Text(EmberBrand.appName).foregroundStyle(colorScheme == .dark ? EmberBrand.cream : EmberBrand.ink)
            + Text(".").foregroundStyle(EmberBrand.ember))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(-0.03 * size)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(EmberBrand.appName)
    }
}

/// Horizontal lockup used as the brand bar on root screens.
struct EmberLockup: View {
    var markSize: CGFloat = 28
    var showsCompany = false

    var body: some View {
        HStack(spacing: markSize * 0.32) {
            EmberMark(size: markSize)
            EmberWordmark(size: markSize * 0.68)
            if showsCompany {
                Spacer(minLength: 8)
                Text(EmberBrand.company)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                    .opacity(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EmberBrand.appName)
        .accessibilityIdentifier("brand.lockup")
    }
}

/// The brand bar as a leading toolbar item, without a glass capsule on iOS 26.
/// Touch and hold it to switch hosts.
struct EmberBrandToolbarItem: ToolbarContent {
    var demoHosts: DemoHosts?

    var body: some ToolbarContent {
        #if compiler(>=6.2) && !os(visionOS) // visionOS toolbars have no shared glass.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { EmberHostSwitcherLockup(demoHosts: demoHosts) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { EmberHostSwitcherLockup(demoHosts: demoHosts) }
        }
        #else
        ToolbarItem(placement: .topBarLeading) { EmberHostSwitcherLockup(demoHosts: demoHosts) }
        #endif
    }
}

/// Stacked lockup for splash and square spaces.
struct EmberSplash: View {
    var body: some View {
        VStack(spacing: 18) {
            EmberMark(size: 120)
            EmberWordmark(size: 34)
            Text("A \(EmberBrand.company) COMPANY")
                .font(.system(size: 10, weight: .bold))
                .tracking(3)
                .foregroundStyle(Color(hex: "8A8A8E"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EmberBrand.appName)
    }
}

#Preview("Ember") {
    VStack(spacing: 24) {
        EmberLockup(markSize: 40, showsCompany: true)
        EmberSplash()
    }
    .padding()
    .background(Color(hex: "FFF9F5"))
}
