import Foundation
import Testing
@testable import Bighelp

/// The tag above the message box: the count first, then the kinds. Adding and
/// "didn't attach" hold Send until everything is in.
@MainActor
struct DraftAttachmentRailTests {
    private static func photo(_ id: String) throws -> ChatAttachment {
        try ChatAttachment(id: "attachment_photo_\(id)", fileName: "\(id).jpg", mimeType: "image/jpeg", data: Data(repeating: 1, count: 2_000))
    }

    private static func pdf(_ name: String = "Lease 2026.pdf", bytes: Int = 240_000) throws -> ChatAttachment {
        try ChatAttachment(id: "attachment_pdf_" + name.filter { $0.isLetter || $0.isNumber }, fileName: name, mimeType: "application/pdf",
                           data: Data(repeating: 2, count: bytes))
    }

    private static func summary(_ attachments: [ChatAttachment], adding: DraftAttachmentImportProgress? = nil,
                                failed: Int = 0) -> DraftAttachmentRailState? {
        DraftAttachmentRailState(attachments: attachments.map(ChatDraftAttachment.attachment),
                                 adding: adding, failedCount: failed)
    }

    @Test func onePhotoSaysOnePhoto() throws {
        let state = try #require(Self.summary([Self.photo("a")]))
        #expect(state.title == "1 photo" && state.detail == nil)
        #expect(state.thumbnails.count == 1)
    }

    @Test func oneFileShowsItsNameAndSize() throws {
        let state = try #require(Self.summary([Self.pdf()]))
        #expect(state.title == "Lease 2026.pdf")
        #expect(state.detail == ByteCountFormatter.string(fromByteCount: 240_000, countStyle: .file))
    }

    @Test func mixedCountsFirstThenEachKindWithPhotosLeading() throws {
        let state = try #require(Self.summary([Self.pdf(), Self.photo("a"), Self.photo("b"), Self.photo("c")]))
        #expect(state.title == "4 attached")
        #expect(state.detail == "3 photos, 1 PDF")
        #expect(state.thumbnails.prefix(2).allSatisfy { $0.isPhoto }, "Photos lead the stack")
        #expect(state.thumbnails.count == 3, "At most three in the stack")
        #expect(state.thumbnails.last?.attachment.isPDF == true, "The file keeps the last spot")
        let files = try #require(Self.summary([Self.pdf("a.pdf"), Self.pdf("b.pdf")]))
        #expect(files.title == "2 attached" && files.detail == "2 PDFs")
        let text = try ChatAttachment(id: "attachment_text_notes", fileName: "notes.txt", mimeType: "text/plain", data: Data("x".utf8))
        let withText = Self.summary([text, try Self.photo("a")])
        #expect(withText?.detail == "1 photo, 1 file")
    }

    @Test func addingAndFailuresTakeOverTheTag() throws {
        let adding = try #require(Self.summary([Self.photo("a")], adding: .init(kind: .photos, total: 4, finished: 1)))
        #expect(adding.title == "Adding 2 of 4…" && adding.detail == "photos" && adding.isAdding)
        let failed = try #require(Self.summary([Self.photo("a")], failed: 1))
        #expect(failed.title == "1 didn't attach" && failed.isFailure)
        #expect(Self.summary([]) == nil, "Nothing attached, no tag")
    }

    /// Each one loads in turn; one that fails stays as "didn't attach" with its reason,
    /// the rest still go in, and Send waits until it's dealt with.
    @Test func importsKeepGoingPastAFailureAndHoldSendUntilItsDealtWith() async throws {
        let model = ChatModel(conversationID: "rail", client: ConversationFixtureClient(), initialItems: [],
                              initialDraft: "Here's the lease")
        var failNext = true
        let loaders = [
            DraftAttachmentLoader(name: "a.jpg") { try Self.photo("a") },
            DraftAttachmentLoader(name: "b.jpg") {
                if failNext { throw ChatAttachmentError.invalidSize }
                return try Self.photo("b")
            },
            DraftAttachmentLoader(name: "Lease 2026.pdf") { try Self.pdf() },
        ]
        await model.importDraftAttachments(.photos, loaders)
        #expect(model.orderedDraftAttachments.count == 2)
        #expect(model.draftAttachmentImport == nil)
        #expect(model.draftAttachmentFailures.map(\.name) == ["b.jpg"])
        #expect(model.draftAttachmentFailures.first?.message.contains("8 MB") == true)
        #expect(!model.canSend, "Send waits while one didn't attach")

        failNext = false
        await model.retryFailedDraftAttachments()
        #expect(model.draftAttachmentFailures.isEmpty)
        #expect(model.orderedDraftAttachments.map(\.sourceAttachmentID).contains("attachment_photo_b"))
        #expect(model.canSend)
    }

    @Test func sendWaitsWhileAttachmentsAreBeingAdded() async throws {
        let model = ChatModel(conversationID: "adding", client: ConversationFixtureClient(), initialItems: [],
                              initialDraft: "Photos")
        var release: CheckedContinuation<Void, Never>?
        let slow = DraftAttachmentLoader(name: "slow.jpg") {
            await withCheckedContinuation { release = $0 }
            return try Self.photo("slow")
        }
        let task = Task { await model.importDraftAttachments(.photos, [DraftAttachmentLoader(name: "a.jpg") {
            try Self.photo("a")
        }, slow]) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        #expect(model.draftAttachmentImport == .init(kind: .photos, total: 2, finished: 1))
        #expect(!model.canSend)
        #expect(ChatComposerPrimaryAction.resolve(draft: "", hasAttachments: model.hasDraftAttachmentActivity) == .send)
        release?.resume()
        await task.value
        #expect(model.draftAttachmentImport == nil && model.canSend)
    }

    @Test func aFailureCanBeRemovedInsteadOfRetried() async throws {
        let model = ChatModel(conversationID: "remove", client: ConversationFixtureClient(), initialItems: [],
                              initialDraft: "Hi")
        await model.importDraftAttachments(.files, [DraftAttachmentLoader(name: "broken.pdf") {
            throw ChatAttachmentError.invalidSize
        }])
        let failure = try #require(model.draftAttachmentFailures.first)
        model.removeDraftAttachmentFailure(id: failure.id)
        #expect(model.draftAttachmentFailures.isEmpty && model.canSend)
    }
}
