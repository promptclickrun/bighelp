// Pinned agents on the Home Screen, like a grid of contacts: each face opens a
// chat with that agent. Current Gateway shows the computer in use; Multi
// Gateway shows every computer's; One Gateway the one chosen. The app writes
// the list and the pictures.
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Pictures

/// Pinned agents' pictures in the shared app group, one small file per agent
/// and computer. The app writes them (`BighelpPinnedAvatarWriter`) and removes
/// those no longer pinned; the widget only reads.
enum BighelpPinnedAvatarStore {
    /// Twice the agents a list carries: the computer in use and all computers.
    static let maximumFiles = BighelpWidgetSnapshot.maximumPinnedAgents * 2
    static let maximumFileBytes = 262_144

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent("pinned-avatars", isDirectory: true)
    }

    static func fileURL(key: String, in directory: URL? = directory) -> URL? {
        guard let key = BighelpActivityText.coordinate(key, maximum: 64) else { return nil }
        return directory?.appendingPathComponent("\(key).png", isDirectory: false)
    }

    static func image(key: String, in directory: URL? = directory) -> UIImage? {
        guard let url = fileURL(key: key, in: directory),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? .max) <= maximumFileBytes else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

private struct BighelpPinnedAvatarDirectoryKey: EnvironmentKey {
    static let defaultValue: URL? = BighelpPinnedAvatarStore.directory
}

extension EnvironmentValues {
    /// Where pinned agents' pictures are read from; tests point it elsewhere.
    var bighelpPinnedAvatarDirectory: URL? {
        get { self[BighelpPinnedAvatarDirectoryKey.self] }
        set { self[BighelpPinnedAvatarDirectoryKey.self] = newValue }
    }
}

// MARK: - Configuration

/// Which pinned agents the widget shows. The names are the person's own words.
enum PinnedAgentsWidgetScope: String, AppEnum {
    case current, multi, one

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Agents") }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .current: DisplayRepresentation(title: "Current Gateway", subtitle: "Pinned agents on the computer you're using"),
            .multi: DisplayRepresentation(title: "Multi Gateway", subtitle: "Pinned agents on all your computers"),
            .one: DisplayRepresentation(title: "One Gateway", subtitle: "Pinned agents on the gateway you choose"),
        ]
    }
}

struct PinnedAgentsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pinned agents"
    static let description = IntentDescription("Show the pinned agents of the computer you're using, or of all your computers.")

    @Parameter(title: "Show", default: .current)
    var scope: PinnedAgentsWidgetScope

    @Parameter(title: "Gateway")
    var gateway: BighelpWidgetGateway?

    static var parameterSummary: some ParameterSummary {
        When(\.$scope, .equalTo, .one) {
            Summary {
                \.$scope
                \.$gateway
            }
        } otherwise: {
            Summary {
                \.$scope
            }
        }
    }
}

extension BighelpWidgetSnapshot {
    func pinnedAgents(_ scope: PinnedAgentsWidgetScope) -> [PinnedAgent] {
        switch scope {
        case .current, .one: pinnedAgents ?? []
        case .multi: allPinnedAgents ?? []
        }
    }

    /// One gateway's pins, as `pinnedAgents`: from All agents' copy, else what that
    /// gateway's widgets last showed. The gateway in use (nil too) shows its live pins.
    static func pinned(onGateway hostID: String?) -> BighelpWidgetSnapshot {
        var snapshot = load()
        guard let hostID, hostID != snapshot.hostID else { return snapshot }
        let fromAll = (snapshot.allPinnedAgents ?? []).filter { $0.hostID == hostID }
        snapshot.pinnedAgents = fromAll.isEmpty
            ? (load(gateway: hostID).pinnedAgents ?? []).map { pin in
                var pin = pin
                pin.hostID = hostID
                return pin
            }
            : fromAll
        return snapshot
    }

    static let agentsURL = URL(string: "loopdy://agents")!

    /// One Gateway's large title names the gateway.
    var pinnedTitle: String {
        guard let name = pinnedAgents?.first?.hostName else { return "Pinned agents" }
        return "Pinned agents · \(name)"
    }

    static var previewPinned: BighelpWidgetSnapshot {
        var snapshot = preview
        let home = "00000000-0000-4000-8000-0000000000A1", studio = "00000000-0000-4000-8000-0000000000A2"
        snapshot.pinnedAgents = [
            .init(agentID: "default", name: "Juno", hostID: home, hostName: "Home"),
            .init(agentID: "finance", name: "Avery", hostID: home, hostName: "Home"),
            .init(agentID: "travel", name: "Mina", hostID: home, hostName: "Home"),
        ]
        snapshot.allPinnedAgents = snapshot.pinnedAgents! + [
            .init(agentID: "research", name: "Rio", hostID: studio, hostName: "Studio"),
        ]
        return snapshot
    }
}

extension BighelpWidgetSnapshot.PinnedAgent {
    /// Current Gateway opens the agent on the computer in use; Multi and One
    /// Gateway name its computer, so bighelp switches there first.
    func link(_ scope: PinnedAgentsWidgetScope) -> URL {
        BighelpWidgetSnapshot.agentChatURL(agentID: agentID, hostID: scope == .current ? nil : hostID)
    }
}

// MARK: - Timeline

struct PinnedAgentsWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpWidgetSnapshot
    let scope: PinnedAgentsWidgetScope
}

