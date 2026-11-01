import Foundation

/// A sheet on a bot's profile that code can open straight away: the Dashboard's pages, or one of
/// Info's rows. A drive uses this to show a person, for example, Dashboard › Templates › Feed.
enum BotProfileSheet: Hashable, Sendable {
    /// The Dashboard's Templates deck, opened on one page.
    case templates(AgentBoardItem.Kind)
    /// The Dashboard's full template list for one page.
    case blueprints(AgentBoardItem.Kind)
    /// A Dashboard pile's page (Feed, Ideas or Goals).
    case seeAll(AgentBoardItem.Kind)
    case character, instructions, photoActions, defaultModel, defaultVoice, advancedOptions
    /// The avatar studio, which people reach from Character's More avatars.
    case avatarStudio
    case addRoutine
    /// The header's Save as Template; it belongs to no tab, so it opens with Info.
    case saveAsTemplate

    /// The tab the sheet's button is on.
    var tab: SimpleBotProfileTab {
        switch self {
        case .templates, .blueprints, .seeAll: .dashboard
        case .character, .instructions, .photoActions, .defaultModel, .defaultVoice, .advancedOptions,
             .avatarStudio, .addRoutine, .saveAsTemplate: .info
        }
    }
}

/// Where a bot's profile opens when code asks: a tab, a sheet, or both. Nil in a route means
/// the profile opens as it does for a tap. Showing one never saves the tab as the default or
/// changes the tab order.
struct BotProfileOpening: Hashable, Sendable {
    var tab: SimpleBotProfileTab?
    var sheet: BotProfileSheet?
    /// A file on the bot's computer to open in its Files tab: one the person sent in a chat.
    var file: String?

    /// The tab to show first. A sheet wins over a tab that disagrees with it: the sheet's button
    /// has to be on screen. A file opens in Files.
    var wantedTab: SimpleBotProfileTab? { sheet?.tab ?? (file != nil ? .files : tab) }
}

/// What a profile has ready right now; a sheet waits until its part is here.
struct BotProfileReadiness: Equatable, Sendable {
    /// The tab on screen.
    var shownTab: SimpleBotProfileTab
    var canEdit = false
    /// The Dashboard's own model exists (the bot has a Dashboard and its tab has opened).
    var hasDashboard = false
    var hasModelDefaults = false
    var hasVoice = false
    var hasAdvancedOptions = false
    var hasRoutines = false
}

extension BotProfileSheet {
    /// Whether the sheet can show now: its tab is on screen and the part behind it is loaded. A
    /// tab this bot doesn't have (Computer without a screen, no Dashboard) never gets here, so
    /// the profile stays on its normal tab and shows no sheet.
    func canPresent(_ ready: BotProfileReadiness) -> Bool {
        guard ready.shownTab == tab else { return false }
        return switch self {
        case .templates, .blueprints, .seeAll: ready.hasDashboard
        // Their rows are off when the computer doesn't let the app edit.
        case .instructions, .photoActions: ready.canEdit
        case .defaultModel: ready.hasModelDefaults
        case .defaultVoice: ready.hasVoice
        case .advancedOptions: ready.hasAdvancedOptions
        case .addRoutine: ready.hasRoutines
        case .character, .avatarStudio, .saveAsTemplate: true
        }
    }
}
