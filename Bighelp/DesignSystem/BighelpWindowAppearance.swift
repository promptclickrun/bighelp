import SwiftUI
import UIKit

/// Light, Dark or Automatic on every window of the app and every sheet open on it, so system parts
/// (text fields, form rows, switches, pickers) change at once with the app's own colors.
/// `.preferredColorScheme` alone left an open sheet as it was when it opened: after a switch to Dark,
/// a name field drew white text on a white row until its screen was opened again.
@MainActor
enum BighelpWindowAppearance {
    private static var current: AppAppearance = .system

    static func apply(_ appearance: AppAppearance) {
        current = appearance
        applyCurrent()
    }

    /// Again for a sheet that just opened: SwiftUI may have given it the look of an earlier choice.
    static func applyCurrent() {
        #if !os(visionOS)
        let style: UIUserInterfaceStyle = switch current {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
                var controller = window.rootViewController
                while let next = controller {
                    if next.overrideUserInterfaceStyle != style { next.overrideUserInterfaceStyle = style }
                    controller = next.presentedViewController
                }
            }
        }
        #endif
    }
}

extension View {
    /// A sheet or cover takes the app's Light or Dark choice as it opens.
    func bighelpPresentedAppearance() -> some View {
        onAppear { BighelpWindowAppearance.applyCurrent() }
    }
}
