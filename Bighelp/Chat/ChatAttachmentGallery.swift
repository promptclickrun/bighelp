import AVKit
import Photos
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatAttachmentGallery: View {
    let attachments: [ChatAttachment]
    let alignsTrailing: Bool

    @State private var previewAttachment: ChatAttachment?

    var body: some View {
        // A horizontal scroll view fills its width and pins content to the
        // leading edge, which put the person's own photos on the agent's side.
        // Scroll only when the row overflows so sent photos stay trailing.
        ViewThatFits(in: .horizontal) {
            attachmentRow
            ScrollView(.horizontal) { attachmentRow }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(alignsTrailing ? .trailing : .leading)
        }
        .frame(maxWidth: 560, alignment: alignsTrailing ? .trailing : .leading)
        .accessibilityIdentifier("chat.message-attachments")
        .sheet(item: $previewAttachment) { attachment in
            ChatAttachmentPreviewView(attachment: attachment)
                .bighelpSheetSize(.large)
        }
    }

    private var attachmentRow: some View {
        HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            ForEach(attachments) { attachment in
                if uiV3Enabled, attachment.mimeType.hasPrefix("audio/") {
                    BighelpV3MessageAudioView(attachment: attachment, theme: theme) {
                        previewAttachment = attachment
                    }
                } else {
                    Button {
                        previewAttachment = attachment
                    } label: {
                        attachmentView(attachment)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview \(attachment.fileName)")
                    .accessibilityHint("Opens a preview with save options")
                    .modifier(PictureActionsIfImage(attachment: attachment))
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentView(_ attachment: ChatAttachment) -> some View {
        if attachment.kind == .image, let image = UIImage(data: attachment.data) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: uiV3Enabled ? 208 : 176, height: uiV3Enabled ? 156 : 132)
                    .clipShape(.rect(cornerRadius: uiV3Enabled ? BighelpTokens.radius20 : BighelpTokens.radius12))
                // Messages shows a photo, not its generated file name.
                if !uiV3Enabled {
                    Text(attachment.fileName)
                        .bighelpMessageFont(.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: uiV3Enabled ? 208 : nil, alignment: .leading)
            .padding(uiV3Enabled ? 0 : BighelpTokens.space4)
            .background(uiV3Enabled ? .clear : theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
            .overlay {
                if !uiV3Enabled {
                    RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                        .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                }
            }
        } else {
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .frame(width: 36, height: 36)
                    .background(theme.action.opacity(0.10), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName)
                        .bighelpMessageFont(.label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(attachment.data.count),
                        countStyle: .file
                    ))
                    .bighelpMessageFont(.metadata)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(BighelpTokens.space12)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius12))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                    .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
            }
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme

    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
}

/// Pictures get Copy and Save to Photos on touch and hold; other files keep
/// their tap-to-preview only.
private struct PictureActionsIfImage: ViewModifier {
    let attachment: ChatAttachment

    func body(content: Content) -> some View {
        if attachment.kind == .image {
            content.chatPictureActions(attachment)
        } else {
            content
        }
    }
}

struct ChatAttachmentPreviewView: View {
    let attachment: ChatAttachment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var previewURL: URL?
    @State private var saveDestination: ChatAttachmentSaveDestination?
    @State private var saveActivity = ChatAttachmentSaveActivity()
    @State private var isExporting = false
    @State private var alert: ChatAttachmentSaveAlert?

    var body: some View {
        NavigationStack {
            Group {
                if saveDestination == .photosVideo, let previewURL {
                    VideoPlayer(player: AVPlayer(url: previewURL))
                        .background(.black)
                } else if case .unavailable(let error)? = saveDestination {
                    ContentUnavailableView(
                        "Attachment unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.message)
                    )
                } else if let previewURL {
                    ChatAttachmentQuickLookPreview(url: previewURL)
                } else {
                    ProgressView("Preparing preview…")
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .primaryAction) {
                    saveControl
                        .disabled(saveActivity.isBusy || saveDestination?.canSave != true)
                        .accessibilityValue(saveActivity.isBusy ? "Saving" : "Ready")
                        .accessibilityIdentifier("chat.attachment.save")
                }
                // The file under its own name, for Messages, Mail or another app.
                ToolbarItem(placement: .primaryAction) {
                    if let previewURL, saveDestination?.canSave == true {
                        ShareLink(item: previewURL) {
                            Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                        }
                        .accessibilityIdentifier("chat.attachment.share")
                    }
                }
            }
        }
        .task {
            saveDestination = await ChatAttachmentMediaValidator.destination(for: attachment)
            do {
                previewURL = try ChatAttachmentTemporaryFile.write(attachment)
            } catch {
                alert = .previewFailure
            }
        }
        .onDisappear {
            if let previewURL {
                try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: ChatAttachmentDocument(data: attachment.data),
            contentType: UTType(mimeType: attachment.mimeType) ?? .data,
            defaultFilename: attachment.fileName
        ) { result in
            saveActivity.finish()
            if case .failure = result {
                alert = .filesFailure
            }
        }
        .alert(item: $alert) { alert in
            if alert.offersSettings {
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Settings"), action: openSettings),
                    secondaryButton: .cancel()
                )
            } else {
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
        }
    }

    @ViewBuilder
    private var saveControl: some View {
        if saveDestination == .photosImage || saveDestination == .photosVideo {
            Menu {
                Button("Save to Files", systemImage: "folder", action: beginFilesSave)
                Button("Save to Photos", systemImage: "photo", action: beginSave)
            } label: {
                saveLabel
            }
            .accessibilityLabel("Save attachment")
        } else {
            Button(action: beginSave) { saveLabel }
                .accessibilityLabel(saveDestination?.accessibilityLabel ?? "Save attachment")
        }
    }

    @ViewBuilder
    private var saveLabel: some View {
        if saveActivity.isBusy {
            ProgressView().controlSize(.small).accessibilityHidden(true)
        } else {
            Label("Save", systemImage: "square.and.arrow.down").labelStyle(.iconOnly)
        }
    }

    private func beginFilesSave() {
        guard saveDestination?.canSave == true, saveActivity.begin() else { return }
        isExporting = true
    }

    private func beginSave() {
        guard let saveDestination, saveDestination.canSave, saveActivity.begin() else { return }
        if saveDestination == .files {
            isExporting = true
            return
        }
        let immutableAttachment = attachment
        Task {
            await saveToPhotos(attachment: immutableAttachment, destination: saveDestination)
        }
    }

    private func saveToPhotos(
        attachment: ChatAttachment,
        destination: ChatAttachmentSaveDestination
    ) async {
        defer { saveActivity.finish() }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            alert = ChatAttachmentPhotosAuthorizationRecovery.requiresSettings(authorization)
                ? .photosPermission
                : .photosFailure
            return
        }
        do {
            switch destination {
            case .photosImage:
                try await ChatAttachmentPhotosSaver.saveImage(attachment.data)
            case .photosVideo:
                try await ChatAttachmentPhotosSaver.saveVideo(
                    data: attachment.data,
                    fileName: attachment.fileName
                )
            case .files, .unavailable:
                return
            }
            alert = .photosSuccess
        } catch {
            alert = .photosFailure
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private enum ChatAttachmentSaveAlert: String, Identifiable {
    case previewFailure
    case filesFailure
    case photosPermission
    case photosFailure
    case photosSuccess

    var id: String { rawValue }
    var title: String { "Attachment" }

    var message: String {
        switch self {
        case .previewFailure:
            "This attachment could not be prepared for preview."
        case .filesFailure:
            "The attachment was not saved to Files."
        case .photosPermission:
            "Photos access is denied or restricted. Allow Photos access in Settings to save this attachment."
        case .photosFailure:
            "The attachment could not be saved to Photos."
        case .photosSuccess:
            "Saved to Photos."
        }
    }

    var offersSettings: Bool { self == .photosPermission }
}

struct ChatAttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum ChatAttachmentTemporaryFile {
    static func write(_ attachment: ChatAttachment) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: attachment.fileName, directoryHint: .notDirectory)
        try attachment.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        return url
    }
}

private struct ChatAttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
