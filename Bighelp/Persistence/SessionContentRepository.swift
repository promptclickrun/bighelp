import Foundation

/// Keeps legacy repository injection and the throwing canonical-send checkpoint
/// intact while allowing production to prepare only changed session payloads.
@MainActor
protocol SessionCatalogRepository: AnyObject {
    var supportsContentCompaction: Bool { get }
    /// How many bytes the last save wrote, for pacing automatic saves. Zero when unknown.
    var lastSaveByteCount: Int { get }
    func load() throws -> [SessionRecord]
    func loadSession(id: String) throws -> SessionRecord?
    func restoreContent(in record: SessionRecord) throws -> SessionRecord
    func compactContent(in record: SessionRecord) throws -> SessionRecord
    func save(_ records: [SessionRecord]) throws
    func saveEncoded(_ data: Data) throws
    func encodeSnapshot(_ records: [SessionRecord]) async throws -> Data
    func resetForAccountBoundary()
}

extension SessionCatalogRepository {
    var supportsContentCompaction: Bool { false }
    var lastSaveByteCount: Int { 0 }
    func loadSession(id: String) throws -> SessionRecord? {
        try load().first { $0.id == id }
    }

    func restoreContent(in record: SessionRecord) throws -> SessionRecord { record }
    func compactContent(in record: SessionRecord) throws -> SessionRecord { record }

    func encodeSnapshot(_ records: [SessionRecord]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try DemoRepository<[SessionRecord]>.encodeForSave(records)
        }.value
    }

    func resetForAccountBoundary() {}
}

extension DemoRepository: SessionCatalogRepository where Value == [SessionRecord] {
    func encodeSnapshot(_ records: [SessionRecord]) async throws -> Data {
        try await prepareCheckpoint(records)
    }

    func resetForAccountBoundary() { discardPreparedCheckpoint() }
}

enum SessionContentRepositoryError: Error, Equatable {
    case invalidManifest
    case missingContent(String)
    case staleCheckpoint
}

/// A protected metadata manifest points to immutable, session-specific revisions.
/// Content is written first; atomic manifest replacement is the only commit.
/// Failed adoption leaves the old manifest and every referenced revision intact.
/// The manifest itself is a small root file and the rows in parts (`SessionListParts`): each
/// part is a file that never changes once written, and replacing the root is the commit. A
/// save writes only the parts whose rows changed; as one file, one changed row wrote megabytes.
/// Builds before parts kept the rows in one file. Its place now holds a marker those builds
/// refuse (`retiredListSchemaVersion`), so one of them shows the computer's own list and
/// saves nothing here, never an older copy.
/// A chat with nothing in it has no revision of its own: all of them point to
/// `emptyContentRevision`. A host's list is mostly chats this device never opened, and
/// a file for each made every save write thousands of files on the main thread.
/// All files remain beneath DemoRepository's existing host directory, which the
/// account data eraser already removes. Legacy snapshots are never deleted here.
@MainActor
final class SessionContentRepository: SessionCatalogRepository {
    var supportsContentCompaction: Bool { true }
    private struct Manifest: Codable, Sendable {
        var revision: UUID?
        var records: [SessionRecord] = []
    }

    /// The root file: which part files hold the rows, and the order the rows go in.
    private struct Root: Codable, Sendable {
        var revision: UUID?
        /// One entry a part. A part with no rows has no file.
        var parts: [UUID?] = []
        /// One byte a row, in the list's order: the part the row is in. Rows keep their order
        /// inside a part, so the list comes back exactly as it was saved.
        var order = Data()
    }

    /// The root's revision alone, read through a repository of its own: committing checks the
    /// file is still the one the plan was made from, without that counting as a read of the rows.
    private struct RootRevision: Codable, Sendable {
        var revision: UUID?
    }

    /// What stands where builds before parts kept the list.
    private struct RetiredList: Codable, Sendable {
        var movedTo = "catalog-root"
    }

    /// No build's schema version gets this high, so every build refuses the marker's file.
    nonisolated static let retiredListSchemaVersion = 1_000_000

