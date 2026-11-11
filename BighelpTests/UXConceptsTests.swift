import Foundation
import Testing
@testable import Bighelp

/// Covers the three UX concepts:
/// - 3A: Unified 3-way Home Experience selector (`Bots`, `Chat`, `Code`) & `allComputersTogether`
/// - 2A & 2B: Empty-board starter blueprints & inline `ChatBlueprintDraft` fill-in chips
/// - 1B: `NeedsYouEntry` badges, metadata & cross-surface triage projection
@MainActor
struct UXConceptsTests {
    // MARK: - 3A: Unified Home Experience Selector

    @Test func selectingHomeModeSwitchesCleanlyAcrossBotsChatAndCode() throws {
        let suite = "bighelp.modes.ux.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        #expect(settings.currentMode == .chat)

        settings.selectHomeMode(.bots)
        #expect(settings.currentMode == .bots)
        #expect(settings.simpleBotsEnabled)

        // Picking Code from Bots clears Bots mode, enables Code mode, and makes Code the active home.
        settings.selectHomeMode(.code)
        #expect(settings.currentMode == .code)
        #expect(!settings.simpleBotsEnabled)
        #expect(settings.codeModeEnabled)
        #expect(settings.startExperience == .code)
        #expect(settings.experience == .code)

        // Picking Chat returns to Chat without breaking Code availability in the mode switcher.
        settings.selectHomeMode(.chat)
        #expect(settings.currentMode == .chat)
        #expect(!settings.simpleBotsEnabled)
        #expect(settings.startExperience == .bighelp)
        #expect(settings.experience == .bighelp)
        #expect(settings.availableModes == [.bots, .chat, .code])
    }

    @Test func allComputersTogetherSyncsBotsAndChatFleetPreferences() throws {
        let suite = "bighelp.computers.ux.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        #expect(!settings.allComputersTogether)
        settings.allComputersTogether = true
        #expect(settings.allHostsMode)
        #expect(settings.simpleBotsMultiGateway)

        settings.selectHomeMode(.bots)
        #expect(settings.allComputersTogether)

        settings.allComputersTogether = false
        #expect(!settings.allHostsMode)
        #expect(!settings.simpleBotsMultiGateway)
    }

    // MARK: - 2A: Empty-Board Starter Blueprints

    @Test func starterBlueprintsPickDistinctTopicsWithFillInSlots() throws {
        let catalog = try BoardBlueprintCatalog.bundled()
        for kind in [AgentBoardItem.Kind.feed, .idea, .goal] {
            let starters = catalog.starterBlueprints(for: kind, limit: 3)
            #expect(starters.count == 3)
            #expect(starters.allSatisfy { !BlueprintAdLib($0.text).blanks.isEmpty })
            let distinctTopics = Set(starters.map(\.category))
            #expect(distinctTopics.count >= 2)
        }
    }

    // MARK: - 2B: Inline Blueprint Fill-In Chips in ChatComposer

    @Test func blueprintDraftAttachesPunctuationAndGatesSendUntilFilled() async {
        let model = ChatModel(
            conversationID: "blueprint-chip-test",
            client: ConversationFixtureClient(),
            initialItems: []
        )

        let started = model.beginBlueprintDraft(
            "Every morning, check mentions of [my brand] on my latest [videos / posts] under $[50]."
        )
        #expect(started)
        let draft = model.blueprintDraft
        #expect(draft != nil)
        #expect(draft?.blanks.count == 3)
        // Choice `[videos / posts]` and number `[50]` pre-fill; `[my brand]` starts focused and empty.
        #expect(draft?.activeBlankID == 0)
        #expect(draft?.hasValue(for: 1) == true)
        #expect(draft?.hasValue(for: 2) == true)
        #expect(!model.canSend)
        #expect(model.sendUnavailableReason == "fill in the blueprint blanks")

        // Adjacent `$` prefix and `.` suffix attach to blank #2 (`$[50].`) so no awkward space appears.
        if let lastBlankToken = draft?.tokens.last,
           case .blank(let blank, let prefix, let suffix) = lastBlankToken {
            #expect(blank.id == 2)
            #expect(prefix == "$")
            #expect(suffix == ".")
        } else {
            Issue.record("Expected final token to be the `$[50].` blank")
        }

        // Filling the remaining blank lights up Send and builds the clean bracket-free message.
        model.pickBlueprintSuggestion("bighelp", for: 0)
        #expect(model.blueprintDraft?.isComplete == true)
        #expect(model.draft == "Every morning, check mentions of bighelp on my latest videos under $50.")
        #expect(model.canSend)
        #expect(model.sendUnavailableReason == nil)

        await model.send()
        #expect(model.blueprintDraft == nil)
    }

    @Test func convertingBlueprintToPlainTextDropsChipModeAndKeepsWords() {
        let model = ChatModel(
            conversationID: "blueprint-plain-test",
            client: ConversationFixtureClient(),
            initialItems: []
        )
        #expect(model.beginBlueprintDraft("Every Monday, check what [competitor] shipped."))
        model.updateBlueprintBlank(0, value: "Linear")
        model.convertBlueprintToPlainText()

        #expect(model.blueprintDraft == nil)
        #expect(model.draft == "Every Monday, check what Linear shipped.")
        #expect(model.canSend)
    }

    // MARK: - 1B: Needs You Decision Deck Entries

    @Test func needsYouEntryMapsBadgesAndMetadataCleanly() {
        let waitingEntry = NeedsYouEntry(
            id: "waiting-bot:finance",
            payload: .waitingBot(
                .init(
                    agentID: "finance",
                    agentName: "Avery Park",
                    agentRole: "Finance agent",
                    hostName: "Mac Studio"
                )
            )
        )
        #expect(waitingEntry.kindBadge == .waiting)
        #expect(waitingEntry.agentName == "Avery Park")
        #expect(waitingEntry.metadataLine == "Mac Studio · Finance agent")
    }
}
