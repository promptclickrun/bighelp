import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// Issue #96: a card's optional weather background. Parsing is lenient (the
/// plugin is the strict gate), text stays readable on every sky, and the
/// animation only runs while someone can see it.
struct CardBackgroundTests {
    // MARK: Parsing

    @Test func everySceneIntensityAndTimeOfDayParses() throws {
        let warnings = RecordingWarnings()
        for scene in CardBackground.Scene.allCases where scene != .none {
            for intensity in CardBackground.Intensity.allCases {
                for time in CardBackground.TimeOfDay.allCases {
                    let value = background(["scene": scene.rawValue, "intensity": intensity.rawValue,
                                            "time_of_day": time.rawValue])
                    let parsed = try #require(CardBackground.parse(value, warnings: warnings.sink))
                    #expect(parsed == CardBackground(scene: scene, intensity: intensity, timeOfDay: time))
                }
            }
        }
        #expect(warnings.messages.isEmpty)
    }

    @Test func intensityAndTimeOfDayDefaultToModerateAndDay() throws {
        let parsed = try #require(CardBackground.parse(background(["scene": "rain"]), warnings: RecordingWarnings().sink))
        #expect(parsed == CardBackground(scene: .rain, intensity: .moderate, timeOfDay: .day))
    }

    @Test func noneAndAMissingBackgroundKeepTheUsualSurface() throws {
        let warnings = RecordingWarnings()
        #expect(CardBackground.parse(nil, warnings: warnings.sink) == nil)
        #expect(CardBackground.parse(background(["scene": "none", "intensity": "heavy"]), warnings: warnings.sink) == nil)
        #expect(CardBackground.of(try card(background: nil), warnings: warnings.sink) == nil)
        #expect(warnings.messages.isEmpty)
    }

    @Test func anUnknownSceneDrawsTheFallbackAndWarnsOnce() throws {
        let warnings = RecordingWarnings()
        let value = background(["scene": "hail", "time_of_day": "night"])
        for _ in 0..<5 {
            let parsed = try #require(CardBackground.parse(value, warnings: warnings.sink))
            #expect(parsed.scene == nil, "Unknown scenes have no scene of their own")
            #expect(parsed.timeOfDay == .night)
        }
        #expect(warnings.messages.count == 1, "\(warnings.messages)")
        #expect(warnings.messages.first?.contains("scene") == true)

        _ = CardBackground.parse(background(["scene": "sleet"]), warnings: warnings.sink)
        #expect(warnings.messages.count == 2, "A different unknown scene gets its own warning")
    }

    @Test func unknownIntensityAndTimeOfDayFallBackToTheDefaults() throws {
        let warnings = RecordingWarnings()
        let value = background(["scene": "snow", "intensity": "blizzard", "time_of_day": "dawn"])
        for _ in 0..<3 {
            let parsed = try #require(CardBackground.parse(value, warnings: warnings.sink))
            #expect(parsed == CardBackground(scene: .snow, intensity: .moderate, timeOfDay: .day))
        }
        #expect(warnings.messages.count == 2, "\(warnings.messages)")
    }

    @Test func malformedBackgroundsKeepTheUsualSurface() throws {
        let warnings = RecordingWarnings()
        let malformed: [BighelpJSONValue] = [
            .string("rain"),
            .array([.string("rain")]),
            .object(["intensity": .string("heavy")]),
            .object(["scene": .integer(3)]),
            .object(["scene": .null]),
        ]
        for value in malformed {
            #expect(CardBackground.parse(value, warnings: warnings.sink) == nil, "\(value)")
        }
        #expect(warnings.messages.count == 1, "Malformed backgrounds warn once, not once per card")
    }

