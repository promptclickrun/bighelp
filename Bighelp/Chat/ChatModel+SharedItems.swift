import Foundation
import UniformTypeIdentifiers

/// Saves each step a chat's shares take (`PendingShareLedger.Effect`), and finds shares a chat no
/// longer knows by the message they went in.
@MainActor
protocol ChatShareTracking: AnyObject {
    /// Throws when a `.sending` step can't be saved: that message must not go to Hermes.
    func apply(_ effects: [PendingShareLedger.Effect], from model: ChatModel) throws
    /// Hermes' history shows this message arrived (a reference message's receipt, read after a relaunch).
    func messageDelivered(conversationID: String, messageID: String)
    /// Shares whose saved copies say the person put them in this chat on computer `scope`, and that
    /// no message took yet: their words may be in the chat's saved draft.
    func sharesPlaced(in conversationID: String, scope: String) -> [PendingShare]
}

extension ChatModel {
    enum SharePlacement: Equatable {
        case placed
        /// This chat has it already.
        case alreadyHere
        /// The chat moved on before every file was in; the share is still saved.
        case interrupted
    }

    /// Whether a message about to go carries shares, and if so the id the client's journal entry
    /// for it binds to (`PendingShareCorrelation`).
    enum ShareDispatch: Equatable {
        case noShares
        case sending(UUID)
        /// Where its shares are going couldn't be saved: it must not go.
        case unsaved

        var id: UUID? {
            if case .sending(let id) = self { return id }
            return nil
        }
    }

    static let unsavedShareMessage = String(localized: "Bighelp couldn't save where your shared items are going, so nothing was sent. Your message is back in the message box.")

    var shareLedger: PendingShareLedger {
        get { shareLedgerStorage ?? PendingShareLedger(conversationID: conversationID) }
        set { shareLedgerStorage = newValue }
    }

    /// Puts a share in the message box: its words below anything typed, its files through the same
    /// path as Add and a drop (prepared, kept as a big file, or "didn't attach" with why and Try
    /// again). Nothing is sent: the person reviews it and taps Send, and the chat's own rules apply.
    func placeShare(_ share: PendingShare, from inbox: PendingShareInbox,
                    tracker: any ChatShareTracking) async -> SharePlacement {
        shareTracker = tracker
        guard shareLedger.beginPlacing(share) else { return .alreadyHere }
        if let updated = PendingShare.draft(draft, adding: share.composerText) { draft = updated }

        let loaders = share.files.enumerated().map { index, file in
            DraftAttachmentLoader(draftNamed: file.name) { @MainActor [weak self] in
                let url = inbox.fileURL(file, in: share)
                let type = UTType(file.typeIdentifier) ?? (file.kind == .image ? .image : .data)
                let read = try await Task.detached(priority: .userInitiated) {
                    try ComposerAttachmentDrop.droppedFile(at: url, type: type, name: file.name,
                                                          mimeType: file.mimeType, copiesBigFile: false)
                }.value
                // The same ID each time, so a share added again after a relaunch never attaches twice.
                let attachment = try await ComposerAttachmentDrop.draftAttachment(
                    from: read, id: "attachment_share_\(share.id)_\(index)", into: self)
                // Here and on every Try again: a big file is a new copy each time.
                self?.shareLedger.fileLanded(shareID: share.id, index: index, attachmentID: attachment.sourceAttachmentID)
                return attachment
            }
        }
        let images = share.files.filter { $0.kind == .image }.count
        let kind: DraftAttachmentImportKind = images == share.files.count ? .photos : images == 0 ? .files : .attachments
        await importDraftAttachments(kind, loaders)

        let present = Set(orderedDraftAttachments.map(\.sourceAttachmentID))
        let failed = Set(draftAttachmentFailures.map(\.name))
        let landed = shareLedger.placing[share.id]?.files ?? [:]
        let accounted = share.files.indices.allSatisfy { index in
            landed[index].map(present.contains) == true || failed.contains(share.files[index].name)
        }
        guard accounted, !referenceOwnerRetired else {
            shareLedger.cancelPlacing(share.id)
            return .interrupted
        }
        applyShareEffects(shareLedger.finishPlacing(share.id))
        return .placed
    }

    /// The chat opened again after a relaunch, its draft back from where it was saved: a share of
    /// words only, put here, that the draft still holds is in the box again, before any Send, so the
    /// message carrying it settles it. A share with files isn't: they were only in memory, and a
    /// message with its words alone would spend them unsent. It stays listed for Open, which brings
    /// every file back.
    func restoreSharesInBox(scope: String?) {
        guard let scope, let shareTracker, !referenceOwnerRetired else { return }
        for share in shareTracker.sharesPlaced(in: conversationID, scope: scope) where share.files.isEmpty {
            guard share.isCarried(byText: draft, attachmentIDs: [], landedIDs: []),
                  shareLedger.beginPlacing(share) else { continue }
            applyShareEffects(shareLedger.finishPlacing(share.id))
        }
    }

    func holdsShare(_ id: String) -> Bool { shareLedgerStorage?.holds(id) == true }

