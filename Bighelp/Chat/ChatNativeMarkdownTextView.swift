import SwiftUI
import UIKit

/// Preserve unchanged TextKit storage and its laid-out paragraphs while a
/// response grows. Formatting changes earlier in the answer still invalidate
/// from the first differing attribute run, even when the characters match.
@MainActor
enum ChatNativeTextStorageUpdater {
    static func apply(_ updated: NSAttributedString, previous: NSAttributedString?, to storage: NSTextStorage) {
        // TextKit may add fallback fonts and other internal attributes. Diff
        // canonical renders so those platform adjustments do not turn every
        // append into a replacement beginning at character zero.
        let previous = previous ?? NSAttributedString(string: "")
        let textPrefix = storage.string == previous.string
            ? (previous.string as NSString).commonPrefix(with: updated.string, options: .literal).utf16.count : 0
        var unchanged = 0
        while unchanged < textPrefix {
            var oldRange = NSRange()
            var newRange = NSRange()
            let oldAttributes = previous.attributes(at: unchanged, effectiveRange: &oldRange)
            let newAttributes = updated.attributes(at: unchanged, effectiveRange: &newRange)
            guard NSDictionary(dictionary: oldAttributes).isEqual(to: newAttributes) else { break }
            unchanged = min(textPrefix, NSMaxRange(oldRange), NSMaxRange(newRange))
        }
        guard unchanged != storage.length || unchanged != updated.length else { return }
        storage.replaceCharacters(in: NSRange(location: unchanged, length: storage.length - unchanged),
                                  with: updated.attributedSubstring(from: NSRange(location: unchanged, length: updated.length - unchanged)))
    }
}

/// The bubble consumes only the width of this ideal proposal; its height is
/// measured at the actual width. Stop once the text exceeds every supported
/// bubble width, without laying out the rest of a long answer a second time.
@MainActor
final class ChatNativeMarkdownIdealLayout {
    static let width: CGFloat = 10_000
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))

    init(textStorage: NSTextStorage) {
        // Otherwise TextKit completes the whole container even for a small probe.
        manager.allowsNonContiguousLayout = true
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        textStorage.addLayoutManager(manager)
    }

    func size() -> CGSize {
        guard let storage = manager.textStorage else { return .zero }
        var height: CGFloat = 256
        while true {
            manager.ensureLayout(forBoundingRect: CGRect(x: 0, y: 0, width: Self.width, height: height),
                                 in: container)
            let bounds = manager.usedRect(for: container)
            let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
            if size.width >= ChatBubbleLayoutMetrics.maximumAbsoluteWidth
                || manager.firstUnlaidCharacterIndex() >= storage.length { return size }
            height *= 2
        }
    }
}

