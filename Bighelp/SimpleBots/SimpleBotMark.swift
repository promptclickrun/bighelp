import Observation
import SwiftUI
import UIKit

/// A bot's mark in Simple Bot mode: one of thirteen solid shapes in one of
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
        case .circle: "Circle"
        case .cloud: "Cloud"
        case .diamond: "Diamond"
        case .sparkle: "Sparkle"
        case .clover: "Clover"
        case .heart: "Heart"
        case .flower: "Flower"
        case .drop: "Drop"
        case .pill: "Pill"
        case .play: "Triangle"
        case .pentagon: "Pentagon"
        case .star: "Star"
        case .hexagon: "Hexagon"
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

    var title: String { rawValue.capitalized }
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
    var isPrimary = false
    /// Blinks now and then, so the bot looks alive (never with Reduce Motion).
    var blinks = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBlinking = false

    var body: some View {
        ZStack {
            SimpleBotShapeOutline(shape: mark.shape)
                .fill(mark.color.color)
                .overlay {
                    if mark.color == .black, colorScheme == .dark {
                        SimpleBotShapeOutline(shape: mark.shape).stroke(Color.white.opacity(0.28), lineWidth: 1)
                    }
                }
            eyes
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if isPrimary { SimpleBotPrimaryBadge(size: size * 0.3) }
        }
        .task(id: blinks && !reduceMotion) { await blink() }
        .accessibilityHidden(true)
    }

    private var eyes: some View {
        let center = mark.shape.eyeCenter
        return HStack(spacing: size * 0.11) {
            eye
            eye
        }
        .scaleEffect(x: 1, y: isBlinking ? 0.1 : 1)
        .position(x: size * center.x, y: size * center.y)
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

/// The star on the primary bot.
struct SimpleBotPrimaryBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(SimpleBotColor.amber.color))
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: max(2, size * 0.12)))
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
}

/// A bot's face in Simple Bot mode: the mark picked here; else the picture,
/// character or pet it already has; else its starting mark.
struct SimpleBotFace: View {
    let agentID: String
    let name: String
    let imageURL: URL?
    var size: CGFloat
    var isPrimary = false
    /// Marks blink now and then; characters and pets move on their own.
    var blinks = false

    @Environment(\.companionAgentScope) private var scope
    @Environment(\.companionStore) private var companions

    var body: some View {
        Group {
            if let mark = SimpleBotMarkStore.shared.mark(scope: scope, agentID: agentID) {
                SimpleBotMarkView(mark: mark, size: size, isPrimary: isPrimary, blinks: blinks)
            } else if hasOwnPicture {
                AgentLiveAvatar(agentID: agentID, displayName: name, imageURL: imageURL, size: size, showsBadge: false)
                    .overlay(alignment: .bottomTrailing) {
                        if isPrimary { SimpleBotPrimaryBadge(size: size * 0.3) }
                    }
            } else {
                SimpleBotMarkView(mark: .defaultMark(for: agentID), size: size, isPrimary: isPrimary, blinks: blinks)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
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
