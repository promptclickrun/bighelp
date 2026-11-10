import Foundation

/// One composer attachment intent. PDF-page selections stay distinct from
/// ordinary files so they can never fall through the existing `file.attach`
/// document path. Array order is the staging order used by explicit Send.
enum ChatDraftAttachment: Identifiable, Equatable, Sendable {
    case attachment(ChatAttachment)
    case pdfPages(DirectHermesPDFPageSelection)
    /// A file over 8 MB, kept on disk and sent in pieces (`BigFileUploader`).
    case bigFile(ChatBigFile)

    var id: String {
        switch self {
        case .attachment(let attachment):
            "attachment:\(attachment.id)"
        case .pdfPages(let selection):
            "pdf-pages:\(selection.attachment.id)"
        case .bigFile(let file):
            "big-file:\(file.id)"
        }
    }

    var sourceAttachmentID: String {
        switch self {
        case .attachment(let attachment): attachment.id
        case .pdfPages(let selection): selection.attachment.id
        case .bigFile(let file): file.id
        }
    }

    var byteCount: Int {
        switch self {
        case .attachment(let attachment): attachment.data.count
        case .pdfPages(let selection): selection.attachment.data.count
        // Sent on its own path; it doesn't count toward the 24 MB a message's other files may hold.
        case .bigFile: 0
        }
    }

    var bigFile: ChatBigFile? {
        guard case .bigFile(let file) = self else { return nil }
        return file
    }

    var ordinaryAttachment: ChatAttachment? {
        guard case .attachment(let attachment) = self else { return nil }
        return attachment
    }

    var pdfSelection: DirectHermesPDFPageSelection? {
        guard case .pdfPages(let selection) = self else { return nil }
        return selection
    }
}

/// Accepted transport receipt for one mixed attachment draft. PDF images remain
/// typed and path-free; the ordinary conversation response keeps its existing
/// reducer ownership.
struct DirectHermesDraftAttachmentSendReceipt: Equatable, Sendable {
    let response: ConversationResponse
    let pdfAttachments: [DirectHermesPDFAttachmentReceipt]
    /// What Hermes took: the message with each file's `@file:` reference, as its history keeps it.
    var submittedText: String = ""
}
