import Foundation

/// Coordinators own independent rows; ActivityKit owns one shared card.
@MainActor
final class BighelpActivityGroupDriver: BighelpLiveActivityDriving {
    typealias State = LoopdySessionActivityAttributes.ContentState
    private let underlying: any BighelpLiveActivityDriving
    private let loadInfos: () -> [String: BighelpActivitySessionInfo]
    private let saveInfos: ([String: BighelpActivitySessionInfo]) -> Void
    private var lastSystemState: State?
    private var physicalID: String?
    private var endingIDs = Set<String>()
    private var virtualIDs: [String: String] = [:]
    private var attributes: [String: LoopdySessionActivityAttributes] = [:]
    private var rows: [String: BighelpActivitySession] = [:]
    private var displayedIDs = Set<String>()
    private var hiddenActiveKeys = Set<String>()
    private var pendingLocalRows = Set<String>()
    private var hiddenActiveCount: Int { hiddenActiveKeys.count }
    private var writeTail: Task<Void, Never>?
    private var revision = 0
    private var nextRowRevision = 0
    /// Called with the physical card's ID when it ends or is dismissed, so its push address can be removed.
    var onPhysicalEnded: (@MainActor (String) -> Void)?

    init(underlying: any BighelpLiveActivityDriving,
         loadInfos: @escaping () -> [String: BighelpActivitySessionInfo] = BighelpActivitySessionInfo.load,
         saveInfos: @escaping ([String: BighelpActivitySessionInfo]) -> Void = BighelpActivitySessionInfo.save) {
        self.underlying = underlying; self.loadInfos = loadInfos; self.saveInfos = saveInfos
        refresh()
    }
    static func physicalID(_ virtualID: String) -> String? {
        let parts = virtualID.components(separatedBy: "|row|")
        return parts.count == 2 && !parts[0].isEmpty ? parts[0] : nil
    }
    static func rowRevision(_ virtualID: String) -> Int? {
        guard physicalID(virtualID) != nil, let suffix = virtualID.components(separatedBy: "|row|").last,
              let prefix = suffix.split(separator: "-").first, let value = Int(prefix), value > 0 else { return nil }
        return value
    }
    private func session(_ id: String) -> String? {
        guard Self.physicalID(id) == physicalID else { return nil }
        return virtualIDs.first(where: { $0.value == id })?.key
    }
    private func clear() {
        physicalID = nil; rows.removeAll(); attributes.removeAll(); virtualIDs.removeAll()
        displayedIDs.removeAll(); hiddenActiveKeys.removeAll(); pendingLocalRows.removeAll(); lastSystemState = nil
    }
    private func refresh() {
        // A system read can lag an in-flight local write. Reconcile remote state
        // once the serial write has finished, rather than undoing a pending row.
        guard writeTail == nil else { return }
        guard let snapshot = underlying.existingActivities().first(where: {
            $0.state.sessions != nil && !endingIDs.contains($0.nativeActivityID)
        }) else { clear(); return }
        guard lastSystemState != snapshot.state || physicalID != snapshot.nativeActivityID else { return }
        if physicalID != snapshot.nativeActivityID { clear() }
        lastSystemState = snapshot.state
        physicalID = snapshot.nativeActivityID
        var saved = loadInfos()
        nextRowRevision = max(nextRowRevision, saved.values.compactMap { $0.virtualID.flatMap(Self.rowRevision) }.max() ?? 0)
        let allVisible = snapshot.state.sessions ?? []
        let activeKeys = Set(snapshot.state.activeRows ?? allVisible.filter { !$0.phase.isTerminal }.map { BighelpActivitySession.membershipKey($0.id) })
        let dismissed = Set(saved.filter { $0.value.dismissed == true && $0.value.virtualID.flatMap(Self.physicalID) == physicalID }.keys)
        let visible = allVisible.filter { !dismissed.contains($0.id) }
        let seenKeys = Set(visible.map { BighelpActivitySession.membershipKey($0.id) })
        pendingLocalRows = pendingLocalRows.filter { !activeKeys.contains(BighelpActivitySession.membershipKey($0)) }
        displayedIDs = Set(visible.map(\.id)).union(pendingLocalRows)
        hiddenActiveKeys = activeKeys.subtracting(seenKeys).subtracting(dismissed.map(BighelpActivitySession.membershipKey))
        // Ownership can be retained for hidden rows, but only the explicit
        // server membership may report them as active after restoration.
        for (id, info) in saved where info.virtualID.flatMap(Self.physicalID) == physicalID
            && info.dismissed != true && activeKeys.contains(BighelpActivitySession.membershipKey(id)) {
            if let state = info.state { rows[id] = .init(id: id, state: state) }
            virtualIDs[id] = info.virtualID; attributes[id] = info.attributes
        }
        for row in visible {
            rows[row.id] = row
            virtualIDs[row.id] = virtualIDs[row.id] ?? saved[row.id]?.virtualID ?? "\(snapshot.nativeActivityID)|row|\(row.id)"
            attributes[row.id] = saved[row.id]?.attributes ?? .make(sessionID: row.id, sessionTitle: "Chat",
                agentID: "agent", agentName: "Your agent")
            if var info = saved[row.id] { info.state = row.state; saved[row.id] = info }
        }
        for id in rows.keys where !displayedIDs.contains(id) && !hiddenActiveKeys.contains(BighelpActivitySession.membershipKey(id)) {
            rows[id] = nil; virtualIDs[id] = nil; attributes[id] = nil
        }
        saveInfos(saved)
    }

