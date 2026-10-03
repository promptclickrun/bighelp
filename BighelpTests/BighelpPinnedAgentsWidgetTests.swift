import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Bighelp

/// The Pinned Agents widget: the pinned agents of the computer in use (Current
/// Gateway) or of every computer (Multi Gateway), as faces with names, each
/// opening a chat with that agent.
@MainActor
struct BighelpPinnedAgentsWidgetTests {
    private static let home = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
    private static let studio = UUID(uuidString: "11111111-0000-4000-8000-000000000002")!
    private static let office = UUID(uuidString: "11111111-0000-4000-8000-000000000003")!

    private static var snapshot: BighelpWidgetSnapshot {
        var snapshot = BighelpWidgetSnapshot(defaultAgentID: "juno", defaultAgentName: "Juno", sessions: [], tasks: [],
                                            generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        snapshot.pinnedAgents = [
            .init(agentID: "juno", name: "Juno", hostID: home.uuidString, hostName: "Home", avatarKey: "abc123"),
            .init(agentID: "rex", name: "Rex", hostID: home.uuidString, hostName: "Home"),
        ]
        snapshot.allPinnedAgents = snapshot.pinnedAgents! + [
            .init(agentID: "juno", name: "Juno", hostID: studio.uuidString, hostName: "Studio"),
        ]
        return snapshot
    }

    // MARK: Snapshot

    @Test func pinnedAgentsRoundTripAndOlderSnapshotsStillLoad() throws {
        let data = try JSONEncoder.bighelpWidget.encode(Self.snapshot)
        let decoded = try JSONDecoder.bighelpWidget.decode(BighelpWidgetSnapshot.self, from: data)
        #expect(decoded == Self.snapshot)
        #expect(decoded.pinnedAgents(.current).map(\.name) == ["Juno", "Rex"])
        #expect(decoded.pinnedAgents(.multi).map(\.hostName) == ["Home", "Home", "Studio"])
        // Two agents can share an ID on different computers; the widget tells them apart.
        #expect(Set(decoded.pinnedAgents(.multi).map(\.id)).count == 3)

        // A snapshot written before the widget existed has none, and says so plainly.
        let json = #"{"defaultAgentID":"juno","defaultAgentName":"Juno","sessions":[],"tasks":[],"generatedAt":1800000000}"#
        let old = try JSONDecoder.bighelpWidget.decode(BighelpWidgetSnapshot.self, from: Data(json.utf8))
        #expect(old.pinnedAgents == nil && old.allPinnedAgents == nil)
        #expect(old.pinnedAgents(.current).isEmpty && old.pinnedAgents(.multi).isEmpty)
    }

    @Test func theWidgetKindReloadsWithTheOthers() {
        #expect(BighelpWidgetSnapshot.widgetKinds.contains(BighelpWidgetSnapshot.pinnedAgentsWidgetKind))
        #expect(BighelpWidgetSnapshot.pinnedAgentsWidgetKind == "BighelpPinnedAgentsWidget")
    }

    @Test func linksCarryTheAgentAndItsComputer() {
        let current = BighelpWidgetSnapshot.agentChatURL(agentID: "juno")
        #expect(BighelpIncomingURLRoute.parse(current) == .agentChat(agentID: "juno", hostID: nil))
        let multi = BighelpWidgetSnapshot.agentChatURL(agentID: "rex", hostID: Self.studio.uuidString)
        #expect(BighelpIncomingURLRoute.parse(multi) == .agentChat(agentID: "rex", hostID: Self.studio))
        // The pinned agent's own link: Current Gateway leaves the computer out.
        let juno = Self.snapshot.pinnedAgents(.current)[0]
        #expect(BighelpIncomingURLRoute.parse(juno.link(.current)) == .agentChat(agentID: "juno", hostID: nil))
        #expect(BighelpIncomingURLRoute.parse(juno.link(.multi)) == .agentChat(agentID: "juno", hostID: Self.home))
    }

    @Test func agentChatLinksAreValidatedAndBounded() {
        func parse(_ string: String) -> BighelpIncomingURLRoute? { URL(string: string).flatMap(BighelpIncomingURLRoute.parse) }
        let host = Self.home.uuidString
        #expect(parse("loopdy://agent-chat?agent=juno") == .agentChat(agentID: "juno", hostID: nil))
        #expect(parse("loopdy://agent-chat?agent=juno&host=\(host)") == .agentChat(agentID: "juno", hostID: Self.home))
        #expect(parse("loopdy://agent-chat?agent=juno&host=\(host.lowercased())") == .agentChat(agentID: "juno", hostID: Self.home))
        #expect(parse("LOOPDY://AGENT-CHAT?agent=juno") == .agentChat(agentID: "juno", hostID: nil))
        #expect(parse("loopdy://agent-chat?agent=my%20agent") == .agentChat(agentID: "my agent", hostID: nil))
        // Missing, empty, too long or odd: not a link to open.
        #expect(parse("loopdy://agent-chat") == nil)
        #expect(parse("loopdy://agent-chat?agent=") == nil)
        #expect(parse("loopdy://agent-chat?host=\(host)") == nil)
        #expect(parse("loopdy://agent-chat?agent=" + String(repeating: "a", count: 97)) == nil)
        #expect(parse("loopdy://agent-chat?agent=" + String(repeating: "a", count: 96)) != nil)
        #expect(parse("loopdy://agent-chat?agent=a%0Ab") == nil, "No control characters")
        #expect(parse("loopdy://agent-chat?agent=%20juno") == nil, "No padding")
        #expect(parse("loopdy://agent-chat?agent=juno&host=not-a-computer") == nil)
        #expect(parse("loopdy://agent-chat?agent=juno&host=") == nil)
        #expect(parse("loopdy://agent-chat?agent=juno&agent=rex") == nil, "One agent only")
        #expect(parse("loopdy://agent-chat/extra?agent=juno") == nil)
    }

    // MARK: The app's side

    private func fleet(hosts: [FleetHost]) -> (FleetStore, FleetStoreTests.Reader) {
        let reader = FleetStoreTests.Reader(hosts: hosts)
        let directory = FileManager.default.temporaryDirectory.appending(path: "pinned-widget-\(UUID().uuidString)")
        return (FleetStore(reader: reader, directory: directory), reader)
    }

    private func fleetAgent(_ host: UUID, _ id: String, _ name: String, pinned: Bool = true) -> FleetAgent {
        FleetAgent(hostID: host, profileID: id, name: name, role: "", isPinned: pinned, isDefault: false)
    }

    @Test func currentGatewayListsThisComputersPinsInTheirOrder() throws {
        let (fleet, _) = fleet(hosts: [.init(id: Self.home, name: "Home Hermes", isSelected: true),
                                       .init(id: Self.studio, name: "Studio Mac", isSelected: false)])
        let picture = URL(fileURLWithPath: "/tmp/juno.png")
        let lists = BighelpPinnedAgentsWidgetFeed.lists(
            livePins: [.init(agentID: "rex", name: "Rex", picture: nil),
                       .init(agentID: "juno", name: "Juno  Park", picture: picture)],
            fleet: fleet)
        #expect(lists.current.map(\.agentID) == ["rex", "juno"])
        #expect(lists.current.map(\.name) == ["Rex", "Juno Park"])
        #expect(lists.current.allSatisfy { $0.hostID == Self.home.uuidString && $0.hostName == "Home Hermes" })
        // Only agents with a picture get a file; the others show their initial.
        #expect(lists.current[0].avatarKey == nil)
        let key = try #require(lists.current[1].avatarKey)
        #expect(lists.pictures[key] == picture)
        #expect(BighelpPinnedAvatarStore.fileURL(key: key, in: URL(fileURLWithPath: "/tmp")) != nil)
    }

    @Test func multiGatewayListsEveryComputerAndSkipsRemovedOnes() async {
        let (fleet, reader) = fleet(hosts: [.init(id: Self.home, name: "Home Hermes", isSelected: true),
                                            .init(id: Self.studio, name: "Studio Mac", isSelected: false),
                                            .init(id: Self.office, name: "Office Linux", isSelected: false)])
        // A stale copy of the computer in use: its live pins win.
        fleet.recordLive(FleetSnapshot(agents: [fleetAgent(Self.home, "old", "Old pin")], refreshedAt: .now),
                         hostID: Self.home)
        fleet.recordLive(FleetSnapshot(agents: [fleetAgent(Self.studio, "juno", "Juno"),
                                                fleetAgent(Self.studio, "sage", "Sage", pinned: false)],
                                       refreshedAt: .now), hostID: Self.studio)
        fleet.recordLive(FleetSnapshot(agents: [fleetAgent(Self.office, "ops", "Ops")], refreshedAt: .now),
                         hostID: Self.office)
        let live: [BighelpPinnedAgentsWidgetFeed.Pin] = [.init(agentID: "juno", name: "Juno", picture: nil)]
        var lists = BighelpPinnedAgentsWidgetFeed.lists(livePins: live, fleet: fleet)
        #expect(lists.current.map(\.agentID) == ["juno"])
        #expect(lists.all.map { "\($0.hostName ?? "?")/\($0.agentID)" }
                == ["Home Hermes/juno", "Studio Mac/juno", "Office Linux/ops"])
        // Same agent ID on two computers: two faces, two pictures.
        #expect(lists.all[0].id != lists.all[1].id)

        // The person's dragged order across computers comes first.
        fleet.reorderPinned([FleetID.make(Self.office, "ops"), FleetID.make(Self.home, "juno")])
        lists = BighelpPinnedAgentsWidgetFeed.lists(livePins: live, fleet: fleet)
        #expect(lists.all.map(\.agentID) == ["ops", "juno", "juno"])

        // A removed computer's agents are gone from the widget.
        reader.hosts.removeAll { $0.id == Self.office }
        fleet.syncHosts()
        lists = BighelpPinnedAgentsWidgetFeed.lists(livePins: live, fleet: fleet)
        #expect(!lists.all.contains { $0.hostID == Self.office.uuidString })
        #expect(lists.all.count == 2)
    }

