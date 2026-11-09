import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The shares waiting in the app group (`PendingShare`), one folder each.
///
/// The share sheet stages a share in a folder of its own under `.staging`, holding a lock file for
/// as long as it writes, and moves the whole folder into place in one rename once every part is
/// in. A share is therefore all there or not there at all: a sheet that's cancelled, refused or
/// killed leaves only a staging folder, which `removeAbandonedStaging` deletes once nothing holds
/// its lock (iOS lets go of a lock when its process ends). Nothing here deletes a saved share by
/// itself: only the person, by sending it from a chat or deleting it, does (`remove`).
///
///     PendingShares/v1/<id>/share.json         what was shared
///     PendingShares/v1/<id>/placement.json     where the person put it, once they have
///     PendingShares/v1/<id>/files/<index>      each file, as it came
///     PendingShares/v1/.staging/<id>(.lock)    a share being saved
///     PendingShares/v1/.trash/                 a share being deleted
struct PendingShareInbox: Sendable {
    enum Entry: Equatable, Identifiable, Sendable {
        case share(PendingShare, placement: PendingSharePlacement?)
        /// A folder whose parts don't check out. It's listed so the person can delete it; it's
        /// never deleted for them.
        case unreadable(id: String)

        var id: String {
            switch self {
            case .share(let share, _): share.id
            case .unreadable(let id): id
            }
        }
    }

    /// The group the app and its extensions already share (`BighelpDeliveryReceipts.appGroup`).
    static let appGroup = "group.app.loopdy.mobile.buzzkit"

    let root: URL
    let limits: PendingShareLimits
    let now: @Sendable () -> Date

    init(root: URL, limits: PendingShareLimits = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.limits = limits
        self.now = now
    }

