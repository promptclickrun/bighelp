import Foundation
import Testing
@testable import Bighelp

/// Bots mode's choices on the person's computers (`bots.layout`, `bots.settings`): named by each
/// computer's own ID, never by the host ID a phone makes, so a reinstall or another phone gets
/// them back in its own stores.
@MainActor
struct BotsAppStateTests {
    static let computer = "0d3e5c1a-7b2f-4c6d-9e8a-1f2b3c4d5e6f"
    static let firstPhoneHost = UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!
    static let secondPhoneHost = UUID(uuidString: "B2B2B2B2-0000-4000-8000-000000000002")!

    static func host(_ id: UUID, scope: String) -> BotsAppStateHost {
        BotsAppStateHost(hostKey: id.uuidString, scopes: [scope], faceScope: CompanionSurfaceScope.computer(id.uuidString),
                         isSelected: true)
    }

    private var firstPhone: BotsPhoneState {
        let face = CompanionSurfaceScope.computer(Self.firstPhoneHost.uuidString)
        return BotsPhoneState(
            orders: ["scope-1": ["bot:mina", "group:hermes-room:crash-1611de2eb694", "bot:otto"],
                     // On top, bare bot IDs: a profile with one gateway, a `FleetID` with Multi-gateway.
                     "top|scope-1": ["otto"],
                     "multi-gateway": ["bot:\(Self.firstPhoneHost.uuidString)/otto", "bot:\(Self.firstPhoneHost.uuidString)/mina"],
                     "top|multi-gateway": ["\(Self.firstPhoneHost.uuidString)/mina"]],
            sections: [FleetSection(id: "sec-m3k2a-q8z1x", name: "Work")],
            groupSections: [FleetID.make(Self.firstPhoneHost, "group/crash-1611de2eb694"): "sec-m3k2a-q8z1x"],
            primary: FleetID.make(Self.firstPhoneHost, "mina"),
            voices: [AgentVoiceChoices.entryKey(computer: "scope-1", agentID: "mina"):
                        .init(mode: "live", liveProvider: "gemini", liveVoices: ["gemini": "Puck"])],
            marks: [CompanionStore.agentKey(agentScope: face, agentID: "mina"): SimpleBotMark(shape: .heart, color: .teal)],
            pets: [CompanionStore.agentKey(agentScope: face, agentID: "otto"): "boba"],
            characters: [CompanionStore.agentKey(agentScope: face, agentID: "juno"):
                            CompanionAppearance(character: .lobster, colorHex: "#3366CC")],
            pins: ["scope-1": .init(pinned: ["otto", "juno"], unpinned: ["default"], primary: "mina")])
    }

    private func strings(in value: BighelpJSONValue?) -> [String] {
        switch value {
        case .string(let text)?: [text]
        case .array(let items)?: items.flatMap { strings(in: $0) }
        case .object(let fields)?: fields.flatMap { [$0.key] + strings(in: $0.value) }
        default: []
        }
    }

