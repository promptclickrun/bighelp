import SwiftUI
import UIKit

/// "Code NS-104" under a notification setup problem, with Copy Details: what people send us
/// so we can tell which step stopped (docs/NOTIFICATION_ERROR_CODES.md).
struct BighelpNotificationFailureCodeRow: View {
    let code: BighelpNotificationErrorCode
    /// Only privacy-safe text (`BighelpNotificationFailureReport`).
    let details: String
    var identifier = "notification-failure"
    @State private var copied = false
    @BighelpThemeReader private var theme

    init(failure: BighelpNotificationSetupFailure, identifier: String = "notification-failure") {
        code = failure.code
        details = BighelpNotificationFailureReport.text(failure)
        self.identifier = identifier
    }

    init(failure: BighelpNotificationLastFailure, identifier: String = "notification-failure") {
        code = failure.code
        details = BighelpNotificationFailureReport.text(failure)
        self.identifier = identifier
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Text("Code \(code.rawValue)")
                .bighelpFont(.metadata, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .accessibilityIdentifier("\(identifier).code")
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = details
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy Details", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .bighelpPlainButtonStyle(padding: 4)
            .accessibilityHint("Copies the code and what went wrong, without your computer's address or names.")
            .accessibilityIdentifier("\(identifier).copy")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
