import Foundation
import Testing
@testable import Bighelp

/// Shared by the Spaces tests: a computer, a folder for the phone's copy, and a client that can
/// hold or refuse answers.
@MainActor
enum SpacesTestKit {
    static let now = Date(timeIntervalSince1970: 1_794_500_000)
    static let bots = ["travel", "home", "finance"].map { SpacesBot(id: $0, name: $0.capitalized) }
    static let commute = Space.key(agentID: "travel", spaceID: DemoSpacesClient.commuteID)
    static let garden = Space.key(agentID: "home", spaceID: DemoSpacesClient.gardenID)
    static let workouts = Space.key(agentID: "home", spaceID: DemoSpacesClient.workoutsID)

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spaces-tests-\(UUID().uuidString)", isDirectory: true)
    }

    static func demo() -> DemoSpacesClient { DemoSpacesClient(clock: { now }) }

    static func computer(_ scope: String = "scope-home", name: String = "Home", client: (any SpacesClient)?,
                         bots: [SpacesBot] = bots, isCurrent: Bool = true) -> SpacesComputer {
        SpacesComputer(hostKey: "host-" + scope, scope: scope, name: name, api: client.map { SpacesAPI(client: $0) },
                       bots: bots, isCurrent: isCurrent)
    }

    static func store(_ folder: URL, scope: String = "scope-home") -> SpacesStore {
        SpacesStore(scope: scope, hostKey: "host-" + scope, cacheFolder: folder, clock: { now })
    }
}

/// The connection a computer has now; tests swap it for a reconnect.
@MainActor
final class SpacesTestConnection {
    var client: any SpacesClient

    init(_ client: any SpacesClient) {
        self.client = client
    }
}

/// Answers through another client, and can hold an answer after it's made (a read that comes back
/// late) or refuse instead.
@MainActor
final class HeldSpacesClient: SpacesClient {
    let inner: any SpacesClient
    var holds: Set<SpacesOperation> = []
    var failure: (any Error)?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var payloads: [(operation: SpacesOperation, payload: [String: BighelpJSONValue])] = []

    init(_ inner: any SpacesClient) {
        self.inner = inner
    }

    var isHolding: Bool { !waiting.isEmpty }

    func perform(_ operation: SpacesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        payloads.append((operation, payload))
        if let failure { throw failure }
        let answer = try await inner.perform(operation, payload: payload)
        if holds.contains(operation) { await withCheckedContinuation { waiting.append($0) } }
        return answer
    }

    func release() {
        let held = waiting
        waiting = []
        for continuation in held { continuation.resume() }
    }

    func untilHolding() async {
        while !isHolding { await Task.yield() }
    }
}

/// The plugin when a bot is gone from the computer: its `list` answer has no spaces for it and
/// says `profile_not_found` for it.
@MainActor
final class GoneBotSpacesClient: SpacesClient {
    let inner: any SpacesClient
    let gone: Set<String>

    init(_ inner: any SpacesClient, gone: Set<String>) {
        self.inner = inner
        self.gone = gone
    }

    func perform(_ operation: SpacesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        var answer = try await inner.perform(operation, payload: payload)
        guard operation == .list else { return answer }
        answer["spaces"] = .array((answer["spaces"]?.array ?? []).filter { !gone.contains($0.object?["agentId"]?.string ?? "") })
        var agents = answer["agents"]?.object ?? [:]
        for id in gone { agents[id] = .string("profile_not_found") }
        answer["agents"] = .object(agents)
        return answer
    }
}

/// A connection as `DirectHermesSpacesClient` sees it: the plugin's context, and answers or errors.
@MainActor
private final class SpacesPerformer: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var features = ["native-context-v1"]
    var failures: [any Error] = []
    var contextFailure: (any Error)?
    private(set) var calls: [(operation: WorkspaceOperation, payload: [String: BighelpJSONValue])] = []

    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard owner == self.owner else { throw WorkspaceClientError.ownerChanged }
        calls.append((operation, payload))
        if operation == .nativeContext {
            if let contextFailure { throw contextFailure }
            return ["features": .array(features.map(BighelpJSONValue.string))]
        }
        if !failures.isEmpty { throw failures.removeFirst() }
        return ["spaces": .array([]), "agents": .object([:])]
    }
}

