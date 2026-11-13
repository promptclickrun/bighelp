import Foundation
import Testing
@testable import Bighelp

/// Today's spaces from several computers in one order, and what each action sends where.
@MainActor
struct TodaySpacesModelTests {
    typealias Kit = SpacesTestKit

    /// Two computers with the demo's spaces, the one in use first.
    private static func twoComputers(folder: URL) -> (model: TodaySpacesModel, home: HeldSpacesClient, studio: HeldSpacesClient) {
        let home = HeldSpacesClient(Kit.demo())
        let studio = HeldSpacesClient(Kit.demo())
        let model = TodaySpacesModel(
            computers: {
                [Kit.computer("scope-home", name: "Home", client: home),
                 Kit.computer("scope-studio", name: "Studio", client: studio, isCurrent: false)]
            },
            current: { Kit.computer("scope-home", name: "Home", client: home) },
            cacheFolder: folder, clock: { Kit.now })
        return (model, home, studio)
    }

    private static func id(_ scope: String, _ key: String) -> String { TodaySpace.id(scope: scope, key: key) }

    @Test func spacesFromEveryComputerAreInOneOrder() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, _, studio) = Self.twoComputers(folder: folder)
        await model.refresh()
        #expect(model.items.map(\.space.title) == ["Commute", "Commute", "Garden", "Garden", "Workouts", "Workouts"])
        // Same place: the computer in use first.
        #expect(model.items.prefix(2).map(\.computerName) == ["Home", "Studio"])
        #expect(model.showsComputerNames)
        #expect(model.items.first?.botName == "Travel")

        // Same place on one computer: by title.
        _ = try await SpacesAPI(client: studio).update(agentID: "home", spaceID: DemoSpacesClient.gardenID,
                                                       changes: SpaceChanges(position: 1_024))
        await model.refresh()
        #expect(model.items.prefix(3).map(\.id) == [
            Self.id("scope-home", Kit.commute), Self.id("scope-studio", Kit.commute), Self.id("scope-studio", Kit.garden),
        ])
    }

    @Test func oneComputerShowsNoComputerNames() async {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = TodaySpacesModel(computers: { [Kit.computer(client: Kit.demo())] }, current: { nil },
                                     cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        #expect(model.items.count == 3)
        #expect(!model.showsComputerNames)
        // Drafts never show on Today.
        #expect(!model.items.contains { $0.space.spaceID == DemoSpacesClient.spendingDraftID })
    }

    @Test func aReorderSendsOnlyTheSpacesWhosePlaceChanged() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, home, studio) = Self.twoComputers(folder: folder)
        await model.refresh()
        let order = [
            Self.id("scope-home", Kit.commute), Self.id("scope-home", Kit.workouts), Self.id("scope-studio", Kit.commute),
            Self.id("scope-home", Kit.garden), Self.id("scope-studio", Kit.garden), Self.id("scope-studio", Kit.workouts),
        ]
        let sending = model.reorder(order)
        // The new order shows before any computer answers: a drag never jumps back for a frame.
        #expect(model.items.map(\.id) == order)
        await sending.value
        #expect(model.items.map(\.id) == order)
        #expect(model.items.map(\.space.position) == [1_024, 2_048, 3_072, 4_096, 5_120, 6_144])

        func sent(_ client: HeldSpacesClient) -> [String: BighelpJSONValue] {
            var sent: [String: BighelpJSONValue] = [:]
            for call in client.payloads where call.operation == .update {
                if let space = call.payload["spaceId"]?.string { sent[space] = call.payload["changes"]?.object?["position"] }
            }
            return sent
        }
        // Home's commute stays at 1,024 and isn't sent; each change goes to its own computer.
        #expect(sent(home) == [DemoSpacesClient.workoutsID: .number(2_048), DemoSpacesClient.gardenID: .number(4_096)])
        #expect(sent(studio) == [DemoSpacesClient.commuteID: .number(3_072), DemoSpacesClient.gardenID: .number(5_120),
                                 DemoSpacesClient.workoutsID: .number(6_144)])
        #expect(model.stores.values.allSatisfy { $0.pending.isEmpty })
    }

    @Test func aHiddenSpaceLeavesTodayButStaysInTheList() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let model = TodaySpacesModel(computers: { [Kit.computer(client: demo)] }, current: { nil },
                                     cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let garden = Self.id("scope-home", Kit.garden)
        try await model.setHidden(garden, true)
        #expect(!model.shown.contains { $0.id == garden })
        #expect(model.items.contains { $0.id == garden })
        #expect(model.hiddenCount == 1)
        let onComputer = try await SpacesAPI(client: demo).space(agentID: "home", spaceID: DemoSpacesClient.gardenID)
        #expect(onComputer.hidden)
        try await model.setHidden(garden, false)
        #expect(model.hiddenCount == 0)
    }

    @Test func aComputerThatIsntConnectedKeepsItsPanels() async {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = SpacesTestConnection(Kit.demo())
        let isConnected = SpacesTestFlag(true)
        let model = TodaySpacesModel(
            computers: { [Kit.computer(client: isConnected.value ? connection.client : nil)] },
            current: { nil }, cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        isConnected.value = false
        await model.refresh()
        #expect(model.items.count == 3)
        #expect(model.items.allSatisfy { !$0.isConnected })
        #expect(model.statuses.map(\.phase) == [.unreachable])
    }

    /// No scope for a computer for a moment (it reconnects, the selection moves) is a gap in the
    /// list, not a removed computer: its store and waiting changes stay.
    @Test func aComputerMissingFromTheListForAMomentKeepsItsStoreAndWaitingChanges() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let listed = SpacesTestFlag(true)
        let model = TodaySpacesModel(
            computers: { listed.value ? [Kit.computer(client: client)] : [] }, current: { nil },
            hostKeys: { ["host-scope-home"] }, cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let store = try #require(model.stores["scope-home"])
        try await store.change(Kit.garden, SpaceChanges(size: .tall), api: nil)

        listed.value = false
        await model.refresh()
        #expect(model.stores["scope-home"] === store)
        #expect(store.pending[Kit.garden] != nil)

        listed.value = true
        await model.refresh()
        #expect(model.stores["scope-home"] === store)
        #expect(store.pending.isEmpty)
    }

    @Test func aRemovedComputerLeavesNoSpacesInMemoryOrOnDisk() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = HeldSpacesClient(Kit.demo())
        let model = TodaySpacesModel(
            computers: { [Kit.computer(client: client), Kit.computer("scope-studio", name: "Studio", client: client,
                                                                     isCurrent: false)] },
            current: { nil }, cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let store = try #require(model.stores["scope-home"])
        await store.savedToDisk()
        await model.stores["scope-studio"]?.savedToDisk()
        #expect(SpacesCacheFile.read(scope: "scope-home", folder: folder) != nil)

        model.forget(hostKey: "host-scope-home", scope: "scope-home")
        #expect(model.stores["scope-home"] == nil)
        #expect(!model.items.contains { $0.scope == "scope-home" })
        // The erase waits for a write under way, so nothing brings the file back.
        try await store.change(Kit.garden, SpaceChanges(size: .tall), api: nil)
        for _ in 0..<50 { await Task.yield() }
        await store.savedToDisk()
        #expect(SpacesCacheFile.read(scope: "scope-home", folder: folder) == nil)
        // The other computer keeps its panels and its copy.
        #expect(model.stores["scope-studio"] != nil)
        #expect(SpacesCacheFile.read(scope: "scope-studio", folder: folder) != nil)
    }

    @Test func aStoppedSpaceRunsAgainButNotTwiceInAMinute() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // One computer for the whole test: the model asks for its connection again at each call.
        let demo = Kit.demo()
        let model = TodaySpacesModel(computers: { [Kit.computer(client: demo)] }, current: { nil },
                                     cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let garden = Self.id("scope-home", Kit.garden)
        #expect(model.items.first { $0.id == garden }?.space.isStopped == true)
        #expect(try await model.runNow(garden) == .now)
        let space = try #require(model.items.first { $0.id == garden }?.space)
        #expect(!space.isStopped)
        #expect(space.updatedAt == Kit.now)
        do throws(SpacesError) {
            _ = try await model.runNow(garden)
            Issue.record("A second run within a minute went through.")
        } catch {
            #expect(error == .tooSoon(retryAfter: nil))
        }
    }

    @Test func aDeletedSpaceIsGoneFromTodayAndTheComputer() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let model = TodaySpacesModel(computers: { [Kit.computer(client: demo)] }, current: { nil },
                                     cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        try await model.delete(Self.id("scope-home", Kit.commute))
        #expect(!model.items.contains { $0.space.key == Kit.commute })
        do throws(SpacesError) {
            _ = try await SpacesAPI(client: demo).space(agentID: "travel", spaceID: DemoSpacesClient.commuteID)
            Issue.record("The deleted space still reads.")
        } catch {
            #expect(error == .notFound)
        }
    }

    @Test func aDraftIsAddedAfterEverythingOnToday() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, home, _) = Self.twoComputers(folder: folder)
        await model.refresh()
        let api = SpacesAPI(client: home)
        let draft = try await api.space(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID)
        #expect(draft.state == .draft)
        let added = try await model.add(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID,
                                        draftRevision: draft.revision, size: .small, preview: draft)
        #expect(added.state == .live)
        #expect(added.size == .small)
        #expect(model.items.last?.space.key == added.key)
        #expect(added.position == 3_072 + SpacesWire.positionStep)
    }

    /// A chat's Add before Today ever showed this run: the space is on Today at once, after what the
    /// computer has.
    @Test func aDraftAddedBeforeTodayShowsIsOnTodayAtOnce() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, home, _) = Self.twoComputers(folder: folder)
        let draft = try await SpacesAPI(client: home).space(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID)
        let added = try await model.add(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID,
                                        draftRevision: draft.revision, size: nil, preview: draft)
        #expect(model.items.contains { $0.space.key == added.key })
        #expect(added.position == 3_072 + SpacesWire.positionStep)
    }

    @Test func aDraftWhoseScriptIsGoneSaysSo() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        demo.missingScripts = [DemoSpacesClient.spendingDraftID]
        let model = TodaySpacesModel(computers: { [Kit.computer(client: demo)] },
                                     current: { Kit.computer(client: demo) }, cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let draft = try await SpacesAPI(client: demo).space(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID)
        await #expect(throws: SpacesError.scriptMissing) {
            try await model.add(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID,
                                draftRevision: draft.revision, size: nil, preview: draft)
        }
        #expect(!model.items.contains { $0.space.spaceID == DemoSpacesClient.spendingDraftID })
    }

    /// An AI routine the person paused in Scheduled tasks: Update now runs nothing, says so, and the
    /// next one isn't held off.
    @Test func aPausedAIRoutineRunsNothing() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        demo.setRoutine(DemoSpacesClient.workoutsID, agentID: "home", state: .paused)
        let model = TodaySpacesModel(computers: { [Kit.computer(client: demo)] }, current: { nil },
                                     cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let workouts = Self.id("scope-home", Kit.workouts)
        let item = try #require(model.items.first { $0.id == workouts })
        #expect(SpacePanelFooter.state(for: item, size: .tall) == .paused)
        #expect(try await model.runNow(workouts) == .paused)
        #expect(try await model.runNow(workouts) == .paused)
        #expect(model.items.first { $0.id == workouts }?.space.isPaused == true)
    }

    /// The bot changed the script after Add: stopped until it's drafted and added again; Update now
    /// can't run it.
    @Test func aScriptThatChangedStopsTheSpace() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        demo.setRoutine(DemoSpacesClient.commuteID, agentID: "travel", state: .failed,
                        problem: SpacesWire.scriptChangedProblem)
        let model = TodaySpacesModel(computers: { [Kit.computer(client: demo)] }, current: { nil },
                                     cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let commute = Self.id("scope-home", Kit.commute)
        let item = try #require(model.items.first { $0.id == commute })
        #expect(SpacePanelFooter.state(for: item, size: .small) == .scriptChanged)
        do throws(SpacesError) {
            _ = try await model.runNow(commute)
            Issue.record("A changed script ran.")
        } catch {
            guard case .routineFailed(let space) = error else { Issue.record("\(error)"); return }
            #expect(space?.isScriptChanged == true)
        }
    }

    @Test func aDraftTheBotChangedIsRefusedWithItsNewRevision() async throws {
        let folder = Kit.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = Kit.demo()
        let model = TodaySpacesModel(computers: { [Kit.computer(client: demo)] },
                                     current: { Kit.computer(client: demo) }, cacheFolder: folder, clock: { Kit.now })
        await model.refresh()
        let draft = try await SpacesAPI(client: demo).space(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID)
        demo.reviseDraft(DemoSpacesClient.spendingDraftID, agentID: "finance")
        do throws(SpacesError) {
            _ = try await model.add(agentID: "finance", spaceID: DemoSpacesClient.spendingDraftID,
                                    draftRevision: draft.revision, size: nil, preview: draft)
            Issue.record("An old revision was added.")
        } catch {
            #expect(error == .draftChanged(revision: 2))
        }
        // The preview went again: the computer didn't add it.
        #expect(!model.items.contains { $0.space.spaceID == DemoSpacesClient.spendingDraftID })
    }

    /// The same request again gets the first answer; the same `operationId` with another body is
    /// refused, and nothing is done (the plugin's `invalid_request`).
    @Test func aRepeatedOperationGetsTheFirstAnswerOnlyForTheSameRequest() async throws {
        let demo = Kit.demo()
        let api = SpacesAPI(client: demo)
        let operation = SpacesWire.newOperationID()
        let first = try await api.update(agentID: "home", spaceID: DemoSpacesClient.gardenID,
                                         changes: SpaceChanges(size: .tall), operationID: operation)
        let again = try await api.update(agentID: "home", spaceID: DemoSpacesClient.gardenID,
                                         changes: SpaceChanges(size: .tall), operationID: operation)
        #expect(again == first)
        await #expect(throws: SpacesError.other(code: "invalid_request")) {
            try await api.update(agentID: "home", spaceID: DemoSpacesClient.gardenID,
                                 changes: SpaceChanges(size: .small), operationID: operation)
        }
        #expect(try await api.space(agentID: "home", spaceID: DemoSpacesClient.gardenID).size == .tall)
    }
}

/// A switch the computers closure reads; tests flip it.
@MainActor
final class SpacesTestFlag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}
