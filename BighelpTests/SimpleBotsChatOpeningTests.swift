import Foundation
import Testing
@testable import Bighelp

/// Bots mode's opening loader for a chat on the gateway in use: it waits a short grace so a quick
/// open never flashes it, stays up until the chat can show its messages, and ends on Cancel or an error.
@MainActor
struct SimpleBotsChatOpeningTests {
    @Test func aCachedChatNeverShowsTheLoaderEvenDuringGatewayHandover() {
        let opening = opening()
        opening.showsNextAtOnce = true
        let id = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [], hasCachedContent: true)
        opening.show(id)
        #expect(!opening.isShowing, "A cached transcript, including a saved empty chat, is usable immediately")
        #expect(opening.current == nil)
    }

    /// The grace never ends by itself here: each test says when it's over (`show`).
    private func opening() -> SimpleBotsChatOpening {
        SimpleBotsChatOpening(grace: .seconds(3_600))
    }

    @Test func aQuickOpenNeverShowsTheLoader() {
        let opening = opening()
        let id = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        #expect(opening.current?.name == "Mina Shah")
        #expect(!opening.isShowing, "Nothing shows during the grace")
        opening.attach(id, conversationID: "chat-1")
        opening.update(.ready)
        #expect(opening.current == nil)
        opening.show(id)
        #expect(!opening.isShowing, "A grace that ends after the chat is ready shows nothing")
    }

    @Test func aSlowOpenShowsTheLoaderUntilTheChatIsReady() {
        let opening = opening()
        let id = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        opening.show(id)
        #expect(opening.isShowing)
        opening.attach(id, conversationID: "chat-1")
        opening.update(.waiting)
        #expect(opening.isShowing, "The chat is there but its messages aren't yet")
        opening.update(.ready)
        #expect(!opening.isShowing)
        #expect(opening.current == nil)
    }

    @Test func theGraceEndsByItself() async throws {
        let opening = SimpleBotsChatOpening(grace: .milliseconds(20))
        opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        #expect(!opening.isShowing)
        let deadline = ContinuousClock.now + .seconds(5)
        while !opening.isShowing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opening.isShowing)
    }

    @Test func cancelGivesBackWhatWasOpeningAndEndsIt() {
        let opening = opening()
        let origin: [AppRoute] = [.simpleBotProfile(agentID: "travel")]
        let id = opening.begin(agentID: "travel", name: "Mina Shah", originPath: origin)
        opening.show(id)
        opening.attach(id, conversationID: "chat-1")
        let cancelled = opening.cancel()
        #expect(cancelled?.conversationID == "chat-1")
        #expect(cancelled?.originPath == origin)
        #expect(opening.current == nil)
        #expect(!opening.isShowing)
        opening.show(id)
        #expect(!opening.isShowing, "A cancelled open's grace never shows the loader")
    }

    @Test func aFailureEndsTheLoaderSoTheErrorShows() {
        let opening = opening()
        let id = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        opening.show(id)
        opening.update(.failed)
        #expect(opening.current == nil)
        #expect(!opening.isShowing)
    }

    @Test func anOpenWithNothingPresentedEnds() {
        let opening = opening()
        let id = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        opening.show(id)
        opening.endIfNothingOpened(id)
        #expect(opening.current == nil)

        // Once its chat is on screen, it waits for the chat instead.
        let next = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        opening.attach(next, conversationID: "chat-1")
        opening.endIfNothingOpened(next)
        #expect(opening.current?.id == next)
    }

    @Test func theSameBotsFallbackKeepsTheOpenUnderWay() {
        let opening = opening()
        let id = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        opening.show(id)
        // The Bot Chat lookup fell back to the latest chat, which opens the same way.
        let again = opening.begin(agentID: "travel", name: nil, originPath: [])
        #expect(again == id)
        #expect(opening.isShowing)
        #expect(opening.current?.name == "Mina Shah")
    }

    @Test func anotherBotReplacesTheOpen() {
        let opening = opening()
        let first = opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        let second = opening.begin(agentID: "finance", name: "Avery Park", originPath: [])
        #expect(first != second)
        #expect(opening.current?.name == "Avery Park")
        opening.show(first)
        #expect(!opening.isShowing, "The replaced open's grace shows nothing")
    }

    @Test func multiGatewaysLoaderHandsOverWithNoGap() {
        let opening = opening()
        opening.showsNextAtOnce = true
        opening.begin(agentID: "travel", name: "Mina Shah", originPath: [])
        opening.showsNextAtOnce = false
        #expect(opening.isShowing, "The gateway's loader was already up: no new grace")
    }
}
