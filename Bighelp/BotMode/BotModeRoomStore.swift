import Foundation
import Observation

@MainActor
protocol BotModeMemberTurnClient {
    func performMemberTurn(_ request: BotModeMemberTurnRequest) async throws -> BotModeMemberTurnResult
}

struct BotModeMemberTurnRequest: Equatable, Sendable {
    let roomID: String
    let memberID: String
    let memberSessionID: String
    let text: String
    let sharedEvents: [BotModeEvent]
}

enum BotModeMemberTurnResult: Equatable, Sendable {
    case reply(String)
    case pass
}

@MainActor
enum BotModeRoomLoadIntent: Equatable, Sendable {
    case startup
    case automaticRestore
    case explicitUse
}

@MainActor
enum BotModeRoomLoadingPolicy {
    static func load(
        _ store: BotModeRoomStore,
        for intent: BotModeRoomLoadIntent
    ) throws {
        switch intent {
        case .startup:
            return
        case .automaticRestore:
            do {
                try store.load()
            } catch {
                store.clearLoadError()
            }
        case .explicitUse:
            try store.load()
        }
    }
}

@MainActor
@Observable
final class BotModeRoomStore {
    // State lives here; responsibility extensions operate on this same MainActor
    // owner. Internal implementation seams are not independent state owners.
    let activity = BotModeActivityStore()
    var terminalNativeAttempts: [String: [String: (generation: Int, sequence: Int)]] = [:]
    final class RoomObserver {
        weak var owner: AnyObject?
        let roomID: String
        let onChange: @MainActor (AnyObject) -> Void

        init(
            owner: AnyObject,
            roomID: String,
            onChange: @escaping @MainActor (AnyObject) -> Void
        ) {
            self.owner = owner
            self.roomID = roomID
            self.onChange = onChange
        }
    }

    var rooms: [BotModeRoom]
    private(set) var loadErrorMessage: String? = nil
    /// Legacy local harness execution remains available to explicit fixture
    /// clients. Production passes `false` and supplies a negotiated native
    /// client. Persisted rooms remain loadable when this is false.
    let executionEnabled: Bool
    var nativeCapabilities: HermesBotModeCapabilities?
    var catalogState: BotModeRoomCatalogState = .idle
    var catalogRooms: [HermesBotModeRoomSummary] = []
    var isCatalogStale = false
    var nativeRoomSyncErrors: [String: String] = [:]
    var catalogRefreshID: UUID?
    var nativePendingApprovalsByRoom: [String: [String: HermesBotModePendingApproval]] = [:]
    var nativePendingRetryTaskIDsByRoom: [String: Set<String>] = [:]
    var nativeDriverWorkingByRoom: [String: Bool] = [:]
    let client: any BotModeMemberTurnClient
    var nativeClient: (any HermesBotModeClient)?
    let persistence: (any BotModeRoomPersistence)?
    let instanceID = UUID().uuidString
    var nextGeneration = 0
    var nativeBoundaryGeneration = 0
    private var hasLoadedNativePersistence = false
    var nativeObservations: [String: Task<Void, Never>] = [:]
    var nativeObservationTokens: [String: UUID] = [:]
    var nativeActiveRunIDs: Set<String> = []
    private var nextPresentationOrder: Int
    private var activityPresentationOrders: [String: Int] = [:]
    var roomObservers: [UUID: RoomObserver] = [:]

    static let nativeLogLimit = 500
    /// Hermes refuses a log page larger than the limit it advertises.
    var nativeLogPageLimit: Int {
        min(Self.nativeLogLimit, nativeCapabilities?.maxLogLimit ?? Self.nativeLogLimit)
    }
    static let nativePollNanoseconds: UInt64 = 500_000_000
    static let nativeTransportRetryNanoseconds: UInt64 = 1_000_000_000

    init(
        client: any BotModeMemberTurnClient,
        repository: DemoRepository<[BotModeRoom]>? = nil,
        rooms: [BotModeRoom] = [],
        persistence: (any BotModeRoomPersistence)? = nil,
        executionEnabled: Bool = true,
        nativeClient: (any HermesBotModeClient)? = nil
    ) {
        self.client = client
        self.rooms = rooms
        self.persistence = persistence ?? repository.map(DemoBotModeRoomPersistence.init)
        self.executionEnabled = executionEnabled
        self.nativeClient = nativeClient
        nextPresentationOrder = Self.presentationOrder(after: rooms)
    }

