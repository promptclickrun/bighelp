import Foundation

struct DirectHermesSessionStatus: Equatable, Sendable {
    let output: String
}

struct DirectHermesSessionUsage: Equatable, Sendable {
    let model: String
    let input: Int
    let output: Int
    let reasoning: Int
    let prompt: Int
    let completion: Int
    let total: Int
    let calls: Int
    let compressions: Int?
    let contextUsed: Int?
    let contextMax: Int?
    let contextPercent: Int?
    let contextSource: String?
    let contextEstimated: Bool?
    let cacheHitPercent: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let averageLatencySeconds: Double?
    let averageTokensPerSecond: Double?
    let activeSubagents: Int?
    let developerCreditsSpentMicros: Int?
    let costUSD: Double?
    let costStatus: String?
    let creditLines: [String]?
}

struct DirectHermesContextBreakdown: Equatable, Sendable {
    struct Category: Equatable, Sendable {
        let id: String
        let label: String
        let tokens: Int
        /// Host presentation hint retained for parity. Native UI uses semantic colors.
        let color: String
    }

    let categories: [Category]
    let contextMax: Int
    let contextPercent: Int
    let contextUsed: Int
    let estimatedTotal: Int
    let contextEstimated: Bool
    let contextSource: String
    let model: String
}

extension DirectHermesContextBreakdown {
    /// The most rows the Context page lists.
    static let maximumCategories = 256

    /// Hermes' `session.context_breakdown` answer, read leniently: Hermes adds to it over time
    /// (0.23 sends `context_files` for a live chat, and the page refused the whole answer as
    /// "Context didn't load", #947). A part the app doesn't know is left alone, a row it can't
    /// read hides only itself, and a missing total is worked out from what is there.
    init(hermes value: BighelpJSONValue) throws {
        guard let object = value.object else { throw DirectHermesError.invalidResponse }
        func count(_ key: String, in row: [String: BighelpJSONValue]) -> Int? {
            guard let value = row[key]?.integer, value >= 0 else { return nil }
            return value
        }
        let categories = (object["categories"]?.array ?? []).prefix(Self.maximumCategories)
            .compactMap { value -> Category? in
                guard let row = value.object, let id = row["id"]?.string, !id.isEmpty,
                      let tokens = count("tokens", in: row) else { return nil }
                return Category(id: id, label: row["label"]?.string ?? id, tokens: tokens,
                                color: row["color"]?.string ?? "")
            }
        let maximum = count("context_max", in: object) ?? 0
        let used = count("context_used", in: object) ?? 0
        self.init(categories: categories, contextMax: maximum,
                  contextPercent: count("context_percent", in: object)
                      ?? (maximum > 0 ? min(100, Int((Double(used) / Double(maximum) * 100).rounded())) : 0),
                  contextUsed: used,
                  estimatedTotal: count("estimated_total", in: object) ?? categories.reduce(0) { $0 + $1.tokens },
                  contextEstimated: object["context_estimated"]?.boolean ?? false,
                  contextSource: object["context_source"]?.string ?? "",
                  model: object["model"]?.string ?? "")
    }
}

struct DirectHermesSessionHistory: Equatable, Sendable {
    let count: Int
    let messages: [BighelpJSONValue]
}

struct DirectHermesSessionMutationReadback: Equatable, Sendable {
    let status: DirectHermesSessionStatus
    let history: DirectHermesSessionHistory?
}

struct DirectHermesCompressionResult: Equatable, Sendable {
    let status: String?
    let removed: Int?
    let beforeMessages: Int?
    let afterMessages: Int?
    let beforeTokens: Int?
    let afterTokens: Int?
    let compressed: Bool?
    let message: String?
    /// Nil means the mutation was acknowledged but its independent readback failed.
    let readback: DirectHermesSessionMutationReadback?
}

struct DirectHermesUndoResult: Equatable, Sendable {
    let removed: Int
    let readback: DirectHermesSessionMutationReadback?
}

struct DirectHermesSaveResult: Equatable, Sendable {
    let file: String?
    let readback: DirectHermesSessionMutationReadback?
}

struct DirectHermesWorkingDirectoryResult: Equatable, Sendable {
    let workingDirectory: String
    let readback: DirectHermesSessionMutationReadback?
}

struct DirectHermesSkillReloadChange: Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    var id: String { name }
}

struct DirectHermesSkillsReloadResult: Equatable, Sendable {
    let output: String
    let added: [DirectHermesSkillReloadChange]
    let removed: [DirectHermesSkillReloadChange]
    let unchanged: [String]
    let total: Int
    let commands: Int
}

enum DirectHermesToolConfigurationAction: String, Equatable, Sendable {
    case enable
    case disable
}

struct DirectHermesToolset: Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let toolCount: Int
    let enabled: Bool
    var id: String { name }
}

struct DirectHermesToolsetsSnapshot: Equatable, Sendable {
    let toolsets: [DirectHermesToolset]
}

struct DirectHermesToolsConfigurationResult: Equatable, Sendable {
    let changed: [String]
    let configuredEnabledToolsets: [String]
    let missingServers: [String]
    let reset: Bool
    let unknown: [String]
    let returnedSessionInfo: Bool
    /// Nil means tools.configure was acknowledged but the independent live
    /// session toolsets.list readback did not complete on this connection.
    let readback: DirectHermesToolsetsSnapshot?
}

enum DirectHermesCorrectionStatus: String, Equatable, Sendable {
    case queued
    case redirected
    case rejected
}

struct DirectHermesRedirectResult: Equatable, Sendable {
    let status: DirectHermesCorrectionStatus
    let text: String
}

struct DirectHermesSessionControlComponent: Equatable, Sendable {
    let fields: [String: BighelpJSONValue]
}

