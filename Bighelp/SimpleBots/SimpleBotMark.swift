import Observation
import SwiftUI
import UIKit

/// A bot's mark in Bots mode: one of thirteen solid shapes in one of
/// eleven colors, with two white eyes. It's the bot's picture everywhere: the
/// host keeps a rendering of it, so other screens, devices and Hermes Desktop
/// show the same bot.
struct SimpleBotMark: Codable, Equatable, Hashable, Sendable {
    var shape: SimpleBotShape
    var color: SimpleBotColor

    /// Where a bot without a picked mark starts: a stable choice from its ID.
    static func defaultMark(for agentID: String) -> SimpleBotMark {
        // djb2, like the other avatars made from an ID, so a bot keeps its mark across launches.
        var hash: UInt64 = 5_381
        for byte in agentID.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let shapes = SimpleBotShape.allCases
        let colors = SimpleBotColor.allCases.filter { $0 != .black && $0 != .gray }
        return SimpleBotMark(shape: shapes[Int(hash % UInt64(shapes.count))],
                             color: colors[Int((hash / 13) % UInt64(colors.count))])
    }
}

enum SimpleBotShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case circle, cloud, diamond, sparkle, clover
    case heart, flower, drop, pill, play
    case pentagon, star, hexagon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: String(localized: "Circle")
        case .cloud: String(localized: "Cloud")
        case .diamond: String(localized: "Diamond")
        case .sparkle: String(localized: "Sparkle")
        case .clover: String(localized: "Clover")
        case .heart: String(localized: "Heart")
        case .flower: String(localized: "Flower")
        case .drop: String(localized: "Drop")
        case .pill: String(localized: "Pill")
        case .play: String(localized: "Triangle")
        case .pentagon: String(localized: "Pentagon")
        case .star: String(localized: "Star")
        case .hexagon: String(localized: "Hexagon")
        }
    }

    /// The middle of the face, as a fraction of the mark: lopsided shapes sit off center.
    fileprivate var eyeCenter: CGPoint {
        switch self {
        case .play: CGPoint(x: 0.44, y: 0.47)
        case .drop: CGPoint(x: 0.53, y: 0.52)
        case .heart: CGPoint(x: 0.5, y: 0.46)
        default: CGPoint(x: 0.5, y: 0.47)
        }
    }

    /// The outline in a square of `rect`.
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        switch self {
        case .circle:
            return Path(ellipseIn: square.insetBy(dx: side * 0.06, dy: side * 0.06))
        case .cloud:
            return Self.radial(square, squash: 0.9) { 0.41 + 0.05 * cos(5 * $0 + 0.6) + 0.015 * cos(3 * $0) }
        case .diamond:
            return Self.roundedPolygon(square, sides: 4, radius: 0.47, corner: 0.13, rotation: .degrees(20))
        case .sparkle:
            return Self.radial(square) { 0.32 + 0.18 * cos(4 * $0) }
        case .clover:
            return Self.radial(square) { 0.385 + 0.085 * cos(4 * $0) }
        case .heart:
            return Self.heart(square).applying(Self.rotation(.degrees(-24), around: square))
        case .flower:
            return Self.radial(square) { 0.41 + 0.055 * cos(8 * $0) }
        case .drop:
            let tip = -0.75 * Double.pi
            return Self.radial(square, center: CGPoint(x: 0.53, y: 0.53)) { angle in
                0.33 * (1 + 0.5 * pow(max(0, cos(angle - tip)), 5))
            }
        case .pill:
            let pill = CGRect(x: square.minX + side * 0.08, y: square.midY - side * 0.22,
                              width: side * 0.84, height: side * 0.44)
            return Path(roundedRect: pill, cornerRadius: side * 0.22)
                .applying(Self.rotation(.degrees(-20), around: square))
        case .play:
            return Self.roundedPolygon(square, sides: 3, radius: 0.5, corner: 0.15, rotation: .zero,
                                       center: CGPoint(x: 0.44, y: 0.5))
        case .pentagon:
            return Self.roundedPolygon(square, sides: 5, radius: 0.47, corner: 0.12, rotation: .degrees(-80))
        case .star:
            return Self.radial(square) { 0.385 + 0.1 * cos(6 * $0) }
        case .hexagon:
            return Self.roundedPolygon(square, sides: 6, radius: 0.48, corner: 0.12, rotation: .degrees(15))
        }
    }

    /// A closed curve whose distance from the center follows `radius(angle)` (fractions of the side).
    private static func radial(_ square: CGRect, center: CGPoint = CGPoint(x: 0.5, y: 0.5), squash: CGFloat = 1,
                               samples: Int = 180, radius: (Double) -> Double) -> Path {
        var path = Path()
        let side = square.width
        let origin = CGPoint(x: square.minX + side * center.x, y: square.minY + side * center.y)
        for index in 0..<samples {
            let angle = Double(index) / Double(samples) * 2 * .pi
            let distance = CGFloat(radius(angle)) * side
            let point = CGPoint(x: origin.x + CGFloat(cos(angle)) * distance,
                                y: origin.y + CGFloat(sin(angle)) * distance * squash)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func roundedPolygon(_ square: CGRect, sides: Int, radius: CGFloat, corner: CGFloat,
                                       rotation: Angle, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Path {
        let side = square.width
        let origin = CGPoint(x: square.minX + side * center.x, y: square.minY + side * center.y)
        let vertices = (0..<sides).map { index -> CGPoint in
            let angle = rotation.radians + Double(index) / Double(sides) * 2 * .pi
            return CGPoint(x: origin.x + CGFloat(cos(angle)) * radius * side,
                           y: origin.y + CGFloat(sin(angle)) * radius * side)
        }
        var path = Path()
        let last = vertices[sides - 1], first = vertices[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in 0..<sides {
            path.addArc(tangent1End: vertices[index], tangent2End: vertices[(index + 1) % sides],
                        radius: corner * side)
        }
        path.closeSubpath()
        return path
    }

    private static func heart(_ square: CGRect) -> Path {
        let side = square.width
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: square.minX + side * x, y: square.minY + side * y)
        }
        var path = Path()
        path.move(to: point(0.5, 0.86))
        path.addCurve(to: point(0.07, 0.4), control1: point(0.28, 0.72), control2: point(0.07, 0.6))
        path.addCurve(to: point(0.5, 0.24), control1: point(0.07, 0.12), control2: point(0.4, 0.1))
        path.addCurve(to: point(0.93, 0.4), control1: point(0.6, 0.1), control2: point(0.93, 0.12))
        path.addCurve(to: point(0.5, 0.86), control1: point(0.93, 0.6), control2: point(0.72, 0.72))
        path.closeSubpath()
        return path
    }

    private static func rotation(_ angle: Angle, around square: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: square.midX, y: square.midY)
            .rotated(by: angle.radians)
            .translatedBy(x: -square.midX, y: -square.midY)
    }
}

