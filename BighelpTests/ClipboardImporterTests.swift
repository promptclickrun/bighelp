import Testing
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import Bighelp

@MainActor
struct ClipboardImporterTests {
    private func png() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }.pngData())
    }

    @Test func providerUsesNormalAttachmentNormalizationAndBounds() async throws {
        let data = try png()
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        let attachments = try await ClipboardImageImporter().importImages(from: [provider])
        let attachment = try #require(attachments.first)
        #expect(attachments.count == 1)
        #expect(attachment.kind == .image)
        #expect(UIImage(data: attachment.data) != nil)
        #expect(attachment.data.count <= ChatAttachment.maximumBytes)
        #expect(attachment.fileName.hasPrefix("Clipboard image."))
    }

    @Test func macScreenshotTIFFIsConvertedToTransportImage() async throws {
        let source = try #require(CGImageSourceCreateWithData(try png() as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let provider = NSItemProvider(item: data, typeIdentifier: UTType.tiff.identifier)

        let attachments = try await ClipboardImageImporter().importImages(from: [provider])
        let attachment = try #require(attachments.first)
        #expect(attachments.count == 1)
        #expect(["image/png", "image/jpeg"].contains(attachment.mimeType))
        #expect(UIImage(data: attachment.data)?.cgImage?.width == image.width)
        #expect(UIImage(data: attachment.data)?.cgImage?.height == image.height)
        #expect(attachment.data.count <= ChatAttachment.maximumBytes)
        #expect(!attachment.fileName.hasSuffix(".tiff"))
        #expect(throws: ImageAttachmentPreparer.Error.sourceTooLarge) {
            try ImageAttachmentPreparer(maximumInputBytes: data.length - 1).prepare(data: data as Data)
        }
        #expect(throws: ImageAttachmentPreparer.Error.outputTooLarge) {
            try ImageAttachmentPreparer(maximumOutputBytes: 32).prepare(data: data as Data)
        }
        let resized = try ImageAttachmentPreparer(maximumPixelDimension: 8).prepare(data: data as Data)
        #expect(resized.pixelSize == CGSize(width: 8, height: 6))
    }

    @Test func unavailablePreferredRepresentationFallsBackToReadableImage() async throws {
        let image = try #require(UIImage(data: try png()))
        let data = try #require(image.jpegData(compressionQuality: 1))
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, ClipboardImageImportError.noReadableImage)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }

        let attachments = try await ClipboardImageImporter().importImages(from: [provider])
        #expect(attachments.count == 1)
        #expect(attachments.first?.data == data)
        #expect(attachments.first?.mimeType == "image/jpeg")
    }

    @Test func invalidImageAndExcessiveProviderCountFailWithoutAttachments() async throws {
        let bad = NSItemProvider(item: Data("not an image".utf8) as NSData, typeIdentifier: UTType.png.identifier)
        do {
            _ = try await ClipboardImageImporter().importImages(from: [bad])
            Issue.record("Spoofed image bytes must be rejected")
        } catch { }
        do {
            _ = try await ClipboardImageImporter().importImages(from: Array(repeating: bad, count: 11))
            Issue.record("Excessive provider count must be rejected")
        } catch {
            #expect(error as? ClipboardImageImportError == .tooManyImages)
        }
    }

    @Test func cancelledImportDoesNotProduceAttachments() async throws {
        let provider = NSItemProvider(item: try png() as NSData, typeIdentifier: UTType.png.identifier)
        let task = Task { try await ClipboardImageImporter().importImages(from: [provider]) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled paste must not produce attachments")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func importOwnershipRejectsReplacementAndDismissedDestinations() {
        let first = NSObject()
        let second = NSObject()
        let ownership = ClipboardImageImportSession()
        let token = ownership.begin(target: first)
        #expect(ownership.owns(token, target: first))
        #expect(!ownership.owns(token, target: second))
        ownership.invalidate()
        #expect(!ownership.owns(token, target: first))
        let next = ownership.begin(target: second)
        #expect(ownership.owns(next, target: second))
        #expect(!ownership.owns(token, target: first))
    }
}