struct DirectHermesSessionControlSnapshot: Equatable, Sendable {
    let goal: DirectHermesSessionControlComponent?
    let loop: DirectHermesSessionControlComponent?
    let heartbeat: DirectHermesSessionControlComponent?
    let revision: String
    let updatedAt: Double

    init(object: [String: BighelpJSONValue]) throws {
        guard Set(object.keys) == ["goal", "loop", "heartbeat", "revision", "updated_at"],
              let revision = object["revision"]?.string,
              let updatedAt = object["updated_at"]?.number, updatedAt.isFinite else {
            throw DirectHermesError.invalidResponse
        }
        func component(_ key: String) throws -> DirectHermesSessionControlComponent? {
            guard let value = object[key] else { throw DirectHermesError.invalidResponse }
            if value == .null { return nil }
            guard let fields = value.object else { throw DirectHermesError.invalidResponse }
            return DirectHermesSessionControlComponent(fields: fields)
        }
        goal = try component("goal")
        loop = try component("loop")
        heartbeat = try component("heartbeat")
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

enum DirectHermesSessionControlContinuation: Equatable, Sendable {
    case notRequired
    case accepted
    case rejected
    case outcomeUnknown

    var label: String {
        switch self {
        case .notRequired: "Not required"
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case .outcomeUnknown: "Outcome unknown — do not repeat"
        }
    }
}

struct DirectHermesSessionControlDispatch: Equatable, Sendable {
    let type: String?
    let output: String?
    let notice: String?
    let message: String?
    let display: String?
    let continuation: DirectHermesSessionControlContinuation
}

struct DirectHermesSessionControlResult: Equatable, Sendable {
    let control: DirectHermesSessionControlSnapshot
    let dispatch: DirectHermesSessionControlDispatch
    let continuation: DirectHermesSessionControlContinuation
}

enum DirectHermesSessionControlAction: Equatable, Sendable {
    case goalPause
    case goalResume
    case goalClear
    case goalUnwait
    case loopPause
    case loopResume
    case loopStop
    case subgoalAdd(String)
    case subgoalRemove(Int)
    case subgoalClear
    case heartbeatPause
    case heartbeatResume
    case heartbeatClear

    fileprivate var wireName: String {
        switch self {
        case .goalPause: "goal.pause"
        case .goalResume: "goal.resume"
        case .goalClear: "goal.clear"
        case .goalUnwait: "goal.unwait"
        case .loopPause: "loop.pause"
        case .loopResume: "loop.resume"
        case .loopStop: "loop.stop"
        case .subgoalAdd: "subgoal.add"
        case .subgoalRemove: "subgoal.remove"
        case .subgoalClear: "subgoal.clear"
        case .heartbeatPause: "heartbeat.pause"
        case .heartbeatResume: "heartbeat.resume"
        case .heartbeatClear: "heartbeat.clear"
        }
    }

    fileprivate var arguments: [String: BighelpJSONValue]? {
        switch self {
        case .subgoalAdd(let text): ["text": .string(text)]
        case .subgoalRemove(let index): ["index": .integer(index)]
        default: nil
        }
    }
}

struct DirectHermesRollbackCheckpoint: Identifiable, Equatable, Sendable {
    let hash: String
    let timestamp: String
    let message: String
    var id: String { hash }
}

struct DirectHermesRollbackList: Equatable, Sendable {
    let enabled: Bool
    let checkpoints: [DirectHermesRollbackCheckpoint]
}

struct DirectHermesRollbackDiff: Equatable, Sendable {
    let stat: String
    let diff: String
    let rendered: String?
}

struct DirectHermesRollbackRestoreResult: Equatable, Sendable {
    let success: Bool
    let restoredTo: String?
    let reason: String?
    let directory: String?
    let file: String?
    let restoredFiles: [String]?
    let skippedUserEdits: [String]?
    let skippedOversize: [String]?
    let failedDeletes: [String]?
    let historyRemoved: Int?
    let error: String?
    let readback: DirectHermesSessionMutationReadback?
}

struct DirectHermesActiveDelegation: Identifiable, Equatable, Sendable {
    let id: String
    let parentID: String?
    let childSessionID: String?
    let delegationID: String?
    let depth: Int?
    let goal: String?
    let model: String?
    let status: String?
}

struct DirectHermesDelegationStatus: Equatable, Sendable {
    let active: [DirectHermesActiveDelegation]
    let paused: Bool
    let maxSpawnDepth: Int
    let maxConcurrentChildren: Int
}

struct DirectHermesSpawnTreeEntry: Identifiable, Equatable, Sendable {
    let path: String
    let sessionID: String?
    let startedAt: Double?
    let finishedAt: Double?
    let label: String
    let count: Int
    var id: String { path }
}

struct DirectHermesSpawnTreeSnapshot: Equatable, Sendable {
    let sessionID: String?
    let startedAt: Double?
    let finishedAt: Double?
    let label: String?
    let subagents: [[String: BighelpJSONValue]]
}

struct DirectHermesSpawnTreeSaveResult: Equatable, Sendable {
    let path: String
    let sessionID: String
}

struct DirectHermesVerificationEvidence: Equatable, Sendable {
    let id: Int?
    let createdAt: String?
    let sessionID: String?
    let workingDirectory: String?
    let root: String?
    let command: String?
    let canonicalCommand: String?
    let kind: String?
    let scope: String?
    let status: String?
    let exitCode: Int?
    let outputSummary: String?
}

struct DirectHermesVerificationStatus: Equatable, Sendable {
    let status: String
    let evidence: DirectHermesVerificationEvidence?
    let root: String?
    let sessionID: String?
    let changedPaths: [String]?
}

struct DirectHermesSideTaskReceipt: Equatable, Sendable {
    let taskID: String
}

enum DirectHermesReactionTarget: Equatable, Sendable {
    case row(Int)
    case newest(role: DirectHermesReactionRole)
}

enum DirectHermesReactionRole: String, Equatable, Sendable {
    case user
    case assistant
}

enum DirectHermesReactionAuthor: String, Equatable, Sendable {
    case user
    case agent
}

struct DirectHermesMessageReactionResult: Equatable, Sendable {
    let rowID: Int
    let reactions: [DirectHermesMessageReaction.Reaction]
}

@MainActor
final class DirectHermesSessionActions {
    struct Connection {
        let rpc: any DirectHermesRPC
        let runtimeSessionID: String
        let storedSessionID: String
        let isRunning: Bool
        let canMutate: Bool
        let isCurrent: @MainActor () -> Bool
    }

    private enum Method: String {
        case background = "prompt.background"
        case btw = "prompt.btw"
        case react = "message.react"
        case status = "session.status"
        case usage = "session.usage"
        case contextBreakdown = "session.context_breakdown"
        case compress = "session.compress"
        case undo = "session.undo"
        case save = "session.save"
        case setWorkingDirectory = "session.cwd.set"
        case controlRead = "session.control.read"
        case control = "session.control"
        case promptSubmit = "prompt.submit"
        case redirect = "session.redirect"
        case history = "session.history"
        case rollbackList = "rollback.list"
        case rollbackDiff = "rollback.diff"
        case rollbackRestore = "rollback.restore"
        case delegationStatus = "delegation.status"
        case delegationPause = "delegation.pause"
        case spawnTreeList = "spawn_tree.list"
        case spawnTreeLoad = "spawn_tree.load"
        case spawnTreeSave = "spawn_tree.save"
        case verificationStatus = "verification.status"
        case skillsReload = "skills.reload"
        case toolsetsList = "toolsets.list"
        case toolsConfigure = "tools.configure"
    }

    private let profile: String
    private let authority: @MainActor () -> Connection?
    private let onSideTaskAccepted: @MainActor (DirectHermesSideTaskAcceptance) -> Void

    init(profile: String,
         authority: @escaping @MainActor () -> Connection?,
         onSideTaskAccepted: @escaping @MainActor (DirectHermesSideTaskAcceptance) -> Void = { _ in }) {
        self.profile = profile
        self.authority = authority
        self.onSideTaskAccepted = onSideTaskAccepted
    }

    func startBackgroundTask(_ text: String) async throws -> DirectHermesSideTaskReceipt {
        try await sideTask(.background, text: text)
    }

    func askBTW(_ text: String) async throws -> DirectHermesSideTaskReceipt {
        try await sideTask(.btw, text: text)
    }

    func status() async throws -> DirectHermesSessionStatus {
        try Self.decodeStatus(try await request(.status))
    }

    func usage() async throws -> DirectHermesSessionUsage {
        try Self.decodeUsage(try await request(.usage))
    }

    func contextBreakdown() async throws -> DirectHermesContextBreakdown {
        try Self.decodeContextBreakdown(try await request(.contextBreakdown))
    }

    func reloadSkills() async throws -> DirectHermesSkillsReloadResult {
        // Stock skills.reload has no runtime or profile parameters. The closed
        // action facade still fences the request to this exact connection.
        let object = try Self.object(try await request(
            .skillsReload, mutation: true, requiresIdle: true,
            includeSession: false, includeProfile: false
        ))
        guard Set(object.keys) == ["output", "result"],
              let output = object["output"]?.string,
              let result = object["result"]?.object,
              Set(result.keys) == ["added", "removed", "unchanged", "total", "commands"],
              let addedValues = result["added"]?.array,
              let removedValues = result["removed"]?.array,
              addedValues.count <= 4_096, removedValues.count <= 4_096 else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesSkillsReloadResult(
            output: output,
            added: try addedValues.map(Self.decodeSkillReloadChange),
            removed: try removedValues.map(Self.decodeSkillReloadChange),
            unchanged: try Self.requiredStrings("unchanged", in: result),
            total: try Self.requiredNonnegativeInteger("total", in: result),
            commands: try Self.requiredNonnegativeInteger("commands", in: result)
        )
    }

    func toolsets() async throws -> DirectHermesToolsetsSnapshot {
        try await readToolsets()
    }

    func configureToolset(
        _ name: String,
        action: DirectHermesToolConfigurationAction
    ) async throws -> DirectHermesToolsConfigurationResult {
        try Self.validateText(name, maximumBytes: 256, allowsEmpty: false)
        // Stock tools.configure derives the profile from the live runtime
        // session. Sending a profile would not select the mutation target.
        let object = try Self.object(try await request(
            .toolsConfigure,
            extras: [
                "action": .string(action.rawValue),
                "names": .array([.string(name)]),
            ],
            mutation: true,
            requiresIdle: true,
            includeProfile: false
        ))
        let keys: Set<String> = [
            "changed", "enabled_toolsets", "info", "missing_servers", "reset", "unknown",
        ]
        guard Set(object.keys) == keys,
              object["reset"]?.boolean == true,
              object["info"]?.object != nil else {
            throw DirectHermesError.invalidResponse
        }
        let readback: DirectHermesToolsetsSnapshot?
        do { readback = try await readToolsets() }
        catch { readback = nil }
        return DirectHermesToolsConfigurationResult(
            changed: try Self.requiredStrings("changed", in: object),
            configuredEnabledToolsets: try Self.requiredStrings("enabled_toolsets", in: object),
            missingServers: try Self.requiredStrings("missing_servers", in: object),
            reset: true,
            unknown: try Self.requiredStrings("unknown", in: object),
            returnedSessionInfo: true,
            readback: readback
        )
    }

    func compress(focusTopic: String? = nil) async throws -> DirectHermesCompressionResult {
        var extras: [String: BighelpJSONValue] = [:]
        if let focusTopic {
            try Self.validateText(focusTopic, maximumBytes: 131_072, allowsEmpty: false)
            extras["focus_topic"] = .string(focusTopic)
        }
        let object = try Self.object(try await request(.compress, extras: extras, mutation: true, requiresIdle: true))
        return DirectHermesCompressionResult(
            status: try Self.optionalString("status", in: object),
            removed: try Self.optionalNonnegativeInteger("removed", in: object),
            beforeMessages: try Self.optionalNonnegativeInteger("before_messages", in: object),
            afterMessages: try Self.optionalNonnegativeInteger("after_messages", in: object),
            beforeTokens: try Self.optionalNonnegativeInteger("before_tokens", in: object),
            afterTokens: try Self.optionalNonnegativeInteger("after_tokens", in: object),
            compressed: try Self.optionalBoolean("compressed", in: object),
            message: try Self.optionalString("message", in: object),
            readback: await mutationReadback(includeHistory: true)
        )
    }

    func undo() async throws -> DirectHermesUndoResult {
        let object = try Self.object(try await request(.undo, mutation: true, requiresIdle: true))
        let removed = try Self.requiredNonnegativeInteger("removed", in: object)
        return DirectHermesUndoResult(removed: removed, readback: await mutationReadback(includeHistory: true))
    }

    func save() async throws -> DirectHermesSaveResult {
        let object = try Self.object(try await request(.save, mutation: true, requiresIdle: true))
        return DirectHermesSaveResult(file: try Self.optionalString("file", in: object),
            readback: await mutationReadback(includeHistory: false))
    }

    func setWorkingDirectory(_ path: String) async throws -> DirectHermesWorkingDirectoryResult {
        try Self.validateText(path, maximumBytes: 16_384, allowsEmpty: false)
        let object = try Self.object(try await request(.setWorkingDirectory,
            extras: ["cwd": .string(path)], mutation: true, requiresIdle: true))
        guard let returned = object["cwd"]?.string,
              Data(returned.utf8) == Data(path.utf8) else { throw DirectHermesError.invalidResponse }
        return DirectHermesWorkingDirectoryResult(workingDirectory: returned,
            readback: await mutationReadback(includeHistory: false))
    }

    func readControl() async throws -> DirectHermesSessionControlSnapshot {
        let object = try Self.object(try await request(.controlRead))
        guard Set(object.keys) == ["control"], let control = object["control"]?.object else {
            throw DirectHermesError.invalidResponse
        }
        return try Self.decodeControlSnapshot(control)
    }

    func applyControl(_ action: DirectHermesSessionControlAction) async throws -> DirectHermesSessionControlResult {
        switch action {
        case .subgoalAdd(let text): try Self.validateText(text, maximumBytes: 131_072, allowsEmpty: false)
        case .subgoalRemove(let index): guard index > 0 else { throw DirectHermesError.invalidResponse }
        default: break
        }
        var extras: [String: BighelpJSONValue] = ["action": .string(action.wireName)]
        if let arguments = action.arguments { extras["args"] = .object(arguments) }
        let object = try Self.object(try await request(.control, extras: extras, mutation: true))
        guard Set(object.keys) == ["control", "dispatch"],
              let control = object["control"]?.object,
              let dispatch = object["dispatch"]?.object else { throw DirectHermesError.invalidResponse }
        let decodedControl = try Self.decodeControlSnapshot(control)
        let decodedDispatch = try Self.decodeControlDispatch(dispatch)
        let continuation = await submitControlContinuationIfNeeded(decodedDispatch)
        let confirmedDispatch = DirectHermesSessionControlDispatch(
            type: decodedDispatch.type,
            output: decodedDispatch.output,
            notice: decodedDispatch.notice,
            message: decodedDispatch.message,
            display: decodedDispatch.display,
            continuation: continuation
        )
        return DirectHermesSessionControlResult(
            control: decodedControl,
            dispatch: confirmedDispatch,
            continuation: continuation
        )
    }

    /// `session.control` deliberately returns the same typed `send` envelope as
    /// `/goal resume`; it does not itself enqueue that continuation turn. Submit
    /// the returned host-authored prompt exactly once. A lost receipt is retained
    /// as unknown and must never cause the control action to be replayed.
    private func submitControlContinuationIfNeeded(
        _ dispatch: DirectHermesSessionControlDispatch
    ) async -> DirectHermesSessionControlContinuation {
        guard dispatch.type == "send", let message = dispatch.message, !message.isEmpty else {
            return .notRequired
        }
        do {
            try Self.validateText(message, maximumBytes: 1_048_576, allowsEmpty: false)
            let response = try Self.object(try await request(
                .promptSubmit,
                extras: [
                    "text": .string(message),
                    "queued": .boolean(true),
                ],
                mutation: true
            ))
            guard let status = response["status"]?.string,
                  ["queued", "streaming", "ok"].contains(status) else {
                return .outcomeUnknown
            }
            return .accepted
        } catch let error as DirectHermesError {
            if error.outcomeIsUnknown { return .outcomeUnknown }
            if case .rpcRejected = error { return .rejected }
            return .outcomeUnknown
        } catch {
            return .outcomeUnknown
        }
    }

    func redirect(_ text: String) async throws -> DirectHermesRedirectResult {
        try Self.validateText(text, maximumBytes: 1_048_576, allowsEmpty: false)
        let object = try Self.object(try await request(.redirect,
            extras: ["text": .string(text)], mutation: true))
        guard Set(object.keys) == ["status", "text"],
              let raw = object["status"]?.string,
              let status = DirectHermesCorrectionStatus(rawValue: raw),
              let returned = object["text"]?.string else { throw DirectHermesError.invalidResponse }
        return DirectHermesRedirectResult(status: status, text: returned)
    }

    func setReaction(target: DirectHermesReactionTarget, emoji: String?,
                     author: DirectHermesReactionAuthor) async throws -> DirectHermesMessageReactionResult {
        if let emoji { try Self.validateText(emoji, maximumBytes: 256, allowsEmpty: false) }
        var extras: [String: BighelpJSONValue] = [
            "emoji": emoji.map(BighelpJSONValue.string) ?? .null,
            "author": .string(author.rawValue),
        ]
        switch target {
        case .row(let rowID):
            guard rowID >= 0 else { throw DirectHermesError.invalidResponse }
            extras["row_id"] = .integer(rowID)
        case .newest(let role):
            extras["newest_role"] = .string(role.rawValue)
        }
        let object = try Self.object(try await request(.react, extras: extras, mutation: true))
        guard Set(object.keys) == ["row_id", "reactions"],
              let rowID = object["row_id"]?.integer, rowID >= 0,
              let values = object["reactions"]?.array else { throw DirectHermesError.invalidResponse }
        return DirectHermesMessageReactionResult(rowID: rowID,
            reactions: try Self.decodeReactions(values))
    }

    func rollbacks() async throws -> DirectHermesRollbackList {
        let object = try Self.object(try await request(.rollbackList))
        guard Set(object.keys).isSubset(of: ["enabled", "checkpoints"]),
              let enabled = object["enabled"]?.boolean else { throw DirectHermesError.invalidResponse }
        let values = object["checkpoints"]?.array ?? []
        guard values.count <= 4_096 else { throw DirectHermesError.invalidResponse }
        let checkpoints = try values.map { value -> DirectHermesRollbackCheckpoint in
            guard let row = value.object,
                  Set(row.keys).isSubset(of: ["hash", "timestamp", "message"]) else {
                throw DirectHermesError.invalidResponse
            }
            return DirectHermesRollbackCheckpoint(hash: try Self.defaultedString("hash", in: row),
                timestamp: try Self.defaultedString("timestamp", in: row),
                message: try Self.defaultedString("message", in: row))
        }
        return DirectHermesRollbackList(enabled: enabled, checkpoints: checkpoints)
    }

    func rollbackDiff(hash: String) async throws -> DirectHermesRollbackDiff {
        try Self.validateOpaque(hash)
        let object = try Self.object(try await request(.rollbackDiff, extras: ["hash": .string(hash)]))
        guard Set(object.keys).isSubset(of: ["stat", "diff", "rendered"]) else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesRollbackDiff(stat: try Self.defaultedString("stat", in: object),
            diff: try Self.defaultedString("diff", in: object),
            rendered: try Self.optionalString("rendered", in: object))
    }

    func restoreRollback(hash: String, filePath: String? = nil) async throws -> DirectHermesRollbackRestoreResult {
        try Self.validateOpaque(hash)
        var extras: [String: BighelpJSONValue] = ["hash": .string(hash)]
        if let filePath {
            try Self.validateText(filePath, maximumBytes: 16_384, allowsEmpty: false)
            extras["file_path"] = .string(filePath)
        }
        let object = try Self.object(try await request(.rollbackRestore,
            extras: extras, mutation: true, requiresIdle: true))
        guard let success = object["success"]?.boolean else { throw DirectHermesError.invalidResponse }
        return DirectHermesRollbackRestoreResult(success: success,
            restoredTo: try Self.optionalString("restored_to", in: object),
            reason: try Self.optionalString("reason", in: object),
            directory: try Self.optionalString("directory", in: object),
            file: try Self.optionalString("file", in: object),
            restoredFiles: try Self.optionalStrings("restored_files", in: object),
            skippedUserEdits: try Self.optionalStrings("skipped_user_edits", in: object),
            skippedOversize: try Self.optionalStrings("skipped_oversize", in: object),
            failedDeletes: try Self.optionalStrings("failed_deletes", in: object),
            historyRemoved: try Self.optionalNonnegativeInteger("history_removed", in: object),
            error: try Self.optionalString("error", in: object),
            readback: await mutationReadback(includeHistory: true))
    }

    func delegationStatus() async throws -> DirectHermesDelegationStatus {
        let object = try Self.object(try await request(.delegationStatus, includeSession: false))
        guard Set(object.keys) == ["active", "paused", "max_spawn_depth", "max_concurrent_children"],
              let values = object["active"]?.array, values.count <= 4_096,
              let paused = object["paused"]?.boolean else { throw DirectHermesError.invalidResponse }
        let depth = try Self.requiredNonnegativeInteger("max_spawn_depth", in: object)
        let concurrent = try Self.requiredNonnegativeInteger("max_concurrent_children", in: object)
        let active = try values.map(Self.decodeDelegation)
        guard Set(active.map { Data($0.id.utf8) }).count == active.count else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesDelegationStatus(active: active, paused: paused,
            maxSpawnDepth: depth, maxConcurrentChildren: concurrent)
    }

    func setDelegationPaused(_ paused: Bool) async throws -> Bool {
        let object = try Self.object(try await request(.delegationPause,
            extras: ["paused": .boolean(paused)], mutation: true, includeSession: false))
        guard Set(object.keys) == ["paused"], object["paused"]?.boolean == paused else {
            throw DirectHermesError.invalidResponse
        }
        return paused
    }

    func spawnTrees(crossSession: Bool = false, limit: Int = 50) async throws -> [DirectHermesSpawnTreeEntry] {
        guard (1...500).contains(limit) else { throw DirectHermesError.invalidResponse }
        let object = try Self.object(try await request(.spawnTreeList, extras: [
            "cross_session": .boolean(crossSession), "limit": .integer(limit),
        ]))
        guard Set(object.keys) == ["entries"], let values = object["entries"]?.array,
              values.count <= limit else { throw DirectHermesError.invalidResponse }
        return try values.map(Self.decodeSpawnTreeEntry)
    }

    func loadSpawnTree(path: String) async throws -> DirectHermesSpawnTreeSnapshot {
        try Self.validateText(path, maximumBytes: 16_384, allowsEmpty: false)
        let object = try Self.object(try await request(.spawnTreeLoad,
            extras: ["path": .string(path)], includeSession: false))
        return try Self.decodeSpawnTreeSnapshot(object)
    }

    func saveSpawnTree(_ snapshot: DirectHermesSpawnTreeSnapshot,
                       label: String? = nil) async throws -> DirectHermesSpawnTreeSaveResult {
        guard snapshot.subagents.count <= 4_096 else { throw DirectHermesError.messageTooLarge }
        var extras: [String: BighelpJSONValue] = [
            "subagents": .array(snapshot.subagents.map(BighelpJSONValue.object)),
        ]
        if let sessionID = snapshot.sessionID { extras["session_id"] = .string(sessionID) }
        if let startedAt = snapshot.startedAt { extras["started_at"] = .number(startedAt) }
        if let finishedAt = snapshot.finishedAt { extras["finished_at"] = .number(finishedAt) }
        if let label = label ?? snapshot.label {
            try Self.validateText(label, maximumBytes: 4_096, allowsEmpty: true)
            extras["label"] = .string(label)
        }
        let object = try Self.object(try await request(.spawnTreeSave,
            extras: extras, mutation: true, includeSession: false))
        guard Set(object.keys) == ["path", "session_id"],
              let path = object["path"]?.string, !path.isEmpty,
              let sessionID = object["session_id"]?.string, !sessionID.isEmpty else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesSpawnTreeSaveResult(path: path, sessionID: sessionID)
    }

    func verificationStatus(workingDirectory: String? = nil) async throws -> DirectHermesVerificationStatus {
        var extras: [String: BighelpJSONValue] = [:]
        if let workingDirectory {
            try Self.validateText(workingDirectory, maximumBytes: 16_384, allowsEmpty: false)
            extras["cwd"] = .string(workingDirectory)
        }
        let object = try Self.object(try await request(.verificationStatus, extras: extras))
        guard Set(object.keys) == ["verification"], let value = object["verification"]?.object else {
            throw DirectHermesError.invalidResponse
        }
        return try Self.decodeVerificationStatus(value)
    }

    private func sideTask(_ method: Method, text: String) async throws -> DirectHermesSideTaskReceipt {
        try Self.validateText(text, maximumBytes: 1_048_576, allowsEmpty: false)
        let object = try Self.object(try await request(method,
            extras: ["text": .string(text)], mutation: true))
        guard Set(object.keys) == ["task_id"],
              let taskID = object["task_id"]?.string, !taskID.isEmpty,
              taskID.utf8.count <= 4_096 else { throw DirectHermesError.invalidResponse }
        let kind: DirectHermesSideTaskKind
        switch method {
        case .background: kind = .background
        case .btw: kind = .btw
        default: throw DirectHermesError.invalidResponse
        }
        onSideTaskAccepted(DirectHermesSideTaskAcceptance(kind: kind, taskID: taskID, prompt: text))
        return DirectHermesSideTaskReceipt(taskID: taskID)
    }

    private func request(_ method: Method, extras: [String: BighelpJSONValue] = [:],
                         mutation: Bool = false, requiresIdle: Bool = false,
                         includeSession: Bool = true,
                         includeProfile: Bool = true) async throws -> BighelpJSONValue {
        guard let connection = authority() else { throw DirectHermesError.notConnected }
        if mutation, !connection.canMutate { throw DirectHermesWorkspaceError.reviewRequired }
        if requiresIdle, connection.isRunning { throw DirectHermesWorkspaceError.nativeTurnActive }
        var params: [String: BighelpJSONValue] = [:]
        if includeProfile { params["profile"] = .string(profile) }
        if includeSession { params["session_id"] = .string(connection.runtimeSessionID) }
        for (key, value) in extras { params[key] = value }
        let result = try await connection.rpc.request(method.rawValue, params: params)
        guard connection.isCurrent() else {
            throw DirectHermesError.disconnected(outcomeUnknown: mutation)
        }
        return result
    }

    private func mutationReadback(includeHistory: Bool) async -> DirectHermesSessionMutationReadback? {
        do {
            let status = try Self.decodeStatus(try await request(.status))
            let history: DirectHermesSessionHistory?
            if includeHistory { history = try await readHistory() }
            else { history = nil }
            return DirectHermesSessionMutationReadback(status: status, history: history)
        } catch {
            return nil
        }
    }

    private func readHistory() async throws -> DirectHermesSessionHistory {
        let object = try Self.object(try await request(.history))
        guard Set(object.keys) == ["count", "messages"],
              let count = object["count"]?.integer, count >= 0,
              let messages = object["messages"]?.array,
              count == messages.count else { throw DirectHermesError.invalidResponse }
        return DirectHermesSessionHistory(count: count, messages: messages)
    }

    private func readToolsets() async throws -> DirectHermesToolsetsSnapshot {
        let object = try Self.object(try await request(
            .toolsetsList, includeProfile: false
        ))
        guard Set(object.keys) == ["toolsets"],
              let values = object["toolsets"]?.array,
              values.count <= 4_096 else { throw DirectHermesError.invalidResponse }
        let toolsets = try values.map { value -> DirectHermesToolset in
            guard let row = value.object,
                  Set(row.keys) == ["name", "description", "tool_count", "enabled"],
                  let name = row["name"]?.string, !name.isEmpty, name.utf8.count <= 256,
                  let description = row["description"]?.string,
                  description.utf8.count <= 16_384,
                  let enabled = row["enabled"]?.boolean else {
                throw DirectHermesError.invalidResponse
            }
            return DirectHermesToolset(
                name: name,
                description: description,
                toolCount: try Self.requiredNonnegativeInteger("tool_count", in: row),
                enabled: enabled
            )
        }
        guard Set(toolsets.map(\.name)).count == toolsets.count else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesToolsetsSnapshot(toolsets: toolsets)
    }

    private static func decodeStatus(_ value: BighelpJSONValue) throws -> DirectHermesSessionStatus {
        let object = try object(value)
        guard Set(object.keys) == ["output"], let output = object["output"]?.string else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesSessionStatus(output: output)
    }

    private static func decodeUsage(_ value: BighelpJSONValue) throws -> DirectHermesSessionUsage {
        let object = try object(value)
        return DirectHermesSessionUsage(model: try defaultedString("model", in: object),
            input: try defaultedNonnegativeInteger("input", in: object),
            output: try defaultedNonnegativeInteger("output", in: object),
            reasoning: try defaultedNonnegativeInteger("reasoning", in: object),
            prompt: try defaultedNonnegativeInteger("prompt", in: object),
            completion: try defaultedNonnegativeInteger("completion", in: object),
            total: try defaultedNonnegativeInteger("total", in: object),
            calls: try defaultedNonnegativeInteger("calls", in: object),
            compressions: try optionalNonnegativeInteger("compressions", in: object),
            contextUsed: try optionalNonnegativeInteger("context_used", in: object),
            contextMax: try optionalNonnegativeInteger("context_max", in: object),
            contextPercent: try optionalNonnegativeInteger("context_percent", in: object),
            contextSource: try optionalString("context_source", in: object),
            contextEstimated: try optionalBoolean("context_estimated", in: object),
            cacheHitPercent: try optionalNonnegativeInteger("cache_hit_pct", in: object),
            cacheRead: try optionalNonnegativeInteger("cache_read", in: object),
            cacheWrite: try optionalNonnegativeInteger("cache_write", in: object),
            averageLatencySeconds: try optionalNumber("avg_latency_s", in: object),
            averageTokensPerSecond: try optionalNumber("avg_tps", in: object),
            activeSubagents: try optionalNonnegativeInteger("active_subagents", in: object),
            developerCreditsSpentMicros: try optionalNonnegativeInteger("dev_credits_spent_micros", in: object),
            costUSD: try optionalNumber("cost_usd", in: object),
            costStatus: try optionalString("cost_status", in: object),
            creditLines: try optionalStrings("credits_lines", in: object))
    }

    private static func decodeContextBreakdown(_ value: BighelpJSONValue) throws -> DirectHermesContextBreakdown {
        try DirectHermesContextBreakdown(hermes: value)
    }

    private static func decodeControlSnapshot(_ object: [String: BighelpJSONValue]) throws -> DirectHermesSessionControlSnapshot {
        try DirectHermesSessionControlSnapshot(object: object)
    }

    private static func decodeControlDispatch(_ object: [String: BighelpJSONValue]) throws -> DirectHermesSessionControlDispatch {
        guard Set(object.keys) == ["type", "output", "notice", "message", "display"] else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesSessionControlDispatch(type: try optionalString("type", in: object),
            output: try optionalString("output", in: object),
            notice: try optionalString("notice", in: object),
            message: try optionalString("message", in: object),
            display: try optionalString("display", in: object),
            continuation: .notRequired)
    }

    private static func decodeReactions(_ values: [BighelpJSONValue]) throws -> [DirectHermesMessageReaction.Reaction] {
        guard values.count <= 1_024 else { throw DirectHermesError.invalidResponse }
        return try values.map { value in
            guard let row = value.object,
                  let emoji = row["emoji"]?.string, !emoji.isEmpty,
                  let author = row["author"]?.string,
                  DirectHermesReactionAuthor(rawValue: author) != nil else {
                throw DirectHermesError.invalidResponse
            }
            return DirectHermesMessageReaction.Reaction(emoji: emoji, author: author,
                at: try optionalNumber("at", in: row), seen: try optionalBoolean("seen", in: row))
        }
    }

    private static func decodeSkillReloadChange(_ value: BighelpJSONValue) throws -> DirectHermesSkillReloadChange {
        guard let row = value.object,
              Set(row.keys) == ["name", "description"],
              let name = row["name"]?.string, !name.isEmpty, name.utf8.count <= 4_096,
              let description = row["description"]?.string,
              description.utf8.count <= 131_072 else { throw DirectHermesError.invalidResponse }
        return DirectHermesSkillReloadChange(name: name, description: description)
    }

    private static func decodeDelegation(_ value: BighelpJSONValue) throws -> DirectHermesActiveDelegation {
        guard let row = value.object, let id = row["subagent_id"]?.string, !id.isEmpty else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesActiveDelegation(id: id,
            parentID: try optionalString("parent_id", in: row),
            childSessionID: try optionalString("child_session_id", in: row),
            delegationID: try optionalString("delegation_id", in: row),
            depth: try optionalNonnegativeInteger("depth", in: row),
            goal: try optionalString("goal", in: row),
            model: try optionalString("model", in: row),
            status: try optionalString("status", in: row))
    }

    private static func decodeSpawnTreeEntry(_ value: BighelpJSONValue) throws -> DirectHermesSpawnTreeEntry {
        guard let row = value.object, let path = row["path"]?.string, !path.isEmpty else {
            throw DirectHermesError.invalidResponse
        }
        return DirectHermesSpawnTreeEntry(path: path,
            sessionID: try optionalString("session_id", in: row),
            startedAt: try optionalNumber("started_at", in: row),
            finishedAt: try optionalNumber("finished_at", in: row),
            label: try defaultedString("label", in: row),
            count: try defaultedNonnegativeInteger("count", in: row))
    }

    private static func decodeSpawnTreeSnapshot(_ object: [String: BighelpJSONValue]) throws -> DirectHermesSpawnTreeSnapshot {
        let values = object["subagents"]?.array ?? []
        guard values.count <= 4_096 else { throw DirectHermesError.messageTooLarge }
        let subagents = try values.map { value -> [String: BighelpJSONValue] in
            guard let row = value.object else { throw DirectHermesError.invalidResponse }
            return row
        }
        return DirectHermesSpawnTreeSnapshot(sessionID: try optionalString("session_id", in: object),
            startedAt: try optionalNumber("started_at", in: object),
            finishedAt: try optionalNumber("finished_at", in: object),
            label: try optionalString("label", in: object), subagents: subagents)
    }

    private static func decodeVerificationStatus(_ object: [String: BighelpJSONValue]) throws -> DirectHermesVerificationStatus {
        let keys: Set<String> = ["status", "evidence", "root", "session_id", "changed_paths"]
        guard Set(object.keys).isSubset(of: keys), let status = object["status"]?.string else {
            throw DirectHermesError.invalidResponse
        }
        let evidence: DirectHermesVerificationEvidence?
        if let value = object["evidence"], value != .null {
            guard let row = value.object else { throw DirectHermesError.invalidResponse }
            evidence = DirectHermesVerificationEvidence(id: try optionalNonnegativeInteger("id", in: row),
                createdAt: try optionalString("created_at", in: row),
                sessionID: try optionalString("session_id", in: row),
                workingDirectory: try optionalString("cwd", in: row),
                root: try optionalString("root", in: row),
                command: try optionalString("command", in: row),
                canonicalCommand: try optionalString("canonical_command", in: row),
                kind: try optionalString("kind", in: row),
                scope: try optionalString("scope", in: row),
                status: try optionalString("status", in: row),
                exitCode: try optionalInteger("exit_code", in: row),
                outputSummary: try optionalString("output_summary", in: row))
        } else {
            evidence = nil
        }
        return DirectHermesVerificationStatus(status: status, evidence: evidence,
            root: try optionalString("root", in: object),
            sessionID: try optionalString("session_id", in: object),
            changedPaths: try optionalStrings("changed_paths", in: object))
    }

    private static func object(_ value: BighelpJSONValue) throws -> [String: BighelpJSONValue] {
        guard let object = value.object else { throw DirectHermesError.invalidResponse }
        return object
    }

    private static func validateText(_ value: String, maximumBytes: Int, allowsEmpty: Bool) throws {
        guard (allowsEmpty || !value.isEmpty), value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x7f }) else {
            throw DirectHermesError.invalidResponse
        }
    }

