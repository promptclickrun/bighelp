import SwiftUI
import UIKit

/// What the tag above the message box says: the count first, then the kinds.
/// Adding and "didn't attach" take it over until everything is in.
struct DraftAttachmentRailState: Equatable {
    struct Thumbnail: Equatable, Identifiable {
        let attachment: ChatDraftAttachment
        var id: String { attachment.id }
        var isPhoto: Bool { attachment.isPhoto }
    }

    let title: String
    let detail: String?
    let thumbnails: [Thumbnail]
    let isAdding: Bool
    let isFailure: Bool
    /// 0…1 while adding.
    let progress: Double?

    init?(attachments: [ChatDraftAttachment], adding: DraftAttachmentImportProgress?, failedCount: Int) {
        if let adding {
            title = "Adding \(min(adding.finished + 1, adding.total)) of \(adding.total)…"
            detail = adding.kind.noun
            thumbnails = []
            isAdding = true; isFailure = false
            progress = adding.total > 0 ? Double(adding.finished) / Double(adding.total) : 0
            return
        }
        if failedCount > 0 {
            title = "\(failedCount) didn't attach"
            detail = nil
            thumbnails = []
            isAdding = false; isFailure = true; progress = nil
            return
        }
        guard let first = attachments.first else { return nil }
        isAdding = false; isFailure = false; progress = nil
        // Photos lead the stack, three at most; a file keeps the last spot so the mix shows.
        let photoItems = attachments.filter(\.isPhoto), fileItems = attachments.filter { !$0.isPhoto }
        let shownPhotos = photoItems.prefix(fileItems.isEmpty ? 3 : 2)
        thumbnails = (Array(shownPhotos) + fileItems.prefix(3 - shownPhotos.count)).map(Thumbnail.init)
        if attachments.count == 1 {
            if first.isPhoto {
                title = "1 photo"; detail = nil
            } else {
                title = first.fileName
                detail = first.sizeOrPages
            }
            return
        }
        title = "\(attachments.count) attached"
        let photos = attachments.filter(\.isPhoto).count
        let pdfs = attachments.filter { !$0.isPhoto && $0.isPDF }.count
        let files = attachments.count - photos - pdfs
        detail = [Self.count(photos, "photo", "photos"), Self.count(pdfs, "PDF", "PDFs"),
                  Self.count(files, "file", "files")].compactMap { $0 }.joined(separator: ", ")
    }

    var accessibilityLabel: String {
        [title.replacingOccurrences(of: "…", with: ""), detail].compactMap { $0 }.joined(separator: ", ")
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String? {
        value == 0 ? nil : "\(value) \(value == 1 ? one : many)"
    }
}

extension ChatDraftAttachment {
    var isPhoto: Bool {
        if case .attachment(let attachment) = self { return attachment.kind == .image }
        return false
    }

    var isPDF: Bool {
        switch self {
        case .pdfPages: return true
        case .attachment(let attachment):
            return attachment.mimeType.lowercased() == "application/pdf"
                || attachment.fileName.lowercased().hasSuffix(".pdf")
        }
    }

    var fileName: String {
        switch self {
        case .attachment(let attachment): attachment.fileName
        case .pdfPages(let selection): selection.attachment.fileName
        }
    }

    /// What you'd check about a file: its size, or the pages picked from a PDF.
    var sizeOrPages: String {
        switch self {
        case .attachment(let attachment):
            ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
        case .pdfPages(let selection):
            "Pages \(selection.pageRange.firstPage)–\(selection.pageRange.lastPage)"
        }
    }

    /// The file itself, for a full preview.
    var previewAttachment: ChatAttachment {
        switch self {
        case .attachment(let attachment): attachment
        case .pdfPages(let selection): selection.attachment
        }
    }
}

/// A small tag above the message box, lined up with the message field, in the
/// rail's glass. Tap it to see and manage each attachment.
struct DraftAttachmentRail: View {
    let model: ChatModel
    /// The width of what sits left of the message field (the + button and its gap).
    var leadingInset: CGFloat = BighelpTokens.hitTarget + BighelpTokens.space8

    @State private var isSheetPresented = false
    @BighelpThemeReader private var theme