    func clearLoadError() {
        loadErrorMessage = nil
    }

    func load() throws {
        if nativeClient != nil {
            try loadNativeStorageIfNeeded()
            return
        }
        guard let persistence else { return }
        do {
            rooms = try persistence.load(recoveringRuns: true)
            nextPresentationOrder = max(nextPresentationOrder, Self.presentationOrder(after: rooms))
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = "Group chats could not be loaded. Try again."
            throw error
        }
    }

    func resetForAccountBoundary() {
        rooms.removeAll()
        hasLoadedNativePersistence = false
        loadErrorMessage = nil
        nextGeneration += 1
        nextPresentationOrder = 1
        activityPresentationOrders.removeAll()
        roomObservers.removeAll()
        invalidateNativeExecutionBoundary()
    }

    /// Restore the host cache once without settling durable Hermes work or
    /// changing the local run's revision during navigation. Native log replay
    /// reconciles pending sends and completion with the host.
    func loadNativeStorageIfNeeded() throws {
        guard !hasLoadedNativePersistence, let persistence else { return }
        do {
            rooms = try persistence.load(recoveringRuns: false)
            nextPresentationOrder = max(nextPresentationOrder, Self.presentationOrder(after: rooms))
            hasLoadedNativePersistence = true
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = "Group chats could not be loaded. Try again."
            throw error
        }
    }

    func room(id: String) -> BotModeRoom? {
        rooms.first(where: { $0.id == id })
    }

    @discardableResult
    func observeRoom<Owner: AnyObject>(
        id: String,
        owner: Owner,
        onChange: @escaping @MainActor (Owner) -> Void
    ) -> UUID {
        pruneRoomObservers()
        let token = UUID()
        roomObservers[token] = RoomObserver(owner: owner, roomID: id) { value in
            guard let owner = value as? Owner else { return }
            onChange(owner)
        }
        return token
    }

    func removeRoomObserver(_ token: UUID) {
        roomObservers[token] = nil
    }

    var roomObserverCount: Int {
        pruneRoomObservers()
        return roomObservers.count
    }

    func replace(room: BotModeRoom) {
        guard let current = self.room(id: room.id) else {
            rooms.append(room)
            notifyRoomChanged(room.id)
            return
        }
        let expectedOwner: BotModeRunOwnerExpectation = current.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
        guard let saved = try? compareAndSave(room, expectedRevision: current.persistenceRevision, expectedOwner: expectedOwner) else { return }
        replaceStored(saved)
    }

    func persist(room: BotModeRoom) throws {
        if let current = self.room(id: room.id) {
            let expectedOwner: BotModeRunOwnerExpectation = current.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
            guard let saved = try compareAndSave(
                room,
                expectedRevision: current.persistenceRevision,
                expectedOwner: expectedOwner
            ) else {
                throw BotModeRoomError.persistenceConflict
            }
            replaceStored(saved)
            return
        }

        if let persistence {
            guard let saved = try persistence.insert(room) else {
                throw BotModeRoomError.persistenceConflict
            }
            rooms.append(saved)
            notifyRoomChanged(saved.id)
        } else {
            var saved = room
            saved.markPersisted(revision: room.persistenceRevision + 1)
            rooms.append(saved)
            notifyRoomChanged(saved.id)
        }
    }

    func remove(roomID: String) throws {
        guard room(id: roomID) != nil else { return }
        nativeObservations[roomID]?.cancel()
        nativeObservations.removeValue(forKey: roomID)
        nativeObservationTokens.removeValue(forKey: roomID)
        nativePendingApprovalsByRoom.removeValue(forKey: roomID)
        nativePendingRetryTaskIDsByRoom.removeValue(forKey: roomID)
        nativeDriverWorkingByRoom.removeValue(forKey: roomID)
        if let persistence, try !persistence.remove(roomID: roomID) {
            throw BotModeRoomError.persistenceConflict
        }
        rooms.removeAll { $0.id == roomID }
        notifyRoomChanged(roomID)
    }

