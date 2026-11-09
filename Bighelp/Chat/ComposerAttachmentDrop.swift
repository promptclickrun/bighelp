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

    /// The same reading as the share sheet's (`SharedItemTypes`).
    static func isAttachment(_ provider: NSItemProvider) -> Bool {
        SharedItemTypes.isAttachment(provider.registeredTypeIdentifiers.compactMap { UTType($0) })
    }

    /// Starts reading every dropped photo and file at once: a drag's data is only
    /// promised around the drop, and the draft adds attachments one at a time.
    /// Text and links in the same drag are left out; past `maximumItems`, each
    /// extra item stays as one that didn't attach.
    @MainActor
    static func imports(from providers: [NSItemProvider],
                        into model: ChatModel? = nil) -> (kind: DraftAttachmentImportKind, loaders: [DraftAttachmentLoader]) {
        let dropped = providers.filter(isAttachment)
        let images = dropped.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        let kind: DraftAttachmentImportKind = images.count == dropped.count ? .photos
            : images.isEmpty ? .files : .attachments
        let loaders = dropped.enumerated().map { index, provider -> DraftAttachmentLoader in
            guard index < maximumItems else {
                return DraftAttachmentLoader(name: provider.suggestedName) { throw ChatAttachmentError.tooMany }
            }
            let read = Task { try await readFile(from: provider) }
            return DraftAttachmentLoader(draftNamed: provider.suggestedName, load: { @MainActor [weak model] in
                let file = try await read.value
                // The copy kept past UIKit's callback goes once the app has its own.
                defer { if let copy = file.largeFile { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) } }
                return try await draftAttachment(from: file, id: "attachment_\(UUID().uuidString.lowercased())",
                                                 into: model)
            })
        }
        return (kind, loaders)
    }

    /// A read file as the draft takes it: a photo or file up to 8 MB prepared in memory, a bigger
    /// file copied to the app's own storage to go in pieces (refused with "update the plugin" when
    /// the chat's computer can't take it). Shares from other apps take the same path.
    @MainActor
    static func draftAttachment(from file: DroppedFile, id: String, into model: ChatModel?) async throws -> ChatDraftAttachment {
        if let large = file.largeFile {
            return .bigFile(try await BigFileStore.importing(large, fileName: file.name, mimeType: file.mimeType,
                                                             byteCount: file.byteCount, into: model))
        }
        return .attachment(try ChatAttachmentPreparer().prepare(
            id: id,
            fileName: file.name,
            mimeType: file.mimeType,
            data: file.data
        ))
    }

    struct DroppedFile: Sendable {
        let name: String
        let mimeType: String
        let data: Data
        /// Over 8 MB: a copy of the file for `BigFileStore`, read a piece at a time.
        var largeFile: URL? = nil
        var byteCount = 0
    }

    /// Photos read in their best non-TIFF image type (TIFF converts when nothing
    /// else is offered); other files in the type they were dragged as. The file
    /// UIKit hands over keeps the dragged item's name and is gone after the callback.
    /// Starts on the main actor with the drop's provider; UIKit reads on its own queue.
    @MainActor
    static func readFile(from provider: NSItemProvider) async throws -> DroppedFile {
        guard let type = SharedItemTypes.fileType(provider.registeredTypeIdentifiers.compactMap { UTType($0) }) else {
            throw ChatAttachmentError.invalidMIMEType
        }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ChatAttachmentError.invalidSize)
                    return
                }
                continuation.resume(with: Result { try droppedFile(at: url, type: type, copiesBigFile: true) })
            }
        }
    }

    /// Reads a file on disk the way a dropped one is: a photo up to the preparer's input limit, any
    /// other file up to the plugin's. `copiesBigFile` keeps a copy of one over 8 MB, for a file iOS
    /// deletes after its callback; otherwise the file itself is read later, a piece at a time.
    /// `name` and `mimeType` replace what the file's own name and type say.
    static func droppedFile(at url: URL, type: UTType, name: String? = nil, mimeType: String? = nil,
                            copiesBigFile: Bool) throws -> DroppedFile {
        let isImage = type.conforms(to: .image)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values.isDirectory == true { throw ChatAttachmentError.invalidMIMEType }
        // Photos are prepared down from up to the preparer's input limit.
        let limit = isImage ? ImageAttachmentPreparer.maximumInputBytes : BigFileUploads.maximumBytes
        guard let size = values.fileSize, size > 0, size <= limit else {
            if isImage { throw ChatAttachmentError.invalidSize }
            throw BigFileUploadError(failure: .tooLarge)
        }
        let fallbackName = (isImage ? "image" : "file")
            + (type.preferredFilenameExtension.map { ".\($0)" } ?? "")
        let name = name ?? (url.lastPathComponent.isEmpty ? fallbackName : url.lastPathComponent)
        let mimeType = mimeType ?? type.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        if !isImage, BigFileUploads.isBig(size) {
            guard copiesBigFile else {
                return DroppedFile(name: name, mimeType: mimeType, data: Data(), largeFile: url, byteCount: size)
            }
            // UIKit removes its file after this callback; keep a copy to read in pieces.
            let folder = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: name)
            try FileManager.default.copyItem(at: url, to: copy)
            return DroppedFile(name: name, mimeType: mimeType, data: Data(), largeFile: copy, byteCount: size)
        }
        return DroppedFile(name: name, mimeType: mimeType, data: try Data(contentsOf: url))
    }
}
