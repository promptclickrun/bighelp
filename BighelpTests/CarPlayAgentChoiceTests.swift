import Foundation
import Testing
@testable import Bighelp

/// Who CarPlay talks to: the saved pick, the fallback when that agent is gone,
/// the 12-item list, and when a chat goes on or starts new.
struct CarPlayAgentChoiceTests {
    private let rosa = CarPlayAgent(id: "rosa", name: "Rosa Quill", isDefault: true)
    private let omar = CarPlayAgent(id: "omar", name: "Omar Bell", isDefault: false)
    private let tess = CarPlayAgent(id: "tess", name: "Tess Wren", isDefault: false)

    private func agents(_ count: Int) -> [CarPlayAgent] {
        (1...count).map { CarPlayAgent(id: "agent-\($0)", name: "Agent \($0)", isDefault: $0 == 1) }
    }

    // MARK: Choosing

    @Test func theSavedAgentIsChosenWhileItExists() {
        #expect(CarPlayAgentChoice.resolve(requestedID: "omar", in: [rosa, omar, tess])?.id == "omar")
    }

    @Test func aMissingAgentFallsBackToTheHostChoice() {
        let chosen = CarPlayAgentChoice.resolve(requestedID: "gone", in: [rosa, omar, tess], fallbackID: "tess")
        #expect(chosen?.id == "tess")
    }

    @Test func aMissingAgentWithNoFallbackFallsBackToTheDefault() {
        #expect(CarPlayAgentChoice.resolve(requestedID: "gone", in: [omar, rosa, tess])?.id == "rosa")
        #expect(CarPlayAgentChoice.resolve(requestedID: nil, in: [omar, rosa, tess])?.id == "rosa")
        #expect(CarPlayAgentChoice.resolve(requestedID: nil, in: [omar, rosa], fallbackID: "also-gone")?.id == "rosa")
    }

    @Test func noAgentsMeansNoChoice() {
        #expect(CarPlayAgentChoice.resolve(requestedID: "omar", in: []) == nil)
        #expect(CarPlayAgentChoice.resolve(requestedID: nil, in: [omar, tess]) == nil)
    }

    // MARK: The list

    @Test func theListMarksTheCurrentAgentAndNotesTheDefault() {
        let rows = CarPlayAgentChoice.rows(for: [rosa, omar, tess], currentID: "omar")
        #expect(rows.map(\.title) == ["Rosa Quill", "Omar Bell", "Tess Wren"])
        #expect(rows.map(\.isCurrent) == [false, true, false])
        #expect(rows.map(\.detail) == ["Default", "Current", nil])
        let both = CarPlayAgentChoice.rows(for: [rosa, omar], currentID: "rosa")
        #expect(both[0].detail == "Current · Default")
    }

    @Test func theListShowsAtMostTwelveAgents() {
        let rows = CarPlayAgentChoice.rows(for: agents(30), currentID: "agent-1")
        #expect(rows.count == 12)
        #expect(rows.first?.id == "agent-1")
        #expect(rows.last?.id == "agent-12")
    }

    @Test func aCurrentAgentPastTheCutStillShows() {
        let rows = CarPlayAgentChoice.rows(for: agents(30), currentID: "agent-25")
        #expect(rows.count == 12)
        #expect(rows.last?.id == "agent-25")
        #expect(rows.last?.isCurrent == true)
        #expect(rows.filter(\.isCurrent).count == 1)
    }

    @Test func aShorterLimitIsKept() {
        #expect(CarPlayAgentChoice.rows(for: agents(30), currentID: nil, limit: 5).count == 5)
        #expect(CarPlayAgentChoice.rows(for: agents(30), currentID: "agent-9", limit: 5).map(\.id).last == "agent-9")
        #expect(CarPlayAgentChoice.rows(for: agents(3), currentID: nil, limit: 0).count == 1)
    }

    @Test func noAgentsMakeAnEmptyList() {
        #expect(CarPlayAgentChoice.rows(for: [], currentID: nil).isEmpty)
        #expect(CarPlayAgentChoice.rows(for: [], currentID: "omar").isEmpty)
    }

    // MARK: Saved on the device

    private func makePreference(_ name: String = #function) -> (CarPlayAgentPreference, UserDefaults) {
        let suite = "bighelp.tests.carplay.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CarPlayAgentPreference(defaults: defaults), defaults)
    }

