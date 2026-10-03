import Foundation
import os
import SwiftUI

/// A card's optional weather background (#96): `background` beside the root
/// card element's props. Parsing is lenient, because the plugin is the strict
/// gate and a newer card must still show on this build: anything this build
/// doesn't know falls back, and is logged once.
struct CardBackground: Equatable, Sendable {
    enum Scene: String, CaseIterable, Sendable {
        case none, clear, partlyCloudy = "partly_cloudy", overcast, rain, thunderstorm, snow, fog, wind
    }

    enum Intensity: String, CaseIterable, Sendable {
        case light, moderate, heavy
    }

    enum TimeOfDay: String, CaseIterable, Sendable {
        case day, dusk, night
    }

    /// Nil for a scene this build doesn't know: drawn as the plain fallback gradient.
    var scene: Scene?
    var intensity: Intensity
    var timeOfDay: TimeOfDay

    /// The root card's background, or nil for the card's usual surface.
    static func of(_ card: BighelpCardDocument, warnings: CardBackgroundWarnings = .shared) -> CardBackground? {
        guard let root = card.elements[card.root]?.object, root["type"]?.string == "card" else { return nil }
        return parse(root["background"], warnings: warnings)
    }

    /// Nil when there's no background, the scene is `none`, or it can't be read.
    static func parse(_ value: BighelpJSONValue?, warnings: CardBackgroundWarnings = .shared) -> CardBackground? {
        guard let value else { return nil }
        guard let object = value.object, let sceneName = object["scene"]?.string else {
            warnings.unknown("background", "malformed")
            return nil
        }
        guard sceneName != Scene.none.rawValue else { return nil }
        let scene = Scene(rawValue: sceneName)
        if scene == nil { warnings.unknown("scene", sceneName) }
        return CardBackground(
            scene: scene,
            intensity: field("intensity", object["intensity"], fallback: .moderate, warnings: warnings),
            timeOfDay: field("time_of_day", object["time_of_day"], fallback: .day, warnings: warnings)
        )
    }

    private static func field<Value: RawRepresentable<String>>(
        _ name: String, _ value: BighelpJSONValue?, fallback: Value, warnings: CardBackgroundWarnings
    ) -> Value {
        guard let value else { return fallback }
        guard let text = value.string else {
            warnings.unknown(name, "malformed")
            return fallback
        }
        guard let known = Value(rawValue: text) else {
            warnings.unknown(name, text)
            return fallback
        }
        return known
    }
}

/// One warning per unknown value per launch, however many times its cards are drawn.
final class CardBackgroundWarnings: Sendable {
    static let shared = CardBackgroundWarnings { field, value in
        Logger(subsystem: "app.loopdy.mobile", category: "Cards")
            .warning("Card background has an unknown \(field, privacy: .public) (\(value, privacy: .private)); drawing the fallback")
    }

    private let reported = OSAllocatedUnfairLock(initialState: Set<String>())
    private let log: @Sendable (_ field: String, _ value: String) -> Void

    init(log: @escaping @Sendable (_ field: String, _ value: String) -> Void) {
        self.log = log
    }

    func unknown(_ field: String, _ value: String) {
        let value = String(value.prefix(40))
        guard reported.withLock({ $0.insert("\(field)=\(value)").inserted }) else { return }
        log(field, value)
    }
}

/// An sRGB color as plain numbers, so the contrast of every sky can be checked
/// in a test rather than by eye.
struct CardBackgroundRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = CardBackgroundRGB(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// This color laid over `below` at `opacity`, the way the screen blends them.
    func composited(over below: CardBackgroundRGB, opacity: Double) -> CardBackgroundRGB {
        CardBackgroundRGB(red: red * opacity + below.red * (1 - opacity),
                          green: green * opacity + below.green * (1 - opacity),
                          blue: blue * opacity + below.blue * (1 - opacity))
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ first: CardBackgroundRGB, _ second: CardBackgroundRGB) -> Double {
        let (high, low) = (max(first.luminance, second.luminance), min(first.luminance, second.luminance))
        return (high + 0.05) / (low + 0.05)
    }
}

