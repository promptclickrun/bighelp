import Testing
@testable import Bighelp

@Suite("Bot profile opening")
struct BotProfileOpeningTests {
    private func ready(on tab: SimpleBotProfileTab, canEdit: Bool = true, hasDashboard: Bool = true,
                       hasModelDefaults: Bool = true, hasVoice: Bool = true, hasAdvancedOptions: Bool = true,
                       hasRoutines: Bool = true) -> BotProfileReadiness {
        BotProfileReadiness(shownTab: tab, canEdit: canEdit, hasDashboard: hasDashboard,
                            hasModelDefaults: hasModelDefaults, hasVoice: hasVoice,
                            hasAdvancedOptions: hasAdvancedOptions, hasRoutines: hasRoutines)
    }

    @Test func eachSheetBelongsToItsTab() {
        for kind in AgentBoardItem.Kind.dashboardOrder {
            #expect(BotProfileSheet.templates(kind).tab == .dashboard)
            #expect(BotProfileSheet.blueprints(kind).tab == .dashboard)
            #expect(BotProfileSheet.seeAll(kind).tab == .dashboard)
        }
        let info: [BotProfileSheet] = [.character, .instructions, .photoActions, .defaultModel, .defaultVoice,
                                       .advancedOptions, .avatarStudio, .addRoutine, .saveAsTemplate]
        for sheet in info { #expect(sheet.tab == .info) }
    }

    @Test func aSheetsTabWinsOverATabThatDisagrees() {
        #expect(BotProfileOpening(tab: .files, sheet: .templates(.feed)).wantedTab == .dashboard)
        #expect(BotProfileOpening(tab: .files, sheet: nil).wantedTab == .files)
        #expect(BotProfileOpening(tab: nil, sheet: .character).wantedTab == .info)
        #expect(BotProfileOpening(tab: nil, sheet: nil).wantedTab == nil)
    }

    @Test func aTabThisBotLacksFallsBackToTheUsualOne() {
        let noScreen: [SimpleBotProfileTab] = [.dashboard, .info, .files, .media]
        #expect(SimpleBotProfileTabs.shown(picked: .computer, defaultTab: nil, in: noScreen) == .dashboard)
        #expect(SimpleBotProfileTabs.shown(picked: .computer, defaultTab: "files", in: noScreen) == .files)
        #expect(SimpleBotProfileTabs.shown(picked: .media, defaultTab: nil, in: noScreen) == .media)
        let noDashboard: [SimpleBotProfileTab] = [.info, .files]
        #expect(SimpleBotProfileTabs.shown(picked: .dashboard, defaultTab: nil, in: noDashboard) == .info)
    }

    @Test func aSheetShowsOnlyOnItsTabOnceItsPartIsLoaded() {
        // The tab it needs isn't on screen (the bot lacks it), so no sheet shows.
        #expect(!BotProfileSheet.templates(.feed).canPresent(ready(on: .info)))
        #expect(!BotProfileSheet.character.canPresent(ready(on: .dashboard)))

        #expect(BotProfileSheet.templates(.feed).canPresent(ready(on: .dashboard)))
        #expect(!BotProfileSheet.templates(.feed).canPresent(ready(on: .dashboard, hasDashboard: false)))
        #expect(!BotProfileSheet.defaultVoice.canPresent(ready(on: .info, hasVoice: false)))
        #expect(BotProfileSheet.defaultVoice.canPresent(ready(on: .info)))
        #expect(!BotProfileSheet.defaultModel.canPresent(ready(on: .info, hasModelDefaults: false)))
        #expect(!BotProfileSheet.advancedOptions.canPresent(ready(on: .info, hasAdvancedOptions: false)))
        #expect(!BotProfileSheet.addRoutine.canPresent(ready(on: .info, hasRoutines: false)))
        // Instructions and Photo actions are off rows when the computer won't let the app edit.
        #expect(!BotProfileSheet.instructions.canPresent(ready(on: .info, canEdit: false)))
        #expect(BotProfileSheet.character.canPresent(ready(on: .info, canEdit: false)))
    }
}
