import Foundation
import UniformTypeIdentifiers

/// A share from another app in this chat's message box, until its words and files leave it.
struct ChatHeldShare {
    let id: String
    /// Every file attached, or showing as "didn't attach" with why.
    var isInBox = false
    let settle: @MainActor (String) -> Void
}

extension ChatModel {
    enum SharePlacement: Equatable {
        case placed
        /// This message box has it already.
        case alreadyHere
        /// The chat moved on before every file was in; the share is still saved.
        case interrupted
    }

    /// Puts a share in the message box: its words below anything typed, its files through the same
    /// path as Add and a drop (prepared, kept as a big file, or "didn't attach" with why and Try
    /// again). Nothing is sent: the person reviews it and taps Send, and the chat's own rules apply.
    /// Its saved copy is deleted only once the box empties after holding it (`settle`).
    func placeShare(_ share: PendingShare, from inbox: PendingShareInbox,
                    settle: @escaping @MainActor (String) -> Void) async -> SharePlacement {
        guard !heldShares.contains(where: { $0.id == share.id }) else { return .alreadyHere }
        heldShares.append(ChatHeldShare(id: share.id, settle: settle))
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
        guard accounted, let index = heldShares.firstIndex(where: { $0.id == share.id }) else {
            heldShares.removeAll { $0.id == share.id }
            return .interrupted
        }
        heldShares[index].isInBox = true
        releaseHeldSharesIfBoxIsEmpty()
        return .placed
    }

    /// The box is empty after holding a share: it was sent, or the person removed it there. Either
    /// way it has left the share's saved copy behind, which can go now.
    func releaseHeldSharesIfBoxIsEmpty() {
        guard !heldShares.isEmpty, draft.isEmpty, orderedDraftAttachments.isEmpty,
              draftAttachmentImport == nil, draftAttachmentFailures.isEmpty else { return }
        let released = heldShares.filter(\.isInBox)
        guard !released.isEmpty else { return }
        heldShares.removeAll(where: \.isInBox)
        for share in released { share.settle(share.id) }
    }
}

/// Which draft attachment each of a share's files became.
@MainActor
private final class ShareLanding {
    var ids: [Int: String] = [:]
}
