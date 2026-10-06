import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Files an agent attached to a Feed post (plugin `native-agent-board-files-v1`): a compact
// row on the post, the post itself with every file, and a preview to save or share each.

/// What a post's compact row shows: up to three pictures, then one chip for the other files.
struct BoardFileSummary: Equatable {
    static let shownPictures = 3

    let pictures: [AgentBoardItem.File]
    /// Pictures past the first three, as "+2" on the last one.
    let morePictures: Int
    let others: [AgentBoardItem.File]

    init(files: [AgentBoardItem.File]) {
        let images = files.filter(\.isImage)
        pictures = Array(images.prefix(Self.shownPictures))
        morePictures = max(0, images.count - Self.shownPictures)
        others = files.filter { !$0.isImage }
    }

    /// One file goes by its name; several by their count.
    var chipTitle: String? {
        switch others.count {
        case 0: nil
        case 1: others[0].fileName
        default: "\(others.count) files"
        }
    }

    var chipSymbol: String { others.count == 1 ? others[0].systemImage : "doc.on.doc" }

    var accessibilityLabel: String {
        let pictureCount = pictures.count + morePictures
        let total = pictureCount + others.count
        var parts: [String] = []
        if pictureCount > 0 { parts.append(pictureCount == 1 ? "1 picture" : "\(pictureCount) pictures") }
        if let chipTitle { parts.append(chipTitle) }
        return (total == 1 ? "1 attachment: " : "\(total) attachments: ") + parts.joined(separator: ", ")
    }
}

/// The post's files in the Feed: picture thumbnails and a file chip. A tap opens the post.
struct BoardFilesStrip: View {
    let item: AgentBoardItem
    let files: [AgentBoardItem.File]
    let store: AgentBoardStore
    let onOpen: () -> Void

    var body: some View {
        let summary = BoardFileSummary(files: files)
        Button(action: onOpen) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(summary.pictures) { file in
                    BoardFileThumbnail(item: item, file: file, store: store)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            if file == summary.pictures.last, summary.morePictures > 0 {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.black.opacity(0.45))
                                    .overlay {
                                        Text("+\(summary.morePictures)")
                                            .font(.bighelp(.headline))
                                            .foregroundStyle(.white)
                                    }
                            }
                        }
                }
                if let title = summary.chipTitle {
                    Label {
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: summary.chipSymbol)
                            .foregroundStyle(theme.action)
                    }
                    .font(.bighelp(.subheadline).weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .background(Capsule().fill(theme.incomingMessageBackground))
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: BighelpTokens.hairline))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        // Only the row takes the tap in a List row.
        .bighelpPlainButtonStyle()
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Opens the post")
        .accessibilityIdentifier("board.feed.files.\(item.id)")
    }

    @BighelpThemeReader private var theme
}

/// A post's picture: its small copy, the loading glow while it comes from the host, or a
/// plain sign when the host no longer serves it. Never the file's path.
struct BoardFileThumbnail: View {
    let item: AgentBoardItem
    let file: AgentBoardItem.File
    let store: AgentBoardStore

    var body: some View {
        Color.clear
            .overlay {
                if let image = store.thumbnail(item, file) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if store.fileState(item, file) == .unavailable {
                    ZStack {
                        theme.incomingMessageBackground
                        Image(systemName: "exclamationmark.triangle")
                            .font(.bighelp(.title3))
                            .foregroundStyle(theme.secondaryText)
                    }
                } else {
                    BighelpImageGeneratingView(caption: "Loading your image", variant: .develop, size: .compact,
                                               phaseOffset: Double(file.index) * 0.4)
                }
            }
            .clipped()
            .task(id: "\(item.id)#\(file.index)") { await store.loadThumbnail(for: item, file: file) }
            .accessibilityElement()
            .accessibilityLabel(label)
    }

    private var label: String {
        if store.thumbnail(item, file) != nil { return "Picture: \(file.fileName)" }
        return store.fileState(item, file) == .unavailable ? "Couldn't load \(file.fileName)" : "Loading \(file.fileName)"
    }

    @BighelpThemeReader private var theme
}

/// A tap on a post's icon, title or pictures opens it, when it has files. Its Markdown keeps
/// its own links, so the text isn't a tap target.
struct OpensPost: ViewModifier {
    let isEnabled: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .bighelpPointer()
                .contentShape(.rect)
                .onTapGesture(perform: open)
        } else {
            content
        }
    }
}

/// The same for VoiceOver, on the whole post.
struct OpensPostForVoiceOver: ViewModifier {
    let isEnabled: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: "Open post", open)
        } else {
            content
        }
    }
}

// MARK: - The post

/// Which post is open; a post the person clears closes it.
struct OpenedFeedPost: Identifiable, Equatable {
    let id: String
}

