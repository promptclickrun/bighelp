import SwiftUI
import Testing
@testable import Bighelp

/// The lifter's motions, read from the bundled Lottie files and drawn natively.
@MainActor
struct BighelpLifterTests {
    /// Every state loads in both palettes with the kit's length and markers (the kit's `manifest.json`).
    @Test func everyStateLoadsAsTheKitMadeIt() throws {
        let kit: [BighelpLifterMotion: (frames: Double, intro: Range<Double>?, loop: Range<Double>)] = [
            .idle: (90, nil, 0..<90), .thinking: (114, 0..<30, 30..<90), .coding: (134, 0..<44, 44..<104),
            .replying: (126, 0..<36, 36..<96), .searching: (114, 0..<30, 30..<90),
            .success: (110, 0..<26, 26..<86), .error: (110, 0..<26, 26..<86), .sleeping: (150, 0..<34, 34..<124),
        ]
        #expect(kit.count == BighelpLifterMotion.allCases.count)
        for motion in BighelpLifterMotion.allCases {
            for dark in [false, true] {
                let animation = try #require(BighelpLifterAnimation.named(motion, dark: dark), "\(motion) \(dark)")
                #expect(animation.frameCount == kit[motion]?.frames, "\(motion)")
                #expect(animation.intro == kit[motion]?.intro, "\(motion)")
                #expect(animation.loop == kit[motion]?.loop, "\(motion)")
                #expect(animation.frameRate == 30)
                #expect(!animation.layers.isEmpty)
            }
        }
    }

    /// The idle box, read from the kit's rectangles, sits exactly where the still mark draws
    /// its box, so a motion and the still mark line up at every size.
    @Test func theStillMarkLinesUpWithTheIdlePose() throws {
        let idle = try #require(BighelpLifterAnimation.named(.idle, dark: false))
        let box = try #require(idle.layers.lazy.compactMap { layer -> CGRect? in
            for group in layer.groups {
                for case .rectangle(let center, let size, _) in group.items where size.value(at: 0) == [200, 130] {
                    let origin = layer.transform.matrix(at: 0)
                    let c = CGPoint(x: center.value(at: 0)[0], y: center.value(at: 0)[1]).applying(origin)
                    return CGRect(x: c.x - 100, y: c.y - 65, width: 200, height: 130)
                }
            }
            return nil
        }.first, "The kit's box is a 200 by 130 rectangle.")
        // From the composition to the mark's 200-unit artboard.
        let unit = BighelpLifterAnimation.markBox / 200
        let center = BighelpLifterAnimation.markCenter
        let inMark = CGRect(x: (box.minX - center.x) / unit + 100, y: (box.minY - center.y) / unit + 100,
                            width: box.width / unit, height: box.height / unit)
        let mark = CGRect(x: 36, y: 28, width: 128, height: 84)
        #expect(abs(inMark.minX - mark.minX) < 1.5 && abs(inMark.minY - mark.minY) < 1.5)
        #expect(abs(inMark.width - mark.width) < 1.5 && abs(inMark.height - mark.height) < 1.5)
    }

    /// The intro plays once, then the loop repeats; idle has no intro and only loops.
    @Test func automaticPlaysTheIntroOnceThenTheLoop() throws {
        let thinking = try #require(BighelpLifterAnimation.named(.thinking, dark: false))
        #expect(BighelpLifterView.automaticFrame(thinking, elapsed: 10) == 10)
        #expect(BighelpLifterView.automaticFrame(thinking, elapsed: 30) == 30)
        #expect(BighelpLifterView.automaticFrame(thinking, elapsed: 95) == 35)
        let idle = try #require(BighelpLifterAnimation.named(.idle, dark: false))
        #expect(BighelpLifterView.automaticFrame(idle, elapsed: 100) == 10)
    }

    /// A marker past the file's end is ignored, and the loop falls back to the whole file.
    @Test func markersOutsideTheFileAreIgnored() throws {
        let json = #"{"fr": 30, "ip": 0, "op": 60, "layers": [], "markers": [{"cm": "loop", "tm": 50, "dr": 40}]}"#
        let animation = try #require(BighelpLifterAnimation(data: Data(json.utf8)))
        #expect(animation.intro == nil)
        #expect(animation.loop == 0..<60)
    }

    @Test func easesFollowTheKitsCubicCurves() {
        let standard = (0.4, 0.0, 0.2, 1.0)
        #expect(BighelpLifterCurve.solve(standard, at: 0) == 0)
        #expect(BighelpLifterCurve.solve(standard, at: 1) == 1)
        // Slow out of the start, fast into the end.
        #expect(BighelpLifterCurve.solve(standard, at: 0.25) < 0.5)
        #expect(BighelpLifterCurve.solve(standard, at: 0.75) > 0.9)
    }

    /// Each loader scenario acts out what's happening.
    @Test func loaderScenariosPlayTheirStates() {
        let expected: [(BighelpThinkingOrbScenario, BighelpLifterMotion)] = [
            (.working, .idle), (.searching, .searching), (.reasoning, .thinking), (.listening, .idle),
            (.connecting, .idle), (.coordinating, .coding), (.composing, .replying), (.waiting, .sleeping),
            (.shaping, .idle),
        ]
        for (scenario, motion) in expected {
            #expect(BighelpThinkingOrbPresentation.resolve(scenario: scenario, scale: .inline).motion == motion,
                    "\(scenario)")
        }
    }

    @Test func voiceActsOutTheCall() {
        #expect(VoiceLifter.motion(turnBased: .listening, live: .listening) == .idle)
        #expect(VoiceLifter.motion(turnBased: .working, live: .thinking) == .thinking)
        #expect(VoiceLifter.motion(turnBased: .speaking, live: .speaking) == .replying)
        #expect(VoiceLifter.motion(turnBased: .paused, live: .idle) == .sleeping)
        #expect(VoiceLifter.motion(turnBased: .unavailable, live: .idle) == .error)
        #expect(VoiceLifter.motion(livePhase: .connecting, live: .idle) == .idle)
        #expect(VoiceLifter.motion(livePhase: .failed, live: .idle) == .error)
        #expect(VoiceLifter.motion(livePhase: .ended, live: .idle) == .sleeping)
    }

    @Test func aPullScrubsThePressUpToItsLastFrame() {
        #expect(BighelpPullToRefreshMetrics.progress(-10) == 0)
        #expect(BighelpPullToRefreshMetrics.progress(45) == 0.5)
        #expect(BighelpPullToRefreshMetrics.progress(400) == 1)
    }
}
