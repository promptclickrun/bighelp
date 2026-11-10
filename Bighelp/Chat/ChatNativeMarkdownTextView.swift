import SwiftUI
import UIKit

/// Preserve unchanged TextKit storage and its laid-out paragraphs while a
/// response grows. Formatting changes earlier in the answer still invalidate
/// from the first differing attribute run, even when the characters match.
@MainActor
enum ChatNativeTextStorageUpdater {
    /// `unchangedPrefix` is how much of `previous` the caller knows `updated` starts with
    /// (`ChatNativeMarkdownRenderCache.unchangedPrefix`): the comparison starts there, so a long
    /// answer's finished blocks aren't compared again for each piece.
    static func apply(_ updated: NSAttributedString, previous: NSAttributedString?, unchangedPrefix: Int = 0,
                      to storage: NSTextStorage) {
        // TextKit may add fallback fonts and other internal attributes. Diff
        // canonical renders so those platform adjustments do not turn every
        // append into a replacement beginning at character zero.
        let previous = previous ?? NSAttributedString(string: "")
        let textPrefix = (storage.string as NSString).isEqual(to: previous.string)
            ? (previous.string as NSString).commonPrefix(with: updated.string, options: .literal).utf16.count : 0
        var unchanged = min(max(unchangedPrefix, 0), textPrefix)
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

/// A message's height at each width SwiftUI asks about while the message is on screen. SwiftUI
/// proposes several widths while it sizes a row, and a text view asked for its size lays its whole
/// text out again every time: four times for each streamed piece of a long answer. Each width
/// here has its own layout on the same text, so when the text grows, each lays out only what
/// was added. They hold more copies of the layout, so `release` drops them once the text has
/// stopped changing.
@MainActor
final class ChatNativeMarkdownSideLayouts {
    private struct Layout {
        let manager: NSLayoutManager
        let container: NSTextContainer
    }

    static let limit = 3
    private weak var storage: NSTextStorage?
    private var layouts: [Layout] = []

    init(textStorage: NSTextStorage) {
        storage = textStorage
    }

    /// What a text view with no insets and no line padding measures at `width`.
    func size(width: CGFloat) -> CGSize {
        guard let storage else { return .zero }
        let layout: Layout
        if let index = layouts.firstIndex(where: { $0.container.size.width == width }) {
            layout = layouts.remove(at: index)
        } else {
            if layouts.count == Self.limit { storage.removeLayoutManager(layouts.removeFirst().manager) }
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byWordWrapping
            let manager = NSLayoutManager()
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            layout = Layout(manager: manager, container: container)
        }
        // Most recently used last, so the oldest goes first.
        layouts.append(layout)
        layout.manager.ensureLayout(for: layout.container)
        let used = layout.manager.usedRect(for: layout.container)
        // A text view counts the empty line after a final line break.
        let height = max(used.maxY, layout.manager.extraLineFragmentRect.maxY)
        return CGSize(width: ceil(used.width), height: ceil(height))
    }

    func release() {
        for layout in layouts { storage?.removeLayoutManager(layout.manager) }
        layouts.removeAll()
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
        context.coordinator.sideLayouts = ChatNativeMarkdownSideLayouts(textStorage: view.textStorage)
        // Read by VoiceOver and tests when they ask: making it from the whole answer for each
        // streamed piece was work nobody read.
        host.accessibilityLabelSource = { [weak coordinator = context.coordinator] in
            guard let coordinator, let text = coordinator.renderedText else { return nil }
            return "\(coordinator.accessibilitySpeakerName): \(ChatMentionRendering.plainText(text, usingNames: true))"
        }
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
        // Setting these lays the text out again, so only when the color changed.
        if context.coordinator.linkColor != accentColor {
            context.coordinator.linkColor = accentColor
            view.linkTextAttributes = [
                .foregroundColor: accentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
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
        context.coordinator.accessibilitySpeakerName = speakerName
        let revision = context.coordinator.renderCache.revision
        guard context.coordinator.renderedRevision != revision else { return }

        let previousSelection = view.selectedRange
        ChatNativeTextStorageUpdater.apply(
            updatedText, previous: context.coordinator.renderedText,
            // Only the change just made is described; a view that missed one compares from the start.
            unchangedPrefix: context.coordinator.renderedRevision == revision &- 1
                ? context.coordinator.renderCache.unchangedPrefix : 0,
            to: view.textStorage)
        // Text that gets longer after it first showed is an answer arriving. A finished answer
        // that only gains its links keeps its size.
        let isGrowing = context.coordinator.renderedText.map { updatedText.length > $0.length } ?? false
        context.coordinator.renderedText = updatedText
        context.coordinator.renderedRevision = revision
        context.coordinator.textChanged(in: host, isGrowing: isGrowing)
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
            // `UITextView.sizeThatFits` lays the whole text out again on every call, also at the
            // width the view already has, and the view's own container is only as tall as the
            // view. So only a view not yet on screen is measured that way. One on screen has a
            // layout of its own for each width it's asked about, the width it shows at too:
            // text that grew is laid out only where it grew.
            let textView = host.textView
            guard textView.bounds.width > 0, let sideLayouts = context.coordinator.sideLayouts else {
                return ChatPerformanceProbe.measure("text.layout.constrained") {
                    textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                }
            }
            context.coordinator.sideLayoutsUsed(in: host)
            return ChatPerformanceProbe.measure("text.layout.side") { sideLayouts.size(width: width) }
        }
        return CGSize(width: width, height: ceil(measured.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let renderCache = ChatNativeMarkdownRenderCache()
        /// The message menu: Reply, Copy and the rest, with the reaction bar.
        let menu = ChatMessageMenuDriver()
        var idealLayout: ChatNativeMarkdownIdealLayout?
        var sideLayouts: ChatNativeMarkdownSideLayouts?
        var renderedText: NSAttributedString?
        /// `renderCache.revision` of `renderedText`.
        var renderedRevision: Int?
        var accessibilitySpeakerName = ""
        var linkColor: UIColor?
        var openURL: OpenURLAction
        private var sideLayoutRelease: DispatchWorkItem?

        init(openURL: OpenURLAction) {
            self.openURL = openURL
        }

        /// The side layouts and the text view's room to grow are for text that is growing. Once
        /// it has been still for a moment they go, and a later question about another width
        /// makes a side layout again.
        @MainActor
        func textChanged(in host: ChatMessageTextHost, isGrowing: Bool) {
            if isGrowing { host.growsInSteps = true }
            scheduleRelease(of: host)
        }

        /// A width change (rotation, a resized window) measures finished text through side layouts
        /// too. They go the same way, so a still message never keeps them.
        @MainActor
        func sideLayoutsUsed(in host: ChatMessageTextHost) {
            if sideLayoutRelease == nil { scheduleRelease(of: host) }
        }

        @MainActor
        private func scheduleRelease(of host: ChatMessageTextHost) {
            sideLayoutRelease?.cancel()
            let release = DispatchWorkItem { [weak self, weak host] in
                MainActor.assumeIsolated {
                    self?.sideLayouts?.release()
                    self?.sideLayoutRelease = nil
                    host?.growsInSteps = false
                }
            }
            sideLayoutRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: release)
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
    /// The message as VoiceOver reads it, made when its text view is asked for its label.
    var accessibilityLabelSource: (@MainActor () -> String?)?

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A text view that doesn't scroll keeps its text container as tall as itself, and lays all
    /// of its text out again whenever its height changes: once for every line a streamed answer
    /// gained. While the text grows, the text view is this view's height rounded up to
    /// `growthStep`, and this view clips it, so that happens once in many lines.
    var growsInSteps = false {
        didSet {
            guard growsInSteps != oldValue else { return }
            // The clip is only for the room below the text; selection handles reach past the edge.
            clipsToBounds = growsInSteps
            setNeedsLayout()
        }
    }
    static let growthStep: CGFloat = 480

    override func layoutSubviews() {
        super.layoutSubviews()
        var frame = bounds
        if growsInSteps, frame.height > 0 {
            frame.size.height = (frame.height / Self.growthStep).rounded(.up) * Self.growthStep
        }
        if textView.frame != frame { textView.frame = frame }
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
