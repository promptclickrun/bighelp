import CoreGraphics
import Foundation
import Testing
@testable import Bighelp

/// Heavyweight, the Thinking look out of the box: where the lifter's box is and how hard he shakes.
struct ThinkingHeavyweightTests {
    private let control = CGSize(width: 320, height: HeavyweightPose.height)

    private func pose(level: Double, lift: Double, time: Double = 12.3, isStill: Bool = false) -> HeavyweightPose {
        HeavyweightPose(size: control, level: level, lift: lift, time: time, isStill: isStill)
    }

    @Test func heavyweightIsTheLookOutOfTheBoxAndAPickedLookStays() throws {
        let suite = "bighelp.tests.thinking-look.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func picked() -> BighelpThinkingLook {
            defaults.string(forKey: BighelpThinkingLook.storageKey).flatMap(BighelpThinkingLook.init(rawValue:))
                ?? BighelpThinkingLook.defaultLook
        }

        #expect(picked() == .heavyweight)
        #expect(BighelpThinkingLook.allCases.first == .heavyweight)
        // Someone who picked Noodle, the look out of the box before, keeps it.
        defaults.set(BighelpThinkingLook.noodle.rawValue, forKey: BighelpThinkingLook.storageKey)
        #expect(picked() == .noodle)
        // A name this build doesn't know reads as the default.
        defaults.set("someLaterLook", forKey: BighelpThinkingLook.storageKey)
        #expect(picked() == .heavyweight)
    }

    @Test func atTheBottomTheBoxIsOnTheFloorBesideHimAndNothingMoves() {
        let rest = pose(level: 0, lift: 0)
        #expect(abs(rest.box.maxY - rest.ground) < 0.001)
        #expect(rest.box.minX > rest.body.maxX)
        #expect(abs(rest.body.maxY - rest.ground) < 0.001)
        #expect(rest.shake == 0)
        #expect(rest.tilt == 0)
        // No time passes for him there.
        let later = pose(level: 0, lift: 0, time: 99.9)
        #expect(later.box == rest.box)
        #expect(later.body == rest.body)
    }

    @Test func theBoxGoesOverHisHeadAndGrowsWithTheLevel() {
        let low = pose(level: 0.2, lift: 1), top = pose(level: 1, lift: 1)
        for carried in [low, top] {
            #expect(carried.box.maxY < carried.body.minY)
            #expect(carried.box.minY >= 0)
            #expect(carried.box.minX >= 0 && carried.box.maxX <= control.width)
            // Over him, not beside him.
            #expect(abs(carried.box.midX - carried.body.midX) < 8)
        }
        #expect(top.box.width > low.box.width)
        #expect(top.box.height > low.box.height)
        // The load squashes him.
        #expect(top.body.height < low.body.height)
        #expect(top.body.width > low.body.width)
    }

    @Test func heShakesOnlyAboveTheMiddleAndHarderAtEachLevel() {
        // Low on a six-level ladder is 0.2, Medium 0.6, the top 1.
        #expect(HeavyweightPose.shake(level: 0, isStill: false) == 0)
        #expect(HeavyweightPose.shake(level: 0.2, isStill: false) == 0)
        let medium = HeavyweightPose.shake(level: 0.6, isStill: false)
        let high = HeavyweightPose.shake(level: 0.8, isStill: false)
        let top = HeavyweightPose.shake(level: 1, isStill: false)
        #expect(medium > 0)
        #expect(high > medium)
        #expect(top > high)
        #expect(abs(top - 1) < 0.000_001)
        // The shake moves him from frame to frame.
        #expect(pose(level: 1, lift: 1, time: 1).body != pose(level: 1, lift: 1, time: 1.02).body)
    }

    @Test func aHeldPoseDoesNotShake() {
        // Reduce Motion, a cover, off screen: the pose shows the level and stands still.
        let first = pose(level: 1, lift: 1, time: 1, isStill: true)
        let second = pose(level: 1, lift: 1, time: 7.7, isStill: true)
        #expect(first.shake == 0)
        #expect(first.tilt == 0)
        #expect(first.box == second.box)
        #expect(first.body == second.body)
        #expect(first.box.maxY < first.body.minY)
    }

    @Test func oneTracksHeightDrawsHimSmallWithNoRail() {
        // New chat's sweep has one track's height for every look.
        let size = CGSize(width: 320, height: ThinkingSliderMetrics.height)
        let sweep = HeavyweightPose(size: size, level: 1, lift: 1, time: 3, isStill: false)
        #expect(sweep.isCompact)
        #expect(sweep.stage.height == size.height)
        #expect(sweep.box.minY >= 0)
        #expect(sweep.body.maxY <= size.height)
        #expect(!pose(level: 1, lift: 1).isCompact)
        #expect(BighelpThinkingLook.heavyweight.height == HeavyweightPose.height)
        #expect(BighelpThinkingLook.noodle.height == ThinkingSliderMetrics.height)
    }
}