    private struct Content: Codable, Equatable, Sendable {
        var draft: String
        var referenceState: ReferenceCanonicalState?
        var items: [TimelineItem]
        var botModePrivateHistory: [TimelineItem]
        var activityEvents: [ChatActivityEvent]

        init(_ record: SessionRecord) {
            draft = record.draft
            referenceState = record.referenceState
            items = record.items
            botModePrivateHistory = record.botModePrivateHistory
            activityEvents = record.activityEvents
        }

        static let empty = Content(SessionRecord(id: "", kind: .direct, agentIDs: [], title: ""))

        var isEmpty: Bool {
            draft.isEmpty && referenceState == nil && items.isEmpty
                && botModePrivateHistory.isEmpty && activityEvents.isEmpty
        }

        func restoring(_ metadata: SessionRecord) -> SessionRecord {
            var record = metadata
            record.draft = draft
            record.referenceState = referenceState
            record.items = items
            record.botModePrivateHistory = botModePrivateHistory
            record.activityEvents = activityEvents
            record.localContentRevision = nil
            record.localContentScope = nil
            record.catalogPreview = nil
            record.catalogHasDraft = false
            record.hasDeferredReferenceState = false
            return record
        }
    }

    private struct Plan: Sendable {
        let schemaVersion: Int
        let scope: String
        let epoch: UUID
        let baseRevision: UUID?
        let manifest: Manifest
        /// The rows and the parts the plan was made from, to tell which parts it changes.
        let baseRecords: [SessionRecord]
        let baseParts: [UUID?]
        let content: [UUID: Content]
        /// Each chat that was saved with its content loaded, and the revision that holds it.
        let loaded: [String: SavedContent]

        func encoded() throws -> PreparedSave {
            let writes = try content.map { revision, value in
                EncodedWrite(revision: revision,
                             data: try DemoRepository<Content>.prepareEncoding(value, schemaVersion: schemaVersion))
            }
            return PreparedSave(
                scope: scope, epoch: epoch, baseRevision: baseRevision, baseParts: baseParts,
                list: try EncodedList(rows: manifest.records, revision: manifest.revision, baseRows: baseRecords,
                                      baseParts: baseParts, schemaVersion: schemaVersion),
                writes: writes
            )
        }
    }

    /// The list as a save writes it: the root, and a new file for each part whose rows changed.
    private struct EncodedList: Sendable {
        let root: DemoRepositoryPreparedEncoding
        /// What `root` encodes, to read the parts back before the root is written.
        let rootValue: Root
        let parts: [UUID?]
        let writes: [EncodedWrite]

        /// `baseParts` is empty when no parts are on disk yet; every part is then written.
        init(rows: [SessionRecord], revision: UUID?, baseRows: [SessionRecord], baseParts: [UUID?],
             schemaVersion: Int) throws {
            let count = SessionListParts.count(for: rows.count, current: baseParts.count)
            let divided = SessionListParts.divide(rows, into: count)
            // More rows than the parts are for: every row has a new part, so all are written.
            let before = baseParts.count == count ? SessionListParts.divide(baseRows, into: count).parts : nil
            var parts = [UUID?](repeating: nil, count: count)
            var writes: [EncodedWrite] = []
            for index in 0..<count where !divided.parts[index].isEmpty {
                if let before, let kept = baseParts[index], before[index] == divided.parts[index] {
                    parts[index] = kept
                    continue
                }
                let part = UUID()
                parts[index] = part
                writes.append(EncodedWrite(revision: part, data: try DemoRepository<[SessionRecord]>.prepareEncoding(
                    divided.parts[index], schemaVersion: schemaVersion)))
            }
            self.parts = parts
            self.writes = writes
            rootValue = Root(revision: revision, parts: parts, order: divided.order)
            root = try DemoRepository<Root>.prepareEncoding(rootValue, schemaVersion: schemaVersion)
        }
    }

    private struct EncodedWrite: Sendable {
        let revision: UUID
        let data: DemoRepositoryPreparedEncoding
    }

    private struct PreparedSave: Sendable {
        let scope: String
        let epoch: UUID
        let baseRevision: UUID?
        let baseParts: [UUID?]
        let list: EncodedList
        let writes: [EncodedWrite]
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let schemaVersion: Int
        let value: Value
    }

