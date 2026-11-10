import CoreGraphics
import Testing
@testable import Bighelp

struct ThinkingLadderTests {
    private let levels = ["none", "low", "medium", "high", "xhigh"]

    @Test func positionStopsAtTheThumbInsetAtBothEnds() {
        let width: CGFloat = 248
        #expect(ThinkingLadder.position(atX: 0, width: width) == 0)
        #expect(ThinkingLadder.position(atX: ThinkingSliderMetrics.inset, width: width) == 0)
        #expect(ThinkingLadder.position(atX: width - ThinkingSliderMetrics.inset, width: width) == 1)
        #expect(ThinkingLadder.position(atX: width, width: width) == 1)
        #expect(ThinkingLadder.position(atX: width / 2, width: width) == 0.5)
    }

    @Test func indexRoundsToTheNearestLevel() {
        let ladder = ThinkingLadder(levels: levels, current: "medium")
        #expect(ladder.index(atPosition: 0) == 0)
        #expect(ladder.index(atPosition: 0.12) == 0)
        #expect(ladder.index(atPosition: 0.13) == 1)
        #expect(ladder.index(atPosition: 0.87) == 3)
        #expect(ladder.index(atPosition: 0.88) == 4)
        #expect(ladder.index(atPosition: 1) == 4)
        #expect(ladder.position(of: 4) == 1)
    }

    @Test func aLevelTheModelDoesntNameStaysOnTheLadder() {
        let ladder = ThinkingLadder(levels: levels, current: "ultra")
        #expect(ladder.levels.last == "ultra")
        #expect(ladder.currentIndex == 5)
    }

    @Test func committingTheCurrentLevelSendsNothing() {
        let ladder = ThinkingLadder(levels: levels, current: "medium")
        #expect(ladder.commit(at: 2) == nil)
        #expect(ladder.commit(at: 3) == "high")
        #expect(ladder.commit(at: 9) == nil)
    }

    @Test func aDragTicksOncePerLevelAndCommitsOnceOnRelease() {
        let ladder = ThinkingLadder(levels: levels, current: "none")
        var drag = ThinkingSliderDrag()
        #expect(drag.move(to: 0.05, on: ladder) == false)
        #expect(drag.move(to: 0.2, on: ladder) == true)
        #expect(drag.move(to: 0.3, on: ladder) == false)
        #expect(drag.move(to: 0.55, on: ladder) == true)
        #expect(drag.move(to: 0.58, on: ladder) == false)

        #expect(drag.end(on: ladder) == 2)
        #expect(drag.isLanded)
        #expect(drag.position == 0.5)
        #expect(drag.end(on: ladder) == nil)
        #expect(drag.position == 0.5)
    }

    @Test func releasingOnTheCurrentLevelSendsNothingAndLetsGo() {
        let ladder = ThinkingLadder(levels: levels, current: "high")
        var drag = ThinkingSliderDrag()
        _ = drag.move(to: 0.74, on: ladder)
        #expect(drag.end(on: ladder) == nil)
        #expect(drag.position == nil)
        #expect(!drag.isLanded)
    }

    @Test func aMostlyVerticalFirstMovementIsNotAnAdjustment() {
        #expect(!ThinkingLadder.isAdjustment(CGSize(width: 3, height: -40)))
        #expect(ThinkingLadder.isAdjustment(CGSize(width: -40, height: 12)))
    }

    @Test func adjustingStepsOneLevelAndStopsAtTheEnds() {
        #expect(ThinkingLadder(levels: levels, current: "medium").adjusted(by: 1) == 3)
        #expect(ThinkingLadder(levels: levels, current: "none").adjusted(by: -1) == nil)
        #expect(ThinkingLadder(levels: levels, current: "xhigh").adjusted(by: 1) == nil)
        #expect(ThinkingLadder(levels: levels, current: nil).adjusted(by: 1) == 0)
        #expect(ThinkingLadder(levels: levels, current: nil).adjusted(by: -1) == 0)
    }
}
