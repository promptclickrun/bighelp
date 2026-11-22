import AVKit
#if os(iOS)
import MediaPlayer
#endif
import Observation
import Photos
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One process-wide owner for the bounded audio bytes, independent of chat and preview lifetimes.
@MainActor
@Observable
final class ChatAttachmentPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = ChatAttachmentPlayback()

    private(set) var activeID: String?
    private(set) var isPlaying = false
    private(set) var failed = false
    private var seekRevision = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var attachment: ChatAttachment?
    @ObservationIgnored private var claim: VoiceAudioSessionClaim?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var resetObserver: (any NSObjectProtocol)?
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private var run: UUID?
    private var track: UUID?
    #if os(iOS)
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    #endif

    init(sessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.sessionCoordinator = sessionCoordinator
    }

    var duration: TimeInterval { player?.duration ?? 0 }
    var elapsed: TimeInterval {
        _ = seekRevision
        return Self.clampedPosition(player?.currentTime ?? 0, duration: duration) ?? 0
    }

    func toggle(_ attachment: ChatAttachment) throws {
        guard attachment.isAudio else { throw PlaybackError.unavailable }
        if self.attachment == attachment, !failed {
            if isPlaying { pause() } else { try resume() }
            return
        }

        // Decode only on explicit play. Using data rather than a URL keeps playback local and
        // avoids a staging file that might be deleted or become unreadable when the phone locks.
        let next = try AVAudioPlayer(data: attachment.data)
        guard next.duration.isFinite, next.duration > 0 else { throw PlaybackError.unavailable }
        stop()
        player = next
        next.delegate = self
        do {
            try resume()
        } catch {
            stop()
            throw error
        }
        self.attachment = attachment
        activeID = attachment.id
        let token = UUID()
        track = token
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.track == token else { return }
                self.stop()
            }
        }
        #if os(iOS)
        installRemoteCommands(token: token)
        #endif
        publishNowPlaying()
    }

    private func resume() throws {
        guard !isPlaying, !failed, let player else { return }
        guard LiveVoiceCurrentCall.shared.call == nil else { throw VoiceAudioSessionError.heldByLiveCall }
        claim = try sessionCoordinator.acquire(for: .attachmentPlayback)
        observeAudioSession()
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else {
            pause()
            throw PlaybackError.unavailable
        }
        isPlaying = true
        publishNowPlaying()
    }

    func pause() {
        guard claim != nil else { return }
        player?.pause()
        isPlaying = false
        run = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        claim?.release()
        claim = nil
        publishNowPlaying()
    }

    func stop() {
        pause()
        #if os(iOS)
        clearNowPlaying()
        #endif
        track = nil
        if let resetObserver {
            NotificationCenter.default.removeObserver(resetObserver)
            self.resetObserver = nil
        }
        player?.stop()
        player = nil
        attachment = nil
        activeID = nil
        failed = false
    }

    func seek(to position: TimeInterval, id: String) {
        guard activeID == id, let player,
              let position = Self.clampedPosition(position, duration: player.duration) else { return }
        player.currentTime = position
        seekRevision &+= 1
        publishNowPlaying()
    }

    static func clampedPosition(_ position: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(0, position), duration)
    }

    private func observeAudioSession() {
        let token = UUID()
        run = token
        for (name, key, reason) in [
            (AVAudioSession.interruptionNotification, AVAudioSessionInterruptionTypeKey,
             AVAudioSession.InterruptionType.began.rawValue),
            (AVAudioSession.routeChangeNotification, AVAudioSessionRouteChangeReasonKey,
             AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue),
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                @Sendable [weak self] notification in
                guard notification.userInfo?[key] as? UInt == reason else { return }
                Task { @MainActor in
                    guard let self, self.run == token else { return }
                    self.pause()
                }
            })
        }
    }

    #if os(iOS)
    private func installRemoteCommands(token: UUID) {
        let commands = MPRemoteCommandCenter.shared()
        addRemoteTarget(commands.playCommand, token: token, action: .play)
        addRemoteTarget(commands.pauseCommand, token: token, action: .pause)
        addRemoteTarget(commands.togglePlayPauseCommand, token: token, action: .toggle)
        addRemoteTarget(commands.changePlaybackPositionCommand, token: token, action: .seek)
    }

    private enum RemoteAction: Sendable { case play, pause, toggle, seek }

    private func addRemoteTarget(_ command: MPRemoteCommand, token: UUID, action: RemoteAction) {
        command.isEnabled = true
        let target = command.addTarget { @Sendable [weak self] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            if action == .seek, position?.isFinite != true { return .commandFailed }
            Task { @MainActor in
                guard let self, self.track == token else { return }
                switch action {
                case .play: try? self.resume()
                case .pause: self.pause()
                case .toggle:
                    if self.isPlaying { self.pause() } else { try? self.resume() }
                case .seek:
                    if let position, let id = self.activeID { self.seek(to: position, id: id) }
                }
            }
            return .success
        }
        remoteTargets.append((command, target))
    }

    private func clearNowPlaying() {
        guard track != nil else { return }
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    #endif

    private func publishNowPlaying() {
        #if os(iOS)
        guard track != nil else { return }
        // The filename and chat identity stay inside the app, not on the lock screen.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: String(localized: "Chat audio"),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(ObjectIdentifier(player), succeeded: flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finish(ObjectIdentifier(player), succeeded: false)
    }

    private nonisolated func finish(_ identity: ObjectIdentifier, succeeded: Bool) {
        Task { @MainActor [weak self] in
            guard let self, let player = self.player, ObjectIdentifier(player) == identity else { return }
            let id = self.activeID
            self.stop()
            if !succeeded {
                self.activeID = id
                self.failed = true
            }
        }
    }

    private enum PlaybackError: Error { case unavailable }
}

