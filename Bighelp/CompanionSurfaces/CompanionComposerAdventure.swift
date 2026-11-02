import CoreGraphics
import Foundation
import SwiftUI

/// A semantic motion authored by the composer path. Semantic chat reactions are
/// carried separately and always take precedence over these ambient phases.
enum CompanionComposerMotionPhase: String, CaseIterable, Equatable, Sendable {
    case rest
    case traverse
    case climb
    case jump
    case bounce
    case dance
}

struct CompanionComposerPathSample: Equatable, Sendable {
    var position: CGPoint
    var phase: CompanionComposerMotionPhase
    var phaseProgress: Double
}

struct CompanionComposerWaypoint: Equatable, Sendable {
    var position: CGPoint
    var phase: CompanionComposerMotionPhase
    var duration: TimeInterval
}

/// Resolved SwiftUI anchors in the coordinate system of the composer overlay.
/// Keeping this a value type makes path sampling deterministic and testable.
struct CompanionComposerPathGeometry: Equatable, Sendable {
    var canvasBounds: CGRect
    var inputFrame: CGRect
    var contextRingFrame: CGRect?
    var railViewport: CGRect?
    var railLedges: [CGRect]
    var itemSide: CGFloat

    init(
        canvasBounds: CGRect,
        inputFrame: CGRect,
        contextRingFrame: CGRect?,
        railViewport: CGRect?,
        railLedges: [CGRect],
        itemSide: CGFloat
    ) {
        self.canvasBounds = canvasBounds.standardized
        self.inputFrame = inputFrame.standardized
        self.contextRingFrame = contextRingFrame?.standardized
        self.railViewport = railViewport?.standardized
        self.railLedges = railLedges.map(\.standardized)
        self.itemSide = itemSide
    }

    static func surfaceItemSide(sizeScale: Double, canvasWidth: CGFloat) -> CGFloat {
        let finiteScale = sizeScale.isFinite ? sizeScale : 1
        let scale = min(max(finiteScale, 0.6), 1.5)
        let finiteWidth = canvasWidth.isFinite ? max(0, canvasWidth) : 0
        let widthCap = min(116, max(44, finiteWidth * 0.28))
        return min(72 * CGFloat(scale), widthCap)
    }
}

/// Pure, deterministic composer path construction and sampling.
///
/// The path always traverses both ends of the measured input top. When visible
/// rail buttons exist, their measured top edges become authored climb/jump
/// ledges; otherwise the pet dances and bounces on the input top alone.
enum CompanionComposerPathSampler {
    static let restGap: CGFloat = 8

    static func restPosition(in geometry: CompanionComposerPathGeometry) -> CGPoint {
        let resolved = sanitized(geometry)
        let half = resolved.itemSide / 2
        let input = resolved.inputFrame
        let ring = valid(resolved.contextRingFrame)

        let proposedX: CGFloat
        let baselineY: CGFloat
        if let ring {
            proposedX = ring.minX - restGap - half
            baselineY = ring.maxY
        } else {
            proposedX = input.maxX - half
            baselineY = input.minY
        }

        return CGPoint(
            x: clamp(proposedX, min: resolved.canvasBounds.minX + half,
                     max: resolved.canvasBounds.maxX - half),
            y: baselineY - half
        )
    }

    static func authoredWaypoints(
        in geometry: CompanionComposerPathGeometry
    ) -> [CompanionComposerWaypoint] {
        let resolved = sanitized(geometry)
        let half = resolved.itemSide / 2
        let input = resolved.inputFrame
        let rest = restPosition(in: resolved)
        let inputBaseline = input.minY - half
        let left = CGPoint(
            x: clamp(input.minX + half, min: resolved.canvasBounds.minX + half,
                     max: resolved.canvasBounds.maxX - half),
            y: inputBaseline
        )
        let right = CGPoint(
            x: clamp(input.maxX - half, min: resolved.canvasBounds.minX + half,
                     max: resolved.canvasBounds.maxX - half),
            y: inputBaseline
        )

        var result = [
            CompanionComposerWaypoint(position: rest, phase: .rest, duration: 1.6),
            CompanionComposerWaypoint(position: right, phase: .traverse, duration: 0.4),
            CompanionComposerWaypoint(position: left, phase: .traverse, duration: 2.2),
            CompanionComposerWaypoint(position: left, phase: .bounce, duration: 0.9)
        ]

        let ledges = visibleLedgePositions(in: resolved)
        if let first = ledges.first {
            result.append(CompanionComposerWaypoint(
                position: first,
                phase: .climb,
                duration: 0.8
            ))
            for ledge in ledges.dropFirst() {
                result.append(CompanionComposerWaypoint(
                    position: ledge,
                    phase: .jump,
                    duration: 0.75
                ))
            }
            result.append(CompanionComposerWaypoint(
                position: ledges.last ?? first,
                phase: .dance,
                duration: 1.2
            ))
            result.append(CompanionComposerWaypoint(
                position: right,
                phase: .jump,
                duration: 1
            ))
        } else {
            let middle = CGPoint(x: (left.x + right.x) / 2, y: inputBaseline)
            result.append(CompanionComposerWaypoint(
                position: middle,
                phase: .jump,
                duration: 0.8
            ))
            result.append(CompanionComposerWaypoint(
                position: middle,
                phase: .dance,
                duration: 1.2
            ))
            result.append(CompanionComposerWaypoint(
                position: right,
                phase: .traverse,
                duration: 1.1
            ))
        }

        result.append(CompanionComposerWaypoint(
            position: rest,
            phase: .traverse,
            duration: 0.4
        ))
        return result
    }

