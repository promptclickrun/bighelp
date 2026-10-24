#if os(iOS)
import SwiftUI
import UIKit

/// Agents' faces for the car's screen: the same face the app draws (a saved character, a pet,
/// the picture or the orb), as an image, with a ring for what the conversation is doing.
@MainActor
enum CarPlayFaces {
    /// The voice screen's pictures may be 150 points at most.
    static let voiceSize: CGFloat = 150

    static func face(for agent: CarPlayAgent, imageURL: URL?, size: CGFloat) -> UIImage {
        let view = AgentLiveAvatar(agentID: agent.id, displayName: agent.name, imageURL: imageURL,
                                   size: size, showsBadge: false, movesPhoto: false)
            .frame(width: size, height: size)
            .environment(\.companionStore, BighelpCarPlayServices.companion)
            .environment(\.companionAgentScope, BighelpCarPlayServices.companionScope?() ?? "")
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage ?? CarPlayVoiceStates.symbol("person.crop.circle.fill", size: size * 0.8)
    }

    enum Ring {
        case connecting, listening, working, speaking, still
    }

    /// The face inside a ring that moves: it breathes while listening, runs round while the
    /// agent works, beats while it speaks, and stays faint while connecting.
    static func voice(_ face: UIImage, ring: Ring) -> UIImage {
        let frames: [UIImage] = switch ring {
        case .still: [framed(face, ring: nil)]
        case .connecting: [0.15, 0.3, 0.15].map { framed(face, ring: .init(alpha: $0, width: 4, arc: 1)) }
        case .listening: [0.35, 0.6, 0.9, 0.6].map { framed(face, ring: .init(alpha: $0, width: 6, arc: 1)) }
        case .working: [0.0, 0.25, 0.5, 0.75].map { framed(face, ring: .init(alpha: 0.9, width: 6, arc: 0.3, start: $0)) }
        case .speaking: [5.0, 9, 12, 9].map { framed(face, ring: .init(alpha: 0.9, width: $0, arc: 1)) }
        }
        guard frames.count > 1 else { return frames[0] }
        return UIImage.animatedImage(with: frames, duration: 0.3 * Double(frames.count)) ?? frames[0]
    }

    private struct RingStyle {
        var alpha: Double
        var width: CGFloat
        /// The share of the circle drawn, from `start` (0–1, clockwise from the top).
        var arc: CGFloat
        var start: CGFloat = 0
    }

    private static func framed(_ face: UIImage, ring: RingStyle?) -> UIImage {
        let side = voiceSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let inset: CGFloat = 16
            face.draw(in: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2))
            guard let ring else { return }
            let radius = side / 2 - ring.width / 2 - 1
            let start = -CGFloat.pi / 2 + ring.start * 2 * .pi
            let path = UIBezierPath(arcCenter: CGPoint(x: side / 2, y: side / 2), radius: radius,
                                    startAngle: start, endAngle: start + ring.arc * 2 * .pi, clockwise: true)
            path.lineWidth = ring.width
            path.lineCapStyle = .round
            CarPlayVoiceStates.tint.withAlphaComponent(ring.alpha).setStroke()
            path.stroke()
        }
    }
}
#endif