enum SimpleBotColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, brown, red, orange, amber, green, teal, blue, purple, pink, gray

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .black: "141414"
        case .brown: "8B5E3C"
        case .red: "E5484D"
        case .orange: "EE7330"
        case .amber: "F2A23A"
        case .green: "59C77A"
        case .teal: "4DB9A6"
        case .blue: "3D83F5"
        case .purple: "8B5CF6"
        case .pink: "E8489A"
        case .gray: "787878"
        }
    }

    var color: Color { Color(hex: hex) }

    var title: String {
        switch self {
        case .black: String(localized: "Black")
        case .brown: String(localized: "Brown")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .amber: String(localized: "Amber")
        case .green: String(localized: "Green")
        case .teal: String(localized: "Teal")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .gray: String(localized: "Gray")
        }
    }
}

private struct SimpleBotShapeOutline: Shape {
    let shape: SimpleBotShape
    func path(in rect: CGRect) -> Path { shape.path(in: rect) }
}

/// The mark itself: the shape in its color and two white eyes. A black mark
/// keeps an outline after dark so it doesn't vanish into a black page.
struct SimpleBotMarkView: View {
    let mark: SimpleBotMark
    var size: CGFloat
    /// Blinks now and then, so the bot looks alive (never with Reduce Motion).
    var blinks = false
    /// Thinking looks up with narrowed eyes; needing you opens them wide. The still pose, which
    /// shows when the mark can't move (Reduce Motion, Low Power Mode).
    var state: AgentLiveState = .idle
    /// A character mood (`BuddyPose`) the mark acts out while it works, as the kit's characters do.
    var mood: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpLoaderMotionReader private var motion
    @State private var isBlinking = false

    var body: some View {
        Group {
            if let mood, motion.animates {
                TimelineView(.animation) { timeline in
                    posed(BuddyPose.make(mood: mood, time: timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 3600)))
                }
            } else {
                ZStack {
                    outline
                    eyes
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: blinks && !reduceMotion && mood == nil) { await blink() }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: state)
        .accessibilityHidden(true)
    }

