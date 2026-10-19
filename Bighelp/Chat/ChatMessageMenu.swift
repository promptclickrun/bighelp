import SwiftUI
import UIKit

/// What holding a message offers.
struct ChatMessageMenuActions {
    var copyActionLabel: String
    var onCopy: () -> Void
    var onSelect: () -> Void
    var onFork: (() -> Void)?
    var onReply: (() -> Void)?
    var reactions: ChatMessageReactionActions?
}

struct ChatMessageReactionActions {
    /// The person's reaction, highlighted in the bar.
    let selectedEmoji: String?
    /// Sends a reaction; nil takes the person's away.
    let onSelect: (String?) -> Void
    /// Opens the full emoji choice.
    let onMore: () -> Void
}

/// The message's bubble shape, for the lifted copy of it.
struct ChatBubbleMenuShape: Equatable {
    var alignsTrailing: Bool
    var hasTail: Bool

    func path(in rect: CGRect) -> UIBezierPath {
        let radius = BighelpV3MessagePresentation.bubbleRadius
        let tail = hasTail ? BighelpV3MessagePresentation.tailRadius : radius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: alignsTrailing ? radius : tail,
            bottomTrailingRadius: alignsTrailing ? tail : radius,
            topTrailingRadius: radius,
            style: .continuous
        )
        return UIBezierPath(cgPath: shape.path(in: rect).cgPath)
    }
}

/// Where a message's bubble is: the views around its text register here, so
/// a hold anywhere on it lifts the whole bubble.
@MainActor
final class ChatBubbleMenuAnchor {
    private var views: [WeakView] = []

    private struct WeakView { weak var view: UIView? }

    func register(_ view: UIView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(WeakView(view: view))
    }

    /// The bubble's frame in `window`'s coordinates.
    func frame(in window: UIWindow) -> CGRect? {
        let frames = views.compactMap { entry -> CGRect? in
            guard let view = entry.view, view.window === window, !view.isHidden else { return nil }
            return view.convert(view.bounds, to: window)
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}

enum ChatMessageMenuStyle {
    /// iPhone and iPad float the reactions over the lifted message. The Mac,
    /// Vision Pro and VoiceOver get them as the menu's first row, where a
    /// pointer, a pinch or a swipe reaches them.
    @MainActor
    static var floatsReactions: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        !UIAccessibility.isVoiceOverRunning
        #else
        false
        #endif
    }

    static var liftsBubble: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}

/// The message menu behind a hold or a right-click: the bubble lifts, the
/// reaction bar floats over it and the actions show below.
@MainActor
final class ChatMessageMenuDriver: NSObject, UIContextMenuInteractionDelegate {
    var actions: ChatMessageMenuActions?
    var anchor: ChatBubbleMenuAnchor?
    var shape = ChatBubbleMenuShape(alignsTrailing: false, hasTail: false)
    var theme: BighelpTheme?

    private var preview: UITargetedPreview?
    private var bubbleInPreview: CGRect = .zero
    private weak var activeInteraction: UIContextMenuInteraction?
    private var afterDismissal: (() -> Void)?

