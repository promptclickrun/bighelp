import SwiftUI

@MainActor
struct ApprovalDestinationView: View {
    @State private var model: ApprovalModel

    init(model: ApprovalModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            ApprovalCard(model: model)
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space24)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("approval.screen")
    }

    @BighelpThemeReader private var theme

}

/// New chat beside the home's bar: a large, tinted Liquid Glass circle, like the iMessage compose
/// button, instead of a small toolbar glyph.
struct RootComposeButton: View {
    static let diameter: CGFloat = 60
    let identifier: String
    var systemImage = "square.and.pencil"
    var size: CGFloat = RootComposeButton.diameter
    let action: () -> Void

    @BighelpThemeReader private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .title2) private var glyph: CGFloat = 24
    @State private var taps = 0

    var body: some View {
        Button(action: tap) { glyphCircle }
            .bighelpPointerButtonStyle(BighelpPressFeedbackStyle(), outline: .circle)
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .bighelpIconLabel("New chat", shortcut: "⌘N")
            .accessibilityIdentifier(identifier)
    }

    private var glyphCircle: some View {
        Image(systemName: systemImage)
            .font(.system(size: glyph * size / Self.diameter, weight: .semibold))
            .foregroundStyle(theme.actionForeground)
            .frame(width: size, height: size)
            .contentShape(.circle)
            .modifier(ComposeSurface(tint: theme.action, reduceTransparency: reduceTransparency))
    }

    private func tap() {
        BighelpKeyboard.dismiss()
        taps += 1
        action()
    }

    private struct ComposeSurface: ViewModifier {
        let tint: Color
        let reduceTransparency: Bool

        func body(content: Content) -> some View {
            #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
            if #available(iOS 26.0, *), !reduceTransparency {
                content.glassEffect(.regular.tint(tint).interactive(), in: .circle)
            } else {
                content.background(tint, in: .circle).shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            #else
            content.background(tint, in: .circle).shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            #endif
        }
    }
}
