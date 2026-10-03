import CryptoKit
import Foundation
import Observation

/// Reads hosts for the all-hosts view.
@MainActor
protocol FleetHostReading: AnyObject {
    /// The person's hosts, in their own order.
    var hosts: [FleetHost] { get }
    /// Reads a host that isn't the selected one. The selected host's comes
    /// from its live connection instead (`FleetStore.recordLive`).
    func read(_ hostID: UUID, avatars: FleetAvatarFolder) async throws -> FleetSnapshot
    /// Makes this host the one the app works with.
    func select(_ hostID: UUID)
    /// Demo hosts can be listed but not opened.
    func canOpen(_ hostID: UUID) -> Bool
    /// Opens the host's connection ahead of a switch, when the app keeps them.
    func keepConnected(_ hostID: UUID) async
    /// Saves a pin for a host that isn't selected. False when it can't be saved.
    func setPinned(_ pinned: Bool, hostID: UUID, profileID: String) -> Bool
    /// Saves an agent's section or hidden state on a host that isn't selected.
    func setPlacement(_ placement: AgentListPlacement, hostID: UUID, profileID: String) async throws
    /// Reaches every host for Fleet settings. None hides it.
    func maintenance() -> (any FleetMaintenanceConnecting)?
    /// A host that isn't the selected one: its agents' usage and its plans and limits.
    func usage(_ hostID: UUID, name: String, days: Int, refresh: Bool) async -> HostUsage
}

extension FleetHostReading {
    func maintenance() -> (any FleetMaintenanceConnecting)? { nil }
    func keepConnected(_ hostID: UUID) async {}
    func setPlacement(_ placement: AgentListPlacement, hostID: UUID, profileID: String) async throws {
        throw WorkspaceClientError.unavailable(.unsupportedHost)
    }
}

/// Why a host couldn't be read, in words for the list.
struct FleetReadError: Error, Equatable {
    let message: String
}

/// Agents' pictures for the all-hosts view, kept in the fleet's own folder so
/// they stay when the app switches hosts.
struct FleetAvatarFolder: Sendable {
    let directory: URL

    func url(for fileName: String?) -> URL? {
        AvatarFileURL.resolve(fileName: fileName, in: directory)
    }

    /// Saves a picture under its own hash and returns the file name.
    func store(_ data: Data, fileExtension: String) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = fileExtension.allSatisfy { $0.isLetter || $0.isNumber } && !fileExtension.isEmpty
            ? fileExtension.lowercased() : "png"
        let name = "agent-\(digest).\(ext)"
        let destination = directory.appending(path: name, directoryHint: .notDirectory)
        guard !FileManager.default.fileExists(atPath: destination.bighelpFileSystemPath) else { return name }
        let protector = BighelpLocalFileProtector()
        try protector.prepareDirectory(directory, protection: .privateVisual, fileManager: .default)
        try protector.write(data, to: destination, protection: .privateVisual)
        return name
    }

    /// An agent's picture sent as a `data:` URL.
    func store(_ avatar: AgentAvatar) -> String? {
        guard let separator = avatar.dataURL.range(of: ";base64,"),
              let data = Data(base64Encoded: String(avatar.dataURL[separator.upperBound...])),
              data.count == avatar.byteCount, data.count <= 4 * 1_024 * 1_024 else { return nil }
        let type = avatar.mimeType.split(separator: "/").last.map(String.init) ?? "png"
        return try? store(data, fileExtension: type == "jpeg" ? "jpg" : type)
    }
}

/// The all-hosts view's data: every host's agents, chats and scheduled tasks.
/// The selected host is live; the others are read when the view shows (at
/// most once a minute) and kept on this device in between.
@MainActor
@Observable
final class FleetStore {
    private(set) var hosts: [FleetHost] = []
    private(set) var snapshots: [UUID: FleetSnapshot] = [:]
    private(set) var statuses: [UUID: FleetHostStatus] = [:]
    /// A tap waiting for its host to become the selected one.
    var pendingOpen: FleetPendingOpen?
    /// The order the person dragged pinned agents into, across hosts.
    private(set) var pinnedOrder: [String] = []

