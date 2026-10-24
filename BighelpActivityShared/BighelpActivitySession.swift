import Foundation

/// Only opaque coordinates and public status travel through the push service.
/// Names and chat titles are resolved from the phone's shared metadata.
struct BighelpActivitySession: Codable, Hashable, Sendable, Identifiable {
    typealias Phase = LoopdySessionActivityAttributes.ContentState.Phase
    let id: String
    var phase: Phase
    var timestamp: Int
    var activeSubagentCount: Int = 0
    var latestTool: String? = nil

    static func membershipKey(_ id: String) -> String { String(id.suffix(16)) }

    var priority: Int { phase == .waiting ? 0 : phase == .failed ? 2 : phase == .completed ? 3 : 1 }
    var state: LoopdySessionActivityAttributes.ContentState {
        .init(phase: phase, currentAction: "", progress: 0, completedSteps: 0,
              activeSubagentCount: activeSubagentCount, latestTool: latestTool, timestamp: timestamp)
    }
    init(id: String, phase: Phase, timestamp: Int, activeSubagentCount: Int = 0, latestTool: String? = nil) {
        self.id = id; self.phase = phase; self.timestamp = timestamp
        self.activeSubagentCount = activeSubagentCount; self.latestTool = latestTool
    }
    init(id: String, state: LoopdySessionActivityAttributes.ContentState) {
        self.init(id: id, phase: state.phase, timestamp: state.timestamp,
                  activeSubagentCount: state.activeSubagentCount, latestTool: state.latestTool)
    }
    static func aggregate(_ rows: [Self], timestamp: Int) -> LoopdySessionActivityAttributes.ContentState {
        let ordered = rows.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        let running = ordered.filter { !$0.phase.isTerminal }
        let phase: Phase = running.first?.phase ?? (rows.contains { $0.phase == .failed } ? .failed : .completed)
        return .init(phase: phase, currentAction: "", progress: 0, completedSteps: 0, activeSubagentCount: 0,
                     latestTool: nil, timestamp: timestamp, sessions: Array(ordered.prefix(5)), activeCount: running.count, activeRows: running.map { membershipKey($0.id) }.sorted())
    }
}

struct BighelpActivitySessionInfo: Codable, Sendable {
    let attributes: LoopdySessionActivityAttributes
    var title: String
    var virtualID: String? = nil
    var state: LoopdySessionActivityAttributes.ContentState? = nil
    var dismissed: Bool? = nil

    static func load() -> [String: Self] {
        guard let data = defaults?.data(forKey: key), data.count < 262_144 else { return [:] }
        return (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
    }
    static func save(_ infos: [String: Self]) {
        guard infos.count <= 128, let data = try? JSONEncoder().encode(infos), data.count < 262_144 else { return }
        defaults?.set(data, forKey: key)
    }
    private static let key = "loopdy.activity.session-info.v1"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: BighelpWidgetSnapshot.appGroup) }
}
