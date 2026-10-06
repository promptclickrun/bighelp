import CryptoKit
import Foundation

struct HermesSessionStoreStats: Equatable, Sendable {
    let profileID: String
    let total: Int
    let activeStore: Int
    let archived: Int
    let messages: Int
    let bySource: [String: Int]
    let emptyEndedCount: Int
}

struct HermesSessionMaintenanceItem: Identifiable, Equatable, Sendable {
    let id: String
    let profileID: String
    let title: String
    let source: String
    let preview: String
    let startedAt: Date?
    let lastActive: Date?
    let endedAt: Date?
    let messageCount: Int
    let archived: Bool
    let hidden: Bool
    let active: Bool

    func withRuntimeActive(_ active: Bool) -> Self {
        .init(
            id: id, profileID: profileID, title: title, source: source,
            preview: preview, startedAt: startedAt, lastActive: lastActive,
            endedAt: endedAt, messageCount: messageCount, archived: archived,
            hidden: hidden, active: active
        )
    }
}

struct HermesSessionBulkDeleteReview: Equatable, Sendable {
    let profileID: String
    let sessions: [HermesSessionMaintenanceItem]
    fileprivate let canonicalSnapshots: [Data: Data]
}

struct HermesSessionEmptyDeleteReview: Equatable, Sendable {
    let profileID: String
    let count: Int
    let stats: HermesSessionStoreStats
}

struct HermesSessionPruneFilter: Equatable, Sendable {
    var olderThanDays: Double? = 90
    var startedBefore: Date?
    var startedAfter: Date?
    var source: String?
    var titleContains: String?
    var endReason: String?
    var cwdPrefix: String?
    var minimumMessages: Int?
    var maximumMessages: Int?
    var modelContains: String?
    var provider: String?
    var userID: String?
    var chatID: String?
    var chatType: String?
    var branchContains: String?
    var minimumTokens: Int?
    var maximumTokens: Int?
    var minimumCost: Double?
    var maximumCost: Double?
    var minimumToolCalls: Int?
    var maximumToolCalls: Int?
    var includeArchived = false
}

struct HermesSessionPruneReview: Equatable, Sendable {
    let profileID: String
    let filter: HermesSessionPruneFilter
    let sessions: [HermesSessionMaintenanceItem]
    let skippedOpen: Int
    let oldestLastActive: Date?
    let newestLastActive: Date?
    fileprivate let reviewToken: Data
}

struct HermesSessionDeletionResult: Equatable, Sendable {
    let profileID: String
    let deleted: Int
    let verifiedAbsentIDs: [String]
}

struct HermesSessionLineage: Equatable, Sendable {
    let profileID: String
    let requestedSessionID: String
    let latestSessionID: String
    let path: [String]
    let changed: Bool
}

struct HermesSessionMostRecent: Equatable, Sendable {
    let profileID: String
    let storedSessionID: String
    let title: String
    let startedAt: Date?
    let source: String
}

struct HermesSessionMostRecentLookup: Equatable, Sendable {
    let profileID: String
    let session: HermesSessionMostRecent?
}

struct HermesSessionRuntimeCloseRequest: Equatable, Sendable {
    let profileID: String
    let storedSessionID: String
    /// Exact live-process identity returned by `session.active_list`. This is
    /// never obtained by activating or resuming the durable session.
    let runtimeSessionID: String
}

/// Supplied only by the retained parent bridge after it rejects drafts,
/// unresolved submissions, active turns, prompts, and stale ownership.
struct HermesSessionRuntimeCloseTarget: Equatable, Sendable {
    let profileID: String
    let storedSessionID: String
    let runtimeSessionID: String
}

struct HermesSessionCloseResult: Equatable, Sendable {
    let profileID: String
    let storedSessionID: String
    let runtimeSessionID: String
    let closedByRequest: Bool
    let preservedMessageCount: Int
}

struct HermesSessionVisibilityResult: Equatable, Sendable {
    let profileID: String
    let storedSessionID: String
    let hidden: Bool
    let archived: Bool
}

struct HermesSessionOwnerBackfillReview: Equatable, Sendable {
    let profileID: String
    let storeStatistics: HermesSessionStoreStats
}

struct HermesSessionOwnerBackfillResult: Equatable, Sendable {
    let profileID: String
    let reviewedStoreRows: Int
    let stampedRows: Int
    let remainingUnownedRows: Int
}

struct HermesSessionExport: Equatable, Sendable {
    let profileID: String
    let sessionID: String
    let filename: String
    let data: Data
}

struct HermesSessionImportReview: Equatable, Sendable {
    let profileID: String
    let sessionIDs: [String]
    let byteCount: Int
    fileprivate let sessions: [BighelpJSONValue]
    fileprivate let reviewToken: Data
}

struct HermesSessionImportResult: Equatable, Sendable {
    let profileID: String
    let importedIDs: [String]
    let skippedIDs: [String]
    let detached: Int
}

struct HermesForeignSessionItem: Identifiable, Equatable, Sendable {
    let id: String
    let source: String
    let sourceLabel: String
    let title: String
    let cwd: String?
    let modifiedAt: Date?
    let turnCount: Int
    let excerpt: String
}

struct HermesForeignSessionPage: Equatable, Sendable {
    let profileID: String
    let host: String
    let sessions: [HermesForeignSessionItem]
    let nextOffset: Int?
    let unreadable: Int
}

struct HermesForeignSessionPreview: Equatable, Sendable {
    struct Message: Identifiable, Equatable, Sendable {
        let index: Int
        let role: String
        let content: String
        var id: Int { index }
    }

    let profileID: String
    let foreignID: String
    let title: String
    let source: String
    let cwd: String?
    let totalMessages: Int
    let isTruncated: Bool
    let alreadyImportedSessionID: String?
    let messages: [Message]
    fileprivate let reviewToken: Data
}

extension HermesForeignSessionPreview {
    /// Demo mode's preview: made-up messages, nothing to review against a host.
    init(demoTitle: String, source: String, cwd: String?, alreadyImported: String? = nil) {
        self.init(profileID: "default", foreignID: String(repeating: "a", count: 64), title: demoTitle, source: source,
                  cwd: cwd, totalMessages: 2, isTruncated: false, alreadyImportedSessionID: alreadyImported,
                  messages: [.init(index: 0, role: "user", content: "Can you look at this with me?"),
                             .init(index: 1, role: "assistant", content: "Sure. Here's where I'd start.")],
                  reviewToken: Data())
    }
}

