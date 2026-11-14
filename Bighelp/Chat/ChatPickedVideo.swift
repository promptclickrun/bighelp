import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video picked in the photo library, as the file Photos hands over (the picker asks for the
/// video as it is kept, so nothing is converted first). Photos removes its file when the
/// callback returns, so the copy is made there, into a folder of its own.
struct ChatPickedVideo: Transferable {
    let file: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            // Kept as it is, a long video can be several GB: refused here, before it is copied.
            if let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > BigFileUploads.maximumBytes {
                throw BigFileUploadError(failure: .tooLarge)
            }
            let folder = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return ChatPickedVideo(file: copy)
        }
    }

    /// The video as the draft takes it, like a file from Add › Files: up to 8 MB in memory, a
    /// bigger one on disk to go in pieces. The copy from Photos goes once the draft has its own.
    @MainActor
    static func draftAttachment(from selection: PhotosPickerItem, id: String,
                                into model: ChatModel) async throws -> ChatDraftAttachment {
        guard let video = try await selection.loadTransferable(type: ChatPickedVideo.self) else {
            throw ChatAttachmentError.invalidSize
        }
        defer { try? FileManager.default.removeItem(at: video.file.deletingLastPathComponent()) }
        let type = UTType(filenameExtension: video.file.pathExtension) ?? .movie
        let file = try ComposerAttachmentDrop.droppedFile(at: video.file, type: type, copiesBigFile: false)
        return try await ComposerAttachmentDrop.draftAttachment(from: file, id: id, into: model)
    }
}

extension PhotosPickerItem {
    /// A video. A Live Photo also carries a short movie, but it is a picture first.
    var isVideo: Bool {
        !supportedContentTypes.contains { $0.conforms(to: .image) }
            && supportedContentTypes.contains { $0.conforms(to: .movie) }
    }
}
