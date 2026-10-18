import SwiftUI
import UIKit

/// Keeps the same UIKit text control, selection and native undo manager while
/// moving between compact and expanded source containers. Not a second draft.
@MainActor
final class ReferenceComposerEditorSession {
    fileprivate var textView: ClipboardPasteTextView?
    fileprivate var coordinator: ReferenceComposerTextView.Coordinator?

    func prepareForSurfaceTransfer() {
        coordinator?.preserveSelectionForSurfaceTransfer()
    }

    func dismissKeyboard() {
        coordinator?.discardTransferredSelection()
        coordinator?.cancelFocusRestoration()
        textView?.resignFirstResponder()
    }
}

final class ReferenceComposerContainer: UIView {
    weak var coordinator: ReferenceComposerTextView.Coordinator?
    private var lastViewportSize: CGSize?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // A SwiftUI update can request focus before a sheet has a window.
        // Attachment retries that request without changing its current owner.
        coordinator?.scheduleSynchronization(in: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let textView = subviews.first as? UITextView else { return }
        let previousSize = lastViewportSize
        lastViewportSize = bounds.size
        textView.frame = bounds
        if previousSize != bounds.size, bounds.width > 0, bounds.height > 0, textView.isFirstResponder,
           !textView.isTracking, !textView.isDragging, !textView.isDecelerating {
            textView.layoutIfNeeded()
            if let selection = textView.selectedTextRange {
                textView.scrollRectToVisible(textView.caretRect(for: selection.end), animated: false)
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// While Skills & commands is open, ↑ ↓ move through it and Esc closes it,
    /// and the message box keeps the keyboard. The text view is first
    /// responder and this container is next in line, so these reach here.
    override var keyCommands: [UIKeyCommand]? {
        guard let coordinator, coordinator.host === self, coordinator.isSurfaceActive,
              coordinator.view?.markedTextRange == nil, coordinator.parent.hub.isPresented else {
            return super.keyCommands
        }
        var commands = [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeReferenceDrawer))]
        if coordinator.parent.hub.keyboard.hasRows {
            commands += [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(highlightPreviousReference)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(highlightNextReference)),
            ]
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func highlightPreviousReference() { coordinator?.parent.hub.keyboard.move(by: -1) }
    @objc private func highlightNextReference() { coordinator?.parent.hub.keyboard.move(by: 1) }
    @objc private func closeReferenceDrawer() {
        guard let hub = coordinator?.parent.hub, !hub.keyboard.back() else { return }
        hub.dismiss()
    }
    #endif
}

/// UIKit owns live source and caret. Only explicit native transactions or a new
/// external binding value may replace text; stale binding echoes never do.
struct ReferenceComposerTextView: UIViewRepresentable {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Binding var text: String
    let hub: ReferenceHubStore
    let session: ReferenceComposerEditorSession
    let focus: Binding<Bool>
    let isEnabled: Bool
    var isSurfaceActive = true
    var viewportHeight: CGFloat?
    var expanded = false
    var onPasteImageProviders: (([NSItemProvider]) -> Void)?
    /// Hardware Return keys (`ComposerReturnKeyHandling`). True means handled.
    var onReturnKey: ((ComposerReturnKey) -> Bool)?
    var onSelectionChange: (Int?) -> Void = { _ in }
    var onExpansionAvailabilityChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        if let coordinator = session.coordinator { return coordinator }
        let coordinator = Coordinator(parent: self)
        session.coordinator = coordinator
        return coordinator
    }

    func makeUIView(context: Context) -> ReferenceComposerContainer {
        let container = ReferenceComposerContainer()
        container.clipsToBounds = true
        container.coordinator = context.coordinator
        guard session.textView == nil else { return container }
        let view = ClipboardPasteTextView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.font = UIFont.bighelp(.body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainer.heightTracksTextView = false
        view.alwaysBounceHorizontal = false
        view.showsHorizontalScrollIndicator = false
        view.isScrollEnabled = true
        #if !os(visionOS)
        view.keyboardDismissMode = .none
        #endif
        view.autocorrectionType = .default
        view.autocapitalizationType = .sentences
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.text = text
        view.selectedRange = Data(hub.source.utf8) == Data(text.utf8)
            ? context.coordinator.clamp(hub.selection, in: text)
            : NSRange(location: text.utf16.count, length: 0)
        context.coordinator.view = view
        session.textView = view
        view.delegate = context.coordinator
        return container
    }

    func updateUIView(_ container: ReferenceComposerContainer, context: Context) {
        context.coordinator.updateSurface(self, in: container)
    }

    static func dismantleUIView(_ container: ReferenceComposerContainer, coordinator: Coordinator) {
        coordinator.retireSurface(container)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView container: ReferenceComposerContainer, context: Context) -> CGSize? {
        guard let uiView = session.textView, let width = proposal.width, width > 0 else { return nil }
        if expanded, let height = proposal.height { return CGSize(width: width, height: height) }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? UIFont.bighelp(.body).lineHeight
        // Wrapped onto a second line (one line plus the editor's insets stays under two line heights):
        // the expand button shows beside the box from there.
        let overflowing = DraftFieldSizing.shouldOfferExpandedEditor(hasText: !uiView.text.isEmpty,
            measuredHeight: measured.height, lineHeight: lineHeight, thresholdLines: 2)
        if isSurfaceActive { context.coordinator.reportOverflow(overflowing) }
        // A compact editor has a real native viewport, not merely a clipped
        // SwiftUI frame. Keep enough room for UIKit's caret and line leading.
        return CGSize(width: width, height: viewportHeight ?? DraftFieldSizing.height(
            measuredHeight: measured.height, lineHeight: lineHeight
        ))
    }

    // Deliberately excludes session: session owns the coordinator, so retaining
    // the representable here would form a cycle containing private source.
    private var configuration: Configuration {
        Configuration(text: $text, hub: hub, focus: focus,
            onSelectionChange: onSelectionChange,
            onExpansionAvailabilityChange: onExpansionAvailabilityChange)
    }

    struct Configuration {
        @Binding var text: String
        let hub: ReferenceHubStore
        let focus: Binding<Bool>
        let onSelectionChange: (Int?) -> Void
        let onExpansionAvailabilityChange: (Bool) -> Void
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let id = UUID()
        var parent: Configuration
        weak var view: ClipboardPasteTextView?
        weak var host: ReferenceComposerContainer?
        var isSurfaceActive = false
        private var applying = false
        private var lastBound: Data
        private var lastPublished: Data
        private var ownedDraft: UUID
        private var lastOverflow: Bool?
        private var scrollGeneration: UInt64 = 0
        private var transferringSurface = false
        private var restoreFocusAfterTransfer = false
        private var focusRequestPending: Bool
        private var lastObservedFocusRequest: Bool
        private var lastObservedExpandedSurface: Bool
        private var synchronizationGeneration: UInt64 = 0
        private var lastPublishedSelection: NSRange?
        private var lastPublishedMarkedText = false
        private struct SurfaceSelection {
            let source: Data
            let draftID: UUID
            let revision: UInt64
            let range: NSRange
            let origin: ObjectIdentifier
        }
        private var transferredSelection: SurfaceSelection?
        private struct SurfaceUpdate {
            let configuration: Configuration
            let theme: BighelpTheme
            let isEnabled: Bool
            let expanded: Bool
            let onPasteImageProviders: (([NSItemProvider]) -> Void)?
            let onReturnKey: ((ComposerReturnKey) -> Bool)?
        }
        private weak var requestedHost: ReferenceComposerContainer?
        private var pendingSurfaceUpdate: SurfaceUpdate?
        private var surfaceUpdateScheduled = false

        func updateSurface(_ surface: ReferenceComposerTextView, in container: ReferenceComposerContainer) {
            guard surface.session.textView != nil else { return }
            guard surface.isSurfaceActive else {
                scheduleDeactivation(in: container)
                return
            }
            let wantsFocus = surface.focus.wrappedValue
            let changedEditorSurface = surface.expanded != lastObservedExpandedSurface
            let pendingFocus = focusRequestPending || (wantsFocus && (!lastObservedFocusRequest || changedEditorSurface))
            lastObservedFocusRequest = wantsFocus
            lastObservedExpandedSurface = surface.expanded
            if host !== container {
                preserveSelectionForSurfaceTransfer()
                // The old surface stops admitting edits immediately, but UIKit
                // must not resign/reparent its responder during SwiftUI update.
                isSurfaceActive = false
                cancelFocusRestoration()
                view?.delegate = nil
            } else if !surface.isEnabled || parent.hub !== surface.hub {
                isSurfaceActive = false
                cancelFocusRestoration()
            }
            focusRequestPending = wantsFocus && pendingFocus
            requestedHost = container
            pendingSurfaceUpdate = SurfaceUpdate(configuration: surface.configuration,
                theme: BighelpTheme.resolve(appearance: surface.appearance, colorScheme: surface.colorScheme, contrast: surface.contrast),
                isEnabled: surface.isEnabled, expanded: surface.expanded,
                onPasteImageProviders: surface.onPasteImageProviders, onReturnKey: surface.onReturnKey)
            guard !surfaceUpdateScheduled else { return }
            surfaceUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.surfaceUpdateScheduled = false
                let container = self.requestedHost
                let update = self.pendingSurfaceUpdate
                self.requestedHost = nil
                self.pendingSurfaceUpdate = nil
                guard let container, let update else { return }
                self.applySurface(update, in: container)
            }
        }

        private func applySurface(_ update: SurfaceUpdate, in container: ReferenceComposerContainer) {
            guard let view else { return }
            view.delegate = nil
            defer { view.delegate = self }
            if parent.hub !== update.configuration.hub { scheduleHubDetachment(parent.hub) }
            parent = update.configuration
            isSurfaceActive = true
            if host !== container {
                detachForSurfaceTransfer()
                container.addSubview(view)
                view.frame = container.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host = container
            }
            if view.isEditable != update.isEnabled { view.isEditable = update.isEnabled }
            let font = update.theme.uiFont(.body, compatibleWith: view.traitCollection)
            if view.font != font { view.font = font }
            // The theme's ink, set on the view so it covers every character,
            // including text placed by the app (Ask, Create a goal…).
            let ink = UIColor(update.theme.primaryText)
            if view.textColor != ink { view.textColor = ink }
            view.isClipboardImagePasteEnabled = update.isEnabled && update.onPasteImageProviders != nil
            view.onPasteImageProviders = update.onPasteImageProviders
            view.onReturnKey = update.onReturnKey
            view.accessibilityLabel = update.expanded ? "Expanded message" : "Message"
            view.accessibilityIdentifier = update.expanded ? "chat.composer.expanded.text" : "chat.composer.text"
            view.accessibilityHint = "Markdown source. Type slash to find references, skills and commands."
            scheduleSynchronization(in: container)
        }

        func retireSurface(_ container: ReferenceComposerContainer) {
            // A disappearing compact host must not cancel the expanded host
            // that already owns the next queued mount (and vice versa).
            if let requestedHost, requestedHost !== container { return }
            if requestedHost === container {
                requestedHost = nil
                pendingSurfaceUpdate = nil
            }
            guard host === container else { return }
            isSurfaceActive = false
            host = nil
            discardTransferredSelection()
            scheduleHubDetachment(parent.hub)
            view?.onPasteImageProviders = nil
            view?.onReturnKey = nil
            view?.isClipboardImagePasteEnabled = false
            cancelFocusRestoration()
            view?.delegate = nil
            DispatchQueue.main.async { [weak self, weak container, weak view] in
                guard let container, let view, view.superview === container,
                      self?.host == nil, self?.requestedHost == nil else { return }
                view.resignFirstResponder()
                view.removeFromSuperview()
            }
        }

        func preserveSelectionForSurfaceTransfer() {
            guard let view, let host, view.markedTextRange == nil,
                  ownedDraft == parent.hub.draftID else {
                transferredSelection = nil
                return
            }
            transferredSelection = SurfaceSelection(source: Data(view.text.utf8),
                draftID: parent.hub.draftID, revision: parent.hub.revision,
                range: view.selectedRange, origin: ObjectIdentifier(host))
        }

        func discardTransferredSelection() {
            transferredSelection = nil
        }

        func cancelFocusRestoration() {
            synchronizationGeneration &+= 1
            restoreFocusAfterTransfer = false
            focusRequestPending = false
        }

        func scheduleHubDetachment(_ hub: ReferenceHubStore) {
            let editorID = id
            DispatchQueue.main.async { [weak self, weak hub] in
                guard let hub else { return }
                if let self, self.parent.hub === hub, self.host != nil || self.requestedHost != nil { return }
                hub.detachEditor(id: editorID)
            }
        }

        func scheduleDeactivation(in container: ReferenceComposerContainer) {
            if let requestedHost, requestedHost !== container { return }
            if requestedHost === container {
                requestedHost = nil
                pendingSurfaceUpdate = nil
            }
            guard host === container else { return }
            // Revoke attachment retries immediately, before deferred publication.
            isSurfaceActive = false
            synchronizationGeneration &+= 1
            let token = synchronizationGeneration
            DispatchQueue.main.async { [weak self, weak container] in
                guard let self, let container, self.host === container,
                      self.requestedHost == nil,
                      self.synchronizationGeneration == token else { return }
                self.deactivate()
            }
        }

        func deactivate() {
            isSurfaceActive = false
            cancelFocusRestoration()
            view?.resignFirstResponder()
            parent.hub.detachEditor(id: id)
        }

        func scheduleSynchronization(in container: ReferenceComposerContainer) {
            guard host === container, isSurfaceActive else { return }
            synchronizationGeneration &+= 1
            let token = synchronizationGeneration
            DispatchQueue.main.async { [weak self, weak container] in
                guard let self, let container, self.host === container,
                      self.isSurfaceActive, self.synchronizationGeneration == token,
                      let view = self.view else { return }
                self.synchronizeExternal(self.parent.text)
                let selection = self.transferredSelection.flatMap { saved -> SurfaceSelection? in
                    guard saved.origin != ObjectIdentifier(container) else { return nil }
                    guard saved.draftID == self.parent.hub.draftID,
                          saved.draftID == self.ownedDraft,
                          saved.revision == self.parent.hub.revision,
                          view.markedTextRange == nil,
                          saved.source == Data(view.text.utf8),
                          saved.source == Data(self.parent.text.utf8) else {
                        self.transferredSelection = nil
                        return nil
                    }
                    return saved
                }
                if !self.parent.focus.wrappedValue || !view.isEditable {
                    self.restoreFocusAfterTransfer = false
                    self.focusRequestPending = false
                    if !view.isEditable, self.parent.focus.wrappedValue {
                        self.parent.focus.wrappedValue = false
                    }
                    if view.isFirstResponder { view.resignFirstResponder() }
                    self.parent.hub.setEditorActive(false)
                } else if view.window != nil, !view.isFirstResponder,
                          self.focusRequestPending || self.restoreFocusAfterTransfer {
                    // Publish the restored caret after UIKit finishes becoming
                    // first responder, rather than an intermediate selection.
                    if let selection {
                        view.delegate = nil
                        view.selectedRange = self.clamp(selection.range, in: view.text)
                    }
                    let restored = view.becomeFirstResponder()
                    view.delegate = self
                    if restored {
                        self.focusRequestPending = false
                        self.restoreFocusAfterTransfer = false
                    }
                }
                if view.isFirstResponder, let selection,
                   selection.draftID == self.parent.hub.draftID,
                   selection.revision == self.parent.hub.revision,
                   selection.source == Data(view.text.utf8),
                   selection.source == Data(self.parent.text.utf8) {
                    self.applying = true
                    view.selectedRange = self.clamp(selection.range, in: view.text)
                    self.applying = false
                    self.transferredSelection = nil
                    self.activate()
                }
                if view.isFirstResponder, !self.parent.hub.isEditorActive { self.activate() }
            }
        }

        func detachForSurfaceTransfer() {
            if transferredSelection == nil { preserveSelectionForSurfaceTransfer() }
            restoreFocusAfterTransfer = restoreFocusAfterTransfer || view?.isFirstResponder == true
            transferringSurface = true
            view?.removeFromSuperview()
            transferringSurface = false
        }

        init(parent: ReferenceComposerTextView) {
            self.parent = parent.configuration
            focusRequestPending = parent.focus.wrappedValue
            lastObservedFocusRequest = parent.focus.wrappedValue
            lastObservedExpandedSurface = parent.expanded
            lastBound = Data(parent.text.utf8)
            lastPublished = lastBound
            ownedDraft = parent.hub.draftID
        }

        func clamp(_ range: NSRange, in text: String) -> NSRange {
            let location = min(max(0, range.location), text.utf16.count)
            return NSRange(location: location, length: min(max(0, range.length), text.utf16.count - location))
        }

        func synchronizeExternal(_ text: String) {
            guard let view else { return }
            let incoming = Data(text.utf8)
            let boundary = ownedDraft != parent.hub.draftID
            if boundary {
                // An authority boundary retires even an unfinished IME draft.
                applying = true
                view.unmarkText()
                applying = false
                ownedDraft = parent.hub.draftID
                view.undoManager?.removeAllActions()
            }
            guard view.markedTextRange == nil else { return }
            defer { lastBound = incoming }
            // A reset is authoritative; otherwise distinguish a genuine external
            // value from the last bound value and the newest UIKit publication.
            guard boundary || (incoming != lastBound && incoming != lastPublished) else { return }
            guard incoming != Data(view.text.utf8) else { return }
            applying = true
            let oldCaret = view.selectedRange
            let replacement = Self.difference(from: view.text, to: text)
            view.textStorage.replaceCharacters(in: replacement.range, with: Self.styled(replacement.text, in: view))
            let end = replacement.range.location + replacement.range.length
            let movedCaret = oldCaret.location >= end
                ? oldCaret.location + replacement.text.utf16.count - replacement.range.length
                : oldCaret.location > replacement.range.location
                    ? replacement.range.location + replacement.text.utf16.count : oldCaret.location
            view.selectedRange = clamp(NSRange(location: movedCaret, length: 0), in: text)
            // External replacements do not retain native undo into a retired
            // draft. Mention insertion also uses this path without moving to end.
            view.undoManager?.removeAllActions()
            applying = false
            lastPublished = incoming
            publish()
        }

        func activate() {
            guard let view, view.isFirstResponder else { return }
            let attachedHub = parent.hub
            attachedHub.attachEditor(id: id) { [weak self, weak attachedHub] edit in
                guard let self, let attachedHub, self.parent.hub === attachedHub else { return false }
                return self.apply(edit)
            }
            parent.hub.setEditorActive(true)
            publish(force: true)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            focusRequestPending = false
            lastObservedFocusRequest = true
            parent.focus.wrappedValue = true
            activate()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !transferringSurface, requestedHost == nil else { return }
            cancelFocusRestoration()
            lastObservedFocusRequest = false
            parent.focus.wrappedValue = false
            // Keep the mounted edit target available for chip removal when the
            // keyboard is closed; dismantle/authority changes revoke it.
            parent.hub.setEditorActive(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !applying else { return }
            publish()
            keepCaretVisible()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying, textView.isFirstResponder else { return }
            publish()
        }

        /// Change traits only, never text/selection or responder ownership. IME
        /// composition keeps its current keyboard until UIKit commits it.
        private func updateKeyboardTraits() {
            guard let view, view.markedTextRange == nil else { return }
            let literal = ReferenceQueryContext.parse(source: view.text, selection: view.selectedRange) != nil
                || ReferenceSourceSyntax.isSuppressed(at: view.selectedRange.location, in: Array(view.text.utf16))
            let correction: UITextAutocorrectionType = literal ? .no : .default
            let capitalization: UITextAutocapitalizationType = literal ? .none : .sentences
            let spelling: UITextSpellCheckingType = literal ? .no : .default
            if view.autocorrectionType != correction { view.autocorrectionType = correction }
            if view.autocapitalizationType != capitalization { view.autocapitalizationType = capitalization }
            if view.spellCheckingType != spelling { view.spellCheckingType = spelling }
        }

        private func publish(selections: [ReferenceDraftSelection]? = nil, force: Bool = false) {
            guard let view, !applying else { return }
            updateKeyboardTraits()
            let bytes = Data(view.text.utf8)
            let marked = view.markedTextRange != nil
            let restoring = view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true
            guard force || bytes != lastPublished || view.selectedRange != lastPublishedSelection
                    || marked != lastPublishedMarkedText || selections != nil || restoring
                    || Data(parent.hub.source.utf8) != bytes
                    || parent.hub.selection != view.selectedRange else { return }
            lastPublished = bytes
            lastPublishedSelection = view.selectedRange
            lastPublishedMarkedText = marked
            if Data(parent.text.utf8) != lastPublished { parent.text = view.text }
            parent.hub.receive(source: view.text, selection: view.selectedRange,
                hasMarkedText: marked, selections: selections,
                restoreArchivedSelections: restoring)
            parent.onSelectionChange(DraftCaretSelection.characterOffset(in: view.text, selectedRange: view.selectedRange))
            view.invalidateIntrinsicContentSize()
        }

        private func apply(_ edit: ReferenceNativeEdit) -> Bool {
            guard isSurfaceActive, let view, host != nil, view.isEditable, view.markedTextRange == nil,
                  ownedDraft == edit.draftID, parent.hub.draftID == edit.draftID, parent.hub.revision == edit.revision,
                  Data(view.text.utf8) == Data(edit.source.utf8), view.selectedRange == edit.selection,
                  ReferenceSourceSyntax.valid(edit.range, in: Array(view.text.utf16)) else { return false }
            if !view.isFirstResponder { view.becomeFirstResponder() }
            replace(range: edit.range, with: edit.replacement, selection: edit.resultingSelection,
                    selections: edit.selections, name: edit.actionName, draftID: edit.draftID)
            return true
        }

        /// Direct text-storage range mutation avoids UIKit's second undo action.
        /// Register an inverse on the real native manager so selection plus chip
        /// metadata round-trip together in one user-visible Undo/Redo step.
        private func replace(range: NSRange, with replacement: String, selection: NSRange,
                             selections: [ReferenceDraftSelection], name: String, draftID: UUID) {
            guard let view, parent.hub.draftID == draftID, view.markedTextRange == nil,
                  ReferenceSourceSyntax.valid(range, in: Array(view.text.utf16)) else { return }
            let removed = (view.text as NSString).substring(with: range)
            let previousSelection = view.selectedRange
            let previousReferences = parent.hub.selected
            let inverseRange = NSRange(location: range.location, length: replacement.utf16.count)
            let undo = view.undoManager
            undo?.registerUndo(withTarget: self) { target in
                target.replace(range: inverseRange, with: removed, selection: previousSelection,
                    selections: previousReferences, name: name, draftID: draftID)
            }
            undo?.setActionName(name)
            applying = true
            let disabledHere = undo?.isUndoRegistrationEnabled == true
            if disabledHere { undo?.disableUndoRegistration() }
            view.textStorage.replaceCharacters(in: range, with: Self.styled(replacement, in: view))
            view.selectedRange = clamp(selection, in: view.text)
            if disabledHere, undo?.isUndoRegistrationEnabled == false { undo?.enableUndoRegistration() }
            applying = false
            publish(selections: selections)
            keepCaretVisible()
        }

        /// Text placed into storage directly carries no attributes of its own,
        /// which UIKit draws black and which the next typed letters inherit.
        static func styled(_ text: String, in view: UITextView) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: view.font ?? UIFont.bighelp(.body),
                .foregroundColor: view.textColor ?? .label,
            ])
        }

        private static func difference(from old: String, to new: String) -> (range: NSRange, text: String) {
            let before = Array(old.utf16), after = Array(new.utf16)
            var start = 0
            while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
            // Back off a split surrogate boundary.
            if start > 0, start < before.count, (0xDC00...0xDFFF).contains(before[start]) { start -= 1 }
            var oldEnd = before.count, newEnd = after.count
            while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] {
                oldEnd -= 1
                newEnd -= 1
            }
            if oldEnd < before.count, oldEnd > start, (0xDC00...0xDFFF).contains(before[oldEnd]) {
                oldEnd += 1
                newEnd += 1
            }
            return (NSRange(location: start, length: oldEnd - start), String(decoding: after[start..<newEnd], as: UTF16.self))
        }

        private func keepCaretVisible() {
            scrollGeneration &+= 1
            let token = scrollGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scrollGeneration == token, let view = self.view else { return }
                view.scrollRangeToVisible(view.selectedRange)
            }
        }

        func reportOverflow(_ value: Bool) {
            guard lastOverflow != value else { return }
            lastOverflow = value
            DispatchQueue.main.async { [weak self] in self?.parent.onExpansionAvailabilityChange(value) }
        }
    }
}