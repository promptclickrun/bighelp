import CoreGraphics

enum WorkspaceEdgeSwipeResolver {
    static let activationEdgeWidth: CGFloat = 28
    static let minimumHorizontalTravel: CGFloat = 64

    static func resolve(
        start: CGPoint,
        translation: CGSize,
        containerWidth: CGFloat,
        leftAction: WorkspaceSwipeAction,
        rightAction: WorkspaceSwipeAction
    ) -> WorkspaceSwipeAction? {
        guard containerWidth > activationEdgeWidth * 2,
              abs(translation.width) >= minimumHorizontalTravel,
              abs(translation.width) > abs(translation.height) * 1.25
        else { return nil }

        if start.x <= activationEdgeWidth, translation.width > 0 {
            return leftAction == .none ? nil : leftAction
        }

        if start.x >= containerWidth - activationEdgeWidth, translation.width < 0 {
            return rightAction == .none ? nil : rightAction
        }

        return nil
    }

    /// Feed, Ideas and Goals rows swipe left to dismiss. The trailing strip sat over the right
    /// end of every row and took those drags first (opening New chat), so it steps aside there.
    /// A chat pushed over a board keeps it.
    static func trailingEdgeIsActive(tab: AppTab, pathIsEmpty: Bool) -> Bool {
        !(pathIsEmpty && [.feed, .ideas, .goals].contains(tab))
    }
}
