import Foundation

/// Keeps legacy repository injection and the throwing canonical-send checkpoint
/// intact while allowing production to prepare only changed session payloads.
@MainActor
protocol SessionCatalogRepository: AnyObject {
    var supportsContentCompaction: Bool { get }
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
/// All files remain beneath DemoRepository's existing host directory, which the
/// account data eraser already removes. Legacy snapshots are never deleted here.
@MainActor
final class SessionContentRepository: SessionCatalogRepository {
    var supportsContentCompaction: Bool { true }
    private struct Manifest: Codable, Sendable {
        var revision: UUID?
        var records: [SessionRecord] = []
    }

    /// The manifest's revision alone. Committing checks the file is still the one the plan was
    /// made from; decoding its thousands of rows for that took the main actor for most of a save.
    private struct ManifestRevision: Codable, Sendable {
        var revision: UUID?
    }

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
        let content: [UUID: Content]

        func encoded() throws -> PreparedSave {
            let writes = try content.map { revision, value in
                EncodedWrite(revision: revision,
                             data: try DemoRepository<Content>.prepareEncoding(value, schemaVersion: schemaVersion))
            }
            return try PreparedSave(
                scope: scope, epoch: epoch, baseRevision: baseRevision,
                manifest: DemoRepository<Manifest>.prepareEncoding(manifest, schemaVersion: schemaVersion), writes: writes
            )
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
        let manifest: DemoRepositoryPreparedEncoding
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

    private struct PreparedCheckpoint {
        let id: UUID
        let plan: Plan
        let encoded: PreparedSave
    }

    private let legacy: DemoRepository<[SessionRecord]>
    private let manifestRepository: DemoRepository<Manifest>
    private let manifestRevisionRepository: DemoRepository<ManifestRevision>
    private let name: String
    private let seed: [SessionRecord]
    private var scope: String?
    private var epoch = UUID()
    private var manifest: Manifest?
    /// Only payloads explicitly loaded or changed in this process are retained.
    private var contentCache: [UUID: ResidentContent] = [:]
    private var contentCacheOrder: [UUID] = []
    private let maximumResidentContentEntries: Int
    private let maximumResidentContentBytes: Int
    private var residentContentBytes = 0
    private var preparedCheckpoint: PreparedCheckpoint?
    private(set) var contentWriteCount = 0
    private(set) var contentLoadCount = 0
    var residentContentCount: Int { contentCache.count }
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
        self.name = name
        self.seed = seed
        manifestRepository = legacy.child(name: "\(name)-catalog", seed: Manifest())
        manifestRevisionRepository = legacy.child(name: "\(name)-catalog", seed: ManifestRevision())
        self.maximumResidentContentEntries = maximumResidentContentEntries
        self.maximumResidentContentBytes = maximumResidentContentBytes
    }

    func resetForAccountBoundary() {
        scope = nil
        epoch = UUID()
        manifest = nil
        contentCache.removeAll()
        contentCacheOrder.removeAll()
        residentContentBytes = 0
        preparedCheckpoint = nil
    }

    func load() throws -> [SessionRecord] {
        try selectScope()
        // Read the manifest even if cached: another repository instance or the
        // account eraser may have changed durable state since our last load.
        manifest = nil
        try ensureManifest()
        let retained = Set((manifest?.records ?? []).compactMap(\.localContentRevision))
        retainResidentContent(revisions: retained)
        return manifest?.records ?? []
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
        if let cached = residentContent(revision) {
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
        let currentRevision = try manifestRevisionRepository.loadExistingPreservingSource()?.revision
        guard currentRevision == prepared.baseRevision else {
            throw SessionContentRepositoryError.staleCheckpoint
        }
        let currentRecords: [SessionRecord]
        if let manifest, manifest.revision == currentRevision {
            currentRecords = manifest.records
        } else {
            currentRecords = try manifestRepository.loadExistingPreservingSource()?.records ?? []
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
        try manifestRepository.savePreparedEncoding(prepared.manifest)
        // Publish the new base only after durable adoption. A thrown write must
        // not poison change detection or a retry's original revision guard.
        manifest = candidate
        preparedCheckpoint = nil
        let encodedByteCounts = Dictionary(uniqueKeysWithValues: prepared.writes.map {
            ($0.revision, $0.data.byteCount)
        })
        for (revision, value) in plan.content {
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
        if let saved = try manifestRepository.loadExistingPreservingSource() {
            try validate(saved)
            manifest = saved
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
            contentCache.removeAll()
            contentCacheOrder.removeAll()
            residentContentBytes = 0
        } catch {
            manifest = nil
            contentCache.removeAll()
            contentCacheOrder.removeAll()
            residentContentBytes = 0
            throw error
        }
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
            if let old = existing[record.id]?.localContentRevision,
               let cached = residentContent(old), cached == payload {
                revision = old
            } else {
                revision = UUID()
                content[revision] = payload
            }
            var row = record
            row.localContentRevision = revision
            row.localContentScope = scope
            row.catalogPreview = String(record.summary.preview.prefix(512))
            row.hasDeferredReferenceState = record.referenceState != nil
                || ReferenceCodec.decode(record.draft).hasValidAppendix
            row.draft = ""
            row.referenceState = nil
            row.items = []
            row.botModePrivateHistory = []
            row.activityEvents = []
            return row
        }
        return Plan(schemaVersion: legacy.currentSchemaVersion, scope: scope, epoch: epoch, baseRevision: manifest.revision,
                    manifest: Manifest(revision: UUID(), records: metadata), content: content)
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
