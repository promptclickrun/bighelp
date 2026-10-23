import Foundation
import UIKit
import UniformTypeIdentifiers

/// Photos and files dropped on a message box become draft attachments.
///
/// The text view keeps dropping text (a selection, a link) native. Anything else
/// it would have pasted as text (a dropped .txt file's contents) or refused
/// outright (a photo, a PDF): its text drop cancels those, and UIKit hands the
/// drop to this interaction on the same view, which passes the providers on.
/// Owned by the text view (`lazy var attachmentDrop`), which keeps it alive.
@MainActor
final class ComposerAttachmentDropTarget: NSObject, UIDropInteractionDelegate, UITextDropDelegate {
    /// Receives the dropped photos and files. Nil leaves every drop to the text view.
    var onDropProviders: (([NSItemProvider]) -> Void)?
    private weak var textView: UITextView?

    init(textView: UITextView) {
        self.textView = textView
        super.init()
        textView.textDropDelegate = self
        textView.addInteraction(UIDropInteraction(delegate: self))
    }

    private func accepts(_ session: any UIDropSession) -> Bool {
        guard onDropProviders != nil, let textView, textView.isEditable, textView.window != nil else { return false }
        return ComposerAttachmentDrop.isAttachmentDrop(session.items.map(\.itemProvider))
    }

    func textDroppableView(
        _ textDroppableView: UIView & UITextDroppable,
        proposalForDrop drop: any UITextDropRequest
    ) -> UITextDropProposal {
        accepts(drop.dropSession) ? UITextDropProposal(operation: .cancel) : drop.suggestedProposal
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        accepts(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: accepts(session) ? .copy : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard accepts(session), let onDropProviders else { return }
        onDropProviders(session.items.map(\.itemProvider))
    }
}

/// Turns dropped item providers into draft attachment loaders.
enum ComposerAttachmentDrop {
    /// One drop adds at most this many, like pasting images.
    static let maximumItems = 10

    /// True when the drag holds a photo or file, not just text or a link.
    static func isAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
        providers.contains(where: isAttachment)
    }

    /// Dragged text and links offer the plain-text and URL types that strings
    /// and URLs write. A file offers its own type instead: a .txt file arrives
    /// as `public.plain-text` and never as `public.utf8-plain-text`.
    static func isAttachment(_ provider: NSItemProvider) -> Bool {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard !types.isEmpty else { return false }
        if types.contains(where: { $0.conforms(to: .image) }) { return true }
        return !types.contains { type in
            type == .utf8PlainText || type == .utf16PlainText
                || (type.conforms(to: .url) && !type.conforms(to: .fileURL))
        }
    }

    /// Starts reading every dropped photo and file at once: a drag's data is only
    /// promised around the drop, and the draft adds attachments one at a time.
    /// Text and links in the same drag are left out; past `maximumItems`, each
    /// extra item stays as one that didn't attach.
    @MainActor
    static func imports(from providers: [NSItemProvider]) -> (kind: DraftAttachmentImportKind, loaders: [DraftAttachmentLoader]) {
        let dropped = providers.filter(isAttachment)
        let images = dropped.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        let kind: DraftAttachmentImportKind = images.count == dropped.count ? .photos
            : images.isEmpty ? .files : .attachments
        let loaders = dropped.enumerated().map { index, provider -> DraftAttachmentLoader in
            guard index < maximumItems else {
                return DraftAttachmentLoader(name: provider.suggestedName) { throw ChatAttachmentError.tooMany }
            }
            let read = Task { try await readFile(from: provider) }
            return DraftAttachmentLoader(name: provider.suggestedName) {
                let file = try await read.value
                return try ChatAttachmentPreparer().prepare(
                    id: "attachment_\(UUID().uuidString.lowercased())",
                    fileName: file.name,
                    mimeType: file.mimeType,
                    data: file.data
                )
            }
        }
        return (kind, loaders)
    }

    struct DroppedFile: Sendable {
        let name: String
        let mimeType: String
        let data: Data
    }

    /// Photos read in their best non-TIFF image type (TIFF converts when nothing
    /// else is offered); other files in the type they were dragged as. The file
    /// UIKit hands over keeps the dragged item's name and is gone after the callback.
    /// Starts on the main actor with the drop's provider; UIKit reads on its own queue.
    @MainActor
    static func readFile(from provider: NSItemProvider) async throws -> DroppedFile {
        let registered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let images = registered.filter { $0.conforms(to: .image) }
        guard let type = images.first(where: { !$0.conforms(to: .tiff) }) ?? images.first ?? registered.first else {
            throw ChatAttachmentError.invalidMIMEType
        }
        let isImage = type.conforms(to: .image)
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ChatAttachmentError.invalidSize)
                    return
                }
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if values.isDirectory == true { throw ChatAttachmentError.invalidMIMEType }
                    // Photos are prepared down from up to the preparer's input limit.
                    let limit = isImage ? ImageAttachmentPreparer.maximumInputBytes : ChatAttachment.maximumBytes
                    guard let size = values.fileSize, size > 0, size <= limit else {
                        throw ChatAttachmentError.invalidSize
                    }
                    let fallbackName = (isImage ? "image" : "file")
                        + (type.preferredFilenameExtension.map { ".\($0)" } ?? "")
                    let name = url.lastPathComponent.isEmpty ? fallbackName : url.lastPathComponent
                    continuation.resume(returning: DroppedFile(
                        name: name,
                        mimeType: type.preferredMIMEType
                            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                            ?? "application/octet-stream",
                        data: try Data(contentsOf: url)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
