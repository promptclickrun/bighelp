import Foundation
import Observation
import SwiftUI
import WidgetKit

/// Keeps the Pinned Agents widget current: the computer in use's pins (live
/// from its agent list) and every computer's (from All agents' copies), each
/// with its picture copied into the shared app group. The widget snapshot
/// publisher writes the lists; pictures of agents no longer pinned go.
@MainActor
final class BighelpPinnedAgentsWidgetFeed {
    static let shared = BighelpPinnedAgentsWidgetFeed()

    /// A pinned agent on the computer in use.
    struct Pin: Equatable, Sendable {
        let agentID: String
        let name: String
        let picture: URL?
    }

    struct Lists: Equatable {
        var current: [BighelpWidgetSnapshot.PinnedAgent] = []
        var all: [BighelpWidgetSnapshot.PinnedAgent] = []
        /// Picture key → the agent's picture on this device.
        var pictures: [String: URL] = [:]
    }

    private let extras: BighelpWidgetExtras
    private weak var agents: AgentDirectoryStore?
    private weak var fleet: FleetStore?
    private var pending: Task<Void, Never>?
    private var writtenPictures: [String: URL]?
    private var writing: Task<Void, Never>?
    #if DEBUG
    private var demoPublisher: BighelpWidgetSnapshotPublisher?
    #endif

    init(extras: BighelpWidgetExtras = .shared) {
        self.extras = extras
    }

    /// Follows these agents and computers from now on.
    func attach(agents: AgentDirectoryStore, fleet: FleetStore?) {
        guard agents !== self.agents || fleet !== self.fleet else { return }
        self.agents = agents
        self.fleet = fleet
        observe()
        update()
    }