struct ChatAttachmentGallery: View {
    let attachments: [ChatAttachment]
    let alignsTrailing: Bool

    @State private var previewAttachment: ChatAttachment?
    /// A picture opened on its own, over the whole display (the Duo).
    @State private var photoViewer: ChatPhotoStart?
    @Environment(\.bighelpScreen) private var screen

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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.message-attachments")
        .bighelpSheet(item: $previewAttachment) { attachment in
            ChatAttachmentPreviewView(attachment: attachment, audioFileOptionsOnly: attachment.isAudio)
                .bighelpSheetSize(.large)
        }
        .bighelpMediaPresentation(item: $photoViewer) { start in
            ChatImageStackViewer(images: start.images, startIndex: start.index, fullBleed: start.presentsFullScreen)
        }
    }

    /// A picture goes straight to the photo viewer where it can take the whole display (the Duo);
    /// everything else keeps the preview sheet, with its file name and save options.
    private func open(_ attachment: ChatAttachment) {
        if attachment.kind == .image, ChatImageStackContent.isFullBleed(screen) {
            photoViewer = ChatPhotoStart(images: [attachment], index: 0, screen: screen)
        } else {
            previewAttachment = attachment
        }
    }

    /// Two or more pictures go in one stack; anything else keeps its own tile beside it.
    private var stackedImages: [ChatAttachment] {
        let images = ChatImageStackContent.split(attachments).images
        return ChatImageStackContent.showsStack(images) ? images : []
    }

    private var attachmentRow: some View {
        let stacked = stackedImages
        let stackedIDs = Set(stacked.map(\.id))
        return HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            if !stacked.isEmpty {
                ChatImageStackView(images: stacked)
            }
            ForEach(attachments.filter { !stackedIDs.contains($0.id) }) { attachment in
                if attachment.isAudio {
                    ChatAttachmentAudioCard(attachment: attachment, theme: theme) {
                        previewAttachment = attachment
                    }
                } else {
                    Button {
                        open(attachment)
                    } label: {
                        attachmentView(attachment)
                    }
                    .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
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
    var audioFileOptionsOnly = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var previewURL: URL?
    @State private var saveDestination: ChatAttachmentSaveDestination?
    @State private var saveActivity = ChatAttachmentSaveActivity()
    @State private var isExporting = false
    @State private var alert: ChatAttachmentSaveAlert?
    @State private var markdownMode = ChatAttachmentMarkdownMode.preview
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            Group {
                if let markdown = ChatAttachmentMarkdown.text(of: attachment) {
                    ChatAttachmentMarkdownView(text: markdown, mode: markdownMode)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Picker("Show", selection: $markdownMode) {
                                ForEach(ChatAttachmentMarkdownMode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .bighelpSegmentedPicker()
                            .padding(.horizontal, BighelpTokens.space16)
                            .padding(.vertical, BighelpTokens.space8)
                            .background(theme.canvas)
                            .accessibilityIdentifier("chat.attachment.markdown.mode")
                        }
                } else if saveDestination == .photosVideo, let previewURL {
                    VideoPlayer(player: AVPlayer(url: previewURL))
                        .background(.black)
                } else if case .unavailable(let error)? = saveDestination {
                    ContentUnavailableView(
                        "Attachment unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.message)
                    )
                } else if audioFileOptionsOnly {
                    ContentUnavailableView(attachment.fileName, systemImage: "waveform",
                                           description: Text("Play this audio in the chat."))
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
            Telemetry.featureUsed(.fileOpened)
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

enum ChatAttachmentMarkdownMode: String, CaseIterable, Identifiable {
    case preview, raw
    var id: String { rawValue }
    var title: String { self == .preview ? "Preview" : "Raw" }
}

/// A Markdown file sent in a chat reads rendered; its raw text is a tap away.
enum ChatAttachmentMarkdown {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    /// Longer files open in the system's plain viewer: rendering a few megabytes would stall.
    static let maximumBytes = 1_000_000

    static func isMarkdown(fileName: String, mimeType: String) -> Bool {
        let type = mimeType.lowercased()
        return type.contains("markdown")
            || extensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    static func text(of attachment: ChatAttachment) -> String? {
        guard isMarkdown(fileName: attachment.fileName, mimeType: attachment.mimeType),
              attachment.data.count <= maximumBytes else { return nil }
        return String(data: attachment.data, encoding: .utf8)
    }
}

private struct ChatAttachmentMarkdownView: View {
    let text: String
    let mode: ChatAttachmentMarkdownMode
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView {
            Group {
                switch mode {
                case .preview:
                    MarkdownMessageView(document: MarkdownDocument(text), primaryText: theme.primaryText,
                                        secondaryText: theme.secondaryText, accent: theme.action)
                        .accessibilityIdentifier("chat.attachment.markdown.rendered")
                case .raw:
                    Text(text)
                        .font(.bighelp(.body).monospaced())
                        .foregroundStyle(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("chat.attachment.markdown.raw")
                }
            }
            .textSelection(.enabled)
            .padding(BighelpTokens.space16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.canvas.ignoresSafeArea())
    }
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

enum ChatAttachmentTemporaryFile {
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
