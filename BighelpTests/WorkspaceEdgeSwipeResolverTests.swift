import CoreGraphics
import Foundation
import Testing
@testable import Bighelp

struct WorkspaceEdgeSwipeResolverTests {
    @Test func resolvesOnlyDeliberateHorizontalGesturesFromTheLeftEdge() {
        let action = WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 12, y: 220),
            translation: CGSize(width: 88, height: 14),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        )

        #expect(action == .quickWorkspace)
        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 42, y: 220),
            translation: CGSize(width: 88, height: 14),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        ) == nil)
        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 12, y: 220),
            translation: CGSize(width: 32, height: 120),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        ) == nil)
    }

    @Test func resolvesTheConfiguredRightEdgeActionAndHonorsDisabledActions() {
        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 382, y: 220),
            translation: CGSize(width: -90, height: 8),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .sessions
        ) == .sessions)

        #expect(WorkspaceEdgeSwipeResolver.resolve(
            start: CGPoint(x: 382, y: 220),
            translation: CGSize(width: -90, height: 8),
            containerWidth: 390,
            leftAction: .quickWorkspace,
            rightAction: .none
        ) == nil)
    }
}
