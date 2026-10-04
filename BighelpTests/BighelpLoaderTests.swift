import Foundation
import SwiftUI
import Testing
@testable import Bighelp

struct BighelpLoaderMotionTests {
    private func motion(reduceMotion: Bool = false, appIsActive: Bool = true, scenePhase: ScenePhase = .active,
                        lowPower: Bool = false,
                        override: BighelpLoaderMotionOverride = .init()) -> BighelpLoaderMotion {
        BighelpLoaderMotionPolicy.resolve(reduceMotion: reduceMotion, appIsActive: appIsActive, scenePhase: scenePhase,
                                          lowPowerMode: lowPower, override: override)
    }

    @Test func loadersMoveOnlyWhileTheAppIsActiveWithMotionAllowed() {
        #expect(motion() == BighelpLoaderMotion(animates: true, moves: true, isLowPower: false))
        #expect(!motion(appIsActive: false).animates)
        #expect(!motion(scenePhase: .background).animates)
        #expect(!motion(reduceMotion: true).animates)
        #expect(!motion(reduceMotion: true).moves)
        // Low Power Mode stops loops and flourishes but keeps plain transitions.
        #expect(motion(lowPower: true) == BighelpLoaderMotion(animates: false, moves: true, isLowPower: true))
    }

    @Test func aStaleInactiveScenePhaseInAChatRowDoesNotFreezeLoaders() {
        // Chat rows carry a copy of the scene phase; an old "inactive" copy once
        // froze every chat animation. The app's own state decides instead.
        #expect(motion(appIsActive: true, scenePhase: .inactive).animates)
        #expect(!motion(appIsActive: false, scenePhase: .inactive).animates)
    }

    @Test func overridesCanOnlyStopMotion() {
        #expect(!motion(override: .init(reduceMotion: true)).animates)
        #expect(!motion(override: .init(reduceMotion: true)).moves)
        #expect(motion(override: .init(lowPowerMode: true)).isLowPower)
        #expect(!motion(override: .init(sceneInactive: true)).animates)
        #expect(!motion(reduceMotion: true, override: .init()).animates)
    }

    @Test func everyCopyReadsTheSamePhaseAtTheSameMoment() {
        let date = Date(timeIntervalSinceReferenceDate: 812_345.678)
        let first = BighelpLoaderTime(date), second = BighelpLoaderTime(date)
        #expect(first.phase(1.9) == second.phase(1.9))
        #expect((0..<1).contains(first.phase(1.9)))
        let later = BighelpLoaderTime(seconds: 812_345.678 + 0.95)
        #expect(abs(later.phase(1.9) - (first.phase(1.9) + 0.5).truncatingRemainder(dividingBy: 1)) < 1e-9)
        #expect(BighelpLoaderTime(seconds: 10).phase(4, offset: 1) == BighelpLoaderTime(seconds: 11).phase(4))
        #expect(BighelpLoaderTime(seconds: 0.2).phase(1, offset: -0.5) > 0)
    }

    @Test func theStillFrameRestsWhereEachLoaderSaysItShould() {
        #expect(BighelpLoaderTime.still.isStill)
        #expect(BighelpLoaderTime.still.phase(1.9) == 0)
        #expect(BighelpLoaderTime.still.phase(1.9, rest: 0.5) == 0.5)
        #expect(BighelpLoaderTime.still.pingPong(2, rest: 0.3) == 0.3)
    }

    @Test func pingPongGoesThereAndBack() {
        #expect(abs(BighelpLoaderTime(seconds: 0).pingPong(2)) < 1e-9)
        #expect(abs(BighelpLoaderTime(seconds: 2).pingPong(2) - 1) < 1e-9)
        #expect(abs(BighelpLoaderTime(seconds: 1).pingPong(2) - 0.5) < 1e-9)
        #expect(abs(BighelpLoaderTime(seconds: 3).pingPong(2) - 0.5) < 1e-9)
    }

