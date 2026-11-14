import SwiftUI
import UniformTypeIdentifiers

/// What the plus button beside the message box can add to a message, in the order its menu
/// shows them. Everything else the old "Add to chat" sheet held lives where people already look:
/// the model chip and the voice button in the message box, New chat, and Settings.
enum ChatActionMenuAction: String, CaseIterable, Identifiable, Sendable {
    case camera
    case scanDocument
    case photo
    case file
    case drawing

    var id: Self { self }

    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .scanDocument: String(localized: "Scan Document")
        case .photo: String(localized: "Photo Library")
        case .file: String(localized: "Files")
        case .drawing: String(localized: "Drawing")
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera"
        case .scanDocument: "doc.viewfinder"
        case .photo: "photo"
        case .file: "folder"
        case .drawing: "scribble"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .camera: "chat.action.camera"
        case .scanDocument: "chat.action.scan-document"
        case .photo: "chat.action.photo"
        case .file: "chat.action.file"
        case .drawing: "chat.action.drawing"
        }
    }

    /// The actions this device has at all. Drawing is Apple's canvas, on iPhone and iPad.
    static var offered: [Self] {
        allCases.filter { action in
            switch action {
            case .drawing: ChatDrawingSheet.isSupported
            case .scanDocument: ChatDocumentScanner.isSupported
            case .camera, .photo, .file: true
            }
        }
    }

    /// Whether the chat's connection takes what this adds: a picture for the camera, the library
    /// and a drawing, a file for Files and a scan (a PDF).
    func isAvailable(taking kinds: Set<ChatAttachment.Kind>, hasCamera: Bool) -> Bool {
        switch self {
        case .camera: kinds.contains(.image) && hasCamera
        case .photo, .drawing: kinds.contains(.image)
        case .file, .scanDocument: kinds.contains(.file)
        }
    }
}

/// The plus button's menu. A native menu, so it opens at the button and closes on a pick.
struct ChatAttachmentMenu<Label: View>: View {
    let model: ChatModel
    let perform: (ChatActionMenuAction) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            let kinds = model.supportedAttachmentKinds
            ForEach(ChatActionMenuAction.offered) { action in
                Button(action.title, systemImage: action.symbol) { perform(action) }
                    .disabled(!action.isAvailable(taking: kinds, hasCamera: ChatCameraPicker.isAvailable))
            }
        } label: {
            label()
        }
        // Top to bottom as listed, also when the menu opens upward from the message box.
        .menuOrder(.fixed)
    }
}

enum ChatReferenceDocumentBuilder {
    static func markdown(for record: SessionRecord) throws -> String {
        var result = "# \(record.title)\n\nReferenced Bighelp session: `\(record.id)`\n"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for item in record.items {
            var section = "\n## \(item.sender.snapshot.name)\n\n"
            switch item.content {
            case .message(let text):
                section += text
            default:
                section += "```json\n"
                section += String(data: try encoder.encode(item.content), encoding: .utf8) ?? "{}"
                section += "\n```"
            }
            if !item.attachments.isEmpty {
                section += "\n\nAttachments: "
                section += item.attachments.map(\.fileName).joined(separator: ", ")
            }
            section += "\n"

            guard result.utf8.count + section.utf8.count < 7_500_000 else {
                result += "\n_This reference was shortened to fit the attachment limit._\n"
                break
            }
            result += section
        }
        return result
    }

    static func fileName(for record: SessionRecord) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = record.title.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let compact = slug.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "session-reference-\(String((compact.isEmpty ? record.id : compact).prefix(120))).md"
    }
}
