import SwiftUI

/// What an agent is doing right now. The avatar itself is the status indicator.
enum AgentLiveState: String, CaseIterable, Sendable {
    case idle, listening, thinking, speaking, happy, nudge

    var label: String {
        switch self {
        case .idle: "Here for you"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Replying"
        case .happy: "All set"
        case .nudge: "Has an update"
        }
    }

    var dotColor: Color {
        switch self {
        case .idle: Color(hex: "8A8A8E")
        case .listening: Color(hex: "007AFF")
        case .thinking: Color(hex: "F28B32")
        case .speaking, .happy: Color(hex: "1E7A4E")
        case .nudge: BighelpBrand.ember
        }
    }
}

/// A small status dot followed by the state label.
struct AgentLiveStateLabel: View {
    let state: AgentLiveState
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.dotColor).frame(width: 8, height: 8)
            Text(state.label)
        }
        .font(font)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Stable visual identity derived from an agent's ID: a color from the agent
/// palette (never Ember coral) and an organic blob or glossy orb body.
struct AgentPersona: Equatable, Sendable {
    enum Body: Sendable { case blob, orb }

    static let palette = ["1E7A4E", "D33F42", "9A6BFF", "F28B32", "1769AA", "B7356F"]

    let colorHex: String
    let body: Body

    init(stableID: String) {
        // djb2: Swift's hashValue is randomized per launch.
        var hash: UInt64 = 5381
        for byte in stableID.utf8 { hash = (hash &<< 5) &+ hash &+ UInt64(byte) }
        colorHex = Self.palette[Int(hash % UInt64(Self.palette.count))]
        body = (hash / 7) % 3 == 0 ? .orb : .blob
    }

    var color: Color { Color(hex: colorHex) }
}

/// The agent avatar from the brand kit: a colored body with two eyes whose
/// shape reflects the live state.
struct AgentPersonaAvatar: View {
    let persona: AgentPersona
    var state: AgentLiveState = .idle
    var size: CGFloat = 44

    private static let eye = Color(hex: "F7F7F5")

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width
            let color = persona.color
            switch persona.body {
            case .blob:
                context.fill(Path(ellipseIn: CGRect(x: s * 0.10, y: s * 0.18, width: s * 0.80, height: s * 0.72)),
                             with: .color(color))
            case .orb:
                context.fill(Path(ellipseIn: CGRect(x: s * 0.10, y: s * 0.10, width: s * 0.80, height: s * 0.80)),
                             with: .color(color))
                context.fill(Path(ellipseIn: CGRect(x: s * 0.26, y: s * 0.24, width: s * 0.24, height: s * 0.24)),
                             with: .color(.white.opacity(0.45)))
            }

            if state == .happy {
                for x in [s * 0.32, s * 0.50] {
                    var arc = Path()
                    arc.move(to: CGPoint(x: x, y: s * 0.52))
                    arc.addQuadCurve(to: CGPoint(x: x + s * 0.18, y: s * 0.52),
                                     control: CGPoint(x: x + s * 0.09, y: s * 0.41))
                    context.stroke(arc, with: .color(Self.eye),
                                   style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                }
            } else {
                let height: CGFloat = switch state {
                case .listening: s * 0.24
                case .thinking: s * 0.13
                default: s * 0.20
                }
                let centerY = s * 0.50 - (state == .thinking ? s * 0.08 : 0)
                for x in [s * 0.40, s * 0.60] {
                    context.fill(Path(ellipseIn: CGRect(x: x - s * 0.075, y: centerY - height / 2,
                                                        width: s * 0.15, height: height)),
                                 with: .color(Self.eye))
                }
            }

            if state == .speaking {
                context.fill(Path(ellipseIn: CGRect(x: s * 0.44, y: s * 0.59, width: s * 0.12, height: s * 0.18)),
                             with: .color(Self.eye))
            }
            if state == .nudge {
                let badge = CGRect(x: s * 0.73, y: s * 0.05, width: s * 0.22, height: s * 0.22)
                context.fill(Path(ellipseIn: badge), with: .color(BighelpBrand.ember))
                context.stroke(Path(ellipseIn: badge), with: .color(.white), lineWidth: s * 0.03)
            }
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.25), value: state)
    }
}

#Preview("Agent personas") {
    VStack(spacing: 16) {
        HStack {
            ForEach(["juniper", "pip", "sage", "miso", "atlas", "wren"], id: \.self) {
                AgentPersonaAvatar(persona: AgentPersona(stableID: $0), size: 52)
            }
        }
        HStack {
            ForEach(AgentLiveState.allCases, id: \.self) { state in
                VStack {
                    AgentPersonaAvatar(persona: AgentPersona(stableID: "juniper"), state: state, size: 52)
                    AgentLiveStateLabel(state: state, font: .caption2)
                }
            }
        }
    }
    .padding()
}
