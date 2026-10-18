// Bots on the Home Screen: one, two or four chosen bots, each face opening its
// Bot Chat. The person picks the gateway and the bots; the app writes every
// gateway's bots and faces into the app group, so the widget keeps them with
// the app closed and taps open the right computer.
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Bots and faces

/// Every gateway's bots, as the Bots widget offers them. The app writes it from
/// the computer in use and All agents' copies of the others.
struct BighelpBotsWidgetRoster: Codable, Equatable, Sendable {
    struct Bot: Codable, Equatable, Sendable, Identifiable {
        let agentID: String
        let name: String
        /// Its face in `BighelpBotsWidgetFaces`; nil draws its first letter.
        var faceKey: String?
        /// A Simple Bot shape (clear around it) stands free; a photo sits in a circle.
        var isShape = false

        var id: String { agentID }
    }

    /// Each gateway's bots, by its ID in bighelp: the primary one first, then pinned, then by name.
    var gateways: [String: [Bot]] = [:]
    /// The gateway in use when the app last wrote this.
    var inUseHostID: String?

    static let fileName = "bighelp-widget-bots-v1.json"
    static let maximumGateways = 16
    static let maximumBotsPerGateway = 48
    static let maximumFileBytes = 524_288

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(from url: URL? = fileURL) -> Self {
        guard let url, let data = try? Data(contentsOf: url), data.count <= maximumFileBytes,
              let roster = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return roster
    }

    func save(to url: URL? = Self.fileURL) throws {
        guard let url else { return }
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The bots of `hostID`, or of the gateway in use (nil).
    func bots(onGateway hostID: String?) -> [Bot] {
        (hostID ?? inUseHostID).flatMap { gateways[$0] } ?? []
    }

    /// The chosen bots in their chosen order; without a choice, the gateway's first ones.
    func shown(onGateway hostID: String?, picked: [String]) -> [Bot] {
        let bots = bots(onGateway: hostID)
        let chosen = picked.compactMap { id in bots.first { $0.agentID == id } }
        return chosen.isEmpty ? bots : chosen
    }

    static var preview: Self {
        Self(gateways: ["preview": [.init(agentID: "default", name: "Juno"), .init(agentID: "finance", name: "Avery"),
                                    .init(agentID: "travel", name: "Mina"), .init(agentID: "home", name: "Jordan")]],
             inUseHostID: "preview")
    }
}

/// The bots' faces in the shared app group, one small file per bot and gateway.
enum BighelpBotsWidgetFaces {
    static let maximumFiles = 160

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent("bot-faces", isDirectory: true)
    }
}

// MARK: - Configuration

/// A bot on the widget's gateway.
struct BotsWidgetBot: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bot")
    static let defaultQuery = BotsWidgetBotQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct BotsWidgetBotQuery: EntityQuery {
    @IntentParameterDependency<BotsWidgetIntent>(\.$gateway) private var intent

    /// A chosen bot is found on any gateway, so a widget keeps it whichever gateway is in use.
    func entities(for identifiers: [String]) async throws -> [BotsWidgetBot] {
        let roster = BighelpBotsWidgetRoster.load()
        let preferred = roster.bots(onGateway: intent?.gateway.hostID)
        let everywhere = preferred + roster.gateways.values.flatMap { $0 }
        return identifiers.map { id in BotsWidgetBot(id: id, name: everywhere.first { $0.agentID == id }?.name ?? id) }
    }

    func suggestedEntities() async throws -> [BotsWidgetBot] {
        BighelpBotsWidgetRoster.load().bots(onGateway: intent?.gateway.hostID)
            .map { BotsWidgetBot(id: $0.agentID, name: $0.name) }
    }
}

struct BotsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Bots"
    static let description = IntentDescription("Choose a gateway and the bots to show. Tap a bot to open its chat.")

    @Parameter(title: "Gateway")
    var gateway: BighelpWidgetGateway?

    @Parameter(title: "Bots", size: [.systemSmall: 1, .systemMedium: 2, .systemLarge: 4])
    var bots: [BotsWidgetBot]?
}

// MARK: - Timeline

struct BotsWidgetEntry: TimelineEntry {
    let date: Date
    let bots: [BighelpBotsWidgetRoster.Bot]
    /// The chosen gateway; nil follows the one in use.
    let hostID: String?
    let snapshot: BighelpWidgetSnapshot
}