    func update(actions: ChatMessageMenuActions, anchor: ChatBubbleMenuAnchor?,
                shape: ChatBubbleMenuShape, theme: BighelpTheme) {
        self.actions = actions
        self.anchor = anchor
        self.shape = shape
        self.theme = theme
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard actions != nil else { return nil }
        let floats = ChatMessageMenuStyle.floatsReactions
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(floatsReactions: floats)
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        preview = nil
        guard ChatMessageMenuStyle.liftsBubble, let source = interaction.view, let window = source.window else {
            return nil
        }
        let bubble = anchor?.frame(in: window) ?? source.convert(source.bounds, to: window)
        guard bubble.width > 1, bubble.height > 1,
              let snapshot = window.resizableSnapshotView(
                from: bubble, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        let reserve = actions?.reactions != nil && ChatMessageMenuStyle.floatsReactions
            ? ChatReactionBarMetrics.reservedHeight : 0
        let container = UIView(frame: CGRect(x: 0, y: 0, width: bubble.width, height: bubble.height + reserve))
        container.backgroundColor = .clear
        bubbleInPreview = CGRect(x: 0, y: reserve, width: bubble.width, height: bubble.height)
        snapshot.frame = bubbleInPreview
        let mask = CAShapeLayer()
        mask.path = shape.path(in: snapshot.bounds).cgPath
        snapshot.layer.mask = mask
        container.addSubview(snapshot)
        // The system places and fits the whole visible area, so the empty room
        // over the bubble stays on screen; only the bubble casts a shadow.
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(rect: container.bounds)
        parameters.shadowPath = shape.path(in: bubbleInPreview)
        let target = UIPreviewTarget(container: window, center: CGPoint(x: bubble.midX, y: bubble.midY - reserve / 2))
        let preview = UITargetedPreview(view: container, parameters: parameters, target: target)
        self.preview = preview
        return preview
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        preview
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        activeInteraction = interaction
        guard ChatMessageMenuStyle.floatsReactions, let reactions = actions?.reactions, let theme,
              let source = interaction.view, let scene = source.window?.windowScene else { return }
        let overlay = ChatReactionBarOverlay.shared
        overlay.show(
            projection: ChatReactionBarProjection(selectedEmoji: reactions.selectedEmoji),
            theme: theme,
            style: source.traitCollection.userInterfaceStyle,
            in: scene,
            owner: self,
            alignsTrailing: shape.alignsTrailing,
            bubbleFrame: { [weak self] in self?.bubbleInScene() },
            onSelect: { [weak self] emoji in self?.react(emoji) },
            onMore: { [weak self] in self?.moreReactions() }
        )
        // The system may move the message to fit its menu; follow it there.
        animator?.addCompletion { [weak self] in
            guard let self else { return }
            overlay.follow(owner: self)
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        ChatReactionBarOverlay.shared.hide(owner: self)
        activeInteraction = nil
        // A sheet opened while the menu still closes never shows.
        let ending = preview
        if let animator {
            animator.addCompletion { [weak self] in self?.finishDismissal(of: ending) }
        } else {
            Task { @MainActor [weak self] in self?.finishDismissal(of: ending) }
        }
    }

    private func finishDismissal(of ending: UITargetedPreview?) {
        // The lifted copy is the app's own view; take it away once it has landed.
        ending?.view.removeFromSuperview()
        if preview === ending { preview = nil }
        let after = afterDismissal
        afterDismissal = nil
        after?()
    }

    /// The bubble in the scene's coordinates: where the lifted copy is, or the
    /// message itself when nothing lifts (a pointer's right-click).
    private func bubbleInScene() -> CGRect? {
        if let container = preview?.view, let window = container.window, let scene = window.windowScene {
            return container.convert(bubbleInPreview, to: scene.coordinateSpace)
        }
        guard let source = activeInteraction?.view, let window = source.window,
              let scene = window.windowScene else { return nil }
        let bubble = anchor?.frame(in: window) ?? source.convert(source.bounds, to: window)
        return window.convert(bubble, to: scene.coordinateSpace)
    }

    private func react(_ emoji: String?) {
        BighelpHaptics.tap()
        actions?.reactions?.onSelect(emoji)
        activeInteraction?.dismissMenu()
    }

    private func moreReactions() {
        afterDismissal = actions?.reactions?.onMore
        activeInteraction?.dismissMenu()
    }

    private func menu(floatsReactions: Bool) -> UIMenu? {
        guard let actions else { return nil }
        var elements: [UIMenuElement] = []
        if !floatsReactions, let reactions = actions.reactions {
            elements.append(Self.reactionPalette(reactions))
        }
        if let onReply = actions.onReply {
            elements.append(UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
                onReply()
            })
        }
        let onCopy = actions.onCopy
        elements.append(UIAction(title: actions.copyActionLabel, image: UIImage(systemName: "doc.on.doc")) { _ in
            onCopy()
        })
        // On the Mac, text is selected with the pointer; no separate sheet.
        if !BighelpPlatform.isMac {
            let onSelect = actions.onSelect
            elements.append(UIAction(title: "Select text", image: UIImage(systemName: "selection.pin.in.out")) { _ in
                onSelect()
            })
        }
        if let onFork = actions.onFork {
            elements.append(UIAction(title: "Fork from here", image: UIImage(systemName: "arrow.triangle.branch")) { _ in
                onFork()
            })
        }
        return UIMenu(children: elements)
    }

    /// The reactions as the menu's first row of icons.
    static func reactionPalette(_ reactions: ChatMessageReactionActions) -> UIMenu {
        let projection = ChatReactionBarProjection(selectedEmoji: reactions.selectedEmoji)
        let onSelect = reactions.onSelect
        var elements: [UIMenuElement] = projection.choices.map { choice in
            UIAction(title: choice.accessibilityLabel, image: ChatReactionEmojiImage.image(choice.emoji),
                     state: choice.isSelected ? .on : .off) { _ in
                onSelect(projection.selection(afterTapping: choice.emoji))
            }
        }
        let onMore = reactions.onMore
        elements.append(UIAction(title: "More reactions", image: UIImage(systemName: "plus")) { _ in onMore() })
        return UIMenu(title: "", options: [.displayInline, .displayAsPalette], children: elements)
    }
}

/// The reaction bar's own window, above the lifted message and its menu.
/// Only the bar takes touches; everything else falls through to the menu.
@MainActor
final class ChatReactionBarOverlay {
    static let shared = ChatReactionBarOverlay()