/// Light the animation lays over the sky, at its brightest.
struct CardBackgroundLight: Equatable, Sendable {
    var color: CardBackgroundRGB
    var peak: Double
}

/// How one scene looks at one time of day. Layers, back to front: the sky
/// gradient, the scrim, the animation's light, then the card's text in white.
/// The scrim is set per scene so primary and secondary text keep 4.5:1 over
/// the brightest sky with all of the scene's glows, clouds, mist and flashes
/// at full strength (`CardBackgroundTests`). Bright skies need the strongest.
struct CardBackgroundLook: Equatable, Sendable {
    /// Top to bottom.
    var sky: [CardBackgroundRGB]
    var scrim: CardBackgroundRGB
    var scrimOpacity: Double
    /// Sun or moon.
    var glow: CardBackgroundLight?
    var cloud: CardBackgroundLight?
    /// Fog banks, or a low mist under rain, snow and wind.
    var mist: CardBackgroundLight?
    var flash: CardBackgroundLight?
    /// Rain, snowflakes, stars and gusts: a few points wide, so they're held
    /// to keeping primary text readable where they pass behind it.
    let fineParticlePeak = 0.28

    /// The sky's stops under the scrim, with every light the scene draws at
    /// full strength stacked on top: the brightest the card ever gets.
    var brightestBackdrops: [CardBackgroundRGB] {
        sky.map { stop in
            [glow, cloud, mist, flash].compactMap { $0 }.reduce(scrim.composited(over: stop, opacity: scrimOpacity)) {
                $1.color.composited(over: $0, opacity: $1.peak)
            }
        }
    }

