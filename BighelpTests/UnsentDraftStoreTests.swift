import Foundation
import Testing
@testable import Bighelp

/// Unsent text in new chats outlives leaving the app, and is offered back only when its chat
/// didn't survive.
@MainActor
struct UnsentDraftStoreTests {
    private let host = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("unsent-\(UUID().uuidString).json")
    }

    private func draft(_ id: String, _ text: String, host: UUID? = nil, at date: Date? = nil) -> UnsentDraft {
        UnsentDraft(id: id, hostID: host ?? self.host, agentID: "alfie", agentName: "Alfie", text: text,
                    savedAt: date ?? now)
    }

    @Test func aDraftIsOfferedOnlyWhenItsChatIsLost() {
        let store = UnsentDraftStore(fileURL: nil, now: { now })
        store.record([draft("chat-a", "Trip budget"), draft("chat-b", "   ")], hostID: host)
        #expect(store.drafts.map(\.id) == ["chat-a"], "Blank text isn't kept")
        #expect(store.lostDrafts(hostID: host).isEmpty, "Nothing to offer while the chat is fine")
        store.markLost(chatID: "chat-a", latestText: "Trip budget for Lisbon")
        #expect(store.lostDrafts(hostID: host).map(\.text) == ["Trip budget for Lisbon"], "Its latest text")
        store.markLost(chatID: "not-kept")
        #expect(store.lostDrafts(hostID: host).count == 1, "A chat that wasn't kept isn't offered")
        #expect(store.lostDrafts(hostID: other).isEmpty, "Only this computer's drafts")
    }

    @Test func comingBackOffersDraftsWhoseChatIsMissing() {
        let store = UnsentDraftStore(fileURL: nil, now: { now })
        store.record([draft("kept", "Still here"), draft("gone", "Lost one")], hostID: host)
        store.markMissing(hostID: host) { $0 == "kept" }
        #expect(store.lostDrafts(hostID: host).map(\.id) == ["gone"])
    }

    @Test func leavingAgainReplacesTheListButKeepsWhatIsWaiting() {
        let store = UnsentDraftStore(fileURL: nil, now: { now })
        store.record([draft("a", "First"), draft("b", "Second")], hostID: host)
        store.record([draft("x", "On the other computer", host: other)], hostID: other)
        store.markLost(chatID: "a")
        store.record([draft("c", "Third")], hostID: host)
        #expect(Set(store.drafts.map(\.id)) == ["a", "c", "x"],
                "b was sent or cleared; a is still waiting; the other computer's stays")
    }

    @Test func continuingOrLettingGoClearsThem() {
        let store = UnsentDraftStore(fileURL: nil, now: { now })
        store.record([draft("a", "One"), draft("b", "Two")], hostID: host)
        store.markLost(chatID: "a")
        store.markLost(chatID: "b")
        store.remove("a")
        #expect(store.lostDrafts(hostID: host).map(\.id) == ["b"])
        store.discardLost(hostID: host)
        #expect(store.drafts.isEmpty && store.lostDrafts(hostID: host).isEmpty)
    }

    @Test func draftsAreBoundedByCountLengthAndAge() {
        let store = UnsentDraftStore(fileURL: nil, now: { now })
        let many = (0..<15).map { draft("chat-\($0)", "Draft \($0)", at: now.addingTimeInterval(Double($0))) }
        store.record(many + [draft("old", "Last week", at: now.addingTimeInterval(-8 * 24 * 3600))], hostID: host)
        #expect(store.drafts.count == UnsentDraftStore.maximumCount)
        #expect(!store.drafts.contains { $0.id == "old" }, "Older than a week is let go")
        #expect(store.drafts.first?.id == "chat-14", "Newest first")
        store.record([draft("long", String(repeating: "x", count: 20_000))], hostID: host)
        #expect(store.drafts.first { $0.id == "long" }?.text.count == UnsentDraftStore.maximumCharacters)
    }

    @Test func draftsSurviveTheAppClosing() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = UnsentDraftStore(fileURL: url, now: { now })
        first.record([draft("a", "Survives a restart")], hostID: host)
        first.markLost(chatID: "a")
        let reopened = UnsentDraftStore(fileURL: url, now: { now })
        #expect(reopened.lostDrafts(hostID: host).map(\.text) == ["Survives a restart"])
        reopened.discardLost(hostID: host)
        #expect(!FileManager.default.fileExists(atPath: url.path), "Nothing left, no file left")
    }

    @Test func thePromptQuotesTheDraft() {
        #expect(UnsentDraftRecovery.message([draft("a", "Trip\nbudget")])
                == "You were writing to Alfie: “Trip budget”")
        #expect(UnsentDraftRecovery.message([draft("a", "One"), draft("b", "Two")])
                == "You have 2 unsent messages from before you left.")
        #expect(UnsentDraftRecovery.snippet(String(repeating: "a", count: 200)).count == 118)
    }
}
