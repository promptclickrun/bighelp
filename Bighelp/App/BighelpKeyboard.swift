import SwiftUI
import UIKit

@MainActor
enum BighelpKeyboard {
    /// The composer uses a UIKit text view for Apple's native selection menu.
    /// Resign explicitly before menu and route transitions so its keyboard
    /// cannot remain attached after the input loses focus.
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

/// ☰ as a glass button, for screens drawn over the app (the voice screen).
struct WorkspaceMenuButton: View {
    let accessibilityIdentifier: String
    let action: () -> Void

    init(
        accessibilityIdentifier: String = "workspace.menu",
        action: @escaping () -> Void
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        .accessibilityLabel("Menu")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
