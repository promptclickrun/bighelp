import Foundation
import Observation

/// How one computer's spaces read last.
enum SpacesPhase: Equatable, Sendable {
    /// Not read yet on this run. What the phone kept may show meanwhile.
    case loading
    case ready
    /// The computer's plugin context doesn't list `native-spaces-v1`.
    case needsPluginUpdate
    /// Not connected, or the last read failed: what was read before stays.
    case unreachable
}

/// A change the computer hasn't confirmed: sent again, with the same `operationId`, until it answers.
/// Any change on top of it is a new request with a new `operationId` (`SpacesStore.stage`).
struct SpacesPendingChange: Codable, Equatable, Sendable {
    var changes: SpaceChanges
    var operationID: String
}

/// A delete the computer hasn't finished: no answer, not connected, or `schedules_unavailable` (the
/// space is off Today there, and Hermes still has its task). The space stays off Today on this phone,
/// and the same request goes again at each read until the computer answers it.
struct SpacesPendingDelete: Codable, Equatable, Sendable {
    let agentID: String
    let spaceID: String
    let operationID: String
}

/// The phone's copy of one computer's spaces (Caches), so Today draws at once and a computer that
/// isn't connected shows its last panels.
struct SpacesCacheFile: Codable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    var scope: String
    var lastLoaded: Date?
    /// Each space in the route's own shape (`Space.json`), read back as an answer is.
    var spaces: [[String: BighelpJSONValue]]
    var pending: [String: SpacesPendingChange]
    /// Optional, so a copy written before deletes waited reads too.
    var deleting: [String: SpacesPendingDelete]?

    static func url(scope: String, folder: URL) -> URL {
        folder.appendingPathComponent(SpacesWire.sha256(scope) + ".json")
    }

    /// Nil for a missing, oversized, unreadable or other computer's file.
    static func read(scope: String, folder: URL) -> SpacesCacheFile? {
        let url = url(scope: scope, folder: folder)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= SpacesWire.maximumCacheBytes,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SpacesCacheFile.self, from: data),
              file.version == currentVersion, file.scope == scope else { return nil }
        return file
    }

    /// Removes one computer's copy.
    static func erase(scope: String, folder: URL) {
        try? FileManager.default.removeItem(at: url(scope: scope, folder: folder))
    }

    /// Writes the copy whole or not at all. A copy too big for the limit keeps its spaces without
    /// their cards, which the next read brings back.
    static func write(_ file: SpacesCacheFile, folder: URL) {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(file) else { return }
        if data.count > SpacesWire.maximumCacheBytes {
            var lighter = file
            lighter.spaces = file.spaces.map { space in
                space.filter { !["card", "sizes", "cardUnreadable"].contains($0.key) }
            }
            guard let smaller = try? encoder.encode(lighter), smaller.count <= SpacesWire.maximumCacheBytes else { return }
            data = smaller
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(scope: file.scope, folder: folder), options: .atomic)
    }
}

/// One computer's spaces, kept by its cache scope (`WorkspaceAuthority.cacheScopeID`): a reconnect is
/// a new owner with the same scope, and the same store. A computer that isn't connected keeps what
/// was read last. Changes the person makes show at once and wait for the computer's word: a definite
/// refusal undoes them, no answer keeps them for the next time the computer answers.
@MainActor
@Observable
final class SpacesStore {
    nonisolated static let defaultCacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BighelpSpaces", isDirectory: true)

    let scope: String
    private(set) var hostKey: String
    /// What the computer said, with this phone's unconfirmed changes on top. Drafts too, when one
    /// was added from a chat before the computer answered.
    private(set) var spaces: [Space] = []
    private(set) var phase: SpacesPhase = .loading
    /// When a read last worked; nil before any did.
    private(set) var lastLoaded: Date?
    /// Changes the computer hasn't confirmed, by space key.
    private(set) var pending: [String: SpacesPendingChange] = [:]
    /// Deletes the computer hasn't finished, by space key. Those spaces never show meanwhile.
    private(set) var deleting: [String: SpacesPendingDelete] = [:]

    @ObservationIgnored private var confirmed: [Space] = []
    /// A newer read makes an older one's answer moot.
    @ObservationIgnored private var readGeneration = 0
    /// Counts what mutations did to `confirmed`, so a read that began before keeps their result.
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var changedAt: [String: Int] = [:]
    /// Mutation answers land in the order they were sent, per space.
    @ObservationIgnored private var sendCount = 0
    @ObservationIgnored private var acceptedSend: [String: Int] = [:]
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?
    /// Space keys with an update request on its way: one at a time per space.
    @ObservationIgnored private var sending: Set<String> = []
    @ObservationIgnored private var sendWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Set once the computer is removed: nothing is written to its copy on disk again.
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private let cacheFolder: URL?
    @ObservationIgnored private let clock: @MainActor () -> Date

