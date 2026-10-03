import Foundation

// MARK: - Safe background-action completion

/// The fixed Hermes action slot addressed by `/api/actions/{name}/status`.
///
/// Most actions have literal names. MCP catalog bootstrap is the one public
/// exception: Hermes returns a bounded `mcp-install-<slug>-<digest>` name and
/// registers that exact slot dynamically. No other host-authored path is valid.
struct HermesHostAction: RawRepresentable, Hashable, Sendable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    static let gatewayRestart = literal("gateway-restart")
    static let gatewayStart = literal("gateway-start")
    static let gatewayStop = literal("gateway-stop")
    static let gatewayMigrate = literal("gateway-migrate")
    static let hermesUpdate = literal("hermes-update")
    static let doctor = literal("doctor")
    static let securityAudit = literal("security-audit")
    static let backup = literal("backup")
    static let importArchive = literal("import")
    static let checkpointsPrune = literal("checkpoints-prune")
    static let skillsInstall = literal("skills-install")
    static let skillsUninstall = literal("skills-uninstall")
    static let skillsUpdate = literal("skills-update")
    static let curatorRun = literal("curator-run")
    static let promptSize = literal("prompt-size")
    static let dump = literal("dump")
    static let configMigrate = literal("config-migrate")
    static let toolsPostSetup = literal("tools-post-setup")

    private static let fixed: Set<String> = [
        "gateway-restart", "gateway-start", "gateway-stop", "gateway-migrate",
        "hermes-update", "doctor", "security-audit", "backup", "import",
        "checkpoints-prune", "skills-install", "skills-uninstall", "skills-update",
        "curator-run", "prompt-size", "dump", "config-migrate", "tools-post-setup",
    ]

    init?(rawValue: String) {
        guard Self.fixed.contains(rawValue) || Self.isMCPInstallAction(rawValue) || Self.isSkillsHubAction(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(validated rawValue: String) { self.rawValue = rawValue }

    private static func literal(_ value: String) -> Self { Self(validated: value) }

    private static func isMCPInstallAction(_ value: String) -> Bool {
        let prefix = "mcp-install-"
        guard value.hasPrefix(prefix), value.utf8.count <= 80,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...122).contains($0) || $0 == 45
              }) else { return false }
        let suffix = value.suffix(9)
        guard suffix.first == "-", suffix.dropFirst().count == 8,
              suffix.dropFirst().utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { return false }
        return value.dropFirst(prefix.count).dropLast(9).isEmpty == false
    }

    private static func isSkillsHubAction(_ value: String) -> Bool {
        guard let prefix = ["skills-install-", "skills-uninstall-"].first(where: { value.hasPrefix($0) }) else { return false }
        let remainder = value.dropFirst(prefix.count)
        guard (10...57).contains(remainder.utf8.count),
              remainder.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return false }
        let suffix = remainder.suffix(9)
        return suffix.first == "-" && suffix.dropFirst().utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct HermesHostActionReceipt: Equatable, Sendable, Identifiable {
    enum Admission: Equatable, Sendable {
        /// The launch response carried a process ID and/or action ID.
        case launchAcknowledged
        /// A completed domain store retained only Hermes' returned action name.
        /// Status is useful but cannot prove which invocation occupied the slot.
        case actionSlotOnly
    }

    let action: HermesHostAction
    let processID: Int?
    let actionID: String?
    let archivePath: String?
    let admittedAt: Date
    let admission: Admission

    var id: String {
        [action.rawValue, actionID ?? "", processID.map(String.init) ?? ""].joined(separator: "\u{1f}")
    }

    /// Reusable bridge for Skills Hub, Curator, toolset, and MCP stores that
    /// currently retain only the host-returned action name.
    static func actionSlot(named name: String, admittedAt: Date = Date()) throws -> Self {
        guard let action = HermesHostAction(rawValue: name) else {
            throw HostOperationsError.unsupportedAction
        }
        return Self(
            action: action, processID: nil, actionID: nil, archivePath: nil,
            admittedAt: admittedAt, admission: .actionSlotOnly
        )
    }
}

struct HermesHostActionStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        case succeeded
        case failed(exitCode: Int)
        /// The host has no live process and no durable exit result. This is not
        /// success and must not trigger a retry of the original mutation.
        case outcomeUnknown
    }

    enum Correlation: Equatable, Sendable {
        case exactActionID
        case matchingProcess
        case actionSlotOnly
        case pendingIdentity
    }

    let action: HermesHostAction
    let phase: Phase
    let processID: Int?
    let actionID: String?
    let correlation: Correlation
    let updateSummary: HermesUpdateReceiptSummary?
}

@MainActor
protocol HermesHostActionStatusClient: AnyObject {
    func receipt(forActionName name: String) throws -> HermesHostActionReceipt
    func status(for receipt: HermesHostActionReceipt) async throws -> HermesHostActionStatus
}

extension HermesHostActionStatusClient {
    /// Bounded polling never relaunches the action. A timeout returns the latest
    /// honest status so a caller can retain the receipt across navigation.
    func poll(
        _ receipt: HermesHostActionReceipt,
        attempts: Int = 30,
        intervalNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> HermesHostActionStatus {
        guard (1...120).contains(attempts),
              (250_000_000...30_000_000_000).contains(intervalNanoseconds) else {
            throw HostOperationsError.invalidRequest
        }
        var latest: HermesHostActionStatus?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let next = try await status(for: receipt)
            latest = next
            if next.phase != .running { return next }
            if attempt + 1 < attempts { try await Task.sleep(nanoseconds: intervalNanoseconds) }
        }
        guard let latest else { throw HostOperationsError.invalidResponse }
        return latest
    }
}

