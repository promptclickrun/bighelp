import Foundation
import UniformTypeIdentifiers

/// Reads one shared item into the share being saved, straight to disk.
///
/// A file comes as a temporary copy iOS deletes as soon as its callback returns, so it's copied
/// inside the callback, a megabyte at a time and within its limit (`PendingShareDraft.addFile`);
/// nothing is read into memory whole except text, which is bounded first. Each item gets two
/// minutes: one that doesn't come by then fails with its name, and the person can cancel any time.
enum ShareCollector {
    enum Kind: Equatable, Sendable { case text, link, picture, file }

    enum Failure: Error, Equatable, Sendable {
        case share(PendingShareError)
        case timedOut
        case unsupported
    }

    struct Outcome: Sendable {
        var kind: Kind
        var title: String
        var detail: String
        var failure: Failure?
    }

    static let itemDeadline: Duration = .seconds(120)

    /// What the item is, from the types it offers, the same way the message box reads a drop.
    @MainActor
    static func kind(of provider: NSItemProvider) -> Kind? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        if SharedItemTypes.isAttachment(types) {
            return types.contains(where: { $0.conforms(to: .image) }) ? .picture : .file
        }
        if SharedItemTypes.isWebLink(types) { return .link }
        if SharedItemTypes.textType(types) != nil { return .text }
        return nil
    }

    @MainActor
    static func collect(_ provider: NSItemProvider, into draft: PendingShareDraft,
                        cancel: ShareCancellation) async -> Outcome {
        let name = provider.suggestedName
        switch kind(of: provider) {
        case .text: return await text(provider, into: draft, cancel: cancel)
        case .link: return await link(provider, into: draft, cancel: cancel)
        case .picture, .file: return await file(provider, into: draft, cancel: cancel)
        case nil:
            return Outcome(kind: .file, title: name ?? String(localized: "Shared item"), detail: "",
                           failure: .unsupported)
        }
    }

    // MARK: - Kinds

    @MainActor
    private static func link(_ provider: NSItemProvider, into draft: PendingShareDraft,
                             cancel: ShareCancellation) async -> Outcome {
        var outcome = Outcome(kind: .link, title: String(localized: "Link"), detail: "")
        let result: Result<URL, Failure> = await deadline(cancel) { finish in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { finish(.success(url)) } else { finish(.failure(.share(.unreadable(name: "Link")))) }
            }
        }
        switch result {
        case .success(let url) where url.isFileURL:
            return await sharedFile(url, suggestedName: provider.suggestedName, into: draft, cancel: cancel)
        case .success(let url):
            outcome.title = url.host() ?? url.absoluteString
            outcome.detail = url.absoluteString
            do { try draft.addLink(url.absoluteString) } catch let error as PendingShareError { outcome.failure = .share(error) }
            catch { outcome.failure = .share(.storageUnavailable) }
        case .failure(let failure):
            outcome.failure = failure
        }
        return outcome
    }

    @MainActor
    private static func text(_ provider: NSItemProvider, into draft: PendingShareDraft,
                             cancel: ShareCancellation) async -> Outcome {
        var outcome = Outcome(kind: .text, title: String(localized: "Text"), detail: "")
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard let type = SharedItemTypes.textType(types) else {
            outcome.failure = .unsupported
            return outcome
        }
        let limit = draft.limits.textBytes
        // As a file first, so its size is known before any of it is read.
        let result: Result<String?, Failure> = await deadline(cancel) { finish in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return finish(.success(nil)) }
                guard let size = PendingShareInbox.regularFileSize(url) else {
                    return finish(.failure(.share(.unreadable(name: "Text"))))
                }
                guard size <= limit else { return finish(.failure(.share(.textTooLong(limit: limit)))) }
                guard let data = PendingShareInbox.read(url, limit: limit) else {
                    return finish(.failure(.share(.unreadable(name: "Text"))))
                }
                if let text = String(data: data, encoding: type == .utf16PlainText ? .utf16 : .utf8) {
                    return finish(.success(text))
                }
                // Not text bighelp can read as words: it goes as a file, byte for byte.
                do {
                    try draft.addFile(copying: url, suggestedName: PendingShare.textFileName, kind: .file,
                                      typeIdentifier: type.identifier, mimeType: "text/plain",
                                      preferredExtension: "txt", isCancelled: { cancel.isCancelled })
                    finish(.success(""))
                } catch let error as PendingShareError {
                    finish(.failure(.share(error)))
                } catch {
                    finish(.failure(.share(.storageUnavailable)))
                }
            }
        }
        let text: String
        switch result {
        case .success(let read?): text = read
        case .success(nil):
            // Some apps hand text over only as a string object.
            let object: Result<String, Failure> = await deadline(cancel) { finish in
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    if let string { finish(.success(string)) } else { finish(.failure(.share(.unreadable(name: "Text")))) }
                }
            }
            switch object {
            case .success(let string): text = string
            case .failure(let failure):
                outcome.failure = failure
                return outcome
            }
        case .failure(let failure):
            outcome.failure = failure
            return outcome
        }
        outcome.detail = preview(text)
        guard !text.isEmpty else { return outcome }
        do { try draft.addText(text) } catch let error as PendingShareError { outcome.failure = .share(error) }
        catch { outcome.failure = .share(.storageUnavailable) }
        return outcome
    }

    @MainActor
    private static func file(_ provider: NSItemProvider, into draft: PendingShareDraft,
                             cancel: ShareCancellation) async -> Outcome {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard let type = SharedItemTypes.fileType(types) else {
            return Outcome(kind: .file, title: provider.suggestedName ?? String(localized: "File"), detail: "",
                           failure: .unsupported)
        }
        if type.conforms(to: .fileURL) {
            // Only the file's address was shared (Files, some document apps): read it there.
            let result: Result<URL, Failure> = await deadline(cancel) { finish in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { finish(.success(url)) } else { finish(.failure(.share(.unreadable(name: "File")))) }
                }
            }
            switch result {
            case .success(let url):
                return await sharedFile(url, suggestedName: provider.suggestedName, into: draft, cancel: cancel)
            case .failure(let failure):
                return Outcome(kind: .file, title: provider.suggestedName ?? String(localized: "File"), detail: "",
                               failure: failure)
            }
        }
        let kind: PendingShare.File.Kind = type.conforms(to: .image) ? .image : .file
        let suggested = provider.suggestedName
        let result: Result<PendingShare.File, Failure> = await deadline(cancel) { finish in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return finish(.failure(.share(.unreadable(name: suggested ?? "File")))) }
                finish(add(url, suggestedName: suggested ?? url.lastPathComponent, type: type, kind: kind,
                           into: draft, cancel: cancel))
            }
        }
        return outcome(result, kind: kind, suggestedName: suggested)
    }

    /// A file the other app named by its address, which may be outside this extension's sandbox.
    @MainActor
    private static func sharedFile(_ url: URL, suggestedName: String?, into draft: PendingShareDraft,
                                   cancel: ShareCancellation) async -> Outcome {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: PendingShare.File.Kind = type.conforms(to: .image) ? .image : .file
        let name = suggestedName ?? url.lastPathComponent
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PendingShare.File, Failure> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return add(url, suggestedName: name, type: type, kind: kind, into: draft, cancel: cancel)
        }.value
        return outcome(result, kind: kind, suggestedName: name)
    }

    private static func add(_ url: URL, suggestedName: String, type: UTType, kind: PendingShare.File.Kind,
                            into draft: PendingShareDraft, cancel: ShareCancellation) -> Result<PendingShare.File, Failure> {
        do {
            return .success(try draft.addFile(
                copying: url, suggestedName: suggestedName, kind: kind, typeIdentifier: type.identifier,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                preferredExtension: type.preferredFilenameExtension, isCancelled: { cancel.isCancelled }))
        } catch let error as PendingShareError {
            return .failure(.share(error))
        } catch {
            return .failure(.share(.storageUnavailable))
        }
    }

    private static func outcome(_ result: Result<PendingShare.File, Failure>, kind: PendingShare.File.Kind,
                                suggestedName: String?) -> Outcome {
        let shown: Kind = kind == .image ? .picture : .file
        switch result {
        case .success(let file):
            return Outcome(kind: shown, title: file.name,
                           detail: ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
        case .failure(let failure):
            let fallback = kind == .image ? String(localized: "Picture") : String(localized: "File")
            return Outcome(kind: shown, title: suggestedName ?? fallback, detail: "", failure: failure)
        }
    }

    private static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }

    // MARK: - Waiting

    /// Waits for `start`'s callback, the item's deadline, or Cancel, whichever comes first. A late
    /// callback is ignored, and a copy still under way stops at its next megabyte.
    @MainActor
    private static func deadline<T: Sendable>(
        _ cancel: ShareCancellation,
        _ start: @escaping @MainActor (_ finish: @escaping @Sendable (Result<T, Failure>) -> Void) -> Void
    ) async -> Result<T, Failure> {
        let once = ShareOnce<Result<T, Failure>>()
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            let timer = Task {
                try? await Task.sleep(for: itemDeadline)
                once.finish(.failure(.timedOut))
            }
            cancel.onCancel { once.finish(.failure(.share(.cancelled))) }
            start { result in
                timer.cancel()
                once.finish(result)
            }
        }
    }
}

/// Cancel, seen by every item and by a copy between megabytes.
final class ShareCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [@Sendable () -> Void] = []

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let handlers = lock.withLock { () -> [@Sendable () -> Void] in
            guard !cancelled else { return [] }
            cancelled = true
            defer { self.handlers = [] }
            return self.handlers
        }
        handlers.forEach { $0() }
    }

    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runsNow = lock.withLock { () -> Bool in
            if cancelled { return true }
            handlers.append(handler)
            return false
        }
        if runsNow { handler() }
    }
}

/// A continuation resumed once, by whichever answer comes first.
private final class ShareOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        let ready = lock.withLock { () -> T? in
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ value: T) {
        let waiting = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            if continuation == nil, early == nil { early = value }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