    init(scope: String, hostKey: String, cacheFolder: URL? = SpacesStore.defaultCacheFolder,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.scope = scope
        self.hostKey = hostKey
        self.cacheFolder = cacheFolder
        self.clock = clock
        if let cacheFolder, let file = SpacesCacheFile.read(scope: scope, folder: cacheFolder) {
            var seen = Set<String>()
            confirmed = file.spaces.compactMap { json in
                guard let space = Space(json: json), seen.insert(space.key).inserted else { return nil }
                return space
            }
            pending = file.pending.filter { seen.contains($0.key) && !$0.value.changes.isEmpty }
            deleting = file.deleting ?? [:]
            lastLoaded = file.lastLoaded
            publish()
        }
    }

    /// `agentId/spaceId` → `cardsSha256` for every space whose cards the phone has.
    var knownCards: [String: String] {
        var known: [String: String] = [:]
        for space in confirmed where space.holdsCards {
            if let hash = space.cardsSHA256 { known[space.key] = hash }
        }
        return known
    }

    /// The space as the computer last said, without this phone's unconfirmed changes.
    func confirmedSpace(_ key: String) -> Space? { confirmed.first { $0.key == key } }

    // MARK: Reading

    /// Reads the computer's spaces for its bots. Not connected, or no bots known yet, the copy stays.
    func load(_ computer: SpacesComputer) async {
        hostKey = computer.hostKey
        guard let api = computer.api else {
            if phase != .needsPluginUpdate { phase = .unreachable }
            return
        }
        var agentIDs: [String] = []
        for bot in computer.bots where SpacesWire.isAgentID(bot.id) && !agentIDs.contains(bot.id) {
            agentIDs.append(bot.id)
        }
        guard !agentIDs.isEmpty else { return }
        // Bots the phone holds spaces for are asked about too: one deleted on the computer is in no
        // list any more, and only the computer saying it's gone takes its spaces off Today.
        for space in confirmed where SpacesWire.isAgentID(space.agentID) && !agentIDs.contains(space.agentID) {
            agentIDs.append(space.agentID)
        }
        readGeneration += 1
        let generation = readGeneration
        let start = changeCount
        func isCurrent() -> Bool { readGeneration == generation && !Task.isCancelled }
        do throws(SpacesError) {
            var list = SpacesList()
            let known = knownCards
            for first in stride(from: 0, to: agentIDs.count, by: SpacesWire.maximumAgentsPerList) {
                let part = try await api.list(
                    agentIDs: Array(agentIDs[first..<min(first + SpacesWire.maximumAgentsPerList, agentIDs.count)]),
                    known: known)
                list.spaces += part.spaces
                list.agents.merge(part.agents) { $1 }
            }
            guard isCurrent() else { return }
            var read = merged(list, asked: Set(agentIDs))
            // Cards the list left out: read now, a few at a time per refresh.
            var reads = 0
            for index in read.indices where read[index].needsCards && reads < SpacesWire.maximumCardReadsPerLoad {
                reads += 1
                let space = read[index]
                if let full = try? await api.space(agentID: space.agentID, spaceID: space.spaceID) { read[index] = full }
                guard isCurrent() else { return }
            }
            commit(read, readSince: start)
            lastLoaded = clock()
            phase = .ready
            saveCache()
            await sendDeletes(api)
            await sendPending(api)
        } catch .needsPluginUpdate {
            guard isCurrent() else { return }
            phase = .needsPluginUpdate
        } catch {
            guard isCurrent() else { return }
            // A failed read during a reconnect keeps what was read, and never says "update the plugin".
            if phase != .needsPluginUpdate { phase = .unreachable }
        }
    }

