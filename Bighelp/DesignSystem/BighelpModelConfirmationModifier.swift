import SwiftUI

/// Shows Hermes's exact warning; consent belongs to this selection, not a global privacy preference.
struct BighelpModelConfirmationModifier: ViewModifier {
    let confirmation: SessionRuntimeModelConfirmation?
    let onConfirm: ((SessionRuntimeModelConfirmation) -> Void)?
    let onCancel: ((SessionRuntimeModelConfirmation) -> Void)?

    @State private var isPresented = false
    @State private var didSubmit = false
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updatePresentation()
            }
            .onChange(of: confirmation) { _, _ in
                // The Mac keeps the quick picker behind the full picker in its navigation stack.
                guard isVisible else { return }
                updatePresentation()
            }
            .onChange(of: isPresented) { _, presented in
                if !presented, !didSubmit, let confirmation { onCancel?(confirmation) }
            }
            // A sheet, not an alert: a long warning at large text sizes pushed an alert's buttons off screen.
            .bighelpSheet(isPresented: $isPresented) {
                if let confirmation {
                    BighelpModelWarningSheet(title: "Confirm model change", message: confirmation.message) {
                        didSubmit = true
                        onConfirm?(confirmation)
                        isPresented = false
                    } onCancel: {
                        isPresented = false
                    }
                }
            }
            .onDisappear {
                isVisible = false
                if let confirmation { onCancel?(confirmation) }
                isPresented = false
            }
    }

    private func updatePresentation() {
        didSubmit = false
        isPresented = confirmation != nil && onConfirm != nil
    }
}

/// Hermes's model warnings (training on your data, cost). Scrolls as a whole, with the warning
/// folded behind Read more, so Approve stays reachable on small screens and at any text size.
struct BighelpModelWarningSheet: View {
    let title: String
    let message: String
    let onApprove: () -> Void
    let onCancel: () -> Void

    @BighelpThemeReader private var theme
    @State private var isExpanded = false

    private var isLong: Bool { message.count > 120 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text(title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                Text(message)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(isExpanded || !isLong ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if isLong {
                    Button(isExpanded ? "Read less" : "Read more") { isExpanded.toggle() }
                        .font(.bighelp(.footnote).weight(.semibold))
                        .tint(theme.action)
                        .accessibilityIdentifier("model-confirmation.read-more")
                }
                VStack(spacing: BighelpTokens.space8) {
                    Button(action: onApprove) {
                        Text("Approve").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(theme.action)
                    .accessibilityIdentifier("model-confirmation.approve")
                    Button(role: .cancel, action: onCancel) {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("model-confirmation.cancel")
                }
                .font(.bighelp(.body).weight(.semibold))
                .padding(.top, BighelpTokens.space8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(BighelpTokens.space20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.canvas)
        // Approve or Cancel only, so a swipe never leaves the host waiting on an answer.
        .interactiveDismissDisabled()
        .bighelpSheetSize(.compact)
    }
}