/// The whole post, with every file it carries. Tap a file to preview it, then save or
/// share it; hold it (right-click on the Mac) to share or save without opening.
struct FeedPostDetailSheet: View {
    let itemID: String
    let context: AgentBoardContext
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ChatAttachment?
    @State private var exporting: ChatAttachment?
    @State private var notice: BoardFileNotice?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let item = context.store.items.first(where: { $0.id == itemID && !$0.dismissed }) {
                    VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                        BighelpDeferredSection { header(item) }
                        BighelpDeferredSection { files(item) }
                        BighelpDeferredSection { links(item) }
                    }
                    .padding(BighelpTokens.space24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("board.feed.detail.done")
                }
            }
        }
        .modifier(BoardFilePreview(attachment: $preview))
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: ChatAttachmentDocument(data: exporting?.data ?? Data()),
                      contentType: exporting.flatMap { UTType(mimeType: $0.mimeType) } ?? .data,
                      defaultFilename: exporting?.fileName) { result in
            exporting = nil
            if case .failure = result { notice = .filesFailure }
        }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.message))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.feed.detail")
    }

    private func header(_ item: AgentBoardItem) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                BoardIcon(icon: item.icon, fallback: "newspaper", size: 56)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(item.title)
                        .font(.bighelp(.title2).weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text((item.source.isEmpty ? "Posted by \(context.agentName)" : item.source) + " · "
                         + item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            if !item.body.isEmpty {
                MarkdownMessageView(document: MarkdownDocument(item.body), primaryText: theme.primaryText)
                    .foregroundStyle(theme.primaryText)
                    .tint(theme.action)
            }
            if !item.pictures.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BighelpTokens.space8) {
                        ForEach(Array(item.pictures.enumerated()), id: \.offset) { _, picture in
                            BoardPictureView(item: item, picture: picture, store: context.store)
                                .frame(width: 220, height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private func files(_ item: AgentBoardItem) -> some View {
        let files = context.store.visibleFiles(of: item)
        if !files.isEmpty {
            let pictures = files.filter(\.isImage)
            let others = files.filter { !$0.isImage }
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text(files.count == 1 ? "1 attachment" : "\(files.count) attachments")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                if !pictures.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: BighelpTokens.space12)],
                              spacing: BighelpTokens.space12) {
                        ForEach(pictures) { file in
                            fileButton(item, file) { pictureTile(item, file) }
                        }
                    }
                }
                ForEach(others) { file in
                    fileButton(item, file) { fileRow(item, file) }
                }
            }
        }
    }

    private func fileButton<Label: View>(_ item: AgentBoardItem, _ file: AgentBoardItem.File,
                                         @ViewBuilder label: () -> Label) -> some View {
        Button { open(item, file) } label: { label() }
            .bighelpPlainButtonStyle()
            .disabled(context.store.isOpening(item, file))
            .contextMenu { BoardFileMenu(item: item, file: file, store: context.store, open: { open(item, file) },
                                         saveToFiles: { save(item, file) },
                                         saveToPhotos: { saveToPhotos(item, file) }) }
            .accessibilityLabel(file.fileName)
            .accessibilityValue(stateText(item, file))
            .accessibilityHint("Opens a preview to save or share it")
            .accessibilityIdentifier("board.feed.detail.file.\(file.index)")
    }

    private func pictureTile(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            BoardFileThumbnail(item: item, file: file, store: context.store)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
                .overlay { openingSpinner(item, file) }
            Text(file.fileName)
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(.rect)
    }

    private func fileRow(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: file.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(width: 44, height: 44)
                .background(theme.action.opacity(0.10), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.bighelp(.body).weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(stateText(item, file))
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: BighelpTokens.space8)
            if context.store.isOpening(item, file) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(BighelpTokens.space12)
        .frame(minHeight: BighelpTokens.hitTarget)
        .background(theme.incomingMessageBackground, in: .rect(cornerRadius: BighelpTokens.radius16))
        .contentShape(.rect)
    }

    @ViewBuilder
    private func openingSpinner(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> some View {
        if context.store.isOpening(item, file) {
            BighelpSpinner(size: 18, lineWidth: 2, color: .white)
                .padding(10)
                .background(.black.opacity(0.4), in: Circle())
        }
    }

    private func stateText(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> String {
        if context.store.isOpening(item, file) { return "Loading…" }
        if context.store.fileState(item, file) == .unavailable { return "Couldn't load. Tap to try again." }
        return file.sizeText
    }

    @ViewBuilder
    private func links(_ item: AgentBoardItem) -> some View {
        if !item.links.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                ForEach(item.links, id: \.url) { link in
                    Link(destination: link.url) {
                        Label(link.title.isEmpty ? (link.url.host() ?? "Open link") : link.title, systemImage: "link")
                            .font(.bighelp(.subheadline).weight(.medium))
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .tint(theme.action)
                }
            }
        }
        Button {
            dismiss()
            context.onAsk("About “\(item.title)”: ")
        } label: {
            Label("Discuss", systemImage: "bubble.left")
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("board.feed.detail.discuss")
    }

    private func open(_ item: AgentBoardItem, _ file: AgentBoardItem.File) {
        Task {
            if let attachment = await context.store.attachment(for: item, file: file) { preview = attachment }
        }
    }

    private func save(_ item: AgentBoardItem, _ file: AgentBoardItem.File) {
        Task {
            if let attachment = await context.store.attachment(for: item, file: file) { exporting = attachment }
        }
    }

    private func saveToPhotos(_ item: AgentBoardItem, _ file: AgentBoardItem.File) {
        Task {
            guard let attachment = await context.store.attachment(for: item, file: file) else { return }
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                notice = .photosPermission
                return
            }
            do {
                try await ChatAttachmentPhotosSaver.saveImage(attachment.data)
                notice = .photosSaved
            } catch {
                notice = .photosFailure
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// Hold a file in the post (right-click on the Mac): open, share or save it without
/// opening it first. Each fetches the file when chosen, if it isn't on the phone yet.
private struct BoardFileMenu: View {
    let item: AgentBoardItem
    let file: AgentBoardItem.File
    let store: AgentBoardStore
    let open: () -> Void
    let saveToFiles: () -> Void
    let saveToPhotos: () -> Void

    var body: some View {
        Button("Open", systemImage: "eye", action: open)
        ShareLink(item: BoardFileShareItem(store: store, item: item, file: file),
                  preview: SharePreview(file.fileName)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button("Save to Files", systemImage: "folder", action: saveToFiles)
        if file.isImage {
            Button("Save to Photos", systemImage: "photo", action: saveToPhotos)
        }
    }
}

private enum BoardFileNotice: String, Identifiable {
    case filesFailure, photosPermission, photosFailure, photosSaved
    var id: String { rawValue }
    var message: String {
        switch self {
        case .filesFailure: "The file wasn't saved to Files."
        case .photosPermission: "Allow bighelp to add to Photos in Settings to save pictures."
        case .photosFailure: "The picture couldn't be saved to Photos."
        case .photosSaved: "Saved to Photos."
        }
    }
}

/// A post's file for the share sheet, fetched only once something asks for it.
struct BoardFileShareItem: Transferable {
    let store: AgentBoardStore
    let item: AgentBoardItem
    let file: AgentBoardItem.File

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { try await $0.sharedFile() }
            .exportingCondition { $0.file.mimeType == "image/png" }
        FileRepresentation(exportedContentType: .jpeg) { try await $0.sharedFile() }
            .exportingCondition { $0.file.mimeType == "image/jpeg" }
        FileRepresentation(exportedContentType: .pdf) { try await $0.sharedFile() }
            .exportingCondition { $0.file.mimeType == "application/pdf" }
        FileRepresentation(exportedContentType: .data) { try await $0.sharedFile() }
    }

    private func sharedFile() async throws -> SentTransferredFile {
        guard let attachment = await store.attachment(for: item, file: file) else { throw CocoaError(.fileReadUnknown) }
        return SentTransferredFile(try BoardSharedFiles.write(attachment))
    }
}

/// Copies handed to the share sheet. Only the latest is kept.
enum BoardSharedFiles {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "BighelpSharedFiles", directoryHint: .isDirectory)

    static func write(_ attachment: ChatAttachment) throws -> URL {
        try? FileManager.default.removeItem(at: folder)
        let directory = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: attachment.fileName, directoryHint: .notDirectory)
        try attachment.data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// Pictures open full screen on iPhone and iPad to pinch and zoom; other files, and every
/// file on the Mac and Vision Pro, open in a sheet. Both have Save and Share.
private struct BoardFilePreview: ViewModifier {
    @Binding var attachment: ChatAttachment?

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst) || os(visionOS)
        content.bighelpSheet(item: $attachment) { ChatAttachmentPreviewView(attachment: $0).bighelpSheetSize(.large) }
        #else
        content
            .bighelpSheet(item: binding(pictures: false)) { ChatAttachmentPreviewView(attachment: $0).bighelpSheetSize(.large) }
            .bighelpFullScreenCover(item: binding(pictures: true)) { ChatAttachmentPreviewView(attachment: $0) }
        #endif
    }

    private func binding(pictures: Bool) -> Binding<ChatAttachment?> {
        Binding(get: { attachment.flatMap { ($0.kind == .image) == pictures ? $0 : nil } },
                set: { if $0 == nil { attachment = nil } })
    }
}