    /// The answer's spaces, with the cards the phone has where the computer left them out. A bot
    /// keeps its spaces as they were when the computer couldn't read it now, and when this read
    /// didn't ask about it (`asked`): a gap in what the phone asked is never the computer saying
    /// a space is gone.
    private func merged(_ list: SpacesList, asked: Set<String>) -> [Space] {
        let old = Dictionary(confirmed.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(list.agents.filter { $0.value.keepsSpaces }.keys)
        func keepsOld(_ agentID: String) -> Bool { kept.contains(agentID) || !asked.contains(agentID) }
        var read = list.spaces.filter { !keepsOld($0.agentID) }.map { $0.takingCards(from: old[$0.key]) }
        read += confirmed.filter { keepsOld($0.agentID) }
        return read
    }

    /// Takes a read's spaces, except where a mutation answered (or a space was added or deleted
    /// here) after the read began: those keep what they are now.
    private func commit(_ read: [Space], readSince start: Int) {
        let touched = Set(changedAt.filter { $0.value > start }.keys)
        var next = read.filter { !touched.contains($0.key) }
        next += confirmed.filter { touched.contains($0.key) }
        // A delete the computer hasn't finished: the space may still be listed there.
        next.removeAll { deleting[$0.key] != nil }
        confirmed = next
        // Changes the computer now has, or for spaces that are gone, are done.
        pending = pending.filter { key, change in
            guard let space = confirmed.first(where: { $0.key == key }) else { return false }
            return !change.changes.isSatisfied(by: space)
        }
        publish()
    }

    // MARK: Changing

    /// Puts a change on top of the space at once and keeps it until the computer confirms it.
    /// False for a space this store doesn't have.
    @discardableResult
    func stage(_ changes: SpaceChanges, for key: String) -> Bool {
        guard !changes.isEmpty, confirmed.contains(where: { $0.key == key }) else { return false }
        let merged = (pending[key]?.changes ?? SpaceChanges()).merging(changes)
        // A new operation: what the computer may have done for the last one is part of this one.
        pending[key] = SpacesPendingChange(changes: merged, operationID: SpacesWire.newOperationID())
        publish()
        saveCache()
        return true
    }

    /// Size, hidden or position: shown at once, then sent. Not connected, it waits for the next
    /// read. Throws only when the computer refused it for good (and it was undone).
    func change(_ key: String, _ changes: SpaceChanges, api: SpacesAPI?) async throws(SpacesError) {
        guard stage(changes, for: key) else { throw .notFound }
        guard let api else { return }
        try await send(key, api: api)
    }

    /// Sends the space's unconfirmed change. No answer keeps it for the next read. One request per
    /// space at a time: a send that finds one on its way waits for it, then sends whatever is
    /// pending by then (the person's last choice), so the computer never takes two changes to one
    /// space in the wrong order. A change still waiting repeats with its own `operationId`.
    func send(_ key: String, api: SpacesAPI) async throws(SpacesError) {
        while sending.contains(key) {
            await withCheckedContinuation { sendWaiters[key, default: []].append($0) }
        }
        sending.insert(key)
        defer {
            sending.remove(key)
            for waiter in sendWaiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        }
        guard let change = pending[key], let space = confirmed.first(where: { $0.key == key }) else { return }
        sendCount += 1
        let stamp = sendCount
        do throws(SpacesError) {
            let answer = try await api.update(agentID: space.agentID, spaceID: space.spaceID,
                                              changes: change.changes, operationID: change.operationID)
            accept(answer, sent: stamp)
            if pending[key]?.operationID == change.operationID { pending[key] = nil }
            publish()
            saveCache()
        } catch .unreachable {
            return
        } catch {
            if case .notFound = error { remove(key) }
            // Undo what was refused; a change made since goes on its own way.
            if pending[key]?.operationID == change.operationID { pending[key] = nil }
            publish()
            saveCache()
            throw error
        }
    }

    private func sendPending(_ api: SpacesAPI) async {
        for key in pending.keys.sorted() {
            try? await send(key, api: api)
        }
    }

    /// Runs the space's routine now. A failed run's space shows as the computer says.
    func runNow(_ key: String, api: SpacesAPI?) async throws(SpacesError) -> SpaceRefreshRun {
        guard let api else { throw .unreachable }
        guard let space = confirmed.first(where: { $0.key == key }) else { throw .notFound }
        sendCount += 1
        let stamp = sendCount
        do throws(SpacesError) {
            let answer = try await api.refresh(agentID: space.agentID, spaceID: space.spaceID)
            let space = await withCards(answer.space, api: api)
            accept(space, sent: stamp)
            publish()
            saveCache()
            return answer.ran
        } catch .routineFailed(let failed) {
            if let failed {
                accept(failed, sent: stamp)
                publish()
                saveCache()
            }
            throw .routineFailed(failed)
        } catch .notFound {
            remove(key)
            publish()
            saveCache()
            throw .notFound
        }
    }

    /// Takes the space off at once. A delete the computer hasn't finished (no answer, not connected,
    /// or `schedules_unavailable`) keeps it off and goes again, as the same request, at each read.
    /// Only a definite refusal brings it back, and throws.
    func delete(_ key: String, api: SpacesAPI?) async throws(SpacesError) {
        guard let index = confirmed.firstIndex(where: { $0.key == key }) else { return }
        let space = confirmed[index]
        let change = pending[key]
        let request = SpacesPendingDelete(agentID: space.agentID, spaceID: space.spaceID,
                                          operationID: SpacesWire.newOperationID())
        remove(key)
        deleting[key] = request
        publish()
        saveCache()
        guard let api else { return }
        do throws(SpacesError) {
            try await sendDelete(request, key: key, api: api)
        } catch {
            if !confirmed.contains(where: { $0.key == key }) {
                confirmed.insert(space, at: min(index, confirmed.count))
                pending[key] = change
                touch(key)
                publish()
                saveCache()
            }
            throw error
        }
    }

    /// One delete request. Finished or gone: forgotten. Not finished: kept for the next read.
    /// Refused for good: forgotten, and thrown, so the space can come back.
    private func sendDelete(_ request: SpacesPendingDelete, key: String, api: SpacesAPI) async throws(SpacesError) {
        do throws(SpacesError) {
            try await api.delete(agentID: request.agentID, spaceID: request.spaceID, operationID: request.operationID)
        } catch .notFound {
            // Gone already.
        } catch .unreachable, .schedulesUnavailable {
            return
        } catch {
            if deleting[key] == request { deleting[key] = nil }
            saveCache()
            throw error
        }
        if deleting[key] == request { deleting[key] = nil }
        saveCache()
    }

    private func sendDeletes(_ api: SpacesAPI) async {
        for (key, request) in deleting.sorted(by: { $0.key < $1.key }) {
            // A refusal is forgotten in `sendDelete`; the next read lists the space again.
            try? await sendDelete(request, key: key, api: api)
        }
    }

    /// Adds a draft to Today. With the draft as `get` read it, it shows at once, and goes again
    /// unless the computer says it's live.
    func add(agentID: String, spaceID: String, draftRevision: Int, size: SpaceSize?, position: Double?,
             preview: Space?, api: SpacesAPI?) async throws(SpacesError) -> Space {
        guard let api else { throw .unreachable }
        let key = Space.key(agentID: agentID, spaceID: spaceID)
        var shown: Space?
        if var preview, preview.key == key, !confirmed.contains(where: { $0.key == key }) {
            preview.state = .live
            if let size { preview.size = size }
            if let position { preview.position = position }
            confirmed.append(preview)
            touch(key)
            publish()
            shown = preview
        }
        sendCount += 1
        let stamp = sendCount
        do throws(SpacesError) {
            let added = try await api.add(agentID: agentID, spaceID: spaceID, draftRevision: draftRevision,
                                          size: size, position: position)
            let answer = await withCards(added, api: api)
            accept(answer, sent: stamp)
            publish()
            saveCache()
            return answer
        } catch {
            // Real data only: a space the computer didn't confirm doesn't stay on Today.
            if let shown, confirmed.first(where: { $0.key == key }) == shown {
                remove(key)
                publish()
            }
            throw error
        }
    }

    // MARK: Helpers

    /// A mutation's answer, unless a later one for the same space already landed.
    private func accept(_ answer: Space, sent stamp: Int) {
        // A late answer for a space being deleted never brings it back.
        guard (acceptedSend[answer.key] ?? 0) < stamp, deleting[answer.key] == nil else { return }
        acceptedSend[answer.key] = stamp
        let current = confirmed.first { $0.key == answer.key }
        let space = answer.takingCards(from: current)
        if let index = confirmed.firstIndex(where: { $0.key == answer.key }) {
            confirmed[index] = space
        } else if space.state == .live {
            confirmed.append(space)
        }
        touch(answer.key)
        if let change = pending[answer.key], change.changes.isSatisfied(by: space) { pending[answer.key] = nil }
    }

    /// The space with its cards, read with `get` when the answer left them out.
    private func withCards(_ space: Space, api: SpacesAPI) async -> Space {
        let space = space.takingCards(from: confirmed.first { $0.key == space.key })
        guard space.needsCards else { return space }
        return (try? await api.space(agentID: space.agentID, spaceID: space.spaceID)) ?? space
    }

    private func remove(_ key: String) {
        confirmed.removeAll { $0.key == key }
        pending[key] = nil
        touch(key)
    }

    private func touch(_ key: String) {
        changeCount += 1
        changedAt[key] = changeCount
    }

    private func publish() {
        let shown = confirmed.map { space in pending[space.key]?.changes.applied(to: space) ?? space }
        if shown != spaces { spaces = shown }
    }

    /// Written off the main thread, one write after the other, so the newest copy is the one kept.
    private func saveCache() {
        guard let cacheFolder, !isRetired else { return }
        let file = SpacesCacheFile(scope: scope, lastLoaded: lastLoaded, spaces: confirmed.map(\.json), pending: pending,
                                   deleting: deleting)
        let previous = cacheWrite
        cacheWrite = Task.detached(priority: .utility) {
            await previous?.value
            SpacesCacheFile.write(file, folder: cacheFolder)
        }
    }

    /// The computer was removed: its copy on disk is erased by the caller, and nothing writes it again.
    func retire() {
        isRetired = true
    }

    /// Waits for the copy on disk to be written, for tests.
    func savedToDisk() async {
        await cacheWrite?.value
    }
}