    @Test func curvesStartAndEndInPlace() {
        for curve in [BighelpLoaderCurve.linear, .easeInOut, .easeOut, .site] {
            #expect(abs(curve(0)) < 1e-6)
            #expect(abs(curve(1) - 1) < 1e-6)
        }
        #expect(abs(BighelpLoaderCurve.easeInOut(0.5) - 0.5) < 1e-3)
        // The site's ease is front-loaded; pop overshoots before settling.
        #expect(BighelpLoaderCurve.site(0.3) > 0.7)
        #expect((0...1).map { BighelpLoaderCurve.pop(Double($0) / 1) }.last == 1)
        #expect(stride(from: 0.0, through: 1, by: 0.05).contains { BighelpLoaderCurve.pop($0) > 1 })
    }

    @Test func theShimmerHighlightCrossesTheWholeLabel() {
        #expect(abs(BighelpShimmerGeometry.highlightCenter(phase: 0) - -0.3) < 1e-9)
        #expect(abs(BighelpShimmerGeometry.highlightCenter(phase: 1) - 1.3) < 1e-9)
    }

    @Test func theSkeletonSweepStartsAndEndsOffTheCard() {
        let width: CGFloat = 360
        let band = BighelpSkeletonPalette.bandWidth(forContainerWidth: width)
        #expect(BighelpSkeletonPalette.bandOffset(phase: 0, containerWidth: width) == -band)
        #expect(abs(BighelpSkeletonPalette.bandOffset(phase: 1, containerWidth: width) - (width + band)) < 0.001)
        #expect(BighelpSkeletonPalette.bandWidth(forContainerWidth: 2_000) == 420)
        #expect(BighelpSkeletonPalette.bandWidth(forContainerWidth: 50) == 140)
    }

    @Test func connectingDotsBounceInTurnAndRestWhenStill() {
        // The first dot tops out 30% into its 1.1 s loop; the next one lags 0.15 s behind.
        let time = BighelpLoaderTime(seconds: 1.1 * 1000 + 0.32)
        #expect(BighelpConnectionMotion.bounce(time, index: 0) > 0.9)
        #expect(BighelpConnectionMotion.bounce(time, index: 1) < BighelpConnectionMotion.bounce(time, index: 0))
        #expect(BighelpConnectionMotion.bounce(.still, index: 0) == 0)
        let start = BighelpConnectionMotion.travel(0), middle = BighelpConnectionMotion.travel(0.5)
        #expect(start.opacity == 0 && middle.opacity == 1)
        #expect(middle.position > 0.5)
    }

    @Test func theOrbBlinksOnceALoop() {
        #expect(BighelpOrbGlyph.eyes(at: .still) == (0, 1))
        let blink = BighelpOrbGlyph.eyes(at: BighelpLoaderTime(seconds: 3.2 * 100 + 3.2 * 0.48))
        #expect(blink.openness < 0.15)
        let glancing = BighelpOrbGlyph.eyes(at: BighelpLoaderTime(seconds: 3.2 * 100 + 3.2 * 0.35))
        #expect(glancing.glance == -1.4 && glancing.openness == 1)
    }
}

