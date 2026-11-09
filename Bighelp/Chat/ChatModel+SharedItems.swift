import Foundation
import UniformTypeIdentifiers

/// A share from another app in this chat (`ChatModel.placeShare`).
struct ChatHeldShare: Equatable {
    let share: PendingShare
    /// The draft attachments its files became in this message box.
    var landedIDs: Set<String> = []

    var id: String { share.id }
}

/// A step on a share's way through a chat, for its `ChatShareTracking`. Only `delivered` lets its
/// saved copy go; every other step keeps it.
enum ChatShareEvent: Equatable {
    /// In the message box; nothing sent.
    case inBox
    /// Waiting in the chat for its connection (`stageComposerMessage`). Those messages live only in
    /// memory, so it hasn't gone anywhere yet.
    case staged(messageID: String)
    /// Handed to Hermes in this message.
    case sending(messageID: String)
    /// That send ended without Hermes confirming it: it may have arrived.
    case unconfirmed(messageID: String)
    /// Hermes took the message.
    case delivered
    /// Out of the chat unsent: the person took it out of the message box, or removed its waiting message.
    case removed
    /// The chat closed for another computer or account before it went.
    case retired
}

@MainActor
protocol ChatShareTracking: AnyObject {
    func share(_ id: String, in model: ChatModel, _ event: ChatShareEvent)
}

extension ChatModel {
    enum SharePlacement: Equatable {
        case placed
        /// This chat has it already.
        case alreadyHere
        /// The chat moved on before every file was in; the share is still saved.
        case interrupted
    }

    /// Puts a share in the message box: its words below anything typed, its files through the same
    /// path as Add and a drop (prepared, kept as a big file, or "didn't attach" with why and Try
    /// again). Nothing is sent: the person reviews it and taps Send, and the chat's own rules apply.
    func placeShare(_ share: PendingShare, from inbox: PendingShareInbox,
                    tracker: any ChatShareTracking) async -> SharePlacement {
        guard !holdsShare(share.id) else { return .alreadyHere }
        shareTracker = tracker
        if let updated = PendingShare.draft(draft, adding: share.composerText) { draft = updated }

        let landed = ShareLanding()
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
                landed.ids[index] = attachment.sourceAttachmentID
                return attachment
            }
        }
        let images = share.files.filter { $0.kind == .image }.count
        let kind: DraftAttachmentImportKind = images == share.files.count ? .photos : images == 0 ? .files : .attachments
        await importDraftAttachments(kind, loaders)

        let present = Set(orderedDraftAttachments.map(\.sourceAttachmentID))
        let failed = Set(draftAttachmentFailures.map(\.name))
        let accounted = share.files.indices.allSatisfy { index in
            landed.ids[index].map(present.contains) == true || failed.contains(share.files[index].name)
        }
        guard accounted, !referenceOwnerRetired, !holdsShare(share.id) else { return .interrupted }
        sharesInBox.append(ChatHeldShare(share: share, landedIDs: Set(landed.ids.values)))
        tracker.share(share.id, in: self, .inBox)
        return .placed
    }

    func holdsShare(_ id: String) -> Bool {
        sharesInBox.contains { $0.id == id } || sharesInMessages.values.contains { $0.contains { $0.id == id } }
    }

    // MARK: - Its way out

    /// The box left as message `messageID`: sent, or `staged` to wait for the connection. A share
    /// goes with it while the message still holds any of it; one it holds nothing of was taken out
    /// by the person, and stays saved.
    func sharesLeaveBox(as messageID: String, message: String, attachments: [ChatDraftAttachment], staged: Bool) {
        guard !sharesInBox.isEmpty else { return }
        let attachmentIDs = Set(attachments.map(\.sourceAttachmentID))
        let leaving = sharesInBox
        sharesInBox = []
        for held in leaving {
            if held.share.isCarried(byText: message, attachmentIDs: attachmentIDs, landedIDs: held.landedIDs) {
                sharesInMessages[messageID, default: []].append(held)
                report(held.id, staged ? .staged(messageID: messageID) : .sending(messageID: messageID))
            } else {
                report(held.id, .removed)
            }
        }
    }

    /// A staged message goes to Hermes now, under `newID` when it takes a new row.
    func shareMessageSending(_ messageID: String, as newID: String? = nil) {
        guard let held = sharesInMessages.removeValue(forKey: messageID) else { return }
        let id = newID ?? messageID
        sharesInMessages[id, default: []] += held
        for share in held { report(share.id, .sending(messageID: id)) }
    }

    /// Hermes took the message: its shares' saved copies can go.
    func shareMessageDelivered(_ messageID: String) {
        guard let held = sharesInMessages.removeValue(forKey: messageID) else { return }
        for share in held { report(share.id, .delivered) }
    }

    /// Its send ended without Hermes confirming it. Nothing once it was delivered or went back in the box.
    func shareMessageUnconfirmed(_ messageID: String) {
        guard let held = sharesInMessages.removeValue(forKey: messageID) else { return }
        for share in held { report(share.id, .unconfirmed(messageID: messageID)) }
    }

    /// The person removed the message while it waited (a big file that didn't go).
    func shareMessageRemoved(_ messageID: String) {
        guard let held = sharesInMessages.removeValue(forKey: messageID) else { return }
        for share in held { report(share.id, .removed) }
    }

    /// Messages going back in the box unsent (`putBackInBox`): their shares are in the box again.
    func sharesReturnToBox(from messageIDs: [String]) {
        for messageID in messageIDs {
            guard let held = sharesInMessages.removeValue(forKey: messageID) else { continue }
            sharesInBox += held
            for share in held { report(share.id, .inBox) }
        }
    }

    /// The chat closes for another computer or account (`invalidateReferenceOwnership`). Nothing is
    /// deleted: a share not yet with Hermes is offered again, and one being sent may have arrived.
    func retireShares() {
        let inBox = sharesInBox
        let inMessages = sharesInMessages
        sharesInBox = []
        sharesInMessages = [:]
        for held in inBox { report(held.id, .retired) }
        for (messageID, held) in inMessages {
            let isStaged = stagedSends.contains { $0.id == messageID }
            for share in held { report(share.id, isStaged ? .retired : .unconfirmed(messageID: messageID)) }
        }
    }

    private func report(_ id: String, _ event: ChatShareEvent) {
        shareTracker?.share(id, in: self, event)
    }
}

/// Which draft attachment each of a share's files became.
@MainActor
private final class ShareLanding {
    var ids: [Int: String] = [:]
}
