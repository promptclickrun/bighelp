import UniformTypeIdentifiers

/// What a shared or dropped item is, from the types it offers. The share sheet and the message
/// box's drop (`ComposerAttachmentDrop`) read items the same way.
enum SharedItemTypes {
    /// A photo or file, not just text or a link. Dragged and shared text and links offer the
    /// plain-text and URL types that strings and URLs write. A file offers its own type instead: a
    /// .txt file arrives as `public.plain-text` and never as `public.utf8-plain-text`.
    static func isAttachment(_ types: [UTType]) -> Bool {
        guard !types.isEmpty else { return false }
        if types.contains(where: { $0.conforms(to: .image) }) { return true }
        return !types.contains { type in
            type == .utf8PlainText || type == .utf16PlainText
                || (type.conforms(to: .url) && !type.conforms(to: .fileURL))
        }
    }

    /// The type to read an attachment as: a photo in its best non-TIFF image type (TIFF converts
    /// when nothing else is offered), any other file in the type it came as.
    static func fileType(_ types: [UTType]) -> UTType? {
        let images = types.filter { $0.conforms(to: .image) }
        return images.first(where: { !$0.conforms(to: .tiff) }) ?? images.first ?? types.first
    }

    static func isWebLink(_ types: [UTType]) -> Bool {
        types.contains { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }
    }

    /// The text type to read: UTF-8 when offered, else any plain text.
    static func textType(_ types: [UTType]) -> UTType? {
        types.first { $0 == .utf8PlainText } ?? types.first { $0.conforms(to: .plainText) }
    }
}
