import SwiftUI
import UIKit

/// The editor for long text people write and tune: an agent's instructions (its SOUL) and a
/// personality's, in the form's box, the full-screen editor and Bots mode's sheet. One UIKit
/// text view everywhere, because SwiftUI's `TextEditor` stuttered with thousands of
/// characters (#727): the form measured all of its text on every keystroke to size the box,
/// a drag down the box took the form's interactive keyboard dismissal, and nothing kept the
/// caret above the keyboard when the box sat behind it.
///
/// The view keeps its own text and selection while you type; the binding only hears about
/// changes, and the view's own keystrokes coming back cost nothing however long the text is.
struct LongTextEditor: UIViewRepresentable {
    enum Layout: Equatable {
        /// A box in a form: as tall as its text from `minimumHeight` to `maximumHeight`, then
        /// it scrolls inside. While it's the field being edited, scrolling it never puts the
        /// keyboard away; the keyboard's Done does.
        case box(minimumHeight: CGFloat, maximumHeight: CGFloat)
        /// Takes the space it's given. A drag down into the keyboard puts it away, as in Notes.
        case fill

        /// The instructions box in a form.
        static let formBox = Layout.box(minimumHeight: 140, maximumHeight: 260)
    }

    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let identifier: String
    let layout: Layout
    let focusesOnAppear: Bool
    /// When editing starts and stops. A form turns its own keyboard dismissal off while its
    /// box is edited: a drag on the box that scrolled the form put the keyboard away.
    let onEditingChanged: ((Bool) -> Void)?
    @BighelpThemeReader private var theme

    init(
        text: Binding<String>,
        placeholder: String = "",
        accessibilityLabel: String,
        identifier: String,
        layout: Layout = .fill,
        focusesOnAppear: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.identifier = identifier
        self.layout = layout
        self.focusesOnAppear = focusesOnAppear
        self.onEditingChanged = onEditingChanged
    }

    /// TextKit 2 lays out only what's on screen, so long text costs the same as short.
    /// DEBUG builds launched with `-test-long-text-textkit1` use TextKit 1, to compare.
    static var usesTextKit2: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-test-long-text-textkit1")
        #else
        true
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onEditingChanged: onEditingChanged) }

    func makeUIView(context: Context) -> LongTextView {
        let view = LongTextView(usesTextKit2: Self.usesTextKit2)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        // The font follows bighelp's text size from the environment (`configure`).
        view.adjustsFontForContentSizeCategory = false
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        // The view clears the keyboard itself (`updateKeyboardInset`), so the safe area adds nothing.
        view.contentInsetAdjustmentBehavior = .never
        view.text = text
        context.coordinator.synced = text
        view.focusesOnAppear = focusesOnAppear
        configure(view, environment: context.environment)
        return view
    }

    func updateUIView(_ view: LongTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.onEditingChanged = onEditingChanged
        configure(view, environment: context.environment)
        // The view's own keystrokes come back as the same string, which compares at once.
        if text != coordinator.synced, view.markedTextRange == nil {
            view.apply(text)
            coordinator.synced = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: LongTextView, context: Context) -> CGSize? {
        let fallbackWidth = view.bounds.width > 0 ? view.bounds.width : 320
        let width = proposal.width ?? fallbackWidth
        switch layout {
        case let .box(minimum, maximum):
            // Layout also asks with zero and infinite widths to learn how flexible the view is.
            let measuringWidth = width.isFinite && width > 0 ? width : fallbackWidth
            return CGSize(width: width,
                          height: view.boxHeight(forWidth: measuringWidth, minimum: minimum, maximum: maximum))
        case .fill:
            return CGSize(width: width, height: proposal.height ?? 320)
        }
    }

    static func dismantleUIView(_ view: LongTextView, coordinator: Coordinator) {
        view.delegate = nil
        // Gone while edited: its form gets its keyboard dismissal back, after this update.
        if view.isFirstResponder, let onEditingChanged = coordinator.onEditingChanged {
            Task { @MainActor in onEditingChanged(false) }
        }
    }

    private func configure(_ view: LongTextView, environment: EnvironmentValues) {
        view.layout = layout
        let traits = UITraitCollection(preferredContentSizeCategory: Self.category(environment.dynamicTypeSize))
        let font = UIFont.bighelp(.body, compatibleWith: traits)
        if view.font != font { view.font = font }
        #if os(visionOS)
        view.applyColors(ink: theme.primaryText, hint: theme.tertiaryText, caret: nil)
        #else
        view.applyColors(ink: theme.primaryText, hint: theme.tertiaryText, caret: theme.action)
        #endif
        view.placeholder = placeholder
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityHint = view.hasText ? nil : placeholder
        view.accessibilityIdentifier = identifier
        view.updateKeyboardDismissMode(editing: view.isFirstResponder)
        view.showsKeyboardDoneButton = layout != .fill
    }

    /// bighelp's text size, stepped in SwiftUI by `BighelpTextSizing`, as UIKit's size category.
    static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var onEditingChanged: ((Bool) -> Void)?
        /// The text the view and the binding last agreed on.
        var synced = ""

        init(text: Binding<String>, onEditingChanged: ((Bool) -> Void)?) {
            self.text = text
            self.onEditingChanged = onEditingChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            let current = textView.text ?? ""
            synced = current
            (textView as? LongTextView)?.didEdit()
            text.wrappedValue = current
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            (textView as? LongTextView)?.didBeginEditing()
            onEditingChanged?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            (textView as? LongTextView)?.didEndEditing()
            onEditingChanged?(false)
        }
    }
}

