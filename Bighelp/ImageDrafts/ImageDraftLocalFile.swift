import Foundation

/// The person's edits to drafts and the approvals of Saves still in progress. These are a person's
/// details, so they live in one protected file in Application Support (readable after the first
/// unlock, so a relaunch in the background can settle a Save), never in UserDefaults or logs, and
/// never in backups. Bounded: the oldest drafts go first, but never one with a Save in progress.
@MainActor
final class ImageDraftLocalFile: ImageDraftPendingStoring {
    static let maximumRecords = 200
    static let maximumBytes = 4_000_000

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "BighelpImageDrafts", directoryHint: .isDirectory)

    struct Record: Codable, Equatable, Sendable {
        var edits: ImageDraftEdits?
        var pending: ImageDraftApproval?
        var updatedAt: Date
    }

    private struct Snapshot: Codable {
        var version = 1
        var records: [String: Record]
    }

    private let url: URL
    private let clock: () -> Date
    private var loaded: [String: Record]?
    private var pendingWrite: Task<Void, Never>?

    init(url: URL = ImageDraftLocalFile.directory.appending(path: "drafts-v1.json"), clock: @escaping () -> Date = { Date() }) {
        self.url = url
        self.clock = clock
    }

    // MARK: Edits

    func edits(for key: ImageDraftKey) -> ImageDraftEdits? { records[key.storageKey]?.edits }

    /// Kept at once in memory; written a moment later, so typing doesn't write on every key.
    func keepEdits(_ edits: ImageDraftEdits?, for key: ImageDraftKey) {
        var all = records
        var record = all[key.storageKey] ?? Record(updatedAt: clock())
        record.edits = edits
        record.updatedAt = clock()
        all[key.storageKey] = record.edits == nil && record.pending == nil ? nil : record
        loaded = all
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? self?.write()
        }
    }

    // MARK: Pending approvals

    func pendingApproval(for key: ImageDraftKey) -> ImageDraftApproval? { records[key.storageKey]?.pending }

    /// Written before the Save goes on: a Save that can't be remembered doesn't start.
    func setPendingApproval(_ approval: ImageDraftApproval) throws {
        var all = records
        var record = all[approval.key.storageKey] ?? Record(updatedAt: clock())
        record.pending = approval
        record.updatedAt = clock()
        all[approval.key.storageKey] = record
        loaded = all
        try write()
    }

    func clearPendingApproval(for key: ImageDraftKey) {
        guard var record = records[key.storageKey], record.pending != nil else { return }
        record.pending = nil
        loaded?[key.storageKey] = record.edits == nil ? nil : record
        try? write()
    }

    /// Every key with a Save in progress, for settling after a relaunch.
    var pendingKeys: [ImageDraftKey] { records.values.compactMap { $0.pending?.key } }

    /// Removes everything: a removed computer's drafts can't be told apart by their one-way names.
    func erase() {
        pendingWrite?.cancel()
        loaded = [:]
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: File

    private var records: [String: Record] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: url)).flatMap { data -> [String: Record]? in
            guard data.count <= Self.maximumBytes else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data).records
        } ?? [:]
        loaded = read
        return read
    }

    private func write() throws {
        pendingWrite?.cancel()
        pendingWrite = nil
        var all = records
        if all.count > Self.maximumRecords {
            let removable = all.filter { $0.value.pending == nil }.sorted { $0.value.updatedAt < $1.value.updatedAt }
            for (key, _) in removable.prefix(all.count - Self.maximumRecords) { all[key] = nil }
            loaded = all
        }
        let data = try JSONEncoder().encode(Snapshot(records: all))
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}
