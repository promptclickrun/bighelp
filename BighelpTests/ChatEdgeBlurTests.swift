import SwiftUI
import Testing
@testable import Bighelp

struct ChatEdgeBlurTests {
    @Test func blursUnlessTransparencyIsReducedOrContrastIncreased() {
        #expect(ChatEdgeBackdropStyle.resolve(reduceTransparency: false, increasedContrast: false) == .blur)
        #expect(ChatEdgeBackdropStyle.resolve(reduceTransparency: true, increasedContrast: false) == .solid)
        #expect(ChatEdgeBackdropStyle.resolve(reduceTransparency: false, increasedContrast: true) == .solid)
    }

    @Test(arguments: [VerticalEdge.top, .bottom])
    func blurIsStrongestAtTheScreenEdgeAndGoneAtTheMessages(_ edge: VerticalEdge) {
        let stops = ChatEdgeBlurMetrics.blurStops(for: edge)
        #expect(stops.first?.location == 0)
        #expect(stops.first?.opacity == 1)
        #expect(stops.last?.location == 1)
        #expect(stops.last?.opacity == 0)
        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location && $0.opacity >= $1.opacity })
    }

    /// The header and message box have no hard color behind them: the wash over the blur
    /// is never opaque, so the messages under it always show.
    @Test(arguments: [VerticalEdge.top, .bottom])
    func tintNeverHidesTheMessages(_ edge: VerticalEdge) {
        let stops = ChatEdgeBlurMetrics.tintStops(for: edge)
        #expect(stops.allSatisfy { $0.opacity <= 0.6 })
        #expect(stops.last?.opacity == 0)
    }

    /// Reduce Transparency keeps the controls readable on a solid fill in the chat's color.
    @Test(arguments: [VerticalEdge.top, .bottom])
    func solidFillCoversTheControlsThenFades(_ edge: VerticalEdge) {
        let stops = ChatEdgeBlurMetrics.solidStops(for: edge)
        #expect(stops.first?.opacity == 1)
        #expect(stops.filter { $0.opacity == 1 }.map(\.location).max() ?? 0 >= 0.5)
        #expect(stops.last?.opacity == 0)
    }

    #if !os(visionOS)
    /// iOS 26: the chat's own scroll view draws its soft edge effect under the header and the
    /// message box, and the marker over them never takes a touch meant for the chat.
    @MainActor @Test(arguments: [VerticalEdge.top, .bottom])
    func edgeAnchorTiesTheSoftEdgeEffectToTheChat(_ edge: VerticalEdge) throws {
        guard #available(iOS 26, *) else { return }
        let scrollView = UIScrollView()
        let anchor = ChatScrollEdgeAnchor(edge: edge)
        anchor.resolveScrollView = { scrollView }
        anchor.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        anchor.layoutIfNeeded()
        #expect(anchor.interaction.scrollView === scrollView)
        #expect(anchor.interaction.edge == (edge == .top ? .top : .bottom))
        #expect((edge == .top ? scrollView.topEdgeEffect : scrollView.bottomEdgeEffect).style == .soft)
        // The invisible text that sizes the effect runs along the inner side, where the messages start.
        #expect(anchor.extentMarker.frame.width == 400)
        #expect(edge == .top ? anchor.extentMarker.frame.maxY == 200 : anchor.extentMarker.frame.minY == 0)
        #expect(anchor.extentMarker.textColor == .clear)
        #expect(!anchor.isUserInteractionEnabled)
        #expect(anchor.hitTest(CGPoint(x: 200, y: 100), with: nil) == nil)
    }
    #endif
}
