import PDFKit
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct ChatDocumentScannerTests {
    @Test func scanExportsAllPagesInOrderAsAFileAttachment() throws {
        let colors: [UIColor] = [.red, .blue]
        let attachment = try ChatScannedDocument.attachment(pageCount: 2) { index in
            UIGraphicsImageRenderer(size: CGSize(width: 300, height: index == 0 ? 500 : 200)).image { context in
                colors[index].setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
            }
        }
        #expect(attachment.kind == .file)
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.fileName == "Scanned document.pdf")
        let document = try #require(PDFDocument(data: attachment.data))
        #expect(document.pageCount == 2)
        let first = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        let second = try #require(document.page(at: 1)).bounds(for: .mediaBox)
        #expect(first.height > first.width)
        #expect(second.width > second.height)
        #expect(attachment.data.count <= ChatAttachment.maximumBytes)
    }

    @Test(arguments: [0, 21]) func invalidPageCountsNeverReadImages(count: Int) {
        var requested = false
        #expect(throws: ChatScannedDocument.ScanError.self) {
            _ = try ChatScannedDocument.attachment(pageCount: count) { _ in requested = true; return UIImage() }
        }
        #expect(!requested)
    }

    @Test func unreadablePageIsRejectedInsteadOfSilentlyDropped() {
        #expect(throws: ChatScannedDocument.ScanError.self) {
            _ = try ChatScannedDocument.attachment(pageCount: 1) { _ in UIImage() }
        }
    }

    @Test func cancellationNeverProducesAnAttachmentAndIgnoresLateCompletion() throws {
        var calls = 0
        var attached = false
        let coordinator = ChatDocumentScanner.Coordinator { result in
            calls += 1
            attached = result != nil
        }
        coordinator.finish(nil)
        coordinator.finish(.failure(ChatScannedDocument.ScanError.captureFailed))
        #expect(calls == 1)
        #expect(!attached)
    }

    @Test func scannerIsOneRowOfThePlusMenu() {
        #expect(ChatActionMenuAction.scanDocument.accessibilityIdentifier == "chat.action.scan-document")
        #expect(ChatActionMenuAction.allCases.filter { $0 == .scanDocument }.count == 1)
    }
}
