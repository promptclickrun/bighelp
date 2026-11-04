import Observation
import SwiftUI

/// What an agent's face is, from what this device and its computer know, in the order every
/// surface draws them: a kit character, a petdex pet, a Hermes face or shape or a Bot Studio
/// avatar (both saved in Hermes' profile), a Bots mode mark, then its picture. One order, so the chat, Bots mode and its pet companion show the same face.
enum AgentFace: Equatable {
    case character(CompanionAppearance)
    case pet(key: String)
    case hermes(AgentAvatarLook, name: String)
    case mark(SimpleBotMark)
    case picture

    @MainActor
    static func resolve(agentID: String, scope: String, companions: CompanionStore?) -> AgentFace {
        guard !scope.isEmpty else { return .picture }
        let key = CompanionStore.agentKey(agentScope: scope, agentID: agentID)
        if let look = companions?.override(for: key) { return .character(look) }
        if PetAvatarStore.shared.slug(for: key) != nil { return .pet(key: key) }
        if let entry = AgentLookStore.shared.looks[key] { return .hermes(entry.look, name: entry.name) }
        if let mark = SimpleBotMarkStore.shared.mark(scope: scope, agentID: agentID) { return .mark(mark) }
        return .picture
    }

    /// Plays moves of its own; a picture stays a picture.
    var moves: Bool { self != .picture }
}

/// The Hermes looks (blob faces and shapes) of the computer in use's agents, from Hermes'
/// profiles (`ui_meta["hermes-bots"]`). The host also keeps each one as a picture; with the look,
/// the app draws the face itself, so it can move as the kit's characters do.
@MainActor
@Observable
final class AgentLookStore {
    static let shared = AgentLookStore()

    struct Entry: Equatable {
        let look: AgentAvatarLook
        /// The profile name a face follows unless its seed is locked.
        let name: String
    }

    /// By `CompanionStore.agentKey`.
    private(set) var looks: [String: Entry] = [:]
    /// When each computer's looks were last read live. A saved all-hosts copy from before that is older
    /// than what the app shows, and must not bring an old face back when another gateway is opened.
    @ObservationIgnored private var readLive: [String: Date] = [:]

    func publish(fleet: [UUID: FleetSnapshot], excluding liveScope: String) {
        for (hostID, snapshot) in fleet {
            let scope = CompanionSurfaceScope.computer(hostID.uuidString)
            guard scope != liveScope else { continue }
            if let readLive = readLive[scope], snapshot.refreshedAt < readLive { continue }
            replace(scope: scope, profiles: snapshot.agents.map {
                AgentProfile(id: $0.profileID, name: $0.name, role: $0.role, summary: "", instructions: "",
                             isDefault: $0.isDefault, look: $0.look)
            })
        }
    }

    /// The computer's agents, replacing what it had: a face or shape draws live, a photo or no look
    /// leaves the picture.
    func publish(scope: String, profiles: [AgentProfile]) {
        guard !scope.isEmpty else { return }
        readLive[scope] = .now
        replace(scope: scope, profiles: profiles)
    }

    private func replace(scope: String, profiles: [AgentProfile]) {
        let prefix = "\(scope.utf8.count):\(scope)"
        var next = looks.filter { !$0.key.hasPrefix(prefix) }
        for profile in profiles.prefix(512) {
            guard let look = profile.look, look.drawsLive else { continue }
            next[CompanionStore.agentKey(agentScope: scope, agentID: profile.id)] = Entry(look: look, name: profile.name)
        }
        if next != looks { looks = next }
    }
}

/// Keeps `AgentLookStore` current with the agents of the computer in use. On the app's root, which
/// a pushed chat never covers.
struct AgentLookPublishing: ViewModifier {
    let scope: String
    let profiles: [AgentProfile]
    var fleet: [UUID: FleetSnapshot] = [:]

    func body(content: Content) -> some View {
        content
            .onChange(of: fleet, initial: true) { _, snapshots in
                AgentLookStore.shared.publish(fleet: snapshots, excluding: scope)
            }
            .onChange(of: profiles, initial: true) { _, profiles in
                AgentLookStore.shared.publish(scope: scope, profiles: profiles)
            }
            .onChange(of: scope) { _, scope in
                AgentLookStore.shared.publish(fleet: fleet, excluding: scope)
                AgentLookStore.shared.publish(scope: scope, profiles: profiles)
            }
    }
}

// MARK: - What each face plays

extension AgentActivityKind {
    /// What a Hermes face plays for this work: one of the states its designer offers.
    var hermesPlayState: AvatarPlayState {
        switch self {
        case .idle: .idle
        case .thinking, .memory: .think
        case .replying, .messaging: .speak
        case .coding, .files, .tools: .work
        case .web, .seeing, .scheduling: .curious
        case .images: .celebrate
        case .publishing, .done: .love
        case .delegating: .bounce
        case .waiting: .listen
        case .failed: .oops
        }
    }
}

extension AvatarPlayState {
    /// The designer's state nearest a character mood, for a Hermes face acting out a pet's reaction.
    init(mood: String?) {
        switch mood {
        case "listening": self = .listen
        case "thinking": self = .think
        case "bounce", "dance", "spin": self = .bounce
        case "nod": self = .speak
        case "scan", "squint": self = .work
        case "curious", "lookAround", "peek", "alert": self = .curious
        case "happy": self = .love
        case "excited": self = .celebrate
        case "sleepy": self = .sleep
        case "sad": self = .oops
        default: self = .idle
        }
    }
}