    @Test func listsAreBoundedAndCarryNoAddresses() throws {
        let (fleet, _) = fleet(hosts: [.init(id: Self.home, name: "Home", isSelected: true),
                                       .init(id: Self.studio, name: String(repeating: "S", count: 80), isSelected: false)])
        fleet.recordLive(FleetSnapshot(agents: (0..<40).map { fleetAgent(Self.studio, "a\($0)", "Agent \($0)") },
                                       refreshedAt: .now), hostID: Self.studio)
        let lists = BighelpPinnedAgentsWidgetFeed.lists(
            livePins: (0..<30).map { .init(agentID: "l\($0)", name: String(repeating: "N", count: 90), picture: nil) },
            fleet: fleet)
        #expect(lists.current.count == BighelpWidgetSnapshot.maximumPinnedAgents)
        #expect(lists.all.count == BighelpWidgetSnapshot.maximumPinnedAgents)
        #expect(lists.current.allSatisfy { $0.name.count <= 40 })
        #expect(lists.all.allSatisfy { ($0.hostName?.count ?? 0) <= 40 })
        let json = String(decoding: try JSONEncoder.bighelpWidget.encode(lists.all), as: UTF8.self)
        #expect(!json.contains("http") && !json.contains("/tmp"), "No addresses or file paths")
    }

