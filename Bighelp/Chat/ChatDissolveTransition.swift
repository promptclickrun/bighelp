import SwiftUI
import UIKit

/// Disposable viewport imagery; this never owns chat data or submission readiness.
@MainActor
final class ChatDissolveTransition {
    private(set) var overlay: UIView?
    private var source: (id: String, scrollView: @MainActor () -> UIScrollView?)?
    private var destinationID: String?

    func register(conversationID: String, scrollView: @escaping @MainActor () -> UIScrollView?) {
        source = (conversationID, scrollView)
    }

    func present(nextID: String, replacing previousID: String?, reduceMotion: Bool) {
        // The local canvas becoming its durable session is still the same transition.
        if overlay != nil, destinationID == previousID {
            destinationID = nextID
            return
        }
        cancel()
        guard !reduceMotion, nextID != previousID, source?.id == previousID,
              let scrollView = source?.scrollView(), let window = scrollView.window else { return }
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
        guard captured, let pixels = image.cgImage else { return }
        let overlay = UIView(frame: scrollView.convert(viewport, to: window))
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        overlay.clipsToBounds = true
        self.overlay = overlay
        destinationID = nextID
        window.addSubview(overlay)
        let count = min(32, max(1, Int(ceil(viewport.height / 28))))
        for index in 0..<count {
            let y = viewport.height * CGFloat(index) / CGFloat(count)
            let end = viewport.height * CGFloat(index + 1) / CGFloat(count)
            let strip = UIView(frame: CGRect(x: 0, y: y, width: viewport.width, height: end - y))
            strip.layer.contents = pixels
            strip.layer.contentsRect = CGRect(x: 0, y: y / viewport.height, width: 1, height: (end - y) / viewport.height)
            strip.layer.contentsScale = format.scale
            overlay.addSubview(strip)
            UIView.animate(withDuration: 0.28, delay: Double(index) * 0.006,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                strip.alpha = 0
                strip.transform = CGAffineTransform(translationX: 0, y: -5).scaledBy(x: 0.985, y: 0.985)
            } completion: { [weak self, weak overlay] _ in
                guard index == count - 1, let self, self.overlay === overlay else { return }
                self.cancel()
            }
        }
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