struct HermesForeignSessionImportResult: Equatable, Sendable {
    let profileID: String
    let foreignID: String
    let sessionID: String
    let alreadyImported: Bool
}

enum HermesSessionMaintenanceError: Error, Equatable, LocalizedError, Sendable {
    case ownerChanged
    case invalidRequest
    case invalidResponse
    case reviewChanged
    case outcomeUnknown
    case nativeReadbackRequired
    case transferTooLarge
    case confirmedCloseNeedsReconciliation

    var errorDescription: String? {
        switch self {
        case .ownerChanged: "The selected Hermes host changed. Reopen Session Maintenance."
        case .invalidRequest: "This session maintenance request is invalid."
        case .invalidResponse: "Hermes returned an unsupported session maintenance response."
        case .reviewChanged: "The reviewed sessions changed. Refresh the review before continuing."
        case .outcomeUnknown: "Hermes did not confirm the operation. Refresh before trying it again."
        case .nativeReadbackRequired: "This destructive action requires the Direct connection’s exact HTTP readback support."
        case .transferTooLarge: "This session package exceeds the current authenticated native transport limit."
        case .confirmedCloseNeedsReconciliation:
            "Hermes closed the live runtime and preserved its stored history, but bighelp could not retire the old native binding. Refresh Sessions; do not repeat the close operation."
        }
    }
}

@MainActor
protocol HermesSessionMaintenanceManaging: AnyObject {
    var ownsScope: Bool { get }
    func statistics(profileID: String) async throws -> HermesSessionStoreStats
    func sessions(profileID: String) async throws -> [HermesSessionMaintenanceItem]
    func mostRecentSession(profileID: String) async throws -> HermesSessionMostRecentLookup
    func setHidden(profileID: String, sessionID: String, hidden: Bool) async throws -> HermesSessionVisibilityResult
    func closeLiveSession(profileID: String, sessionID: String) async throws -> HermesSessionCloseResult
    func prepareOwnerBackfill(profileID: String) async throws -> HermesSessionOwnerBackfillReview
    func ownerBackfill(reviewed: HermesSessionOwnerBackfillReview) async throws -> HermesSessionOwnerBackfillResult
    func prepareBulkDelete(profileID: String, sessionIDs: [String]) async throws -> HermesSessionBulkDeleteReview
    func deleteBulk(reviewed: HermesSessionBulkDeleteReview) async throws -> HermesSessionDeletionResult
    func prepareEmptyDelete(profileID: String) async throws -> HermesSessionEmptyDeleteReview
    func deleteEmpty(reviewed: HermesSessionEmptyDeleteReview) async throws -> HermesSessionDeletionResult
    func preparePrune(profileID: String, filter: HermesSessionPruneFilter) async throws -> HermesSessionPruneReview
    func prune(reviewed: HermesSessionPruneReview) async throws -> HermesSessionDeletionResult
    func exportSession(profileID: String, sessionID: String) async throws -> HermesSessionExport
    func prepareImport(profileID: String, data: Data) throws -> HermesSessionImportReview
    func importSessions(reviewed: HermesSessionImportReview) async throws -> HermesSessionImportResult
    func latestDescendant(profileID: String, sessionID: String) async throws -> HermesSessionLineage
    func foreignSessions(profileID: String, source: String?, offset: Int, limit: Int) async throws -> HermesForeignSessionPage
    func foreignPreview(profileID: String, item: HermesForeignSessionItem) async throws -> HermesForeignSessionPreview
    func importForeign(reviewed: HermesForeignSessionPreview) async throws -> HermesForeignSessionImportResult
}

/// Fixed, owner-bound session maintenance and portability adapter. It never
/// accepts a caller-supplied route or RPC method. Basic chat/history remains in
/// the existing catalog and conversation clients.
@MainActor
final class DirectHermesSessionMaintenanceClient: HermesSessionMaintenanceManaging {
    typealias ResolveClosableRuntime = @MainActor (
        HermesSessionRuntimeCloseRequest
    ) async throws -> HermesSessionRuntimeCloseTarget
    typealias ReconcileClosedRuntime = @MainActor (
        HermesSessionCloseResult
    ) async throws -> Void

