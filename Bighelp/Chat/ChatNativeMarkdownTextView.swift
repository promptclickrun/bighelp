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

/// A separate native layout measures the natural bubble width without rebuilding
/// Core Text's glyph layout for the entire attributed string on every append.
/// Both layouts receive the same incremental NSTextStorage edits.
@MainActor
final class ChatNativeMarkdownIdealLayout {
    static let width: CGFloat = 10_000
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))

    init(textStorage: NSTextStorage) {
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        textStorage.addLayoutManager(manager)
    }

    func size() -> CGSize {
        manager.ensureLayout(for: container)
        let bounds = manager.usedRect(for: container)
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
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
    let onReact: (() -> Void)?
    var onReply: (() -> Void)? = nil
    var textScale: CGFloat = 1
    var mentionIdentities: [ChatMentionIdentity] = []

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL, copyActionLabel: copyActionLabel, onCopy: onCopy,
            onSelect: onSelect, onFork: onFork, onReact: onReact, onReply: onReply)
    }

    func makeUIView(context: Context) -> UITextView {
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
        let textLongPressRecognizers = (view.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }
        let contextMenuInteraction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(contextMenuInteraction)
        let textRecognizerIDs = Set(textLongPressRecognizers.map(ObjectIdentifier.init))
        if let contextMenuLongPress = (view.gestureRecognizers ?? [])
            .compactMap({ $0 as? UILongPressGestureRecognizer })
            .first(where: { !textRecognizerIDs.contains(ObjectIdentifier($0)) }) {
            // The message menu owns a hold; UIKit's tap gestures remain free to
            // select a precise word or range without a second message surface.
            textLongPressRecognizers.forEach { $0.require(toFail: contextMenuLongPress) }
        }
        context.coordinator.idealLayout = ChatNativeMarkdownIdealLayout(textStorage: view.textStorage)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        _ = dynamicTypeSize
        context.coordinator.openURL = openURL
        context.coordinator.copyActionLabel = copyActionLabel
        context.coordinator.onCopy = onCopy
        context.coordinator.onSelect = onSelect
        context.coordinator.onFork = onFork
        context.coordinator.onReact = onReact
        context.coordinator.onReply = onReply
        view.tintColor = UIColor(theme.action)
        view.accessibilityCustomActions = (onReact.map { action in
            [UIAccessibilityCustomAction(name: "React") { _ in action(); return true }]
        } ?? []) + (onReply.map { action in
            [UIAccessibilityCustomAction(name: "Reply") { _ in action(); return true }]
        } ?? []) + [
            UIAccessibilityCustomAction(name: copyActionLabel) { _ in onCopy(); return true }
        ] + (BighelpPlatform.isMac ? [] : [  // Mac text is selectable with the pointer.
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
                mentionIdentities: mentionIdentities
            )
        )
        view.accessibilityLabel = "\(speakerName): \(ChatMentionRendering.plainText(updatedText, usingNames: true))"
        guard context.coordinator.renderedText?.isEqual(to: updatedText) != true else { return }

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
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            guard let idealLayout = context.coordinator.idealLayout else { return nil }
            return context.coordinator.renderCache.measure(width: ChatNativeMarkdownIdealLayout.width) { _ in
                idealLayout.size()
            }
        }
        let measured = context.coordinator.renderCache.measure(width: width) { width in
            uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        return CGSize(width: width, height: ceil(measured.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIContextMenuInteractionDelegate {
        let renderCache = ChatNativeMarkdownRenderCache()
        var idealLayout: ChatNativeMarkdownIdealLayout?
        var renderedText: NSAttributedString?
        var openURL: OpenURLAction
        var copyActionLabel: String
        var onCopy: () -> Void
        var onSelect: () -> Void
        var onFork: (() -> Void)?
        var onReact: (() -> Void)?
        var onReply: (() -> Void)?

        init(openURL: OpenURLAction, copyActionLabel: String, onCopy: @escaping () -> Void,
             onSelect: @escaping () -> Void, onFork: (() -> Void)?, onReact: (() -> Void)?,
             onReply: (() -> Void)?) {
            self.openURL = openURL
            self.copyActionLabel = copyActionLabel
            self.onCopy = onCopy
            self.onSelect = onSelect
            self.onFork = onFork
            self.onReact = onReact
            self.onReply = onReply
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0, !suggestedActions.isEmpty else { return nil }
            return UIMenu(children: suggestedActions)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                var actions: [UIMenuElement] = []
                if onReact != nil {
                    actions.append(UIAction(
                        title: "React",
                        image: UIImage(systemName: "face.smiling")
                    ) { [weak self] _ in
                        self?.onReact?()
                    })
                }
                if onReply != nil {
                    actions.append(UIAction(
                        title: "Reply",
                        image: UIImage(systemName: "arrowshape.turn.up.left")
                    ) { [weak self] _ in
                        self?.onReply?()
                    })
                }
                actions.append(UIAction(
                    title: copyActionLabel,
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in
                    self?.onCopy()
                })
                // On the Mac, text is selected with the pointer; no separate sheet.
                if !BighelpPlatform.isMac {
                    actions.append(UIAction(
                        title: "Select text",
                        image: UIImage(systemName: "selection.pin.in.out")
                    ) { [weak self] _ in
                        self?.onSelect()
                    })
                }
                if onFork != nil {
                    actions.append(UIAction(
                        title: "Fork from here",
                        image: UIImage(systemName: "arrow.triangle.branch")
                    ) { [weak self] _ in
                        self?.onFork?()
                    })
                }
                return UIMenu(children: actions)
            }
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