    private var window: PassthroughWindow?
    private var host: UIHostingController<ChatReactionBarView>?
    private weak var owner: AnyObject?
    private var alignsTrailing = false
    private var bubbleFrame: () -> CGRect? = { nil }

    func show(
        projection: ChatReactionBarProjection,
        theme: BighelpTheme,
        style: UIUserInterfaceStyle,
        in scene: UIWindowScene,
        owner: AnyObject,
        alignsTrailing: Bool,
        bubbleFrame: @escaping () -> CGRect?,
        onSelect: @escaping (String?) -> Void,
        onMore: @escaping () -> Void
    ) {
        dismantle()
        self.owner = owner
        self.alignsTrailing = alignsTrailing
        self.bubbleFrame = bubbleFrame
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.overrideUserInterfaceStyle = style
        let root = RootController()
        root.appWindow = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        window.rootViewController = root
        let slot = ChatReactionBarMetrics.slot(
            choiceCount: projection.choices.count, availableWidth: window.bounds.width)
        let host = UIHostingController(rootView: ChatReactionBarView(
            projection: projection, theme: theme, slot: slot, onSelect: onSelect, onMore: onMore))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        window.isHidden = false
        self.window = window
        self.host = host

        guard let frame = targetFrame() else { return }
        host.view.frame = frame
        host.view.alpha = 0
        host.view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            .translatedBy(x: alignsTrailing ? frame.width / 2 : -frame.width / 2, y: frame.height / 2)
        UIView.animate(springDuration: 0.4, bounce: 0.3, initialSpringVelocity: 0, delay: 0.05, options: [.allowUserInteraction]) {
            host.view.alpha = 1
            host.view.transform = .identity
        }
    }

    /// Moves the bar to where the message ended up.
    func follow(owner: AnyObject) {
        guard self.owner === owner, let host, let frame = targetFrame() else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard hypot(center.x - host.view.center.x, center.y - host.view.center.y) > 0.5 else { return }
        UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
            host.view.center = center
        }
    }

    func hide(owner: AnyObject) {
        guard self.owner === owner, let window, let host else { return }
        self.owner = nil
        UIView.animate(withDuration: BighelpTokens.stateDuration, delay: 0, options: [.beginFromCurrentState]) {
            host.view.alpha = 0
            host.view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        } completion: { [weak self] _ in
            guard let self, self.window === window else { return }
            self.dismantle()
        }
    }

    private func targetFrame() -> CGRect? {
        guard let window, let host, let scene = window.windowScene, let bubbleInScene = bubbleFrame() else { return nil }
        let bubble = window.convert(bubbleInScene, from: scene.coordinateSpace)
        let size = host.sizeThatFits(in: window.bounds.size)
        return ChatReactionBarMetrics.frame(
            barSize: size, over: bubble, alignsTrailing: alignsTrailing,
            within: window.bounds.inset(by: window.safeAreaInsets))
    }

    private func dismantle() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        host = nil
        bubbleFrame = { nil }
    }

    private final class PassthroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === rootViewController?.view || hit === self ? nil : hit
        }
    }

    /// Leaves the status bar as the app has it.
    private final class RootController: UIViewController {
        weak var appWindow: UIWindow?

        private var appController: UIViewController? {
            var controller = appWindow?.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return controller
        }

        override func loadView() { view = PassthroughView() }
        override var prefersStatusBarHidden: Bool { appController?.prefersStatusBarHidden ?? false }
        override var preferredStatusBarStyle: UIStatusBarStyle { appController?.preferredStatusBarStyle ?? .default }
    }

    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }
}

/// The edges of a message around its text: holding them opens the same menu
/// as holding the text, and the strips together give the bubble's frame.
struct ChatMessageMenuStrip: UIViewRepresentable {
    let anchor: ChatBubbleMenuAnchor
    let actions: ChatMessageMenuActions
    let shape: ChatBubbleMenuShape
    let theme: BighelpTheme

    func makeCoordinator() -> ChatMessageMenuDriver { ChatMessageMenuDriver() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        anchor.register(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(actions: actions, anchor: anchor, shape: shape, theme: theme)
    }
}
