import Foundation

#if DEBUG
extension ConversationFixtures {
    private struct WeatherCard {
        let scene: String, intensity: String, time: String
        let place: String, condition: String, temperature: Int, detail: String
    }

    /// `-test-weather-cards`: one weather card per scene, a few more at other
    /// times and strengths, one with a scene this build doesn't know, and one
    /// with `none`, so there are ten moving cards to scroll past. With `plain`
    /// (`-test-weather-cards-plain`) every card is `none`, for comparison.
    /// Made-up places and numbers.
    static func weatherCardsPreview(plain: Bool = false) -> SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let cards = [
            WeatherCard(scene: "clear", intensity: "moderate", time: "day", place: "Sample Bay",
                        condition: "Clear and sunny", temperature: 71, detail: "UV 6"),
            WeatherCard(scene: "partly_cloudy", intensity: "moderate", time: "dusk", place: "Demo Ridge",
                        condition: "Clouds clearing", temperature: 63, detail: "Wind 6 mph"),
            WeatherCard(scene: "overcast", intensity: "heavy", time: "day", place: "Testville",
                        condition: "Overcast", temperature: 58, detail: "Humidity 81%"),
            WeatherCard(scene: "rain", intensity: "heavy", time: "night", place: "Port Example",
                        condition: "Heavy rain", temperature: 52, detail: "1.2 in tonight"),
            WeatherCard(scene: "thunderstorm", intensity: "heavy", time: "dusk", place: "Mockford",
                        condition: "Thunderstorms", temperature: 66, detail: "Gusts 38 mph"),
            WeatherCard(scene: "snow", intensity: "moderate", time: "day", place: "Placeholder Peak",
                        condition: "Snow showers", temperature: 29, detail: "4 in expected"),
            WeatherCard(scene: "fog", intensity: "moderate", time: "night", place: "Fixture Harbor",
                        condition: "Dense fog", temperature: 47, detail: "Visibility 0.2 mi"),
            WeatherCard(scene: "wind", intensity: "heavy", time: "day", place: "Gusty Flats",
                        condition: "Windy", temperature: 61, detail: "Gusts 44 mph"),
            WeatherCard(scene: "rain", intensity: "light", time: "day", place: "Drizzle Point",
                        condition: "Light rain", temperature: 55, detail: "Ends by 3 PM"),
            WeatherCard(scene: "clear", intensity: "light", time: "night", place: "Starry Hollow",
                        condition: "Clear night", temperature: 44, detail: "Moonrise 8:12 PM"),
            WeatherCard(scene: "hail", intensity: "moderate", time: "dusk", place: "Unknown Vale",
                        condition: "Hail", temperature: 49, detail: "A scene this build doesn't know"),
            WeatherCard(scene: "none", intensity: "moderate", time: "day", place: "Plain Town",
                        condition: "No background", temperature: 60, detail: "The usual card surface"),
        ]
        var items = [TimelineItem(id: "weather-q", role: .human, sender: .user(snapshot: .init(name: "You")),
                                  content: .message("Show me the weather cards."), metadata: .init(sourceOrder: 1))]
        for (index, card) in cards.enumerated() {
            items.append(TimelineItem(id: "weather-card-\(index)", role: .assistant, sender: agent,
                                      content: .message(fenced(card, index: index, plain: plain)),
                                      metadata: .init(sourceOrder: 10 + index * 10)))
        }
        items.append(TimelineItem(id: "weather-end", role: .assistant, sender: agent,
                                  content: .message("That's every scene."), metadata: .init(sourceOrder: 500)))
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Weather cards",
                             items: items, hasAcceptedMessage: true)
    }

    /// Hosts deliver cards as a fenced block in the reply's text.
    private static func fenced(_ card: WeatherCard, index: Int, plain: Bool) -> String {
        let document: [String: Any] = [
            "schema": "loopdy.card", "version": 1, "title": card.place,
            "spoken_summary": "\(card.condition) in \(card.place), \(card.temperature) degrees.",
            "data_sources": [], "root": "card",
            "elements": [
                "card": [
                    "type": "card", "props": ["title": card.place, "subtitle": card.condition],
                    "background": ["scene": plain ? "none" : card.scene, "intensity": card.intensity,
                                   "time_of_day": card.time],
                    "children": ["row", "note"],
                ],
                "row": ["type": "hstack", "props": ["spacing": "medium"], "children": ["now", "feels"]],
                "now": ["type": "metric", "children": [],
                        "props": ["label": "Now", "value": ["literal": card.temperature],
                                  "format": ["style": "integer"]]],
                "feels": ["type": "metric", "children": [],
                          "props": ["label": "Feels like", "value": ["literal": card.temperature - 3],
                                    "format": ["style": "integer"]]],
                "note": ["type": "text", "children": [],
                         "props": ["value": ["literal": card.detail], "typography": "caption", "color": "secondary"]],
            ],
            "content_hash": String(repeating: "e", count: 64), "card_id": String(format: "%032x", 0xC0FFEE00 + index),
            "created_at": "2026-09-30T18:00:00Z", "origin": "live",
        ]
        let json = try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return "```\(ChatCardMessageProjection.fenceLanguage)\n" + String(decoding: json, as: UTF8.self) + "\n```"
    }
}
#endif