/// The text view behind `LongTextEditor`. It keeps its caret above the keyboard on its own:
/// the part of it the keyboard covers becomes bottom inset, and a box in a form scrolls the form
/// so the whole box clears the keyboard when it starts editing.
final class LongTextView: UITextView {
    var layout: LongTextEditor.Layout = .fill
    var focusesOnAppear = false
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            placeholderLabel.text = placeholder
            setNeedsLayout()
        }
    }
    var showsKeyboardDoneButton = false {
        didSet {
            guard showsKeyboardDoneButton != oldValue else { return }
            installKeyboardDoneButton()
        }
    }

    private let placeholderLabel = UILabel()
    private var hasFocusedOnAppear = false
    private var observesKeyboard = false
    private var lastBoxHeight: CGFloat?
    private var revealsCaretAfterEdit = false
    /// The colors last applied, resolved, so an update that changes nothing re-colors nothing:
    /// setting `textColor` touches every character.
    private var appliedColors: [CGFloat] = []

    /// Never `UITextView(usingTextLayoutManager:)`: that factory makes the view through an
    /// initializer Swift doesn't override, so this class's stored properties were never set and
    /// the first read of one crashed (#727).
    init(usesTextKit2: Bool) {
        super.init(frame: .zero, textContainer: nil)
        // Asking for the layout manager is how a text view moves to TextKit 1.
        if !usesTextKit2 { _ = layoutManager }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var font: UIFont? {
        didSet { placeholderLabel.font = font }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if placeholderLabel.superview == nil {
            placeholderLabel.numberOfLines = 0
            placeholderLabel.isAccessibilityElement = false
            placeholderLabel.font = font
            placeholderLabel.text = placeholder
            addSubview(placeholderLabel)
        }
        placeholderLabel.isHidden = hasText
        observeKeyboard(window != nil)
        guard window != nil, focusesOnAppear, !hasFocusedOnAppear else { return }
        hasFocusedOnAppear = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.isEditable else { return }
            self.becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The view moves and resizes with its form (a box growing, the form scrolled, rotation).
        updateKeyboardInset(followsCaret: false)
        guard !placeholderLabel.isHidden else { return }
        let padding = textContainer.lineFragmentPadding
        let width = max(bounds.width - textContainerInset.left - textContainerInset.right - padding * 2, 0)
        let size = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(x: textContainerInset.left + padding, y: textContainerInset.top,
                                        width: width, height: size.height)
    }

    func applyColors(ink: Color, hint: Color, caret: Color?) {
        let inkColor = UIColor(ink), hintColor = UIColor(hint), caretColor = caret.map { UIColor($0) }
        let resolved = [inkColor, hintColor, caretColor ?? .clear].flatMap { color -> [CGFloat] in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha]
        }
        guard resolved != appliedColors else { return }
        appliedColors = resolved
        textColor = inkColor
        placeholderLabel.textColor = hintColor
        if let caretColor {
            tintColor = caretColor
            inputAccessoryView?.tintColor = caretColor
        }
    }

    /// The box's height for a width. Text past `LongTextBox.measuredLength` is always taller than
    /// the box, so it isn't laid out at all; shorter text is measured, which is cheap.
    func boxHeight(forWidth width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let measured: CGFloat? = textStorage.length > LongTextBox.measuredLength
            ? nil
            : sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = LongTextBox.height(measured: measured, minimum: minimum, maximum: maximum)
        lastBoxHeight = height
        return height
    }

    /// After the person's own keystroke. UIKit scrolls to the caret after the edit, and not always
    /// far enough: after a jump through text TextKit 2 hasn't laid out yet, or onto a new empty last
    /// line, the line being typed stayed out of sight (#727). A scroll during the edit doesn't hold,
    /// so the caret is brought into view right after it, once however fast the keys come.
    func didEdit() {
        textDidChange()
        guard isFirstResponder, !revealsCaretAfterEdit else { return }
        revealsCaretAfterEdit = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revealsCaretAfterEdit = false
            if self.isFirstResponder { self.scrollCaretToVisible() }
        }
    }

    /// After the person's own edit, or text put in from elsewhere.
    func textDidChange() {
        placeholderLabel.isHidden = hasText
        if case let .box(minimum, maximum) = layout, let last = lastBoxHeight, bounds.width > 0,
           boxHeight(forWidth: bounds.width, minimum: minimum, maximum: maximum) != last {
            invalidateIntrinsicContentSize()
        }
    }

    /// Text from elsewhere: a template, the full-screen editor, a name filled into the
    /// instructions. While the person types here it goes in as the smallest edit, so the caret
    /// and the scroll position stay; otherwise it replaces the text and keeps the scroll position.
    func apply(_ newText: String) {
        let old = text ?? ""
        if isFirstResponder, !old.isEmpty, let edit = LongTextEdit.difference(from: old, to: newText) {
            let selection = selectedRange
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let font { attributes[.font] = font }
            if let textColor { attributes[.foregroundColor] = textColor }
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: edit.range,
                                          with: NSAttributedString(string: edit.replacement, attributes: attributes))
            textStorage.endEditing()
            selectedRange = LongTextEdit.selection(selection, after: edit)
            // Its undo steps no longer match the text.
            undoManager?.removeAllActions()
        } else {
            let offset = contentOffset
            text = newText
            layoutIfNeeded()
            let bottom = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
            contentOffset = CGPoint(x: offset.x, y: min(max(offset.y, -adjustedContentInset.top), bottom))
        }
        textDidChange()
    }

    func didBeginEditing() {
        updateKeyboardDismissMode(editing: true)
        updateKeyboardInset(followsCaret: true)
        revealBoxAboveKeyboard()
    }

    func didEndEditing() {
        updateKeyboardDismissMode(editing: false)
        updateKeyboardInset(followsCaret: false)
    }

    /// A box keeps the keyboard while it's the field being edited, so scrolling back up through
    /// its text never drops it. Otherwise it scrolls like the rest of the form.
    func updateKeyboardDismissMode(editing: Bool) {
        #if !os(visionOS)
        let mode: UIScrollView.KeyboardDismissMode = switch layout {
        case .box: editing ? .none : .interactive
        case .fill: .interactive
        }
        if keyboardDismissMode != mode { keyboardDismissMode = mode }
        #endif
    }

    // MARK: Keyboard

    private func observeKeyboard(_ observes: Bool) {
        #if !os(visionOS)
        guard observes != observesKeyboard else { return }
        observesKeyboard = observes
        let center = NotificationCenter.default
        if observes {
            _ = LongTextKeyboardTracker.shared
            center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardDidChangeFrame(_:)),
                               name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                               name: UIResponder.keyboardWillHideNotification, object: nil)
        } else {
            center.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            center.removeObserver(self, name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            center.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        #endif
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        LongTextKeyboardTracker.shared.note(notification)
        guard isFirstResponder else { return }
        // Along with the keyboard, so the text doesn't jump ahead of it or behind it.
        let info = notification.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        UIView.animate(withDuration: duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]) {
            self.updateKeyboardInset(followsCaret: true)
        }
    }

    @objc private func keyboardDidChangeFrame(_ notification: Notification) {
        guard isFirstResponder else { return }
        // Once the form has made room for the keyboard: the box moves up out of its way.
        revealBoxAboveKeyboard()
    }

    /// The keyboard's frame in the window, while it's up.
    private var keyboardFrameInWindow: CGRect? {
        #if os(visionOS)
        // Vision Pro's keyboard is a window of its own; it never covers the text.
        return nil
        #else
        guard let frame = LongTextKeyboardTracker.shared.screenFrame, let window,
              let screen = window.windowScene?.screen else { return nil }
        return window.convert(frame, from: screen.coordinateSpace)
        #endif
    }

    /// The part of the view the keyboard covers becomes bottom inset, so the caret scrolls above
    /// it as you type. `followsCaret` also scrolls the caret into view now, for when the keyboard
    /// moves or the box starts editing; never while the person scrolls.
    func updateKeyboardInset(followsCaret: Bool) {
        var overlap: CGFloat = 0
        if isFirstResponder, let keyboard = keyboardFrameInWindow, let window {
            overlap = LongTextKeyboard.overlap(view: convert(bounds, to: window), keyboard: keyboard)
        }
        if abs(contentInset.bottom - overlap) > 0.5 {
            contentInset.bottom = overlap
            verticalScrollIndicatorInsets.bottom = overlap
        }
        if followsCaret, isFirstResponder { scrollCaretToVisible() }
    }

    /// Each step only when the caret is still out of view: TextKit 2 places text it hasn't laid out
    /// by estimate, so a caret far from what's on screen isn't where it says until the text is laid
    /// out; then UIKit's own scroll to the selection; then a scroll to the caret's rect with room.
    private func scrollCaretToVisible() {
        for step in 0..<4 {
            layoutIfNeeded()
            guard let end = selectedTextRange?.end else { return }
            let caret = caretRect(for: end)
            guard !caret.isNull, !caret.isInfinite else { return }
            if caret.minY >= bounds.minY, caret.maxY - 1 <= bounds.maxY - contentInset.bottom { return }
            switch step {
            case 0:
                if let manager = textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
            case 1:
                scrollRangeToVisible(selectedRange)
            default:
                scrollRectToVisible(caret.insetBy(dx: 0, dy: -LongTextKeyboard.caretMargin), animated: false)
            }
        }
    }

    /// A box the keyboard covers scrolls its form up, never past the box's own top. Only when
    /// editing starts or the keyboard moves, never per keystroke: the form and the box never
    /// both chase the caret.
    private func revealBoxAboveKeyboard() {
        guard case .box = layout, isFirstResponder, let keyboard = keyboardFrameInWindow, let window,
              let form = enclosingScrollView else { return }
        let formFrame = form.convert(form.bounds, to: window)
        let visibleTop = formFrame.minY + form.adjustedContentInset.top
        let visibleBottom = min(formFrame.maxY - form.adjustedContentInset.bottom, keyboard.minY)
        let distance = LongTextKeyboard.revealDistance(box: convert(bounds, to: window),
                                                       visibleTop: visibleTop, visibleBottom: visibleBottom)
        guard distance > 0 else { return }
        let bottomOffset = form.contentSize.height + form.adjustedContentInset.bottom - form.bounds.height
        let target = min(form.contentOffset.y + distance, max(bottomOffset, -form.adjustedContentInset.top))
        guard target > form.contentOffset.y + 0.5 else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            form.contentOffset.y = target
        } completion: { [weak self] _ in
            self?.updateKeyboardInset(followsCaret: true)
        }
    }

    private var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }

    private func installKeyboardDoneButton() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard showsKeyboardDoneButton else {
            inputAccessoryView = nil
            return
        }
        // A form's own keyboard bar is SwiftUI's and only shows for SwiftUI fields.
        // The word, in the app's color: iOS 26 draws the system Done item as a check in the
        // system accent instead.
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.tintColor = tintColor
        let title = String(localized: "Done")
        let done = UIBarButtonItem(title: title, image: nil, primaryAction: UIAction(title: title) { [weak self] _ in
            self?.resignFirstResponder()
        }, menu: nil)
        done.accessibilityLabel = String(localized: "Dismiss keyboard")
        bar.items = [.flexibleSpace(), done]
        bar.sizeToFit()
        inputAccessoryView = bar
        #endif
    }
}