    private func observe() {
        withObservationTracking { _ = makeLists() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.changed() }
        }
    }

    /// Pins change rarely, but All agents' copies change while replies stream.
    private func changed() {
        observe()
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            pending = nil
            update()
        }
    }

    private func makeLists() -> Lists {
        guard let agents else { return Lists() }
        let pins = agents.pinnedAgents.map { Pin(agentID: $0.id, name: $0.name, picture: agents.avatarURL(for: $0)) }
        return Self.lists(livePins: pins, fleet: fleet)
    }

    private func update() {
        let lists = makeLists()
        if extras.pinnedAgents != lists.current { extras.pinnedAgents = lists.current }
        if extras.allPinnedAgents != lists.all { extras.allPinnedAgents = lists.all }
        guard lists.pictures != writtenPictures else { return }
        writtenPictures = lists.pictures
        let pictures = lists.pictures, previous = writing
        writing = Task.detached(priority: .utility) {
            await previous?.value
            BighelpPinnedAvatarWriter.sync(pictures)
            // The list may have reached the widget before its pictures did.
            WidgetCenter.shared.reloadTimelines(ofKind: BighelpWidgetSnapshot.pinnedAgentsWidgetKind)
        }
    }

    // MARK: Lists

    static func lists(livePins: [Pin], fleet: FleetStore?) -> Lists {
        struct Candidate {
            let fleetID: String
            let agent: BighelpWidgetSnapshot.PinnedAgent
            let picture: URL?
        }
        let limit = BighelpWidgetSnapshot.maximumPinnedAgents
        let hosts = fleet?.hosts ?? []
        let currentHost = hosts.first(where: \.isSelected)
        func candidate(hostID: UUID?, agentID: String, name: String, picture: URL?) -> Candidate {
            Candidate(
                fleetID: hostID.map { FleetID.make($0, agentID) } ?? agentID,
                agent: .init(agentID: agentID, name: clip(name) ?? "Agent", hostID: hostID?.uuidString,
                             hostName: hostID.flatMap { id in hosts.firstIndex { $0.id == id } }
                                .map { widgetHostName(hosts[$0].name, number: $0 + 1) },
                             avatarKey: picture.map { _ in BighelpPinnedAvatarWriter.key(hostID: hostID, agentID: agentID) }),
                picture: picture)
        }

        let live = livePins.prefix(limit).map {
            candidate(hostID: currentHost?.id, agentID: $0.agentID, name: $0.name, picture: $0.picture)
        }
        var everywhere = live
        if let fleet {
            // The computer in use is live; All agents' copy of it may be old.
            let others = fleet.pinnedAgents(limit: .max).filter { $0.hostID != currentHost?.id }.map {
                candidate(hostID: $0.hostID, agentID: $0.profileID, name: $0.name,
                          picture: fleet.avatars.url(for: $0.avatarFile))
            }
            // The order the person dragged them into across computers, as All agents shows them.
            let rank = Dictionary(fleet.pinnedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            everywhere = (live + others).enumerated().sorted { lhs, rhs in
                switch (rank[lhs.element.fleetID], rank[rhs.element.fleetID]) {
                case let (left?, right?): left < right
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): lhs.offset < rhs.offset
                }
            }.map(\.element)
        }
        let all = Array(everywhere.prefix(limit))
        var pictures: [String: URL] = [:]
        for item in live + all {
            if let key = item.agent.avatarKey, let picture = item.picture { pictures[key] = picture }
        }
        return Lists(current: live.map(\.agent), all: all.map(\.agent), pictures: pictures)
    }

    /// A computer the person never named is called by its address; the
    /// widget's file says "Computer 2" instead.
    static func widgetHostName(_ name: String, number: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressLike = trimmed.isEmpty || trimmed.contains("://") || (!trimmed.contains(" ")
            && (trimmed.contains(".") || trimmed.filter { $0 == ":" }.count >= 2)
            && trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]%".contains($0)) })
        return addressLike ? "Computer \(number)" : clip(trimmed) ?? "Computer \(number)"
    }

    private static func clip(_ value: String) -> String? {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= 40 ? collapsed : String(collapsed.prefix(39)) + "…"
    }

    // MARK: Other computers

    /// A Multi Gateway widget needs the other computers' pins: read them when
    /// the app opens, at most once a minute (as All agents does). The demo's
    /// sample computers are always read.
    func refreshOtherComputers() async {
        guard let fleet, fleet.hosts.count > 1 else { return }
        #if DEBUG
        let isDemo = fleet.reader is FleetFixtureReader
        #else
        let isDemo = false
        #endif
        if !isDemo {
            guard await Self.showsMultiGateway() else { return }
        }
        fleet.refresh()
    }

    /// Whether a Pinned Agents widget on this device is set to Multi Gateway.
    static func showsMultiGateway() async -> Bool {
        // The async form needs iOS 18; this one reaches back to iOS 17.
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { @Sendable result in
                let widgets = (try? result.get()) ?? []
                continuation.resume(returning: widgets.contains {
                    $0.kind == BighelpWidgetSnapshot.pinnedAgentsWidgetKind
                        && $0.widgetConfigurationIntent(of: PinnedAgentsWidgetIntent.self)?.scope == .multi
                })
            }
        }
    }

    #if DEBUG
    /// Demo runs have no host connection to publish the widgets' snapshot, so
    /// the demo's own stores do, for screenshots and tests.
    func publishDemo(sessions: SessionCatalogStore, scheduledTasks: ScheduledTasksStore?, agents: AgentDirectoryStore) {
        guard demoPublisher == nil else { return }
        let publisher = BighelpWidgetSnapshotPublisher(sessions: sessions, scheduledTasks: scheduledTasks,
                                                       agents: agents, extras: extras)
        demoPublisher = publisher
        publisher.publishNow()
    }
    #endif
}

/// Starts the Pinned Agents widget's feed and reads other computers for it
/// when the app comes to the front. Its own modifier keeps the shell's body
/// small enough to type-check.
struct PinnedAgentsWidgetHooks: ViewModifier {
    let agents: AgentDirectoryStore
    let fleet: FleetStore?
    let isActive: Bool
    /// The demo's stores, when the demo runs without a host.
    let demo: (sessions: SessionCatalogStore, scheduledTasks: ScheduledTasksStore?)?

    func body(content: Content) -> some View {
        content
            .task {
                BighelpPinnedAgentsWidgetFeed.shared.attach(agents: agents, fleet: fleet)
                #if DEBUG
                if let demo {
                    BighelpPinnedAgentsWidgetFeed.shared.publishDemo(sessions: demo.sessions,
                                                                     scheduledTasks: demo.scheduledTasks, agents: agents)
                }
                #endif
            }
            .task(id: isActive) {
                guard isActive else { return }
                await BighelpPinnedAgentsWidgetFeed.shared.refreshOtherComputers()
            }
    }
}
