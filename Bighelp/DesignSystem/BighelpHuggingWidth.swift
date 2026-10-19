import SwiftUI

/// As wide as its content, up to `maxWidth`, where text inside truncates. `.frame(maxWidth:)`
/// instead fills whatever width is offered, so a chip around short text would stretch.
struct BighelpHuggingWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        let width = min(ideal.width, maxWidth, proposal.width ?? .infinity)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
