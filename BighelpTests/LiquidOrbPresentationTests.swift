import Testing
@testable import Bighelp

struct LiquidOrbPresentationTests {
    @Test func voiceSurfaceUsesAnExplicitOrbAndCompactControls() {
        #expect(VoiceOrbPresentation.usesExplicitOrbSurface)
        #expect(!VoiceViewPresentation.statusUsesFullWidthSurface)
        #expect(VoiceViewPresentation.controlMinimumHeight == 64)
    }

    @Test func agentRowsGiveLongRoleAndSummaryCopyRoomToWrap() {
        #expect(AgentRowPresentation.roleLineLimit == 2)
        #expect(AgentRowPresentation.summaryLineLimit == 2)
        #expect(AgentRowPresentation.textColumnCanShrink)
    }

    @Test func voiceStatusesMapToTheirPurposeBuiltThinkingOrbAnimations() {
        #expect(VoiceOrbPresentation.scenario(for: .listening) == .listening)
        #expect(VoiceOrbPresentation.scenario(for: .working) == .reasoning)
        #expect(VoiceOrbPresentation.scenario(for: .speaking) == .waiting)
        #expect(VoiceOrbPresentation.scenario(for: .paused) == .waiting)
        #expect(VoiceOrbPresentation.scenario(for: .unavailable) == .working)
    }

    @Test func controlledInputSamplesAreSmoothedWithAttackAndRelease() {
        var smoother = VoiceInputLevelSmoother()

        let attack = smoother.update(target: 1)
        let secondAttack = smoother.update(target: 1)
        let release = smoother.update(target: 0)

        #expect(attack > 0)
        #expect(secondAttack > attack)
        #expect(release < secondAttack)
        #expect(release > 0)
        #expect(smoother.value >= 0 && smoother.value <= 1)
    }
}
