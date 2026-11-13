import XCTest
import SwiftUI
@testable import Bighelp

final class PrimaryNavigationSelectionTests: XCTestCase {
    @MainActor
    func testSelectedSurfaceIsRoundedSquareRatherThanCapsule() {
        let bounds = CGRect(x: 0, y: 0, width: 74, height: 74)
        let selected = FloatingTabBar.selectionShape.path(in: bounds)
        XCTAssertTrue(selected.contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(Capsule().path(in: bounds).contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(selected.contains(CGPoint(x: 0, y: 0)))
    }

    @MainActor
    func testAllRootSelectionsRenderThroughTheSameSurface() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let tabs: [(AppTab, String)] = [(.agents, "agents"), (.sessions, "sessions"), (.scheduledTasks, "tasks")]
        for (tab, name) in tabs {
            let content = FloatingTabBar(selection: .constant(tab), onNewChat: {})
                .frame(width: 402, height: 110)
                .background(Color.white)
                .environment(\.appAppearance, BighelpAppearanceContext(appearance: .light))
                .environment(\.colorScheme, .light)
            let host = UIHostingController(rootView: content)
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 110)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            await Task.yield()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "rounded-square-navigation-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
