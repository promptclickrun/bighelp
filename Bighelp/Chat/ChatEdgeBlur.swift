import SwiftUI

/// What sits behind the chat's header and its message box. Messages scroll on
/// under both, so the glass buttons have something to show; near the screen
/// edge they blur and fade, sharp again where the header or message box ends.
/// Reduce Transparency and Increase Contrast get a solid fill in the theme's own color.
enum ChatEdgeBackdropStyle: Equatable {
    case blur
    case solid

    static func resolve(reduceTransparency: Bool, increasedContrast: Bool) -> ChatEdgeBackdropStyle {
        reduceTransparency || increasedContrast ? .solid : .blur
    }
}

/// One gradient stop: how strong the layer is at a point between the screen
/// edge (0) and the messages (1).
struct ChatEdgeStop: Equatable {
    let location: CGFloat
    let opacity: Double
}

enum ChatEdgeBlurMetrics {
    /// How far inside the header (or the message box) the blur starts to fade. The fade then
    /// ends at about the header's bottom edge (the message box's top edge), so the messages
    /// between them stay sharp. iOS's own soft edge fades on past its marker by about this much.
    static let topInset: CGFloat = 30
    static let bottomInset: CGFloat = 26

    static func inset(for edge: VerticalEdge) -> CGFloat { edge == .top ? topInset : bottomInset }

    /// The blur's strength: full at the screen edge, gone where the messages are sharp again.
    static func blurStops(for edge: VerticalEdge) -> [ChatEdgeStop] {
        switch edge {
        // The header is tall (the agent's avatar); keep the blur strong behind the buttons
        // and the name, then let it go over the overhang.
        case .top: [.init(location: 0, opacity: 1), .init(location: 0.6, opacity: 0.9),
                    .init(location: 1, opacity: 0)]
        // The message box and tab bar sit low; messages blur only as they slide under them.
        case .bottom: [.init(location: 0, opacity: 1), .init(location: 0.55, opacity: 0.85),
                       .init(location: 1, opacity: 0)]
        }
    }

    /// A light wash of the chat's own color over the blur, so the status bar, the name and the
    /// buttons read in light and dark and the edge matches the theme. Never opaque.
    static func tintStops(for edge: VerticalEdge) -> [ChatEdgeStop] {
        switch edge {
        case .top: [.init(location: 0, opacity: 0.4), .init(location: 0.45, opacity: 0.15),
                    .init(location: 1, opacity: 0)]
        case .bottom: [.init(location: 0, opacity: 0.3), .init(location: 0.5, opacity: 0.1),
                       .init(location: 1, opacity: 0)]
        }
    }

    /// Reduce Transparency: the theme's color, solid behind the controls, fading out at the end.
    static func solidStops(for edge: VerticalEdge) -> [ChatEdgeStop] {
        switch edge {
        case .top: [.init(location: 0, opacity: 1), .init(location: 0.72, opacity: 1),
                    .init(location: 1, opacity: 0)]
        case .bottom: [.init(location: 0, opacity: 1), .init(location: 0.6, opacity: 1),
                       .init(location: 1, opacity: 0)]
        }
    }
}

#if !os(visionOS)
/// The backdrop under the chat's header (`.top`) or its message box and tab bar (`.bottom`).
/// iOS 26 and later use the chat's own soft scroll edge effect, the system's variable blur:
/// a material under a gradient mask only tints there, its blur is lost. Older systems get
/// that masked material. Neither redraws the messages, so a long chat keeps scrolling
/// smoothly while it streams. visionOS fades the messages out instead (its window is see-through).
struct ChatEdgeBlur: View {
    let edge: VerticalEdge
    let scrollView: @MainActor () -> UIScrollView?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @BighelpThemeReader private var theme

    var body: some View {
        Group {
            switch ChatEdgeBackdropStyle.resolve(reduceTransparency: reduceTransparency,
                                                 increasedContrast: contrast == .increased) {
            case .blur:
                if #available(iOS 26, *) {
                    // The system's effect fades out on its own just past the header.
                    ChatScrollEdgeAnchor.Representable(edge: edge, scrollView: scrollView)
                } else {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                            .mask { gradient(ChatEdgeBlurMetrics.blurStops(for: edge), color: .black) }
                        gradient(ChatEdgeBlurMetrics.tintStops(for: edge), color: theme.canvas)
                    }
                    .padding(edge == .top ? .bottom : .top, ChatEdgeBlurMetrics.inset(for: edge) / 2)
                }
            case .solid:
                gradient(ChatEdgeBlurMetrics.solidStops(for: edge), color: theme.canvas)
                    .padding(edge == .top ? .bottom : .top, ChatEdgeBlurMetrics.inset(for: edge) / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func gradient(_ stops: [ChatEdgeStop], color: Color) -> LinearGradient {
        LinearGradient(stops: stops.map { .init(color: color.opacity($0.opacity), location: $0.location) },
                       startPoint: edge == .top ? .top : .bottom,
                       endPoint: edge == .top ? .bottom : .top)
    }
}

/// Marks the area the header (or the message box and tab bar) covers, so the chat's scroll
/// view draws its soft edge effect under it. The effect takes its size from the UIKit
/// text and controls in this view; the header is SwiftUI, so an invisible line of text
/// stands in for it, `ChatEdgeBlurMetrics.inset` inside the inner side so the effect's own
/// fade ends where the header (or message box) does. An empty or see-through plain view does not count.
@available(iOS 26, *)
final class ChatScrollEdgeAnchor: UIView {
    var edge: VerticalEdge {
        didSet { if edge != oldValue { interaction.edge = Self.rectEdge(edge); setNeedsLayout() } }
    }
    var resolveScrollView: @MainActor () -> UIScrollView? = { nil }
    let interaction = UIScrollEdgeElementContainerInteraction()
    let extentMarker = UILabel()

    init(edge: VerticalEdge) {
        self.edge = edge
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        extentMarker.text = "M"
        extentMarker.textColor = .clear
        extentMarker.font = .systemFont(ofSize: 4)
        extentMarker.isAccessibilityElement = false
        addSubview(extentMarker)
        interaction.edge = Self.rectEdge(edge)
        addInteraction(interaction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height: CGFloat = 4
        let inset = min(ChatEdgeBlurMetrics.inset(for: edge), max(0, bounds.height - height))
        extentMarker.frame = CGRect(x: 0, y: edge == .top ? bounds.maxY - height - inset : inset,
                                    width: bounds.width, height: height)
        attach()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
    }

    /// The chat's table can arrive after the header does; look again on each layout.
    func attach() {
        guard let scrollView = resolveScrollView() else { return }
        switch edge {
        case .top: scrollView.topEdgeEffect.style = .soft
        case .bottom: scrollView.bottomEdgeEffect.style = .soft
        }
        if interaction.scrollView !== scrollView { interaction.scrollView = scrollView }
    }

    private static func rectEdge(_ edge: VerticalEdge) -> UIRectEdge { edge == .top ? .top : .bottom }

    struct Representable: UIViewRepresentable {
        let edge: VerticalEdge
        let scrollView: @MainActor () -> UIScrollView?

        func makeUIView(context: Context) -> ChatScrollEdgeAnchor { ChatScrollEdgeAnchor(edge: edge) }

        func updateUIView(_ view: ChatScrollEdgeAnchor, context: Context) {
            view.resolveScrollView = scrollView
            view.edge = edge
            view.attach()
        }
    }
}
#endif
