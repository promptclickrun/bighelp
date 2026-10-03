import SwiftUI

/// A horizontal rail of `BighelpRailCard`s that runs to the screen's edges.
struct BighelpCardRail<Content: View>: View {
    var spacing: CGFloat = BighelpTokens.space12
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) {
                content()
            }
        }
        .scrollClipDisabled()
    }
}

/// A card in a horizontal rail (Agent Studio's templates, Default model's
/// agents): a rounded tile that fills with the accent when it's the one chosen.
/// The content gets the ink colors to use on it.
struct BighelpRailCard<Content: View>: View {
    let isSelected: Bool
    let width: CGFloat
    var height: CGFloat?
    var alignment: Alignment = .topLeading
    @ViewBuilder let content: (_ ink: Color, _ secondaryInk: Color) -> Content

    static var cornerRadius: CGFloat { 18 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        content(isSelected ? theme.actionForeground : theme.primaryText,
                isSelected ? theme.actionForeground.opacity(0.85) : theme.secondaryText)
            .padding(BighelpTokens.space12)
            .frame(width: width, height: height, alignment: alignment)
            .frame(minHeight: BighelpTokens.hitTarget)
            .background(shape.fill(isSelected ? theme.action : theme.incomingMessageBackground))
            .overlay(shape.strokeBorder(isSelected ? Color.clear : theme.border, lineWidth: 1))
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
    }

    @BighelpThemeReader private var theme
}
