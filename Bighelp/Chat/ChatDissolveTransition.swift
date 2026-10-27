import Accelerate
import SwiftUI
import UIKit

/// Disposable viewport imagery; this never owns chat data or submission readiness.
///
/// New Chat dissolves the outgoing chat line by line, from the bottom up: each line takes
/// the tint, blurs and fades where it is, while the new chat is already live underneath.
@MainActor
final class ChatDissolveTransition {
    /// Bounds the work whatever the viewport shows.
    nonisolated static let maximumBands = 40
    /// How long one line takes, and how long the wave takes to reach the top line.
    nonisolated static let lineDuration: CFTimeInterval = 0.44
    nonisolated static let waveDuration: CFTimeInterval = 0.4

    private(set) var overlay: UIView?
    private var source: (id: String, tint: UIColor, backdrop: UIColor?, scrollView: @MainActor () -> UIScrollView?)?
    private var destinationID: String?

    /// `backdrop` is the page behind the chat, when it's a plain color: each line covers the new
    /// chat until it has gone, so the new chat shows line by line instead of through the old one.
    func register(conversationID: String, tint: UIColor = .systemRed, backdrop: UIColor? = nil,
                  scrollView: @escaping @MainActor () -> UIScrollView?) {
        source = (conversationID, tint, backdrop, scrollView)
    }

    func present(nextID: String, replacing previousID: String?, reduceMotion: Bool) {
        // The local canvas becoming its durable session is still the same transition.
        if overlay != nil, destinationID == previousID {
            destinationID = nextID
            return
        }
        cancel()
        guard !reduceMotion, nextID != previousID, let source, source.id == previousID,
              let scrollView = source.scrollView(), let window = scrollView.window else { return }
        let viewport = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        guard viewport.width > 0, viewport.height > 0, !scrollView.isHidden else { return }

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, scrollView.traitCollection.displayScale)
        var captured = false
        let image = UIGraphicsImageRenderer(size: viewport.size, format: format).image { _ in
            captured = scrollView.drawHierarchy(in: CGRect(x: scrollView.bounds.minX - viewport.minX,
                                               y: scrollView.bounds.minY - viewport.minY,
                                               width: scrollView.bounds.width, height: scrollView.bounds.height),
                                     afterScreenUpdates: false)
        }
        guard captured, let pixels = image.cgImage,
              let art = ChatDissolveArt(snapshot: pixels, size: viewport.size, tint: source.tint,
                                        bandLimit: Self.maximumBands), !art.bands.isEmpty else { return }
        let overlay = UIView(frame: scrollView.convert(viewport, to: window))
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        overlay.clipsToBounds = true
        self.overlay = overlay
        destinationID = nextID
        window.addSubview(overlay)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            MainActor.assumeIsolated {
                guard let self, let overlay, self.overlay === overlay else { return }
                self.cancel()
            }
        }
        let start = CACurrentMediaTime()
        let last = art.bands.count - 1
        let spread = min(Self.waveDuration, 0.03 * Double(last))
        for (index, band) in art.bands.enumerated() {
            let strip = UIView(frame: CGRect(x: 0, y: band.lowerBound, width: viewport.width,
                                             height: band.upperBound - band.lowerBound))
            strip.backgroundColor = source.backdrop
            let slice = CGRect(x: 0, y: band.lowerBound / viewport.height, width: 1,
                               height: (band.upperBound - band.lowerBound) / viewport.height)
            // Bottom line first.
            let begin = start + (last == 0 ? 0 : spread * Double(last - index) / Double(last))
            for stage in Stage.allCases {
                let layer = CALayer()
                layer.frame = strip.bounds
                layer.contents = art.image(stage)
                layer.contentsRect = slice
                layer.add(stage.animation(begin: begin), forKey: "dissolve")
                strip.layer.addSublayer(layer)
            }
            strip.layer.add(Stage.fade(begin: begin), forKey: "dissolve")
            overlay.addSubview(strip)
        }
        CATransaction.commit()
    }

    func reconcile(conversationID: String?) {
        guard overlay != nil, conversationID != destinationID else { return }
        cancel()
    }

    func cancel() {
        let previous = overlay
        overlay = nil
        destinationID = nil
        previous?.subviews.forEach { $0.layer.removeAllAnimations() }
        previous?.removeFromSuperview()
    }

    /// What a line shows on its way out: itself, tinted, softened, then blurred. Each
    /// cross-fades into the next while the whole line fades.
    enum Stage: CaseIterable {
        case sharp, tinted, softened, blurred

        func animation(begin: CFTimeInterval) -> CAAnimation {
            let (times, values): ([NSNumber], [NSNumber]) = switch self {
            case .sharp: ([0, 0.3, 1], [1, 0, 0])
            case .tinted: ([0, 0.3, 0.55, 1], [0, 1, 0, 0])
            case .softened: ([0, 0.25, 0.5, 0.75, 1], [0, 0, 1, 0, 0])
            case .blurred: ([0, 0.45, 0.75, 1], [0, 0, 1, 1])
            }
            return Self.keyframes(times, values, begin: begin)
        }

        static func fade(begin: CFTimeInterval) -> CAAnimation {
            keyframes([0, 0.45, 1], [1, 1, 0], begin: begin)
        }

        private static func keyframes(_ times: [NSNumber], _ values: [NSNumber],
                                      begin: CFTimeInterval) -> CAAnimation {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.keyTimes = times
            animation.values = values
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                                              count: values.count - 1)
            animation.beginTime = begin
            animation.duration = ChatDissolveTransition.lineDuration
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            return animation
        }
    }
}