    func start(attributes value: LoopdySessionActivityAttributes, state: State) throws -> String {
        refresh()
        let row = BighelpActivitySession(id: value.sessionID, state: state)
        if physicalID == nil {
            let content = BighelpActivitySession.aggregate([row], timestamp: state.timestamp)
            // A failed foreground request must remain retryable.
            physicalID = try underlying.start(attributes: value, state: content)
            lastSystemState = content
            // Upgrade old per-chat cards only after the shared card was accepted.
            let legacy = underlying.existingActivities().filter {
                $0.nativeActivityID != physicalID && $0.state.sessions == nil && $0.attributes.sessionID.hasPrefix("native-")
            }
            for old in legacy { Task { await underlying.dismiss(id: old.nativeActivityID, state: old.state) } }
        }
        guard let physicalID else { preconditionFailure("A successful start supplies an activity ID") }
        nextRowRevision = max(nextRowRevision + 1, Int(Date().timeIntervalSince1970 * 1_000_000))
        let id = "\(physicalID)|row|\(nextRowRevision)-\(UUID().uuidString.lowercased())"
        virtualIDs[value.sessionID] = id; attributes[value.sessionID] = value
        pendingLocalRows.insert(value.sessionID)
        admit(row)
        scheduleWrite()
        return id
    }
    private func admit(_ row: BighelpActivitySession) {
        if !displayedIDs.contains(row.id), rows[row.id]?.phase.isTerminal == false {
            hiddenActiveKeys.remove(BighelpActivitySession.membershipKey(row.id))
        }
        rows[row.id] = row; displayedIDs.insert(row.id)
        var saved = loadInfos()
        if saved.count >= 128 { saved = saved.filter { rows[$0.key] != nil } }
        if let attributes = attributes[row.id] {
            saved[row.id] = .init(attributes: attributes, title: saved[row.id]?.title ?? "Chat",
                virtualID: virtualIDs[row.id], state: row.state)
            saveInfos(saved)
        }
    }
    func update(id: String, state: State) async {
        refresh()
        guard let key = session(id) else { return }
        admit(.init(id: key, state: state))
        scheduleWrite()
        await writeTail?.value
    }
    func end(id: String, state: State) async { await update(id: id, state: state) }
    func dismiss(id: String, state: State) async {
        refresh()
        guard let key = session(id) else { return }
        hiddenActiveKeys.remove(BighelpActivitySession.membershipKey(key))
        pendingLocalRows.remove(key)
        var saved = loadInfos()
        if var info = saved[key] { info.dismissed = true; saved[key] = info; saveInfos(saved) }
        rows[key] = nil; attributes[key] = nil; virtualIDs[key] = nil; displayedIDs.remove(key)
        scheduleWrite(dismiss: rows.isEmpty && hiddenActiveCount == 0)
        await writeTail?.value
    }
    private func scheduleWrite(dismiss: Bool = false) {
        guard let id = physicalID else { return }
        revision += 1
        let expected = revision
        let previous = writeTail
        writeTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.physicalID == id, self.revision == expected else { return }
            let visible = self.rows.values.filter { self.displayedIDs.contains($0.id) }
            var state = BighelpActivitySession.aggregate(Array(visible), timestamp: visible.map(\.timestamp).max() ?? 1)
            state.activeCount = (state.activeCount ?? 0) + self.hiddenActiveCount
            state.activeRows = Array(Set(state.activeRows ?? []).union(self.hiddenActiveKeys)).sorted()
            if state.phase.isTerminal && (state.activeCount ?? 0) > 0 {
                state = .init(phase: .thinking, currentAction: "", progress: 0, completedSteps: 0,
                    activeSubagentCount: 0, latestTool: nil, timestamp: state.timestamp,
                    sessions: state.sessions, activeCount: state.activeCount, activeRows: state.activeRows)
            }
            self.lastSystemState = state
            if state.activeCount == 0 {
                // Detach before awaiting ActivityKit. A new turn must never reuse
                // the card whose irreversible end is already in flight.
                self.endingIDs.insert(id); self.clear()
                self.onPhysicalEnded?(id)
                if dismiss { await self.underlying.dismiss(id: id, state: state) }
                else { await self.underlying.end(id: id, state: state) }
                self.endingIDs.remove(id)
            } else { await self.underlying.update(id: id, state: state) }
            if self.revision == expected { self.writeTail = nil }
        }
    }
    func invalidate(id virtualID: String) async {
        guard let id = physicalID, Self.physicalID(virtualID) == id else { return }
        let state = lastSystemState ?? BighelpActivitySession.aggregate([], timestamp: 1)
        let pending = writeTail
        revision += 1; writeTail = nil; endingIDs.insert(id); clear()
        onPhysicalEnded?(id)
        await pending?.value
        await underlying.dismiss(id: id, state: state)
        endingIDs.remove(id)
    }

    func existingActivities() -> [BighelpLiveActivitySnapshot] {
        refresh()
        guard let physicalID else { return [] }
        return rows.values.compactMap { row in
            guard let attributes = attributes[row.id], let id = virtualIDs[row.id], !row.phase.isTerminal else { return nil }
            return .init(nativeActivityID: id, attributes: attributes, state: row.state,
                         pushToken: underlying.currentPushToken(id: physicalID))
        }
    }
    func currentPushToken(id: String) -> Data? {
        guard session(id) != nil, let physicalID else { return nil }
        return underlying.currentPushToken(id: physicalID)
    }
    func pushTokenUpdates(id: String) -> AsyncStream<Data> {
        guard session(id) != nil, let physicalID else { return AsyncStream { $0.finish() } }
        return underlying.pushTokenUpdates(id: physicalID)
    }
}
