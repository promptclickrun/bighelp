import SwiftUI
import Testing
@testable import Bighelp

@MainActor
struct BighelpThinkingOrbTests {
    @Test func accessibilityLabelsStayUnchanged() {
        let cases: [(BighelpThinkingOrbScenario, String)] = [
            (.working, "Working…"), (.searching, "Searching…"),
            (.reasoning, "Solving…"), (.listening, "Listening…"),
            (.connecting, "Connecting…"), (.coordinating, "Weaving…"),
            (.composing, "Composing…"), (.waiting, "Thinking…"),
            (.shaping, "Shaping…")
        ]
        for (scenario, label) in cases {
            #expect(BighelpThinkingOrbPresentation.resolve(
                scenario: scenario, scale: .standard).state.label == label)
        }
    }

    @Test func scenariosResolveToTheIntendedStates() {
        let cases: [(BighelpThinkingOrbScenario, String)] = [
            (.working, "working"),
            (.searching, "searching"),
            (.reasoning, "solving"),
            (.listening, "listening"),
            (.connecting, "connecting"),
            (.coordinating, "weaving"),
            (.composing, "composing"),
            (.waiting, "breathing"),
            (.shaping, "shaping"),
        ]

        for (scenario, expectedState) in cases {
            let resolved = BighelpThinkingOrbPresentation.resolve(
                scenario: scenario,
                scale: .standard
            )

            #expect(resolved.state.rawValue == expectedState)
        }
    }

    @Test func presentationScalesPreserveTheLoaderSizes() {
        let inline = BighelpThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .inline
        )
        let standard = BighelpThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .standard
        )

        #expect(inline.size.rawValue == 20)
        #expect(inline.displaySize == nil)
        #expect(standard.size.rawValue == 64)
        #expect(standard.displaySize == nil)
    }

    @Test func visibleLabelsSuppressTheDuplicateAccessibilityElement() {
        let unlabeled = BighelpThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .inline
        )
        let labeled = BighelpThinkingOrbPresentation.resolve(
            scenario: .working,
            scale: .inline,
            visibleLabel: "Working"
        )

        #expect(unlabeled.visibleLabel == nil)
        #expect(!unlabeled.hidesOrbFromAccessibility)
        #expect(labeled.visibleLabel == "Working")
        #expect(labeled.hidesOrbFromAccessibility)
    }

    @Test func animationPausesOutsideTheActiveSceneOrWhenExplicitlyRequested() {
        #expect(!BighelpThinkingOrbPresentation.shouldPause(
            explicitly: false,
            scenePhase: .active
        ))
        #expect(BighelpThinkingOrbPresentation.shouldPause(
            explicitly: true,
            scenePhase: .active
        ))
        #expect(BighelpThinkingOrbPresentation.shouldPause(
            explicitly: false,
            scenePhase: .inactive
        ))
        #expect(BighelpThinkingOrbPresentation.shouldPause(
            explicitly: false,
            scenePhase: .background
        ))
    }

    @Test func filledActionControlsUseTheThemesDeclaredForegroundContrast() {
        #expect(BighelpTheme.light.actionThinkingOrbSurface == .dark)
        // Lavender dark-mode actions carry ink, so the orb renders for a light surface.
        #expect(BighelpTheme.dark.actionThinkingOrbSurface == .light)
    }

    @Test func pendingAgentIndicatorIsATypingBubble() {
        #expect(PendingMessagePresentation.showsContainer)
        #expect(PendingMessagePresentation.dotSize == 8)
        #expect(PendingMessagePresentation.restingDotOpacity > 0)
        #expect(PendingMessagePresentation.restingDotOpacity < 1)
    }
}