    func carriesShares(_ messageID: String) -> Bool { shareLedgerStorage?.message(row: messageID) != nil }

    // MARK: - The box

    /// After the person changed the box (took a file or a failed file out, or edited its text and
    /// paused): a share it holds nothing of now is out of this chat, kept and listed. Not while
    /// files are still being read in, since a retry or an import clears the box for a moment.
    func reviewSharesInBox() {
        guard shareLedgerStorage?.inBox.isEmpty == false, draftAttachmentImport == nil,
              !isReplacingReferenceDraft else { return }
        applyShareEffects(shareLedger.reviewBox(
            text: draft, attachmentIDs: Set(orderedDraftAttachments.map(\.sourceAttachmentID)),
            failedNames: Set(draftAttachmentFailures.map(\.name))))
    }

    func scheduleShareBoxReview() {
        shareBoxReview?.cancel()
        let delay = shareBoxReviewDelay
        shareBoxReview = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.reviewSharesInBox()
        }
    }

    // MARK: - Its way out

    /// The box left as message `messageID`: sent, staged, or waiting on its files. A share goes
    /// with it while the message still holds any of it; one it holds nothing of stays saved.
    func sharesLeaveBox(as messageID: String, message: String, attachments: [ChatDraftAttachment]) {
        guard shareLedgerStorage?.inBox.isEmpty == false else { return }
        applyShareEffects(shareLedger.leaveBox(as: messageID, text: message,
                                               attachmentIDs: Set(attachments.map(\.sourceAttachmentID)), now: .now))
    }

    /// Right before message `messageID` goes to Hermes: saves that its shares are being sent. When
    /// that can't be saved, the caller puts the message back in the box instead of sending it.
    func dispatchShares(_ messageID: String) -> ShareDispatch {
        let effects = shareLedger.dispatch(messageID, now: .now)
        guard !effects.isEmpty, let id = shareLedger.message(row: messageID)?.id else { return .noShares }
        guard let shareTracker else { return .unsaved }
        do {
            try shareTracker.apply(effects, from: self)
            return .sending(id)
        } catch {
            return .unsaved
        }
    }

    /// A staged message took a new row as it went.
    func shareMessageRenamed(_ messageID: String, to newID: String) {
        shareLedger.rename(messageID, to: newID)
    }

    /// Hermes took the message: from the client's journal entry it was recorded as (it admits only
    /// that entry), or the send that returned.
    func shareMessageAdmitted(_ id: UUID) {
        applyShareEffects(shareLedger.admitted(id, now: .now))
    }

    /// Hermes took the message with this row: a send that returned, or its history (a reference's
    /// receipt). One this chat doesn't know (bighelp opened again since) is found by its saved row.
    func shareMessageAdmitted(row messageID: String) {
        let effects = shareLedger.admitted(row: messageID, now: .now)
        if effects.isEmpty {
            shareTracker?.messageDelivered(conversationID: conversationID, messageID: messageID)
        } else {
            applyShareEffects(effects)
        }
    }

    /// Hermes definitely didn't take it, and it isn't back in the box: kept, not sent.
    func shareMessageRefused(row messageID: String) {
        applyShareEffects(shareLedger.refused(row: messageID))
    }

    /// Its send ended without an answer either way. Nothing once it was settled.
    func shareMessageUnknown(row messageID: String) {
        applyShareEffects(shareLedger.unknown(row: messageID, now: .now))
    }

    /// Its files didn't go, and it waits in the chat for Try again.
    func shareMessageWaits(row messageID: String) {
        applyShareEffects(shareLedger.waits(row: messageID, now: .now))
    }

    /// The person removed it while it waited.
    func shareMessageRemoved(row messageID: String) {
        applyShareEffects(shareLedger.removed(row: messageID))
    }

    /// Messages going back in the box unsent (`putBackInBox`): their shares are in the box again.
    func sharesReturnToBox(from messageIDs: [String]) {
        applyShareEffects(shareLedger.returnToBox(messageIDs))
    }

    /// The chat closes for another computer or account (`invalidateReferenceOwnership`). Nothing is
    /// deleted: a share not yet with Hermes is offered again, and one being sent may have arrived.
    func retireShares() {
        shareBoxReview?.cancel()
        guard shareLedgerStorage != nil else { return }
        applyShareEffects(shareLedger.retire(now: .now))
    }

    /// A share-carrying message that definitely didn't go goes back in the box with its shares,
    /// rather than to Try again, which would send it without them.
    func putShareMessageBack(_ humanID: String, message: String, attachments: [ChatAttachment],
                             orderedAttachments: [ChatDraftAttachment]) {
        removeItem(id: humanID)
        removeProjectedMessage(id: humanID)
        nativeConversationClient?.retainVisibleState()
        putBackInBox(message, attachments: attachments, orderedAttachments: orderedAttachments, returning: humanID)
        retryRequest = nil
    }

    private func applyShareEffects(_ effects: [PendingShareLedger.Effect]) {
        guard !effects.isEmpty else { return }
        // Only `.sending` steps must be saved (`dispatchShares`); the others are saved as they can be.
        try? shareTracker?.apply(effects, from: self)
    }
}