    @Test func thePickIsSavedAndRead() {
        let (preference, _) = makePreference()
        #expect(preference.agentID == nil)
        preference.agentID = "omar"
        #expect(preference.agentID == "omar")
        preference.agentID = nil
        #expect(preference.agentID == nil)
    }

    @Test func aSavedPickSurvivesANewPreferenceOnTheSameDefaults() {
        let (first, defaults) = makePreference()
        first.agentID = "tess"
        #expect(CarPlayAgentPreference(defaults: defaults).agentID == "tess")
    }

    @Test func emptyOrOversizedIDsAreNeverSaved() {
        let (preference, defaults) = makePreference()
        preference.agentID = "omar"
        preference.agentID = "   "
        #expect(preference.agentID == nil)
        preference.agentID = String(repeating: "x", count: CarPlayAgentPreference.maximumIDLength + 1)
        #expect(preference.agentID == nil)
        defaults.set(String(repeating: "y", count: 500), forKey: CarPlayAgentPreference.key)
        #expect(preference.agentID == nil)
    }

    // MARK: Going on or starting new

    @Test func theSameAgentGoesOnInTheSameChat() {
        var continuity = CarPlayChatContinuity()
        continuity.remember(sessionID: "chat-1", agentID: "omar")
        #expect(continuity.reusableSessionID(for: "omar") == "chat-1")
    }

    @Test func anotherAgentStartsANewChat() {
        var continuity = CarPlayChatContinuity()
        continuity.remember(sessionID: "chat-1", agentID: "omar")
        #expect(continuity.reusableSessionID(for: "tess") == nil)
        continuity.remember(sessionID: "chat-2", agentID: "tess")
        #expect(continuity.reusableSessionID(for: "tess") == "chat-2")
        #expect(continuity.reusableSessionID(for: "omar") == nil)
    }

    @Test func aNewConnectionStartsANewChat() {
        #expect(CarPlayChatContinuity().reusableSessionID(for: "omar") == nil)
    }
}

/// The car's home and its live steps, and the computer Settings › CarPlay picks.
@MainActor
struct CarPlayHomeTests {
    @Test func theHeaderSaysWhatTheConversationIsDoing() {
        #expect(CarPlayHeaderContent.status(phase: .connecting, step: nil) == "Connecting…")
        #expect(CarPlayHeaderContent.status(phase: .listening, step: nil) == "Listening")
        // Working shows the agent's step, as voice mode does.
        #expect(CarPlayHeaderContent.status(phase: .working, step: "Checking your calendars…") == "Checking your calendars…")
        #expect(CarPlayHeaderContent.status(phase: .working, step: nil) == "Working…")
        #expect(CarPlayHeaderContent.status(phase: .paused, step: nil) == "Tap Talk to start")
        #expect(CarPlayHeaderContent.isTalking(.speaking))
        #expect(!CarPlayHeaderContent.isTalking(.paused))
        #expect(!CarPlayHeaderContent.isTalking(.problem("x")))
    }

    @Test func eachNewStepPushesTheLastOneDownAndTheTurnsEndClearsThem() {
        var step: String?
        var earlier: [String] = []
        for next in ["Searching the web…", "Searching the web…", "Reading the page…", "Writing it up…", "Checking the map…"] {
            (step, earlier) = CarPlayVoiceSession.steps(after: step, earlier: earlier, next: next, isWorking: true)
        }
        #expect(step == "Checking the map…")
        #expect(earlier == ["Writing it up…", "Reading the page…", "Searching the web…"], "Newest first, one line each")
        (step, earlier) = CarPlayVoiceSession.steps(after: step, earlier: earlier, next: nil, isWorking: false)
        #expect(step == nil)
        #expect(earlier.isEmpty)
    }

    @Test func theComputerPickedForCarPlayIsKeptOnThisDevice() throws {
        let name = "carplay-host-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = CarPlayAgentPreference(defaults: defaults)
        #expect(preference.hostID == nil, "The one bighelp is using, until one is picked")
        let host = UUID()
        preference.hostID = host
        #expect(CarPlayAgentPreference(defaults: defaults).hostID == host)
        preference.hostID = nil
        #expect(CarPlayAgentPreference(defaults: defaults).hostID == nil)
    }

    @Test func aStallSaysWhichStepItWas() {
        #expect(CarPlayConnectStep.computer.problem.contains("couldn't reach your computer"))
        #expect(CarPlayConnectStep.chat.problem.contains("chat didn't start"))
        #expect(CarPlayConnectStep.voice.problem.contains("voice didn't start"))
    }
}