    /// Newer cards may add keys; this build ignores them rather than dropping
    /// the card. The plugin is where extra keys are rejected.
    @Test func extraKeysAreIgnored() throws {
        let parsed = try #require(CardBackground.parse(
            .object(["scene": .string("fog"), "wind_direction": .string("nw")]),
            warnings: RecordingWarnings().sink))
        #expect(parsed.scene == .fog)
    }

    @Test func aCardsBackgroundComesFromItsRootCardElement() throws {
        let weather = try card(background: ["scene": "thunderstorm", "intensity": "heavy", "time_of_day": "dusk"])
        #expect(try BighelpCardValidator.validateForStaticRelease(weather) == weather,
                "Cards with a background stay valid")
        #expect(CardBackground.of(weather, warnings: RecordingWarnings().sink)
                == CardBackground(scene: .thunderstorm, intensity: .heavy, timeOfDay: .dusk))

        // Placed on another element it's an authoring mistake the plugin
        // rejects; here it's simply not drawn.
        let misplaced = try card(background: nil, metricBackground: ["scene": "rain"])
        #expect(try BighelpCardValidator.validateForStaticRelease(misplaced) == misplaced)
        #expect(CardBackground.of(misplaced, warnings: RecordingWarnings().sink) == nil)
    }

    // MARK: Contrast

    /// Primary and secondary text on every sky, at its brightest: each stop of
    /// the gradient under the scrim, with every glow, cloud, fog band and
    /// lightning flash the scene draws at full strength stacked on top.
    /// Luminance along a gradient peaks at a stop, so the stops are the worst case.
    @Test func textMeetsFourPointFiveToOneOnEverySceneAndTime() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let primary = TextColor(UIColor.label.resolvedColor(with: dark))
        let secondary = TextColor(UIColor.secondaryLabel.resolvedColor(with: dark))
        // The Mac draws secondary text white at 55%; check that too.
        let macSecondary = TextColor(red: 1, green: 1, blue: 1, alpha: 0.55)
        var weakest = (ratio: Double.infinity, label: "")
        for scene in [nil] + CardBackground.Scene.allCases.filter({ $0 != .none }).map(Optional.some) {
            for time in CardBackground.TimeOfDay.allCases {
                let look = CardBackgroundLook(scene: scene, timeOfDay: time)
                for (index, worst) in look.brightestBackdrops.enumerated() {
                    for (name, text) in [("primary", primary), ("secondary", secondary), ("Mac secondary", macSecondary)] {
                        let ratio = CardBackgroundRGB.contrast(text.on(worst), worst)
                        let label = "\(scene?.rawValue ?? "unknown") \(time.rawValue) stop \(index) \(name)"
                        #expect(ratio >= 4.5, "\(label): \(ratio)")
                        if ratio < weakest.ratio { weakest = (ratio, label) }
                    }
                }
            }
        }
        print("Weakest card background contrast: \(weakest.label) \(String(format: "%.2f", weakest.ratio)):1")
    }

    /// Rain, snowflakes, stars and gusts are a few points wide. Even where one
    /// passes right behind a letter at full strength, primary text keeps 4.5:1.
    @Test func fineParticlesNeverDrownPrimaryText() {
        let primary = TextColor(UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
        for scene in CardBackground.Scene.allCases where scene != .none {
            for time in CardBackground.TimeOfDay.allCases {
                let look = CardBackgroundLook(scene: scene, timeOfDay: time)
                for backdrop in look.brightestBackdrops {
                    let worst = CardBackgroundRGB.white.composited(over: backdrop, opacity: look.fineParticlePeak)
                    let ratio = CardBackgroundRGB.contrast(primary.on(worst), worst)
                    #expect(ratio >= 4.5, "\(scene.rawValue) \(time.rawValue): \(ratio)")
                }
            }
        }
    }

    @Test func brightScenesNeedTheStrongestScrim() {
        let clearDay = CardBackgroundLook(scene: .clear, timeOfDay: .day).scrimOpacity
        let snowDay = CardBackgroundLook(scene: .snow, timeOfDay: .day).scrimOpacity
        let rainNight = CardBackgroundLook(scene: .rain, timeOfDay: .night).scrimOpacity
        #expect(clearDay > rainNight)
        #expect(snowDay > rainNight)
    }

    // MARK: Motion

    @Test func theAnimationRunsOnlyWhenItCanBeSeen() {
        let rain = CardBackground(scene: .rain, intensity: .heavy, timeOfDay: .night)
        let moving = BighelpLoaderMotion(animates: true, moves: true, isLowPower: false)
        let still = BighelpLoaderMotion(animates: false, moves: true, isLowPower: false)
        func animates(_ background: CardBackground = rain, motion: BighelpLoaderMotion = moving,
                      onScreen: Bool = true, snapshot: Bool = false) -> Bool {
            CardBackgroundAnimationPolicy.animates(background, motion: motion, isOnScreen: onScreen, isSnapshot: snapshot)
        }
        #expect(animates())
        #expect(!animates(onScreen: false), "Offscreen cards pause")
        #expect(!animates(snapshot: true), "Copy as Image draws the still gradient")
        #expect(!animates(motion: still), "Reduce Motion, Low Power Mode and a backgrounded app stop it")
        #expect(!animates(CardBackground(scene: nil, intensity: .moderate, timeOfDay: .day)),
                "An unknown scene only has its gradient")
        for scene in CardBackground.Scene.allCases where scene != .none {
            #expect(animates(CardBackground(scene: scene, intensity: .light, timeOfDay: .day)), "\(scene)")
        }
    }

    /// Reduce Motion, Low Power Mode and the app leaving the screen all reach
    /// the card through the loaders' shared motion rule.
    @Test func systemSettingsStopTheAnimation() {
        func motion(reduce: Bool = false, lowPower: Bool = false, active: Bool = true) -> BighelpLoaderMotion {
            BighelpLoaderMotionPolicy.resolve(reduceMotion: reduce, appIsActive: active, scenePhase: .active,
                                              lowPowerMode: lowPower, override: .init())
        }
        let rain = CardBackground(scene: .rain, intensity: .moderate, timeOfDay: .day)
        for (label, value) in [("reduce", motion(reduce: true)), ("low power", motion(lowPower: true)),
                               ("inactive", motion(active: false))] {
            #expect(!CardBackgroundAnimationPolicy.animates(rain, motion: value, isOnScreen: true, isSnapshot: false),
                    "\(label)")
        }
    }

    @Test func particleCountsRiseWithIntensityAndStayCapped() {
        for scene in CardBackground.Scene.allCases where scene != .none {
            let counts = CardBackground.Intensity.allCases.map { CardWeatherPainter.particleCount(scene, $0) }
            #expect(counts == counts.sorted(), "\(scene): \(counts)")
            #expect(counts.allSatisfy { $0 <= CardWeatherPainter.maximumParticles }, "\(scene): \(counts)")
        }
        #expect(CardWeatherPainter.particleCount(.rain, .heavy) > CardWeatherPainter.particleCount(.rain, .light))
        #expect(CardWeatherPainter.maximumParticles <= 100)
    }

    // MARK: Rendering

    /// A card without a background, or with scene none, draws exactly as before.
    @MainActor @Test func noneDrawsExactlyLikeACardWithoutABackground() throws {
        let plain = try png(card(background: nil))
        let none = try png(card(background: ["scene": "none"]))
        let rain = try png(card(background: ["scene": "rain"]))
        #expect(plain == none)
        #expect(plain != rain)
    }

    /// Copy as Image draws the still gradient, so the same card copies the same
    /// picture every time.
    @MainActor @Test func aWeatherCardCopiesAsTheSameStillPicture() throws {
        let storm = try card(background: ["scene": "thunderstorm", "intensity": "heavy", "time_of_day": "night"])
        let first = try png(storm)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(first == (try png(storm)), "Nothing in the picture depends on the time it was taken")
    }

    // MARK: Helpers

    @MainActor private func png(_ card: BighelpCardDocument) throws -> Data {
        try #require(ChatCardImage.png(BighelpCardView(card: card), width: 320, scale: 2,
                                       background: .white, environment: EnvironmentValues()))
    }

    private func background(_ fields: [String: String]) -> BighelpJSONValue {
        .object(fields.mapValues(BighelpJSONValue.string))
    }

    private func card(background: [String: String]?,
                      metricBackground: [String: String]? = nil) throws -> BighelpCardDocument {
        var root: [String: BighelpJSONValue] = [
            "type": .string("card"),
            "props": .object(["title": .string("Sample Bay"), "subtitle": .string("Made-up weather")]),
            "children": .array([.string("now")]),
        ]
        if let background { root["background"] = self.background(background) }
        var metric: [String: BighelpJSONValue] = [
            "type": .string("metric"),
            "props": .object(["label": .string("Now"), "value": .object(["literal": .integer(54)])]),
            "children": .array([]),
        ]
        if let metricBackground { metric["background"] = self.background(metricBackground) }
        return try BighelpCardDocument(document: [
            "schema": .string("loopdy.card"),
            "version": .integer(1),
            "title": .string("Sample Bay"),
            "spoken_summary": .string("Made-up weather for a test."),
            "data_sources": .array([]),
            "root": .string("root"),
            "elements": .object(["root": .object(root), "now": .object(metric)]),
            "content_hash": .string(String(repeating: "c", count: 64)),
            "card_id": .string(String(repeating: "d", count: 32)),
            "origin": .string("live"),
            "created_at": .string("2026-09-02T12:00:00Z"),
        ])
    }
}

/// Collects warnings in place of the system log.
private final class RecordingWarnings: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    lazy var sink = CardBackgroundWarnings { [weak self] field, value in
        guard let self else { return }
        lock.lock(); recorded.append("\(field)=\(value)"); lock.unlock()
    }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// A text color with its alpha, laid over a backdrop the way UIKit draws it.
private struct TextColor {
    let rgb: CardBackgroundRGB
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        rgb = CardBackgroundRGB(red: red, green: green, blue: blue)
        self.alpha = alpha
    }

    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    func on(_ backdrop: CardBackgroundRGB) -> CardBackgroundRGB {
        rgb.composited(over: backdrop, opacity: alpha)
    }
}