    private struct EncodingFormat: Decodable {
        let schemaVersion: Int?
    }

    private struct CheckpointHandle: Codable {
        let id: UUID
    }

    private struct ResidentContent {
        let value: Content
        let bytes: Int
    }

    private struct SavedContent: Sendable {
        let revision: UUID
        let value: Content
    }

    private struct PreparedCheckpoint {
        let id: UUID
        let plan: Plan
        let encoded: PreparedSave
    }

    private let legacy: DemoRepository<[SessionRecord]>
    private let protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding
    private let rootRepository: DemoRepository<Root>
    private let rootRevisionRepository: DemoRepository<RootRevision>
    /// The one file builds before parts kept the list in, and the marker that takes its place.
    private let oneFileListRepository: DemoRepository<Manifest>
    private let retiredListRepository: DemoRepository<RetiredList>
    private let name: String
    private let seed: [SessionRecord]
    private var scope: String?
    private var epoch = UUID()
    private var manifest: Manifest?
    /// The parts the root on disk lists for `manifest`. Empty while the list has no root yet.
    private var savedParts: [UUID?] = []
    /// The scopes whose one-file list this process has retired, or tried to.
    private var retiredListScopes: Set<String> = []
    /// Only payloads explicitly loaded or changed in this process are retained.
    private var contentCache: [UUID: ResidentContent] = [:]
    private var contentCacheOrder: [UUID] = []
    private let maximumResidentContentEntries: Int
    private let maximumResidentContentBytes: Int
    private var residentContentBytes = 0
    /// What the last save wrote for each chat whose content the catalog holds. The catalog
    /// owns those transcripts already, so keeping them costs nothing, and a save can tell an
    /// unchanged chat from a changed one however many are loaded. The cache above holds six.
    private var savedContent: [String: SavedContent] = [:]
    /// The scopes whose unreferenced content files this process has already removed.
    private var cleanedScopes: Set<String> = []
    private var preparedCheckpoint: PreparedCheckpoint?
    private(set) var contentWriteCount = 0
    private(set) var lastSaveByteCount = 0
    private(set) var contentLoadCount = 0
    var residentContentCount: Int { contentCache.count }

    /// The revision of every chat with no draft, messages or activity. Its file is written
    /// with the first chat that points to it and removed with the last, like any revision.
    nonisolated static let emptyContentRevision = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    var residentContentByteCount: Int { residentContentBytes }

    init(
        directory: URL,
        name: String = "sessions",
        seed: [SessionRecord] = [],
        fileManager: FileManager = .default,
        fileProtection: any BighelpLocalFileProtecting = BighelpLocalFileProtector(),
        protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability(),
        scopeID: (() -> String?)? = nil,
        currentSchemaVersion: Int = 1,
        migrations: [DemoRepositoryMigration] = [],
        maximumResidentContentEntries: Int = 6,
        maximumResidentContentBytes: Int = 64 * 1024 * 1024
    ) {
        precondition(maximumResidentContentEntries > 0)
        precondition(maximumResidentContentBytes > 0)
        let legacy = DemoRepository<[SessionRecord]>(
            directory: directory, name: name, seed: seed, fileManager: fileManager,
            fileProtection: fileProtection, protectedDataAvailability: protectedDataAvailability,
            migrations: migrations, scopeID: scopeID, currentSchemaVersion: currentSchemaVersion
        )
        self.legacy = legacy
        self.protectedDataAvailability = protectedDataAvailability
        self.name = name
        self.seed = seed
        rootRepository = legacy.child(name: "\(name)-catalog-root", seed: Root())
        rootRevisionRepository = legacy.child(name: "\(name)-catalog-root", seed: RootRevision())
        oneFileListRepository = legacy.child(name: "\(name)-catalog", seed: Manifest())
        retiredListRepository = legacy.child(name: "\(name)-catalog", seed: RetiredList(),
                                             schemaVersion: Self.retiredListSchemaVersion)
        self.maximumResidentContentEntries = maximumResidentContentEntries
        self.maximumResidentContentBytes = maximumResidentContentBytes
    }

