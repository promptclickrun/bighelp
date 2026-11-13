import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Several pictures in one message show as a stack: the first on top, the next two fanned behind
/// it, and a count. Tap it to swipe through them; save or share one, or all of them.
enum ChatImageStackContent {
    /// Pictures, in message order, and everything else.
    static func split(_ attachments: [ChatAttachment]) -> (images: [ChatAttachment], others: [ChatAttachment]) {
        var images: [ChatAttachment] = []
        var others: [ChatAttachment] = []
        for attachment in attachments {
            if isPicture(attachment) {
                images.append(attachment)
            } else {
                others.append(attachment)
            }
        }
        return (images, others)
    }

    /// Whether the bytes really are a picture this device can draw, whatever the host called the
    /// file. Reads only the header. A file that just claims to be a picture keeps its own tile, so
    /// the stack never shows a blank card.
    static func isPicture(_ attachment: ChatAttachment) -> Bool {
        guard !attachment.mimeType.hasPrefix("video/"), !attachment.mimeType.hasPrefix("audio/"),
              let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              type.conforms(to: .image)
        else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// One picture stays a single picture; two or more become a stack.
    static func showsStack(_ images: [ChatAttachment]) -> Bool { images.count >= 2 }

    static func countLabel(_ count: Int) -> String { count == 1 ? "1 photo" : "\(count) photos" }

    static func position(_ index: Int, of count: Int) -> String { "\(index + 1) of \(count)" }

    /// Whether pictures open over the whole display. On a screen that stands its bar up in a side
    /// column (the Duo's cover and inner screens) the column would otherwise sit over the photo, and
    /// the HIG allows full width where bars aren't needed. A screen with a bar along the bottom keeps
    /// its sheet, so half-folded the pictures stay clear of the fold.
    static func isFullBleed(_ screen: BighelpScreenGeometry) -> Bool { screen.usesSideBar }

    /// What saving several pictures to Photos says afterwards.
    static func savedMessage(saved: Int, of total: Int) -> String {
        if saved == total { return total == 1 ? "Saved to Photos." : "Saved \(total) photos to Photos." }
        if saved == 0 { return "The photos couldn't be saved to Photos." }
        return "Saved \(saved) of \(total) photos to Photos."
    }
}

struct ChatImageStackView: View {
    let images: [ChatAttachment]

    @State private var viewerStart: ChatImageStackStart?
    @State private var saver = ChatImageStackSaver()
    @Environment(\.bighelpScreen) private var screen

    var body: some View {
        Button {
            viewerStart = ChatImageStackStart(index: 0, screen: screen)
        } label: {
            stack
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius20))
        .accessibilityLabel(ChatImageStackContent.countLabel(images.count))
        .accessibilityHint("Opens the photos to swipe through, save or share")
        .accessibilityIdentifier("chat.image-stack")
        .contextMenu {
            Button("Save All to Photos", systemImage: "square.and.arrow.down.on.square") {
                Task { await saver.saveAll(images) }
            }
            if !saver.shareURLs.isEmpty {
                ShareLink(items: saver.allShareURLs) {
                    Label("Share All", systemImage: "square.and.arrow.up.on.square")
                }
            }
        }
        .task(id: images.map(\.id)) { saver.prepareShareFiles(images) }
        .onDisappear { saver.removeShareFiles() }
        .bighelpMediaPresentation(item: $viewerStart) { start in
            ChatImageStackViewer(images: images, startIndex: start.index, fullBleed: start.presentsFullScreen)
                .bighelpSheetSize(.large)
        }
        .chatImageStackAlert(saver)
    }

    private var stack: some View {
        let shown = Array(images.prefix(3).enumerated())
        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                // Back to front, so the first picture sits on top.
                ForEach(shown.reversed(), id: \.offset) { index, attachment in
                    thumbnail(attachment)
                        .rotationEffect(.degrees(Self.tilt(index)))
                        .offset(x: Self.shift(index), y: CGFloat(index) * -4)
                        .shadow(color: .black.opacity(index == 0 ? 0.18 : 0.10), radius: 6, y: 2)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            Label(ChatImageStackContent.countLabel(images.count), systemImage: "photo.on.rectangle.angled")
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, BighelpTokens.space8)
                .padding(.vertical, BighelpTokens.space4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(BighelpTokens.space12 + 6)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    private static func tilt(_ index: Int) -> Double { [0, -5, 5][min(index, 2)] }
    private static func shift(_ index: Int) -> CGFloat { [0, -10, 10][min(index, 2)] }

    private func thumbnail(_ attachment: ChatAttachment) -> some View {
        ChatImageThumbnailView(attachment: attachment)
            .frame(width: 208, height: 156)
        .clipShape(.rect(cornerRadius: BighelpTokens.radius20))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius20)
                .stroke(.white.opacity(0.6), lineWidth: 1.5)
        }
    }
}

