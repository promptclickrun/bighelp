import UIKit
import ImageIO
import Testing
@testable import Bighelp

struct ChatAttachmentPreparerTests {
    @Test func largeCameraPhotoIsResizedAndCompressedForTransport() throws {
        let source = try makeLargeCameraJPEG()
        #expect(source.count > ChatAttachment.maximumBytes)

        let attachment = try ChatAttachmentPreparer().prepare(
            id: "attachment_large_camera_0001",
            fileName: "IMG_1234.HEIC",
            mimeType: "image/heic",
            data: source
        )

        #expect(attachment.data.count <= ChatAttachment.maximumBytes)
        #expect(attachment.fileName == "IMG_1234.jpg")
        #expect(attachment.mimeType == "image/jpeg")
        #expect(imagePixelSize(attachment.data) == CGSize(width: 2_560, height: 1_920))
    }

    @Test func nonImageAttachmentRemainsByteForByteUnchanged() throws {
        let source = Data("%PDF-1.7\nfixture body".utf8)

        let attachment = try ChatAttachmentPreparer().prepare(
            id: "attachment_pdf_fixture_0001",
            fileName: "reference.pdf",
            mimeType: "application/pdf",
            data: source
        )

        #expect(attachment.data == source)
        #expect(attachment.fileName == "reference.pdf")
        #expect(attachment.mimeType == "application/pdf")
    }

    @Test func imageIsRejectedWhenNoEncodedOutputCanMeetTheLimit() throws {
        let source = try makeLargeCameraJPEG()
        let preparer = ChatAttachmentPreparer(
            imagePreparer: ImageAttachmentPreparer(
                maximumInputBytes: 64 * 1_024 * 1_024,
                maximumOutputBytes: 32,
                maximumPixelDimension: 32
            )
        )

        #expect(throws: ImageAttachmentPreparer.Error.outputTooLarge) {
            try preparer.prepare(
                id: "attachment_impossible_fixture_0001",
                fileName: "camera.jpg",
                mimeType: "image/jpeg",
                data: source
            )
        }
    }
}

struct AvatarImageProcessorTests {
    @Test func rejectsInvalidDataWithoutProducingAnAvatar() {
        let processor = AvatarImageProcessor()

        #expect(throws: AvatarImageProcessor.Error.self) {
            try processor.prepare(data: Data("not an image".utf8))
        }
    }

    @Test func preparesDownsampledPNGForLocalFixtureStorage() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2_000, height: 1_000))
        let data = renderer.pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
        }

        let avatar = try AvatarImageProcessor().prepare(data: data)

        #expect(avatar.fileExtension == "png")
        #expect(avatar.data.count <= AvatarImageProcessor.maximumOutputBytes)
        #expect(avatar.pixelSize.width <= AvatarImageProcessor.maximumPixelDimension)
        #expect(avatar.pixelSize.height <= AvatarImageProcessor.maximumPixelDimension)
    }

    @Test func largeCameraPhotoIsPreparedWithinAvatarStorageLimits() throws {
        let source = try makeLargeCameraJPEG()
        #expect(source.count > 12 * 1_024 * 1_024)

        let avatar = try AvatarImageProcessor().prepare(data: source)

        #expect(avatar.fileExtension == "jpg")
        #expect(avatar.data.count <= AvatarImageProcessor.maximumOutputBytes)
        #expect(avatar.pixelSize == CGSize(width: 1_024, height: 768))
    }

    @Test func storedAvatarUsesCompleteDataProtection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpAvatarTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let avatar = PreparedAvatar(
            data: Data([0x01, 0x02, 0x03]),
            fileExtension: "png",
            pixelSize: CGSize(width: 1, height: 1)
        )
        let protection = AvatarFileProtectionRecorder()

        _ = try AvatarImageProcessor(fileProtection: protection).store(avatar, in: directory)

        #expect(protection.events == [
            .prepare(.privateVisual),
            .write(.privateVisual),
            .apply(.privateVisual),
        ])
        #expect(
            BighelpLocalFileProtector.writingOptions(for: .privateVisual)
                .contains(.completeFileProtection)
        )
    }

    @Test func lockedAvatarStoreThrowsBeforeCreatingProtectedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpAvatarTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let avatar = PreparedAvatar(
            data: Data([0x01, 0x02, 0x03]),
            fileExtension: "png",
            pixelSize: CGSize(width: 1, height: 1)
        )
        let availability = TestProtectedDataAvailability(isAvailable: false)
        let processor = AvatarImageProcessor(
            protectedDataAvailability: availability
        )

        #expect(throws: BighelpLocalPersistenceError.protectedDataUnavailable) {
            try processor.store(avatar, in: directory)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }
}

private final class AvatarFileProtectionRecorder: BighelpLocalFileProtecting, @unchecked Sendable {
    enum Event: Equatable {
        case prepare(BighelpLocalProtectionClass)
        case write(BighelpLocalProtectionClass)
        case apply(BighelpLocalProtectionClass)
    }

    var events: [Event] = []

    func prepareDirectory(
        _ directory: URL,
        protection: BighelpLocalProtectionClass,
        fileManager: FileManager
    ) throws {
        events.append(.prepare(protection))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(
        _ data: Data,
        to file: URL,
        protection: BighelpLocalProtectionClass
    ) throws {
        events.append(.write(protection))
        try data.write(to: file, options: .withoutOverwriting)
    }

    func apply(
        _ protection: BighelpLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws {
        events.append(.apply(protection))
    }
}

private final class TestProtectedDataAvailability: BighelpProtectedDataAvailabilityProviding, @unchecked Sendable {
    var isProtectedDataAvailable: Bool

    init(isAvailable: Bool) {
        isProtectedDataAvailable = isAvailable
    }
}

private func makeLargeCameraJPEG() throws -> Data {
    let width = 4_032
    let height = 3_024
    let bytesPerRow = width * 4
    var pixels = Data(count: bytesPerRow * height)
    let pixelByteCount = pixels.count
    pixels.withUnsafeMutableBytes { rawBuffer in
        guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
        var value: UInt32 = 0xA341_316C
        for offset in stride(from: 0, to: pixelByteCount, by: 4) {
            value = value &* 1_664_525 &+ 1_013_904_223
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            bytes[offset + 3] = 0xFF
        }
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output,
        "public.jpeg" as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary
    )
    try #require(CGImageDestinationFinalize(destination))
    return output as Data
}

private func imagePixelSize(_ data: Data) -> CGSize? {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else { return nil }
    return CGSize(width: width.doubleValue, height: height.doubleValue)
}
