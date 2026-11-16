import Foundation
import SwiftUI
import Testing
@testable import Bighelp

/// The open Dynamic Island for a chat with news: which chat leads, what it says and which buttons
/// it offers. A yes to a command is offered only beside the whole command.
@MainActor
struct IslandMomentTests {
    typealias State = LoopdySessionActivityAttributes.ContentState
    private let working = "native-" + String(repeating: "aa", count: 32)
    private let other = "native-" + String(repeating: "bb", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_030)

    private func state(_ rows: [BighelpActivitySession], lead: String? = nil) -> State {
        var state = BighelpActivitySession.aggregate(rows, timestamp: 1_800_000_000)
        state.lead = lead
        return state
    }

    private func row(_ id: String, _ phase: State.Phase) -> BighelpActivitySession {
        BighelpActivitySession(id: id, phase: phase, timestamp: 1_800_000_000)
    }

    private func detail(_ json: String) throws -> BighelpActivityDetail {
        try BighelpActivityDetail(json: Data(json.utf8))
    }

    private func moment(_ phase: State.Phase, _ json: String = #"{"v":1}"#,
                        level: BighelpActivityDetailLevel = .stepsAndText, isStale: Bool = false,
                        asOf: Date? = nil) throws -> BighelpIslandMoment? {
        let info = BighelpActivitySessionInfo(
            attributes: .init(sessionID: other, sessionTitle: "Active chat", agentID: "scout", agentName: "Scout"),
            title: "Weekend trip")
        return BighelpIslandMoment(state: state([row(other, phase)]), isStale: isStale, asOf: asOf ?? now,
                                   infos: [other: info], details: [other: try detail(json)], level: level)
    }

    @Test func theRowWithNewsIsShownFirst() {
        let rows = [row(working, .usingTool), row(other, .completed)]
        #expect(BighelpActivitySession.shown(state(rows)).map(\.id) == [working, other])
        #expect(BighelpActivitySession.shown(state(rows, lead: other)).map(\.id) == [other, working])
        // A lead that names no row on the card changes nothing.
        #expect(BighelpActivitySession.shown(state(rows, lead: "native-gone")).map(\.id) == [working, other])
    }

