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
    private var barInPreview: CGRect?
    private var barSlot = ChatReactionBarMetrics.preferredSlot
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
        // A hold let go before its menu showed leaves no copy behind.
        if preview?.view.window != nil { preview?.view.removeFromSuperview() }
        preview = nil
        guard ChatMessageMenuStyle.liftsBubble, let source = interaction.view, let window = source.window else {
            return nil
        }
        // Only the part on screen lifts, drawn from the message's own row so the
        // header or the message box over it never comes along.
        let bubble = (anchor?.frame(in: window) ?? source.convert(source.bounds, to: window))
            .intersection(window.bounds)
        let row = Self.row(containing: source) ?? window
        guard !bubble.isNull, bubble.width > 1, bubble.height > 1,
              let snapshot = row.resizableSnapshotView(
                from: row.convert(bubble, from: window), afterScreenUpdates: false, withCapInsets: .zero)
        else { return nil }
        // The bar's pill lifts with the bubble, so the system fits both on
        // screen; its emoji arrive in the bar's own window over the pill.
        var bar: CGRect?
        if ChatMessageMenuStyle.floatsReactions, let reactions = actions?.reactions {
            let count = ChatReactionBarProjection(selectedEmoji: reactions.selectedEmoji).choices.count
            barSlot = ChatReactionBarMetrics.slot(choiceCount: count, availableWidth: window.bounds.width)
            bar = ChatReactionBarMetrics.liftedFrame(
                barSize: ChatReactionBarMetrics.barSize(choiceCount: count, slot: barSlot), over: bubble,
                alignsTrailing: shape.alignsTrailing, minX: window.bounds.minX, maxX: window.bounds.maxX)
        }
        let area = bar.map { $0.union(bubble) } ?? bubble
        let container = UIView(frame: CGRect(origin: .zero, size: area.size))
        container.backgroundColor = .clear
        bubbleInPreview = bubble.offsetBy(dx: -area.minX, dy: -area.minY)
        barInPreview = bar?.offsetBy(dx: -area.minX, dy: -area.minY)
        snapshot.frame = bubbleInPreview
        // A reply's bubble is a see-through tint over the chat; keep the chat behind it.
        let backing = UIView(frame: bubbleInPreview)
        backing.backgroundColor = theme.map { UIColor($0.canvas) } ?? .systemBackground
        for view in [backing, snapshot] {
            let mask = CAShapeLayer()
            mask.path = shape.path(in: view.bounds).cgPath
            view.layer.mask = mask
            container.addSubview(view)
        }
        // Only the bubble and the pill are lifted; everything around them,
        // the message above included, stays under the menu's blur.
        let visible = shape.path(in: bubbleInPreview)
        if let barInPreview {
            let pill = UIView(frame: barInPreview)
            pill.backgroundColor = theme.map { UIColor($0.raisedSurface) } ?? .systemBackground
            pill.layer.cornerRadius = barInPreview.height / 2
            container.addSubview(pill)
            visible.append(UIBezierPath(roundedRect: barInPreview, cornerRadius: barInPreview.height / 2))
        }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = visible
        parameters.shadowPath = visible
        let target = UIPreviewTarget(container: window, center: CGPoint(x: area.midX, y: area.midY))
        let preview = UITargetedPreview(view: container, parameters: parameters, target: target)
        self.preview = preview
        return preview
    }

    private static func row(containing view: UIView) -> UIView? {
        var current = view.superview
        while let candidate = current {
            if candidate is UITableViewCell || candidate is UICollectionViewCell { return candidate }
            current = candidate.superview
        }
        return nil
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
        #if !os(visionOS)
        guard ChatMessageMenuStyle.floatsReactions, let reactions = actions?.reactions, let theme,
              let source = interaction.view, let scene = source.window?.windowScene else { return }
        let overlay = ChatReactionBarOverlay.shared
        let projection = ChatReactionBarProjection(selectedEmoji: reactions.selectedEmoji)
        if preview == nil, let window = source.window {
            barSlot = ChatReactionBarMetrics.slot(choiceCount: projection.choices.count,
                                                  availableWidth: window.bounds.width)
        }
        overlay.show(
            projection: projection,
            theme: theme,
            style: source.traitCollection.userInterfaceStyle,
            in: scene,
            owner: self,
            slot: barSlot,
            barFrame: { [weak self] in self?.barInScene() },
            onSelect: { [weak self] emoji in self?.react(emoji) },
            onMore: { [weak self] in self?.moreReactions() }
        )
        // The system may move the message to fit its menu; follow it there.
        animator?.addCompletion { [weak self] in
            guard let self else { return }
            overlay.follow(owner: self)
        }
        #endif
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        #if !os(visionOS)
        ChatReactionBarOverlay.shared.hide(owner: self)
        #endif
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

    #if !os(visionOS)
    /// The bar in the scene's coordinates: on the lifted pill, or over the
    /// message itself when nothing lifts (a pointer's right-click).
    private func barInScene() -> CGRect? {
        if let container = preview?.view, let barInPreview, let window = container.window,
           let scene = window.windowScene {
            return container.convert(barInPreview, to: scene.coordinateSpace)
        }
        guard let source = activeInteraction?.view, let window = source.window,
              let scene = window.windowScene, let reactions = actions?.reactions else { return nil }
        let bubble = anchor?.frame(in: window) ?? source.convert(source.bounds, to: window)
        let count = ChatReactionBarProjection(selectedEmoji: reactions.selectedEmoji).choices.count
        let bar = ChatReactionBarMetrics.frame(
            barSize: ChatReactionBarMetrics.barSize(choiceCount: count, slot: barSlot), over: bubble,
            alignsTrailing: shape.alignsTrailing, within: window.bounds.inset(by: window.safeAreaInsets))
        return window.convert(bar, to: scene.coordinateSpace)
    }
    #endif

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

#if !os(visionOS)
/// The reaction bar's own window, above the lifted message and its menu.
/// Only the bar takes touches; everything else falls through to the menu.
@MainActor
final class ChatReactionBarOverlay {
    static let shared = ChatReactionBarOverlay()

    private var window: PassthroughWindow?
    private var host: UIHostingController<ChatReactionBarView>?
    private weak var owner: AnyObject?
    private var barFrame: () -> CGRect? = { nil }

    func show(
        projection: ChatReactionBarProjection,
        theme: BighelpTheme,
        style: UIUserInterfaceStyle,
        in scene: UIWindowScene,
        owner: AnyObject,
        slot: CGFloat,
        barFrame: @escaping () -> CGRect?,
        onSelect: @escaping (String?) -> Void,
        onMore: @escaping () -> Void
    ) {
        dismantle()
        self.owner = owner
        self.barFrame = barFrame
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.overrideUserInterfaceStyle = style
        let root = RootController()
        root.appWindow = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        window.rootViewController = root
        let host = UIHostingController(rootView: ChatReactionBarView(
            projection: projection, theme: theme, slot: slot, onSelect: onSelect, onMore: onMore))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        window.bar = host.view
        self.window = window
        self.host = host

        guard let frame = targetFrame() else {
            dismantle()
            return
        }
        window.isHidden = false
        host.view.bounds = CGRect(origin: .zero, size: host.sizeThatFits(in: window.bounds.size))
        Self.place(host.view, on: frame)
        host.view.alpha = 0
        UIView.animate(withDuration: BighelpTokens.stateDuration, delay: 0, options: [.allowUserInteraction]) {
            host.view.alpha = 1
        }
    }

    /// Moves the bar onto the lifted pill once the system has placed the message.
    func follow(owner: AnyObject) {
        guard self.owner === owner, let host, let frame = targetFrame(),
              host.view.frame.integral != frame.integral else { return }
        UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
            Self.place(host.view, on: frame)
        }
    }

    /// The lifted copy can be drawn a little larger than the message; the bar
    /// takes the same scale so it covers its pill exactly.
    private static func place(_ view: UIView, on frame: CGRect) {
        let size = view.bounds.size
        view.center = CGPoint(x: frame.midX, y: frame.midY)
        guard size.width > 0, size.height > 0 else { return }
        view.transform = CGAffineTransform(scaleX: frame.width / size.width, y: frame.height / size.height)
    }

    func hide(owner: AnyObject) {
        guard self.owner === owner, let window, let host else { return }
        self.owner = nil
        UIView.animate(withDuration: BighelpTokens.stateDuration, delay: 0, options: [.beginFromCurrentState]) {
            host.view.alpha = 0
        } completion: { [weak self] _ in
            guard let self, self.window === window else { return }
            self.dismantle()
        }
    }

    private func targetFrame() -> CGRect? {
        guard let window, let scene = window.windowScene, let barInScene = barFrame() else { return nil }
        return window.convert(barInScene, from: scene.coordinateSpace)
    }

    private func dismantle() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        host = nil
        barFrame = { nil }
    }

    /// Only touches on the bar stay here; iPad wraps the root view in
    /// containers of its own, so anything else must fall through by name.
    private final class PassthroughWindow: UIWindow {
        weak var bar: UIView?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let bar, let hit = super.hitTest(point, with: event), hit.isDescendant(of: bar) else { return nil }
            return hit
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

        override var prefersStatusBarHidden: Bool { appController?.prefersStatusBarHidden ?? false }
        override var preferredStatusBarStyle: UIStatusBarStyle { appController?.preferredStatusBarStyle ?? .default }
    }
}

#endif

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
