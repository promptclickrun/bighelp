import Foundation

/// What's being added to the draft, for the tag's "Adding 2 of 4… photos".
enum DraftAttachmentImportKind: Equatable, Sendable {
    case photos, files, attachments

    var noun: String {
        switch self {
        case .photos: "photos"
        case .files: "files"
        case .attachments: "attachments"
        }
    }

    fileprivate var singular: String {
        switch self {
        case .photos: "A photo"
        case .files: "A file"
        case .attachments: "An attachment"
        }
    }
}

struct DraftAttachmentImportProgress: Equatable, Sendable {
    var kind: DraftAttachmentImportKind
    var total: Int
    var finished: Int
}

/// Reads one photo or file into an attachment; kept so one that failed can be tried again.
struct DraftAttachmentLoader {
    let name: String?
    let load: @MainActor () async throws -> ChatAttachment

    init(name: String?, load: @escaping @MainActor () async throws -> ChatAttachment) {
        self.name = name
        self.load = load
    }
}

struct DraftAttachmentFailure: Identifiable {
    let id = UUID().uuidString
    let name: String
    let message: String
    let kind: DraftAttachmentImportKind
    let loader: DraftAttachmentLoader
}

extension ChatModel {
    /// Anything in the tag above the message box: attachments, ones being added, or ones that didn't attach.
    var hasDraftAttachmentActivity: Bool {
        !orderedDraftAttachments.isEmpty || draftAttachmentImport != nil || !draftAttachmentFailures.isEmpty
    }

    /// Adds each in turn. One that can't be read stays as "didn't attach", with why, and
    /// the rest still go in. Send waits until they're all in.
    func importDraftAttachments(_ kind: DraftAttachmentImportKind, _ loaders: [DraftAttachmentLoader]) async {
        guard !loaders.isEmpty else { return }
        if var running = draftAttachmentImport {
            running.total += loaders.count
            if running.kind != kind { running.kind = .attachments }
            draftAttachmentImport = running
        } else {
            draftAttachmentImport = DraftAttachmentImportProgress(kind: kind, total: loaders.count, finished: 0)
        }
        for loader in loaders {
            do {
                try addDraftAttachment(try await loader.load())
            } catch is CancellationError {
                // The chat moved on; nothing to report.
            } catch {
                draftAttachmentFailures.append(DraftAttachmentFailure(
                    name: loader.name ?? kind.singular, message: ChatAttachmentError.userMessage(for: error),
                    kind: kind, loader: loader))
            }
            draftAttachmentImport?.finished += 1
        }
        if let progress = draftAttachmentImport, progress.finished >= progress.total { draftAttachmentImport = nil }
    }

    func retryFailedDraftAttachments() async {
        let failures = draftAttachmentFailures
        guard !failures.isEmpty else { return }
        draftAttachmentFailures = []
        let kinds = Set(failures.map(\.kind))
        await importDraftAttachments(kinds.count == 1 ? failures[0].kind : .attachments, failures.map(\.loader))
    }

    func retryDraftAttachmentFailure(id: String) async {
        guard let failure = draftAttachmentFailures.first(where: { $0.id == id }) else { return }
        draftAttachmentFailures.removeAll { $0.id == id }
        await importDraftAttachments(failure.kind, [failure.loader])
    }

    func removeDraftAttachmentFailure(id: String) {
        draftAttachmentFailures.removeAll { $0.id == id }
    }
}