    static func sample(
        elapsed: TimeInterval,
        in geometry: CompanionComposerPathGeometry,
        isAdventurous: Bool = true
    ) -> CompanionComposerPathSample {
        let resolved = sanitized(geometry)
        let rest = restPosition(in: resolved)
        guard isAdventurous else {
            return CompanionComposerPathSample(position: rest, phase: .rest, phaseProgress: 0)
        }

        let waypoints = authoredWaypoints(in: resolved)
        let cycleDuration = waypoints.reduce(0) { $0 + max(0.001, $1.duration) }
        guard cycleDuration.isFinite, cycleDuration > 0 else {
            return CompanionComposerPathSample(position: rest, phase: .rest, phaseProgress: 0)
        }

        let finiteElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        var cursor = finiteElapsed.truncatingRemainder(dividingBy: cycleDuration)
        var start = rest

        for waypoint in waypoints {
            let duration = max(0.001, waypoint.duration)
            if cursor <= duration {
                let linearProgress = min(max(cursor / duration, 0), 1)
                let progress = smoothstep(linearProgress)
                var position = interpolate(from: start, to: waypoint.position, progress: progress)
                position = authoredOffset(
                    position,
                    phase: waypoint.phase,
                    progress: linearProgress,
                    itemSide: resolved.itemSide,
                    travel: hypot(waypoint.position.x - start.x, waypoint.position.y - start.y)
                )
                position.x = clamp(
                    position.x,
                    min: resolved.canvasBounds.minX + resolved.itemSide / 2,
                    max: resolved.canvasBounds.maxX - resolved.itemSide / 2
                )
                return CompanionComposerPathSample(
                    position: position,
                    phase: waypoint.phase,
                    phaseProgress: linearProgress
                )
            }
            cursor -= duration
            start = waypoint.position
        }

        return CompanionComposerPathSample(position: rest, phase: .rest, phaseProgress: 0)
    }

    private static func visibleLedgePositions(
        in geometry: CompanionComposerPathGeometry
    ) -> [CGPoint] {
        let half = geometry.itemSide / 2
        let visibilityBounds = geometry.railViewport
            .flatMap { valid($0) }
            .map { $0.intersection(geometry.canvasBounds) }
            ?? geometry.canvasBounds

        return geometry.railLedges
            .filter { frame in
                valid(frame) != nil && !visibilityBounds.isNull
                    && frame.intersects(visibilityBounds)
            }
            .sorted {
                if abs($0.minY - $1.minY) > 0.5 { return $0.minY > $1.minY }
                return $0.midX < $1.midX
            }
            .map { frame in
                let visibleFrame = frame.intersection(visibilityBounds)
                return CGPoint(
                    x: clamp(visibleFrame.midX,
                             min: geometry.canvasBounds.minX + half,
                             max: geometry.canvasBounds.maxX - half),
                    y: frame.minY - half
                )
            }
    }

    private static func authoredOffset(
        _ position: CGPoint,
        phase: CompanionComposerMotionPhase,
        progress: Double,
        itemSide: CGFloat,
        travel: CGFloat
    ) -> CGPoint {
        var position = position
        switch phase {
        case .rest, .traverse, .climb:
            break
        case .jump:
            let arc = min(itemSide * 0.48, max(itemSide * 0.22, travel * 0.22))
            position.y -= CGFloat(sin(.pi * progress)) * arc
        case .bounce:
            position.y -= CGFloat(abs(sin(.pi * 2 * progress))) * itemSide * 0.24
        case .dance:
            position.x += CGFloat(sin(.pi * 4 * progress)) * itemSide * 0.1
            position.y -= CGFloat(abs(sin(.pi * 4 * progress))) * itemSide * 0.06
        }
        return position
    }

