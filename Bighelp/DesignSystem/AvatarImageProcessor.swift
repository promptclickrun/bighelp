import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct PreparedImageAttachment: Equatable, Sendable {
    let data: Data
    let fileExtension: String
    let mimeType: String
    let pixelSize: CGSize
}

struct ImageAttachmentPreparer: Sendable {
    enum Error: Swift.Error, Equatable {
        case invalidData
        case unsupportedFormat
        case sourceTooLarge
        case sourceDimensionsTooLarge
        case outputTooLarge
        case processingFailed
    }

    static let maximumInputBytes = 64 * 1_024 * 1_024
    static let maximumSourcePixelCount = 100_000_000
    static let maximumOutputBytes = ChatAttachment.maximumBytes
    static let maximumPixelDimension = 2_560

    let maximumInputBytes: Int
    let maximumOutputBytes: Int
    let maximumPixelDimension: Int

    init(
        maximumInputBytes: Int = Self.maximumInputBytes,
        maximumOutputBytes: Int = Self.maximumOutputBytes,
        maximumPixelDimension: Int = Self.maximumPixelDimension
    ) {
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumPixelDimension = maximumPixelDimension
    }

    func prepare(data: Data) throws -> PreparedImageAttachment {
        guard !data.isEmpty else { throw Error.invalidData }
        guard data.count <= maximumInputBytes else { throw Error.sourceTooLarge }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw Error.invalidData
        }
        guard
            let sourceType = CGImageSourceGetType(source),
            isSupportedRaster(sourceType)
        else { throw Error.unsupportedFormat }
        let sourceSize = try pixelSize(of: source)
        let sourceWidth = Int(sourceSize.width)
        let sourceHeight = Int(sourceSize.height)
        guard
            sourceWidth > 0,
            sourceHeight > 0,
            sourceWidth <= Self.maximumSourcePixelCount / sourceHeight
        else { throw Error.sourceDimensionsTooLarge }

        let sourceMaximumDimension = max(sourceWidth, sourceHeight)
        // macOS clipboard images may be TIFF. Decode them here, but always
        // encode a transport-supported PNG/JPEG instead of passing TIFF through.
        if sourceType as String != UTType.tiff.identifier,
           data.count <= maximumOutputBytes, sourceMaximumDimension <= maximumPixelDimension {
            let type = UTType(sourceType as String)
            guard
                let fileExtension = type?.preferredFilenameExtension,
                let mimeType = type?.preferredMIMEType
            else { throw Error.unsupportedFormat }
            return PreparedImageAttachment(
                data: data,
                fileExtension: fileExtension,
                mimeType: mimeType,
                pixelSize: sourceSize
            )
        }