    private var outline: some View {
        SimpleBotShapeOutline(shape: mark.shape)
            .fill(mark.color.color)
            .overlay {
                if mark.color == .black, colorScheme == .dark {
                    SimpleBotShapeOutline(shape: mark.shape).stroke(Color.white.opacity(0.28), lineWidth: 1)
                }
            }
    }

    /// One frame of a mood: the mark hops, leans and squashes on its base, and its eyes blink,
    /// look, squint, close or smile with the pose.
    private func posed(_ pose: BuddyPose) -> some View {
        let unit = size / 100
        let center = mark.shape.eyeCenter
        let eyes: (height: CGFloat, look: CGPoint) = switch pose.eyes {
        case let .open(openness, look): (max(0.1, openness), look)
        case let .wide(look): (1.15, look)
        case let .squint(look): (0.45, look)
        case .sad: (0.7, CGPoint(x: 0, y: 0.5))
        case .closed: (0.1, .zero)
        case .happy: (0.3, CGPoint(x: 0, y: -0.3))
        }
        return ZStack {
            outline
            HStack(spacing: size * 0.11) { eye; eye }
                .scaleEffect(x: 1, y: eyes.height)
                .position(x: size * center.x + eyes.look.x * size * 0.04,
                          y: size * center.y + eyes.look.y * size * 0.04)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: pose.squash, y: 1 / pose.squash, anchor: .bottom)
        .rotationEffect(.degrees(pose.rotation))
        .offset(x: pose.offset.width * unit, y: pose.offset.height * unit)
    }

    private var eyes: some View {
        let center = mark.shape.eyeCenter
        let pose: (height: CGFloat, lift: CGFloat) = switch state {
        case .thinking: (0.7, 0.05)
        case .nudge: (1.15, 0)
        default: (1, 0)
        }
        return HStack(spacing: size * 0.11) {
            eye
            eye
        }
        .scaleEffect(x: 1, y: (isBlinking ? 0.1 : 1) * pose.height)
        .position(x: size * center.x, y: size * (center.y - pose.lift))
    }

    /// A quick blink every few seconds, at its own pace, so marks side by side don't blink together.
    private func blink() async {
        guard blinks, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 2_400...5_600)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.07)) { isBlinking = true }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.1)) { isBlinking = false }
        }
    }

    private var eye: some View {
        Capsule(style: .continuous)
            .fill(.white)
            .frame(width: size * 0.085, height: size * 0.165)
            .rotationEffect(.degrees(-24))
    }

    /// The mark at `pixels` square, transparent around the shape: the bot's picture on the host.
    @MainActor
    static func png(_ mark: SimpleBotMark, pixels: CGFloat = 512) -> Data? {
        let renderer = ImageRenderer(content: SimpleBotMarkView(mark: mark, size: pixels)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }
}

/// What a bot is doing, on its face, when the face can't act it out: a still badge, so it reads with
/// Reduce Motion and on a photo.
/// Working shows the kind of work (a globe while it browses); needing you, a raised hand; work in the
/// background, a stack.
struct SimpleBotActivityBadge: View {
    let activity: BotChatActivity
    let size: CGFloat
    @BighelpThemeReader private var theme

    var body: some View {
        Image(systemName: activity.badgeSymbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(activity == .waiting ? Color.white : theme.actionForeground)
            .frame(width: size, height: size)
            .background(Circle().fill(activity == .waiting ? BighelpBrand.ember : theme.action))
            .overlay(Circle().stroke(theme.canvas, lineWidth: max(2, size * 0.12)))
            .accessibilityHidden(true)
    }
}

/// Marks people picked, kept on this device per computer and bot. The host
/// keeps each one's picture; this lets the app draw it crisply at any size.
@MainActor
@Observable
final class SimpleBotMarkStore {
    static let shared = SimpleBotMarkStore()
    static let defaultsKey = "bighelp.simple-bots.marks"
    private static let maximumMarks = 512

