#if DEBUG
import Foundation

/// Demo room activity: two members of an open demo group report writing on
/// every poll, so the typing rows show without a host.
@MainActor
final class BotModeActivityFixtureClient: HermesBotModeActivityClient {
    static let launchArgument = "-preview-group-typing"
    static let demoMembers: [String: [String]] = [
        "demo-agent-group": ["member-finance", "member-home"],
        "studio-pair": ["member-studio", "member-build"],
        "research-circle": ["member-studio", "member-field"],
    ]

    private let membersByRoom: [String: [String]]
    private let openedAt = Int(Date().timeIntervalSince1970 * 1000)
    private var sequence = 0

    init(membersByRoom: [String: [String]] = demoMembers) {
        self.membersByRoom = membersByRoom
    }

    func open(roomID: String) async throws -> HermesBotModeActivityPage {
        page(roomID: roomID, responding: [])
    }

    func poll(roomID: String, streamID: String, after: Int, limit: Int) async throws -> HermesBotModeActivityPage {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let responding = (membersByRoom[roomID] ?? []).prefix(limit).map { memberID in
            sequence += 1
            return HermesBotModeRespondingObservation(
                observationSequence: sequence, observedAt: now, roomId: roomID, memberId: memberID,
                threadId: "demo-thread", turnId: "demo-turn", taskId: "demo-task-\(memberID)",
                executionGeneration: 1, sourceSequence: nil
            )
        }
        return page(roomID: roomID, responding: Array(responding))
    }

    func close(roomID: String, streamID: String) async throws {}

    private func page(roomID: String, responding: [HermesBotModeRespondingObservation]) -> HermesBotModeActivityPage {
        var page = HermesBotModeActivityPage(
            schemaVersion: 1, runtimeId: "demo-runtime", roomId: roomID, streamId: "demo-stream",
            sourceState: .observed, upstreamLoss: "unobservable",
            openedAt: openedAt, expiresAt: openedAt + 86_400_000,
            cursor: sequence, highWater: sequence, hasMore: false,
            resetRequired: false, resetReason: nil, droppedTotal: 0, projectionDrops: 0, events: []
        )
        page.responding = responding
        return page
    }
}
#endif