struct BighelpConnectionStatusTests {
    @Test func detailShowsOnlyRealValues() {
        #expect(BighelpConnectionDetail().text(for: .connecting) == nil)
        #expect(BighelpConnectionDetail().text(for: .reconnecting) == nil)
        #expect(BighelpConnectionDetail().text(for: .connected) == nil)
        #expect(BighelpConnectionDetail().text(for: .disconnected) == nil)
        #expect(BighelpConnectionDetail(attempt: 2, maximumAttempts: 5).text(for: .reconnecting) == "Trying again · 2 of 5")
        #expect(BighelpConnectionDetail(latencyMilliseconds: 24, hermesVersion: "0.21.4").text(for: .connected)
                == "Hermes 0.21.4 · 24 ms")
        #expect(BighelpConnectionDetail(hermesVersion: "0.21.2").text(for: .connected) == "Hermes 0.21.2")
        #expect(BighelpConnectionDetail(latencyMilliseconds: 31).text(for: .connected) == "31 ms")
        #expect(BighelpConnectionDetail(message: "Hermes didn't answer.").text(for: .disconnected)
                == "Hermes didn't answer.")
    }

    @Test func nonsenseIsDroppedRatherThanShown() {
        #expect(BighelpConnectionDetail(attempt: 6, maximumAttempts: 5).text(for: .reconnecting) == nil)
        #expect(BighelpConnectionDetail(attempt: 0, maximumAttempts: 5).text(for: .reconnecting) == nil)
        #expect(BighelpConnectionDetail(attempt: 2).text(for: .reconnecting) == nil)
        #expect(BighelpConnectionDetail(latencyMilliseconds: -3).text(for: .connected) == nil)
        #expect(BighelpConnectionDetail(hermesVersion: "<script>").text(for: .connected) == nil)
        #expect(BighelpConnectionDetail(message: "   ").text(for: .disconnected) == nil)
        // The attempt count belongs to retrying only.
        #expect(BighelpConnectionDetail(attempt: 2, maximumAttempts: 5).text(for: .connected) == nil)
    }

    @Test func phasesAlwaysHaveWords() {
        #expect(BighelpConnectionPhase.allCases.map(\.label)
                == ["Connecting…", "Reconnecting…", "Connected", "Disconnected"])
    }

    @Test func theDeviceSaysWhichDeviceItIs() {
        #expect(BighelpDeviceKind.allCases.map(\.label) == ["This iPhone", "This iPad", "This Mac", "This Vision Pro"])
        #expect(BighelpDeviceKind.allCases.allSatisfy { UIImage(systemName: $0.systemImage) != nil })
    }
}

struct BighelpActivityRowTests {
    @Test func aFinishedTurnSaysHowLongItReallyTook() {
        #expect(BighelpActivitySummary.doneLabel(elapsed: nil) == "Done")
        #expect(BighelpActivitySummary.doneLabel(elapsed: .nan) == "Done")
        #expect(BighelpActivitySummary.doneLabel(elapsed: -1) == "Done")
        #expect(BighelpActivitySummary.doneLabel(elapsed: 0.3) == "Worked for less than a second")
        #expect(BighelpActivitySummary.doneLabel(elapsed: 14) == "Worked for 14s")
        #expect(BighelpActivitySummary.doneLabel(elapsed: 125) == "Worked for 2m 5s")
        #expect(BighelpActivitySummary.doneLabel(elapsed: 3_725) == "Worked for 1h 2m")
    }