    var body: some View {
        if let state = DraftAttachmentRailState(
            attachments: model.orderedDraftAttachments, adding: model.draftAttachmentImport,
            failedCount: model.draftAttachmentFailures.count) {
            tag(state)
                .padding(.leading, leadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .sheet(isPresented: $isSheetPresented) {
                    DraftAttachmentsSheet(model: model)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .bighelpSheetSize(.standard)
                }
        }
    }

    private func tag(_ state: DraftAttachmentRailState) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Button { isSheetPresented = true } label: {
                HStack(spacing: BighelpTokens.space8) {
                    leading(state)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.title)
                            .font(.bighelp(.subheadline).weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = state.detail {
                            Text(detail)
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    if !state.isFailure {
                        Image(systemName: "chevron.up")
                            .font(.bighelp(.caption).weight(.bold))
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, state.isFailure ? 0 : BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.accessibilityLabel)
            .accessibilityHint("Shows your attachments")
            .accessibilityIdentifier("chat.draft-attachments.rail")

            if state.isFailure {
                Button("Try again") { Task { await model.retryFailedDraftAttachments() } }
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(minHeight: 34)
                    .background(theme.action.opacity(0.14), in: .capsule)
                    .padding(.trailing, 5)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.capsule)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.draft-attachments.try-again")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .bighelpNavigationGlass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.draft-attachments")
    }

    @ViewBuilder
    private func leading(_ state: DraftAttachmentRailState) -> some View {
        if state.isAdding {
            ZStack {
                Circle().stroke(theme.secondaryText.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.08, state.progress ?? 0))
                    .stroke(theme.action, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: state.progress)
            }
            .frame(width: 24, height: 24)
            .padding(5)
        } else if state.isFailure {
            Text("!")
                .font(.bighelp(.subheadline).weight(.bold))
                .foregroundStyle(theme.danger)
                .frame(width: 34, height: 34)
                .background(theme.danger.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
        } else {
            HStack(spacing: -14) {
                ForEach(Array(state.thumbnails.enumerated()), id: \.element.id) { index, thumbnail in
                    DraftAttachmentThumbnail(attachment: thumbnail.attachment, size: 34)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.canvas, lineWidth: state.thumbnails.count > 1 ? 1.5 : 0)
                        }
                        .zIndex(Double(index))
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// A photo's own picture, or a file mark in the bubble color.
struct DraftAttachmentThumbnail: View {
    let attachment: ChatDraftAttachment
    let size: CGFloat
    @BighelpThemeReader private var theme

    var body: some View {
        Group {
            if case .attachment(let file) = attachment, file.kind == .image, let image = UIImage(data: file.data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: attachment.isPDF ? "doc.text" : "doc")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .frame(width: size, height: size)
                    .background(theme.action.opacity(0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.29, style: .continuous))
    }
}

/// Every attachment in the draft: see it, open it, take it out, or try again.
struct DraftAttachmentsSheet: View {
    let model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var previewing: ChatAttachment?
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            List {
                if let adding = model.draftAttachmentImport {
                    Section {
                        HStack(spacing: BighelpTokens.space12) {
                            ProgressView(value: Double(adding.finished), total: Double(max(adding.total, 1)))
                                .progressViewStyle(.circular)
                            Text("Adding \(min(adding.finished + 1, adding.total)) of \(adding.total) \(adding.kind.noun)…")
                                .font(.bighelp(.body))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !model.draftAttachmentFailures.isEmpty {
                    Section("Didn't attach") {
                        ForEach(model.draftAttachmentFailures) { failure in failureRow(failure) }
                    }
                }
                if !model.orderedDraftAttachments.isEmpty {
                    Section {
                        ForEach(model.orderedDraftAttachments) { attachment in row(attachment) }
                    } footer: {
                        Text("Tap one to see it. Swipe or tap Remove to take it out.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bighelpToolbarText()
                }
                if model.orderedDraftAttachments.count > 1 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Remove all", role: .destructive) {
                            for attachment in model.orderedDraftAttachments {
                                model.removeOrderedDraftAttachment(id: attachment.id)
                            }
                        }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("chat.draft-attachments.remove-all")
                    }
                }
            }
            .sheet(item: $previewing) { attachment in
                ChatAttachmentPreviewView(attachment: attachment)
                    .bighelpSheetSize(.large)
            }
        }
        .accessibilityIdentifier("chat.draft-attachments.sheet")
        .onChange(of: model.hasDraftAttachmentActivity) { _, has in
            if !has { dismiss() }
        }
    }

    private var title: String {
        let count = model.orderedDraftAttachments.count
        return count == 1 ? "1 attachment" : "\(count) attachments"
    }

    private func row(_ attachment: ChatDraftAttachment) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Button { previewing = attachment.previewAttachment } label: {
                HStack(spacing: BighelpTokens.space12) {
                    DraftAttachmentThumbnail(attachment: attachment, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.isPhoto ? "Photo" : attachment.fileName)
                            .font(.bighelp(.body).weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(stale(attachment) ? "Earlier session · remove and re-add these pages"
                             : attachment.isPhoto ? attachment.sizeOrPages
                             : [attachment.isPDF ? "PDF" : "File", attachment.sizeOrPages].joined(separator: " · "))
                            .font(.bighelp(.footnote))
                            .foregroundStyle(stale(attachment) ? theme.warning : theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens it")
            Button("Remove", systemImage: "xmark.circle.fill") { model.removeOrderedDraftAttachment(id: attachment.id) }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(theme.secondaryText)
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.isPhoto ? "photo" : attachment.fileName)")
                .accessibilityIdentifier("chat.draft-attachment.remove")
        }
        .swipeActions {
            Button("Remove", role: .destructive) { model.removeOrderedDraftAttachment(id: attachment.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.draft-attachment")
    }

    private func failureRow(_ failure: DraftAttachmentFailure) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space12) {
                Text("!")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.danger)
                    .frame(width: 40, height: 40)
                    .background(theme.danger.opacity(0.14), in: .rect(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.name).font(.bighelp(.body).weight(.semibold)).lineLimit(1)
                    Text(failure.message)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: BighelpTokens.space12) {
                Button("Try again") { Task { await model.retryDraftAttachmentFailure(id: failure.id) } }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.action)
                Button("Remove", role: .destructive) { model.removeDraftAttachmentFailure(id: failure.id) }
                    .buttonStyle(.bordered)
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.draft-attachment.failure")
    }

    private func stale(_ attachment: ChatDraftAttachment) -> Bool {
        guard let selection = attachment.pdfSelection else { return false }
        return model.pdfAttachmentTarget == nil || selection.target != model.pdfAttachmentTarget
    }
}

#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
/// "-test-draft-attachments photo|file|mixed|adding|failed": puts the tag in one state
/// for screenshots and UI tests, with made-up pictures and a made-up lease.
enum DraftAttachmentRailFixture {
    @MainActor
    static func seed(_ model: ChatModel, arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard let index = arguments.firstIndex(of: "-test-draft-attachments"), arguments.indices.contains(index + 1),
              model.orderedDraftAttachments.isEmpty, model.draftAttachmentImport == nil else { return }
        let photos = [UIColor(red: 0.89, green: 0.84, blue: 0.76, alpha: 1), UIColor(red: 0.80, green: 0.86, blue: 0.92, alpha: 1),
                      UIColor(red: 0.78, green: 0.58, blue: 0.40, alpha: 1)].enumerated().map { photo($1, id: $0) }
        let lease = pdf()
        func add(_ attachments: [ChatAttachment]) { for item in attachments { try? model.addDraftAttachment(item) } }
        switch arguments[index + 1] {
        case "photo": add([photos[0]])
        case "file": add([lease])
        case "mixed": add(photos + [lease])
        case "adding":
            Task { @MainActor in
                await model.importDraftAttachments(.photos, [
                    DraftAttachmentLoader(name: nil) { photos[0] },
                    DraftAttachmentLoader(name: nil) { try await Task.sleep(for: .seconds(3_600)); return photos[1] },
                    DraftAttachmentLoader(name: nil) { photos[2] },
                    DraftAttachmentLoader(name: nil) { photos[0] },
                ])
            }
        case "failed":
            add(Array(photos.prefix(2)))
            final class Attempts { var count = 0 }
            let attempts = Attempts()
            await model.importDraftAttachments(.photos, [DraftAttachmentLoader(name: "IMG_2041.HEIC") {
                attempts.count += 1
                if attempts.count == 1 { throw ImageAttachmentPreparer.Error.processingFailed }
                return photos[2]
            }])
        default: break
        }
    }

    private static func photo(_ color: UIColor, id: Int) -> ChatAttachment {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
            UIColor.white.withAlphaComponent(0.35).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 40, y: 60, width: 120, height: 70))
        }
        // swiftlint:disable:next force_try
        return try! ChatAttachment(id: "attachment_fixture_photo_\(id)", fileName: "stain-\(id + 1).jpg", mimeType: "image/jpeg",
                                   data: image.jpegData(compressionQuality: 0.8) ?? Data())
    }

    private static func pdf() -> ChatAttachment {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Lease agreement (sample)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 22)])
        }
        // swiftlint:disable:next force_try
        return try! ChatAttachment(id: "attachment_fixture_lease", fileName: "Lease 2026.pdf", mimeType: "application/pdf", data: data)
    }
}
#endif
