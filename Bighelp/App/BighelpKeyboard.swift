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
