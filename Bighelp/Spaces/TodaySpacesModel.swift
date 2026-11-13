import Foundation
import Observation

/// One space on Today, with the computer and bot it belongs to.
struct TodaySpace: Identifiable, Equatable, Sendable {
    /// Unique across computers, the same across launches and reconnects, and safe in accessibility
    /// ids and the layout's file: `id(scope:key:)`. Today's grid knows the panel by it too.
    let id: String
    /// As the computer said, with this phone's unconfirmed changes on top.
    let space: Space
    let scope: String
    let hostKey: String
    let computerName: String
    /// The bot's name, or its id when the computer's bots aren't known.
    let botName: String
    /// False while its computer isn't connected: the panel says "Not connected", the rest still draws.
    let isConnected: Bool

    /// The computer's cache scope and the space's key, hashed (a scope can hold any character).
    static func id(scope: String, key: String) -> String {
        "space-" + String(SpacesWire.sha256(scope + "\n" + key).prefix(24))
    }
}

/// How each computer's spaces read, for "Update the plugin on <computer>" and "Not connected".
struct TodaySpacesComputerStatus: Identifiable, Equatable, Sendable {
    var id: String { scope }
    let scope: String
    let hostKey: String
    let name: String
    let phase: SpacesPhase
    let isConnected: Bool
    let lastLoaded: Date?
}

/// Today's spaces from every computer, in one order: by position, then computer, then title.
/// Each computer's spaces live in its own `SpacesStore`, kept by cache scope; this model only
/// reads them together and sends each action to the space's own computer.
@MainActor
@Observable
final class TodaySpacesModel {
    static let shared = TodaySpacesModel()

    /// By cache scope.
    private(set) var stores: [String: SpacesStore] = [:]
    private(set) var isRefreshing = false
    private var computers: [ComputerInfo] = []

    private struct ComputerInfo: Equatable {
        let hostKey: String
        let scope: String
        let name: String
        let bots: [SpacesBot]
        let isConnected: Bool
    }

    @ObservationIgnored private let source: @MainActor () -> [SpacesComputer]
    @ObservationIgnored private let current: @MainActor () -> SpacesComputer?
    @ObservationIgnored private let pages: @MainActor (String) -> HTMLAppsAPI?
    @ObservationIgnored private let hostKeys: @MainActor () -> Set<String>?
    @ObservationIgnored private let cacheFolder: URL?
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var reading: Task<Void, Never>?

    init(computers: @escaping @MainActor () -> [SpacesComputer] = { SpacesHost.computers() },
         current: @escaping @MainActor () -> SpacesComputer? = { SpacesHost.current() },
         pages: @escaping @MainActor (String) -> HTMLAppsAPI? = { SpacesHost.pages($0) },
         hostKeys: @escaping @MainActor () -> Set<String>? = { SpacesHost.hostKeys() },
         cacheFolder: URL? = SpacesStore.defaultCacheFolder,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        source = computers
        self.current = current
        self.pages = pages
        self.hostKeys = hostKeys
        self.cacheFolder = cacheFolder
        self.clock = clock
    }

    // MARK: What Today shows

    /// Every live space, hidden ones too, in Today's order (Edit Today's list).
    var items: [TodaySpace] {
        var rows: [(item: TodaySpace, computer: Int)] = []
        for (order, computer) in computers.enumerated() {
            guard let store = stores[computer.scope] else { continue }
            let names = Dictionary(computer.bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            for space in store.spaces where space.state == .live {
                let item = TodaySpace(id: TodaySpace.id(scope: computer.scope, key: space.key), space: space,
                                      scope: computer.scope, hostKey: computer.hostKey, computerName: computer.name,
                                      botName: names[space.agentID] ?? space.agentID, isConnected: computer.isConnected)
                rows.append((item, order))
            }
        }
        return rows.sorted { lhs, rhs in
            if lhs.item.space.position != rhs.item.space.position { return lhs.item.space.position < rhs.item.space.position }
            if lhs.computer != rhs.computer { return lhs.computer < rhs.computer }
            switch lhs.item.space.title.localizedStandardCompare(rhs.item.space.title) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.item.id < rhs.item.id
            }
        }.map { $0.item }
    }