struct PinnedAgentsWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PinnedAgentsWidgetEntry {
        PinnedAgentsWidgetEntry(date: .now, snapshot: .previewPinned, scope: .current)
    }

    func snapshot(for configuration: PinnedAgentsWidgetIntent, in context: Context) async -> PinnedAgentsWidgetEntry {
        let snapshot = load(configuration)
        let shown = context.isPreview && snapshot.pinnedAgents(configuration.scope).isEmpty ? .previewPinned : snapshot
        return PinnedAgentsWidgetEntry(date: .now, snapshot: shown, scope: configuration.scope)
    }

    func timeline(for configuration: PinnedAgentsWidgetIntent, in context: Context) async -> Timeline<PinnedAgentsWidgetEntry> {
        // The app reloads this whenever pins change; this is only a safety net.
        Timeline(entries: [PinnedAgentsWidgetEntry(date: .now, snapshot: load(configuration), scope: configuration.scope)],
                 policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func load(_ configuration: PinnedAgentsWidgetIntent) -> BighelpWidgetSnapshot {
        configuration.scope == .one ? .pinned(onGateway: configuration.gateway?.hostID) : .load()
    }
}

// MARK: - Layout

/// How many faces each size shows, in how many columns and rows, and how big.
struct BighelpPinnedAgentsLayout: Equatable {
    let shown: Int
    let columns: Int
    let rows: Int
    let diameter: CGFloat

    init(family: WidgetFamily, count: Int) {
        let limit: Int, columns: Int
        switch family {
        case .systemMedium: (limit, columns) = (8, 4)
        // Big faces while there are few, like a contact grid filling up.
        case .systemLarge: (limit, columns) = (12, count <= 4 ? 2 : count <= 9 ? 3 : 4)
        default: (limit, columns) = (4, 2)
        }
        shown = min(max(count, 0), limit)
        self.columns = max(1, min(columns, shown))
        rows = shown == 0 ? 0 : (shown + self.columns - 1) / self.columns
        diameter = switch family {
        case .systemMedium: rows <= 1 ? 58 : 40
        case .systemLarge: columns == 2 ? 84 : columns == 3 ? 64 : 58
        default: rows <= 1 ? 58 : 42
        }
    }
}

// MARK: - Views

struct BighelpPinnedAgentsWidgetView: View {
    let snapshot: BighelpWidgetSnapshot
    let scope: PinnedAgentsWidgetScope
    /// Set by render tests; WidgetKit supplies the family otherwise.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.bighelpWidgetColors) private var colors

    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private var agents: [BighelpWidgetSnapshot.PinnedAgent] { snapshot.pinnedAgents(scope) }
    private var layout: BighelpPinnedAgentsLayout { .init(family: family, count: agents.count) }

    /// Which computer each agent is on, only when they're on more than one.
    private var showsHosts: Bool {
        scope == .multi && Set(agents.prefix(layout.shown).map { $0.hostID ?? "" }).count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if family == .systemLarge {
                BighelpWidgetSectionTitle(title: scope == .multi ? "Pinned agents · All computers"
                                          : scope == .one ? snapshot.pinnedTitle : "Pinned agents",
                                          symbol: "pin.fill")
            }
            if agents.isEmpty {
                empty
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(layout.shown == 1 ? agents[0].link(scope)
                   : BighelpWidgetSnapshot.link(BighelpWidgetSnapshot.agentsURL,
                                                onGateway: scope == .one ? agents.first?.hostID : nil))
    }

    private var grid: some View {
        let layout = layout
        let shown = Array(agents.prefix(layout.shown))
        return VStack(spacing: family == .systemLarge ? 14 : 8) {
            ForEach(0..<layout.rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(0..<layout.columns, id: \.self) { column in
                        let index = row * layout.columns + column
                        if index < shown.count {
                            Link(destination: shown[index].link(scope)) { tile(shown[index], diameter: layout.diameter) }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
        }
        .padding(.top, family == .systemLarge ? 6 : 0)
        // Large fills from the top, like the Home Screen; the others sit centered.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .systemLarge ? .top : .center)
    }

    private func tile(_ agent: BighelpWidgetSnapshot.PinnedAgent, diameter: CGFloat) -> some View {
        let small = diameter < 50, big = diameter >= 80
        return VStack(spacing: small ? 3 : 5) {
            BighelpWidgetAvatar(agentID: nil, name: agent.name, diameter: diameter, avatarKey: agent.avatarKey)
            VStack(spacing: 0) {
                Text(agent.name)
                    .font(.system(size: big ? 14 : small ? 11 : 12, weight: .semibold))
                    .foregroundStyle(colors.primary)
                if showsHosts, let host = agent.hostName {
                    Text(host)
                        .font(.system(size: big ? 11 : small ? 9 : 10))
                        .foregroundStyle(colors.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsHosts && agent.hostName != nil ? "\(agent.name), on \(agent.hostName!)" : agent.name)
        .accessibilityAddTraits(.isButton)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "pin")
                .font(.title3)
                .foregroundStyle(colors.accent.opacity(0.75))
                .widgetAccentable()
            Text("No pinned agents yet. Pin agents in bighelp to see them here.")
                .font(.caption)
                .foregroundStyle(colors.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget

struct BighelpPinnedAgentsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: BighelpWidgetSnapshot.pinnedAgentsWidgetKind, intent: PinnedAgentsWidgetIntent.self,
                               provider: PinnedAgentsWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.snapshot) {
                BighelpPinnedAgentsWidgetView(snapshot: entry.snapshot, scope: entry.scope)
            }
        }
        .configurationDisplayName("Pinned Agents")
        .description("Your pinned agents. Tap one to chat.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .bighelpWidgetPlacement()
    }
}