    #if canImport(Darwin)
    /// Nil when the build has no app group (an unsigned simulator copy).
    static func shared(limits: PendingShareLimits = .standard) -> PendingShareInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup).map {
            PendingShareInbox(root: $0.appending(path: "PendingShares/v1", directoryHint: .isDirectory),
                              limits: limits)
        }
    }
    #endif

    var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }
    var trash: URL { root.appendingPathComponent(".trash", isDirectory: true) }
    private var lockFile: URL { root.appendingPathComponent(".lock") }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func fileURL(_ file: PendingShare.File, in share: PendingShare) -> URL {
        folder(share.id).appendingPathComponent(file.storedName)
    }

    /// Starts saving a share. Nothing is visible to the app until `commit`.
    func begin() throws -> PendingShareDraft {
        try prepareRoot()
        return try PendingShareDraft(inbox: self)
    }

    // MARK: - Reading

    /// Every saved share, oldest first, each checked against what's on disk.
    func entries() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var shares: [(Date, Entry)] = []
        for name in names where PendingShare.isValidID(name) {
            if let share = readShare(name) {
                shares.append((share.createdAt, .share(share, placement: readPlacement(name))))
            } else {
                shares.append((.distantPast, .unreadable(id: name)))
            }
        }
        return shares.sorted { ($0.0, $0.1.id) < ($1.0, $1.1.id) }.map(\.1)
    }

    private func readShare(_ id: String) -> PendingShare? {
        let manifest = folder(id).appendingPathComponent("share.json")
        guard let data = Self.read(manifest, limit: limits.manifestBytes),
              let share = try? JSONDecoder().decode(PendingShare.self, from: data),
              share.version == PendingShare.currentVersion, share.id == id,
              share.text.utf8.count <= limits.inlineTextBytes, share.note.utf8.count <= limits.noteBytes,
              share.links.count <= limits.links,
              share.links.allSatisfy({ PendingShare.webLink($0, limits: limits) == $0 }),
              share.files.count <= limits.files, share.byteCount <= limits.shareBytes,
              !share.files.isEmpty || !share.links.isEmpty || PendingShare.hasWords(share.text),
              Set(share.files.map { $0.name.lowercased() }).count == share.files.count else { return nil }
        for (index, file) in share.files.enumerated() {
            guard file.storedName == "files/\(index)", PendingShare.isValidFileName(file.name),
                  PendingShare.isValidMIMEType(file.mimeType),
                  PendingShare.isValidTypeIdentifier(file.typeIdentifier),
                  (1...limits.maximumBytes(for: file.kind)).contains(file.byteCount),
                  Self.regularFileSize(fileURL(file, in: share)) == file.byteCount else { return nil }
        }
        return share
    }

    private func readPlacement(_ id: String) -> PendingSharePlacement? {
        Self.read(folder(id).appendingPathComponent("placement.json"), limit: 16 * 1_024)
            .flatMap { try? JSONDecoder().decode(PendingSharePlacement.self, from: $0) }
    }

    // MARK: - Changing

    /// Records where the person put a share. Throws `gone` when it was sent or deleted meanwhile.
    func place(_ id: String, _ placement: PendingSharePlacement) throws {
        guard PendingShare.isValidID(id) else { throw PendingShareError.gone }
        let data = try JSONEncoder().encode(placement)
        try withInboxLock {
            guard FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("share.json").path) else {
                throw PendingShareError.gone
            }
            try Self.write(data, to: folder(id).appendingPathComponent("placement.json"))
        }
    }

    /// Deletes a share for good: sent from its chat, or deleted by the person. The folder leaves in
    /// one rename first, so a share is never left half deleted. False when it was gone already.
    @discardableResult
    func remove(_ id: String) throws -> Bool {
        guard PendingShare.isValidID(id) else { return false }
        let target = trash.appendingPathComponent(id + "-" + PendingShare.newID(), isDirectory: true)
        let moved: Bool = try withInboxLock {
            guard FileManager.default.fileExists(atPath: folder(id).path) else { return false }
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            do { try FileManager.default.moveItem(at: folder(id), to: target) }
            catch { throw PendingShareError.storageUnavailable }
            return true
        }
        if moved { try? FileManager.default.removeItem(at: target) }
        return moved
    }

    /// Deletes staging folders whose share sheet is gone (cancelled, refused or killed), and
    /// anything left in the trash. A staging folder whose sheet still runs keeps its lock and stays.
    func removeAbandonedStaging() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: trash.path)) ?? [] {
            try? manager.removeItem(at: trash.appendingPathComponent(name))
        }
        // Under the inbox lock, so a draft is never caught between taking its lock and making its folder.
        try? withInboxLock {
            let names = Set((try? manager.contentsOfDirectory(atPath: staging.path)) ?? [])
            for id in Set(names.map { $0.hasSuffix(".lock") ? String($0.dropLast(5)) : $0 }) {
                let directory = staging.appendingPathComponent(id, isDirectory: true)
                let lockURL = staging.appendingPathComponent(id + ".lock")
                if names.contains(id + ".lock") {
                    // Still held: its sheet is writing.
                    guard let lock = try? PendingShareFileLock.acquire(lockURL, timeout: 0) else { continue }
                    try? manager.removeItem(at: directory)
                    try? manager.removeItem(at: lockURL)
                    lock.release()
                } else {
                    try? manager.removeItem(at: directory)
                }
            }
        }
    }

    // MARK: - Committing (used by `PendingShareDraft`)

    func commit(_ share: PendingShare, from stagingFolder: URL) throws {
        try withInboxLock {
            let waiting = entries()
            guard waiting.count < limits.shares else { throw PendingShareError.inboxFull(shares: waiting.count) }
            let held = waiting.reduce(0) { total, entry in
                if case .share(let share, _) = entry { return total + share.byteCount }
                return total + Self.folderSize(folder(entry.id))
            }
            guard held + share.byteCount <= limits.inboxBytes else {
                throw PendingShareError.inboxFull(shares: waiting.count)
            }
            do { try FileManager.default.moveItem(at: stagingFolder, to: folder(share.id)) }
            catch { throw PendingShareError.storageUnavailable }
        }
    }

    func prepareRoot() throws {
        do {
            for directory in [root, staging] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw PendingShareError.storageUnavailable
        }
        #if canImport(Darwin)
        // What's waiting here is copied from other apps for a moment; it doesn't belong in a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try? excluded.setResourceValues(values)
        #endif
    }

    func withInboxLock<T>(_ body: () throws -> T) throws -> T {
        try prepareRoot()
        guard let lock = try PendingShareFileLock.acquire(lockFile, timeout: 2) else {
            throw PendingShareError.storageUnavailable
        }
        defer { lock.release() }
        return try body()
    }

    // MARK: - Files

    /// Readable only once the device has been unlocked, and kept readable for a copy already under way.
    static var fileAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if canImport(Darwin)
        attributes[.protectionKey] = FileProtectionType.completeUnlessOpen
        #endif
        return attributes
    }

    static func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.atomic]
        #if canImport(Darwin)
        options.insert(.completeFileProtectionUnlessOpen)
        #endif
        do {
            try data.write(to: url, options: options)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PendingShareError.storageUnavailable
        }
    }

    /// Copies a file a megabyte at a time, stopping as soon as it passes `limit`: its size on disk
    /// can be wrong, or change while it's read, so only the count of what was read is trusted.
    static func copy(_ source: URL, to target: URL, name: String, limit: Int,
                     isCancelled: () -> Bool) throws -> Int {
        guard regularFileSize(source) != nil else { throw PendingShareError.unreadable(name: name) }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw PendingShareError.unreadable(name: name) }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: fileAttributes),
              let output = try? FileHandle(forWritingTo: target) else { throw PendingShareError.storageUnavailable }
        defer { try? output.close() }
        var total = 0
        while true {
            if isCancelled() { throw PendingShareError.cancelled }
            let block: Data
            do { block = try input.read(upToCount: 1_024 * 1_024) ?? Data() }
            catch { throw PendingShareError.unreadable(name: name) }
            guard !block.isEmpty else { break }
            total += block.count
            guard total <= limit else { throw PendingShareError.fileTooLarge(name: name, limit: limit) }
            do { try output.write(contentsOf: block) } catch { throw PendingShareError.storageUnavailable }
        }
        guard total > 0 else { throw PendingShareError.emptyFile(name: name) }
        do { try output.synchronize() } catch { throw PendingShareError.storageUnavailable }
        return total
    }

    /// Reads a small file whole, or nil when it's missing or over `limit`.
    static func read(_ url: URL, limit: Int) -> Data? {
        guard let size = regularFileSize(url), size <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    static func regularFileSize(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    private static func folderSize(_ url: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let file as URL in files { total += regularFileSize(file) ?? 0 }
        return total
    }
}

/// One share being saved. Each part goes straight to disk in the share's staging folder; `commit`
/// moves the folder into the inbox in one step, and `rollback` (or dropping it unsaved) deletes it.
final class PendingShareDraft: @unchecked Sendable {
    let id = PendingShare.newID()
    private let inbox: PendingShareInbox
    private let folder: URL
    private let lockURL: URL
    private var lock: PendingShareFileLock?
    private let state = NSLock()
    private var texts: [String] = []
    private var textBytes = 0
    private var links: [String] = []
    private var files: [PendingShare.File] = []
    private var isFinished = false

    fileprivate init(inbox: PendingShareInbox) throws {
        self.inbox = inbox
        folder = inbox.staging.appendingPathComponent(id, isDirectory: true)
        lockURL = inbox.staging.appendingPathComponent(id + ".lock")
        // The lock comes before the folder, both under the inbox lock, so a cleanup never takes the
        // folder for an abandoned one.
        let folder = folder
        let lockURL = lockURL
        lock = try inbox.withInboxLock { () throws -> PendingShareFileLock in
            guard let lock = try PendingShareFileLock.acquire(lockURL, timeout: 0) else {
                throw PendingShareError.storageUnavailable
            }
            do {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("files", isDirectory: true),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                try? FileManager.default.removeItem(at: lockURL)
                lock.release()
                throw PendingShareError.storageUnavailable
            }
            return lock
        }
    }

    deinit { rollback() }

    var limits: PendingShareLimits { inbox.limits }

    var isEmpty: Bool {
        state.withLock { texts.isEmpty && links.isEmpty && files.isEmpty }
    }

    /// Text another app shared. Kept exactly; text with no words in it is left out.
    func addText(_ text: String) throws {
        try state.withLock {
            guard !isFinished else { throw PendingShareError.finished }
            guard PendingShare.hasWords(text) else { return }
            let bytes = text.utf8.count + (texts.isEmpty ? 0 : 2)
            guard textBytes + bytes <= inbox.limits.textBytes else {
                throw PendingShareError.textTooLong(limit: inbox.limits.textBytes)
            }
            texts.append(text)
            textBytes += bytes
        }
    }

    /// A shared URL: a web link stays a link; anything else (a `mailto:`, a map) goes in as text.
    func addLink(_ link: String) throws {
        guard let web = PendingShare.webLink(link, limits: inbox.limits) else { return try addText(link) }
        try state.withLock {
            guard !isFinished else { throw PendingShareError.finished }
            guard !links.contains(web) else { return }
            guard links.count < inbox.limits.links else { throw PendingShareError.tooManyLinks(limit: inbox.limits.links) }
            links.append(web)
        }
    }

    /// Copies a shared file in, bounded by its kind's limit and the share's. The source can be a
    /// file iOS deletes once its callback returns, so this copies before it returns.
    @discardableResult
    func addFile(copying source: URL, suggestedName: String?, kind: PendingShare.File.Kind,
                 typeIdentifier: String, mimeType: String, preferredExtension: String?,
                 isCancelled: () -> Bool = { false }) throws -> PendingShare.File {
        let (index, name, room) = try state.withLock { () throws -> (Int, String, Int) in
            guard !isFinished else { throw PendingShareError.finished }
            guard files.count < inbox.limits.files else { throw PendingShareError.tooManyFiles(limit: inbox.limits.files) }
            let name = PendingShare.fileName(suggested: suggestedName, kind: kind,
                                             preferredExtension: preferredExtension, taken: Set(files.map(\.name)))
            return (files.count, name, inbox.limits.shareBytes - files.reduce(0) { $0 + $1.byteCount })
        }
        let type = PendingShare.isValidTypeIdentifier(typeIdentifier) ? typeIdentifier
            : (kind == .image ? "public.image" : "public.data")
        let mime = PendingShare.isValidMIMEType(mimeType.lowercased()) ? mimeType.lowercased()
            : (kind == .image ? "image/jpeg" : "application/octet-stream")
        let limit = inbox.limits.maximumBytes(for: kind)
        // What iOS says the size is, first; the copy then counts what it actually reads.
        guard let declared = PendingShareInbox.regularFileSize(source) else { throw PendingShareError.unreadable(name: name) }
        guard declared <= limit else { throw PendingShareError.fileTooLarge(name: name, limit: limit) }
        guard declared <= room else { throw PendingShareError.shareTooLarge(limit: inbox.limits.shareBytes) }
        let target = folder.appendingPathComponent("files/\(index)")
        let byteCount: Int
        do {
            byteCount = try PendingShareInbox.copy(source, to: target, name: name, limit: min(limit, room),
                                                   isCancelled: isCancelled)
        } catch PendingShareError.fileTooLarge where room < limit {
            try? FileManager.default.removeItem(at: target)
            throw PendingShareError.shareTooLarge(limit: inbox.limits.shareBytes)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        let file = PendingShare.File(name: name, kind: kind, typeIdentifier: type, mimeType: mime,
                                     byteCount: byteCount, storedName: "files/\(index)")
        try state.withLock {
            guard !isFinished, files.count == index else { throw PendingShareError.finished }
            files.append(file)
        }
        return file
    }

    /// Saves the share with the person's note and hands it to the inbox. Afterwards the draft is done.
    func commit(note: String) throws -> PendingShare {
        let share: PendingShare = try state.withLock {
            guard !isFinished else { throw PendingShareError.finished }
            guard note.utf8.count <= inbox.limits.noteBytes else {
                throw PendingShareError.noteTooLong(limit: inbox.limits.noteBytes)
            }
            var text = texts.joined(separator: "\n\n")
            var files = files
            if text.utf8.count > inbox.limits.inlineTextBytes {
                // A long text goes as a file, every byte of it, rather than into the message box.
                guard files.count < inbox.limits.files else {
                    throw PendingShareError.tooManyFiles(limit: inbox.limits.files)
                }
                let data = Data(text.utf8)
                guard files.reduce(data.count, { $0 + $1.byteCount }) <= inbox.limits.shareBytes else {
                    throw PendingShareError.shareTooLarge(limit: inbox.limits.shareBytes)
                }
                let index = files.count
                try PendingShareInbox.write(data, to: folder.appendingPathComponent("files/\(index)"))
                let name = PendingShare.fileName(suggested: PendingShare.textFileName, kind: .file,
                                                 preferredExtension: "txt", taken: Set(files.map(\.name)))
                files.append(.init(name: name, kind: .file, typeIdentifier: "public.utf8-plain-text",
                                   mimeType: "text/plain", byteCount: data.count, storedName: "files/\(index)"))
                text = ""
            }
            guard PendingShare.hasWords(text) || !links.isEmpty || !files.isEmpty else {
                throw PendingShareError.nothingToShare
            }
            let share = PendingShare(version: PendingShare.currentVersion, id: id, createdAt: inbox.now(),
                                     text: text, links: links, note: PendingShare.hasWords(note) ? note : "",
                                     files: files)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let manifest = try encoder.encode(share)
            guard manifest.count <= inbox.limits.manifestBytes else {
                throw PendingShareError.textTooLong(limit: inbox.limits.inlineTextBytes)
            }
            try PendingShareInbox.write(manifest, to: folder.appendingPathComponent("share.json"))
            try inbox.commit(share, from: folder)
            isFinished = true
            return share
        }
        // The folder is in the inbox now; its lock file goes, then the lock.
        try? FileManager.default.removeItem(at: lockURL)
        lock?.release()
        lock = nil
        return share
    }

    /// Throws the staged parts away. Safe to call more than once, and after a commit.
    func rollback() {
        let wasFinished = state.withLock { () -> Bool in
            defer { isFinished = true }
            return isFinished
        }
        if !wasFinished { try? FileManager.default.removeItem(at: folder) }
        if let lock {
            try? FileManager.default.removeItem(at: lockURL)
            lock.release()
            self.lock = nil
        }
    }

    #if DEBUG
    /// A sheet that iOS killed mid-copy: its lock goes with its process, its folder stays.
    func abandonForTesting() {
        state.withLock { isFinished = true }
        lock?.release()
        lock = nil
    }
    #endif
}

/// An advisory lock on a file (`flock`), held until `release` or until the process ends.
final class PendingShareFileLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { release() }

    /// Nil when another holder keeps it past `timeout` seconds.
    static func acquire(_ url: URL, timeout: TimeInterval) throws -> PendingShareFileLock? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PendingShareError.storageUnavailable }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(descriptor)
                return nil
            }
            usleep(10_000)
        }
        return PendingShareFileLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