/// A picture's small copy, filling its frame.
struct ChatImageThumbnailView: View {
    let attachment: ChatAttachment

    var body: some View {
        if let image = ChatImageThumbnail.image(for: attachment) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            theme.surface.overlay {
                Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            }
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme
}

/// Small, upright copies of pictures, made once each: drawing full-size photos in every tile
/// and strip button would be slow.
@MainActor
enum ChatImageThumbnail {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    static func image(for attachment: ChatAttachment, maximumPixels: Int = 640) -> UIImage? {
        let key = "\(attachment.id)-\(attachment.data.count)-\(maximumPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct ChatImageStackStart: Identifiable, BighelpMediaPresentationItem {
    let id = UUID()
    let index: Int
    /// Decided when it opens: turning or folding must not swap the cover for a sheet mid-look.
    let presentsFullScreen: Bool

    init(index: Int, screen: BighelpScreenGeometry) {
        self.index = index
        presentsFullScreen = ChatImageStackContent.isFullBleed(screen)
    }
}

/// A picture opened on its own over the whole display: what to show, and which of them.
struct ChatPhotoStart: Identifiable, BighelpMediaPresentationItem {
    let id = UUID()
    let images: [ChatAttachment]
    let index: Int
    let presentsFullScreen: Bool

    init(images: [ChatAttachment], index: Int, screen: BighelpScreenGeometry) {
        self.images = images
        self.index = index
        presentsFullScreen = ChatImageStackContent.isFullBleed(screen)
    }
}

/// The stack opened: swipe through the pictures, or jump with the strip at the bottom. Save or
/// share the one showing, or all of them. Where the screen keeps a column for its bar (the Duo),
/// the pictures take the whole display and the controls stand down the leading edge instead.
struct ChatImageStackViewer: View {
    let images: [ChatAttachment]
    /// How it was opened. Fixed for the look, so a turn or a fold keeps the picture on screen.
    let fullBleed: Bool

    @State private var index: Int
    @State private var saver = ChatImageStackSaver()
    @Environment(\.dismiss) private var dismiss

    init(images: [ChatAttachment], startIndex: Int, fullBleed: Bool) {
        self.images = images
        self.fullBleed = fullBleed
        _index = State(initialValue: min(max(startIndex, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        Group {
            if fullBleed {
                wholeDisplay
            } else {
                sheet
            }
        }
        .chatImageStackAlert(saver)
        .task { saver.prepareShareFiles(images) }
        .onDisappear { saver.removeShareFiles() }
    }

    private var pages: some View {
        TabView(selection: $index) {
            ForEach(Array(images.enumerated()), id: \.offset) { offset, attachment in
                ChatImageStackPage(attachment: attachment)
                    .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("chat.image-stack.pages")
    }

    /// A sheet's version: the bar says which picture this is and holds Done, Save and Share.
    private var sheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pages
                strip
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(ChatImageStackContent.position(index, of: images.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The system title is dark ink, lost on the black behind the pictures.
                ToolbarItem(placement: .principal) {
                    Text(ChatImageStackContent.position(index, of: images.count))
                        .font(.bighelp(.headline))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu { saveButtons } label: {
                        if saver.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Save", systemImage: "square.and.arrow.down").labelStyle(.iconOnly)
                        }
                    }
                    .disabled(saver.isSaving)
                    .accessibilityLabel("Save")
                    .accessibilityIdentifier("chat.image-stack.save")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu { shareButtons } label: {
                        Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("chat.image-stack.share")
                }
            }
        }
    }

    /// The Duo's: the picture edge to edge, with no bar standing a column up over it. Close, Save
    /// and Share go down the leading edge, above the fold's side of the column, and the thumbnails
    /// stay at the bottom.
    private var wholeDisplay: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            pages
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Button { dismiss() } label: { scrim("xmark") }
                    .bighelpPlainButtonStyle(.circle)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("chat.image-stack.close")
                Menu { saveButtons } label: {
                    if saver.isSaving {
                        ProgressView().controlSize(.small).tint(.white).frame(width: scrimSize, height: scrimSize)
                    } else {
                        scrim("square.and.arrow.down")
                    }
                }
                .disabled(saver.isSaving)
                .accessibilityLabel("Save")
                .accessibilityIdentifier("chat.image-stack.save")
                Menu { shareButtons } label: { scrim("square.and.arrow.up") }
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("chat.image-stack.share")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space16)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: BighelpTokens.space8) {
                Text(ChatImageStackContent.position(index, of: images.count))
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, BighelpTokens.space8)
                    .padding(.vertical, BighelpTokens.space4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .accessibilityIdentifier("chat.image-stack.position")
                if images.count > 1 { strip }
            }
            .padding(.bottom, BighelpTokens.space8)
        }
    }

