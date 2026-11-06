import Foundation
import Testing
@testable import Bighelp

/// App state (plugin `native-app-state-v1`): each key's newest revision wins across the person's
/// computers, a change goes on top of whatever another device saved first, and a computer that's
/// behind is brought up to date.
@MainActor
struct AppStateSyncTests {
    static let person = "5f0c2a9e-7d1b-4e5a-9c3f-2b8d6e4a1f07"
    static let studio = "11111111-2222-4333-8444-555555555555"
    static let laptop = "66666666-7777-4888-9999-aaaaaaaaaaaa"
    static let key = "bots.layout"

    private func sync(file: URL? = nil) -> AppStateSync {
        AppStateSync(keys: [Self.key], device: "a1d4c3b2-9e8f-4a7b-8c6d-5e4f3a2b1c0d", file: file,
                     person: { Self.person })
    }

    private func value(_ text: String) throws -> BighelpJSONValue {
        try JSONDecoder().decode(BighelpJSONValue.self, from: Data(text.utf8))
    }

    private func noJoin(_ key: String, _ value: BighelpJSONValue?, _ computers: [String]) -> [AppStatePatch] {
        Issue.record("Nothing should be joined: \(computers)")
        return []
    }

    @Test func theNewestRevisionWinsAcrossTwoComputers() async throws {
        let studio = DemoAppStateClient(computerID: Self.studio), laptop = DemoAppStateClient(computerID: Self.laptop)
        let both = #"["\#(Self.studio)", "\#(Self.laptop)"]"#
        studio.save(.init(value: try value(#"{"v": 1, "primary": "old", "computers": \#(both)}"#), revision: 3),
                    key: Self.key, person: Self.person)
        laptop.save(.init(value: try value(#"{"v": 1, "primary": "new", "computers": \#(both)}"#), revision: 5),
                    key: Self.key, person: Self.person)
        let sync = sync()

        let outcome = await sync.sync([.init(hostKey: "studio", client: studio), .init(hostKey: "laptop", client: laptop)],
                                      join: noJoin)

        #expect(outcome.reached == ["studio", "laptop"])
        #expect(sync.value(Self.key)?.object?["primary"]?.string == "new")
        #expect(studio.stored(Self.person)[Self.key]?.revision == 5, "The computer behind gets the newest revision")
        #expect(studio.stored(Self.person)[Self.key]?.value?.object?["primary"]?.string == "new")
        #expect(laptop.writes == 0, "The newest computer is left alone")
        #expect(sync.computerID(forHost: "laptop") == Self.laptop)
    }

    @Test func aChangeGoesOnTopOfAnotherDevicesWriteAfterAConflict() async throws {
        let demo = DemoAppStateClient(computerID: Self.studio)
        demo.save(.init(value: try value(#"{"v": 1, "sections": [{"id": "s1", "name": "Work"}], "computers": ["\#(Self.studio)"]}"#),
                        revision: 2), key: Self.key, person: Self.person)
        let sync = sync()
        await sync.sync([.init(hostKey: "studio", client: demo)], join: noJoin)
        sync.change(Self.key, [AppStatePatch(path: ["primary"], value: .string("mina"))])
        // Another phone writes between this phone's read and its write.
        let racing = RacingAppStateClient(demo) {
            demo.save(.init(value: try! self.value(
                #"{"v": 1, "sections": [{"id": "s1", "name": "Work"}, {"id": "s2", "name": "Home"}], "computers": ["\#(Self.studio)"]}"#),
                            revision: 3), key: Self.key, person: Self.person)
        }

        await sync.sync([.init(hostKey: "studio", client: racing)], join: noJoin)

        let stored = try #require(demo.stored(Self.person)[Self.key])
        #expect(stored.revision == 4)
        #expect(stored.value?.object?["primary"]?.string == "mina", "This phone's change is applied again")
        #expect(stored.value?.object?["sections"]?.array?.count == 2, "The other phone's section stays")
        #expect(racing.conflicts == 1)
        #expect(sync.saved.pending.isEmpty)
    }

    @Test func aComputerThatIsBehindIsBroughtUpToDate() async throws {
        let studio = DemoAppStateClient(computerID: Self.studio), laptop = DemoAppStateClient(computerID: Self.laptop)
        let both = #"["\#(Self.studio)", "\#(Self.laptop)"]"#
        studio.save(.init(value: try value(#"{"v": 1, "primary": "mina", "computers": \#(both)}"#), revision: 4),
                    key: Self.key, person: Self.person)
        laptop.save(.init(value: try value(#"{"v": 1, "primary": "otto", "computers": \#(both)}"#), revision: 2),
                    key: Self.key, person: Self.person)
        let sync = sync()
        await sync.sync([.init(hostKey: "studio", client: studio)], join: noJoin)

        // Later, only the laptop is reached: this phone's copy is newer, so the laptop takes it.
        await sync.sync([.init(hostKey: "laptop", client: laptop)], join: noJoin)

        #expect(laptop.stored(Self.person)[Self.key]?.revision == 4)
        #expect(laptop.stored(Self.person)[Self.key]?.value?.object?["primary"]?.string == "mina")
        #expect(studio.writes == 0)
    }

    @Test func aKeyIsSeededFromThePhoneOnlyWhenNoComputerHasIt() async throws {
        let studio = DemoAppStateClient(computerID: Self.studio), laptop = DemoAppStateClient(computerID: Self.laptop)
        var joins: [(BighelpJSONValue?, [String])] = []
        let sync = sync()

        await sync.sync([.init(hostKey: "studio", client: studio), .init(hostKey: "laptop", client: laptop)]) { _, value, ids in
            joins.append((value, ids))
            return [AppStatePatch(path: ["v"], value: .integer(1)), AppStatePatch(path: ["primary"], value: .string("mina"))]
        }

        #expect(joins.count == 1)
        #expect(joins.first?.0 == nil, "Nothing on any computer: the phone's choices seed it")
        #expect(joins.first?.1 == [Self.studio, Self.laptop])
        for client in [studio, laptop] {
            let stored = try #require(client.stored(Self.person)[Self.key])
            #expect(stored.revision == 1)
            #expect(stored.value?.object?["primary"]?.string == "mina")
            #expect(stored.value?.object?["computers"]?.array == [.string(Self.studio), .string(Self.laptop)])
        }
    }

    @Test func aComputerReachedForTheFirstTimeGetsThePhonesPartButTheValueOnAnotherWins() async throws {
        let studio = DemoAppStateClient(computerID: Self.studio), laptop = DemoAppStateClient(computerID: Self.laptop)
        studio.save(.init(value: try value(#"{"v": 1, "primary": "mina", "computers": ["\#(Self.studio)"]}"#), revision: 6),
                    key: Self.key, person: Self.person)
        var joins: [(BighelpJSONValue?, [String])] = []
        let sync = sync()

        await sync.sync([.init(hostKey: "studio", client: studio), .init(hostKey: "laptop", client: laptop)]) { _, value, ids in
            joins.append((value, ids))
            return [AppStatePatch(path: ["home", Self.laptop], value: .string("laptop order"))]
        }

        #expect(joins.count == 1)
        #expect(joins.first?.0?.object?["primary"]?.string == "mina", "The value already on a computer is kept")
        #expect(joins.first?.1 == [Self.laptop], "Only the computer not listed yet is joined")
        for client in [studio, laptop] {
            let stored = try #require(client.stored(Self.person)[Self.key])
            #expect(stored.revision == 7)
            #expect(stored.value?.object?["primary"]?.string == "mina")
            #expect(stored.value?.object?["home"]?.object?[Self.laptop]?.string == "laptop order")
            #expect(stored.value?.object?["computers"]?.array == [.string(Self.studio), .string(Self.laptop)])
        }
    }

    @Test func aFreshInstallTakesWhatTheComputerHas() async throws {
        let studio = DemoAppStateClient(computerID: Self.studio)
        let saved = try value(#"{"v": 1, "home": {"x": {"list": ["bot/x/mina", "bot/x/otto"]}}, "computers": ["\#(Self.studio)"]}"#)
        studio.save(.init(value: saved, revision: 9), key: Self.key, person: Self.person)
        let sync = sync()

        await sync.sync([.init(hostKey: "studio", client: studio)], join: noJoin)

        #expect(sync.value(Self.key) == saved)
        #expect(studio.writes == 0, "An empty phone never overwrites the computer")
    }

    @Test func fieldsANewerAppAddedAreKept() async throws {
        let studio = DemoAppStateClient(computerID: Self.studio)
        studio.save(.init(value: try value("""
            {"v": 1, "future": {"pins": ["a"]}, "computers": ["\(Self.studio)"],
             "sections": [{"id": "s1", "name": "Work", "color": "red"}, {"id": "s2", "name": "Old"}]}
            """), revision: 1), key: Self.key, person: Self.person)
        let sync = sync()
        await sync.sync([.init(hostKey: "studio", client: studio)], join: noJoin)

        sync.change(Self.key, [AppStatePatch(path: ["sections"], value: try value(#"[{"id": "s1", "name": "Home"}]"#),
                                             fields: ["id", "name"])])
        await sync.sync([.init(hostKey: "studio", client: studio)], join: noJoin)

        let stored = try #require(studio.stored(Self.person)[Self.key]?.value?.object)
        #expect(stored["future"] == (try value(#"{"pins": ["a"]}"#)))
        #expect(stored["sections"] == (try value(#"[{"id": "s1", "name": "Home", "color": "red"}]"#)))
    }

    @Test func aComputerWithoutTheFeatureIsLeftAlone() async throws {
        let old = UnsupportedAppStateClient()
        let sync = sync()
        sync.change(Self.key, [AppStatePatch(path: ["primary"], value: .string("mina"))])

        let outcome = await sync.sync([.init(hostKey: "old", client: old)], join: noJoin)

        #expect(outcome.lacking == ["old"])
        #expect(outcome.reached.isEmpty)
        #expect(sync.value(Self.key)?.object?["primary"]?.string == "mina", "The phone keeps its own choice")
        #expect(sync.saved.pending[Self.key]?.count == 1, "It waits for a computer that keeps it")
    }

    @Test func theValuesAndUnsentChangesSurviveARelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "app-state-\(UUID().uuidString)/state.json")
        let studio = DemoAppStateClient(computerID: Self.studio)
        let first = sync(file: file)
        await first.sync([.init(hostKey: "studio", client: studio)]) { _, _, _ in
            [AppStatePatch(path: ["primary"], value: .string("mina"))]
        }
        first.change(Self.key, [AppStatePatch(path: ["primary"], value: .string("otto"))])

        let again = sync(file: file)

        #expect(again.value(Self.key)?.object?["primary"]?.string == "otto")
        #expect(again.computerID(forHost: "studio") == Self.studio)
        await again.sync([.init(hostKey: "studio", client: studio)], join: noJoin)
        #expect(studio.stored(Self.person)[Self.key]?.value?.object?["primary"]?.string == "otto")
        #expect(studio.stored(Self.person)[Self.key]?.revision == 2)
    }

    // MARK: Patches

    @Test func aDiffChangesOnlyWhatChanged() throws {
        let shape = AppStateShape.object([
            "sections": .leaf(fields: ["id", "name"]),
            "bots": .map(.object(["voice": .leaf(), "mark": .leaf()])),
        ])
        let old = try value(#"{"sections": [{"id": "s1", "name": "Work"}], "bots": {"a": {"voice": "x", "mark": "m"}, "b": {"mark": "n"}}}"#)
        let new = try value(#"{"sections": [{"id": "s1", "name": "Work"}], "bots": {"a": {"voice": "y", "mark": "m"}, "c": {"mark": "o"}}}"#)

        let patches = shape.patches(from: old, to: new)

        #expect(patches == [
            AppStatePatch(path: ["bots", "a", "voice"], value: .string("y")),
            AppStatePatch(path: ["bots", "b", "mark"], value: nil),
            AppStatePatch(path: ["bots", "c", "mark"], value: .string("o")),
        ])
        let applied = patches.reduce(old) { $1.applied(to: $0) }
        #expect(applied == new, "Removing a bot's last choice removes the bot")
    }

    @Test func answersAreReadLeniently() throws {
        let answer = try AppStateWire.answer(try value("""
            {"computerId": "\(Self.studio)", "extra": true, "keys": {
              "bots.layout": {"value": {"v": 1}, "revision": 12, "updatedAt": "2026-11-06T17:02:11Z", "device": "x"},
              "bots.settings": {"value": null, "revision": 3},
              "Bad Key": {"value": 1, "revision": 1},
              "no.revision": {"value": 1},
              "too.big": {"value": 1, "revision": 9007199254740993}}}
            """).object!)

        #expect(answer.computerID == Self.studio)
        #expect(answer.entries == ["bots.layout": .init(value: .object(["v": .integer(1)]), revision: 12),
                                   "bots.settings": .init(value: nil, revision: 3)])
        #expect(throws: WorkspaceClientError.invalidResponse) {
            try AppStateWire.answer(["computerId": .string("NOT-A-UUID"), "keys": .object([:])])
        }
    }
}

/// Lets another device write once, between this phone's read and its first write.
@MainActor
final class RacingAppStateClient: AppStateClient {
    private let base: DemoAppStateClient
    private var race: (() -> Void)?
    private(set) var conflicts = 0

    init(_ base: DemoAppStateClient, race: @escaping () -> Void) {
        self.base = base
        self.race = race
    }

    func read(person: String, keys: [String]) async throws -> AppStateWire.Answer {
        try await base.read(person: person, keys: keys)
    }

    func write(person: String, device: String, writes: [String: AppStateWire.Write]) async throws -> AppStateWire.Answer {
        if let race {
            self.race = nil
            race()
        }
        do {
            return try await base.write(person: person, device: device, writes: writes)
        } catch AppStateError.conflict {
            conflicts += 1
            throw AppStateError.conflict
        }
    }
}

/// A computer whose plugin is older than the feature.
@MainActor
final class UnsupportedAppStateClient: AppStateClient {
    func read(person: String, keys: [String]) async throws -> AppStateWire.Answer { throw AppStateError.needsPluginUpdate }
    func write(person: String, device: String, writes: [String: AppStateWire.Write]) async throws -> AppStateWire.Answer {
        throw AppStateError.needsPluginUpdate
    }
}
