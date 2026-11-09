import Foundation
import UniformTypeIdentifiers

/// What another app handed over, reduced to something a prompt can carry.
struct ShareInput {
    var text = ""
    var link: String?
    var attachments: [ShareAttachment] = []

    var isEmpty: Bool { text.isEmpty && link == nil && attachments.isEmpty }
}

/// Reads the share sheet's items off the `NSExtensionContext`.
///
/// Everything an extension receives has to fit in its own memory, so this refuses
/// anything the app would have handed to its chunked uploader instead of half-loading it.
@MainActor
enum ShareInputReader {
    nonisolated static let maximumItems = 4

    static func read(from context: NSExtensionContext?) async -> ShareInput {
        guard let items = context?.inputItems as? [NSExtensionItem] else { return ShareInput() }
        let providers = items.flatMap { $0.attachments ?? [] }.prefix(maximumItems)
        var input = ShareInput()
        var carried = 0

        for provider in providers {
            if let url = await url(from: provider) {
                if url.isFileURL {
                    if let attachment = file(at: url, suggestedName: provider.suggestedName,
                                             carried: &carried) {
                        input.attachments.append(attachment)
                    }
                } else {
                    // A web link travels as text in the prompt's own words.
                    input.link = url.absoluteString
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let attachment = await image(from: provider, carried: &carried) {
                input.attachments.append(attachment)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = await text(from: provider) {
                input.text = [input.text, text].filter { !$0.isEmpty }.joined(separator: "\n")
                continue
            }
            if let attachment = await data(from: provider, carried: &carried) {
                input.attachments.append(attachment)
            }
        }
        return input
    }

    // MARK: - Item loading

    private static func url(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data, let text = String(data: data, encoding: .utf8),
                        let url = URL(string: text) { continuation.resume(returning: url) }
                else if let text = item as? String, let url = URL(string: text) { continuation.resume(returning: url) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                if let text = item as? String { continuation.resume(returning: text) }
                else if let data = item as? Data { continuation.resume(returning: String(data: data, encoding: .utf8)) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private static func image(from provider: NSItemProvider, carried: inout Int) async -> ShareAttachment? {
        let type = UTType.image.identifier
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, fits(data.count, carried: &carried) else { return nil }
        let name = provider.suggestedName.map { $0.contains(".") ? $0 : $0 + ".jpg" } ?? "Shared picture.jpg"
        return ShareAttachment(kind: .image, fileName: String(name.prefix(180)),
                               mimeType: "image/jpeg", data: data)
    }

    /// A file another app owns arrives as a temporary URL that is deleted as soon as the
    /// completion returns, so its bytes are read inside the callback.
    private static func data(from provider: NSItemProvider, carried: inout Int) async -> ShareAttachment? {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: { candidate in
            UTType(candidate)?.conforms(to: .data) == true || UTType(candidate)?.conforms(to: .content) == true
        }) else { return nil }
        let loaded: (Data, String)? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url, let data = try? Data(contentsOf: url), data.count <= ShareSender.maximumItemBytes
                else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (data, url.lastPathComponent))
            }
        }
        guard let (data, name) = loaded, fits(data.count, carried: &carried) else { return nil }
        let mime = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return ShareAttachment(kind: .file, fileName: String(name.prefix(180)), mimeType: mime, data: data)
    }

    private static func file(at url: URL, suggestedName: String?, carried: inout Int) -> ShareAttachment? {
        guard let data = try? Data(contentsOf: url), fits(data.count, carried: &carried) else { return nil }
        let name = suggestedName ?? url.lastPathComponent
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ShareAttachment(kind: .file, fileName: String(name.prefix(180)), mimeType: mime, data: data)
    }

    private static func fits(_ byteCount: Int, carried: inout Int) -> Bool {
        guard byteCount > 0, byteCount <= ShareSender.maximumItemBytes,
              carried + byteCount <= ShareSender.maximumBatchBytes else { return false }
        carried += byteCount
        return true
    }
}
