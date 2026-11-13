#if DEBUG
import SwiftUI

/// Spaces on made-up data: the demo computer (`DemoSpacesClient`) with its three live spaces and
/// one draft, its bots, and the draft's chat card.
@MainActor
enum SpacesFixture {
    /// The demo computer as Today reads it.
    static var demoComputer: SpacesComputer {
        SpacesComputer(hostKey: "demo", scope: "spaces-fixture", name: "Demo computer",
                       api: SpacesAPI(client: DemoSpacesClient.shared),
                       bots: [SpacesBot(id: "finance", name: "Avery Park"), SpacesBot(id: "travel", name: "Mina Shah"),
                              SpacesBot(id: "home", name: "Jordan Lee")],
                       isCurrent: true)
    }

    /// The demo draft as `bighelp_draft_space` delivers it: one `space_draft` element, alone in its card.
    nonisolated static var spendingDraft: SpaceDraftCard {
        SpaceDraftCard(spaceID: DemoSpacesClient.spendingDraftID, title: "Spending",
                       description: "This month's spending against the budget.", updates: "Every 2 hours",
                       usesAI: false, revision: 1)
    }

    nonisolated static func document(_ draft: SpaceDraftCard) -> [String: BighelpJSONValue] {
        var document: [String: BighelpJSONValue] = [
            "schema": .string("loopdy.card"), "version": .integer(1), "title": .string(draft.title),
            "spoken_summary": .string("A space to add to Today: \(draft.title). \(draft.updates), without AI."),
            "data_sources": .array([]), "root": .string("space"),
            "elements": .object(["space": .object([
                "type": .string(SpacesWire.type),
                "props": .object(["space_id": .string(draft.spaceID), "description": .string(draft.description),
                                  "updates": .string(draft.updates), "uses_ai": .boolean(draft.usesAI),
                                  "revision": .integer(draft.revision)]),
                "children": .array([]),
            ])]),
        ]
        let hash = SpacesWire.sha256(draft.spaceID + "/\(draft.revision)")
        document["content_hash"] = .string(hash)
        document["card_id"] = .string(String(hash.prefix(32)))
        document["origin"] = .string("live")
        document["created_at"] = .string("2026-11-12T12:00:00Z")
        return document
    }

    /// The card fenced the way hosts deliver cards in a reply.
    nonisolated static func fenced(_ draft: SpaceDraftCard) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(BighelpJSONValue.object(document(draft)))) ?? Data()
        return "```\(ChatCardMessageProjection.fenceLanguage)\n" + String(decoding: json, as: UTF8.self) + "\n```"
    }
}

extension ConversationFixtures {
    /// `-test-spaces`: the person asks the finance bot for a space and gets its draft card.
    static var spacesPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let person = TimelineSender.user(snapshot: .init(name: "You"))
        let items = [
            TimelineItem(id: "spaces-q1", role: .human, sender: person,
                         content: .message("Make me a space for Today: my spending this month."),
                         metadata: .init(sourceOrder: 1)),
            TimelineItem(id: "spaces-draft", role: .assistant, sender: agent,
                         content: .message("Here it is. A script updates it every 2 hours, with no AI. "
                                           + "Add it when it looks right.\n\n"
                                           + SpacesFixture.fenced(SpacesFixture.spendingDraft)),
                         metadata: .init(sourceOrder: 10)),
        ]
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Spending space",
                             items: items, hasAcceptedMessage: true)
    }
}

/// `-test-spaces-today`: Today's grid with the demo computer's spaces through `SpacesTodayBridge`,
/// before the shell shows them. Every run starts from the demo's own sizes and order.
struct SpacesTodayFixture: View {
    static let launchArgument = "-test-spaces-today"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }
    /// Emptied once a run, so every run starts from the computer's sizes and order.
    private static let layoutDefaults: UserDefaults = {
        let suite = "bighelp.spaces.fixture"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    @State private var model = TodaySpacesModel(computers: { [SpacesFixture.demoComputer] },
                                                current: { SpacesFixture.demoComputer },
                                                pages: { _ in HTMLAppsAPI(client: DemoHTMLAppsClient.shared) },
                                                cacheFolder: nil)
    @State private var layout = TodayPanelLayoutStore(defaults: SpacesTodayFixture.layoutDefaults)
    @State private var isEditing = false
    @State private var deleting: TodayPanelDescriptor?
    @State private var openPage: TodaySpace?
    @Environment(\.scenePhase) private var scenePhase

    private var bridge: SpacesTodayBridge {
        SpacesTodayBridge(model: model) { openPage = $0 }
    }

    var body: some View {
        TodayView(context: context)
            // The shell does the same where it builds Today.
            .onAppear { layout.ownedChanges = bridge.ownedChanges }
            .spacesDeleteConfirmation($deleting, bridge: bridge, layout: layout)
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.watch()
            }
            .bighelpFullScreenCover(item: $openPage) { item in
                if let page = item.space.page {
                    // A space's page never sends a message.
                    HTMLAppScreen(app: page.card(title: item.space.title, description: item.space.description),
                                  agentID: item.space.agentID, connection: model.pageConnection(item),
                                  send: { _ in throw SpacesError.other(code: nil) })
                }
            }
    }

    private var context: TodayContext {
        let bridge = bridge
        var context = TodayContext(
            header: AnyView(header),
            needsYou: nil,
            onOpenNeedsYou: {},
            panels: bridge.descriptors(from: model.items),
            makePanel: { bridge.panel(for: $0) },
            layout: layout,
            isEditing: $isEditing,
            onDeletePanel: { deleting = $0 })
        context.aboveGrid = AnyView(SpacesTodayNotes(notes: bridge.notes))
        context.belowGrid = isEditing ? nil : AnyView(
            TodayCreateBox(bots: SpacesFixture.demoComputer.bots, primaryBotID: "finance") { _, _ in })
        context.panelMenu = { bridge.menuItems(for: $0) }
        return context
    }

    private var header: some View {
        HStack {
            Text("Today")
                .font(.bighelp(.title2, weight: .bold))
            Spacer()
            TodayEditButton(isEditing: $isEditing)
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
    }
}
#endif