    init(scene: CardBackground.Scene?, timeOfDay: CardBackground.TimeOfDay) {
        let sun = CardBackgroundRGB(0xFFE7A8), sunset = CardBackgroundRGB(0xFFB070), moon = CardBackgroundRGB(0xDDE4FF)
        func light(_ color: CardBackgroundRGB, _ peak: Double) -> CardBackgroundLight { .init(color: color, peak: peak) }
        func white(_ peak: Double) -> CardBackgroundLight { light(.white, peak) }
        func look(_ top: UInt32, _ bottom: UInt32, scrim: UInt32, _ opacity: Double) -> (sky: [CardBackgroundRGB], scrim: CardBackgroundRGB, opacity: Double) {
            ([CardBackgroundRGB(top), CardBackgroundRGB(bottom)], CardBackgroundRGB(scrim), opacity)
        }
        let base: (sky: [CardBackgroundRGB], scrim: CardBackgroundRGB, opacity: Double)
        var glow: CardBackgroundLight?, cloud: CardBackgroundLight?, mist: CardBackgroundLight?, flash: CardBackgroundLight?
        switch (scene, timeOfDay) {
        case (.clear?, .day): base = look(0x1E5BB8, 0x3F8EDB, scrim: 0x041E52, 0.91); glow = light(sun, 0.07)
        case (.clear?, .dusk): base = look(0x2B2A63, 0xB4583F, scrim: 0x24103A, 0.82); glow = light(sunset, 0.1)
        case (.clear?, .night): base = look(0x070D24, 0x16224A, scrim: 0x03071A, 0.04); glow = light(moon, 0.08)
        case (.partlyCloudy?, .day):
            base = look(0x2A60A8, 0x5A8FC7, scrim: 0x071C46, 0.96); glow = light(sun, 0.05); cloud = white(0.06)
        case (.partlyCloudy?, .dusk):
            base = look(0x33305C, 0x9A5E55, scrim: 0x1C0E2E, 0.91); glow = light(sunset, 0.08); cloud = white(0.07)
        case (.partlyCloudy?, .night):
            base = look(0x0B1229, 0x1E2845, scrim: 0x050A1C, 0.16); glow = light(moon, 0.06)
            cloud = light(CardBackgroundRGB(0xC7CFE0), 0.07)
        case (.overcast?, .day): base = look(0x4B5868, 0x6E7B8A, scrim: 0x121C2B, 0.9); cloud = white(0.09)
        case (.overcast?, .dusk): base = look(0x433F52, 0x6A5E66, scrim: 0x1A1626, 0.82); cloud = white(0.09)
        case (.overcast?, .night): base = look(0x15181F, 0x262B34, scrim: 0x07090E, 0.1); cloud = white(0.09)
        case (.rain?, .day): base = look(0x2F4257, 0x4F6378, scrim: 0x0C1A2C, 0.73); mist = white(0.06)
        case (.rain?, .dusk): base = look(0x2E2D45, 0x544759, scrim: 0x161328, 0.56); mist = white(0.06)
        case (.rain?, .night): base = look(0x0B111B, 0x1A2330, scrim: 0x04070C, 0.04); mist = white(0.06)
        case (.thunderstorm?, .day): base = look(0x232A38, 0x3E4656, scrim: 0x0A0F1C, 0.84)
        case (.thunderstorm?, .dusk): base = look(0x211C2D, 0x3F3343, scrim: 0x120C1C, 0.76)
        case (.thunderstorm?, .night): base = look(0x08090F, 0x151824, scrim: 0x030408, 0.04)
        case (.snow?, .day): base = look(0x5A7698, 0x8FA9C6, scrim: 0x081B38, 0.9); mist = white(0.06)
        case (.snow?, .dusk): base = look(0x56577A, 0x94808F, scrim: 0x1C1534, 0.84); mist = white(0.06)
        case (.snow?, .night): base = look(0x141D33, 0x2A3754, scrim: 0x050B1C, 0.22); mist = white(0.06)
        case (.fog?, .day): base = look(0x5F6A74, 0x86909A, scrim: 0x10161E, 0.93); mist = white(0.11)
        case (.fog?, .dusk): base = look(0x57525F, 0x7E7277, scrim: 0x1A1624, 0.92); mist = white(0.11)
        case (.fog?, .night): base = look(0x1B1F25, 0x2E333B, scrim: 0x08090D, 0.4); mist = white(0.11)
        case (.wind?, .day): base = look(0x2C67A6, 0x5E95C8, scrim: 0x061C48, 0.91); mist = white(0.07)
        case (.wind?, .dusk): base = look(0x34345E, 0x8F6152, scrim: 0x1F1232, 0.79); mist = white(0.07)
        case (.wind?, .night): base = look(0x0B1329, 0x1E2846, scrim: 0x040A1C, 0.04); mist = white(0.07)
        // Unknown scenes (and `none`, which never gets here) only have a sky.
        case (_, .day): base = look(0x46566A, 0x66778B, scrim: 0x101826, 0.66)
        case (_, .dusk): base = look(0x3E3A50, 0x625868, scrim: 0x17141F, 0.5)
        case (_, .night): base = look(0x11151E, 0x222835, scrim: 0x06080D, 0.04)
        }
        if scene == .thunderstorm {
            cloud = white(0.06)
            flash = light(CardBackgroundRGB(0xEEF0FF), 0.1)
        }
        sky = base.sky
        scrim = base.scrim
        scrimOpacity = base.opacity
        self.glow = glow
        self.cloud = cloud
        self.mist = mist
        self.flash = flash
    }
}

enum CardBackgroundAnimationPolicy {
    /// Moves only while someone can see it: on screen, the app in front,
    /// Reduce Motion and Low Power Mode off (`motion`), and never in a copied
    /// picture. Otherwise the card shows its still gradient.
    static func animates(_ background: CardBackground, motion: BighelpLoaderMotion, isOnScreen: Bool,
                         isSnapshot: Bool) -> Bool {
        background.scene != nil && motion.animates && isOnScreen && !isSnapshot
    }
}
