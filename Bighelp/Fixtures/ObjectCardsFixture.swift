import Foundation

#if DEBUG
extension ConversationFixtures {
    /// `-test-object-cards`: a reply with a person, a place and a song in one
    /// card (`BighelpCardDemoFixtures.objects`). Made-up people and places.
    static var objectCardsPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(BighelpCardDemoFixtures.objects)) ?? Data()
        // Hosts deliver cards as a fenced block in the reply's text.
        let fenced = "```\(ChatCardMessageProjection.fenceLanguage)\n" + String(decoding: json, as: UTF8.self) + "\n```"
        let items = [
            TimelineItem(id: "objects-q", role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message("What's the plan for Saturday?"), metadata: .init(sourceOrder: 1)),
            TimelineItem(id: "objects-card", role: .assistant, sender: agent,
                         content: .message("Here's Saturday:\n\n" + fenced), metadata: .init(sourceOrder: 10)),
        ]
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Saturday plans",
                             items: items, hasAcceptedMessage: true)
    }
}
#endif