    /// The person's sections, in their order; empty ones too. This device's own.
    var sections: [FleetSection] = []
    /// Which section each group chat is in, by its list ID. Kept on this device.
    var groupSectionIDs: [String: String] = [:]
    /// Why the last section or hide change couldn't be saved.
    var placementError: String?

    @ObservationIgnored let avatars: FleetAvatarFolder
    @ObservationIgnored let reader: any FleetHostReading
    @ObservationIgnored let directory: URL
    /// Saves the selected host's placements through its own agent list.
    @ObservationIgnored var selectedHostPlacementWriter: ((AgentListPlacement, String) async throws -> Void)?
    /// Sections deleted here whose members are still being unfiled.
    @ObservationIgnored var pendingSectionDeletes: [String: UUID] = [:]
    /// When each agent's placement was last saved from here.
    @ObservationIgnored var placementWrites: [String: Date] = [:]
    @ObservationIgnored private var reads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingSaves: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Live pictures already copied in, by their file on the host's own folder.
    @ObservationIgnored private var copiedAvatars: [String: String] = [:]
    @ObservationIgnored private let saveDelay: Duration
    /// Fleet settings, kept while the app runs so updates carry on after its page closes.
    @ObservationIgnored private var maintenanceStore: FleetMaintenanceStore?

    /// How long a read host counts as current.
    static let freshness: TimeInterval = 60

    static var storageRoot: URL {
        URL.applicationSupportDirectory.appending(path: "BighelpFleet", directoryHint: .isDirectory)
    }

    init(reader: any FleetHostReading, directory: URL = FleetStore.storageRoot, saveDelay: Duration = .seconds(2)) {
        self.reader = reader
        self.directory = directory
        self.saveDelay = saveDelay
        avatars = FleetAvatarFolder(directory: directory.appending(path: "avatars", directoryHint: .isDirectory))
        hosts = reader.hosts
        if let saved = try? Data(contentsOf: pinnedOrderURL),
           let order = try? JSONDecoder().decode([String].self, from: saved) {
            pinnedOrder = Array(order.prefix(64))
        }
        for host in hosts {
            if let saved = try? Data(contentsOf: snapshotURL(host.id)),
               let snapshot = try? JSONDecoder().decode(FleetSnapshot.self, from: saved) {
                snapshots[host.id] = snapshot
            }
        }
        loadSections()
    }

    var selectedHostID: UUID? { hosts.first(where: \.isSelected)?.id }
    /// Host names are only worth showing with more than one host.
    var showsHostNames: Bool { hosts.count > 1 }

    func hostName(_ id: UUID) -> String { hosts.first { $0.id == id }?.name ?? "Host" }
    func canOpen(_ hostID: UUID) -> Bool { reader.canOpen(hostID) }
    func select(_ hostID: UUID) { reader.select(hostID); syncHosts() }

    /// Fleet settings for every host; nil when the hosts can't be reached for it.
    func maintenance() -> FleetMaintenanceStore? {
        if let maintenanceStore { return maintenanceStore }
        guard let connector = reader.maintenance() else { return nil }
        let store = FleetMaintenanceStore(connector: connector)
        maintenanceStore = store
        return store
    }

    /// Follows the configured hosts: a removed host's saved snapshot goes too.
    func syncHosts() {
        let current = reader.hosts
        if current != hosts { hosts = current }
        let ids = Set(current.map(\.id))
        let removed = snapshots.keys.filter { !ids.contains($0) }
        for id in removed {
            snapshots[id] = nil
            statuses[id] = nil
            reads[id]?.cancel()
            reads[id] = nil
            try? FileManager.default.removeItem(at: snapshotURL(id))
        }
        if !removed.isEmpty { removeUnusedAvatars() }
    }