    /// An action over a picture: white on its own dark circle, so it reads on any photo.
    private func scrim(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.bighelp(.title3).weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: scrimSize, height: scrimSize)
            .background(.black.opacity(0.5), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: BighelpTokens.hairline))
            .contentShape(.circle)
    }

    private var scrimSize: CGFloat { BighelpTokens.hitTarget }

    @ViewBuilder private var saveButtons: some View {
        Button("Save This Photo", systemImage: "square.and.arrow.down") {
            Task { await saver.saveAll([images[index]]) }
        }
        Button("Save All \(images.count) Photos", systemImage: "square.and.arrow.down.on.square") {
            Task { await saver.saveAll(images) }
        }
        .accessibilityIdentifier("chat.image-stack.save-all")
    }

    @ViewBuilder private var shareButtons: some View {
        if let current = saver.shareURLs[index] {
            ShareLink(item: current) {
                Label("Share This Photo", systemImage: "square.and.arrow.up")
            }
        }
        ShareLink(items: saver.allShareURLs) {
            Label("Share All \(images.count) Photos", systemImage: "square.and.arrow.up.on.square")
        }
    }

    /// Every picture small, the one showing outlined; tap one to jump to it.
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: BighelpTokens.space8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { offset, attachment in
                        Button {
                            withAnimation(.snappy) { index = offset }
                        } label: {
                            ChatImageThumbnailView(attachment: attachment)
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                                        .stroke(offset == index ? Color.white : .clear, lineWidth: 2.5)
                                }
                                .opacity(offset == index ? 1 : 0.6)
                                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                        }
                        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                        .id(offset)
                        .accessibilityLabel("Photo \(ChatImageStackContent.position(offset, of: images.count))")
                        .accessibilityAddTraits(offset == index ? .isSelected : [])
                        .accessibilityIdentifier("chat.image-stack.thumbnail.\(offset)")
                    }
                }
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: index) { _, newIndex in
                withAnimation(.snappy) { proxy.scrollTo(newIndex, anchor: .center) }
            }
        }
    }
}

/// One picture, fitted to the screen; pinch or double-tap to look closer.
private struct ChatImageStackPage: View {
    let attachment: ChatAttachment
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Group {
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(min(max(scale * pinch, 1), 4))
                    .gesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in scale = min(max(scale * value.magnification, 1), 4) })
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) { scale = scale > 1 ? 1 : 2.5 }
                    }
                    .accessibilityLabel(attachment.fileName)
            } else {
                ContentUnavailableView("Photo unavailable", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Saves pictures to Photos (asking once) and hands files to the share sheet, cleaning up after.
@MainActor
@Observable
final class ChatImageStackSaver {
    private(set) var isSaving = false
    var message: String?
    var offersSettings = false
    /// Each picture as a file under its own name for the share sheet, by its place in the message.
    private(set) var shareURLs: [Int: URL] = [:]
    var allShareURLs: [URL] { shareURLs.keys.sorted().compactMap { shareURLs[$0] } }

    func saveAll(_ images: [ChatAttachment]) async {
        guard !isSaving, !images.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            offersSettings = ChatAttachmentPhotosAuthorizationRecovery.requiresSettings(authorization)
            message = offersSettings
                ? "Photos access is off. Allow it in Settings to save these photos."
                : "The photos couldn't be saved to Photos."
            return
        }
        var saved = 0
        for image in images {
            if (try? await ChatAttachmentPhotosSaver.saveImage(image.data)) != nil { saved += 1 }
        }
        offersSettings = false
        message = ChatImageStackContent.savedMessage(saved: saved, of: images.count)
    }

    /// Writes the files once while the stack or viewer is showing; removed when it goes.
    func prepareShareFiles(_ images: [ChatAttachment]) {
        removeShareFiles()
        for (index, image) in images.enumerated() {
            if let url = try? ChatAttachmentTemporaryFile.write(image) { shareURLs[index] = url }
        }
    }

    func removeShareFiles() {
        for url in shareURLs.values { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        shareURLs.removeAll()
    }
}

private struct ChatImageStackAlert: ViewModifier {
    @Bindable var saver: ChatImageStackSaver
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert("Photos", isPresented: Binding(
            get: { saver.message != nil },
            set: { if !$0 { saver.message = nil } }
        )) {
            if saver.offersSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(saver.message ?? "")
        }
    }
}

extension View {
    func chatImageStackAlert(_ saver: ChatImageStackSaver) -> some View {
        modifier(ChatImageStackAlert(saver: saver))
    }
}
