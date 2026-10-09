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
            .alert("Confirm model change", isPresented: $isPresented, presenting: confirmation) { confirmation in
                Button("Approve") {
                    didSubmit = true
                    onConfirm?(confirmation)
                }
                Button("Cancel", role: .cancel) { onCancel?(confirmation) }
            } message: { confirmation in
                Text(confirmation.message)
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