// MARK: - Hermes looks that move

/// A Hermes look acting out a state, as the avatar designer plays it: a blob face or a shape.
/// Reduce Motion, Low Power Mode and the background hold the state's key pose.
struct HermesLookPlayer: View {
    let look: AgentAvatarLook
    let name: String
    let state: AvatarPlayState

    var body: some View {
        if let studio = look.studio {
            BotLookPlayer(look: studio, state: state)
        } else {
            hermes
        }
    }

    @ViewBuilder
    private var hermes: some View {
        switch look.style {
        case .face:
            let blob = HermesBlobShape(look.shape) ?? HermesBlobShape()
            HermesBlobFacePlayer(seed: look.faceSeed ?? blob.seed(name: name), kind: blob.kind, edits: blob.edits,
                                 color: look.color, state: state)
        case .shape:
            HermesShapeFacePlayer(shape: look.shape ?? HermesShapeFace.defaultShape(for: name),
                                  color: HermesShapeFace.color(look.color, name: name), state: state)
        case .photo:
            Color.clear
        }
    }
}

/// A geometric face acting out a `BuddyPose`, like `HermesBlobFacePlayer`.
struct HermesShapeFacePlayer: View {
    let shape: String
    let color: String
    let state: AvatarPlayState
    @BighelpLoaderMotionReader private var motion

    var body: some View {
        let face = HermesShapeFacePaths(shape: shape, color: color)
        Group {
            if state.animates, motion.animates {
                TimelineView(.animation) { timeline in
                    canvas(face, time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                }
            } else {
                canvas(face, time: state.keyTime)
            }
        }
        .accessibilityHidden(true)
    }

    private func canvas(_ face: HermesShapeFacePaths, time: Double) -> some View {
        let pose = state.mood.map { BuddyPose.make(mood: $0, time: time) } ?? BuddyPose()
        return Canvas { context, size in face.draw(in: context, size: size, pose: pose) }
    }
}

/// One geometric face in Hermes's 40×44 box, ready to pose: the same body, eyes and catchlights
/// `HermesShapeFaceView` draws at rest.
struct HermesShapeFacePaths {
    let body: Path
    let eyes: [Path]
    let fill: Color
    let eye: Color
    let sparkle: Color
    let colorHex: String
    let eyeHex: String

    init(shape: String, color: String) {
        let isDark = HermesShapeFace.isDark(color)
        fill = HermesFaceColor.color(color)
        eye = isDark ? Color(red: 232 / 255, green: 220 / 255, blue: 195 / 255).opacity(0.95) : Color.black.opacity(0.85)
        sparkle = isDark ? Color.black.opacity(0.6) : Color.white.opacity(0.85)
        colorHex = HermesBlobFacePaths.hex(color)
        eyeHex = isDark ? "#E8DCC3" : "#16181B"
        var outline = Path()
        let ring = HermesShapeFace.ring(shape)
        if let first = ring.first {
            outline.move(to: CGPoint(x: first.0, y: first.1))
            for point in ring.dropFirst() { outline.addLine(to: CGPoint(x: point.0, y: point.1)) }
            outline.closeSubpath()
        }
        body = outline
        let eyeY = HermesShapeFace.eyeLine(shape)
        eyes = [15.4, 24.6].map { Path(ellipseIn: CGRect(x: $0 - 2.2, y: eyeY - 2.3, width: 4.4, height: 4.6)) }
    }

    func draw(in context: GraphicsContext, size: CGSize, pose: BuddyPose) {
        let side = min(size.width, size.height)
        // The pose moves in a 100-unit box; the shape's is 44 tall.
        let unit = 0.44
        let scale = side / 44 * 0.82
        var face = context
        face.translateBy(x: size.width / 2, y: size.height / 2)
        face.scaleBy(x: scale, y: scale)
        face.translateBy(x: pose.offset.width * unit, y: pose.offset.height * unit)
        face.rotate(by: .degrees(pose.rotation))
        let feet = 20.0
        face.translateBy(x: 0, y: feet)
        face.scaleBy(x: pose.squash, y: 1 / pose.squash)
        face.translateBy(x: -20, y: -22 - feet)
        face.fill(body, with: .color(fill))
        for path in eyes {
            HermesBlobFacePaths.drawEye(path, pose: pose, color: eye, in: face)
            if case .open(let openness, let look) = pose.eyes, openness > 0.6 {
                let box = path.boundingRect
                face.fill(Path(ellipseIn: CGRect(x: box.midX - 1.25 + look.x * 1.3, y: box.midY - 1.35 + look.y * 1.3,
                                                 width: 1.3, height: 1.3)), with: .color(sparkle))
            }
        }

        guard pose.effect != nil else { return }
        var overlay = context
        overlay.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        overlay.scaleBy(x: side / 200, y: side / 200)
        BuddyPainter(ctx: overlay, u: 2, palette: BuddyPalette(bodyHex: colorHex, eyeHex: eyeHex), look: BuddyLook(), pose: pose)
            .effect(72, 24)
    }
}
