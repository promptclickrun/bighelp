import Foundation
import Testing
import UIKit
@testable import Bighelp

/// Several pictures in a message become one stack of their own thumbnails; everything else keeps
/// its own tile.
struct ChatImageStackTests {
    private func png(width: Int = 40, height: Int = 30) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func attachment(_ name: String, _ mime: String, _ data: Data? = nil) throws -> ChatAttachment {
        try ChatAttachment(id: "attachment_" + name.filter { $0.isLetter || $0.isNumber } + "_fixture",
                           fileName: name, mimeType: mime, data: data ?? png())
    }

    @Test func picturesStackOnlyWhenThereAreTwoOrMore() throws {
        let pdf = Data("%PDF-1.4 made up".utf8)
        let one = ChatImageStackContent.split([try attachment("a.png", "image/png"),
                                               try attachment("plan.pdf", "application/pdf", pdf)])
        #expect(one.images.count == 1 && one.others.count == 1)
        #expect(!ChatImageStackContent.showsStack(one.images), "A single picture stays a picture")

        let several = ChatImageStackContent.split([try attachment("a.png", "image/png"),
                                                   try attachment("plan.pdf", "application/pdf", pdf),
                                                   try attachment("b.png", "image/png"),
                                                   try attachment("c.png", "image/png")])
        #expect(several.images.map(\.fileName) == ["a.png", "b.png", "c.png"],
                "In message order")
        #expect(several.others.map(\.fileName) == ["plan.pdf"])
        #expect(ChatImageStackContent.showsStack(several.images))
    }

    @Test func onlyRealPicturesGoInTheStack() throws {
        // Named a picture but not one: it keeps a file tile instead of a blank card in the stack.
        let fake = try attachment("broken.png", "image/png", Data(repeating: 1, count: 64))
        // A real picture the host didn't label as one still stacks.
        let unlabeled = try attachment("photo.png", "application/octet-stream")
        let split = ChatImageStackContent.split([try attachment("a.png", "image/png"), fake, unlabeled])
        #expect(split.images.map(\.fileName) == ["a.png", "photo.png"])
        #expect(split.others.map(\.fileName) == ["broken.png"])
    }

    @MainActor
    @Test func thumbnailsAreTheRealPictureMadeSmall() throws {
        let big = try attachment("big.png", "image/png", png(width: 1600, height: 1200))
        let thumbnail = try #require(ChatImageThumbnail.image(for: big))
        #expect(thumbnail.cgImage?.width == 640 && thumbnail.cgImage?.height == 480, "Same shape, smaller")
        #expect(ChatImageThumbnail.image(for: big) === thumbnail, "Made once")
        let fake = try attachment("broken.png", "image/png", Data(repeating: 1, count: 64))
        #expect(ChatImageThumbnail.image(for: fake) == nil)
    }

    @Test func theStackSaysHowManyAndWhereYouAre() {
        #expect(ChatImageStackContent.countLabel(1) == "1 photo")
        #expect(ChatImageStackContent.countLabel(4) == "4 photos")
        #expect(ChatImageStackContent.position(0, of: 4) == "1 of 4")
        #expect(ChatImageStackContent.position(3, of: 4) == "4 of 4")
    }

    @Test func savingSaysHowItWent() {
        #expect(ChatImageStackContent.savedMessage(saved: 4, of: 4) == "Saved 4 photos to Photos.")
        #expect(ChatImageStackContent.savedMessage(saved: 1, of: 1) == "Saved to Photos.")
        #expect(ChatImageStackContent.savedMessage(saved: 3, of: 4) == "Saved 3 of 4 photos to Photos.")
        #expect(ChatImageStackContent.savedMessage(saved: 0, of: 4) == "The photos couldn't be saved to Photos.")
    }
}
