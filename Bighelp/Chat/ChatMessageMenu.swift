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
    /// Share…: the message as Messages text, Markdown, plain text or a PDF.
    var onShare: (() -> Void)? = nil
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
    static var liftsBubble: Bool {
        #if os(iOS)
        !showsMacMenus
        #else
        false
        #endif
    }

    /// A right-click on a Mac opens a Mac menu, which takes every click until it
    /// closes: a bar floating beside it could never be clicked. The iPad app on a
    /// Mac is built for iOS, so only `isiOSAppOnMac` tells it apart from an iPad.
    static var showsMacMenus: Bool {
        showsMacMenus(isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
    }

    static func showsMacMenus(isiOSAppOnMac: Bool) -> Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        isiOSAppOnMac
        #endif
    }
}

/// The message menu behind a hold or a right-click. UIKit lays out the
/// reaction palette and actions together, including beside very long bubbles.
@MainActor
final class ChatMessageMenuDriver: NSObject, UIContextMenuInteractionDelegate {
    var actions: ChatMessageMenuActions?
    var anchor: ChatBubbleMenuAnchor?
    var shape = ChatBubbleMenuShape(alignsTrailing: false, hasTail: false)
    var theme: BighelpTheme?

    private var preview: UITargetedPreview?
    private weak var activeInteraction: UIContextMenuInteraction?
    private var afterDismissal: (() -> Void)?
    private var menuIsPresented = false

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
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu()
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
        let area = bubble
        let container = UIView(frame: CGRect(origin: .zero, size: area.size))
        container.backgroundColor = .clear
        let bubbleInPreview = CGRect(origin: .zero, size: area.size)
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
        let visible = shape.path(in: bubbleInPreview)
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
        menuIsPresented = true
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
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
        menuIsPresented = false
        // The lifted copy is the app's own view; take it away once it has landed.
        ending?.view.removeFromSuperview()
        if preview === ending { preview = nil }
        let after = afterDismissal
        afterDismissal = nil
        after?()
    }

    private func moreReactions() {
        guard menuIsPresented else {
            actions?.reactions?.onMore()
            return
        }
        afterDismissal = actions?.reactions?.onMore
        activeInteraction?.dismissMenu()
    }

    func menu() -> UIMenu? {
        guard let actions else { return nil }
        var elements: [UIMenuElement] = []
        if let reactions = actions.reactions {
            elements.append(Self.reactionPalette(reactions))
            let projection = ChatReactionBarProjection(selectedEmoji: reactions.selectedEmoji)
            let onSelect = reactions.onSelect
            // UIKit clips palettes beyond six items. Keep custom reactions and
            // the emoji picker in ordinary rows so every choice stays visible.
            for choice in projection.choices.dropFirst(ChatReactionBarProjection.common.count) {
                elements.append(UIAction(title: choice.accessibilityLabel,
                    image: ChatReactionEmojiImage.image(choice.emoji), state: .on) { _ in
                    onSelect(projection.selection(afterTapping: choice.emoji))
                })
            }
            elements.append(UIAction(title: "More reactions", image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.moreReactions()
            })
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
        if let onShare = actions.onShare {
            elements.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                onShare()
            })
        }
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
        let elements: [UIMenuElement] = projection.choices.prefix(ChatReactionBarProjection.common.count).map { choice in
            UIAction(title: choice.accessibilityLabel, image: ChatReactionEmojiImage.image(choice.emoji),
                     state: choice.isSelected ? .on : .off) { _ in
                onSelect(projection.selection(afterTapping: choice.emoji))
            }
        }
        return UIMenu(title: "", options: [.displayInline, .displayAsPalette], children: elements)
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
