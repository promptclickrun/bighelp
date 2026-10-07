import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DirectHermesFileAttachments {
    static let maximumBatchBytes = 24 * 1_024 * 1_024
    static let maximumFrameBytes = 12 * 1_024 * 1_024
    static let imagesUnavailable = "Images are unavailable on native connections until Hermes can bind an upload to the intended message. Ordinary files are supported."

    static func validate(_ attachments: [ChatAttachment], message: String) throws {
        guard !attachments.isEmpty, attachments.count <= 10,
              Set(attachments.map(\.id)).count == attachments.count,
              message.utf8.count <= 1_048_576 else { throw DirectHermesError.messageTooLarge }
        var total = 0
        for attachment in attachments {
            guard (1...ChatAttachment.maximumBytes).contains(attachment.data.count),
                  attachment.fileName.utf8.count <= 720 else { throw ChatAttachmentError.invalidSize }
            let extensionType = UTType(filenameExtension: URL(fileURLWithPath: attachment.fileName).pathExtension)
            // Only an image type counts: Image I/O also opens PDFs (as pages), and those are files.
            let recognizedImage = CGImageSourceCreateWithData(attachment.data as CFData, nil)
                .flatMap { CGImageSourceGetType($0) }
                .flatMap { UTType($0 as String) }?
                .conforms(to: .image) ?? false
            guard attachment.kind != .image, extensionType?.conforms(to: .image) != true,
                  !recognizedImage else {
                throw ChatAttachmentError.unsupportedKind
            }
            total += attachment.data.count
            guard total <= maximumBatchBytes else { throw ChatAttachmentError.invalidSize }
        }
    }

    static func payload(_ attachment: ChatAttachment, runtimeID: String) -> [String: BighelpJSONValue] {
        ["session_id": .string(runtimeID), "name": .string(attachment.fileName),
         "data_url": .string("data:\(attachment.mimeType);base64," + attachment.data.base64EncodedString())]
    }

    static func reference(_ value: BighelpJSONValue) throws -> String {
        guard let object = value.object, object["attached"]?.boolean == true,
              object["uploaded"]?.boolean == true,
              let name = object["name"]?.string, !name.isEmpty, name.utf8.count <= 720,
              let path = object["path"]?.string, !path.isEmpty, path.utf8.count <= 4_096,
              let referencePath = object["ref_path"]?.string, !referencePath.isEmpty, referencePath.utf8.count <= 4_096,
              let text = object["ref_text"]?.string, text.utf8.count <= 8_192,
              [name, path, referencePath, text].allSatisfy({
                  !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }),
              path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) == name,
              referencePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) == name,
              text.hasPrefix("@file:") else { throw DirectHermesError.invalidResponse }
        guard let decoded = referenceValue(String(text.dropFirst(6))),
              decoded.utf8.elementsEqual(referencePath.utf8) else { throw DirectHermesError.invalidResponse }
        return text
    }

    /// Stock reference wrappers are delimiters, not shell or URL escaping.
    static func referenceValue(_ token: String) -> String? {
        if let quote = token.first, ["`", "\"", "'"].contains(quote), token.last == quote, token.count >= 2 {
            let decoded = String(token.dropFirst().dropLast())
            return decoded.contains(quote) ? nil : decoded
        } else {
            guard !token.contains(where: { $0.isWhitespace || "[]\"'`".contains($0) }) else {
                return nil
            }
            return token
        }
    }

    static func permitsLargeFrame(method: String, params: [String: BighelpJSONValue]) -> Bool {
        guard method == "file.attach", Set(params.keys) == ["session_id", "name", "data_url"],
              let session = params["session_id"]?.string, !session.isEmpty, session.utf8.count <= 512,
              let name = params["name"]?.string, !name.isEmpty, name.utf8.count <= 720,
              let dataURL = params["data_url"]?.string, dataURL.hasPrefix("data:"),
              !dataURL.prefix(11).lowercased().hasPrefix("data:image/"),
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].hasSuffix(";base64"),
              dataURL[..<comma].utf8.count <= 140,
              dataURL[dataURL.index(after: comma)...].utf8.count <= ((ChatAttachment.maximumBytes + 2) / 3) * 4 else {
            return false
        }
        return true
    }
}