    private static func validateOpaque(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw DirectHermesError.invalidResponse
        }
    }

    private static func defaultedString(_ key: String, in object: [String: BighelpJSONValue]) throws -> String {
        guard let value = object[key] else { return "" }
        guard let string = value.string else { throw DirectHermesError.invalidResponse }
        return string
    }

    private static func optionalString(_ key: String, in object: [String: BighelpJSONValue]) throws -> String? {
        guard let value = object[key], value != .null else { return nil }
        guard let string = value.string else { throw DirectHermesError.invalidResponse }
        return string
    }

    private static func defaultedNonnegativeInteger(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> Int {
        guard object[key] != nil else { return 0 }
        return try requiredNonnegativeInteger(key, in: object)
    }

    private static func requiredNonnegativeInteger(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> Int {
        guard let value = object[key]?.integer, value >= 0 else { throw DirectHermesError.invalidResponse }
        return value
    }

    private static func optionalNonnegativeInteger(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> Int? {
        guard let value = object[key], value != .null else { return nil }
        guard let integer = value.integer, integer >= 0 else { throw DirectHermesError.invalidResponse }
        return integer
    }

    private static func optionalInteger(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> Int? {
        guard let value = object[key], value != .null else { return nil }
        guard let integer = value.integer else { throw DirectHermesError.invalidResponse }
        return integer
    }

    private static func optionalBoolean(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> Bool? {
        guard let value = object[key], value != .null else { return nil }
        guard let boolean = value.boolean else { throw DirectHermesError.invalidResponse }
        return boolean
    }

    private static func optionalNumber(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> Double? {
        guard let value = object[key], value != .null else { return nil }
        guard let number = value.number, number.isFinite else { throw DirectHermesError.invalidResponse }
        return number
    }

    private static func optionalStrings(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> [String]? {
        guard let value = object[key], value != .null else { return nil }
        guard let values = value.array, values.count <= 4_096 else { throw DirectHermesError.invalidResponse }
        let strings = values.compactMap(\.string)
        guard strings.count == values.count else { throw DirectHermesError.invalidResponse }
        return strings
    }

    private static func requiredStrings(_ key: String,
        in object: [String: BighelpJSONValue]) throws -> [String] {
        guard let strings = try optionalStrings(key, in: object) else {
            throw DirectHermesError.invalidResponse
        }
        return strings
    }
}