// MARK: - Public, bounded host projections

struct HermesHostOverview: Equatable, Sendable {
    struct Component: Identifiable, Equatable, Sendable {
        let id: String
        let status: String
    }

    let version: String
    let releaseDate: String?
    let gatewayRunning: Bool
    let gatewayState: String
    let gatewayBusy: Bool
    let gatewayDrainable: Bool
    let gatewayMode: String
    let gatewaySharedWith: [String]
    let activeAgents: Int
    let activeSessions: Int
    let restartDrainTimeout: Double
    let overall: String
    let components: [Component]
}

struct HermesSystemStats: Equatable, Sendable {
    struct Capacity: Equatable, Sendable {
        let total: Int
        let used: Int
        let available: Int
        let percent: Double
    }

    struct Process: Equatable, Sendable {
        let residentBytes: Int
        let threadCount: Int
        let createdAt: Date?
    }

    let operatingSystem: String
    let operatingSystemRelease: String?
    let architecture: String
    let hostname: String
    let pythonVersion: String
    let pythonImplementation: String?
    let hermesVersion: String
    let cpuCount: Int?
    let cpuPercent: Double?
    let loadAverage: [Double]
    let uptimeSeconds: Int?
    let memory: Capacity?
    let disk: Capacity?
    let process: Process?
    let hasExtendedMetrics: Bool
}

struct HermesEgressStatus: Equatable, Sendable {
    let text: String
}

struct HermesUpdateCheck: Equatable, Sendable {
    struct Commit: Identifiable, Equatable, Sendable {
        let sha: String
        let summary: String
        let occurredAt: Date?
        var id: String { sha }
    }

    let installMethod: String
    let currentVersion: String
    let commitsBehind: Int?
    let updateAvailable: Bool
    let canApply: Bool
    let updateCommand: String
    let message: String?
    let commits: [Commit]
}

extension HermesUpdateCheck {
    /// "12 commits behind"; Hermes reports -1 when it can't count.
    var behindText: String {
        switch commitsBehind {
        case .some(let count) where count == 1: "1 commit behind"
        case .some(let count) where count > 1: "\(count.formatted()) commits behind"
        default: "A newer version is ready"
        }
    }
}

struct HermesUpdateReceiptSummary: Equatable, Sendable {
    let outcome: String
    let startedAt: Date?
    let finishedAt: Date?
    let preUpdateSHA: String?
    let postUpdateSHA: String?
    let postUpdateVersion: String?
    let fleetStates: [String]
}

struct HermesUpdateReceipt: Equatable, Sendable {
    struct Step: Identifiable, Equatable, Sendable {
        let index: Int
        let name: String
        let succeeded: Bool
        let occurredAt: Date?
        var id: Int { index }
    }

    struct Skip: Identifiable, Equatable, Sendable {
        let index: Int
        let name: String
        let occurredAt: Date?
        var id: Int { index }
    }

    struct FleetMember: Identifiable, Equatable, Sendable {
        let profile: String
        let codeSHA: String?
        let codeVersion: String?
        let state: String
        var id: String { profile }
    }

    let schema: Int
    let summary: HermesUpdateReceiptSummary
    let steps: [Step]
    let skips: [Skip]
    let fleet: [FleetMember]
    let gatewayRestartIncomplete: Bool?
}

struct HermesCheckpointSnapshot: Equatable, Sendable {
    struct Session: Identifiable, Equatable, Sendable {
        let id: String
        let fileCount: Int
        let bytes: Int
    }

    let sessions: [Session]
    let totalBytes: Int
}

struct HermesBackupDownload: Equatable, Sendable {
    let filename: String
    let bytes: Data
}

enum HostOperationsError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(String)
    case ownerChanged
    case invalidRequest
    case invalidResponse
    case outcomeUnknown
    case unsupportedAction
    case downloadUnavailable
    case downloadTooLarge
    case reviewChanged
    case shareFailed
    case importUploadUnavailable
    case importTooLarge
    case privateDocumentTooLarge
    case noChanges

    var errorDescription: String? {
        switch self {
        case .unavailable(let feature): "This Hermes host does not expose \(feature). No private substitute was used."
        case .ownerChanged: "The selected host or connection changed. Reopen Host Operations before continuing."
        case .invalidRequest: "This host operation is invalid."
        case .invalidResponse: "Hermes returned an unsupported Host Operations response."
        case .outcomeUnknown: "Hermes did not confirm the operation. Refresh its status before trying again."
        case .unsupportedAction: "Hermes returned an action that this client cannot safely poll."
        case .downloadUnavailable: "This connection cannot download backup archives through the authenticated native transport."
        case .downloadTooLarge: "This backup exceeds the native client’s bounded download limit."
        case .reviewChanged: "Authoritative host state changed after review. Refresh and review it again before continuing."
        case .shareFailed: "Hermes could not create a redacted diagnostics share. No upload receipt was returned."
        case .importUploadUnavailable: "This connection does not expose the fixed authenticated backup-import upload transport."
        case .importTooLarge: "This backup exceeds bighelp’s bounded private import limit."
        case .privateDocumentTooLarge: "This configuration exceeds bighelp’s bounded private editor limit."
        case .noChanges: "The proposed configuration is identical to the reviewed snapshot."
        }
    }
}