    /// The panels Today draws.
    var shown: [TodaySpace] { items.filter { !$0.space.hidden } }

    var hiddenCount: Int { items.filter { $0.space.hidden }.count }

    /// Computer names show beside panels only when they come from two or more computers.
    var showsComputerNames: Bool { Set(items.map(\.scope)).count >= 2 }

    var statuses: [TodaySpacesComputerStatus] {
        computers.compactMap { computer in
            guard let store = stores[computer.scope] else { return nil }
            return TodaySpacesComputerStatus(scope: computer.scope, hostKey: computer.hostKey, name: computer.name,
                                             phase: store.phase, isConnected: computer.isConnected,
                                             lastLoaded: store.lastLoaded)
        }
    }

    // MARK: Reading

    /// Today's `.task` while it shows and the app is active: reads every computer now, then every
    /// minute. Coming back to the app starts it again, which reads at once.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: SpacesWire.refreshInterval)
        }
    }

    /// Reads every connected computer at once, side by side. A read already under way is joined.
    func refresh() async {
        if let reading {
            await reading.value
            return
        }
        let reads = Task { await readAll() }
        reading = reads
        await reads.value
        reading = nil
    }

    private func readAll() async {
        let list = sync()
        isRefreshing = true
        let reads = list.compactMap { computer in
            stores[computer.scope].map { store in Task<Void, Never> { await store.load(computer) } }
        }
        for read in reads { await read.value }
        isRefreshing = false
    }

    /// The computers as the app knows them now: a store for each new scope (with what the phone
    /// kept), and none for a computer that's gone. A computer missing from the list only for now (no
    /// scope while it reconnects or the selection moves) keeps its store, with its waiting changes:
    /// a store goes when its computer leaves the registry, or the same computer shows under another scope.
    @discardableResult
    private func sync() -> [SpacesComputer] {
        var seen = Set<String>()
        let list = source().filter { seen.insert($0.scope).inserted }
        for computer in list where stores[computer.scope] == nil {
            stores[computer.scope] = SpacesStore(scope: computer.scope, hostKey: computer.hostKey,
                                                 cacheFolder: cacheFolder, clock: clock)
        }
        let known = hostKeys()
        let listed = Set(list.map(\.hostKey))
        for (scope, store) in stores where !seen.contains(scope) {
            let isGone = known.map { !$0.contains(store.hostKey) } ?? true
            guard isGone || listed.contains(store.hostKey) else { continue }
            store.retire()
            stores[scope] = nil
        }
        let info = list.map {
            ComputerInfo(hostKey: $0.hostKey, scope: $0.scope, name: $0.name, bots: $0.bots, isConnected: $0.api != nil)
        }
        if info != computers { computers = info }
        return list
    }

    /// A removed computer: its panels leave Today and its copy on this phone is erased. The host
    /// registry calls it from `remove(_:)`, with the saved scope when it has one. Nothing else
    /// removes a computer's spaces.
    func forget(hostKey: String, scope: String?) {
        var scopes = Set(stores.filter { $0.value.hostKey == hostKey }.keys)
        if let scope { scopes.insert(scope) }
        for scope in scopes {
            let store = stores.removeValue(forKey: scope)
            store?.retire()
            guard let cacheFolder else { continue }
            // A write already under way finishes first, so it can't bring the file back.
            Task {
                await store?.savedToDisk()
                SpacesCacheFile.erase(scope: scope, folder: cacheFolder)
            }
        }
        computers.removeAll { $0.hostKey == hostKey }
    }

    /// The connection `HTMLAppScreen` opens a space's page through: the space's own computer,
    /// read each time it's asked, since bighelp reconnects every time it comes back.
    func pageConnection(_ item: TodaySpace) -> @MainActor () -> (scope: String, api: HTMLAppsAPI)? {
        let scope = item.scope
        let pages = self.pages
        return { pages(scope).map { (scope: scope, api: $0) } }
    }

    // MARK: Acting on a space

    private func locate(_ id: String) throws(SpacesError) -> (store: SpacesStore, item: TodaySpace, api: SpacesAPI?) {
        guard let item = items.first(where: { $0.id == id }), let store = stores[item.scope] else { throw .notFound }
        // The connection as it is now: bighelp reconnects every time it comes back.
        return (store, item, source().first { $0.scope == item.scope }?.api)
    }

    func resize(_ id: String, to size: SpaceSize) async throws(SpacesError) {
        let target = try locate(id)
        try await target.store.change(target.item.space.key, SpaceChanges(size: size), api: target.api)
    }

    /// Hidden spaces keep updating; only Today stops drawing them.
    func setHidden(_ id: String, _ hidden: Bool) async throws(SpacesError) {
        let target = try locate(id)
        try await target.store.change(target.item.space.key, SpaceChanges(hidden: hidden), api: target.api)
    }

    /// Today's grid and Edit: the change shows before this returns (a drag or a picker never draws
    /// the old value for a frame), then goes to the space's computer. A refusal is undone in its
    /// store. The task ends when the computer answered.
    @discardableResult
    func changeNow(_ id: String, _ changes: SpaceChanges) -> Task<Void, Never>? {
        guard let target = try? locate(id), target.store.stage(changes, for: target.item.space.key),
              let api = target.api else { return nil }
        let store = target.store
        let key = target.item.space.key
        return Task { try? await store.send(key, api: api) }
    }

    /// Update now, and a stopped panel's Try again.
    func runNow(_ id: String) async throws(SpacesError) -> SpaceRefreshRun {
        let target = try locate(id)
        return try await target.store.runNow(target.item.space.key, api: target.api)
    }

    /// Stops its routine and removes it and its page from the computer.
    func delete(_ id: String) async throws(SpacesError) {
        let target = try locate(id)
        try await target.store.delete(target.item.space.key, api: target.api)
    }

    /// The person's new order (Edit Today's whole list; ids left out keep their order after the
    /// rest). Every space gets a place 1,024 apart, and only those whose place changed are sent,
    /// each to its own computer. The new places show before this returns, so a drag never jumps
    /// back for a frame; the task ends when every computer answered.
    @discardableResult
    func reorder(_ ids: [String]) -> Task<Void, Never> {
        let current = items
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = ids.compactMap { byID.removeValue(forKey: $0) }
        ordered += current.filter { byID[$0.id] != nil }
        var moved: [(store: SpacesStore, key: String, scope: String)] = []
        for (index, item) in ordered.enumerated() {
            let position = Double(index + 1) * SpacesWire.positionStep
            guard item.space.position != position, let store = stores[item.scope],
                  store.stage(SpaceChanges(position: position), for: item.space.key) else { continue }
            moved.append((store, item.space.key, item.scope))
        }
        let apis = Dictionary(source().map { ($0.scope, $0.api) }, uniquingKeysWith: { first, _ in first })
        let sends = moved
        return Task {
            for scope in Set(sends.map { $0.scope }).sorted() {
                // A computer that isn't connected gets its places at its next read.
                guard let api = apis[scope] ?? nil else { continue }
                for move in sends where move.scope == scope {
                    try? await move.store.send(move.key, api: api)
                }
            }
        }
    }

    /// A chat's draft card: adds the draft on the computer in use, after every space on Today
    /// unless Today already has a place for it. With the draft as `get` read it, it shows at once.
    func add(agentID: String, spaceID: String, draftRevision: Int, size: SpaceSize?,
             preview: Space? = nil) async throws(SpacesError) -> Space {
        guard let computer = current() else { throw .unreachable }
        // Today may not have shown yet this run: know the computers (so the space shows on Today at
        // once) and read this one, so the new place comes after what's there.
        sync()
        let store: SpacesStore
        if let existing = stores[computer.scope] {
            store = existing
        } else {
            store = SpacesStore(scope: computer.scope, hostKey: computer.hostKey, cacheFolder: cacheFolder, clock: clock)
            stores[computer.scope] = store
        }
        if store.phase == .loading { await store.load(computer) }
        let last = items.map(\.space.position).filter { $0 < SpacesWire.maximumPositionMagnitude }.max() ?? 0
        return try await store.add(agentID: agentID, spaceID: spaceID, draftRevision: draftRevision, size: size,
                                   position: last + SpacesWire.positionStep, preview: preview, api: computer.api)
    }
}
