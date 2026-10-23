import CoreGraphics
import SwiftUI
import UIKit

/// The formats a message can be shared in.
enum ChatMessageShareFormat: String, CaseIterable, Identifiable, Sendable {
    case messages
    case markdown
    case plain
    case pdf

    static let storageKey = "bighelp.chat.share-format"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Messages"
        case .markdown: "Markdown"
        case .plain: "Plain text"
        case .pdf: "PDF"
        }
    }
}

/// Long-press › Share…: the message in the format picked, a preview of exactly
/// what goes out, and Copy and Share.
struct ChatMessageShareSheet: View {
    /// The message's Markdown, as the chat draws it.
    let markdown: String
    /// The agent's name, or nil for the person's own message.
    let agentName: String?

    @AppStorage(ChatMessageShareFormat.storageKey) private var format: ChatMessageShareFormat = .messages
    @State private var texts: [ChatMessageShareFormat: String] = [:]
    @State private var pdf: ChatMessageSharePDF?
    @State private var isCopied = false
    @State private var copyGeneration = 0
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme: BighelpTheme

    /// "Message from Avery Park", or "Message" for the person's own.
    var documentTitle: String {
        guard let agentName = agentName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !agentName.isEmpty else { return "Message" }
        return "Message from \(agentName)"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Picker("Format", selection: $format) {
                    ForEach(ChatMessageShareFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .bighelpSegmentedPicker()
                .labelsHidden()
                .accessibilityIdentifier("chat.share.format")

                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12,
                                                                          style: .continuous))

                if format == .messages {
                    Text("Some apps and screen readers can't read styled letters.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: BighelpTokens.space12) {
                    copyButton
                    shareButton
                }
            }
            .padding(BighelpTokens.space16)
            .background(theme.canvas)
            .navigationTitle("Share message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.share.sheet")
        .task(id: format) { preparePDFIfNeeded() }
        .onDisappear { pdf?.removeFile() }
    }

    @ViewBuilder
    private var preview: some View {
        if format == .pdf {
            if let page = pdf?.firstPage {
                ScrollView {
                    Image(uiImage: page)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .padding(BighelpTokens.space16)
                        .accessibilityLabel("First page of the PDF")
                        .accessibilityIdentifier("chat.share.preview")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ChatMessageSharePreviewText(text: text(for: format), theme: theme)
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                .bighelpFont(.label, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12,
                                                                      style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
        }
        .bighelpPlainButtonStyle()
        .disabled(format == .pdf && pdf == nil)
        .accessibilityLabel(isCopied ? "Copied" : "Copy")
        .accessibilityIdentifier("chat.share.copy")
    }

    @ViewBuilder
    private var shareButton: some View {
        if format == .pdf {
            if let url = pdf?.fileURL {
                ShareLink(item: url) { shareLabel }
                    .bighelpPlainButtonStyle()
                    .accessibilityIdentifier("chat.share.share")
            } else {
                shareLabel
                    .opacity(0.5)
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("chat.share.share")
            }
        } else {
            ShareLink(item: text(for: format)) { shareLabel }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("chat.share.share")
        }
    }

    private var shareLabel: some View {
        Label("Share…", systemImage: "square.and.arrow.up")
            .bighelpFont(.label, weight: .semibold)
            .foregroundStyle(Color.bighelpActionInk)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .background(theme.action, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
    }

    private func text(for format: ChatMessageShareFormat) -> String {
        if let cached = texts[format] { return cached }
        return Self.convert(markdown, to: format)
    }

    static func convert(_ markdown: String, to format: ChatMessageShareFormat) -> String {
        switch format {
        case .messages: ChatMessageExport.styled(markdown)
        case .markdown: ChatMessageExport.markdown(markdown)
        case .plain: ChatMessageExport.plain(markdown)
        case .pdf: ""
        }
    }

    private func preparePDFIfNeeded() {
        if format != .pdf {
            if texts[format] == nil { texts[format] = Self.convert(markdown, to: format) }
            return
        }
        guard pdf == nil else { return }
        pdf = ChatMessageSharePDF(markdown: markdown, title: documentTitle)
    }

    private func copy() {
        if format == .pdf {
            guard let pdf else { return }
            UIPasteboard.general.setData(pdf.data, forPasteboardType: "com.adobe.pdf")
        } else {
            UIPasteboard.general.string = text(for: format)
        }
        BighelpHaptics.success()
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        withAnimation(.easeInOut(duration: BighelpTokens.stateDuration)) { isCopied = true }
        copyGeneration += 1
        let generation = copyGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard generation == copyGeneration else { return }
            withAnimation(.easeInOut(duration: BighelpTokens.stateDuration)) { isCopied = false }
        }
    }
}

/// The message as a PDF, its first page for the preview, and a file to share
/// under a readable name.
@MainActor
final class ChatMessageSharePDF {
    let data: Data
    let firstPage: UIImage?
    let fileURL: URL?
    private let folder: URL?

    init(markdown: String, title: String) {
        data = ChatMessageExport.pdf(markdown, title: title)
        firstPage = Self.renderFirstPage(of: data)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatMessageShare-\(UUID().uuidString)", isDirectory: true)
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("\(name).pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            self.folder = folder
            fileURL = file
        } catch {
            self.folder = nil
            fileURL = nil
        }
    }

    func removeFile() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func renderFirstPage(of data: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.drawPDFPage(page)
        }
    }
}

/// The converted text: scrolls, and can be selected, never edited.
private struct ChatMessageSharePreviewText: UIViewRepresentable {
    let text: String
    let theme: BighelpTheme

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFont.bighelp(.body)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.accessibilityIdentifier = "chat.share.preview"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.textColor = UIColor(theme.primaryText)
        view.tintColor = UIColor(theme.action)
        if view.text != text {
            view.text = text
            view.setContentOffset(.zero, animated: false)
        }
    }
}
