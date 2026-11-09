import SwiftUI

/// The looks the Thinking control can wear. Each draws on a `Canvas` every frame while it is on
/// screen and the agent is asked to think, and stands still at the bottom level and under Reduce
/// Motion. New cases keep their raw value, which may be stored on the device.
enum BighelpThinkingLook: String, CaseIterable, Identifiable, Sendable {
    case noodle, trainOfThought, clockwork, meadow, inkBloom, wideAwake

    static let defaultLook: BighelpThinkingLook = .noodle

    var id: Self { self }

    /// A proper name, like an app icon's, so it reads the same in every language.
    var name: String {
        switch self {
        case .noodle: "Noodle"
        case .trainOfThought: "Train of Thought"
        case .clockwork: "Clockwork"
        case .meadow: "Meadow"
        case .inkBloom: "Ink Bloom"
        case .wideAwake: "Wide Awake"
        }
    }

    /// One short sentence for the settings page.
    var summary: String {
        switch self {
        case .noodle: String(localized: "One stroke that loops tighter and turns to your color's opposite.")
        case .trainOfThought: String(localized: "Little words drift toward a cursor, faster as it thinks harder.")
        case .clockwork: String(localized: "Gears that spin faster, then overheat and rattle.")
        case .meadow: String(localized: "Grass grows to the thumb, and the wind picks up.")
        case .inkBloom: String(localized: "Ink curls through water, thicker and faster.")
        case .wideAwake: String(localized: "A little face that wakes up and gets more determined.")
        }
    }

    func drawTrack(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        switch self {
        case .noodle: Self.drawNoodle(&context, frame, store, paint)
        case .trainOfThought: Self.drawTrain(&context, frame, store, paint)
        case .clockwork: Self.drawClockwork(&context, frame, store, paint)
        case .meadow: Self.drawMeadow(&context, frame, store, paint)
        case .inkBloom: Self.drawInk(&context, frame, store, paint)
        case .wideAwake: Self.drawAwake(&context, frame, store, paint)
        }
    }

    /// Some thumbs keep state of their own (Wide Awake's gaze and steam), so they get the store too.
    func drawThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore, _ paint: ThinkingPaint) {
        switch self {
        case .noodle: Self.drawNoodleThumb(&context, frame, store, paint)
        case .trainOfThought: Self.drawTrainThumb(&context, frame, store, paint)
        case .clockwork: Self.drawClockworkThumb(&context, frame, store, paint)
        case .meadow: Self.drawMeadowThumb(&context, frame, store, paint)
        case .inkBloom: Self.drawInkThumb(&context, frame, store, paint)
        case .wideAwake: Self.drawAwakeThumb(&context, frame, store, paint)
        }
    }
}

/// What a look paints with, worked out once per view update: day or night, and the person's color.
struct ThinkingPaint: Equatable, Sendable {
    let isDark: Bool
    let accent: ThinkingAccent
}