    @Test func aCardStateFromThePushNamesItsLeadAndOlderOnesStillRead() throws {
        let push = #"{"phase":"completed","currentAction":"","progress":0,"completedSteps":0,"activeSubagentCount":0,"latestTool":null,"timestamp":1800000000,"activeCount":0,"activeRows":[],"sessions":[],"lead":"native-x"}"#
        #expect(try JSONDecoder().decode(State.self, from: Data(push.utf8)).lead == "native-x")
        let older = push.replacingOccurrences(of: #","lead":"native-x""#, with: "")
        #expect(try JSONDecoder().decode(State.self, from: Data(older.utf8)).lead == nil)
    }

    @Test func theCardKnowsWhatKindOfAnswerWaits() throws {
        #expect(try detail(#"{"v":1,"q":"rm -rf build/cache","a":"c"}"#).ask == .command)
        #expect(try detail(#"{"v":1,"q":"deletes files","a":"a"}"#).ask == .approval)
        #expect(try detail(#"{"v":1,"q":"Send the order?","a":"q"}"#).ask == .question)
        #expect(try detail(#"{"v":1,"q":"Send the order?"}"#).ask == nil)
        #expect(try detail(#"{"v":1,"q":"Send the order?","a":"later"}"#).ask == nil)
        // A command the card would fold or cut is not the command a yes would run.
        #expect(try detail(#"{"v":1,"q":"echo  two  spaces","a":"c"}"#).ask == .approval)
        #expect(try detail(#"{"v":1,"q":"\#(String(repeating: "x", count: 220))","a":"c"}"#).ask == .approval)
    }

    @Test func aShortCommandGetsApproveAndDenyBesideIt() throws {
        let moment = try #require(try moment(.waiting, #"{"v":1,"q":"rm -rf build/cache","a":"c"}"#))
        #expect(moment.kind == .needsYou)
        #expect(moment.text == "rm -rf build/cache")
        #expect(moment.buttons == .decide)
        #expect(moment.agentName == "Scout")
        #expect(moment.status == "Needs you")
    }

    @Test func aYesIsNeverOfferedWithoutTheWholeCommandOnScreen() throws {
        // The computer says it must be read in the app.
        #expect(try moment(.waiting, #"{"v":1,"q":"deletes files","a":"a"}"#)?.buttons == .review)
        // Longer than the island shows whole.
        let long = String(repeating: "x", count: BighelpIslandMoment.wholeCommandCharacters + 1)
        #expect(try moment(.waiting, #"{"v":1,"q":"\#(long)","a":"c"}"#)?.buttons == .review)
        // The person turned the card's text off, so the command isn't on screen.
        let hidden = try #require(try moment(.waiting, #"{"v":1,"q":"rm -rf build/cache","a":"c"}"#, level: .steps))
        #expect(hidden.text == nil)
        #expect(hidden.buttons == .review)
        // A computer that doesn't say what waits gets a way into the chat, nothing more.
        #expect(try moment(.waiting, #"{"v":1,"q":"rm -rf build/cache"}"#)?.buttons == .open)
        #expect(try moment(.waiting, level: .statusOnly)?.buttons == .open)
    }

    @Test func aQuestionAFinishedReplyAndAFailureEachGetTheirOwnButtons() throws {
        #expect(try moment(.waiting, #"{"v":1,"q":"Send the order?","a":"q"}"#)?.buttons == .answer)
        let done = try #require(try moment(.completed, #"{"v":1,"p":"Booked the 7:40 train."}"#))
        #expect(done.kind == .done)
        #expect(done.text == "Booked the 7:40 train.")
        #expect(done.buttons == .reply)
        let failed = try #require(try moment(.failed))
        #expect(failed.kind == .failed)
        #expect(failed.text == nil)
        #expect(failed.title == "Weekend trip")
        #expect(failed.buttons == .open)
    }

    @Test func aChatThatOnlyWorksOrWentQuietKeepsThePlainRows() throws {
        #expect(try moment(.usingTool) == nil)
        #expect(try moment(.thinking) == nil)
        #expect(try moment(.waiting, isStale: true) == nil)
        #expect(try moment(.waiting, asOf: Date(timeIntervalSince1970: 1_800_000_121)) == nil)
        // A finished chat stays news: it has nothing more to say.
        #expect(try moment(.completed, asOf: Date(timeIntervalSince1970: 1_800_000_121)) != nil)
    }

    @Test func replyOnTheIslandIsAChatLinkThatAsksForTheKeyboard() throws {
        let reply = BighelpWidgetSnapshot.chatURL(other, reply: true)
        #expect(BighelpIncomingURLRoute.parse(reply) == .chat(sessionID: other))
        #expect(BighelpIncomingURLRoute.asksForReply(reply))
        #expect(!BighelpIncomingURLRoute.asksForReply(BighelpWidgetSnapshot.chatURL(other)))
        #expect(!BighelpIncomingURLRoute.asksForReply(try #require(URL(string: "loopdy://sessions?reply=1"))))
    }

    @Test func aReplyRequestIsTakenOnceAndOnlySoonAfterTheTap() {
        let tap = Date(timeIntervalSince1970: 1_800_000_000)
        ChatReplyRequest.note(at: tap)
        #expect(ChatReplyRequest.take(at: tap.addingTimeInterval(2)))
        #expect(!ChatReplyRequest.take(at: tap.addingTimeInterval(3)))
        ChatReplyRequest.note(at: tap)
        #expect(!ChatReplyRequest.take(at: tap.addingTimeInterval(60)))

        let state = AppState()
        state.requestReply(in: "chat-1")
        #expect(!state.consumeReplyRequest(for: "chat-2"))
        #expect(state.consumeReplyRequest(for: "chat-1"))
        #expect(!state.consumeReplyRequest(for: "chat-1"))
    }

    /// BIGHELP_EVIDENCE=<folder> (TEST_RUNNER_BIGHELP_EVIDENCE through xcodebuild) draws each moment's
    /// own views into a black shape the size of the open island and saves it as a PNG. The system draws
    /// the real island; a simulator's screenshots leave it out.
    @Test func picturesOfEachMoment() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_EVIDENCE"] else { return }
        let moments: [(String, State.Phase, String)] = [
            ("command", .waiting, #"{"v":1,"q":"rm -rf build/cache","a":"c"}"#),
            ("approval", .waiting, #"{"v":1,"q":"Deletes the old builds and their caches from three folders","a":"a"}"#),
            ("question", .waiting, #"{"v":1,"q":"Can I delete the 14 old drafts in Notes, Archive?","a":"q"}"#),
            ("done", .completed, #"{"v":1,"p":"Booked the 7:40 train to Leeds and put it in your calendar. The return is open until Friday."}"#),
            ("failed", .failed, #"{"v":1,"p":"The airline site asked for a sign-in I don't have. Your search is saved."}"#),
        ]
        for (name, phase, json) in moments {
            let moment = try #require(try moment(phase, json))
            let island = VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BighelpIslandMomentSender(moment: moment)
                    Spacer(minLength: 12)
                    BighelpIslandMomentStatus(moment: moment)
                }
                .frame(height: 40)
                BighelpIslandMomentBody(moment: moment).padding(.top, 4)
            }
            .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 18)
            .frame(width: 374)
            .foregroundStyle(.white)
            .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            .environment(\.colorScheme, .dark)
            for (look, page) in [("light", Color(white: 0.94)), ("dark", Color(white: 0.12))] {
                let renderer = ImageRenderer(content: island.padding(14).background(page))
                renderer.scale = 3
                let image = try #require(renderer.uiImage)
                try #require(image.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent("island-\(name)-\(look).png"))
            }
        }
    }
}
