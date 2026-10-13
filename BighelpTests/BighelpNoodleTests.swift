import SwiftUI
import Testing
@testable import Bighelp

/// The brand kit's motions, read from the bundled Lottie files and drawn natively.
@MainActor
struct BighelpNoodleTests {
    /// Every motion loads with the kit's length and loop flag (the kit's `index.json`).
    @Test func everyMotionLoadsAsTheKitMadeIt() throws {
        let kit: [BighelpNoodleMotion: (frames: Double, loops: Bool)] = [
            .reveal: (96, false), .loader: (100, true), .idle: (240, true), .launch: (80, false),
            .exit: (48, false), .pull: (60, false), .thinking: (160, true), .listening: (120, true),
            .talking: (80, true), .done: (120, false), .resting: (200, true), .hello: (100, false),
            .heart: (140, false), .question: (140, false), .infinity: (140, false), .lasso: (140, false),
            .spring: (140, false), .bunny: (140, false), .squiggle: (140, false),
        ]
        #expect(kit.count == BighelpNoodleMotion.allCases.count)
        for motion in BighelpNoodleMotion.allCases {
            let animation = try #require(BighelpNoodleAnimation.named(motion), "\(motion)")
            #expect(animation.frameCount == kit[motion]?.frames, "\(motion)")
            #expect(animation.loops == kit[motion]?.loops, "\(motion)")
            #expect(animation.frameRate == 60)
            #expect(!animation.layers.isEmpty)
        }
    }

    /// The loader writes the b and erases it: its trim opens from nothing to the whole stroke.
    @Test func theLoaderWritesTheMarkThenErasesIt() throws {
        let loader = try #require(BighelpNoodleAnimation.named(.loader))
        let mark = try #require(loader.layers.last, "The kit's top layer is the mark.")
        let group = try #require(mark.groups.first)
        let trim = try #require(group.items.compactMap { item -> (BighelpNoodleAnimation.Animated<Double>,
                                                                  BighelpNoodleAnimation.Animated<Double>)? in
            if case .trim(let start, let end, _) = item { return (start, end) }
            return nil
        }.first)
        #expect(trim.1.value(at: 0) == 0)
        #expect(trim.1.value(at: 52) == 100, "Written by frame 52.")
        #expect(trim.0.value(at: 92) == 100, "Erased by frame 92.")
        let halfway = trim.1.value(at: 26)
        #expect(halfway > 0 && halfway < 100)
    }

    @Test func easesFollowTheKitsCubicCurves() {
        let standard = (0.4, 0.0, 0.2, 1.0)
        #expect(BighelpNoodleCurve.solve(standard, at: 0) == 0)
        #expect(BighelpNoodleCurve.solve(standard, at: 1) == 1)
        // Slow out of the start, fast into the end.
        #expect(BighelpNoodleCurve.solve(standard, at: 0.25) < 0.5)
        #expect(BighelpNoodleCurve.solve(standard, at: 0.75) > 0.9)
    }

    /// A trim that runs past the end wraps to the start, as Lottie's offset does.
    @Test func trimsWrapAroundTheirOffset() {
        var line = Path()
        line.move(to: .zero)
        line.addLine(to: CGPoint(x: 100, y: 0))
        #expect(BighelpNoodleAnimation.trim(line, (0, 0, 0)).isEmpty)
        #expect(BighelpNoodleAnimation.trim(line, (0, 100, 0)).boundingRect.width == 100)
        #expect(abs(BighelpNoodleAnimation.trim(line, (0, 50, 0)).boundingRect.width - 50) < 0.5)
        // Starting at 75% for half the length: the last quarter and the first quarter.
        let wrapped = BighelpNoodleAnimation.trim(line, (0, 50, 270)).boundingRect
        #expect(abs(wrapped.minX) < 0.5 && abs(wrapped.maxX - 100) < 0.5)
    }

    /// Each loader scenario acts out what's happening.
    @Test func loaderScenariosPlayTheirMotions() {
        let expected: [(BighelpThinkingOrbScenario, BighelpNoodleMotion)] = [
            (.working, .loader), (.searching, .lasso), (.reasoning, .thinking), (.listening, .listening),
            (.connecting, .launch), (.coordinating, .infinity), (.composing, .squiggle), (.waiting, .resting),
            (.shaping, .launch),
        ]
        for (scenario, motion) in expected {
            #expect(BighelpThinkingOrbPresentation.resolve(scenario: scenario, scale: .inline).motion == motion,
                    "\(scenario)")
        }
    }

    @Test func voiceActsOutTheCall() {
        #expect(VoiceNoodle.motion(turnBased: .listening, live: .listening) == .listening)
        #expect(VoiceNoodle.motion(turnBased: .working, live: .thinking) == .thinking)
        #expect(VoiceNoodle.motion(turnBased: .speaking, live: .speaking) == .talking)
        #expect(VoiceNoodle.motion(turnBased: .paused, live: .idle) == .resting)
        #expect(VoiceNoodle.motion(turnBased: .unavailable, live: .idle) == .question)
        #expect(VoiceNoodle.motion(livePhase: .connecting, live: .idle) == .launch)
        #expect(VoiceNoodle.motion(livePhase: .failed, live: .idle) == .question)
        #expect(VoiceNoodle.motion(livePhase: .ended, live: .idle) == .exit)
        #expect(VoiceNoodle.playback(.launch) == .loop(pause: 0.6))
    }

    @Test func aPullScrubsTheKitsPullUpToItsLastFrame() {
        #expect(BighelpPullToRefreshMetrics.progress(-10) == 0)
        #expect(BighelpPullToRefreshMetrics.progress(45) == 0.5)
        #expect(BighelpPullToRefreshMetrics.progress(400) == 1)
    }
}
