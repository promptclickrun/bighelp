import SwiftUI

// The neutral glass the home's bar, headers and round buttons share, and the bar's row layout.

/// What navigation glass draws as: liquid glass where the system has it, else a material, and a solid
/// surface when the person asked for less transparency.
enum NavigationGlassSurface: Equatable, Sendable {
    case regularLiquidGlass
    case regularMaterial
    case thickMaterial
    case opaque

    static func resolve(supportsLiquidGlass: Bool, reduceTransparency: Bool,
                        increasedContrast: Bool) -> NavigationGlassSurface {
        if reduceTransparency { return .opaque }
        if supportsLiquidGlass { return .regularLiquidGlass }
        return increasedContrast ? .thickMaterial : .regularMaterial
    }
}

/// The labelled row reports its ideal width; the icon fallback respects its proposal.
/// Every destination gets the same measured width and height.
struct NavigationRowLayout: Layout {
    var constrainsWidth = false

    static func fittingSize(
        proposedWidth: CGFloat?, itemSizes: [CGSize], constrainsWidth: Bool = false
    ) -> CGSize {
        let requiredWidth = (itemSizes.map(\.width).max() ?? 44) * CGFloat(itemSizes.count)
        let availableWidth = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? requiredWidth
        let width = constrainsWidth
            ? max(44 * CGFloat(itemSizes.count), availableWidth)
            : max(availableWidth, requiredWidth)
        return CGSize(width: width,
                      height: itemSizes.map(\.height).max() ?? 44)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = Self.fittingSize(
            proposedWidth: proposal.width,
            itemSizes: subviews.map { $0.sizeThatFits(.unspecified) },
            constrainsWidth: constrainsWidth
        )
        guard constrainsWidth, !subviews.isEmpty else { return ideal }
        let cellProposal = ProposedViewSize(width: ideal.width / CGFloat(subviews.count), height: nil)
        return Self.fittingSize(
            proposedWidth: ideal.width,
            itemSizes: subviews.map { $0.sizeThatFits(cellProposal) },
            constrainsWidth: true
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

extension View {
    /// Neutral native navigation glass with an optional interactive response.
    /// No custom tint, glow or shadow; all consumers share its fallbacks.
    func bighelpNavigationGlass<S: InsettableShape>(in shape: S, isInteractive: Bool = false) -> some View {
        modifier(BighelpNavigationGlass(shape: shape, isInteractive: isInteractive))
    }
}

private struct BighelpNavigationGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content.modifier(NavigationSurface(
            shape: shape,
            isInteractive: isInteractive,
            surface: NavigationGlassSurface.resolve(
                supportsLiquidGlass: supportsLiquidGlass,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            ),
            increasedContrast: colorSchemeContrast == .increased
        ))
    }

    private var supportsLiquidGlass: Bool {
        #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

private struct NavigationSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool
    let surface: NavigationGlassSurface
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        surfaced(content)
            .modifier(InteractiveGlassHover(shape: shape, isInteractive: isInteractive))
            .overlay {
                if increasedContrast {
                    shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        switch surface {
        case .opaque:
            content.background(Color(uiColor: .systemBackground), in: shape)
        case .regularMaterial:
            content.background(.regularMaterial, in: shape)
        case .thickMaterial:
            content.background(.thickMaterial, in: shape)
        case .regularLiquidGlass:
            #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
            if #available(iOS 26.0, *) {
                content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
            #else
            content.background(.regularMaterial, in: shape)
            #endif
        }
    }
}

/// Mac: glass that's a button lights up under the pointer.
private struct InteractiveGlassHover<S: Shape>: ViewModifier {
    let shape: S
    let isInteractive: Bool

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if isInteractive { content.bighelpHover(in: shape) } else { content }
        #else
        content
        #endif
    }
}