/// Where the keyboard is, for every `LongTextView`. One observer for the app, started with the
/// first editor, so an editor that opens while the keyboard is already up knows where it is.
@MainActor
final class LongTextKeyboardTracker: NSObject {
    static let shared = LongTextKeyboardTracker()
    /// In screen coordinates. Nil while the keyboard is away.
    private(set) var screenFrame: CGRect?

    private override init() {
        super.init()
        #if !os(visionOS)
        NotificationCenter.default.addObserver(self, selector: #selector(note(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(note(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        #endif
    }

    /// Also called by each view first, so it never reads a frame from before the same notification.
    @objc func note(_ notification: Notification) {
        #if !os(visionOS)
        if notification.name == UIResponder.keyboardWillHideNotification {
            screenFrame = nil
        } else {
            screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        }
        #endif
    }
}

/// When a box measures its text (`LongTextView.boxHeight`).
enum LongTextBox {
    /// UTF-16 units past which the text is always taller than the box: 1,500 characters fill
    /// more than 260 points at every text size, even on a wide iPad form.
    static let measuredLength = 1_500

    static func height(measured: CGFloat?, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard let measured else { return maximum }
        return min(max(measured.rounded(.up), minimum), maximum)
    }
}

/// Where the keyboard is, for `LongTextView`. All frames in one coordinate space.
enum LongTextKeyboard {
    /// Room kept between the caret or a box and the keyboard.
    static let caretMargin: CGFloat = 8