        var targetDimension = min(sourceMaximumDimension, maximumPixelDimension)
        repeat {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else { throw Error.processingFailed }

            if image.hasAlpha {
                if let output = encode(image, as: UTType.png, compressionQuality: nil),
                   output.count <= maximumOutputBytes {
                    return PreparedImageAttachment(
                        data: output,
                        fileExtension: "png",
                        mimeType: "image/png",
                        pixelSize: CGSize(width: image.width, height: image.height)
                    )
                }
            } else {
                for quality in [0.82, 0.72, 0.62, 0.52, 0.42, 0.32] {
                    if let output = encode(image, as: UTType.jpeg, compressionQuality: quality),
                       output.count <= maximumOutputBytes {
                        return PreparedImageAttachment(
                            data: output,
                            fileExtension: "jpg",
                            mimeType: "image/jpeg",
                            pixelSize: CGSize(width: image.width, height: image.height)
                        )
                    }
                }
            }
            targetDimension = Int(Double(targetDimension) * 0.75)
        } while targetDimension >= 32
        throw Error.outputTooLarge
    }

    private func pixelSize(of source: CGImageSource) throws -> CGSize {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { throw Error.invalidData }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    private func encode(
        _ image: CGImage,
        as type: UTType,
        compressionQuality: Double?
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        var properties: [CFString: Any] = [:]
        if let compressionQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func isSupportedRaster(_ type: CFString) -> Bool {
        let identifier = type as String
        return identifier == UTType.png.identifier
            || identifier == UTType.jpeg.identifier
            || identifier == UTType.heic.identifier
            || identifier == UTType.heif.identifier
            || identifier == UTType.tiff.identifier
    }
}

struct ChatAttachmentPreparer: Sendable {
    private let imagePreparer: ImageAttachmentPreparer

    init(imagePreparer: ImageAttachmentPreparer = ImageAttachmentPreparer()) {
        self.imagePreparer = imagePreparer
    }

    func prepare(
        id: String,
        fileName: String,
        mimeType: String,
        data: Data
    ) throws -> ChatAttachment {
        let validatedMetadata = try ChatAttachment(
            id: id,
            fileName: fileName,
            mimeType: mimeType,
            data: Data([0])
        )
        guard validatedMetadata.kind == .image else {
            return try ChatAttachment(
                id: id,
                fileName: fileName,
                mimeType: mimeType,
                data: data
            )
        }
        let image = try imagePreparer.prepare(data: data)
        let baseName = URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
        return try ChatAttachment(
            id: id,
            fileName: "\(baseName).\(image.fileExtension)",
            mimeType: image.mimeType,
            data: image.data
        )
    }
}

private extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            true
        case .none, .noneSkipFirst, .noneSkipLast:
            false
        @unknown default:
            true
        }
    }
}

struct PreparedAvatar: Equatable, Sendable {
    let data: Data
    let fileExtension: String
    let pixelSize: CGSize
}

struct AvatarImageProcessor: Sendable {
    enum Error: Swift.Error, Equatable {
        case invalidData
        case unsupportedFormat
        case sourceTooLarge
        case outputTooLarge
        case processingFailed
    }

    static let maximumInputBytes = ImageAttachmentPreparer.maximumInputBytes
    static let maximumOutputBytes = 1_500_000
    static let maximumPixelDimension: CGFloat = 1_024

    private let fileProtection: any BighelpLocalFileProtecting
    private let protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding

    init(
        fileProtection: any BighelpLocalFileProtecting = BighelpLocalFileProtector(),
        protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability()
    ) {
        self.fileProtection = fileProtection
        self.protectedDataAvailability = protectedDataAvailability
    }

    func prepare(data: Data) throws -> PreparedAvatar {
        do {
            let image = try ImageAttachmentPreparer(
                maximumInputBytes: Self.maximumInputBytes,
                maximumOutputBytes: Self.maximumOutputBytes,
                maximumPixelDimension: Int(Self.maximumPixelDimension)
            ).prepare(data: data)
            return PreparedAvatar(
                data: image.data,
                fileExtension: image.fileExtension,
                pixelSize: image.pixelSize
            )
        } catch let error as ImageAttachmentPreparer.Error {
            throw switch error {
            case .invalidData: Error.invalidData
            case .unsupportedFormat: Error.unsupportedFormat
            case .sourceTooLarge, .sourceDimensionsTooLarge: Error.sourceTooLarge
            case .outputTooLarge: Error.outputTooLarge
            case .processingFailed: Error.processingFailed
            }
        }
    }

    func store(_ avatar: PreparedAvatar, in directory: URL) throws -> String {
        try requireBighelpProtectedData(protectedDataAvailability)
        try fileProtection.prepareDirectory(
            directory,
            protection: .privateVisual,
            fileManager: .default
        )
        let fileName = "avatar-\(UUID().uuidString.lowercased()).\(avatar.fileExtension)"
        let destination = directory.appending(path: fileName, directoryHint: .notDirectory)
        try fileProtection.write(
            avatar.data,
            to: destination,
            protection: .privateVisual
        )
        try fileProtection.apply(
            .privateVisual,
            to: destination,
            fileManager: .default
        )
        return fileName
    }

}