struct NativeInlineSelectableMarkdownTextView: UIViewRepresentable {
    let document: MarkdownDocument
    let speakerName: String
    let proseLineSpacing: CGFloat
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let codeBackground: Color
    let openURL: OpenURLAction
    let theme: BighelpTheme
    let copyActionLabel: String
    let onCopy: () -> Void
    let onSelect: () -> Void
    let onFork: (() -> Void)?
    let reactions: ChatMessageReactionActions?
    var onReply: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var textScale: CGFloat = 1
    var mentionIdentities: [ChatMentionIdentity] = []
    /// The bubble around this text, so a hold lifts all of it.
    var menuAnchor: ChatBubbleMenuAnchor? = nil
    var bubbleShape = ChatBubbleMenuShape(alignsTrailing: false, hasTail: false)
    var citationLinks: [Int: URL] = [:]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.opensHostFiles) private var opensHostFiles

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL)
    }

    func makeUIView(context: Context) -> ChatMessageTextHost {
        // Read-only messages use incremental NSTextStorage updates and full-height
        // measurement. Avoid TextKit 2 fragment relayout on each streaming append.
        // The editable composer keeps its own text system and selection owner.
        let view = ChatMentionTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.isUserInteractionEnabled = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isOpaque = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.textContainer.widthTracksTextView = true
        view.textContainer.heightTracksTextView = false
        view.tintColor = UIColor(theme.action)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "chat.message.inline-selection"
        view.accessibilityHint = "Long press shows message actions. Double tap selects a word. Links open in your chosen browser."
        let host = ChatMessageTextHost(textView: view)
        host.addInteraction(UIContextMenuInteraction(delegate: context.coordinator.menu))
        context.coordinator.idealLayout = ChatNativeMarkdownIdealLayout(textStorage: view.textStorage)
        return host
    }

    func updateUIView(_ host: ChatMessageTextHost, context: Context) {
        let view = host.textView
        _ = dynamicTypeSize
        context.coordinator.openURL = openURL
        context.coordinator.menu.update(
            actions: ChatMessageMenuActions(copyActionLabel: copyActionLabel, onCopy: onCopy, onSelect: onSelect,
                                            onFork: onFork, onReply: onReply, reactions: reactions,
                                            onShare: onShare),
            anchor: menuAnchor, shape: bubbleShape, theme: theme)
        view.tintColor = UIColor(theme.action)
        view.accessibilityCustomActions = (reactions.map { reactions in
            [UIAccessibilityCustomAction(name: "React") { _ in reactions.onMore(); return true }]
        } ?? []) + (onReply.map { action in
            [UIAccessibilityCustomAction(name: "Reply") { _ in action(); return true }]
        } ?? []) + [
            UIAccessibilityCustomAction(name: copyActionLabel) { _ in onCopy(); return true }
        ] + (onShare.map { action in
            [UIAccessibilityCustomAction(name: "Share") { _ in action(); return true }]
        } ?? []) + (BighelpPlatform.isMac ? [] : [  // Mac text is selectable with the pointer.
            UIAccessibilityCustomAction(name: "Select text") { _ in onSelect(); return true }
        ]) + (onFork.map { action in [UIAccessibilityCustomAction(name: "Fork from here") { _ in action(); return true }] } ?? [])
        let accentColor = UIColor(accent)
        view.linkTextAttributes = [
            .foregroundColor: accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let updatedText = context.coordinator.renderCache.render(
            document: document,
            style: ChatNativeMarkdownStyle(
                primaryText: UIColor(primaryText),
                secondaryText: UIColor(secondaryText),
                accent: accentColor,
                codeBackground: UIColor(codeBackground),
                proseLineSpacing: proseLineSpacing,
                traitCollection: view.traitCollection,
                theme: theme,
                textScale: textScale,
                mentionIdentities: mentionIdentities,
                linksMarkdownFiles: opensHostFiles,
                citationLinks: citationLinks
            )
        )
        let textChanged = context.coordinator.renderedText?.isEqual(to: updatedText) != true
        if textChanged || context.coordinator.accessibilitySpeakerName != speakerName {
            view.accessibilityLabel = "\(speakerName): \(ChatMentionRendering.plainText(updatedText, usingNames: true))"
            context.coordinator.accessibilitySpeakerName = speakerName
        }
        guard textChanged else { return }

        let previousSelection = view.selectedRange
        ChatNativeTextStorageUpdater.apply(updatedText, previous: context.coordinator.renderedText, to: view.textStorage)
        context.coordinator.renderedText = updatedText
        if previousSelection.location != NSNotFound {
            let location = min(previousSelection.location, updatedText.length)
            view.selectedRange = NSRange(
                location: location,
                length: min(previousSelection.length, updatedText.length - location)
            )
        }
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        host.setNeedsLayout()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView host: ChatMessageTextHost,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            guard let idealLayout = context.coordinator.idealLayout else { return nil }
            return context.coordinator.renderCache.measure(width: ChatNativeMarkdownIdealLayout.width) { _ in
                ChatPerformanceProbe.measure("text.layout.ideal") { idealLayout.size() }
            }
        }
        let measured = context.coordinator.renderCache.measure(width: width) { width in
            ChatPerformanceProbe.measure("text.layout.constrained") {
                host.textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            }
        }
        return CGSize(width: width, height: ceil(measured.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let renderCache = ChatNativeMarkdownRenderCache()
        /// The message menu: Reply, Copy and the rest, with the reaction bar.
        let menu = ChatMessageMenuDriver()
        var idealLayout: ChatNativeMarkdownIdealLayout?
        var renderedText: NSAttributedString?
        var accessibilitySpeakerName: String?
        var openURL: OpenURLAction

        init(openURL: OpenURLAction) {
            self.openURL = openURL
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0, !suggestedActions.isEmpty else { return nil }
            return UIMenu(children: suggestedActions)
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            openURL(url)
            return false
        }
    }
}

/// Holds a message's text view and the message menu. The menu sits on this view, not on the text
/// view: UIKit never asks a menu added to the text view itself, so a hold on the text opened nothing
/// and only the bubble's padding strips worked (#719). Holds on the text reach this view's menu,
/// which wins over the text view's own long-press; taps still select words and open links.
final class ChatMessageTextHost: UIView {
    let textView: UITextView

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // The menu's recognizers exist once the view is in a window. The text view's long-press
        // (its loupe) waits for them, so a hold opens the menu; Select text there selects.
        let menuRecognizers = gestureRecognizers ?? []
        for recognizer in textView.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
            menuRecognizers.forEach { recognizer.require(toFail: $0) }
        }
    }
}