    /// Models head each thought with `**Checking the tests**`; the Thinking text
    /// draws that emphasis instead of showing the asterisks, and leaves code-ish
    /// text (`2 * 3`, `snake_case`, `__init__`) as written.
    @Test func thinkingDrawsMarkdownEmphasis() {
        func runs(_ text: String) -> [(String, InlinePresentationIntent?)] {
            let note = BighelpActivitySummary.note(text)
            return note.runs.map { (String(note[$0.range].characters), $0.inlinePresentationIntent) }
        }
        func plain(_ text: String) -> String { String(BighelpActivitySummary.note(text).characters) }

        let heading = runs("**Checking state contract updates**\n\nI should read the tests.")
        #expect(heading.map(\.0) == ["Checking state contract updates", "\n\nI should read the tests."])
        #expect(heading.map(\.1) == [.stronglyEmphasized, nil])
        #expect(runs("__Planning__ next").map(\.1) == [.stronglyEmphasized, nil])
        #expect(runs("a *quick* look").map(\.0) == ["a ", "quick", " look"])
        #expect(runs("a *quick* look").map(\.1) == [nil, .emphasized, nil])
        #expect(runs("**Read *all* of it**").map(\.1) == [.stronglyEmphasized, [.stronglyEmphasized, .emphasized],
                                                          .stronglyEmphasized])

        for literal in ["2 * 3 * 4", "2*3*4", "call __init__ first", "edit __init__.py", "snake_case_name",
                        "f(*args, **kwargs)", "**unclosed bold", "** spaced **", "*a\nb*", "***", "a**b**c",
                        "`**raw**` stays"] {
            #expect(plain(literal) == literal, "\(literal)")
        }
        #expect(plain("**Two**\n\n**Thoughts**") == "Two\n\nThoughts")
    }

    @Test func stepCountsReadNaturally() {
        #expect(BighelpActivitySummary.stepCountLabel(0) == nil)
        #expect(BighelpActivitySummary.stepCountLabel(1) == "· 1 step")
        #expect(BighelpActivitySummary.stepCountLabel(3) == "· 3 steps")
    }

    @Test func eachPhaseHasItsLabelAndGlyph() {
        #expect(BighelpActivitySummary.label(for: .thinking) == "Thinking")
        #expect(BighelpActivitySummary.glyph(for: .thinking) == .thinking)
        let browsing = BighelpToolActivityCatalog.activity(forTool: "browser_navigate")
        #expect(BighelpActivitySummary.label(for: .working(browsing)) == "Browsing the web…")
        #expect(BighelpActivitySummary.label(for: .waitingForApproval()) == "Waiting for your yes")
        #expect(BighelpActivitySummary.glyph(for: .waitingForApproval()) == .glyph(.shield))
        #expect(BighelpActivitySummary.label(for: .done(elapsed: 9)) == "Worked for 9s")
        #expect(BighelpActivitySummary.glyph(for: .done(elapsed: 9)) == .done)
        #expect(BighelpActivityPhase.thinking.isLive && !BighelpActivityPhase.done(elapsed: nil).isLive)
        #expect(!BighelpActivityPhase.waitingForApproval().isLive)
    }

    @Test func otherEndingsSayWhatHappened() {
        #expect(BighelpActivitySummary.label(for: .thought(elapsed: 6.7)) == "Thought for 6s")
        #expect(BighelpActivitySummary.label(for: .thought(elapsed: 125)) == "Thought for 2m 5s")
        #expect(BighelpActivitySummary.label(for: .thought(elapsed: 0.4)) == "Thought process")
        #expect(BighelpActivitySummary.label(for: .thought(elapsed: nil)) == "Thought process")
        #expect(BighelpActivitySummary.label(for: .thought(elapsed: .infinity)) == "Thought process")
        #expect(BighelpActivitySummary.glyph(for: .thought(elapsed: 6)) == .thinking)
        #expect(BighelpActivitySummary.label(for: .stopped) == "Stopped")
        #expect(BighelpActivitySummary.label(for: .failed) == "Hit a snag")
        for phase in [BighelpActivityPhase.thought(elapsed: 6), .stopped, .failed] {
            #expect(!phase.isLive, "\(phase)")
        }
    }

    @Test func theRenderersOlderOneCardPerKindToolsAreMakingACard() {
        #expect(BighelpToolActivityCatalog.activity(forTool: "loopdy_render_weather_forecast").label == "Making a card…")
        #expect(BighelpToolActivityCatalog.activity(forTool: "bighelp_render_summary").doneLabel == "Made a card")
    }
}

struct BighelpImageGeneratingTests {
    @Test func theProgressBarNeedsARealFraction() {
        #expect(BighelpImageGeneratingView.visibleProgress(nil) == nil)
        #expect(BighelpImageGeneratingView.visibleProgress(.nan) == nil)
        #expect(BighelpImageGeneratingView.visibleProgress(.infinity) == nil)
        #expect(BighelpImageGeneratingView.visibleProgress(0.4) == 0.4)
        #expect(BighelpImageGeneratingView.visibleProgress(1.6) == 1)
        #expect(BighelpImageGeneratingView.visibleProgress(-0.2) == 0)
    }

    @Test func countsShowOnlyForARealSet() {
        #expect(BighelpImageCount(completed: 2, total: 4)?.label == "2 of 4")
        #expect(BighelpImageCount(completed: 0, total: 1) == nil)
        #expect(BighelpImageCount(completed: 5, total: 4) == nil)
        #expect(BighelpImageCount(completed: -1, total: 4) == nil)
    }

    @Test func theDefaultCaptionMakesNoPromises() {
        let view = BighelpImageGeneratingView()
        #expect(view.caption == "Making your image")
        #expect(view.progress == nil && view.count == nil)
    }
}
