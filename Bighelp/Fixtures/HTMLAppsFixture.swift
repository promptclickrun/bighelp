import Foundation

#if DEBUG
/// `-test-html-apps`: the person asks for two apps and the agent answers with a card for each, as
/// `bighelp_show_app` makes them. The demo computer (`DemoHTMLAppsClient`) serves their pages.
enum HTMLAppsFixture {
    static var tripBudget: HTMLAppCard {
        HTMLAppCard(appID: DemoHTMLAppsClient.tripBudgetID, title: "Trip budget",
                    description: "Split $2,400 across travel, food and fun, then send your pick.",
                    sendsAnswers: true, isLive: false)
    }

    static var gardenWatch: HTMLAppCard {
        HTMLAppCard(appID: DemoHTMLAppsClient.gardenWatchID, title: "Garden watch",
                    description: "Soil, temperature and the last watering, from the sensors.",
                    sendsAnswers: false, isLive: true)
    }

    /// A card holding one app, fenced the way hosts deliver cards in a reply.
    static func fenced(_ app: HTMLAppCard) -> String {
        var document: [String: BighelpJSONValue] = [
            "schema": .string("loopdy.card"), "version": .integer(1), "title": .string(app.title),
            "spoken_summary": .string("An app to open in bighelp: \(app.title)."), "data_sources": .array([]),
            "root": .string("app"),
            "elements": .object(["app": .object([
                "type": .string(HTMLAppWire.type),
                "props": .object(["app_id": .string(app.appID), "description": .string(app.description),
                                  "sends_answers": .boolean(app.sendsAnswers), "live": .boolean(app.isLive)]),
                "children": .array([]),
            ])]),
        ]
        let hash = HTMLAppHash.sha256(Data(app.appID.utf8))
        document["content_hash"] = .string(hash)
        document["card_id"] = .string(String(hash.prefix(32)))
        document["origin"] = .string("live")
        document["created_at"] = .string("2026-11-07T12:00:00Z")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(BighelpJSONValue.object(document))) ?? Data()
        return "```\(ChatCardMessageProjection.fenceLanguage)\n" + String(decoding: json, as: UTF8.self) + "\n```"
    }
}

extension ConversationFixtures {
    static var htmlAppsPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let person = TimelineSender.user(snapshot: .init(name: "You"))
        let items = [
            TimelineItem(id: "html-apps-q1", role: .human, sender: person,
                         content: .message("Can you make a little app to split our weekend trip budget?"),
                         metadata: .init(sourceOrder: 1)),
            TimelineItem(id: "html-apps-trip", role: .assistant, sender: agent,
                         content: .message("Here it is. Move the sliders, then send me what you pick.\n\n"
                                           + HTMLAppsFixture.fenced(HTMLAppsFixture.tripBudget)),
                         metadata: .init(sourceOrder: 10)),
            TimelineItem(id: "html-apps-q2", role: .human, sender: person,
                         content: .message("And one to watch the garden sensors?"),
                         metadata: .init(sourceOrder: 20)),
            TimelineItem(id: "html-apps-garden", role: .assistant, sender: agent,
                         content: .message("Done. It updates on its own while it's open.\n\n"
                                           + HTMLAppsFixture.fenced(HTMLAppsFixture.gardenWatch)),
                         metadata: .init(sourceOrder: 30)),
        ]
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Apps",
                             items: items, hasAcceptedMessage: true)
    }
}
#endif
