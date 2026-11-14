import Foundation

enum HermesAchievementsAPI: String, CaseIterable, Sendable {
    case achievements = "GET /api/plugins/hermes-achievements/achievements"
    case recentUnlocks = "GET /api/plugins/hermes-achievements/recent-unlocks"
    case rescan = "POST /api/plugins/hermes-achievements/rescan"
    case reset = "POST /api/plugins/hermes-achievements/reset-state"
    case scanStatus = "GET /api/plugins/hermes-achievements/scan-status"
    case sessionBadges = "GET /api/plugins/hermes-achievements/sessions/{session_id}/badges"
}

enum HermesAchievementsMount: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

enum HermesAchievementsError: Error, Equatable, LocalizedError {
    case unavailable
    case staleOwner
    case invalidRequest
    case invalidResponse
    case capacityExceeded
    case reviewChanged
    case resetNotVerified
    case scanStillRunning
    case scanFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The selected Hermes host does not have the Achievements dashboard plugin mounted."
        case .staleOwner:
            "The selected host or account changed. Reopen Achievements from the current workspace."
        case .invalidRequest:
            "The Achievements request is invalid. Refresh the mounted plugin state."
        case .invalidResponse:
            "Hermes returned an invalid Achievements response."
        case .capacityExceeded:
            "The Achievements response exceeded Bighelp’s bounded native limit."
        case .reviewChanged:
            "Achievements changed after review. Refresh and review the current state."
        case .resetNotVerified:
            "Hermes did not provide authoritative readback for the reset. Do not retry until the current status is refreshed."
        case .scanStillRunning:
            "The achievements scan is still running. Bighelp will continue showing its reported status without claiming completion."
        case .scanFailed(let reason):
            reason
        }
    }
}

enum HermesAchievementScanState: String, Equatable, Sendable {
    case idle, running, failed
}

struct HermesAchievementScanStatus: Equatable, Sendable {
    let state: HermesAchievementScanState
    let startedAt: Date?
    let finishedAt: Date?
    let lastError: String?
    let lastDurationMilliseconds: Int?
    let runCount: Int
    let TTLSeconds: Int
    let snapshotGeneratedAt: Date?
    let snapshotAgeSeconds: Int?
    let snapshotIsStale: Bool
}

struct HermesAchievementEvidence: Equatable, Sendable {
    let sessionID: String?
    let sessionTitle: String?
    let value: Int?
}

struct HermesAchievement: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let criteria: String
    let category: String
    let kind: String
    let icon: String
    let isSecret: Bool
    let isUnlocked: Bool
    let isDiscovered: Bool
    let state: String
    let tier: String?
    let progress: Int
    let progressPercent: Int
    let nextTier: String?
    let nextThreshold: Int?
    let unlockedAt: Date?
    let evidence: HermesAchievementEvidence?
}

struct HermesAchievementsCatalog: Equatable, Sendable {
    let achievements: [HermesAchievement]
    let unlockedCount: Int
    let discoveredCount: Int
    let secretCount: Int
    let totalCount: Int
    let generatedAt: Date
    let isStale: Bool
    let scanMode: String
    let sessionsTotal: Int
    let sessionsRescanned: Int
    let sessionsReused: Int
    let sessionsScannedSoFar: Int?
    let sessionsExpectedTotal: Int?
    let status: HermesAchievementScanStatus
    let error: String?
}

struct HermesAchievementsReview: Identifiable, Equatable, Sendable {
    enum Action: String, Equatable, Sendable { case rescan, reset }

    let action: Action
    let catalogRevision: Data
    let status: HermesAchievementScanStatus
    let unlockedCount: Int
    let totalCount: Int

    var id: String { "\(action.rawValue):\(catalogRevision.base64EncodedString()):\(status.runCount)" }
}

enum HermesAchievementsRescanResult: Equatable, Sendable {
    case completed(HermesAchievementsCatalog, HermesAchievementScanStatus)
    case running(HermesAchievementScanStatus)
    case failed(HermesAchievementScanStatus)
}