    /// How much of the bottom of `view` the keyboard covers.
    static func overlap(view: CGRect, keyboard: CGRect?) -> CGFloat {
        guard let keyboard, !keyboard.isEmpty, view.intersects(keyboard) else { return 0 }
        return min(view.height, max(0, view.maxY - keyboard.minY))
    }

    /// How far a form scrolls so a box clears the keyboard: enough for its bottom, never so far
    /// that its top leaves the visible part of the form.
    static func revealDistance(box: CGRect, visibleTop: CGFloat, visibleBottom: CGFloat,
                               margin: CGFloat = caretMargin) -> CGFloat {
        let needed = box.maxY + margin - visibleBottom
        guard needed > 0 else { return 0 }
        let room = box.minY - margin - visibleTop
        return max(0, min(needed, room))
    }
}

/// The smallest replacement that turns one text into another, in UTF-16 units, the way the text
/// view counts. Common text at the start and end stays put, so its layout and the caret do too.
struct LongTextEdit: Equatable {
    /// What to replace, in the old text.
    var range: NSRange
    var replacement: String

    static func difference(from old: String, to new: String) -> LongTextEdit? {
        guard old != new else { return nil }
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        let shorter = min(oldUnits.count, newUnits.count)
        while prefix < shorter, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        // Never cut a character's surrogate pair in two.
        if prefix > 0, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldUnits.count - suffix]) { suffix -= 1 }
        let replaced = Array(newUnits[prefix..<(newUnits.count - suffix)])
        return LongTextEdit(range: NSRange(location: prefix, length: oldUnits.count - suffix - prefix),
                            replacement: String(decoding: replaced, as: UTF16.self))
    }

    /// Where a caret goes after the edit: kept before it, moved with the text after it, and to
    /// the end of the new text when it was inside the replaced part.
    static func selection(_ selection: NSRange, after edit: LongTextEdit) -> NSRange {
        let inserted = (edit.replacement as NSString).length
        let delta = inserted - edit.range.length
        if selection.location >= edit.range.location + edit.range.length {
            return NSRange(location: selection.location + delta, length: selection.length)
        }
        if selection.location + selection.length <= edit.range.location { return selection }
        return NSRange(location: edit.range.location + inserted, length: 0)
    }
}