    /// Restores the canonical room after a catalog transaction callback fails.
    /// The previous value is optional because a failed initial conversion must
    /// remove its newly inserted orphan instead of leaving a usable-looking room.
    func restore(room previous: BotModeRoom?, roomID: String) throws {
        if let previous {
            if self.room(id: roomID) != nil {
                let expectedOwner: BotModeRunOwnerExpectation = previous.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
                guard let saved = try compareAndSave(
                    previous,
                    expectedRevision: self.room(id: roomID)?.persistenceRevision ?? previous.persistenceRevision,
                    expectedOwner: expectedOwner
                ) else { throw BotModeRoomError.persistenceConflict }
                replaceStored(saved)
            } else {
                try persist(room: previous)
            }
            return
        }

        rooms.removeAll { $0.id == roomID }
        notifyRoomChanged(roomID)
        if let persistence, try !persistence.remove(roomID: roomID) {
            throw BotModeRoomError.persistenceConflict
        }
    }

    func cancel(roomID: String) {
        guard var room = room(id: roomID) else { return }
        let expectedOwner: BotModeRunOwnerExpectation = room.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
        room.settleRun()
        guard let saved = try? compareAndSave(room, expectedRevision: room.persistenceRevision, expectedOwner: expectedOwner) else { return }
        replaceStored(saved)
    }

    func compareAndSave(
        _ room: BotModeRoom,
        expectedRevision: Int,
        expectedOwner: BotModeRunOwnerExpectation
    ) throws -> BotModeRoom? {
        if let persistence {
            return try persistence.compareAndSave(room, expectedRevision: expectedRevision, expectedOwner: expectedOwner)
        }
        guard let current = self.room(id: room.id), current.persistenceRevision == expectedRevision,
              expectedOwner.matches(current) else { return nil }
        var saved = room
        saved.markPersisted(revision: current.persistenceRevision + 1)
        return saved
    }

    func recoverAfterPersistenceFailure(
        roomID: String,
        owner: BotModeRunOwner,
        fallback: BotModeRoom
    ) {
        var settled = fallback
        settled.settleRun()
        if let saved = try? compareAndSave(
            settled,
            expectedRevision: self.room(id: roomID)?.persistenceRevision ?? settled.persistenceRevision,
            expectedOwner: .owner(owner)
        ) {
            replaceStored(saved)
        } else {
            // Even if the backing write remains unavailable, never strand this
            // process-owned run as active or permit a duplicate human event.
            replaceStored(settled)
        }
    }

    func runActivity(
        owner: BotModeRunOwner,
        turnID: String,
        member: BotModeMember,
        from sourceMember: BotModeMember?,
        lifecycle: ChatActivityLifecycle,
        summary: String,
        detail: String?
    ) -> BotModeRunActivity {
        let eventID = "bot-mode-\(owner.runID)-\(member.id)"
        let sourceOrder: Int
        if let existing = activityPresentationOrders[eventID] {
            sourceOrder = existing
        } else {
            sourceOrder = takePresentationOrder()
            activityPresentationOrders[eventID] = sourceOrder
            if activityPresentationOrders.count > 512 {
                activityPresentationOrders.removeValue(forKey: activityPresentationOrders.keys.first!)
            }
        }
        return BotModeRunActivity(
            eventID: eventID,
            runID: owner.runID,
            turnID: turnID,
            memberID: member.id,
            memberHandle: member.handle,
            fromMemberID: sourceMember?.id,
            fromMemberHandle: sourceMember?.handle,
            lifecycle: lifecycle,
            summary: summary,
            detail: detail,
            occurredAt: Int(Date().timeIntervalSince1970 * 1_000),
            sourceOrder: sourceOrder
        )
    }

    func ensurePresentationOrder(atLeast minimum: Int) {
        nextPresentationOrder = max(nextPresentationOrder, minimum)
    }

    func takePresentationOrder() -> Int {
        defer { nextPresentationOrder += 1 }
        return nextPresentationOrder
    }

    private static func presentationOrder(after rooms: [BotModeRoom]) -> Int {
        (rooms.flatMap(\.visibleEvents).compactMap(\.sourceOrder).max() ?? 0) + 1
    }

    func replaceStored(_ room: BotModeRoom) {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        rooms[index] = room
        notifyRoomChanged(room.id)
    }

    func notifyRoomChanged(_ roomID: String) {
        pruneRoomObservers()
        let callbacks = roomObservers.values.compactMap { observer -> (() -> Void)? in
            guard observer.roomID == roomID, let owner = observer.owner else { return nil }
            return { observer.onChange(owner) }
        }
        callbacks.forEach { $0() }
    }

    private func pruneRoomObservers() {
        roomObservers = roomObservers.filter { $0.value.owner != nil }
    }
}
