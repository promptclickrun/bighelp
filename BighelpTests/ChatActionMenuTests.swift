import Foundation
import Testing
@testable import Bighelp

struct ChatActionMenuTests {
    @Test func successfulAttachmentImportDismissesDrawerAndRequestsComposerFocus() {
        var state = ChatAttachmentFlowState(
            isActionMenuPresented: true,
            composerFocusRequest: 4
        )

        state.completeSuccessfulImport()

        #expect(!state.isActionMenuPresented)
        #expect(state.composerFocusRequest == 5)
    }

    @Test func agentRowsExposeAnExplicitManagementAccessory() {
        #expect(AgentRowPresentation.actionAlignment == .center)
        #expect(AgentRowPresentation.actionSystemImage == "ellipsis")
        #expect(!AgentRowPresentation.showsNavigationDisclosureIndicator)
        #expect(AgentRowMenuAction.allCases.contains(.openChat))
        #expect(AgentRowMenuAction.allCases.contains(.togglePin))
    }

    @Test func successfulAgentSelectionReturnsOnlyTheDrawerSubmenuToMain() {
        #expect(ChatActionMenuAgentSelectionTransition.resolve(.reassigned) == .init(
            page: .main,
            errorMessage: nil
        ))
        #expect(ChatActionMenuAgentSelectionTransition.resolve(.unchanged) == .init(
            page: .main,
            errorMessage: nil
        ))
    }

    @Test func historyBlockedAgentSelectionKeepsTheAgentSubmenuAndExplainsWhy() {
        #expect(ChatActionMenuAgentSelectionTransition.resolve(.blockedByHistory) == .init(
            page: .agents,
            errorMessage: "This chat already has messages. Start a new chat to use a different agent."
        ))
    }

    @Test func sharedHistoryRemovalExplainsWhyBotModeMustKeepTwoAgents() {
        #expect(BotModeMemberRemovalPresentation.errorMessage(
            for: BotModeRoomError.sharedHistoryRequiresBotMode
        ) == "Group chats with shared messages must keep at least two agents.")
    }

    @Test func actionDrawerKeepsEveryActionInExactlyOneVisibleSection() {
        #expect(ChatActionMenuLayout.mediaActions == [
            .camera,
            .photo,
            .file,
        ])
        #expect(ChatActionMenuLayout.mediaColumnCount == 3)
        #expect(ChatActionMenuLayout.rowActions == [
            .scanDocument,
            .voice,
            .startSession,
            .chooseAgent,
            .skillsAndTools,
            .changeModel,
        ])
        #expect(
            Set(ChatActionMenuLayout.mediaActions + ChatActionMenuLayout.rowActions)
                == Set(ChatActionMenuAction.allCases)
        )
    }

    @Test func pickerAndActionDrawerUseTheSharedSemanticSurfaceHierarchy() {
        #expect(ChatActionMenuLayout.rootSurfaceRole == .sheet)
        #expect(BighelpPickerSheetLayout.rootSurfaceRole == .sheet)
        #expect(BighelpPickerSheetLayout.panelComponent == .menuPanel)
        #expect(BighelpPickerSheetLayout.rowComponent == .menuRow)
        #expect(BighelpPickerSheetLayout.searchComponent == .searchField)
        #expect(
            ChatActionMenuLayout.surfacePresentation(isDarkMode: true)
                == .init(base: .canvas, opacity: 0.72)
        )
        #expect(!ChatActionMenuLayout.usesColoredOutline)
    }

    @Test func configurableDrawerActionsStayInsideNestedPages() {
        #expect(ChatActionMenuAction.chooseAgent.submenu == .agents)
        #expect(ChatActionMenuAction.skillsAndTools.submenu == .skillsAndTools)
        #expect(ChatActionMenuAction.changeModel.submenu == .modelAndReasoning)
        #expect(ChatActionMenuAction.camera.submenu == nil)
        #expect(ChatActionMenuAction.voice.submenu == nil)
    }

    @Test func activeTurnLocksOnlyTheDrawerModelSelectionAction() {
        #expect(!ChatActionMenuAvailability.isEnabled(
            .changeModel,
            hasRuntimeControls: true,
            isTurnActive: true
        ))
        for action in ChatActionMenuAction.allCases where action != .changeModel {
            #expect(ChatActionMenuAvailability.isEnabled(
                action,
                hasRuntimeControls: true,
                isTurnActive: true
            ))
        }
        #expect(!ChatActionMenuAvailability.isEnabled(
            .changeModel,
            hasRuntimeControls: false,
            isTurnActive: false
        ))
        #expect(ChatActionMenuAvailability.isEnabled(
            .changeModel,
            hasRuntimeControls: true,
            isTurnActive: false
        ))
    }

    @Test func skillsAndPluginsSearchFiltersBothAndNeverProjectsMCPServers() {
        let catalog = HermesSkillsAndToolsCatalog(
            agentID: "finance",
            skills: [
                .init(
                    id: "weather",
                    name: "Weather",
                    description: "Forecasts",
                    category: "Research",
                    isEnabled: true
                ),
            ],
            plugins: [
                .init(
                    id: "loopdy",
                    name: "bighelp",
                    kind: "platform",
                    version: "1",
                    description: "Mobile delivery",
                    isEnabled: true,
                    capabilityCount: 2
                ),
            ],
            mcpServers: [
                .init(id: "filesystem", name: "Filesystem", transport: "stdio", isEnabled: true, toolCount: 4),
            ]
        )

        #expect(ChatSkillsAndPluginsIndex(catalog: catalog).entries(query: "")
            .map(\.kind) == [.skill, .plugin])
        #expect(ChatSkillsAndPluginsIndex(catalog: catalog).entries(query: "loop")
            .map(\.id) == ["loopdy"])
        #expect(ChatSkillsAndPluginsIndex(catalog: catalog).entries(query: "file").isEmpty)
    }

    @MainActor
    @Test func capabilitySelectionUsesOnlyUniqueAuthenticatedMatchingSlashCommand() throws {
        let weather = ChatSkillsAndPluginsEntry(
            id: "weather",
            kind: .skill,
            name: "Weather",
            detail: "Forecasts",
            metadata: "Research",
            isEnabled: true
        )
        let authenticated = SlashCommandDescriptor(
            name: "weather",
            description: "Use the Weather skill",
            category: "Skills",
            argsHint: "[place]",
            aliases: [],
            argumentMode: .text,
            source: .skill,
            requiresArguments: false
        )
        let unrelated = SlashCommandDescriptor(
            name: "help",
            description: "Show help",
            category: "Help",
            argsHint: "",
            aliases: [],
            argumentMode: .none,
            source: .core,
            requiresArguments: false
        )
        let bighelpPlugin = ChatSkillsAndPluginsEntry(
            id: "loopdy",
            kind: .plugin,
            name: "bighelp",
            detail: "Mobile delivery",
            metadata: "platform",
            isEnabled: true
        )
        let pluginCommand = SlashCommandDescriptor(
            name: "loopdy",
            description: "Use the bighelp plugin",
            category: "Plugins",
            argsHint: "[action]",
            aliases: [],
            argumentMode: .text,
            source: .plugin,
            requiresArguments: false
        )

        let resolved = ChatCapabilitySlashCommandResolver.command(
            for: weather,
            commands: [unrelated, authenticated]
        )
        #expect(resolved == authenticated)
        #expect(ChatCapabilitySlashCommandResolver.command(
            for: weather,
            commands: [unrelated]
        ) == nil)
        #expect(ChatCapabilitySlashCommandResolver.command(
            for: bighelpPlugin,
            commands: [unrelated, pluginCommand]
        ) == pluginCommand)

        let model = ChatModel(
            conversationID: "capability-command-session",
            client: ConversationFixtureClient(),
            initialItems: [],
            initialDraft: "Keep this only if selection fails"
        )
        model.selectSlashCommand(try #require(resolved))
        #expect(model.draft == "/weather ")

        let noMatchModel = ChatModel(
            conversationID: "capability-no-command-session",
            client: ConversationFixtureClient(),
            initialItems: [],
            initialDraft: "Keep this draft"
        )
        if let command = ChatCapabilitySlashCommandResolver.command(for: weather, commands: [unrelated]) {
            noMatchModel.selectSlashCommand(command)
        }
        #expect(noMatchModel.draft == "Keep this draft")
    }

    @Test func referenceDocumentPreservesConversationAttributionAndStructuredContent() throws {
        let attachment = try ChatAttachment(
            id: "attachment_reference_fixture_0001",
            fileName: "forecast.png",
            mimeType: "image/png",
            data: Data([1, 2, 3])
        )
        let record = SessionRecord(
            id: "session-reference-fixture-0001",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Weather / planning: Saturday",
            items: [
                TimelineItem(
                    id: "reference-message-1",
                    role: .human,
                    sender: .user(snapshot: .init(name: "Sam")),
                    content: .message("Check tomorrow's weather."),
                    metadata: .init(delivery: "Sent")
                ),
                TimelineItem(
                    id: "reference-message-2",
                    role: .assistant,
                    sender: .agent(id: "juno", snapshot: .init(name: "Juno")),
                    content: .weatherAndTasks(
                        WeatherAndTasks(
                            city: "Chicago",
                            condition: "Clear",
                            currentTemperature: 72,
                            highTemperature: 76,
                            lowTemperature: 61,
                            hourly: [],
                            tasks: []
                        )
                    ),
                    metadata: .init(source: "Weather"),
                    attachments: [attachment]
                ),
            ],
            hasAcceptedMessage: true
        )

        let document = try ChatReferenceDocumentBuilder.markdown(for: record)

        #expect(document.contains("# Weather / planning: Saturday"))
        #expect(document.contains("## Sam"))
        #expect(document.contains("Check tomorrow's weather."))
        #expect(document.contains("## Juno"))
        #expect(document.contains("weatherAndTasks"))
        #expect(document.contains("Attachments: forecast.png"))
        #expect(
            ChatReferenceDocumentBuilder.fileName(for: record)
                == "session-reference-weather-planning-saturday.md"
        )
    }
}