/// The outgoing viewport's pictures for the dissolve, and where its lines are.
struct ChatDissolveArt {
    let sharp: CGImage
    let tinted: CGImage
    let softened: CGImage
    let blurred: CGImage
    /// Lines in points, top to bottom, together covering the viewport.
    let bands: [Range<CGFloat>]

    /// `snapshot` is the viewport drawn over nothing, so empty space is clear.
    init?(snapshot: CGImage, size: CGSize, tint: UIColor, bandLimit: Int) {
        // One pixel a point is plenty to find the lines and to blur.
        let width = max(1, Int(size.width.rounded(.up))), height = max(1, Int(size.height.rounded(.up)))
        guard let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = small.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        small.interpolationQuality = .medium
        small.draw(snapshot, in: whole)
        // The bitmap's first row is the picture's top.
        let rows = (0..<height).map { y in
            (0..<width).contains { x in bytes[(y * width + x) * 4 + 3] > 24 }
        }
        let scale = size.height / CGFloat(height)
        bands = ChatDissolveBands.lines(rows: rows, limit: bandLimit).map {
            CGFloat($0.lowerBound) * scale..<CGFloat($0.upperBound) * scale
        }
        Self.tint(small, rect: whole, color: tint)
        let full = UIGraphicsImageRendererFormat()
        full.scale = 1
        let tintedFull = UIGraphicsImageRenderer(size: CGSize(width: snapshot.width, height: snapshot.height),
                                                 format: full).image { context in
            let rect = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
            UIImage(cgImage: snapshot).draw(in: rect)
            Self.tint(context.cgContext, rect: rect, color: tint)
        }
        guard let smallTinted = small.makeImage(), let tinted = tintedFull.cgImage,
              let softened = Self.blur(smallTinted, radius: 2),
              let blurred = Self.blur(smallTinted, radius: 6) else { return nil }
        sharp = snapshot
        self.tinted = tinted
        self.softened = softened
        self.blurred = blurred
    }

    func image(_ stage: ChatDissolveTransition.Stage) -> CGImage {
        switch stage {
        case .sharp: sharp
        case .tinted: tinted
        case .softened: softened
        case .blurred: blurred
        }
    }

    /// Colors what's drawn, keeping some of its own color so text in a bubble stays readable.
    private static func tint(_ context: CGContext, rect: CGRect, color: UIColor) {
        context.setBlendMode(.sourceAtop)
        context.setFillColor(color.withAlphaComponent(0.8).cgColor)
        context.fill(rect)
    }

