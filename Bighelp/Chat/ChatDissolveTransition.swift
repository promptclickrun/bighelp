import Accelerate
import SwiftUI
import UIKit

/// Disposable viewport imagery; this never owns chat data or submission readiness.
///
/// New Chat sweeps the outgoing chat away with the Thinking look the person picked: the look's
/// own running track rises from the bottom of the chat to the top, and each line softens and
/// fades as the track passes it, while the new chat is already live underneath.
@MainActor
final class ChatDissolveTransition {
    /// Bounds the work whatever the viewport shows.
    nonisolated static let maximumBands = 40
    /// How long one line takes to go, and how long the look takes to rise to the top line.
    nonisolated static let lineDuration: CFTimeInterval = 0.44
    nonisolated static let waveDuration: CFTimeInterval = 0.7

    private(set) var overlay: UIView?
    /// The look's track on its way up, on top of the lines.
    private(set) var band: UIView?
    private var bandHost: UIHostingController<AnyView>?
    private var source: (id: String, backdrop: UIColor?, look: (@MainActor () -> AnyView)?,
                         scrollView: @MainActor () -> UIScrollView?)?
    private var destinationID: String?

    /// `backdrop` is the page behind the chat, when it's a plain color: each line covers the new
    /// chat until it has gone, so the new chat shows line by line instead of through the old one.
    /// `look` draws the picked Thinking look's track; without one the lines go by themselves.
    func register(conversationID: String, backdrop: UIColor? = nil, look: (@MainActor () -> AnyView)? = nil,
                  scrollView: @escaping @MainActor () -> UIScrollView?) {
        source = (conversationID, backdrop, look, scrollView)
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
              let art = ChatDissolveArt(snapshot: pixels, size: viewport.size, bandLimit: Self.maximumBands),
              !art.bands.isEmpty else { return }
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
        for band in art.bands {
            let strip = UIView(frame: CGRect(x: 0, y: band.lowerBound, width: viewport.width,
                                             height: band.upperBound - band.lowerBound))
            strip.backgroundColor = source.backdrop
            let slice = CGRect(x: 0, y: band.lowerBound / viewport.height, width: 1,
                               height: (band.upperBound - band.lowerBound) / viewport.height)
            // Bottom line first: a line goes as the look, rising from the bottom, reaches it.
            let middle = (band.lowerBound + band.upperBound) / 2
            let begin = start + Self.waveDuration * Double(1 - middle / viewport.height)
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
        if let look = source.look { addBand(look(), to: overlay, size: viewport.size, start: start) }
        CATransaction.commit()
    }

    /// The picked look's track, rising through the chat at the pace the lines go.
    private func addBand(_ look: AnyView, to overlay: UIView, size: CGSize, start: CFTimeInterval) {
        let host = UIHostingController(rootView: look)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        let height = ThinkingSliderMetrics.height, inset = BighelpTokens.space16
        host.view.frame = CGRect(x: inset, y: size.height - height, width: max(0, size.width - inset * 2), height: height)
        overlay.addSubview(host.view)
        bandHost = host
        band = host.view

        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = size.height - height / 2
        rise.toValue = height / 2
        rise.beginTime = start
        rise.duration = Self.waveDuration
        rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rise.fillMode = .both
        rise.isRemovedOnCompletion = false
        host.view.layer.add(rise, forKey: "rise")

        // In as it starts, out with the last line.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let total = Self.waveDuration + Self.lineDuration
        fade.keyTimes = [0, NSNumber(value: 0.12 / total), NSNumber(value: Self.waveDuration / total), 1]
        fade.values = [0, 1, 1, 0]
        fade.beginTime = start
        fade.duration = total
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        host.view.layer.add(fade, forKey: "fade")
    }

    func reconcile(conversationID: String?) {
        guard overlay != nil, conversationID != destinationID else { return }
        cancel()
    }

    func cancel() {
        let previous = overlay
        overlay = nil
        band = nil
        bandHost = nil
        destinationID = nil
        previous?.subviews.forEach { $0.layer.removeAllAnimations() }
        previous?.removeFromSuperview()
    }

    /// What a line shows on its way out: itself, softened, then blurred, in its own colors. Each
    /// cross-fades into the next while the whole line fades.
    enum Stage: CaseIterable {
        case sharp, softened, blurred

        func animation(begin: CFTimeInterval) -> CAAnimation {
            let (times, values): ([NSNumber], [NSNumber]) = switch self {
            case .sharp: ([0, 0.35, 1], [1, 0, 0])
            case .softened: ([0, 0.35, 0.7, 1], [0, 1, 0, 0])
            case .blurred: ([0, 0.4, 0.75, 1], [0, 0, 1, 1])
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
    let softened: CGImage
    let blurred: CGImage
    /// Lines in points, top to bottom, together covering the viewport.
    let bands: [Range<CGFloat>]

    /// `snapshot` is the viewport drawn over nothing, so empty space is clear.
    init?(snapshot: CGImage, size: CGSize, bandLimit: Int) {
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
        guard let smallCopy = small.makeImage(),
              let softened = Self.blur(smallCopy, radius: 2),
              let blurred = Self.blur(smallCopy, radius: 6) else { return nil }
        sharp = snapshot
        self.softened = softened
        self.blurred = blurred
    }

    func image(_ stage: ChatDissolveTransition.Stage) -> CGImage {
        switch stage {
        case .sharp: sharp
        case .softened: softened
        case .blurred: blurred
        }
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

/// The picked Thinking look's own track for the dissolve, thinking harder as it rises. It runs in a
/// view of its own on the window, so what the track reads from its surroundings is handed to it.
struct ChatDissolveLookBand: View {
    let look: BighelpThinkingLook
    let accent: Color
    @State private var level = 0.2

    var body: some View {
        ThinkingSliderTrack(look: look, level: level, followsFinger: false, accent: accent)
            // A view outside any scene reads as in the background, which holds the track still.
            .environment(\.scenePhase, .active)
            .onAppear { level = 1 }
    }
}
