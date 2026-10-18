import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Bighelp

/// Copying a whole table, and a card as a picture.
@MainActor
struct ChatCopyTests {
    private let table = MarkdownTable(
        header: ["Item", "**Cost**"],
        alignments: [.leading, .trailing],
        rows: [["Wax ring | kit", "$12"], ["Plumber <visit>", "$250"]]
    )

    @Test func aTableCopiesAsMarkdownForMessages() {
        #expect(ChatTableCopy.markdown(table) == """
        | Item | Cost |
        | --- | ---: |
        | Wax ring \\| kit | $12 |
        | Plumber <visit> | $250 |
        """)
    }

    @Test func aTableCopiesAsColumnsForSpreadsheets() {
        #expect(ChatTableCopy.tabSeparated(table) == "Item\tCost\nWax ring | kit\t$12\nPlumber <visit>\t$250")
    }

    @Test func aTableCopiesAsAnHTMLTableForMail() {
        let html = ChatTableCopy.html(table)
        #expect(html.hasPrefix("<table><thead><tr><th>Item</th><th>Cost</th></tr></thead>"))
        #expect(html.contains("<td>Plumber &lt;visit&gt;</td>"), "Cell text is escaped")
    }

    private var fence: String {
        "```loopdy-card\n{\"schema\":\"loopdy.generative_ui\",\"version\":1,\"component\":\"summary\","
            + "\"title\":\"Trip budget\",\"body\":\"Under $400 a night\"}\n```"
    }

    /// Copying a message with a card gives its words and a picture of the
    /// card, in order, never the card's code.
    @Test func aMessageWithACardCopiesItsWordsAndAPictureOfTheCard() throws {
        let projection = ChatCardMessageProjection(source: "Here's the plan.\n\n" + fence + "\n\nWant changes?",
                                                   role: .assistant)
        var drawn: [String] = []
        let parts = ChatMessageCopy.parts(projection) { envelope in
            drawn.append(envelope.title)
            return Data([0x89, 0x50])
        }
        #expect(drawn == ["Trip budget"])
        #expect(parts == [.text("Here's the plan."), .image(Data([0x89, 0x50])), .text("Want changes?")])
        let items = ChatMessageCopy.items(parts)
        #expect(items.count == 3)
        #expect(items[0][UTType.utf8PlainText.identifier] as? String == "Here's the plan.")
        #expect(items[1][UTType.png.identifier] as? Data == Data([0x89, 0x50]))
        #expect(items[2].keys.sorted() == [UTType.utf8PlainText.identifier])
    }

    @Test func aCardThatCantBeDrawnStillSaysWhatItWas() {
        let projection = ChatCardMessageProjection(source: "Before\n\n" + fence + "\n\nAfter", role: .assistant)
        let parts = ChatMessageCopy.parts(projection) { _ in nil }
        #expect(parts == [.text("Before\n\nTrip budget\n\nAfter")])
        #expect(!parts.contains { if case .text(let text) = $0 { text.contains("schema") } else { false } })
    }

    @Test func aRealCardInAMessageDrawsToAPicture() throws {
        let projection = ChatCardMessageProjection(source: "Plan:\n\n" + fence, role: .assistant)
        let context = ChatCardCopyContext()
        context.width = 320
        let parts = ChatMessageCopy.parts(projection) { envelope in
            guard case .legacy(let card) = envelope else { return nil }
            return context.png(GenerativeUICardView(card: card, messageID: "m"), background: .white)
        }
        #expect(parts.count == 2)
        guard case .image(let png)? = parts.last else { Issue.record("No picture"); return }
        #expect(UIImage(data: png) != nil)
    }

    /// Touch and hold a picture to copy it: its own format, plus a PNG when
    /// that format isn't one every app pastes.
    @Test func aPictureCopiesInItsOwnFormat() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let plain = ChatPictureClipboard.items(data: png, mimeType: "image/png")
        #expect(plain.count == 1)
        #expect(plain[0].keys.sorted() == [UTType.png.identifier])
        let heic = ChatPictureClipboard.items(data: png, mimeType: "image/heic")
        #expect(Set(heic[0].keys) == [UTType.heic.identifier, UTType.png.identifier])
        #expect(ChatPictureClipboard.items(data: Data("text".utf8), mimeType: "text/plain").isEmpty)
    }

    @Test func markdownFilesOpenRenderedAndOthersDont() throws {
        #expect(ChatAttachmentMarkdown.isMarkdown(fileName: "Kyoto plan.md", mimeType: "application/octet-stream"))
        #expect(ChatAttachmentMarkdown.isMarkdown(fileName: "notes", mimeType: "text/markdown"))
        #expect(ChatAttachmentMarkdown.isMarkdown(fileName: "README.MARKDOWN", mimeType: "text/plain"))
        #expect(!ChatAttachmentMarkdown.isMarkdown(fileName: "report.pdf", mimeType: "application/pdf"))
        let note = try ChatAttachment(id: "fixture-note-0001", fileName: "plan.md", mimeType: "text/markdown", data: Data("# Hi".utf8))
        #expect(ChatAttachmentMarkdown.text(of: note) == "# Hi")
        let huge = try ChatAttachment(id: "fixture-huge-0001", fileName: "log.md", mimeType: "text/markdown",
                                      data: Data(repeating: 0x61, count: ChatAttachmentMarkdown.maximumBytes + 1))
        #expect(ChatAttachmentMarkdown.text(of: huge) == nil, "Very long files use the plain viewer")
    }

    @Test func aCardCopiesAsASharpPicture() throws {
        let card = try #require(BighelpCardDemoFixtures.documents.first)
        let png = try #require(ChatCardImage.png(BighelpCardView(card: card), width: 320, scale: 3,
                                                 background: .white, environment: EnvironmentValues()))
        let image = try #require(UIImage(data: png))
        #expect(abs(image.size.width * image.scale - (320 + 32) * 3) < 1, "The card's width plus a margin, at screen scale")
        #expect(image.size.height > 100)
        #expect(ChatCardImage.png(BighelpCardView(card: card), width: 0, scale: 3, background: .white,
                                  environment: EnvironmentValues()) == nil, "Nothing before the card has a size")
    }

    /// Issue #17: the forecast row scrolls on screen, and the copied image left
    /// it blank. Five periods must draw more than one in the image.
    @Test func aWeatherCardsForecastIsInItsImage() throws {
        let one = try varied(rowsIn: weatherCard(periods: 1))
        let five = try varied(rowsIn: weatherCard(periods: 5))
        #expect(five > one + 40, "Five forecast periods draw a second line of pills (one: \(one), five: \(five))")
    }

    private func weatherCard(periods: Int) throws -> Data {
        let labels = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        let card = try GenerativeUICard.decode([
            "schema": "loopdy.generative_ui", "version": 2, "component": "weather_forecast", "title": "Tomorrow",
            "content_hash": String(repeating: "a", count: 64), "card_id": String(repeating: "b", count: 32),
            "origin": "live", "created_at": "2026-10-01T12:00:00Z", "provenance": ["source": "fixture"],
            "data": [
                "location": "Example City", "units": "imperial",
                "current": ["temperature": 61, "condition_code": "clear", "condition_label": "Clear"],
                "periods": (0..<periods).map { index in
                    ["id": "p\(index)", "label": labels[index], "condition_code": "rain", "high": 70 + index] as [String: Any]
                },
            ] as [String: Any],
        ])
        return try #require(ChatCardImage.png(GenerativeUICardView(card: card, messageID: "m"), width: 320, scale: 2,
                                              background: .white, environment: EnvironmentValues()))
    }

    /// Rows of the image that aren't one flat color.
    private func varied(rowsIn png: Data) throws -> Int {
        let image = try #require(UIImage(data: png)?.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).filter { row in
            var low = 255, high = 0
            for column in stride(from: 0, to: width, by: 2) {
                let offset = (row * width + column) * 4
                let luminance = (Int(pixels[offset]) * 3 + Int(pixels[offset + 1]) * 6 + Int(pixels[offset + 2])) / 10
                low = min(low, luminance)
                high = max(high, luminance)
            }
            return high - low > 24
        }.count
    }
}