    private static func blur(_ image: CGImage, radius: Int) -> CGImage? {
        guard let format = vImage_CGImageFormat(cgImage: image),
              var source = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { source.free() }
        guard var destination = try? vImage_Buffer(width: Int(source.width), height: Int(source.height),
                                                   bitsPerPixel: format.bitsPerPixel) else { return nil }
        defer { destination.free() }
        let kernel = UInt32(radius * 2 + 1)
        var clear: [UInt8] = [0, 0, 0, 0]
        // Two tent passes come close to a Gaussian.
        guard vImageTentConvolve_ARGB8888(&source, &destination, nil, 0, 0, kernel, kernel, &clear,
                                          vImage_Flags(kvImageBackgroundColorFill)) == kvImageNoError,
              vImageTentConvolve_ARGB8888(&destination, &source, nil, 0, 0, kernel, kernel, &clear,
                                          vImage_Flags(kvImageBackgroundColorFill)) == kvImageNoError
        else { return nil }
        return try? source.createCGImage(format: format)
    }
}

/// Where the lines are in a picture of the chat.
enum ChatDissolveBands {
    /// `rows` is true where a row has something drawn. Returns the lines top to bottom,
    /// each grown halfway into the space around it so together they cover every row.
    /// A tall run (a bubble, a picture, a code block) is cut into line-sized pieces,
    /// and neighbours are joined until there are at most `limit`.
    static func lines(rows: [Bool], limit: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (y, drawn) in rows.enumerated() {
            if drawn, start == nil { start = y }
            if !drawn, let top = start {
                // A one-row gap is antialiasing inside a line, not between two.
                if let previous = runs.last, top - previous.upperBound <= 1 {
                    runs[runs.count - 1] = previous.lowerBound..<y
                } else {
                    runs.append(top..<y)
                }
                start = nil
            }
        }
        if let top = start { runs.append(top..<rows.count) }
        guard !runs.isEmpty, limit > 0 else { return [] }

        let ordinary = runs.map(\.count).filter { (8...40).contains($0) }.sorted()
        let line = ordinary.isEmpty ? 20 : ordinary[ordinary.count / 2]
        var pieces: [Range<Int>] = []
        for run in runs {
            let count = run.count * 4 > line * 7 ? max(1, Int((Double(run.count) / Double(line)).rounded())) : 1
            for index in 0..<count {
                pieces.append(run.lowerBound + run.count * index / count
                              ..< run.lowerBound + run.count * (index + 1) / count)
            }
        }
        while pieces.count > limit {
            pieces = stride(from: 0, to: pieces.count, by: 2).map { index in
                index + 1 < pieces.count ? pieces[index].lowerBound..<pieces[index + 1].upperBound : pieces[index]
            }
        }
        return pieces.indices.map { index in
            let top = index == 0 ? 0 : (pieces[index - 1].upperBound + pieces[index].lowerBound) / 2
            let bottom = index == pieces.count - 1
                ? rows.count : (pieces[index].upperBound + pieces[index + 1].lowerBound) / 2
            return top..<bottom
        }
    }
}

private struct ChatDissolveTransitionKey: EnvironmentKey {
    static let defaultValue: ChatDissolveTransition? = nil
}

extension EnvironmentValues {
    var chatDissolveTransition: ChatDissolveTransition? {
        get { self[ChatDissolveTransitionKey.self] }
        set { self[ChatDissolveTransitionKey.self] = newValue }
    }
}

struct ChatDissolveLifetime: ViewModifier {
    let transition: ChatDissolveTransition
    let appState: AppState
    let signIn: WorkspaceSignIn?
    let scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.path) { _, path in
                if case .chat(let id)? = path.last { transition.reconcile(conversationID: id) }
                else { transition.cancel() }
            }
            .onChange(of: signIn) { _, _ in transition.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { transition.cancel() } }
            .onDisappear { transition.cancel() }
    }
}