    private static func sanitized(
        _ geometry: CompanionComposerPathGeometry
    ) -> CompanionComposerPathGeometry {
        var canvas = valid(geometry.canvasBounds) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let side = min(
            max(24, geometry.itemSide.isFinite ? geometry.itemSide : 72),
            max(24, canvas.width)
        )
        if canvas.width < side {
            canvas.size.width = side
        }
        let fallbackInput = CGRect(
            x: canvas.minX,
            y: canvas.maxY,
            width: canvas.width,
            height: 1
        )
        return CompanionComposerPathGeometry(
            canvasBounds: canvas,
            inputFrame: valid(geometry.inputFrame) ?? fallbackInput,
            contextRingFrame: valid(geometry.contextRingFrame),
            railViewport: valid(geometry.railViewport),
            railLedges: geometry.railLedges.compactMap { valid($0) },
            itemSide: side
        )
    }

    private static func valid(_ rect: CGRect?) -> CGRect? {
        guard let rect,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else { return nil }
        return rect.standardized
    }

    private static func interpolate(
        from start: CGPoint,
        to end: CGPoint,
        progress: Double
    ) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * CGFloat(progress),
            y: start.y + (end.y - start.y) * CGFloat(progress)
        )
    }

    private static func smoothstep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return (lower + upper) / 2 }
        return Swift.min(Swift.max(value, lower), upper)
    }
}

enum CompanionComposerAnchor: Hashable {
    case input
    case contextRing
    case railViewport
    case railLedge(String)
}

struct CompanionComposerAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [CompanionComposerAnchor: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [CompanionComposerAnchor: Anchor<CGRect>],
        nextValue: () -> [CompanionComposerAnchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func companionComposerAnchor(_ kind: CompanionComposerAnchor) -> some View {
        anchorPreference(key: CompanionComposerAnchorPreferenceKey.self, value: .bounds) {
            [kind: $0]
        }
    }
}

struct CompanionComposerAdventureLayer: View {
    let pet: AgentPetIdentity
    let reaction: CompanionReaction
    let sizeScale: Double
    let isAdventurous: Bool
    let anchors: [CompanionComposerAnchor: Anchor<CGRect>]
    let resetToken: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var motionEpoch = Date()

    var body: some View {
        GeometryReader { proxy in
            let itemSide = CompanionComposerPathGeometry.surfaceItemSide(
                sizeScale: sizeScale,
                canvasWidth: proxy.size.width
            )
            let geometry = CompanionComposerPathGeometry(
                canvasBounds: CGRect(origin: .zero, size: proxy.size),
                inputFrame: anchors[.input].map { proxy[$0] } ?? .zero,
                contextRingFrame: anchors[.contextRing].map { proxy[$0] },
                railViewport: anchors[.railViewport].map { proxy[$0] },
                railLedges: resolvedRailLedges(in: proxy),
                itemSide: itemSide
            )
            let canMove = isAdventurous
                && reaction != .question && reaction != .failed
                && isVisible
                && scenePhase == .active
                && !reduceMotion
                && !CompanionAcceptanceFixture.reducedMotion

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !canMove)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(motionEpoch))
                let sample = CompanionComposerPathSampler.sample(
                    elapsed: elapsed,
                    in: geometry,
                    isAdventurous: canMove
                )
                companion(sample: sample, side: itemSide)
            }
            .onChange(of: geometry) { _, _ in resetMotion() }
            .onChange(of: canMove) { _, _ in resetMotion() }
        }
        .allowsHitTesting(false)
        .onAppear {
            isVisible = true
            resetMotion()
        }
        .onDisappear { isVisible = false }
        .onChange(of: resetToken) { _, _ in resetMotion() }
        .accessibilityElement(children: .contain)
    }

    private func companion(
        sample: CompanionComposerPathSample,
        side: CGFloat
    ) -> some View {
        let ambientMotion = ambientMotion(for: sample.phase)
        let danceRotation = sample.phase == .dance
            ? sin(.pi * 4 * sample.phaseProgress) * 8
            : 0
        let bounceScale: CGFloat = sample.phase == .bounce
            ? CGFloat(1 - abs(sin(.pi * 2 * sample.phaseProgress)) * 0.08)
            : 1

        return AgentPet(
            identity: pet,
            reaction: reaction,
            isAnimating: isVisible && scenePhase == .active,
            ambientMotion: ambientMotion
        )
        .frame(width: side, height: side)
        .scaleEffect(x: 2 - bounceScale, y: bounceScale)
        .rotationEffect(.degrees(danceRotation))
        .position(sample.position)
        .accessibilityIdentifier("companion-chat")
    }

    private func ambientMotion(
        for phase: CompanionComposerMotionPhase
    ) -> CompanionAmbientMotion {
        guard reaction == .idle else { return .none }
        switch phase {
        case .bounce: return .bounce
        case .dance: return .dance
        default: return .none
        }
    }

    private func resolvedRailLedges(in proxy: GeometryProxy) -> [CGRect] {
        anchors.compactMap { key, anchor -> (String, CGRect)? in
            guard case let .railLedge(id) = key else { return nil }
            return (id, proxy[anchor])
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private func resetMotion() {
        motionEpoch = Date()
    }
}