    func resetForAccountBoundary() {
        scope = nil
        epoch = UUID()
        manifest = nil
        savedParts = []
        forgetLoadedContent()
        preparedCheckpoint = nil
    }

    func load() throws -> [SessionRecord] {
        try selectScope()
        // Another repository instance or the account eraser may have changed durable state
        // since our last load, so the cached manifest stands only while its file is the same.
        if !rootRepository.holdsKnownFile {
            manifest = nil
            savedParts = []
        }
        try ensureManifest()
        let retained = Set((manifest?.records ?? []).compactMap(\.localContentRevision))
        retainResidentContent(revisions: retained)
        if let scope, !cleanedScopes.contains(scope), let sweep = unreferencedContentSweep() {
            cleanedScopes.insert(scope)
            Task.detached(priority: .utility) { _ = sweep() }
        }
        return manifest?.records ?? []
    }

    /// Removes content files no row points to, and part files the root doesn't list. A save
    /// ended part-way (the watchdog, a crash, a full disk) leaves the files it wrote before the
    /// root, and a save only removes the revisions it retires itself.
    @discardableResult
    func removeUnreferencedContent() async -> Int {
        guard let sweep = unreferencedContentSweep() else { return 0 }
        return await Task.detached(priority: .utility, operation: sweep).value
    }