@MainActor
struct SpacesStoreTests {
    typealias Kit = SpacesTestKit

    // MARK: Keeping the data

    @Test func theCacheScopeSurvivesANewOwner() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = SpacesTestConnection(Kit.demo())
        let model = TodaySpacesModel(computers: { [Kit.computer(client: connection.client)] }, current: { nil },
                                     cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let store = try #require(model.stores["scope-home"])
        #expect(store.spaces.count == 3)
        // A reconnect: a new connection to the same computer, which doesn't answer yet.
        let refusing = HeldSpacesClient(Kit.demo())
        refusing.failure = WorkspaceClientError.transportUnavailable
        connection.client = refusing
        await model.refresh()
        #expect(model.stores["scope-home"] === store)
        #expect(store.spaces.count == 3)
        #expect(store.phase == .unreachable)
    }

    @Test func aRelaunchDrawsTheLastPanelsAtOnce() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: Kit.demo()))
        await store.savedToDisk()
        let again = Kit.store(folder)
        #expect(again.spaces == store.spaces)
        #expect(again.spaces.allSatisfy { $0.card != nil })
        #expect(again.lastLoaded == Kit.now)
        #expect(again.phase == .loading)
        // Another computer's copy isn't this one's.
        #expect(Kit.store(folder, scope: "scope-other").spaces.isEmpty)
    }

    @Test func aNilOwnerKeepsTheData() async {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: Kit.demo()))
        let read = store.spaces
        await store.load(Kit.computer(client: nil))
        #expect(store.spaces == read)
        #expect(store.phase == .unreachable)
    }

    @Test func nothingIsReadBeforeTheBotsAreKnown() async {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client, bots: []))
        #expect(client.payloads.isEmpty)
        #expect(store.phase == .loading)
    }

    // MARK: Changes the computer hasn't confirmed

    @Test func anUnconfirmedChangeIsReplayedWhenTheComputerAnswersAgain() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let client = HeldSpacesClient(demo)
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        // Not connected: it shows at once and waits.
        try await store.change(Kit.garden, SpaceChanges(size: .small), api: nil)
        #expect(store.spaces.first { $0.key == Kit.garden }?.size == .small)
        let waiting = try #require(store.pending[Kit.garden])
        // It survives a relaunch too.
        await store.savedToDisk()
        let relaunched = Kit.store(folder)
        #expect(relaunched.pending[Kit.garden] == waiting)
        #expect(relaunched.spaces.first { $0.key == Kit.garden }?.size == .small)

        await relaunched.load(Kit.computer(client: client))
        let sent = try #require(client.payloads.last(where: { $0.operation == .update }))
        #expect(sent.payload["operationId"] == .string(waiting.operationID))
        #expect(sent.payload["changes"] == .object(["size": .string("small")]))
        #expect(relaunched.pending.isEmpty)
        let onComputer = try await SpacesAPI(client: demo).space(agentID: "home", spaceID: DemoSpacesClient.gardenID)
        #expect(onComputer.size == .small)
    }

    @Test func anUnconfirmedChangeGoesOnceTheComputersValueCatchesUp() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let client = HeldSpacesClient(demo)
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        try await store.change(Kit.garden, SpaceChanges(hidden: true), api: nil)
        // Another device hid it meanwhile.
        _ = try await SpacesAPI(client: demo).update(agentID: "home", spaceID: DemoSpacesClient.gardenID,
                                                     changes: SpaceChanges(hidden: true))
        await store.load(Kit.computer(client: client))
        #expect(store.pending.isEmpty)
        #expect(!client.payloads.contains { $0.operation == .update })
        #expect(store.spaces.first { $0.key == Kit.garden }?.hidden == true)
    }

    @Test func aRefusalUndoesTheChangeAndNoAnswerKeepsIt() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        let api = SpacesAPI(client: client)

        client.failure = WorkspaceClientError.transportUnavailable
        try await store.change(Kit.commute, SpaceChanges(size: .tall), api: api)
        #expect(store.spaces.first { $0.key == Kit.commute }?.size == .tall)
        #expect(store.pending[Kit.commute] != nil)

        client.failure = WorkspaceClientError.rejected(code: "invalid_request")
        do throws(SpacesError) {
            try await store.change(Kit.commute, SpaceChanges(size: .wide), api: api)
            Issue.record("The refusal didn't reach the caller.")
        } catch {
            #expect(error == .other(code: "invalid_request"))
        }
        #expect(store.pending[Kit.commute] == nil)
        #expect(store.spaces.first { $0.key == Kit.commute }?.size == .small)
    }

    /// An `operationId` goes again only with its own request: a change on top of one the computer
    /// hasn't confirmed is a new request, with a new id.
    @Test func aChangeOnTopOfAnUnconfirmedOneIsANewRequest() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        let api = SpacesAPI(client: client)
        client.failure = WorkspaceClientError.transportUnavailable
        try await store.change(Kit.garden, SpaceChanges(size: .tall), api: api)
        let first = try #require(store.pending[Kit.garden])
        client.failure = nil
        try await store.change(Kit.garden, SpaceChanges(hidden: true), api: api)
        let updates = client.payloads.filter { $0.operation == .update }
        #expect(updates.count == 2)
        #expect(updates.last?.payload["operationId"] != .string(first.operationID))
        #expect(updates.last?.payload["changes"] == .object(["size": .string("tall"), "hidden": .boolean(true)]))
        #expect(store.pending.isEmpty)
        #expect(store.confirmedSpace(Kit.garden)?.size == .tall)
    }

    @Test func aMutationsAnswerIsNotUndoneByAReadThatBeganBefore() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        client.holds = [.list]
        let read = Task { await store.load(Kit.computer(client: client)) }
        await client.untilHolding()
        // The read holds the computer's answer from before this change.
        client.holds = []
        try await store.change(Kit.garden, SpaceChanges(size: .tall), api: SpacesAPI(client: client))
        client.release()
        await read.value
        #expect(store.spaces.first { $0.key == Kit.garden }?.size == .tall)
        #expect(store.confirmedSpace(Kit.garden)?.size == .tall)
    }


    // MARK: One request at a time

    /// Hide, then show, before the computer answers the first: the second request waits, so the
    /// computer never takes them in the wrong order, and the space ends as the person last chose.
    @Test func overlappingChangesToOneSpaceGoOneAtATimeAndEndOnTheLastChoice() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let client = HeldSpacesClient(demo)
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        let api = SpacesAPI(client: client)
        client.holds = [.update]

        let hide = Task { try? await store.change(Kit.garden, SpaceChanges(hidden: true), api: api) }
        await client.untilHolding()
        let show = Task { try? await store.change(Kit.garden, SpaceChanges(hidden: false), api: api) }
        for _ in 0..<20 { await Task.yield() }
        // The first answer is still out: only one request has gone.
        #expect(client.payloads.filter { $0.operation == .update }.count == 1)
        #expect(store.spaces.first { $0.key == Kit.garden }?.hidden == false)

        client.release()
        await client.untilHolding()
        client.release()
        await hide.value
        await show.value

        let updates = client.payloads.filter { $0.operation == .update }
        #expect(updates.count == 2)
        #expect(updates[0].payload["changes"] == .object(["hidden": .boolean(true)]))
        #expect(updates[1].payload["changes"] == .object(["hidden": .boolean(false)]))
        #expect(updates[0].payload["operationId"] != updates[1].payload["operationId"])
        #expect(store.pending.isEmpty)
        #expect(store.spaces.first { $0.key == Kit.garden }?.hidden == false)
        let onComputer = try await SpacesAPI(client: demo).space(agentID: "home", spaceID: DemoSpacesClient.gardenID)
        #expect(!onComputer.hidden)
    }

    // MARK: A partial list of bots

    /// The phone's list of bots can lag or be partial while a computer reconnects or the selection
    /// moves. A read asks about the bots the phone holds spaces for too, so a short list takes
    /// nothing off Today and a waiting change still gets to the computer.
    @Test func aPartialListOfBotsKeepsTheOtherBotsSpacesAndTheirChanges() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        #expect(store.spaces.count == 3)
        try await store.change(Kit.garden, SpaceChanges(size: .tall), api: nil)

        await store.load(Kit.computer(client: client, bots: [SpacesBot(id: "travel", name: "Travel")]))
        #expect(store.spaces.map(\.key).sorted() == [Kit.commute, Kit.garden, Kit.workouts].sorted())
        #expect(store.spaces.first { $0.key == Kit.garden }?.size == .tall)

        // A list with only a bot this computer has no spaces for is a partial list too.
        await store.load(Kit.computer(client: client, bots: [SpacesBot(id: "finance", name: "Finance")]))
        #expect(store.spaces.count == 3)
        await store.savedToDisk()
        #expect(Kit.store(folder).spaces.count == 3)
    }

    @Test func onlyTheComputerSayingABotIsGoneRemovesItsSpaces() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: demo))
        try await store.change(Kit.garden, SpaceChanges(size: .tall), api: nil)
        try await store.change(Kit.commute, SpaceChanges(size: .tall), api: nil)

        await store.load(Kit.computer(client: GoneBotSpacesClient(demo, gone: ["home"])))
        #expect(store.spaces.map(\.key) == [Kit.commute])
        #expect(store.pending.keys.contains(Kit.garden) == false)
    }

    // MARK: Deleting

    /// `schedules_unavailable` from delete: the space is off Today on the computer, and Hermes still
    /// has its task. It never shows again here, and the same request goes at each read until done.
    @Test func aDeleteTheComputerHasntFinishedStaysOffAndGoesAgainAsTheSameRequest() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let client = HeldSpacesClient(demo)
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        demo.stuckTasks = [DemoSpacesClient.commuteID]
        try await store.delete(Kit.commute, api: SpacesAPI(client: client))
        #expect(!store.spaces.contains { $0.key == Kit.commute })
        let waiting = try #require(store.deleting[Kit.commute])

        await store.load(Kit.computer(client: client))
        #expect(!store.spaces.contains { $0.key == Kit.commute })
        #expect(store.deleting[Kit.commute] == waiting)

        demo.stuckTasks = []
        await store.load(Kit.computer(client: client))
        #expect(store.deleting.isEmpty)
        let deletes = client.payloads.filter { $0.operation == .delete }
        #expect(deletes.count == 3)
        #expect(deletes.allSatisfy { $0.payload["operationId"] == .string(waiting.operationID) })
        await #expect(throws: SpacesError.notFound) {
            try await SpacesAPI(client: demo).space(agentID: "travel", spaceID: DemoSpacesClient.commuteID)
        }
    }

    @Test func aDeleteWithoutAConnectionWaitsAndSurvivesARelaunch() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        try await store.delete(Kit.garden, api: nil)
        #expect(!store.spaces.contains { $0.key == Kit.garden })
        await store.savedToDisk()

        let relaunched = Kit.store(folder)
        #expect(!relaunched.spaces.contains { $0.key == Kit.garden })
        #expect(relaunched.deleting[Kit.garden] == store.deleting[Kit.garden])
        await relaunched.load(Kit.computer(client: client))
        #expect(relaunched.deleting.isEmpty)
        #expect(!relaunched.spaces.contains { $0.key == Kit.garden })
        #expect(relaunched.spaces.count == 2)
    }

    @Test func aRefusedDeleteBringsTheSpaceBack() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        client.failure = WorkspaceClientError.rejected(code: "invalid_request")
        await #expect(throws: SpacesError.other(code: "invalid_request")) {
            try await store.delete(Kit.commute, api: SpacesAPI(client: client))
        }
        #expect(store.spaces.contains { $0.key == Kit.commute })
        #expect(store.deleting.isEmpty)
    }

    // MARK: Stale and cancelled reads

    @Test func aStaleReadDoesNotWrite() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let older = Kit.demo()
        _ = try await SpacesAPI(client: older).update(agentID: "home", spaceID: DemoSpacesClient.gardenID,
                                                      changes: SpaceChanges(hidden: true))
        let late = HeldSpacesClient(older)
        late.holds = [.list]
        let store = Kit.store(folder)
        let first = Task { await store.load(Kit.computer(client: late)) }
        await late.untilHolding()
        await store.load(Kit.computer(client: Kit.demo()))
        late.release()
        await first.value
        // The newer read's answer stands.
        #expect(store.spaces.first { $0.key == Kit.garden }?.hidden == false)
    }

    @Test func aCancelledReadDoesNotWrite() async {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let late = HeldSpacesClient(Kit.demo())
        late.holds = [.list]
        let store = Kit.store(folder)
        let read = Task { await store.load(Kit.computer(client: late)) }
        await late.untilHolding()
        read.cancel()
        late.release()
        await read.value
        #expect(store.spaces.isEmpty)
        #expect(store.lastLoaded == nil)
        #expect(store.phase == .loading)
    }

    // MARK: Cards the phone has

    @Test func knownCardsAreSentAndLeftOut() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: client))
        let hashes = Dictionary(uniqueKeysWithValues: store.spaces.compactMap { space in
            space.cardsSHA256.map { (space.key, $0) }
        })
        #expect(hashes.count == 3)
        await store.load(Kit.computer(client: client))
        let lists = client.payloads.filter { $0.operation == .list }
        #expect(lists.first?.payload["known"] == .object([:]))
        #expect(lists.last?.payload["known"] == .object(hashes.mapValues(BighelpJSONValue.string)))
        #expect(!client.payloads.contains { $0.operation == .get })
        // The answer left the cards out; the phone's own stay.
        #expect(store.spaces.count == 3)
        #expect(store.spaces.allSatisfy { $0.card != nil })
    }

    // MARK: needsPluginUpdate comes only from the context

    @Test func needsPluginUpdateOnlyFromAContextWithoutTheFeature() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Kit.store(folder)
        await store.load(Kit.computer(client: Kit.demo()))
        let performer = try SpacesPerformer()
        let client = DirectHermesSpacesClient(workspace: { performer })

        // The route is refused while the context lists the feature (a reconnect): the data stays.
        performer.features = ["native-context-v1", SpacesWire.feature]
        performer.failures = [WorkspaceClientError.unavailable(.unsupportedOperation)]
        await store.load(Kit.computer(client: client))
        #expect(store.phase == .unreachable)
        #expect(store.spaces.count == 3)

        // The context didn't load: still not "update the plugin".
        performer.contextFailure = WorkspaceClientError.transportUnavailable
        performer.failures = [WorkspaceClientError.unavailable(.unsupportedOperation)]
        await store.load(Kit.computer(client: client))
        #expect(store.phase == .unreachable)

        // The computer's plugin says it has no spaces.
        performer.contextFailure = nil
        performer.features = ["native-context-v1"]
        performer.failures = [WorkspaceClientError.unavailable(.unsupportedOperation)]
        await store.load(Kit.computer(client: client))
        #expect(store.phase == .needsPluginUpdate)
        #expect(store.spaces.count == 3)

        // A later failed read doesn't turn that into "not connected".
        performer.failures = [WorkspaceClientError.transportUnavailable]
        await store.load(Kit.computer(client: client))
        #expect(store.phase == .needsPluginUpdate)
    }

    // MARK: The client's retries

    @Test func aLostAnswerIsAskedAgainOnceWithTheSameOperationID() async throws {
        let performer = try SpacesPerformer()
        let client = DirectHermesSpacesClient(workspace: { performer })
        let payload: [String: BighelpJSONValue] = [
            "agentId": .string("home"), "spaceId": .string(DemoSpacesClient.gardenID),
            "operationId": .string(SpacesWire.newOperationID()), "changes": .object(["hidden": .boolean(true)]),
        ]
        performer.failures = [WorkspaceClientError.outcomeUnknown]
        _ = try await client.perform(.update, payload: payload)
        #expect(performer.calls.map { $0.operation } == [.spacesUpdate, .spacesUpdate])
        #expect(performer.calls.allSatisfy { $0.payload == payload })

        performer.failures = [WorkspaceClientError.outcomeUnknown, WorkspaceClientError.outcomeUnknown]
        await #expect(throws: WorkspaceClientError.outcomeUnknown) { try await client.perform(.update, payload: payload) }
        #expect(performer.calls.count == 4)
    }

    @Test func aChangedContextIsLoadedAgainOnce() async throws {
        let performer = try SpacesPerformer()
        let client = DirectHermesSpacesClient(workspace: { performer })
        performer.failures = [WorkspaceClientError.conflict]
        _ = try await client.perform(.list, payload: ["agentIds": .array([.string("home")]), "known": .object([:])])
        #expect(performer.calls.count == 2)
        performer.failures = [WorkspaceClientError.conflict, WorkspaceClientError.conflict]
        await #expect(throws: WorkspaceClientError.conflict) {
            try await client.perform(.list, payload: ["agentIds": .array([.string("home")]), "known": .object([:])])
        }
    }
}
