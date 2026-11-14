import Foundation
import SwiftUI

/// The share sheet: read what was shared onto the device, let the person add a note, save it for
/// bighelp. It sends nothing and signs in to nothing; bighelp sends it, from the chat the person
/// picks there, once they tap Send.
@MainActor
final class ShareModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: Int
        var kind: ShareCollector.Kind
        var title: String
        var detail: String
        var problem: String?
        var isReading: Bool
    }

    enum Phase: Equatable {
        case reading
        case ready
        case saving
        case saved
        /// Nothing was saved; why.
        case failed(String)
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var phase: Phase = .reading
    @Published var note = ""

    private let inbox: PendingShareInbox?
    private var draft: PendingShareDraft?
    private let cancellation = PendingShareCancellation()
    private var reading: Task<Void, Never>?

    init(inbox: PendingShareInbox? = PendingShareInbox.shared()) {
        self.inbox = inbox
    }

    var problems: [String] { rows.compactMap(\.problem) }

    var noteIsTooLong: Bool { note.utf8.count > (inbox?.limits.noteBytes ?? 0) }

    var canSave: Bool { phase == .ready && problems.isEmpty && !rows.isEmpty && !noteIsTooLong }

    func start(_ providers: [NSItemProvider]) {
        guard reading == nil else { return }
        guard let inbox else {
            phase = .failed(String(localized: "Bighelp can't save shares on this device. Open Bighelp and try again."))
            return
        }
        guard !providers.isEmpty else {
            phase = .failed(String(localized: "There was nothing to share."))
            return
        }
        rows = providers.enumerated().map { index, provider in
            Row(id: index, kind: ShareCollector.kind(of: provider) ?? .file,
                title: provider.suggestedName ?? String(localized: "Reading…"), detail: "", isReading: true)
        }
        reading = Task {
            // A sheet that was closed or ended mid-save leaves a staging folder; it goes now.
            await Task.detached(priority: .utility) { inbox.removeAbandonedStaging() }.value
            let draft: PendingShareDraft
            do {
                draft = try await Task.detached(priority: .userInitiated) { try inbox.begin() }.value
            } catch {
                phase = .failed(Self.message(for: .share(error as? PendingShareError ?? .storageUnavailable)))
                return
            }
            self.draft = draft
            for (index, provider) in providers.enumerated() {
                if cancellation.isCancelled { return }
                let outcome = await ShareCollector.collect(provider, into: draft, cancel: cancellation)
                rows[index] = Row(id: index, kind: outcome.kind, title: outcome.title, detail: outcome.detail,
                                  problem: outcome.failure.map(Self.message), isReading: false)
            }
            if !cancellation.isCancelled { phase = .ready }
        }
    }

    /// Saves the share in one step. Afterwards it waits in bighelp until it's sent or deleted.
    func save() async {
        guard canSave, let draft else { return }
        phase = .saving
        let note = note
        do {
            _ = try await Task.detached(priority: .userInitiated) { try draft.commit(note: note) }.value
            phase = .saved
        } catch let error as PendingShareError {
            // A full inbox, or the device's storage: nothing was saved, and the person can still cancel.
            phase = .failed(Self.message(for: .share(error)))
        } catch {
            phase = .failed(Self.message(for: .share(.storageUnavailable)))
        }
    }

    /// Stops reading and throws away what was staged. A saved share stays.
    func cancel() {
        cancellation.cancel()
        reading?.cancel()
        guard let draft else { return }
        self.draft = nil
        Task.detached(priority: .userInitiated) { draft.rollback() }
    }

    static func message(for failure: ShareCollector.Failure) -> String {
        switch failure {
        case .timedOut:
            return String(localized: "This didn't arrive in time. Try sharing it again.")
        case .unsupported:
            return String(localized: "Bighelp can't take this kind of item.")
        case .share(let error):
            switch error {
            case .nothingToShare:
                return String(localized: "There was nothing to share.")
            case .tooManyFiles(let limit):
                return String(localized: "Bighelp takes up to \(limit) photos and files at a time.")
            case .fileTooLarge(_, let limit):
                return String(localized: "This is over \(Self.size(limit)), the most Bighelp can take.")
            case .shareTooLarge(let limit):
                return String(localized: "Together these are over \(Self.size(limit)). Share fewer at a time.")
            case .textTooLong:
                return String(localized: "This text is too long to share.")
            case .noteTooLong:
                return String(localized: "Your note is too long.")
            case .tooManyLinks(let limit):
                return String(localized: "Bighelp takes up to \(limit) links at a time.")
            case .unreadable:
                return String(localized: "Bighelp couldn't read this.")
            case .emptyFile:
                return String(localized: "This file is empty.")
            case .inboxFull(let shares):
                return String(localized: "Bighelp is holding \(shares) shares you haven't sent. Open Bighelp, send or delete some, then share this again.")
            case .storageUnavailable, .gone, .finished:
                return String(localized: "Bighelp couldn't save this. Nothing was saved.")
            case .cancelled:
                return String(localized: "Cancelled.")
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
