import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// Touch and hold (right-click on the Mac) a picture in the chat to copy it
    /// for a quick paste, or save it to Photos, without opening it first.
    func chatPictureActions(_ attachment: ChatAttachment) -> some View {
        modifier(ChatPictureActions(attachment: attachment))
    }
}

enum ChatPictureClipboard {
    /// The picture in its own format, plus a PNG when that format isn't one
    /// every app pastes (WebP, HEIC…).
    static func items(data: Data, mimeType: String) -> [[String: Any]] {
        let type = UTType(mimeType: mimeType.lowercased())
        var item: [String: Any] = [:]
        if let type, type.conforms(to: .image) { item[type.identifier] = data }
        if type != .png, type != .jpeg, let png = UIImage(data: data)?.pngData() {
            item[UTType.png.identifier] = png
        }
        return item.isEmpty ? [] : [item]
    }
}

private struct ChatPictureActions: ViewModifier {
    let attachment: ChatAttachment
    @State private var result: SaveResult?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .accessibilityIdentifier("chat.picture.copy")
                Button("Save to Photos", systemImage: "square.and.arrow.down") {
                    Task { await save() }
                }
                .accessibilityIdentifier("chat.picture.save")
            }
            .accessibilityAction(named: "Copy picture", copy)
            .accessibilityAction(named: "Save to Photos") { Task { await save() } }
            .alert(item: $result) { result in
                if result == .needsPermission {
                    Alert(title: Text("Allow Photos"), message: Text(result.message),
                          primaryButton: .default(Text("Open Settings")) {
                              if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                          },
                          secondaryButton: .cancel())
                } else {
                    Alert(title: Text(result.message))
                }
            }
    }

    private func copy() {
        let items = ChatPictureClipboard.items(data: attachment.data, mimeType: attachment.mimeType)
        guard !items.isEmpty else { return }
        UIPasteboard.general.setItems(items)
        BighelpHaptics.success()
        UIAccessibility.post(notification: .announcement, argument: "Picture copied")
    }

    private func save() async {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            result = ChatAttachmentPhotosAuthorizationRecovery.requiresSettings(authorization) ? .needsPermission : .failed
            return
        }
        do {
            try await ChatAttachmentPhotosSaver.saveImage(attachment.data)
            BighelpHaptics.success()
            UIAccessibility.post(notification: .announcement, argument: "Saved to Photos")
        } catch {
            result = .failed
        }
    }

    private enum SaveResult: String, Identifiable {
        case needsPermission, failed
        var id: String { rawValue }
        var message: String {
            switch self {
            case .needsPermission: "Allow Bighelp to add to Photos in Settings to save pictures."
            case .failed: "The picture couldn't be saved to Photos."
            }
        }
    }
}