    private static let maximumSessionCount = 10_000
    private static let maximumSelection = 500
    private static let maximumTransferBytes = DirectHermesHTTP.maximumSessionTransferBytes
    private static let maximumPruneReviewBytes = 900 * 1_024

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let resolveClosableRuntime: ResolveClosableRuntime
    private let reconcileClosedRuntime: ReconcileClosedRuntime

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        resolveClosableRuntime: @escaping ResolveClosableRuntime,
        reconcileClosedRuntime: @escaping ReconcileClosedRuntime
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
        self.resolveClosableRuntime = resolveClosableRuntime
        self.reconcileClosedRuntime = reconcileClosedRuntime
    }

    var ownsScope: Bool { owner.authority.kind == .direct && currentOwner() == owner }

    func statistics(profileID: String) async throws -> HermesSessionStoreStats {
        let profile = try Self.profile(profileID)
        let value = try await requestHTTP(.init(
            path: "/api/sessions/stats", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 128 * 1_024
        ))
        guard let row = value.object else { throw HermesSessionMaintenanceError.invalidResponse }
        let bySourceObject = try Self.object(row["by_source"])
        guard bySourceObject.count <= 256 else { throw HermesSessionMaintenanceError.invalidResponse }
        var bySource: [String: Int] = [:]
        for (source, count) in bySourceObject {
            let key = try Self.text(source, maximum: 128, allowEmpty: false)
            guard let number = count.integer, number >= 0 else { throw HermesSessionMaintenanceError.invalidResponse }
            bySource[key] = number
        }
        let empty = try await emptyCount(profileID: profile)
        return .init(
            profileID: profile,
            total: try Self.count(row["total"]),
            activeStore: try Self.count(row["active_store"]),
            archived: try Self.count(row["archived"]),
            messages: try Self.count(row["messages"]),
            bySource: bySource,
            emptyEndedCount: empty
        )
    }

    func sessions(profileID: String) async throws -> [HermesSessionMaintenanceItem] {
        let profile = try Self.profile(profileID)
        var result: [HermesSessionMaintenanceItem] = []
        var offset = 0
        var expectedTotal: Int?
        repeat {
            let value = try await requestHTTP(.init(
                path: "/api/sessions", method: .get,
                query: [
                    .init(name: "profile", value: profile), .init(name: "limit", value: "100"),
                    .init(name: "offset", value: String(offset)), .init(name: "archived", value: "include"),
                    .init(name: "order", value: "recent"), .init(name: "full", value: "false"),
                ], maximumResponseBytes: 512 * 1_024
            ))
            guard let envelope = value.object, let rows = envelope["sessions"]?.array,
                  rows.count <= 100, let total = envelope["total"]?.integer,
                  total >= 0, total <= Self.maximumSessionCount else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            if let expectedTotal, expectedTotal != total { throw HermesSessionMaintenanceError.reviewChanged }
            expectedTotal = total
            result.append(contentsOf: try rows.map { try Self.item($0, profileID: profile) })
            offset += rows.count
            if rows.isEmpty { break }
        } while offset < (expectedTotal ?? 0)

        // REST intentionally omits hidden rows and its total also counts rows the
        // human listing projects away. Discover the supported human-facing hidden
        // set through the exact RPC, then read every missing row from durable HTTP.
        let hiddenCatalog = try await requestRPC("session.list", params: [
            "profile": .string(profile),
            "include_hidden": .boolean(true),
            "limit": .integer(Self.maximumSessionCount),
        ])
        guard let hiddenRows = hiddenCatalog.object?["sessions"]?.array,
              hiddenRows.count <= Self.maximumSessionCount else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        var known = Set(result.map { Data($0.id.utf8) })
        var discovered = Set<Data>()
        for value in hiddenRows {
            guard let rawID = value.object?["id"]?.string else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            let id = try Self.sessionID(rawID)
            let key = Data(id.utf8)
            guard discovered.insert(key).inserted else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            guard !known.contains(key) else { continue }
            let detail = try await sessionDetail(profileID: profile, sessionID: id)
            let item = try Self.item(detail, profileID: profile)
            guard Self.exact(item.id, id), item.hidden else {
                throw HermesSessionMaintenanceError.reviewChanged
            }
            result.append(item)
            known.insert(key)
        }
        guard result.count <= Self.maximumSessionCount,
              result.count <= (expectedTotal ?? 0), known.count == result.count else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        let activeStoredIDs = try await activeStoredSessionIDs(profileID: profile)
        return result.map { item in
            item.withRuntimeActive(activeStoredIDs.contains(Data(item.id.utf8)))
        }.sorted { lhs, rhs in
            let lhsDate = lhs.lastActive ?? lhs.startedAt ?? .distantPast
            let rhsDate = rhs.lastActive ?? rhs.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return Data(lhs.id.utf8).lexicographicallyPrecedes(Data(rhs.id.utf8))
        }
    }

    func mostRecentSession(profileID: String) async throws -> HermesSessionMostRecentLookup {
        let profile = try Self.profile(profileID)
        let value = try await requestRPC("session.most_recent", params: ["profile": .string(profile)])
        guard let row = value.object, let rawID = row["session_id"] else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        guard rawID != .null else { return .init(profileID: profile, session: nil) }
        guard let rawSessionID = rawID.string else { throw HermesSessionMaintenanceError.invalidResponse }
        let sessionID = try Self.sessionID(rawSessionID)
        let durable = try await sessionDetail(profileID: profile, sessionID: sessionID)
        let item = try Self.item(durable, profileID: profile)
        guard Self.exact(item.id, sessionID) else { throw HermesSessionMaintenanceError.invalidResponse }
        return .init(profileID: profile, session: .init(
            profileID: profile,
            storedSessionID: sessionID,
            title: try Self.optionalText(row["title"], maximum: 4_096) ?? item.title,
            startedAt: Self.date(row["started_at"]) ?? item.startedAt,
            source: try Self.optionalText(row["source"], maximum: 128) ?? item.source
        ))
    }

    func setHidden(
        profileID: String,
        sessionID: String,
        hidden: Bool
    ) async throws -> HermesSessionVisibilityResult {
        let profile = try Self.profile(profileID)
        let stored = try Self.sessionID(sessionID)
        let before = try Self.item(
            try await sessionDetail(profileID: profile, sessionID: stored), profileID: profile
        )
        guard Self.exact(before.id, stored) else { throw HermesSessionMaintenanceError.invalidResponse }
        // session.set_hidden is not SessionParams: stock Hermes explicitly accepts
        // a stored ID fallback here. Only session.close receives a runtime ID.
        let value = try await requestRPC("session.set_hidden", params: [
            "profile": .string(profile), "session_id": .string(stored), "hidden": .boolean(hidden),
        ], mutation: true)
        guard let row = value.object, row["hidden"]?.boolean == hidden,
              Self.exact(row["session_key"]?.string, stored) else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let after = try Self.item(
            try await sessionDetail(profileID: profile, sessionID: stored), profileID: profile
        )
        guard Self.exact(after.id, stored), after.hidden == hidden,
              after.archived == before.archived,
              after.messageCount == before.messageCount else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        return .init(
            profileID: profile, storedSessionID: stored,
            hidden: hidden, archived: after.archived
        )
    }

    func closeLiveSession(profileID: String, sessionID: String) async throws -> HermesSessionCloseResult {
        let profile = try Self.profile(profileID)
        let stored = try Self.sessionID(sessionID)
        // `session.active_list` is stock Hermes' authoritative inventory of
        // already-live process objects. Resolve the runtime there so an idle,
        // unmounted chat does not need to be reopened (which would activate or
        // resume it) merely to close it.
        let listedRuntime = try await idleRuntimeSessionID(profileID: profile, storedID: stored)
        let request = HermesSessionRuntimeCloseRequest(
            profileID: profile,
            storedSessionID: stored,
            runtimeSessionID: listedRuntime
        )
        let target = try await resolveClosableRuntime(request)
        try requireOwner()
        let runtime = try Self.sessionID(target.runtimeSessionID)
        guard Self.exact(target.profileID, profile), Self.exact(target.storedSessionID, stored),
              Self.exact(runtime, listedRuntime),
              !Self.exact(runtime, stored) else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let before = try Self.item(
            try await sessionDetail(profileID: profile, sessionID: stored), profileID: profile
        )
        guard Self.exact(before.id, stored),
              try await activeSessionMatches(
                profileID: profile, runtimeID: runtime, storedID: stored, requireIdle: true
              ) else {
            throw HermesSessionMaintenanceError.reviewChanged
        }
        let value = try await requestRPC("session.close", params: [
            "profile": .string(profile), "session_id": .string(runtime),
        ], mutation: true)
        guard let closed = value.object?["closed"]?.boolean else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        guard try await activeSessionMatches(
            profileID: profile, runtimeID: runtime, storedID: stored, requirePair: false
        ) == false else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let after = try Self.item(
            try await sessionDetail(profileID: profile, sessionID: stored), profileID: profile
        )
        guard Self.exact(after.id, stored), after.messageCount == before.messageCount else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let result = HermesSessionCloseResult(
            profileID: profile, storedSessionID: stored, runtimeSessionID: runtime,
            closedByRequest: closed, preservedMessageCount: after.messageCount
        )
        do {
            try await reconcileClosedRuntime(result)
            try requireOwner()
        } catch {
            throw HermesSessionMaintenanceError.confirmedCloseNeedsReconciliation
        }
        return result
    }

    func prepareOwnerBackfill(profileID: String) async throws -> HermesSessionOwnerBackfillReview {
        let profile = try Self.profile(profileID)
        return .init(profileID: profile, storeStatistics: try await statistics(profileID: profile))
    }

    func ownerBackfill(
        reviewed: HermesSessionOwnerBackfillReview
    ) async throws -> HermesSessionOwnerBackfillResult {
        let profile = try Self.profile(reviewed.profileID)
        guard Self.exact(reviewed.storeStatistics.profileID, profile) else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let current = try await statistics(profileID: profile)
        guard current == reviewed.storeStatistics else { throw HermesSessionMaintenanceError.reviewChanged }
        let body: [String: BighelpJSONValue] = ["profile": .string(profile)]
        let value = try await mutateHTTP(.init(
            path: "/api/sessions/owner-backfill", method: .post, body: body,
            maximumResponseBytes: 16 * 1_024
        ))
        guard let row = value.object, row["ok"]?.boolean == true,
              let stamped = row["stamped"]?.integer, stamped >= 0,
              Self.exact(row["profile"]?.string, profile) else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        // The stock route has no dry-run/count read. Its supported authoritative
        // readback is an idempotent second call, which must stamp zero rows.
        let readback = try await mutateHTTP(.init(
            path: "/api/sessions/owner-backfill", method: .post, body: body,
            maximumResponseBytes: 16 * 1_024
        ))
        guard let readbackRow = readback.object, readbackRow["ok"]?.boolean == true,
              readbackRow["stamped"]?.integer == 0,
              Self.exact(readbackRow["profile"]?.string, profile),
              try await statistics(profileID: profile) == reviewed.storeStatistics else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        return .init(
            profileID: profile, reviewedStoreRows: reviewed.storeStatistics.total,
            stampedRows: stamped, remainingUnownedRows: 0
        )
    }

    func prepareBulkDelete(profileID: String, sessionIDs: [String]) async throws -> HermesSessionBulkDeleteReview {
        let profile = try Self.profile(profileID)
        let ids = try Self.sessionIDs(sessionIDs, maximum: Self.maximumSelection)
        guard !ids.isEmpty else { throw HermesSessionMaintenanceError.invalidRequest }
        var rows: [HermesSessionMaintenanceItem] = []
        var snapshots: [Data: Data] = [:]
        for id in ids {
            let value = try await sessionDetail(profileID: profile, sessionID: id)
            let item = try Self.item(value, profileID: profile)
            guard Self.exact(item.id, id) else { throw HermesSessionMaintenanceError.invalidResponse }
            rows.append(item)
            snapshots[Data(id.utf8)] = try Self.canonical(value)
        }
        return .init(profileID: profile, sessions: rows, canonicalSnapshots: snapshots)
    }

    func deleteBulk(reviewed: HermesSessionBulkDeleteReview) async throws -> HermesSessionDeletionResult {
        let profile = try Self.profile(reviewed.profileID)
        guard http is any DirectHermesNativeHTTP else {
            throw HermesSessionMaintenanceError.nativeReadbackRequired
        }
        guard reviewed.sessions.count == reviewed.canonicalSnapshots.count,
              !reviewed.sessions.isEmpty, reviewed.sessions.count <= Self.maximumSelection else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        for item in reviewed.sessions {
            let current = try await sessionDetail(profileID: profile, sessionID: item.id)
            guard reviewed.canonicalSnapshots[Data(item.id.utf8)] == (try Self.canonical(current)) else {
                throw HermesSessionMaintenanceError.reviewChanged
            }
        }
        let value = try await mutateHTTP(.init(
            path: "/api/sessions/bulk-delete", method: .post,
            body: [
                "ids": .array(reviewed.sessions.map { .string($0.id) }),
                "profile": .string(profile),
            ], maximumResponseBytes: 32 * 1_024
        ))
        guard value.object?["ok"]?.boolean == true,
              value.object?["deleted"]?.integer == reviewed.sessions.count else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let ids = reviewed.sessions.map(\.id)
        try await requireAbsent(profileID: profile, sessionIDs: ids)
        return .init(profileID: profile, deleted: ids.count, verifiedAbsentIDs: ids)
    }

    func prepareEmptyDelete(profileID: String) async throws -> HermesSessionEmptyDeleteReview {
        let profile = try Self.profile(profileID)
        let stats = try await statistics(profileID: profile)
        return .init(profileID: profile, count: stats.emptyEndedCount, stats: stats)
    }

    func deleteEmpty(reviewed: HermesSessionEmptyDeleteReview) async throws -> HermesSessionDeletionResult {
        let profile = try Self.profile(reviewed.profileID)
        guard reviewed.count > 0, reviewed.stats.profileID == profile,
              reviewed.stats.emptyEndedCount == reviewed.count else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        guard try await emptyCount(profileID: profile) == reviewed.count else {
            throw HermesSessionMaintenanceError.reviewChanged
        }
        let value = try await mutateHTTP(.init(
            path: "/api/sessions/empty", method: .delete,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 32 * 1_024
        ))
        guard value.object?["ok"]?.boolean == true,
              value.object?["deleted"]?.integer == reviewed.count else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        guard try await emptyCount(profileID: profile) == 0 else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        return .init(profileID: profile, deleted: reviewed.count, verifiedAbsentIDs: [])
    }

    func preparePrune(profileID: String, filter: HermesSessionPruneFilter) async throws -> HermesSessionPruneReview {
        let profile = try Self.profile(profileID)
        let body = try Self.pruneBody(profileID: profile, filter: filter, dryRun: true)
        let value = try await requestHTTP(.init(
            path: "/api/sessions/prune", method: .post, body: body,
            maximumResponseBytes: Self.maximumPruneReviewBytes
        ))
        guard let row = value.object, row["ok"]?.boolean == true,
              row["removed"]?.integer == 0, let rawSessions = row["sessions"]?.array,
              rawSessions.count <= Self.maximumSessionCount,
              row["matched"]?.integer == rawSessions.count else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        let sessions = try rawSessions.map { try Self.item($0, profileID: profile) }
        guard Set(sessions.map { Data($0.id.utf8) }).count == sessions.count else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        return .init(
            profileID: profile, filter: filter, sessions: sessions,
            skippedOpen: try Self.count(row["skipped_open"]),
            oldestLastActive: Self.date(row["oldest_last_active"]),
            newestLastActive: Self.date(row["newest_last_active"]),
            reviewToken: try Self.canonical(value)
        )
    }

    func prune(reviewed: HermesSessionPruneReview) async throws -> HermesSessionDeletionResult {
        guard http is any DirectHermesNativeHTTP else {
            throw HermesSessionMaintenanceError.nativeReadbackRequired
        }
        guard !reviewed.sessions.isEmpty else { throw HermesSessionMaintenanceError.invalidRequest }
        let current = try await preparePrune(profileID: reviewed.profileID, filter: reviewed.filter)
        guard current.reviewToken == reviewed.reviewToken else { throw HermesSessionMaintenanceError.reviewChanged }
        let body = try Self.pruneBody(profileID: reviewed.profileID, filter: reviewed.filter, dryRun: false)
        let value = try await mutateHTTP(.init(
            path: "/api/sessions/prune", method: .post, body: body,
            maximumResponseBytes: 32 * 1_024
        ))
        guard value.object?["ok"]?.boolean == true,
              value.object?["removed"]?.integer == reviewed.sessions.count else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let readback = try await preparePrune(profileID: reviewed.profileID, filter: reviewed.filter)
        let removed = Set(reviewed.sessions.map { Data($0.id.utf8) })
        guard readback.sessions.allSatisfy({ !removed.contains(Data($0.id.utf8)) }) else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let ids = reviewed.sessions.map(\.id)
        try await requireAbsent(profileID: reviewed.profileID, sessionIDs: ids)
        return .init(profileID: reviewed.profileID, deleted: ids.count, verifiedAbsentIDs: ids)
    }

    func exportSession(profileID: String, sessionID: String) async throws -> HermesSessionExport {
        let profile = try Self.profile(profileID)
        let session = try Self.sessionID(sessionID)
        let value: BighelpJSONValue
        do {
            value = try await requestHTTP(.init(
                path: "/api/sessions/\(try Self.pathComponent(session))/export", method: .get,
                query: [.init(name: "profile", value: profile)],
                maximumResponseBytes: Self.maximumTransferBytes
            ))
        } catch DirectHermesError.messageTooLarge {
            throw HermesSessionMaintenanceError.transferTooLarge
        }
        guard let object = value.object, Self.exact(object["id"]?.string, session),
              object["messages"]?.array != nil else { throw HermesSessionMaintenanceError.invalidResponse }
        let wrapper: BighelpJSONValue = .object([
            "schema": .integer(1), "profile": .string(profile), "sessions": .array([value]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(wrapper)
        guard data.count <= Self.maximumTransferBytes else { throw HermesSessionMaintenanceError.transferTooLarge }
        return .init(
            profileID: profile, sessionID: session,
            filename: "hermes-session-\(Self.safeFilename(session)).json", data: data
        )
    }

    func prepareImport(profileID: String, data: Data) throws -> HermesSessionImportReview {
        let profile = try Self.profile(profileID)
        guard !data.isEmpty, data.count <= Self.maximumTransferBytes else {
            throw HermesSessionMaintenanceError.transferTooLarge
        }
        try DirectHermesWire.validateNesting(data)
        let decoded = try JSONDecoder().decode(BighelpJSONValue.self, from: data)
        let sessions: [BighelpJSONValue]
        if let envelope = decoded.object, let values = envelope["sessions"]?.array {
            sessions = values
        } else if decoded.object?["id"]?.string != nil, decoded.object?["messages"]?.array != nil {
            sessions = [decoded]
        } else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        guard !sessions.isEmpty, sessions.count <= 1_000 else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let ids = try sessions.map { value -> String in
            guard let id = value.object?["id"]?.string, value.object?["messages"]?.array != nil else {
                throw HermesSessionMaintenanceError.invalidRequest
            }
            return try Self.sessionID(id)
        }
        guard Set(ids.map { Data($0.utf8) }).count == ids.count else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let canonicalEnvelope: BighelpJSONValue = .object([
            "schema": .integer(1), "profile": .string(profile), "sessions": .array(sessions),
        ])
        return .init(
            profileID: profile, sessionIDs: ids, byteCount: data.count,
            sessions: sessions, reviewToken: Data(SHA256.hash(data: try Self.encoded(canonicalEnvelope)))
        )
    }

    func importSessions(reviewed: HermesSessionImportReview) async throws -> HermesSessionImportResult {
        let profile = try Self.profile(reviewed.profileID)
        guard !reviewed.sessions.isEmpty,
              reviewed.sessionIDs.count == reviewed.sessions.count else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let envelope: BighelpJSONValue = .object([
            "schema": .integer(1), "profile": .string(profile), "sessions": .array(reviewed.sessions),
        ])
        let encoded = try Self.encoded(envelope)
        guard encoded.count <= Self.maximumTransferBytes else {
            throw HermesSessionMaintenanceError.transferTooLarge
        }
        guard Data(SHA256.hash(data: encoded)) == reviewed.reviewToken else {
            throw HermesSessionMaintenanceError.reviewChanged
        }
        let value = try await mutateHTTP(.init(
            path: "/api/sessions/import", method: .post,
            body: ["sessions": .array(reviewed.sessions), "profile": .string(profile)],
            maximumResponseBytes: 128 * 1_024
        ))
        guard let row = value.object, row["ok"]?.boolean == true,
              let imported = row["imported_ids"]?.array,
              let skipped = row["skipped_ids"]?.array,
              let detached = row["detached"]?.integer, detached >= 0 else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let importedIDs = try imported.map { try Self.sessionID(try Self.requiredString($0)) }
        let skippedIDs = try skipped.map { try Self.sessionID(try Self.requiredString($0)) }
        let resultIDs = importedIDs + skippedIDs
        guard Set(resultIDs.map { Data($0.utf8) }).count == resultIDs.count,
              Set(resultIDs) == Set(reviewed.sessionIDs),
              row["imported"]?.integer == importedIDs.count,
              row["skipped"]?.integer == skippedIDs.count else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        for id in importedIDs {
            let detail = try await sessionDetail(profileID: profile, sessionID: id)
            guard Self.exact(detail.object?["id"]?.string, id) else {
                throw HermesSessionMaintenanceError.outcomeUnknown
            }
        }
        return .init(profileID: profile, importedIDs: importedIDs, skippedIDs: skippedIDs, detached: detached)
    }

    func latestDescendant(profileID: String, sessionID: String) async throws -> HermesSessionLineage {
        let profile = try Self.profile(profileID)
        let session = try Self.sessionID(sessionID)
        let value = try await requestHTTP(.init(
            path: "/api/sessions/\(try Self.pathComponent(session))/latest-descendant", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 64 * 1_024
        ))
        guard let row = value.object,
              let requested = row["requested_session_id"]?.string,
              let latest = row["session_id"]?.string,
              let rawPath = row["path"]?.array,
              rawPath.count <= 1_000,
              let changed = row["changed"]?.boolean else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        let path = try rawPath.map { try Self.sessionID(try Self.requiredString($0)) }
        guard Self.exact(requested, session), path.first.map({ Self.exact($0, requested) }) ?? false,
              path.last.map({ Self.exact($0, latest) }) ?? false,
              changed == !Self.exact(requested, latest) else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        return .init(
            profileID: profile, requestedSessionID: requested,
            latestSessionID: try Self.sessionID(latest), path: path, changed: changed
        )
    }

    func foreignSessions(
        profileID: String,
        source: String? = nil,
        offset: Int = 0,
        limit: Int = 25
    ) async throws -> HermesForeignSessionPage {
        let profile = try Self.profile(profileID)
        guard offset >= 0, (1...50).contains(limit) else { throw HermesSessionMaintenanceError.invalidRequest }
        var params: [String: BighelpJSONValue] = [
            "profile": .string(profile), "offset": .integer(offset), "limit": .integer(limit),
        ]
        if let source {
            params["source"] = .string(try Self.text(source, maximum: 64, allowEmpty: false))
        }
        let value = try await requestRPC("session.foreign.list", params: params)
        guard let row = value.object, let rawSessions = row["sessions"]?.array,
              rawSessions.count <= limit, let host = row["host"]?.string,
              let unreadable = row["unreadable"]?.integer, unreadable >= 0 else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        var seen = Set<Data>()
        let sessions = try rawSessions.map { value -> HermesForeignSessionItem in
            guard let item = value.object,
                  let id = item["id"]?.string, Self.isForeignHandle(id), seen.insert(Data(id.utf8)).inserted,
                  let source = item["source"]?.string,
                  let label = item["label"]?.string,
                  let title = item["title"]?.string,
                  let turns = item["turn_count"]?.integer, turns > 0,
                  let excerpt = item["excerpt"]?.string else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            return .init(
                id: id,
                source: try Self.text(source, maximum: 64, allowEmpty: false),
                sourceLabel: try Self.text(label, maximum: 128, allowEmpty: false),
                title: try Self.text(title, maximum: 1_024, allowEmpty: false),
                cwd: try Self.optionalText(item["cwd"], maximum: 4_096),
                modifiedAt: Self.date(item["mtime"]), turnCount: turns,
                excerpt: try Self.text(excerpt, maximum: 1_024)
            )
        }
        let nextOffset: Int?
        if row["next_offset"] == nil || row["next_offset"] == .null { nextOffset = nil }
        else if let value = row["next_offset"]?.integer, value > offset { nextOffset = value }
        else { throw HermesSessionMaintenanceError.invalidResponse }
        return .init(
            profileID: profile, host: try Self.text(host, maximum: 512, allowEmpty: false),
            sessions: sessions, nextOffset: nextOffset, unreadable: unreadable
        )
    }

    func foreignPreview(
        profileID: String,
        item: HermesForeignSessionItem
    ) async throws -> HermesForeignSessionPreview {
        let profile = try Self.profile(profileID)
        guard Self.isForeignHandle(item.id) else { throw HermesSessionMaintenanceError.invalidRequest }
        let value = try await requestRPC("session.foreign.preview", params: [
            "profile": .string(profile), "id": .string(item.id),
        ])
        guard let row = value.object, let rawMessages = row["messages"]?.array,
              rawMessages.count <= 40, let total = row["total"]?.integer, total >= rawMessages.count,
              let truncated = row["truncated"]?.boolean else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        let messages = try rawMessages.enumerated().map { index, value -> HermesForeignSessionPreview.Message in
            guard let message = value.object, let role = message["role"]?.string,
                  let content = message["content"]?.string else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            return .init(
                index: index, role: try Self.text(role, maximum: 64, allowEmpty: false),
                content: try Self.text(content, maximum: 64_000)
            )
        }
        let imported = try Self.optionalText(row["already_imported"], maximum: 512)
        if let imported { _ = try Self.sessionID(imported) }
        return .init(
            profileID: profile, foreignID: item.id, title: item.title, source: item.source,
            cwd: try Self.optionalText(row["cwd"], maximum: 4_096),
            totalMessages: total, isTruncated: truncated,
            alreadyImportedSessionID: imported, messages: messages,
            reviewToken: try Self.canonical(value)
        )
    }

    func importForeign(reviewed: HermesForeignSessionPreview) async throws -> HermesForeignSessionImportResult {
        let profile = try Self.profile(reviewed.profileID)
        guard Self.isForeignHandle(reviewed.foreignID), reviewed.alreadyImportedSessionID == nil else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        let value = try await requestRPC("session.foreign.preview", params: [
            "profile": .string(profile), "id": .string(reviewed.foreignID),
        ])
        guard try Self.canonical(value) == reviewed.reviewToken else {
            throw HermesSessionMaintenanceError.reviewChanged
        }
        let result: BighelpJSONValue
        do {
            result = try await requestRPC("session.foreign.import", params: [
                "profile": .string(profile), "id": .string(reviewed.foreignID),
            ], mutation: true)
        } catch {
            try requireOwner()
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        guard let row = result.object, let rawID = row["session_id"]?.string else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let sessionID = try Self.sessionID(rawID)
        let alreadyImported = row["already_imported"]?.boolean ?? false
        let readback = try await requestRPC("session.foreign.preview", params: [
            "profile": .string(profile), "id": .string(reviewed.foreignID),
        ])
        guard Self.exact(readback.object?["already_imported"]?.string, sessionID) else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        let detail = try await sessionDetail(profileID: profile, sessionID: sessionID)
        guard Self.exact(detail.object?["id"]?.string, sessionID) else {
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
        return .init(
            profileID: profile, foreignID: reviewed.foreignID,
            sessionID: sessionID, alreadyImported: alreadyImported
        )
    }

    private func emptyCount(profileID: String) async throws -> Int {
        let value = try await requestHTTP(.init(
            path: "/api/sessions/empty/count", method: .get,
            query: [.init(name: "profile", value: profileID)], maximumResponseBytes: 16 * 1_024
        ))
        return try Self.count(value.object?["count"])
    }

    private func activeSessionMatches(
        profileID: String,
        runtimeID: String,
        storedID: String,
        requirePair: Bool = true,
        requireIdle: Bool = false
    ) async throws -> Bool {
        let value = try await requestRPC("session.active_list", params: ["profile": .string(profileID)])
        guard let rows = value.object?["sessions"]?.array,
              rows.count <= Self.maximumSessionCount else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        var runtimeMatches = 0
        var exactPairs = 0
        var idleExactPairs = 0
        for value in rows {
            guard let row = value.object, let rawRuntime = row["id"]?.string,
                  let rawStored = row["session_key"]?.string,
                  let status = row["status"]?.string else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            guard ["idle", "starting", "waiting", "working", "streaming", "resuming"].contains(status) else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            let listedRuntime = try Self.sessionID(rawRuntime)
            let listedStored = try Self.sessionID(rawStored)
            if Self.exact(listedRuntime, runtimeID) {
                runtimeMatches += 1
                if Self.exact(listedStored, storedID) {
                    exactPairs += 1
                    if status == "idle" { idleExactPairs += 1 }
                }
            }
        }
        guard runtimeMatches <= 1, exactPairs <= 1 else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        if requirePair {
            return exactPairs == 1 && (!requireIdle || idleExactPairs == 1)
        }
        return runtimeMatches == 1
    }

    /// Returns one exact idle runtime/stored pair from the live-process list.
    /// The stock list is not a durable-session browser and does not create,
    /// activate, or resume a runtime.
    private func idleRuntimeSessionID(profileID: String, storedID: String) async throws -> String {
        let value = try await requestRPC("session.active_list", params: ["profile": .string(profileID)])
        guard let rows = value.object?["sessions"]?.array,
              rows.count <= Self.maximumSessionCount else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        var runtimeIDs = Set<Data>()
        var storedIDs = Set<Data>()
        var matches: [(runtimeID: String, status: String)] = []
        for value in rows {
            guard let row = value.object, let rawRuntime = row["id"]?.string,
                  let rawStored = row["session_key"]?.string,
                  let status = row["status"]?.string,
                  ["idle", "starting", "waiting", "working", "streaming", "resuming"].contains(status) else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            let runtime = try Self.sessionID(rawRuntime)
            let stored = try Self.sessionID(rawStored)
            guard runtimeIDs.insert(Data(runtime.utf8)).inserted,
                  storedIDs.insert(Data(stored.utf8)).inserted else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            if Self.exact(stored, storedID) {
                matches.append((runtime, status))
            }
        }
        guard matches.count == 1, let match = matches.first,
              match.status == "idle", !Self.exact(match.runtimeID, storedID) else {
            throw HermesSessionMaintenanceError.reviewChanged
        }
        return match.runtimeID
    }

    private func activeStoredSessionIDs(profileID: String) async throws -> Set<Data> {
        let value = try await requestRPC("session.active_list", params: ["profile": .string(profileID)])
        guard let rows = value.object?["sessions"]?.array,
              rows.count <= Self.maximumSessionCount else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        var result = Set<Data>()
        for value in rows {
            guard let rawStored = value.object?["session_key"]?.string else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
            let stored = try Self.sessionID(rawStored)
            guard result.insert(Data(stored.utf8)).inserted else {
                throw HermesSessionMaintenanceError.invalidResponse
            }
        }
        return result
    }

    private func sessionDetail(profileID: String, sessionID: String) async throws -> BighelpJSONValue {
        let id = try Self.sessionID(sessionID)
        return try await requestHTTP(.init(
            path: "/api/sessions/\(try Self.pathComponent(id))", method: .get,
            query: [.init(name: "profile", value: profileID)], maximumResponseBytes: 512 * 1_024
        ))
    }

    private func requireAbsent(profileID: String, sessionIDs: [String]) async throws {
        guard let native = http as? any DirectHermesNativeHTTP else {
            throw HermesSessionMaintenanceError.nativeReadbackRequired
        }
        for id in sessionIDs {
            try requireOwner()
            let response = try await native.nativeResponse(.init(
                path: "/api/sessions/\(try Self.pathComponent(id))", method: .get,
                query: [.init(name: "profile", value: profileID)], maximumResponseBytes: 64 * 1_024
            ), requestGuard: nil)
            try requireOwner()
            guard response.http.statusCode == 404 else {
                throw HermesSessionMaintenanceError.outcomeUnknown
            }
        }
    }

    private func requestHTTP(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: requireOwner) {
            try await http.request(request)
        }
    }

    private func mutateHTTP(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        do { return try await requestHTTP(request) }
        catch {
            try requireOwner()
            throw HermesSessionMaintenanceError.outcomeUnknown
        }
    }

    private func requestRPC(
        _ method: String,
        params: [String: BighelpJSONValue],
        mutation: Bool = false
    ) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: requireOwner,
            mapError: { mutation ? HermesSessionMaintenanceError.outcomeUnknown : $0 }) {
            try await rpc.request(method, params: params)
        }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard ownsScope else { throw HermesSessionMaintenanceError.ownerChanged }
    }

    private static func item(_ value: BighelpJSONValue, profileID: String) throws -> HermesSessionMaintenanceItem {
        guard let row = value.object, let rawID = row["id"]?.string else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        let id = try sessionID(rawID)
        if let responseProfile = try optionalText(row["profile"], maximum: 128),
           !exact(responseProfile, profileID) {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        let title = try optionalText(row["title"], maximum: 4_096) ?? "Untitled session"
        let source = try optionalText(row["source"], maximum: 128) ?? "unknown"
        let endedAt = date(row["ended_at"])
        return .init(
            id: id, profileID: profileID, title: title, source: source,
            preview: try optionalText(row["preview"], maximum: 8_192) ?? "",
            startedAt: date(row["started_at"]), lastActive: date(row["last_active"]),
            endedAt: endedAt, messageCount: try optionalCount(row["message_count"]) ?? 0,
            archived: try flag(row["archived"], fallback: false),
            hidden: try flag(row["hidden"], fallback: false),
            active: try flag(row["is_active"], fallback: endedAt == nil)
        )
    }

    private static func pruneBody(
        profileID: String,
        filter: HermesSessionPruneFilter,
        dryRun: Bool
    ) throws -> [String: BighelpJSONValue] {
        if let value = filter.olderThanDays, (!value.isFinite || value < 1 || value > 365_000) {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        var body: [String: BighelpJSONValue] = [
            "profile": .string(try profile(profileID)),
            "include_archived": .boolean(filter.includeArchived),
            "dry_run": .boolean(dryRun),
        ]
        body["older_than_days"] = filter.olderThanDays.map(BighelpJSONValue.number) ?? .null
        let dates: [(String, Date?)] = [("started_before", filter.startedBefore), ("started_after", filter.startedAfter)]
        for (key, value) in dates { if let value { body[key] = .number(value.timeIntervalSince1970) } }
        let strings: [(String, String?)] = [
            ("source", filter.source), ("title_like", filter.titleContains),
            ("end_reason", filter.endReason), ("cwd_prefix", filter.cwdPrefix),
            ("model_like", filter.modelContains), ("provider", filter.provider),
            ("user_id", filter.userID), ("chat_id", filter.chatID),
            ("chat_type", filter.chatType), ("branch_like", filter.branchContains),
        ]
        for (key, value) in strings {
            if let value { body[key] = .string(try text(value, maximum: 4_096, allowEmpty: false)) }
        }
        let integers: [(String, Int?)] = [
            ("min_messages", filter.minimumMessages), ("max_messages", filter.maximumMessages),
            ("min_tokens", filter.minimumTokens), ("max_tokens", filter.maximumTokens),
            ("min_tool_calls", filter.minimumToolCalls), ("max_tool_calls", filter.maximumToolCalls),
        ]
        for (key, value) in integers {
            if let value {
                guard value >= 0 else { throw HermesSessionMaintenanceError.invalidRequest }
                body[key] = .integer(value)
            }
        }
        let numbers: [(String, Double?)] = [
            ("min_cost", filter.minimumCost), ("max_cost", filter.maximumCost),
        ]
        for (key, value) in numbers {
            if let value {
                guard value.isFinite, value >= 0 else { throw HermesSessionMaintenanceError.invalidRequest }
                body[key] = .number(value)
            }
        }
        return body
    }

    private static func profile(_ value: String) throws -> String {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: 128)
        guard value != "all", value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains(where: \.isWhitespace) else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        return value
    }

    private static func sessionIDs(_ values: [String], maximum: Int) throws -> [String] {
        guard values.count <= maximum else { throw HermesSessionMaintenanceError.invalidRequest }
        let ids = try values.map(sessionID)
        guard Set(ids.map { Data($0.utf8) }).count == ids.count else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        return ids
    }

    private static func sessionID(_ value: String) throws -> String {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: 512)
        guard value != ".", value != "..", !value.contains("/"), !value.contains("\\") else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        return value
    }

    private static func pathComponent(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty, !encoded.contains("/") else {
            throw HermesSessionMaintenanceError.invalidRequest
        }
        return encoded
    }

    private static func text(_ value: String, maximum: Int, allowEmpty: Bool = true) throws -> String {
        guard value.utf8.count <= maximum, allowEmpty || !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw HermesSessionMaintenanceError.invalidResponse
        }
        return value
    }

    private static func optionalText(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let string = value.string else { throw HermesSessionMaintenanceError.invalidResponse }
        return try text(string, maximum: maximum)
    }

    private static func requiredString(_ value: BighelpJSONValue) throws -> String {
        guard let string = value.string else { throw HermesSessionMaintenanceError.invalidResponse }
        return string
    }

    private static func object(_ value: BighelpJSONValue?) throws -> [String: BighelpJSONValue] {
        guard let value, value != .null else { return [:] }
        guard let object = value.object else { throw HermesSessionMaintenanceError.invalidResponse }
        return object
    }

    private static func count(_ value: BighelpJSONValue?) throws -> Int {
        guard let count = value?.integer, count >= 0 else { throw HermesSessionMaintenanceError.invalidResponse }
        return count
    }

    private static func optionalCount(_ value: BighelpJSONValue?) throws -> Int? {
        guard let value, value != .null else { return nil }
        return try count(value)
    }

    private static func flag(_ value: BighelpJSONValue?, fallback: Bool) throws -> Bool {
        guard let value, value != .null else { return fallback }
        if let flag = value.boolean { return flag }
        if value.integer == 0 { return false }
        if value.integer == 1 { return true }
        throw HermesSessionMaintenanceError.invalidResponse
    }

    private static func date(_ value: BighelpJSONValue?) -> Date? {
        guard let number = value?.number, number.isFinite, number >= 0 else { return nil }
        return Date(timeIntervalSince1970: number)
    }

    private static func canonical(_ value: BighelpJSONValue) throws -> Data {
        Data(SHA256.hash(data: try encoded(value)))
    }

    private static func encoded(_ value: BighelpJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func exact(_ lhs: String?, _ rhs: String) -> Bool {
        lhs?.utf8.elementsEqual(rhs.utf8) == true
    }

    private static func isForeignHandle(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let bytes = value.utf8.prefix(80).map { byte -> UInt8 in
            if (48...57).contains(byte) || (65...90).contains(byte) ||
                (97...122).contains(byte) || byte == 45 || byte == 95 { return byte }
            return 45
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .nonEmpty ?? "session"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