    /// The removal, with the folder and the rows read in this one step: a switch to another
    /// computer before it runs must not point one computer's rows at another's folder.
    /// Files from the last minute stay, since whatever this process writes from now on is newer
    /// than that. The shared empty revision is never touched, because a later save may write
    /// that same file again.
    private func unreferencedContentSweep() -> (@Sendable () -> Int)? {
        guard let scope, let manifest, (try? legacy.storageScopeIdentifier()) == scope,
              let directory = try? legacy.scopedDirectory(),
              protectedDataAvailability.isProtectedDataAvailable else { return nil }
        // A part's revision is never one of a content file's, so one set serves both kinds.
        let referenced = Set(manifest.records.compactMap(\.localContentRevision)).union(savedParts.compactMap { $0 })
        let prefixes = ["\(name)-content-", "\(name)-catalog-part-"], suffix = "-v1.json"
        let cutoff = Date.now.addingTimeInterval(-60)
        return {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            var removed = 0
            for file in files {
                let fileName = file.lastPathComponent
                guard let prefix = prefixes.first(where: fileName.hasPrefix), fileName.hasSuffix(suffix),
                      let revision = UUID(uuidString: String(fileName.dropFirst(prefix.count).dropLast(suffix.count))),
                      revision != Self.emptyContentRevision, !referenced.contains(revision),
                      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
            return removed
        }
    }

    func loadSession(id: String) throws -> SessionRecord? {
        try ensureManifest()
        guard let metadata = manifest?.records.first(where: { $0.id == id }) else { return nil }
        return try restoreContent(in: metadata)
    }

    func restoreContent(in metadata: SessionRecord) throws -> SessionRecord {
        guard let revision = metadata.localContentRevision else { return metadata }
        try ensureManifest()
        guard metadata.localContentScope == scope,
              manifest?.records.contains(where: { $0.localContentRevision == revision }) == true else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        let content: Content
        if revision == Self.emptyContentRevision {
            content = .empty
        } else if let cached = residentContent(revision) {
            content = cached
        } else {
            let child = contentRepository(revision)
            guard let loaded = try child.loadExistingPreservingSourceWithByteCount() else {
                throw SessionContentRepositoryError.missingContent(metadata.id)
            }
            content = loaded.value
            rememberResidentContent(content, revision: revision, bytes: loaded.byteCount)
            contentLoadCount += 1
        }
        return content.restoring(metadata)
    }

    func compactContent(in record: SessionRecord) throws -> SessionRecord {
        try ensureManifest()
        guard let metadata = manifest?.records.first(where: { $0.id == record.id }) else {
            throw SessionContentRepositoryError.missingContent(record.id)
        }
        guard metadata.kind == record.kind,
              metadata.agentIDs == record.agentIDs,
              metadata.remoteStoredID == record.remoteStoredID,
              DirectHermesIdentity.sameSessionSource(
                metadata.remoteSource,
                record.remoteSource
              ) else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        savedContent[record.id] = nil
        return metadata
    }

    func save(_ records: [SessionRecord]) throws {
        let plan = try prepare(records)
        try commit(plan.encoded(), plan: plan)
    }

    func encodeSnapshot(_ records: [SessionRecord]) async throws -> Data {
        let plan = try prepare(records)
        let encoded = try await Task.detached(priority: .utility) { try plan.encoded() }.value
        try Task.checkCancellation()
        try selectScope()
        guard plan.epoch == epoch, plan.scope == scope,
              plan.baseRevision == manifest?.revision else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        let id = UUID()
        // Return a one-shot handle, not a second base64 encoding of the changed
        // transcripts. Adoption reuses the validated snapshot instead of
        // decoding large payloads back on the main actor.
        preparedCheckpoint = PreparedCheckpoint(id: id, plan: plan, encoded: encoded)
        return try JSONEncoder().encode(CheckpointHandle(id: id))
    }

    func saveEncoded(_ data: Data) throws {
        // Preserve the legacy injectable encoder seam. Production uses the
        // scoped prepared format below; callers supplying legacy snapshot bytes
        // retain the same account/revision guards as DemoRepository.saveEncoded.
        if let version = try JSONDecoder().decode(EncodingFormat.self, from: data).schemaVersion {
            guard version == legacy.currentSchemaVersion else {
                throw DemoRepositoryError.unsupportedSchemaVersion(found: version, current: legacy.currentSchemaVersion)
            }
            let records = try JSONDecoder().decode(Envelope<[SessionRecord]>.self, from: data).value
            try save(records)
            return
        }
        let handle = try JSONDecoder().decode(CheckpointHandle.self, from: data)
        guard let checkpoint = preparedCheckpoint, checkpoint.id == handle.id else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        try commit(checkpoint.encoded, plan: checkpoint.plan)
    }

    private func commit(_ prepared: PreparedSave, plan: Plan) throws {
        try selectScope()
        guard prepared.scope == scope, prepared.epoch == epoch else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        // The root this repository last read or wrote holds the manifest it has in memory.
        // Reading megabytes of rows back from disk to learn one revision held the main thread.
        let currentRevision: UUID?
        if let manifest, rootRepository.holdsKnownFile {
            currentRevision = manifest.revision
        } else {
            currentRevision = try rootRevisionRepository.loadExistingPreservingSource()?.revision
        }
        guard currentRevision == prepared.baseRevision else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        let currentRecords: [SessionRecord], currentParts: [UUID?]
        if let manifest, manifest.revision == currentRevision {
            (currentRecords, currentParts) = (manifest.records, savedParts)
        } else if let saved = try loadList() {
            (currentRecords, currentParts) = (saved.manifest.records, saved.parts)
        } else {
            (currentRecords, currentParts) = ([], [])
        }
        // The plan left unchanged parts where they are, so they must be the ones on disk.
        guard currentParts == prepared.baseParts else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        let candidate = plan.manifest
        try validate(candidate)
        let currentRevisions = Set(currentRecords.compactMap(\.localContentRevision))
        let writes = Set(prepared.writes.map(\.revision))
        guard writes.count == prepared.writes.count,
              writes.isDisjoint(with: currentRevisions),
              Set(candidate.records.compactMap(\.localContentRevision)).isSubset(of: currentRevisions.union(writes))
        else { throw SessionContentRepositoryError.invalidManifest }

        for write in prepared.writes {
            try contentRepository(write.revision).savePreparedEncoding(write.data)
            contentWriteCount += 1
        }
        for write in prepared.list.writes {
            try partRepository(write.revision).savePreparedEncoding(write.data)
        }
        try rootRepository.savePreparedEncoding(prepared.list.root)
        // Publish the new base only after durable adoption. A thrown write must
        // not poison change detection or a retry's original revision guard.
        manifest = candidate
        savedParts = prepared.list.parts
        preparedCheckpoint = nil
        savedContent = plan.loaded
        lastSaveByteCount = (prepared.writes + prepared.list.writes)
            .reduce(prepared.list.root.byteCount) { $0 + $1.data.byteCount }
        let encodedByteCounts = Dictionary(uniqueKeysWithValues: prepared.writes.map {
            ($0.revision, $0.data.byteCount)
        })
        for (revision, value) in plan.content where revision != Self.emptyContentRevision {
            rememberResidentContent(
                value,
                revision: revision,
                bytes: encodedByteCounts[revision] ?? 0
            )
        }
        let retained = Set(candidate.records.compactMap(\.localContentRevision))
        retainResidentContent(revisions: retained)
        // Cleanup is post-commit and best effort, never part of send success.
        // Only revisions retired by this exact adoption are eligible; pending
        // writes and the original legacy snapshot are deliberately untouched.
        for retired in currentRevisions.subtracting(retained) {
            try? contentRepository(retired).removeExistingFile()
        }
        for retired in Set(currentParts.compactMap { $0 }).subtracting(prepared.list.parts.compactMap { $0 }) {
            try? partRepository(retired).removeExistingFile()
        }
        retireOneFileList()
    }

    private func selectScope() throws {
        let selected = try legacy.storageScopeIdentifier()
        guard selected != scope else { return }
        resetForAccountBoundary()
        scope = selected
    }

    private func ensureManifest() throws {
        try selectScope()
        guard manifest == nil else { return }
        if let saved = try loadList() {
            try validate(saved.manifest)
            manifest = saved.manifest
            savedParts = saved.parts
            retireOneFileList()
            return
        }
        // A list from a build before parts. With no root, a retired one-file list throws here:
        // the list is then unreadable, and nothing older stands in for it.
        if let saved = try oneFileListRepository.loadExistingPreservingSource() {
            try validate(saved)
            try moveIntoParts(saved)
            return
        }
        // The sole whole-history read is first-use migration. Preserve even an
        // older-schema original byte-for-byte until and after manifest commit.
        let records = try legacy.loadExistingPreservingSource() ?? seed
        manifest = Manifest()
        guard !records.isEmpty else { return }
        do {
            try save(records)
            // Migration is the sole whole-history read; do not keep that
            // temporary decoded corpus alive behind a metadata-only catalog.
            forgetLoadedContent()
        } catch {
            manifest = nil
            forgetLoadedContent()
            throw error
        }
    }

    /// The rows as the root and its parts hold them, or nil when there is no root.
    private func loadList() throws -> (manifest: Manifest, parts: [UUID?])? {
        guard let root = try rootRepository.loadExistingPreservingSource() else { return nil }
        return (Manifest(revision: root.revision, records: try rows(of: root)), root.parts)
    }

    /// The rows a root names, read from its part files and put back in the list's order.
    private func rows(of root: Root) throws -> [SessionRecord] {
        let count = root.parts.count
        // The number of parts only ever doubles from one.
        guard count <= SessionListParts.maximumCount, count & (count - 1) == 0 else {
            throw SessionContentRepositoryError.invalidManifest
        }
        let parts = try root.parts.enumerated().map { index, part -> [SessionRecord] in
            guard let part else { return [] }
            guard let rows = try partRepository(part).loadExistingPreservingSource(),
                  rows.allSatisfy({ SessionListParts.part(of: $0.id, among: count) == index }) else {
                throw SessionContentRepositoryError.invalidManifest
            }
            return rows
        }
        var taken = [Int](repeating: 0, count: count)
        var records: [SessionRecord] = []
        records.reserveCapacity(root.order.count)
        for byte in root.order {
            let part = Int(byte)
            guard part < count, taken[part] < parts[part].count else {
                throw SessionContentRepositoryError.invalidManifest
            }
            records.append(parts[part][taken[part]])
            taken[part] += 1
        }
        guard zip(taken, parts).allSatisfy({ $0 == $1.count }) else {
            throw SessionContentRepositoryError.invalidManifest
        }
        return records
    }

    /// Takes the one-file list of a build before parts: the same rows and revision, as parts and
    /// a root. Content files stay as they are, so every draft and transcript is where its row
    /// says. Stopped before the root is written, the one file is still the list and the next
    /// launch does this again. The parts are read back first: the root is written, and the one
    /// file retired, only for parts that give the same rows in the same order.
    private func moveIntoParts(_ saved: Manifest) throws {
        let list = try EncodedList(rows: saved.records, revision: saved.revision, baseRows: [], baseParts: [],
                                   schemaVersion: legacy.currentSchemaVersion)
        for write in list.writes {
            try partRepository(write.revision).savePreparedEncoding(write.data)
        }
        guard try rows(of: list.rootValue) == saved.records else {
            throw SessionContentRepositoryError.invalidManifest
        }
        try rootRepository.savePreparedEncoding(list.root)
        manifest = saved
        savedParts = list.parts
        retireOneFileList(knownToHoldRows: true)
    }

    /// Puts the marker where builds before parts kept the list, once the root holds the rows. A
    /// build from before then refuses the file: it reads the computer's own list and saves nothing
    /// here. Without the marker it would start from whatever it finds, an older copy or nothing,
    /// and clear this list's files away. Best effort, and tried once a launch for each computer:
    /// a marker that isn't written is tried again at the next launch, and the root is the list
    /// either way.
    private func retireOneFileList(knownToHoldRows: Bool = false) {
        guard let scope, retiredListScopes.insert(scope).inserted else { return }
        if !knownToHoldRows {
            // A read that throws found the marker, or a file that is no list: nothing to retire.
            // No file at all (a list that began in parts) gets the marker like a list does.
            do { _ = try oneFileListRepository.loadExistingPreservingSource() } catch { return }
        }
        try? retiredListRepository.save(RetiredList())
    }

    private func forgetLoadedContent() {
        contentCache.removeAll()
        contentCacheOrder.removeAll()
        residentContentBytes = 0
        savedContent.removeAll()
    }

    private func prepare(_ records: [SessionRecord]) throws -> Plan {
        try ensureManifest()
        guard let scope, let manifest else { throw SessionContentRepositoryError.invalidManifest }
        guard Set(records.map(\.id)).count == records.count else {
            throw SessionContentRepositoryError.invalidManifest
        }
        let existing = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.id, $0) })
        let knownRevisions = Set(manifest.records.compactMap(\.localContentRevision))
        var content: [UUID: Content] = [:]
        var loaded: [String: SavedContent] = [:]
        let metadata = try records.map { record -> SessionRecord in
            if let revision = record.localContentRevision {
                // Metadata-only edits reuse the exact existing content pointer.
                // Never interpret a lazy projection's [] or empty draft as a
                // request to replace a protected transcript.
                guard record.localContentScope == scope, knownRevisions.contains(revision),
                      record.items.isEmpty, record.botModePrivateHistory.isEmpty,
                      record.activityEvents.isEmpty, record.draft.isEmpty,
                      record.referenceState == nil else {
                    throw SessionContentRepositoryError.missingContent(record.id)
                }
                return record
            }
            let payload = Content(record)
            let revision: UUID
            if payload.isEmpty {
                revision = Self.emptyContentRevision
                if !knownRevisions.contains(revision) { content[revision] = payload }
            } else {
                if let old = existing[record.id]?.localContentRevision, old != Self.emptyContentRevision,
                   holds(payload, for: record.id, at: old) {
                    revision = old
                } else {
                    revision = UUID()
                    content[revision] = payload
                }
                loaded[record.id] = SavedContent(revision: revision, value: payload)
            }
            var row = record
            row.localContentRevision = revision
            row.localContentScope = scope
            row.catalogPreview = String(record.summary.preview.prefix(512))
            row.catalogHasDraft = SessionRecord.holdsDraft(record.draft)
            row.hasDeferredReferenceState = record.referenceState != nil
                || (!record.draft.isEmpty && ReferenceCodec.decode(record.draft).hasValidAppendix)
            row.draft = ""
            row.referenceState = nil
            row.items = []
            row.botModePrivateHistory = []
            row.activityEvents = []
            return row
        }
        return Plan(schemaVersion: legacy.currentSchemaVersion, scope: scope, epoch: epoch, baseRevision: manifest.revision,
                    manifest: Manifest(revision: UUID(), records: metadata), baseRecords: manifest.records,
                    baseParts: savedParts, content: content, loaded: loaded)
    }

    /// Whether `revision` already holds exactly this content for the chat.
    private func holds(_ payload: Content, for id: String, at revision: UUID) -> Bool {
        if let saved = savedContent[id], saved.revision == revision { return saved.value == payload }
        return residentContent(revision) == payload
    }

    private func validate(_ manifest: Manifest) throws {
        guard Set(manifest.records.map(\.id)).count == manifest.records.count,
              manifest.records.allSatisfy({
                  $0.localContentRevision != nil && $0.localContentScope == scope
                      && $0.items.isEmpty && $0.botModePrivateHistory.isEmpty
                      && $0.activityEvents.isEmpty && $0.draft.isEmpty && $0.referenceState == nil
              }) else { throw SessionContentRepositoryError.invalidManifest }
    }

    private func contentRepository(_ revision: UUID) -> DemoRepository<Content> {
        legacy.child(name: "\(name)-content-\(revision.uuidString.lowercased())", seed: Content(
            SessionRecord(id: "", kind: .direct, agentIDs: [], title: "")
        ))
    }

    private func partRepository(_ part: UUID) -> DemoRepository<[SessionRecord]> {
        legacy.child(name: "\(name)-catalog-part-\(part.uuidString.lowercased())", seed: [])
    }

    private func residentContent(_ revision: UUID) -> Content? {
        guard let entry = contentCache[revision] else { return nil }
        contentCacheOrder.removeAll { $0 == revision }
        contentCacheOrder.append(revision)
        return entry.value
    }

    private func rememberResidentContent(_ content: Content, revision: UUID, bytes: Int) {
        guard bytes > 0, bytes <= maximumResidentContentBytes else {
            removeResidentContent(revision)
            return
        }
        removeResidentContent(revision)
        while contentCache.count >= maximumResidentContentEntries
            || residentContentBytes + bytes > maximumResidentContentBytes {
            guard let oldest = contentCacheOrder.first else { break }
            removeResidentContent(oldest)
        }
        contentCache[revision] = ResidentContent(value: content, bytes: bytes)
        contentCacheOrder.append(revision)
        residentContentBytes += bytes
    }

    private func retainResidentContent(revisions: Set<UUID>) {
        for revision in Array(contentCache.keys) where !revisions.contains(revision) {
            removeResidentContent(revision)
        }
    }

    private func removeResidentContent(_ revision: UUID) {
        if let removed = contentCache.removeValue(forKey: revision) {
            residentContentBytes -= removed.bytes
        }
        contentCacheOrder.removeAll { $0 == revision }
    }

}

