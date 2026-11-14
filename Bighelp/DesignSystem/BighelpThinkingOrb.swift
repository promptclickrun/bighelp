import SwiftUI

enum BighelpThinkingOrbScenario: Sendable, Equatable {
    case working
    case searching
    case reasoning
    case listening
    case connecting
    case coordinating
    case composing
    case waiting
    case shaping
}

enum BighelpThinkingOrbScale: Sendable {
    case inline
    case standard
}

enum BighelpThinkingOrbSurface: Sendable, Equatable {
    case automatic
    case light
    case dark
}

/// What the loader stands for, and the label VoiceOver reads when no visible text says it.
enum BighelpThinkingOrbState: String, Sendable {
    case working
    case searching
    case solving
    case listening
    case connecting
    case weaving
    case composing
    case breathing
    case shaping

    var label: String {
        switch self {
        case .working: "Working…"
        case .searching: "Searching…"
        case .solving: "Solving…"
        case .listening: "Listening…"
        case .connecting: "Connecting…"
        case .weaving: "Weaving…"
        case .composing: "Composing…"
        case .breathing: "Thinking…"
        case .shaping: "Shaping…"
        }
    }
}

/// The loader's two sizes, in points.
enum BighelpThinkingOrbSize: Int, Sendable {
    case px20 = 20
    case px64 = 64
}

extension BighelpTheme {
    var actionThinkingOrbSurface: BighelpThinkingOrbSurface {
        let normalized = actionForegroundHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else {
            return .automatic
        }
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        let perceivedBrightness = (red * 299 + green * 587 + blue * 114) / 1_000
        return perceivedBrightness >= 128 ? .dark : .light
    }
}

struct BighelpThinkingOrbPresentation: Sendable {
    let state: BighelpThinkingOrbState
    let size: BighelpThinkingOrbSize
    let displaySize: Double?
    let visibleLabel: String?
    /// The lifter's state for the scenario.
    let motion: BighelpLifterMotion

    var hidesOrbFromAccessibility: Bool {
        visibleLabel != nil
    }

    static func resolve(
        scenario: BighelpThinkingOrbScenario,
        scale: BighelpThinkingOrbScale,
        visibleLabel: String? = nil
    ) -> Self {
        return Self(
            state: state(for: scenario),
            size: size(for: scale),
            displaySize: nil,
            visibleLabel: visibleLabel,
            motion: motion(for: scenario)
        )
    }

    /// The lifter's state for what's going on (DESIGN.md › Lifter).
    private static func motion(for scenario: BighelpThinkingOrbScenario) -> BighelpLifterMotion {
        switch scenario {
        case .working, .listening, .connecting, .shaping: .idle
        case .searching: .searching
        case .reasoning: .thinking
        case .coordinating: .coding
        case .composing: .replying
        case .waiting: .sleeping
        }
    }

    static func shouldPause(
        explicitly: Bool,
        scenePhase: ScenePhase
    ) -> Bool {
        explicitly || scenePhase != .active
    }

    private static func state(for scenario: BighelpThinkingOrbScenario) -> BighelpThinkingOrbState {
        switch scenario {
        case .working:
            .working
        case .searching:
            .searching
        case .reasoning:
            .solving
        case .listening:
            .listening
        case .connecting:
            .connecting
        case .coordinating:
            .weaving
        case .composing:
            .composing
        case .waiting:
            .breathing
        case .shaping:
            .shaping
        }
    }

    private static func size(for scale: BighelpThinkingOrbScale) -> BighelpThinkingOrbSize {
        switch scale {
        case .inline:
            .px20
        case .standard:
            .px64
        }
    }
}

/// Bighelp's loader: the lifter, acting out the scenario (DESIGN.md › Lifter).
struct BighelpThinkingOrb: View {
    let scenario: BighelpThinkingOrbScenario
    let scale: BighelpThinkingOrbScale
    let isPaused: Bool
    let displaySize: Double?
    let visibleLabel: String?
    let surface: BighelpThinkingOrbSurface
    let tint: Color?

    @Environment(\.scenePhase) private var scenePhase

    init(
        scenario: BighelpThinkingOrbScenario,
        scale: BighelpThinkingOrbScale = .standard,
        isPaused: Bool = false,
        displaySize: Double? = nil,
        visibleLabel: String? = nil,
        surface: BighelpThinkingOrbSurface = .automatic,
        tint: Color? = nil
    ) {
        self.scenario = scenario
        self.scale = scale
        self.isPaused = isPaused
        self.displaySize = displaySize
        self.visibleLabel = visibleLabel
        self.surface = surface
        self.tint = tint
    }

    @ViewBuilder
    var body: some View {
        let presentation = BighelpThinkingOrbPresentation.resolve(
            scenario: scenario,
            scale: scale,
            visibleLabel: visibleLabel
        )

        if let visibleLabel = presentation.visibleLabel {
            HStack(spacing: BighelpTokens.space8) {
                orb(for: presentation)
                    .accessibilityHidden(presentation.hidesOrbFromAccessibility)
                Text(verbatim: visibleLabel)
            }
        } else {
            orb(for: presentation)
        }
    }

    private func orb(for presentation: BighelpThinkingOrbPresentation) -> some View {
        BighelpLifterView(
            motion: presentation.motion,
            size: CGFloat(displaySize ?? presentation.displaySize ?? Double(presentation.size.rawValue)),
            tint: lifterTint,
            isPaused: BighelpThinkingOrbPresentation.shouldPause(explicitly: isPaused, scenePhase: scenePhase),
            accessibilityLabel: presentation.hidesOrbFromAccessibility ? nil : presentation.state.label
        )
    }

    /// The kit's own colors by default; black or white when it sits on a filled button.
    private var lifterTint: Color? {
        if let tint { return tint }
        switch surface {
        case .automatic: return nil
        case .light: return .black
        case .dark: return .white
        }
    }
}
