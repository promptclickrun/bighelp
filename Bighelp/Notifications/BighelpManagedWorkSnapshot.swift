import Foundation

/// A plugin-owned CURRENT observation for an exact subscribed session. It does
/// not assert that a native projection segment has this canonical turn ID.
struct BighelpManagedWorkSnapshot: Decodable, Equatable, Sendable {
    struct Work: Decodable, Equatable, Sendable {
        enum Outcome: String, Decodable, Sendable { case completed, failed, cancelled }
        let profile: String
        let sessionId: String
        let turnId: String
        let phase: LoopdySessionActivityAttributes.ContentState.Phase
        let activeSubagentCount: Int
        let terminal: Bool
        let outcome: Outcome?
        let observedAt: Int

        var contentState: LoopdySessionActivityAttributes.ContentState {
            let action: String
            switch phase {
            case .thinking, .usingTool: action = "Your agent is working"
            case .waiting: action = "Your agent needs attention"
            case .delegating: action = "Agents are working"
            case .responding: action = "Your agent is responding"
            case .completed: action = outcome == .cancelled ? "Stopped" : "Your agent finished"
            case .failed: action = "Your agent could not finish"
            }
            return .init(phase: phase, currentAction: action, progress: terminal ? 100 : 0,
                completedSteps: 0, activeSubagentCount: activeSubagentCount, latestTool: nil, timestamp: observedAt)
        }
    }
    let version: Int
    let grantId: String
    let work: Work?

    static func validated(_ value: BighelpJSONValue, grantID: String, profile: String,
                          sessionID: String, now: Int) throws -> Self {
        guard let object = value.object, Set(object.keys) == ["version", "grantId", "work"] else {
            throw DirectHermesError.invalidResponse
        }
        if let work = object["work"]?.object {
            guard Set(work.keys) == ["profile", "sessionId", "turnId", "phase", "activeSubagentCount",
                                     "terminal", "outcome", "observedAt"] else { throw DirectHermesError.invalidResponse }
        }
        let snapshot = try ManagedNotificationValidation.decode(Self.self, from: value)
        guard snapshot.version == 1, snapshot.grantId == grantID,
              ManagedNotificationValidation.uuid(grantID) else { throw DirectHermesError.invalidResponse }
        if let work = snapshot.work {
            guard work.profile == profile, work.sessionId == sessionID,
                  ManagedNotificationValidation.profile(work.profile),
                  ManagedNotificationValidation.coordinate(work.sessionId),
                  ManagedNotificationValidation.coordinate(work.turnId),
                  (0...99).contains(work.activeSubagentCount), work.observedAt > 0,
                  work.observedAt <= min(9_999_999_999, now + 120),
                  work.terminal == (work.outcome != nil && work.activeSubagentCount == 0),
                  (work.activeSubagentCount == 0 || work.phase == .delegating),
                  (!work.phase.isTerminal || work.terminal),
                  (work.outcome != .completed || work.activeSubagentCount > 0 || work.phase == .completed),
                  (work.outcome != .failed || work.activeSubagentCount > 0 || work.phase == .failed),
                  (work.phase != .completed || work.outcome == .completed || work.outcome == .cancelled),
                  (work.phase != .failed || work.outcome == .failed) else { throw DirectHermesError.invalidResponse }
        }
        return snapshot
    }
}

extension BighelpManagedNotificationService {
    /// One bounded authenticated read; caller owns deduplication per local turn.
    func workSnapshot(host: BighelpConfiguredHost, profile: String, storedSessionID: String,
                      isCurrent: @escaping @MainActor () -> Bool) async throws -> BighelpManagedWorkSnapshot? {
        let credentials = try credentials(for: host)
        let generation = registry.generation
        guard ManagedNotificationValidation.profile(profile), ManagedNotificationValidation.coordinate(storedSessionID),
              let record = ledger.record(host: host, profile: profile), record.enabled,
              record.richLiveActivitySupported, !record.revokePending,
              let grant = record.grant, grant.state == "active", grant.expiresAt > Int(Date().timeIntervalSince1970) else { return nil }
        @MainActor func check() throws {
            try requireCurrent(host, credentials: credentials)
            guard isCurrent(), registry.generation == generation,
                  let current = ledger.record(host: host, profile: profile), current.enabled,
                  current.richLiveActivitySupported, !current.revokePending, current.grant == grant,
                  grant.expiresAt > Int(Date().timeIntervalSince1970) else {
                throw DirectHermesError.secureStorageChanged
            }
        }
        try check()
        let client = try client(for: host, profile: profile)
        let value = try await client.request("/enrollments/\(grant.grantId)/work", method: "POST", body: [
            "version": .integer(1), "profile": .string(profile), "sessionId": .string(storedSessionID)
        ], isCurrent: { (try? check()) != nil })
        try check()
        return try BighelpManagedWorkSnapshot.validated(value, grantID: grant.grantId, profile: profile,
            sessionID: storedSessionID, now: Int(Date().timeIntervalSince1970))
    }
}