    @Test func aPhonesChoicesAreNamedByTheComputerAndComeBackOnAnotherPhone() throws {
        let first = BotsAppState.Names(hosts: [Self.host(Self.firstPhoneHost, scope: "scope-1")],
                                       computerIDs: [Self.firstPhoneHost.uuidString: Self.computer])
        let layout = BotsAppState.layout(firstPhone, names: first)
        let settings = BotsAppState.settings(firstPhone, names: first)

        let home = try #require(layout.object?["home"]?.object?[Self.computer]?.object)
        #expect(home["list"] == .array(["bot/\(Self.computer)/mina", "group/\(Self.computer)/crash-1611de2eb694",
                                        "bot/\(Self.computer)/otto"].map(BighelpJSONValue.string)))
        #expect(home["top"] == .array([.string("bot/\(Self.computer)/otto")]))
        #expect(home["pinned"] == .array(["\(Self.computer)/otto", "\(Self.computer)/juno"].map(BighelpJSONValue.string)))
        #expect(layout.object?["primary"] == .string("\(Self.computer)/mina"))
        #expect(settings.object?["bots"]?.object?["\(Self.computer)/mina"]?.object?["mark"]
                == .object(["shape": .string("heart"), "color": .string("teal")]))
        let sent = strings(in: layout) + strings(in: settings)
        #expect(!sent.contains { $0.contains(Self.firstPhoneHost.uuidString) || $0.contains("scope-1") },
                "Nothing this phone made up for itself goes to the computer")
        #expect(!sent.contains { $0.contains("bot:") || $0.contains("group:") || $0.contains("room:") },
                "Items go by the computer's names, never the phone's own `bot:` keys")

        // Another phone: its own host ID and sign-in for the same computer.
        let second = BotsAppState.Names(hosts: [Self.host(Self.secondPhoneHost, scope: "scope-2")],
                                        computerIDs: [Self.secondPhoneHost.uuidString: Self.computer])
        let listed = { (value: BighelpJSONValue) in
            AppStatePatch(path: ["computers"], value: .array([.string(Self.computer)])).applied(to: value)
        }
        var restored = BotsAppState.applying(layout: listed(layout), to: BotsPhoneState(), names: second)
        restored = BotsAppState.applying(settings: listed(settings), to: restored, names: second)

        let face = CompanionSurfaceScope.computer(Self.secondPhoneHost.uuidString)
        let host = Self.secondPhoneHost.uuidString
        #expect(restored.orders == ["scope-2": ["bot:mina", "group:hermes-room:crash-1611de2eb694", "bot:otto"],
                                    "top|scope-2": ["otto"],
                                    "multi-gateway": ["bot:\(host)/otto", "bot:\(host)/mina"],
                                    "top|multi-gateway": ["\(host)/mina"]])
        #expect(restored.sections == [FleetSection(id: "sec-m3k2a-q8z1x", name: "Work")])
        #expect(restored.groupSections == [FleetID.make(Self.secondPhoneHost, "group/crash-1611de2eb694"): "sec-m3k2a-q8z1x"])
        #expect(restored.primary == FleetID.make(Self.secondPhoneHost, "mina"))
        #expect(restored.voices == [AgentVoiceChoices.entryKey(computer: "scope-2", agentID: "mina"):
                                        .init(mode: "live", liveProvider: "gemini", liveVoices: ["gemini": "Puck"])])
        #expect(restored.marks == [CompanionStore.agentKey(agentScope: face, agentID: "mina"): SimpleBotMark(shape: .heart, color: .teal)])
        #expect(restored.pets == [CompanionStore.agentKey(agentScope: face, agentID: "otto"): "boba"])
        #expect(restored.characters[CompanionStore.agentKey(agentScope: face, agentID: "juno")]?.colorHex == "#3366CC")
        #expect(restored.pins == ["scope-2": .init(pinned: ["otto", "juno"], unpinned: ["default"], primary: "mina")])
    }

    @Test func aCatalogCharactersFullAddressComesBackOnAnotherPhone() throws {
        let kitURL = "https://avatars.bighelp.app/v1/kits/\(String(repeating: "ab", count: 32)).json"
        let reference = AvatarCatalogReference(id: "fox", name: "Fox", kitSHA256: String(repeating: "ab", count: 32),
                                               kitURL: URL(string: kitURL)!)
        let face = CompanionSurfaceScope.computer(Self.firstPhoneHost.uuidString)
        let phone = BotsPhoneState(characters: [CompanionStore.agentKey(agentScope: face, agentID: "juno"):
                                                    CompanionAppearance(character: .lobster, catalogAvatar: reference)])
        let first = BotsAppState.Names(hosts: [Self.host(Self.firstPhoneHost, scope: "scope-1")],
                                       computerIDs: [Self.firstPhoneHost.uuidString: Self.computer])

        let settings = BotsAppState.settings(phone, names: first)

        #expect(strings(in: settings).contains(kitURL), "The plugin takes links, so the address goes as it is")
        let second = BotsAppState.Names(hosts: [Self.host(Self.secondPhoneHost, scope: "scope-2")],
                                        computerIDs: [Self.secondPhoneHost.uuidString: Self.computer])
        let listed = AppStatePatch(path: ["computers"], value: .array([.string(Self.computer)])).applied(to: settings)
        let restored = BotsAppState.applying(settings: listed, to: BotsPhoneState(), names: second)
        let secondFace = CompanionSurfaceScope.computer(Self.secondPhoneHost.uuidString)
        let look = try #require(restored.characters[CompanionStore.agentKey(agentScope: secondFace, agentID: "juno")])
        #expect(look.catalogAvatar == reference)
        #expect(look.catalogAvatar?.kitURL.absoluteString == kitURL)
    }

    /// Pinned and hidden group chats, group chats on top and in Multi-gateway's order go by the
    /// computer, and come back on another phone by its own host ID.
    @Test func groupChatsPinsHidesAndPlacesComeBackOnAnotherPhone() throws {
        let host = Self.firstPhoneHost.uuidString, computer = Self.computer
        let first = BotsAppState.Names(hosts: [Self.host(Self.firstPhoneHost, scope: "scope-1")],
                                       computerIDs: [host: computer])
        let crew = FleetID.make(Self.firstPhoneHost, "group/crew-1611de2eb694")
        let phone = BotsPhoneState(
            orders: ["top|scope-1": ["group:hermes-room:crew-1611de2eb694", "otto"],
                     "multi-gateway": ["group:\(crew)", "bot:\(host)/otto"],
                     "top|multi-gateway": ["group:\(crew)", "\(host)/otto"]],
            pinnedGroups: [crew], hiddenGroups: [FleetID.make(Self.firstPhoneHost, "group/quiet")])

        let layout = BotsAppState.layout(phone, names: first)

        let both = BighelpJSONValue.array(["group/\(computer)/crew-1611de2eb694", "bot/\(computer)/otto"]
            .map(BighelpJSONValue.string))
        #expect(layout.object?["pinnedGroups"] == .array([.string("\(computer)/crew-1611de2eb694")]))
        #expect(layout.object?["hiddenGroups"] == .array([.string("\(computer)/quiet")]))
        #expect(layout.object?["home"]?.object?[computer]?.object?["top"] == both, "A pinned group chat on top")
        #expect(layout.object?["multiGatewayHome"]?.object?["list"] == both)
        #expect(layout.object?["multiGatewayHome"]?.object?["top"] == both)

        let other = Self.secondPhoneHost.uuidString
        let second = BotsAppState.Names(hosts: [Self.host(Self.secondPhoneHost, scope: "scope-2")],
                                        computerIDs: [other: computer])
        let listed = AppStatePatch(path: ["computers"], value: .array([.string(computer)])).applied(to: layout)
        let restored = BotsAppState.applying(layout: listed, to: BotsPhoneState(), names: second)
        let crewThere = FleetID.make(Self.secondPhoneHost, "group/crew-1611de2eb694")
        #expect(restored.pinnedGroups == [crewThere])
        #expect(restored.hiddenGroups == [FleetID.make(Self.secondPhoneHost, "group/quiet")])
        #expect(restored.orders["top|scope-2"] == ["group:hermes-room:crew-1611de2eb694", "otto"])
        #expect(restored.orders["multi-gateway"] == ["group:\(crewThere)", "bot:\(other)/otto"])
        #expect(restored.orders["top|multi-gateway"] == ["group:\(crewThere)", "\(other)/otto"])
    }

    @Test func orderItemsAnotherPhoneCantNameStayInPlace() {
        let merged = BotsAppState.keepingUnnamed(["bot:a", "x:1", "bot:b", "x:2"], placed: ["bot:b", "bot:a", "bot:c"]) {
            $0.hasPrefix("x:")
        }

        // Each stays after the item it followed: x:1 after bot:a, x:2 after bot:b.
        #expect(merged == ["bot:b", "x:2", "bot:a", "x:1", "bot:c"])
    }

    // MARK: Through the stores

    @MainActor
    private final class Phone {
        let defaults = UserDefaults(suiteName: "BotsAppState-\(UUID().uuidString)")!
        let folder = FileManager.default.temporaryDirectory.appending(path: "bots-app-state-\(UUID().uuidString)")
        lazy var order = SimpleBotsOrderStore(defaults: defaults)
        lazy var fleet = FleetStore(reader: FleetFixtureReader(), directory: folder, saveDelay: .zero)
        lazy var voices = AgentVoiceChoices(defaults: defaults)
        lazy var marks = SimpleBotMarkStore(defaults: defaults)
        lazy var pets = PetAvatarStore(defaults: defaults, directory: folder.appending(path: "pets"))
        lazy var companions = CompanionStore(defaults: defaults)
        var primary: String?
        var restoredPets: [String: String] = [:]
        var pins: [String: AgentDirectoryStore.SavedPins] = [:]

        func sync(host: UUID, scope: String, client: any AppStateClient) -> BotsAppStateSync {
            sync(hosts: [BotsAppStateTests.host(host, scope: scope)],
                 computers: { [AppStateComputer(hostKey: host.uuidString, client: client)] })
        }

        func sync(hosts: [BotsAppStateHost], computers: @escaping @MainActor () -> [AppStateComputer]) -> BotsAppStateSync {
            let bridge = BotsAppStateSync(
                engine: AppStateSync(keys: BotsAppState.keys, device: UUID().uuidString.lowercased(), file: nil,
                                     person: { AppStateSyncTests.person }),
                settle: .seconds(3_600))
            bridge.hosts = { hosts }
            bridge.computers = computers
            bridge.start(BotsAppStateStores(
                order: order, fleet: fleet, primary: { [unowned self] in self.primary },
                setPrimary: { [unowned self] in self.primary = $0 }, voices: voices, marks: marks, pets: pets,
                companions: companions, restorePet: { [unowned self] slug, key in self.restoredPets[key] = slug },
                pins: { [unowned self] in self.pins[$0] ?? .init() }, setPins: { [unowned self] in self.pins[$1] = $0 }))
            return bridge
        }
    }

    /// A computer reached for the first time gets this phone's pinned group chats on it, added to the
    /// list the other computers keep.
    @Test func aComputerReachedForTheFirstTimeGetsThisPhonesPinnedGroupChats() async throws {
        let studioComputer = "1e2d3c4b-5a69-4788-97a6-b5c4d3e2f1a0"
        let home = DemoAppStateClient(computerID: Self.computer), studio = DemoAppStateClient(computerID: studioComputer)
        let studioHost = UUID(uuidString: "C3C3C3C3-0000-4000-8000-000000000003")!
        let phone = Phone()
        var reached = [AppStateComputer(hostKey: Self.firstPhoneHost.uuidString, client: home)]
        let bridge = phone.sync(hosts: [Self.host(Self.firstPhoneHost, scope: "scope-1"),
                                        BotsAppStateHost(hostKey: studioHost.uuidString, scopes: ["scope-3"],
                                                         faceScope: CompanionSurfaceScope.computer(studioHost.uuidString),
                                                         isSelected: false)],
                                computers: { reached })
        phone.fleet.setPinned(groupKey: FleetID.make(Self.firstPhoneHost, "group/crew"), true)
        phone.fleet.setPinned(groupKey: FleetID.make(studioHost, "group/launch"), true)
        await bridge.sync()
        #expect(home.stored(AppStateSyncTests.person)[BotsAppState.layoutKey]?.value?.object?["pinnedGroups"]
                == .array([.string("\(Self.computer)/crew")]), "The studio isn't reached yet")

        reached.append(AppStateComputer(hostKey: studioHost.uuidString, client: studio))
        await bridge.sync()

        let pinned = BighelpJSONValue.array([.string("\(Self.computer)/crew"), .string("\(studioComputer)/launch")])
        #expect(studio.stored(AppStateSyncTests.person)[BotsAppState.layoutKey]?.value?.object?["pinnedGroups"] == pinned)
        #expect(home.stored(AppStateSyncTests.person)[BotsAppState.layoutKey]?.value?.object?["pinnedGroups"] == pinned)
        #expect(phone.fleet.pinnedGroupIDs == [FleetID.make(Self.firstPhoneHost, "group/crew"),
                                               FleetID.make(studioHost, "group/launch")])
    }

    @Test func aFreshInstallGetsTheOrderBackFromTheComputer() async {
        let computer = DemoAppStateClient(computerID: Self.computer)
        let before = Phone()
        before.order.set(["bot:otto", "bot:mina"], scope: "scope-1")
        before.voices.setMode(.codexLive, computer: "scope-1", agentID: "mina")
        before.pins["scope-1"] = .init(pinned: ["juno"], primary: "otto")
        let first = before.sync(host: Self.firstPhoneHost, scope: "scope-1", client: computer)
        await first.sync()
        // Rearranged after the first sync: the change goes to the computer too.
        before.order.set(["bot:mina", "bot:otto"], scope: "scope-1")
        await first.sync()
        let writes = computer.writes

        // Deleted and installed again: a new host ID, sign-in and stores, all empty.
        let after = Phone()
        let second = after.sync(host: Self.secondPhoneHost, scope: "scope-2", client: computer)
        await second.sync()

        #expect(after.order.order(scope: "scope-2") == ["bot:mina", "bot:otto"])
        #expect(after.voices.mode(computer: "scope-2", agentID: "mina") == .codexLive)
        #expect(after.pins["scope-2"] == .init(pinned: ["juno"], primary: "otto"), "The pinned bots and primary bot too")
        #expect(computer.writes == writes, "The empty phone took the computer's choices and sent nothing")
    }

    @Test func theDemosComputerNeverReachesARealOne() async throws {
        let demo = DemoAppStateClient(computerID: "11111111-2222-4333-8444-555555555555")
        let real = DemoAppStateClient(computerID: Self.computer)
        let phone = Phone()
        var inDemo = true
        let engine = { AppStateSync(keys: BotsAppState.keys, device: UUID().uuidString.lowercased(), file: nil,
                                    person: { AppStateSyncTests.person }) }
        let bridge = BotsAppStateSync(engine: engine(), demoEngine: engine(), settle: .seconds(3_600))
        bridge.usesDemo = { inDemo }
        bridge.hosts = {
            [inDemo ? BotsAppStateHost(hostKey: "demo", scopes: ["demo-scope"], faceScope: "fixture-account:fixture-host",
                                       isSelected: true)
                    : Self.host(Self.firstPhoneHost, scope: "scope-1")]
        }
        bridge.computers = {
            [inDemo ? AppStateComputer(hostKey: "demo", client: demo)
                    : AppStateComputer(hostKey: Self.firstPhoneHost.uuidString, client: real)]
        }
        bridge.start(BotsAppStateStores(
            order: phone.order, fleet: phone.fleet, primary: { nil }, setPrimary: { _ in }, voices: phone.voices,
            marks: phone.marks, pets: phone.pets, companions: phone.companions, restorePet: { _, _ in },
            pins: { _ in .init() }, setPins: { _, _ in }))
        phone.order.set(["bot:demo-bot"], scope: "demo-scope")
        await bridge.sync()
        #expect(demo.stored(AppStateSyncTests.person)[BotsAppState.layoutKey] != nil)

        // A real computer added in the same run.
        inDemo = false
        phone.order.set(["bot:mina"], scope: "scope-1")
        await bridge.sync()

        let home = try #require(real.stored(AppStateSyncTests.person)[BotsAppState.layoutKey]?.value?.object?["home"]?.object)
        #expect(Array(home.keys) == [Self.computer], "Only the real computer's bots, never the demo's")
        #expect(bridge.engine.computerID(forHost: "demo") == nil)
    }

    @Test func aHostWithoutTheFeatureKeepsItsChoicesOnThePhone() async {
        let phone = Phone()
        phone.order.set(["bot:otto", "bot:mina"], scope: "scope-1")
        let bridge = phone.sync(host: Self.firstPhoneHost, scope: "scope-1", client: UnsupportedAppStateClient())

        phone.order.set(["bot:mina", "bot:otto"], scope: "scope-1")
        await bridge.sync()

        #expect(phone.order.order(scope: "scope-1") == ["bot:mina", "bot:otto"])
        #expect(bridge.engine.computerID(forHost: Self.firstPhoneHost.uuidString) == nil)
    }
}