    /// Pictures no remaining host's agents use.
    private func removeUnusedAvatars() {
        let used = Set(snapshots.values.flatMap(\.agents).compactMap(\.avatarFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: avatars.directory.bighelpFileSystemPath)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: avatars.directory.appending(path: file, directoryHint: .notDirectory))
        }
        copiedAvatars = copiedAvatars.filter { used.contains($0.value) }
    }

    // MARK: Reading

    /// The selected host's agents, chats and tasks, straight from the app.
    func recordLive(_ snapshot: FleetSnapshot, hostID: UUID) {
        guard hosts.contains(where: { $0.id == hostID }) else { return }
        let snapshot = fencedPlacements(snapshot, hostID: hostID)
        var unchanged = snapshots[hostID]
        unchanged?.refreshedAt = snapshot.refreshedAt
        statuses[hostID] = .ready
        guard unchanged != snapshot else { return }
        snapshots[hostID] = snapshot
        scheduleSave(hostID)
        adoptSections()
    }

    /// A live agent's picture, copied in once.
    func liveAvatarFile(from source: URL?) -> String? {
        guard let source else { return nil }
        let key = source.bighelpFileSystemPath
        if let copied = copiedAvatars[key] { return copied }
        guard let data = try? Data(contentsOf: source), data.count <= 4 * 1_024 * 1_024,
              let name = try? avatars.store(data, fileExtension: source.pathExtension) else { return nil }
        copiedAvatars[key] = name
        return name
    }

    /// Reads the other hosts. Skips ones read in the last minute unless forced.
    func refresh(force: Bool = false) {
        syncHosts()
        for host in hosts where !host.isSelected && reads[host.id] == nil {
            if !force, statuses[host.id] == .ready, let snapshot = snapshots[host.id],
               Date().timeIntervalSince(snapshot.refreshedAt) < Self.freshness {
                // Read recently, but its connection may have closed since.
                let id = host.id
                Task { [reader] in await reader.keepConnected(id) }
                continue
            }
            statuses[host.id] = .loading
            let id = host.id
            reads[id] = Task { [weak self] in
                guard let self else { return }
                let outcome: Result<FleetSnapshot, any Error>
                do { outcome = .success(try await reader.read(id, avatars: avatars)) }
                catch { outcome = .failure(error) }
                reads[id] = nil
                guard !Task.isCancelled else {
                    if statuses[id] == .loading { statuses[id] = .idle }
                    return
                }
                switch outcome {
                case .success(let snapshot):
                    // Selected while it was read: its live data wins.
                    if selectedHostID != id {
                        snapshots[id] = fencedPlacements(snapshot, hostID: id)
                        scheduleSave(id)
                        adoptSections()
                    }
                    statuses[id] = .ready
                case .failure(let error as FleetReadError):
                    statuses[id] = .unreachable(error.message)
                case .failure(is CancellationError):
                    statuses[id] = .idle
                case .failure:
                    statuses[id] = .unreachable("Couldn't reach this host.")
                }
            }
        }
    }

    /// The app is leaving the foreground: stop reading other hosts.
    func cancelReads() {
        for task in reads.values { task.cancel() }
        reads.removeAll()
        for (id, status) in statuses where status == .loading { statuses[id] = .idle }
    }

    func isReading(_ hostID: UUID) -> Bool { statuses[hostID] == .loading }

    /// Waits for the reads in flight (pull to refresh, tests).
    func waitForReads() async {
        for task in Array(reads.values) { await task.value }
    }

    /// Waits for pending snapshot saves (tests).
    func waitForSaves() async { await saveTask?.value }

    // MARK: Lists

    /// Every agent, the most recently active first.
    func agents(on hostID: UUID? = nil) -> [FleetAgent] {
        let all = hosts.filter { hostID == nil || $0.id == hostID }.flatMap { snapshots[$0.id]?.agents ?? [] }
        return all.sorted { lhs, rhs in
            let left = latestChat(for: lhs)?.updatedAt, right = latestChat(for: rhs)?.updatedAt
            if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func agent(hostID: UUID, profileID: String) -> FleetAgent? {
        snapshots[hostID]?.agents.first { $0.profileID == profileID }
    }

    func latestChat(for agent: FleetAgent) -> FleetChat? {
        snapshots[agent.hostID]?.chats
            .filter { $0.profileID == agent.profileID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Every direct chat, the newest first.
    func chats(on hostID: UUID? = nil) -> [FleetChat] {
        hosts.filter { hostID == nil || $0.id == hostID }
            .flatMap { snapshots[$0.id]?.chats ?? [] }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Every scheduled task, the next to run first.
    func tasks(on hostID: UUID? = nil) -> [FleetTask] {
        hosts.filter { hostID == nil || $0.id == hostID }
            .flatMap { snapshots[$0.id]?.tasks ?? [] }
            .sorted { lhs, rhs in
                if (lhs.status == .active) != (rhs.status == .active) { return lhs.status == .active }
                return (lhs.nextRun ?? .distantFuture) < (rhs.nextRun ?? .distantFuture)
            }
    }

    // MARK: Pinned

    /// Pinned agents in the person's order; ones not arranged yet follow, latest chat first.
    func pinnedAgents(limit: Int = 8) -> [FleetAgent] {
        let rank = Dictionary(pinnedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = agents().filter(\.isPinned).enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }
        return Array(pinned.map(\.element).prefix(limit))
    }

    /// Pins or unpins an agent from the all-hosts view and shows it at once. The
    /// selected host's agent list saves its own pins (the app does that first);
    /// another host's are saved for it by the reader.
    func setPinned(_ agent: FleetAgent, _ pinned: Bool) {
        guard var snapshot = snapshots[agent.hostID],
              let index = snapshot.agents.firstIndex(where: { $0.id == agent.id }),
              snapshot.agents[index].isPinned != pinned else { return }
        if agent.hostID != selectedHostID {
            guard reader.setPinned(pinned, hostID: agent.hostID, profileID: agent.profileID) else { return }
        }
        snapshot.agents[index].isPinned = pinned
        snapshots[agent.hostID] = snapshot
        scheduleSave(agent.hostID)
        if !pinned, pinnedOrder.contains(agent.id) {
            pinnedOrder.removeAll { $0 == agent.id }
            savePinnedOrder()
        }
    }

    /// Saves a dragged order; agents it doesn't name keep their places after it.
    func reorderPinned(_ ids: [String]) {
        let order = Array((ids + pinnedOrder.filter { !ids.contains($0) }).prefix(64))
        guard order != pinnedOrder else { return }
        pinnedOrder = order
        savePinnedOrder()
    }

    private func savePinnedOrder() {
        let protector = BighelpLocalFileProtector()
        try? protector.prepareDirectory(directory, protection: .privateVisual, fileManager: .default)
        if let data = try? JSONEncoder().encode(pinnedOrder) {
            try? data.write(to: pinnedOrderURL, options: [.atomic, .completeFileProtection])
        }
    }

    /// Changes one host's snapshot from here (a placement), saved soon.
    func replaceSnapshot(_ snapshot: FleetSnapshot, hostID: UUID) {
        snapshots[hostID] = snapshot
        scheduleSave(hostID)
    }

    // MARK: Saving

    private var pinnedOrderURL: URL {
        directory.appending(path: "pinned-order.json", directoryHint: .notDirectory)
    }

    private func snapshotURL(_ id: UUID) -> URL {
        directory.appending(path: id.uuidString.lowercased() + ".json", directoryHint: .notDirectory)
    }

    /// Batches saves: live snapshots change while a reply streams.
    func scheduleSave(_ id: UUID) {
        pendingSaves.insert(id)
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            saveTask = nil
            let ids = pendingSaves
            pendingSaves.removeAll()
            let protector = BighelpLocalFileProtector()
            try? protector.prepareDirectory(directory, protection: .privateVisual, fileManager: .default)
            for id in ids {
                guard let snapshot = snapshots[id], let data = try? JSONEncoder().encode(snapshot) else { continue }
                try? data.write(to: snapshotURL(id), options: [.atomic, .completeFileProtection])
            }
        }
    }
}
