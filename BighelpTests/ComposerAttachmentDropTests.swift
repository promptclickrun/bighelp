import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Bighelp

@MainActor
struct ComposerAttachmentDropTests {
    private func png() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }.pngData())
    }

    /// A provider like the one a Finder drag delivers: a file representation in the file's own type.
    private func file(_ name: String, _ data: Data, type: UTType) throws -> NSItemProvider {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    @Test func textAndLinksStayTextWhileFilesAndPhotosAttach() throws {
        let selection = NSItemProvider(object: "dragged words" as NSString)
        let link = try NSItemProvider(object: #require(URL(string: "https://example.com/page")) as NSURL)
        let textFile = try file("Notes.txt", Data("notes".utf8), type: .plainText)
        let pdf = try file("Report.pdf", Data("%PDF-1.4".utf8), type: .pdf)
        let photo = try file("Photo.png", png(), type: .png)

        #expect(!ComposerAttachmentDrop.isAttachmentDrop([selection]))
        #expect(!ComposerAttachmentDrop.isAttachmentDrop([link]))
        #expect(ComposerAttachmentDrop.isAttachment(textFile))
        #expect(ComposerAttachmentDrop.isAttachment(pdf))
        #expect(ComposerAttachmentDrop.isAttachment(photo))
        #expect(ComposerAttachmentDrop.isAttachmentDrop([selection, pdf]))
    }

    @Test func droppedFilesKeepTheirNamesAndPhotosArePrepared() async throws {
        let model = ChatModel(conversationID: "drop", client: ConversationFixtureClient(), initialItems: [])
        let providers = try [
            file("Quarterly report.pdf", Data("%PDF-1.4 synthetic".utf8), type: .pdf),
            file("Notes.txt", Data("Made-up notes".utf8), type: .plainText),
            file("Sunset.png", png(), type: .png),
            NSItemProvider(object: "ignored text" as NSString),
        ]
        let drop = ComposerAttachmentDrop.imports(from: providers)
        #expect(drop.kind == .attachments)
        #expect(drop.loaders.count == 3)

        await model.importDraftAttachments(drop.kind, drop.loaders)
        #expect(model.draftAttachmentFailures.isEmpty)
        let attachments = model.draftAttachments
        #expect(attachments.map(\.fileName) == ["Quarterly report.pdf", "Notes.txt", "Sunset.png"])
        #expect(attachments.map(\.mimeType) == ["application/pdf", "text/plain", "image/png"])
        #expect(attachments[1].data == Data("Made-up notes".utf8))
        #expect(attachments[2].kind == .image)
    }

    @Test func extraItemsAndUnreadableFilesStayAsDidNotAttach() async throws {
        let model = ChatModel(conversationID: "drop", client: ConversationFixtureClient(), initialItems: [])
        var providers = try (0..<ComposerAttachmentDrop.maximumItems).map {
            try file("note-\($0).txt", Data("note \($0)".utf8), type: .plainText)
        }
        providers.append(try file("one-too-many.txt", Data("extra".utf8), type: .plainText))
        let drop = ComposerAttachmentDrop.imports(from: providers)
        #expect(drop.kind == .files)

        await model.importDraftAttachments(drop.kind, drop.loaders)
        #expect(model.draftAttachments.count == ComposerAttachmentDrop.maximumItems)
        let failure = try #require(model.draftAttachmentFailures.first)
        #expect(model.draftAttachmentFailures.count == 1)
        #expect(failure.message == ChatAttachmentError.tooMany.localizedDescription)
    }
}