/// How the list's rows divide into part files. A chat's part comes from its ID alone, so a
/// change to one row changes one part. The number of parts only grows, by doubling, and a
/// list that fits one part has one: most people's lists are two files, the root and a part.
enum SessionListParts {
    /// A part holds about this many rows before the parts double.
    static let rowsInAPart = 128
    /// The root names a row's part in one byte.
    static let maximumCount = 256

    static func count(for rows: Int, current: Int) -> Int {
        var count = min(max(current, 1), maximumCount)
        while rows > count * rowsInAPart, count < maximumCount { count = min(count * 2, maximumCount) }
        return count
    }

    /// FNV-1a over the ID's bytes: the same on every launch and device, which `Hasher` is not.
    /// Saved lists depend on it, so it must never change.
    static func part(of id: String, among count: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Int((hash ^ (hash >> 32)) % UInt64(count))
    }

    /// Each part's rows in the list's order, and for each row of the list the part it went to.
    static func divide(_ rows: [SessionRecord], into count: Int) -> (parts: [[SessionRecord]], order: Data) {
        var parts = [[SessionRecord]](repeating: [], count: count)
        var order = Data(capacity: rows.count)
        for row in rows {
            let part = part(of: row.id, among: count)
            parts[part].append(row)
            order.append(UInt8(part))
        }
        return (parts, order)
    }
}