    /// Demo mode: the demo agents and the demo computers fill the widget, so
    /// screenshots and tests have something real-looking to show.
    @Test func demoAgentsAndComputersFillTheWidget() async throws {
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: DemoAgentDirectoryClient.fixtureProfiles),
                                         defaults: isolatedDefaults())
        try await agents.load()
        let fleet = FleetStore(reader: FleetFixtureReader(), directory: FileManager.default.temporaryDirectory
            .appending(path: "pinned-demo-\(UUID().uuidString)"))
        fleet.refresh()
        await fleet.waitForReads()
        let lists = BighelpPinnedAgentsWidgetFeed.lists(
            livePins: agents.pinnedAgents.map { .init(agentID: $0.id, name: $0.name, picture: nil) }, fleet: fleet)
        #expect(lists.current.map(\.name) == ["Avery Park"])
        #expect(lists.all.map { "\($0.name) · \($0.hostName ?? "")" } == ["Avery Park · Home Hermes", "Rio Tanaka · Studio Mac"])
    }

    @Test func computersCalledByTheirAddressGetAPlainName() {
        #expect(BighelpPinnedAgentsWidgetFeed.widgetHostName("Studio Mac", number: 2) == "Studio Mac")
        #expect(BighelpPinnedAgentsWidgetFeed.widgetHostName("Sam's Mac mini", number: 2) == "Sam's Mac mini")
        #expect(BighelpPinnedAgentsWidgetFeed.widgetHostName("Hermes", number: 2) == "Hermes")
        for address in ["192.168.1.20", "studio.tailnet.example.net", "fd00::1", "[fd00::1]", "https://10.0.0.2", " "] {
            #expect(BighelpPinnedAgentsWidgetFeed.widgetHostName(address, number: 3) == "Computer 3", "\(address)")
        }
    }

    @Test func publisherWritesBothListsForThisComputersAgentsOnly() async throws {
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        let extras = BighelpWidgetExtras()
        let finance = AgentProfile.financeFixture.id
        extras.pinnedAgents = [.init(agentID: finance, name: "Finley", hostID: Self.home.uuidString, hostName: "Home"),
                               // Left over from the computer used before: never shown.
                               .init(agentID: "elsewhere", name: "Gone", hostID: Self.studio.uuidString, hostName: "Studio")]
        extras.allPinnedAgents = [.init(agentID: finance, name: "Finley", hostID: Self.home.uuidString, hostName: "Home"),
                                  .init(agentID: "elsewhere", name: "Gone", hostID: Self.studio.uuidString, hostName: "Studio")]
        var writes: [BighelpWidgetSnapshot] = []
        let publisher = BighelpWidgetSnapshotPublisher(
            sessions: SessionCatalogStore(client: DemoSessionCatalogClient(), records: []),
            scheduledTasks: ScheduledTasksStore(client: ScheduledTasksFixtureClient(), initialAgentID: finance),
            agents: agents, extras: extras, interval: .milliseconds(1), write: { writes.append($0) })
        publisher.publishNow()
        let snapshot = try #require(writes.last)
        #expect(snapshot.pinnedAgents(.current).map(\.agentID) == [finance])
        #expect(snapshot.pinnedAgents(.multi).map(\.agentID) == [finance, "elsewhere"])

        // A pin change publishes again, which reloads the widget.
        extras.allPinnedAgents = Array(extras.allPinnedAgents.prefix(1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(writes.last?.pinnedAgents(.multi).map(\.agentID) == [finance])
        publisher.retire()
        #expect(writes.last == .empty)
    }

    // MARK: Pictures

    private func picture(_ color: UIColor, size: CGFloat = 600) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }.pngData()!
    }

    @Test func picturesAreWrittenSmallAndRemovedWhenUnpinned() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pinned-avatars-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appending(path: "sources")
        let store = root.appending(path: "store")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let red = sources.appending(path: "red.png"), blue = sources.appending(path: "blue.png")
        let notAPicture = sources.appending(path: "broken.png")
        try picture(.red).write(to: red)
        try picture(.blue, size: 2_000).write(to: blue)
        try Data("not a picture".utf8).write(to: notAPicture)
        let keyA = BighelpPinnedAvatarWriter.key(hostID: Self.home, agentID: "juno")
        let keyB = BighelpPinnedAvatarWriter.key(hostID: Self.studio, agentID: "juno")
        let keyC = BighelpPinnedAvatarWriter.key(hostID: Self.studio, agentID: "rex")
        #expect(keyA != keyB, "The same agent ID on another computer has its own picture")

        BighelpPinnedAvatarWriter.sync([keyA: red, keyB: blue, keyC: notAPicture], in: store)
        let fileA = try #require(BighelpPinnedAvatarStore.fileURL(key: keyA, in: store))
        let fileB = try #require(BighelpPinnedAvatarStore.fileURL(key: keyB, in: store))
        let imageB = try #require(BighelpPinnedAvatarStore.image(key: keyB, in: store))
        #expect(BighelpPinnedAvatarStore.image(key: keyA, in: store) != nil)
        #expect(imageB.size.width * imageB.scale == CGFloat(BighelpActivityAvatarStore.pixelSize))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: fileB.path)[.size] as? Int)
        #expect(size <= BighelpPinnedAvatarStore.maximumFileBytes)
        #expect(BighelpPinnedAvatarStore.image(key: keyC, in: store) == nil, "A broken picture shows the initial")

        // Unpinned (or its computer removed): its picture goes; strays go too.
        try Data("stray".utf8).write(to: store.appending(path: "stray.png"))
        BighelpPinnedAvatarWriter.sync([keyB: blue], in: store)
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.path) == [fileB.lastPathComponent])

        // Never more than the widget can show.
        var many: [String: URL] = [:]
        for index in 0..<40 { many[BighelpPinnedAvatarWriter.key(hostID: Self.home, agentID: "a\(index)")] = red }
        BighelpPinnedAvatarWriter.sync(many, in: store)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).count
                <= BighelpPinnedAvatarStore.maximumFiles)

        // Nothing pinned anywhere: nothing left behind.
        BighelpPinnedAvatarWriter.sync([:], in: store)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).isEmpty)
        // Keys can't reach outside the folder.
        #expect(BighelpPinnedAvatarStore.fileURL(key: "../escape", in: store) == nil)
    }

    // MARK: Renders

    /// Sample pictures drawn from the avatar kit, like the looks people save.
    private func samplePictures(_ keys: [String], in directory: URL) throws {
        let looks: [CompanionCharacter] = [.lobster, .robot, .owl, .fox, .cat, .dragon, .octopus, .dog]
        let backgrounds: [Color] = [.orange, .mint, .indigo, .pink, .teal, .yellow, .purple, .blue]
        let sources = directory.appending(path: "sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var pictures: [String: URL] = [:]
        for (index, key) in keys.enumerated() {
            let view = ZStack {
                backgrounds[index % backgrounds.count].opacity(0.35)
                CompanionAvatar(appearance: CompanionAppearance(character: looks[index % looks.count],
                                                                usesCharacterColors: true),
                                reaction: .idle, isAnimating: false, activityMood: nil)
                    .padding(18)
            }
            .frame(width: 200, height: 200)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let url = sources.appending(path: "\(index).png")
            try #require(renderer.uiImage?.pngData()).write(to: url)
            pictures[key] = url
        }
        BighelpPinnedAvatarWriter.sync(pictures, in: directory)
    }

    private static let people: [(String, String, UUID)] = [
        ("juno", "Juno", home), ("rex", "Rex Whitfield-Montgomery", home), ("mira", "Mira", studio),
        ("ada", "Ada", studio), ("kai", "Kai", home), ("juno", "Juno", studio), ("lena", "Lena", office),
        ("otto", "Otto", office), ("pia", "Pia", home), ("sol", "Sol", studio), ("ivy", "Ivy", office),
        ("max", "Max", home), ("zed", "Zed", studio),
    ]

    private static let hostNames = [home: "Home Hermes", studio: "Studio Mac", office: "Office Linux"]

    /// Every size, light and dark, both modes, a few and many agents and none,
    /// saved for review when BIGHELP_WIDGET_RENDER_DIR is set.
    @Test func pinnedAgentsWidgetRendersEverySizeInBothModes() throws {
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        let avatars = FileManager.default.temporaryDirectory.appending(path: "pinned-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: avatars) }
        let pins = Self.people.enumerated().map { index, person in
            BighelpWidgetSnapshot.PinnedAgent(
                agentID: person.0, name: person.1, hostID: person.2.uuidString, hostName: Self.hostNames[person.2],
                // A couple without a picture show their initial.
                avatarKey: index % 5 == 3 ? nil : BighelpPinnedAvatarWriter.key(hostID: person.2, agentID: person.0))
        }
        try samplePictures(pins.compactMap(\.avatarKey), in: avatars)

        let families: [(String, WidgetFamily, CGSize)] = [("small", .systemSmall, .init(width: 170, height: 170)),
                                                          ("medium", .systemMedium, .init(width: 364, height: 170)),
                                                          ("large", .systemLarge, .init(width: 364, height: 382))]
        let currentPins = pins.filter { $0.hostID == Self.home.uuidString }
        let cases: [(String, PinnedAgentsWidgetScope, [BighelpWidgetSnapshot.PinnedAgent])] = [
            ("current-few", .current, Array(currentPins.prefix(3))),
            ("current", .current, currentPins),
            ("multi", .multi, pins),
            ("multi-few", .multi, Array(pins.prefix(4))),
            ("empty", .current, []),
            ("empty-multi", .multi, []),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, family, size) in families {
                for (state, scope, list) in cases {
                    var snapshot = BighelpWidgetSnapshot.preview
                    snapshot.pinnedAgents = scope == .current ? list : []
                    snapshot.allPinnedAgents = scope == .multi ? list : []
                    let colors = BighelpWidgetColors(snapshot: snapshot, scheme: scheme, isFullColor: true)
                    let view = BighelpPinnedAgentsWidgetView(snapshot: snapshot, scope: scope, familyOverride: family)
                        .environment(\.bighelpPinnedAvatarDirectory, avatars)
                        .environment(\.bighelpWidgetColors, colors)
                        .foregroundStyle(colors.primary)
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .background(colors.canvas)
                        .clipShape(.rect(cornerRadius: 22))
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try #require(renderer.uiImage, "\(state) \(name) did not render")
                    #expect(image.size.width >= size.width && image.size.height >= size.height)
                    if let out, let data = image.pngData() {
                        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                        try data.write(to: out.appendingPathComponent(
                            "pinned-\(state)-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    @Test func eachSizeShowsAsManyAsFitNicely() {
        #expect(BighelpPinnedAgentsLayout(family: .systemSmall, count: 9).shown == 4)
        #expect(BighelpPinnedAgentsLayout(family: .systemSmall, count: 9).columns == 2)
        #expect(BighelpPinnedAgentsLayout(family: .systemMedium, count: 3).shown == 3)
        #expect(BighelpPinnedAgentsLayout(family: .systemMedium, count: 3).rows == 1)
        #expect(BighelpPinnedAgentsLayout(family: .systemMedium, count: 6).rows == 2)
        #expect(BighelpPinnedAgentsLayout(family: .systemMedium, count: 20).shown == 8)
        #expect(BighelpPinnedAgentsLayout(family: .systemLarge, count: 20).shown == 12)
        #expect(BighelpPinnedAgentsLayout(family: .systemLarge, count: 2).shown == 2)
        #expect(BighelpPinnedAgentsLayout(family: .systemLarge, count: 3).columns == 2)
        #expect(BighelpPinnedAgentsLayout(family: .systemLarge, count: 5).columns == 3)
        #expect(BighelpPinnedAgentsLayout(family: .systemLarge, count: 10).columns == 4)
        #expect(BighelpPinnedAgentsLayout(family: .systemLarge, count: 0).shown == 0)
    }
}