    private(set) var marks: [String: SimpleBotMark]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        marks = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: SimpleBotMark].self, from: $0) } ?? [:]
    }

    func mark(scope: String, agentID: String) -> SimpleBotMark? {
        marks[CompanionStore.agentKey(agentScope: scope, agentID: agentID)]
    }

    func set(_ mark: SimpleBotMark?, scope: String, agentID: String) {
        let key = CompanionStore.agentKey(agentScope: scope, agentID: agentID)
        marks[key] = mark
        while marks.count > Self.maximumMarks, let first = marks.keys.sorted().first { marks[first] = nil }
        if let data = try? JSONEncoder().encode(marks) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Every mark at once, from app state on the computers (`BotsAppState`).
    func replaceAll(_ next: [String: SimpleBotMark]) {
        guard marks != next else { return }
        marks = next
        while marks.count > Self.maximumMarks, let first = marks.keys.sorted().first { marks[first] = nil }
        if let data = try? JSONEncoder().encode(marks) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// A bot's face in Bots mode, in `AgentFace`'s order: its character, pet, Hermes face or mark,
/// else its picture, else its starting mark. While its Bot Chat works, the face acts the work out
/// (a mark or character plays the mood for it, a Hermes face the designer's state, a pet its move);
/// a photo, or any face that can't move, shows a still badge instead. Needing you always shows
/// its raised hand.
struct SimpleBotFace: View {
    let agentID: String
    let name: String
    let imageURL: URL?
    var size: CGFloat
    /// Marks blink now and then; characters and pets move on their own.
    var blinks = false
    /// What its Bot Chat is doing; nil or idle shows nothing.
    var activity: BotChatActivity? = nil

    @Environment(\.companionAgentScope) private var scope
    @Environment(\.companionStore) private var companions
    @BighelpLoaderMotionReader private var motion

    private var busy: BotChatActivity? { activity?.isBusy == true ? activity : nil }

    var body: some View {
        let face = AgentFace.resolve(agentID: agentID, scope: scope, companions: companions)
        Group {
            switch face {
            case .mark(let mark):
                markView(mark)
            case .picture where !hasOwnPicture:
                markView(.defaultMark(for: agentID))
            default:
                // Characters, pets and Hermes faces play the move for the work; a photo stays still.
                AgentLiveAvatar(agentID: agentID, displayName: name, imageURL: imageURL,
                                activity: busy?.activityKind ?? .idle, size: size, showsBadge: false,
                                movesPhoto: false)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let busy, Self.showsBadge(for: busy, faceMoves: (face.moves || !hasOwnPicture) && motion.animates) {
                SimpleBotActivityBadge(activity: busy, size: min(28, max(18, size * 0.28)))
            }
        }
        // The row or tile it's in says the state, once, as its value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }

    /// Needing you always shows its hand, and work in the background its stack: the face stays calm
    /// for it. The kind of work on a turn shows as a badge only on a face that can't act it out: a
    /// photo, or any face with Reduce Motion or Low Power Mode.
    static func showsBadge(for activity: BotChatActivity, faceMoves: Bool) -> Bool {
        switch activity {
        case .idle: false
        case .waiting, .background: true
        case .working: !faceMoves
        }
    }

    private func markView(_ mark: SimpleBotMark) -> some View {
        SimpleBotMarkView(mark: mark, size: size, blinks: blinks,
                          state: busy?.liveState ?? .idle, mood: busy?.activityKind.moodID)
    }

    private var hasOwnPicture: Bool {
        if let imageURL, FileManager.default.fileExists(atPath: imageURL.bighelpFileSystemPath) { return true }
        guard !scope.isEmpty else { return false }
        return companions?.override(for: CompanionStore.agentKey(agentScope: scope, agentID: agentID)) != nil
    }
}

/// Saves a bot's mark everywhere: its picture on the host (what other screens,
/// devices and Hermes Desktop show) and here. A character or pet drawn over
/// the picture goes, so the mark is what chats show too.
@MainActor
enum SimpleBotMarkSaving {
    enum Failure: Error { case render }

    static func save(_ mark: SimpleBotMark, for profile: AgentProfile, agents: AgentDirectoryStore,
                     companions: CompanionStore?, scope: String) async throws {
        SimpleBotMarkStore.shared.set(mark, scope: scope, agentID: profile.id)
        guard let picture = SimpleBotMarkView.png(mark) else { throw Failure.render }
        let processor = AvatarImageProcessor()
        let prepared = try processor.prepare(data: picture)
        var draft = AgentDraft(name: profile.name, role: profile.role, summary: profile.summary,
                               instructions: profile.instructions, avatarFileName: profile.avatarFileName,
                               avatar: profile.avatar, isDefault: profile.isDefault)
        if let directory = agents.avatarDirectory {
            draft.avatarFileName = try processor.store(prepared, in: directory)
        }
        draft.avatar = try AgentAvatar(preparedAvatar: prepared)
        draft.look = .photo
        _ = try await agents.update(id: profile.id, draft: draft)
        guard !scope.isEmpty else { return }
        let key = CompanionStore.agentKey(agentScope: scope, agentID: profile.id)
        companions?.setOverride(nil, for: key)
        PetAvatarStore.shared.remove(key)
    }
}
