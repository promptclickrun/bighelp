import SwiftUI

/// bighelp's dark palette on the Watch: warm surfaces, cream text, lavender
/// for actions and your own messages, Ember coral only in the brand mark.
enum WatchDesign {
    static let minimumControlHeight: CGFloat = 44

    enum Color {
        static let canvas = SwiftUI.Color.black
        static let surface = SwiftUI.Color(red: 0x1E / 255, green: 0x1C / 255, blue: 0x1B / 255)
        static let raised = SwiftUI.Color(red: 0x29 / 255, green: 0x26 / 255, blue: 0x24 / 255)
        static let text = SwiftUI.Color(red: 0xF6 / 255, green: 0xEF / 255, blue: 0xE8 / 255)
        static let secondaryText = text.opacity(0.66)
        static let accent = SwiftUI.Color(red: 0xC9 / 255, green: 0xB6 / 255, blue: 0xFF / 255)
        static let outgoing = SwiftUI.Color(red: 0x7B / 255, green: 0x52 / 255, blue: 0xE0 / 255)
        static let ember = SwiftUI.Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x7A / 255)
        static let needs = SwiftUI.Color(red: 0xE5 / 255, green: 0x62 / 255, blue: 0x4F / 255)
        static let done = SwiftUI.Color(red: 0x2F / 255, green: 0xA5 / 255, blue: 0x8B / 255)
    }
}

/// An agent's initials on a soft lavender orb.
struct WatchAgentOrb: View {
    let name: String
    var size: CGFloat = 26

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(WatchDesign.Color.canvas)
            .frame(width: size, height: size)
            .background(
                Circle().fill(RadialGradient(
                    colors: [WatchDesign.Color.accent, WatchDesign.Color.outgoing],
                    center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: size * 0.8))
            )
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// The Noodle, bighelp's mark.
struct WatchBrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image("BighelpMarkColor")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A short "time ago" for rows.
enum WatchWhen {
    static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