struct BotsWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BotsWidgetEntry {
        BotsWidgetEntry(date: .now, bots: BighelpBotsWidgetRoster.preview.bots(onGateway: nil), hostID: nil,
                        snapshot: .preview)
    }

    func snapshot(for configuration: BotsWidgetIntent, in context: Context) async -> BotsWidgetEntry {
        let entry = load(configuration)
        guard context.isPreview, entry.bots.isEmpty else { return entry }
        return placeholder(in: context)
    }

    func timeline(for configuration: BotsWidgetIntent, in context: Context) async -> Timeline<BotsWidgetEntry> {
        // The app reloads this whenever bots or faces change; this is only a safety net.
        Timeline(entries: [load(configuration)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func load(_ configuration: BotsWidgetIntent) -> BotsWidgetEntry {
        let hostID = configuration.gateway?.hostID
        let bots = BighelpBotsWidgetRoster.load().shown(onGateway: hostID, picked: (configuration.bots ?? []).map(\.id))
        return BotsWidgetEntry(date: .now, bots: bots, hostID: hostID, snapshot: .load(gateway: hostID))
    }
}

// MARK: - Views

struct BighelpBotsWidgetView: View {
    let bots: [BighelpBotsWidgetRoster.Bot]
    /// The chosen gateway; nil opens chats on the one in use.
    let hostID: String?
    /// Set by render tests; WidgetKit supplies the family otherwise.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.bighelpWidgetColors) private var colors

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    /// How many bots each size shows.
    static func capacity(_ family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: 2
        case .systemLarge: 4
        default: 1
        }
    }

    var body: some View {
        let shown = Array(bots.prefix(Self.capacity(family)))
        Group {
            if shown.isEmpty {
                Text("Add bots in bighelp, then choose them here.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if family == .systemLarge {
                let rows = stride(from: 0, to: shown.count, by: 2).map { Array(shown[$0..<min($0 + 2, shown.count)]) }
                VStack(spacing: 18) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 12) { ForEach(row) { tile($0, face: 104) } }
                    }
                }
            } else {
                HStack(spacing: 12) { ForEach(shown) { tile($0, face: family == .systemMedium ? 92 : 86) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(shown.count == 1 ? link(shown[0]) : nil)
    }

    func link(_ bot: BighelpBotsWidgetRoster.Bot) -> URL {
        BighelpWidgetSnapshot.agentChatURL(agentID: bot.agentID, hostID: hostID)
    }

    private func tile(_ bot: BighelpBotsWidgetRoster.Bot, face size: CGFloat) -> some View {
        Link(destination: link(bot)) {
            VStack(spacing: 8) {
                BighelpBotsWidgetFace(bot: bot, size: size)
                Text(bot.name)
                    .font(.system(size: size >= 100 ? 17 : 15, weight: .semibold))
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(bot.name)
        .accessibilityHint("Opens its chat")
    }
}

/// A bot's face: its shape standing free, its photo in a circle, or its first letter.
struct BighelpBotsWidgetFace: View {
    let bot: BighelpBotsWidgetRoster.Bot
    let size: CGFloat
    @Environment(\.bighelpWidgetColors) private var colors
    @Environment(\.bighelpBotsWidgetFaces) private var faces

    var body: some View {
        Group {
            if let image = bot.faceKey.flatMap({ BighelpPinnedAvatarStore.image(key: $0, in: faces) }) {
                if bot.isShape {
                    Image(uiImage: image).resizable().bighelpWidgetFullColor().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().bighelpWidgetFullColor().scaledToFill().clipShape(Circle())
                }
            } else {
                Text(String(bot.name.first ?? "b").uppercased())
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.accentForeground)
                    .frame(width: size, height: size)
                    .background(Circle().fill(colors.accent.gradient))
                    .widgetAccentable()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct BighelpBotsWidgetFacesKey: EnvironmentKey {
    static let defaultValue: URL? = BighelpBotsWidgetFaces.directory
}

extension EnvironmentValues {
    /// Where the Bots widget reads faces from; tests point it elsewhere.
    var bighelpBotsWidgetFaces: URL? {
        get { self[BighelpBotsWidgetFacesKey.self] }
        set { self[BighelpBotsWidgetFacesKey.self] = newValue }
    }
}

/// The app's page color and ink, plain: the faces carry the color.
struct BighelpBotsWidgetBackground<Content: View>: View {
    let snapshot: BighelpWidgetSnapshot
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        #if os(visionOS)
        let colors = BighelpWidgetColors.glass(snapshot: snapshot)
        #else
        let colors = BighelpWidgetColors(snapshot: snapshot, scheme: scheme, isFullColor: mode == .fullColor)
        #endif
        content
            .environment(\.bighelpWidgetColors, colors)
            .foregroundStyle(colors.primary)
            .containerBackground(for: .widget) {
                #if os(visionOS)
                Color.clear
                #else
                colors.isFullColor ? colors.canvas : Color.clear
                #endif
            }
    }
}

// MARK: - Widget

struct BighelpBotsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: BighelpWidgetSnapshot.botsWidgetKind, intent: BotsWidgetIntent.self,
                               provider: BotsWidgetProvider()) { entry in
            BighelpBotsWidgetBackground(snapshot: entry.snapshot) {
                BighelpBotsWidgetView(bots: entry.bots, hostID: entry.hostID)
            }
        }
        .configurationDisplayName("Bots")
        .description("The bots you choose. Tap one to open its chat.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .bighelpWidgetPlacement()
    }
}
