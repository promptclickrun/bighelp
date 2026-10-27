import Testing
import UIKit
@testable import Bighelp

@MainActor
struct ChatDissolveTransitionTests {
    @Test func capturesOnlyTheReadableViewportWithoutChangingScrollingOrContent() async throws {
        let (window, scroll) = try await mountedChat()
        defer { window.isHidden = true }
        let offset = scroll.contentOffset
        let contentSize = scroll.contentSize
        let content = try #require(scroll.subviews.compactMap { $0 as? UILabel }.first)
        let transition = ChatDissolveTransition()
        transition.register(conversationID: "outgoing", scrollView: { scroll })
        transition.present(nextID: "local-draft:new", replacing: "outgoing", reduceMotion: false)
        let overlay = try #require(transition.overlay)
        defer { transition.cancel() }
        #expect(overlay.superview === window)
        #expect(overlay.frame == CGRect(x: 0, y: 100, width: 390, height: 580))
        #expect(!overlay.isUserInteractionEnabled)
        #expect(overlay.accessibilityElementsHidden)
        #expect(overlay.subviews.count <= ChatDissolveTransition.maximumBands,
                "Work stays bounded even with a huge scroll extent")
        #expect(scroll.contentOffset == offset)
        #expect(scroll.contentSize == contentSize)
        #expect(content.superview === scroll, "The live transcript was not replaced or split")
    }

    @Test func localDraftReplacementKeepsOneOverlayAndUnrelatedNavigationRemovesIt() async throws {
        let (window, scroll) = try await mountedChat()
        defer { window.isHidden = true }
        let transition = ChatDissolveTransition()
        transition.register(conversationID: "old", scrollView: { scroll })
        transition.present(nextID: "local-draft:new", replacing: "old", reduceMotion: false)
        let overlay = try #require(transition.overlay)
        transition.reconcile(conversationID: "local-draft:new")
        #expect(transition.overlay === overlay)
        transition.present(nextID: "authoritative", replacing: "local-draft:new", reduceMotion: false)
        transition.reconcile(conversationID: "authoritative")
        #expect(transition.overlay === overlay, "One New Chat has one effect")
        transition.reconcile(conversationID: "another-agent")
        #expect(transition.overlay == nil)
        #expect(overlay.superview == nil)
    }

    @Test func reduceMotionAndMissingSnapshotDoNotGateTheNewChat() async throws {
        let (window, scroll) = try await mountedChat()
        defer { window.isHidden = true }
        let transition = ChatDissolveTransition()
        transition.register(conversationID: "old", scrollView: { scroll })
        transition.present(nextID: "new", replacing: "old", reduceMotion: true)
        #expect(transition.overlay == nil)
        transition.register(conversationID: "new", scrollView: { nil })
        transition.present(nextID: "next", replacing: "new", reduceMotion: false)
        #expect(transition.overlay == nil)
    }

    @Test func theBottomLineGoesFirst() async throws {
        let (window, scroll) = try await mountedChat(lines: [500, 900])
        defer { window.isHidden = true }
        let transition = ChatDissolveTransition()
        transition.register(conversationID: "old", scrollView: { scroll })
        transition.present(nextID: "new", replacing: "old", reduceMotion: false)
        let overlay = try #require(transition.overlay)
        defer { transition.cancel() }
        let strips = overlay.subviews.sorted { $0.frame.minY < $1.frame.minY }
        #expect(strips.count == 2)
        let top = try #require(strips.first?.layer.animation(forKey: "dissolve"))
        let bottom = try #require(strips.last?.layer.animation(forKey: "dissolve"))
        #expect(bottom.beginTime < top.beginTime)
    }

    @Test func findsEachLineAndCoversTheWholeViewport() {
        var rows = Array(repeating: false, count: 200)
        for y in 10..<26 { rows[y] = true }
        for y in 30..<46 where y != 38 { rows[y] = true }
        // A bubble five lines tall.
        for y in 80..<160 { rows[y] = true }
        let bands = ChatDissolveBands.lines(rows: rows, limit: 40)
        #expect(bands.count == 7, "Two lines, one row of antialiasing inside the second, and a bubble cut in five")
        #expect(bands.first?.lowerBound == 0)
        #expect(bands.last?.upperBound == 200)
        #expect(zip(bands, bands.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(ChatDissolveBands.lines(rows: rows, limit: 3).count <= 3)
        #expect(ChatDissolveBands.lines(rows: Array(repeating: false, count: 50), limit: 40).isEmpty)
    }

    private func mountedChat(lines: [CGFloat] = [500]) async throws -> (UIWindow, UIScrollView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 100, left: 0, bottom: 120, right: 0)
        scroll.contentSize = CGSize(width: 390, height: 1_000_000)
        scroll.contentOffset = CGPoint(x: 0, y: 400)
        for y in lines {
            let label = UILabel(frame: CGRect(x: 10, y: y, width: 360, height: 80))
            label.text = "The complete conversation stays here."
            scroll.addSubview(label)
        }
        controller.view.addSubview(scroll)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        return (window, scroll)
    }
}
