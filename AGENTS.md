# AGENTS.md: working on the bighelp iPhone app

This guide is for AI agents and people picking up work on bighelp. It covers how we work, where things live, and the
traps that have already cost us time. Read it before you change anything. Release steps, the maintainer's own hosts
and service deploys are covered by private notes kept outside the repo; agents on the maintainer's machine are told
where they are.

## What bighelp is

bighelp is a native iPhone, iPad, Mac and Vision Pro app (plus Watch, widgets, Live Activities and Shortcuts) for personal AI agents running
on [Hermes](https://github.com/NousResearch/hermes-agent). It should feel like texting a friend, not like running a
server. The app talks straight to the user's own Hermes host. There's no bighelp account.

The companion Hermes plugin lives in [bighelp-plugin](https://github.com/promptclickrun/bighelp-plugin). It adds the
extras: Feed/Ideas/Goals, cards, live voice, provider usage, secure input, and notifications. Many features need a
change in both repos.

## Mindset

- **Simple for normal people.**
  - Everyday screens use plain words and short sentences.
  - Anything that looks like host administration goes behind Settings › Advanced options: files, MCP, logs, raw
    IDs, token counts. The switch is `settings.nerdModeEnabled`, also the `nerdModeEnabled` environment value and
    the id `settings.nerd-mode`. The code name is still Nerd Mode: only what a person reads changed. Its sections
    sit last on the page they tune, headed "Advanced" or "Advanced · <name>".
  - What agents can add is for everyone: Settings › Apps & skills (`AppsHubView`) lists Skills, Plugins (with this
    week's featured plugin) and Talk anywhere (Messaging apps), and with Advanced options on, MCP servers and
    Toolsets. Each bot's profile has its own Marketplace (`MarketplaceView`) for that bot, with the same pages. A
    bot's Advanced Options no longer lists the Skills Hub, Plugins or MCP servers. A bot's profile also has
    Connections (Device access and its apps),
    Core Files and Active Project. Core Files: its SOUL.md, USER.md, MEMORY.md and the AGENTS.md Hermes loads for
    its chat (the chat's folder: the open chat when it's this bot's, else its Bot Chat; plugin
    `native-core-files-chat-v1`), read and saved whole through the plugin's `core-files/*` in the Markdown viewer
    (`CoreFilesView`). Active Project (`BotActiveProjectView`) sets the project the bot's new chats start in, in a
    `HermesWorkspaceStore` of its own (`separateStore()`), so the shell's Projects never move.
  - Everyday controls must never live only behind Advanced options.
- **One place for each thing.**
  - There's one Settings (`SettingsView`), and the person's circle in the header opens it from every tab. Its first
    screen is a short list of rows that each open one page, in groups: the person's row, Usage and, while a share
    waits, Shared with bighelp; Your bots (Models, Apps & skills, Voice, Personality and the Teamwork switch); This
    app (Appearance, Chat, Notifications); on Vision Pro the agent in the room; Your computers (one row per
    computer, Add a computer, Show every computer, Time zone, and with two or more, Update every computer); then
    Help & feedback and the Advanced options switch.
  - Settings copy follows DESIGN.md › Simplicity means hierarchy. A row's title is one to three words and its second
    line is its current value (a hint of at most six words, only when needed). Every section has a sentence-case
    header and at most one footer. Advanced groups come last and show only with Advanced options on. Consequences
    for data, cost and deletion stay at the control.
  - Appearance › Thinking (`ThinkingLookSettingsView`) picks the look of the Thinking control
    (`BighelpThinkingLook`, kept on the device) that a chat's Model settings shows (`ChatModelSettingsSheet`,
    from the model chip in the message box). Model settings sends each choice as it's made; there is no Apply.
  - Apps & skills (`AppsHubView`) is everything agents can use: This device (Device access, every phone tool and
    iOS permission) first, then Apps (Built-in apps, Composio), Skills and plugins, Talk anywhere, Logins (the
    credential vault) and, with Advanced options, MCP servers and Toolsets. Models (`ModelsSettingsView`) is the
    providers and each bot's default model on one page. Each computer has one page (`BighelpConfiguredHostView`:
    Use this computer, Updates, Restart, This computer, Access, its Advanced groups, Remove this computer), and
    Update every computer (`FleetSettingsView`) updates and restarts them together. Appearance holds the
    companion pet, and Help & feedback the usage-sharing switch and the Apple Watch's status. The
    old Hermes tools list (`WorkspaceHubView`) and Settings › System are gone: their pages open from where they
    belong (skills, plugins, messaging apps, MCP servers and toolsets in Apps & skills; logs, webhooks, tool
    backends, the computer voice test, diagnostics, backups, config.yaml, shell hooks and Kanban boards on a
    computer's page; Clean up chats and Archived chats in Chat; Toolsets and Manage bots in a bot's Advanced
    Options › For experts).
  - Don't add a second menu, drawer or settings copy for a feature. Add a row where people already look.
  - There are no modes. One home has three places, the same for everyone: the first shows the Bots view
    (`SimpleBotsHomeView`) or the Chats view (`ChatsInboxView`), then Today (`TodayView`) and Work (`WorkView`). The
    first tab takes the name of the person's default view (`settings.homeView`), and the header's Bots | Chats
    switch (`HomeViewSwitchPill`) changes the view for this run only. `HomeSelection` (`appState.home`, one for the
    whole app; `AppState()` in tests and previews makes its own) holds the tab, the view, New chat's picks
    (`NewChatSession`) and Today's layout and boards, so they stay when the computer in use changes. A tab is a root: `AppState.select(_:)` closes whatever was pushed, and
    `select(_:thenOpen:)` shows a page over a tab for links, widgets and alerts (`showOverWork`, `showOverToday`).
  - The app opens on Settings › Chat › Opens on (Bots, Chats, Today or Work: `settings.homeLanding`, read once per
    launch as `launchHomeLanding` and applied by `HomeSelection.land`). With Today or Work, Chat › First tab shows
    picks the first tab's view. No chat opens by itself. `HomeSettingsMigration` reads the old settings once
    (marker `bighelp.home.migrated-v1`; it renames no key and removes none): Bots mode opens on Bots, Code mode as
    the launch home opens on Work, an old Opens on screen maps to its place, the all-hosts view and Multi-gateway
    become Show every computer, and a mode edge swipe becomes the edge's default (Bots mode's own swipes are
    written down as the swipes they were).
  - The bar is the same for everyone (`HomeTabBar`): the three places in a glass capsule, and the round New chat
    button beside it. It shows on roots only, so a pushed page, a chat included, has Back instead, and the keyboard
    hides it. Vision Pro puts the places in an ornament (`HomeTabOrnament`), and the iPhone Duo's side strip holds
    them as toolbar items (`HomeStripTabs`). Today's dot on the bar means Needs you has an entry.
  - Every root hides the navigation bar and draws one header (`HomeHeaderBar`, from a `HomeHeaderContext`): the
    person's circle, which opens Settings, then the Bots | Chats switch or the title (Today, Work), search (a
    button that opens a search page, or a field on a row under the buttons: `HomeHeaderSearch`), the computer menu
    (Today and Work, with two or more computers; a computer that doesn't answer gives the selection back, as
    everywhere: `selectFleetHost`), the root's own control (Today's Edit) and +. Place the header's
    buttons with `bighelpHeaderButtonsPlacement()`, so they sit where a top bar puts them on every screen
    (`MenuButtonPlacementUITests`). When the switch or the title doesn't fit beside the buttons (large text), it
    moves to a row of its own instead of being cut.
  - Search is a `BighelpSearchField` as the first row under the header (`bighelpListSearchRow()`), filter chips
    below it; never `.searchable` on a screen with the bar (iOS 26 puts it along the bottom, on the bar).
  - iPhone has no menu and no sidebar. iPad at regular width has a slide-in sidebar behind a header button
    (`HomeMenuPresentation`). The Mac and Vision Pro have the sidebar column (`BighelpSideMenu` hosts
    `HomeSidebar`, drawn again from the stores by `BighelpLiveColumn`). It lists the three places, Settings, New
    chat, up to eight recent chats with See all, and More: Needs you while something waits, Shared with bighelp
    while a share waits, Usage and, on Vision Pro, Simple mode. A new place goes where people already look (a Work
    door, a Settings row), not in More.
  - Every chat is a pushed page (`AppRoute.chat`) with one header (`ChatPushedHeader`, from
    `AgentHomeChrome.pushedChat`): Back, the bot and ⋯. The bot opens its bot page (`openBotPage(fromChat:)` pushes
    one run-loop turn later: a push straight from the header's tap was dropped about one time in three). ⋯ ends
    with Bot page, the same push. No bar sits under a chat.
  - Work's four doors (Projects, Tasks, Workflows, Schedules) open Projects, Kanban, Workflows and Scheduled tasks as
    pushed pages, each only where the computer has it. Usage is a pushed page too (Settings' first group, the
    sidebar's More). Settings is a sheet: Back steps through it, Done closes it.
  - Never show "bighelp account" or "Link" wording. That pairing system is retired.
  - Needs you (`NeedsYouDeckView`) is the one place a waiting approval, question or workflow sign-off is
    answered outside its own card: a chat's prompts open it (`ChatAttentionPresenter`), Today's Needs you card
    opens it, and the sidebar's More has its row, both only while something waits. Each entry is read from where it lives (`RootShellView.needsYouEntries`):
    prompts on open chats' connections, the Dashboard's list for chats that aren't open, one entry per
    prompt ID (`DashboardAttentionItem.promptID`; Hermes' prompts reach the app both ways), and
    `WorkflowsStore.waiting` (the store is made and read as soon as the computer says it has Workflows, so a
    sign-off shows on Today before Work is ever opened). A bot whose chat isn't open gets only an Open chat row. A long command or
    sign-off file opens in full before Approve works. Prompts answer through `DirectHermesPromptResponseView`
    (its `deck` look), the same code as the card in the chat. There is no Activity screen: an alert that names no
    chat opens Needs you while something waits (`AppState.openNeedsYou()`; the request is kept in `HomeSelection`, so
    the shell on screen gets it whichever computer's `AppState` took it), else Today. A bot's Dashboard
    tab and its Activities list stay.
  - A blueprint is filled in in the message box, nowhere else: a pick anywhere (a board's Blueprints, an
    empty board's starters, a bot's Dashboard) leaves it for the chat with `fillsBlanks`
    (`AppState.leaveComposerText`), and its [blanks] show as chips (`ChatBlueprintDraft`,
    `ChatModel.blueprintDraft`). Brackets in any other text are just text. The chips are the draft: when
    the draft becomes anything else, they go. A blank offers only the choices its blueprint wrote.
  - Text a board leaves for a new chat (Ask, Discuss, a blueprint) is shown by the chat's blank canvas
    (`showComposerText`) and taken by the chat Hermes makes (`takeComposerText`). The canvas is thrown
    away when that chat arrives, and its draft doesn't always get across in time: text only the canvas
    took was lost about every other time.
  - An idea, Feed post or goal goes to a chat as a card (`ChatBoardCard`): a block before the person's
    words in the message's own text, so the agent reads all of it and a reread draws it in their bubble.
    Discuss puts it in the message box (`ChatModel.boardCardDraft`). Let's do it sends "Let's do it!"
    with the idea at once (`leaveComposerText(sendsAtOnce:)`, `ChatModel.sendFromOutside`), never
    touching the box, and the idea moves to Ideas › Completed (the plugin's `answer`, `answeredAt`).
  - New chat is the new chat's own screen, drawn by the ordinary chat (`ChatNewChatSlot`, handed only to the chat
    whose ID is `NewChatSession.conversationID`, never decided from its messages; from the first message on, staged,
    sending or sent, it's an ordinary chat). Under Back and ⋯ a To row (`NewChatToRow`) holds the picked bots as
    chips and a field that filters the people list (`NewChatPeopleList`, over the empty messages): one bot is a
    chat, two to six (`BotModeRoom.maximumMembers`) a group chat, and a group chat the person already has can be
    picked at the end of the list. With nobody picked the blank chat is the primary bot's; picking another single
    bot makes the chat that bot's, replacing the blank chat in one step (`NewChatCoordinator.start(replacingBlankChat:)`).
    A pick made while a chat starts waits, and the To row is read again when the start ends: the latest pick wins.
    The message box's Send asks `ChatComposerActions.sendOverride` first (`NewChatSend.decide`): `.chat` sends in
    this chat, `.group` makes the group chat, `.coding` and `.staged` hand the text to `CodeHomeStore` and go to
    Work. Send sends everything in the box, or sends nothing, keeps the box and says why in a line under the To
    row (`NewChatSend.Note`): with nobody picked it says "Pick who gets this" and puts the cursor in the To field.
    A group chat and a coding session start with text only, so they are refused while the box holds an attachment
    or a reference, and so is a pick that would replace the chat. A group Send keeps its text in the box until the
    group chat is open (`NewChatSession.isStartingGroup` holds a second Send), so a group that can't be made loses
    nothing. Text that goes with a pick to another computer rides in `HomeSelection.newChatHandoff`, dropped when
    that computer doesn't open. Only a blank chat is ever taken off the stack (`AppState.dropBlankChat`). The
    override holds a `NewChatSendRelay` and must not capture a view (the box keeps it while the chat is open), and
    the choices row reads `ChatModel.draftShape` inside its own host view, never in the shell: a key press would
    redraw the shell. + offers attachments only for a plain one-bot chat, and voice and ⋯ › Bot page show only
    while the To row is exactly the chat's own bot.
  - For exactly one bot on a computer that has a coding store, a single row under the message box scrolls sideways
    (`NewChatChoicesRow`, `Equatable`): Project (none is an ordinary chat), then, once a project is picked, where it
    runs (a new worktree or local), the branch, the mode (Hermes' Plan and YOLO, `CodeSessionMode`) and Stage. A
    project makes the chat a coding session (`CodeLauncher`; see Coding sessions below). There is no Code home and no
    Code message box: Work lists the coding sessions, and Work filtered to a project (`AppRoute.work(projectID:)`)
    is the project's own page.
  - Chats (`Bighelp/Home/Chats/`) lists every chat on every computer, newest first, with Pinned on top and the rest
    by day. Once two or more computers show, one row of chips (All, each computer, Unread) sits under search. The
    computer in use is read live from its catalog; the others come from their all-hosts copies (`FleetStore`) and
    open through `openFleet`. Pin and Mark Read or Unread change only the computer in use's chats; another
    computer's rows rename and archive. "This computer" pushes that computer's own Sessions page (projects,
    imports from other apps, one bot's chats). The list is a pure function of the stores (`ChatsInboxProjection`),
    kept until an input changes (`ChatsInboxCache`), so a computer's events don't redo it.
  - Today (`Bighelp/Today/`) is a grid of panels under the header (`TodayPanelGrid`; Small, Wide or Tall), with the
    Needs you card and the Shared with bighelp card above it while something waits, and the Make a space box
    below (`TodayCreateBox`, hidden while the computer in use's plugin has no spaces). A panel is Feed, Ideas and
    Goals for every bot (`TodayBoardsPanel`; See all pushes `TodayBoardPage` as `AppRoute.board`) or a space
    (docs/SPACES.md). Edit changes order, hiding and size and deletes a space (`TodayPanelLayoutStore`; a space's
    own layout belongs to its computer). What a panel's long press offers, VoiceOver gets from the panel's Actions
    menu. A refusal (Update now too soon, a delete the computer refused) shows as one quiet line under the header
    (`TodayNotice`). A read where no bot answered is not a read: the boards keep loading rather than say "Nothing
    yet". One `TodayBoardsStore` and one `TodayPanelLayoutStore` live in `HomeSelection`, above the per-computer
    `AppState`. `TodayBoardPage` is a pushed page, so it brings the shell's board to the connection of the moment
    itself (`configureShellBoard`, as a bot's Dashboard does): the shell's root task waits under a pushed page, and
    after a return to the app the page then showed its copy while the computer refused every thumbs down and Clear.
  - Work (`Bighelp/Work/`) is one list of what the bots are doing, each row read from the store that holds it
    (`WorkProjection`): coding sessions, chats and background work running now, workflow runs, Kanban tasks and
    scheduled tasks. Chips: All, Needs you, Working, Done. Four doors lead on: Projects, Tasks, Workflows and
    Schedules. Work filtered to a project has the navigation bar (Back, the project's name, ⋯ with pull requests,
    worktrees and Dev Factory), not `HomeHeaderBar`.
  - One bot page for every bot from every door (`SimpleBotProfileView`, `AppRoute.simpleBotProfile`): a bot's name
    in a chat header, Bot Profile in a bot's long-press menu, a bot chip on a Today board. Its tabs are Dashboard,
    Info, Computer, Files and Media. Info's About rows (Name, Role, Summary) edit in place, Handle is read only, and Approvals
    lists what the bot asked to do. ⋯ holds what is done to the bot: New chat, Chats with this bot, Pin, Use with
    Siri, Duplicate, Manage bots and Delete bot. The shell fills `SimpleBotProfileContext` in
    `RootSimpleBots.simpleBotProfileContext(for:)`; a bot on another computer is pushed only once that computer
    is in use (`openingComputer`). There is no profile sheet, no action sheet and no Agents screen.
  - Sections are folders of bots and group chats (`Bighelp/SimpleBots/SimpleBotsSections.swift`): cards on the Bots
    view and a page of their own (`AppRoute.simpleBotsSection`, the home view with a `sectionID`). A bot's section
    is its profile's `AgentListPlacement` (Hermes Desktop's field, saved on its own computer through
    `SimpleBotsSectionEditor`); the sections list and each group chat's section, pin and hide are `FleetStore`'s,
    kept on the computers too (`bots.layout`). Same-named sections on two computers are one (`FleetSectioning`).
    With one computer shown, a section whose members are all elsewhere stays off (`SimpleBotsSectioning.elsewhere`).
    + on the Bots view is New Bot, New Group Chat and New Section, each only where it can work
    (`SimpleBotsNewItem`); the bot and group chat menus come from `SimpleBotsMenuAction`.
  - Show every computer (Settings › Your computers, `settings.showsEveryComputer`, on until turned off) puts every
    computer's bots and chats in the Bots view, the Chats view and New chat's people list: the computer in use
    live, the others from the all-hosts copies (`SimpleBotsGateways`, one `SimpleBotsBot` model keyed by
    `FleetID`). It is the one switch behind the old all-hosts view and Multi-gateway (the saved key is the old
    all-hosts one). Pins live on each bot's own computer; the primary bot is kept on the device
    (`simpleBotsMultiPrimary`). Acting on another computer's bot goes through `openFleet`; the Bots view stays
    under the lifter loader (`SimpleBotsOpeningOverlay`, with Cancel) until the bot opens. A computer that
    doesn't answer gives the selection back to the one the tap came from (`FleetSwitchFallback`), so neither the
    app nor its next launch is left on it. While it's on, the other computers stay connected
    (`keepsFleetHostsConnected`), through the background grace too, so opening on one is instant.
  - First run (`FirstRunOnboardingView`) is Welcome (with an optional Appearance step behind Appearance options),
    the AI data agreement if not given yet, Connect, the optional plugin, notifications (only once the plugin is
    in), then "How do you want to start?" (`FirstRunHome`: With a bot opens on Bots, Across chats on Chats; the
    answer sets Opens on, which Settings › Chat changes later). Optional steps have a small Skip; Connect and the
    start question don't. `FirstRunOnboarding.afterConnectKey` keeps it on screen after host setup's own finish.
    The two cards draw a small sketch of the home they open (`FirstRunHomeSketch`), not a screenshot.
- **Real data only.**
  - Avatars, activity poses and badges must come from what the agent is actually doing.
  - Never fake progress.
- **No AI spending by default.**
  - Feed, Ideas and Goals start empty, with no default scheduled jobs.
  - Content appears only after the user asks their agent for it.
- **The plus button only adds to a message.** Its menu (`ChatAttachmentMenu`, `ChatActionMenuAction`) is Camera,
  Scan Document, Photo Library, Files and Drawing (Apple's canvas, `ChatDrawingSheet`; Add attaches a picture).
  Never put a setting or a way to another screen there: the model chip, the voice button, New chat and Settings
  hold those.
- **Protect the chat.** The accepted chat behavior is a contract: [docs/CHAT_INTERACTION_CONTRACT.md](docs/CHAT_INTERACTION_CONTRACT.md).
  New looks must not break scrolling, drafts, streaming, keyboard control or history.
- **Reproduce first, then fix the root cause.**
  - Write the failing test before the fix, and make sure it fails without the fix.
  - Fakes must behave like the real host. For example, Hermes answers `prompt.submit` with `streaming`, not `queued`.
    A fake that says `queued` hid a real bug.
- **Verify what you ship.**
  - Run it, look at screenshots in light and dark mode, and use the real controls.
  - Say which evidence came from demo fixtures, which from a real host, and which from a device.
  - Don't call something done without proof.
- **Keep it focused and tidy.**
  - Match the surrounding code, naming and comment density. Comments explain why, not what.
  - Remove temporary files, simulators, proxies and background processes you started.
- **This repo is public.** Never put a real person's data, hosts, balances or plans in code, tests, docs, issues or
  screenshots. Use made-up numbers.

## Where things live

| Path | What it is |
|---|---|
| `Bighelp/App/` | App composition, `RootShellView` and its `Root*.swift` extensions (`RootHome` draws the three roots, the bar and the sidebar), routes (`AppRoute`, `RootDestinations`), `AppState`, `BighelpSideMenu`, connection keeper, widget/Shortcut entry points |
| `Bighelp/Home/` | The one home's parts: `HomeSelection`, `HomeHeaderBar`, `HomeTabBar` (+ `HomeTabOrnament`, `HomeStripTabs`), `HomeSidebar`, `Chats/` (the Chats view) and `NewChat/` (`NewChatSession`, the To row, the people list, the choices row, `NewChatSend`) |
| `Bighelp/Today/`, `Bighelp/Work/` | The Today and Work tabs: panel grid, layout store, boards panel and page, Needs you card; Work's list, cards and doors (`WorkProjection`) |
| `Bighelp/Spaces/` | Spaces on Today: the plugin client, stores, panels, the chat's `space_draft` card, the Make a space box ([docs/SPACES.md](docs/SPACES.md)) |
| `Bighelp/SimpleBots/` | The Bots view (`SimpleBotsHomeView`), sections, the bot page (`SimpleBotProfileView` and its tabs), creating a bot |
| `Bighelp/Chat/` | Chat screen, composer, `ChatModel` (+ `ChatModel+Submission`), the native chat timeline |
| `Bighelp/DirectHermes/` | The Hermes client: sign-in, WebSocket JSON-RPC, dashboard REST, plugin routes (`DirectHermesNativeContext.swift`), access credentials |
| `Bighelp/Workspace/` | `WorkspaceOperation` (every host operation) and workspace stores |
| `Bighelp/Settings/` | The one Settings tree (`SettingsView` and its `+Menu`, `+NerdMode`, `+Computers` pages: the groups, the Advanced options switch, Your computers) and `SettingsStore`; Models (`ModelsSettingsView`), Voice and Notifications pages. A computer's own page is `BighelpConfiguredHostView` in `Bighelp/Hosts/` |
| `Bighelp/Agents/`, `Board/`, `Companion/` | The bot directory and its editors, Feed/Ideas/Goals boards, the avatar kit renderer |
| `Bighelp/Kanban/` | Kanban on Hermes' Kanban plugin: board model, lanes, cards, Vision Pro window and pinch-drag |
| `Bighelp/Code/` | Coding sessions, started from New chat's choices row (project, new worktree or local, branch, mode, Stage) and listed on Work: `CodeHomeStore`, `CodeLauncher`, the pickers, Changes and Ship |
| `BighelpShare/`, `Bighelp/ShareShared/`, `Bighelp/Share/` | The share sheet (#922): the extension saves what's shared into the app group (`PendingShareInbox`, Foundation only and shared with the app), and the app's review puts it in the message box of the chat the person picks (`PendingShareCenter`, `ChatModel.placeShare`) |
| `Bighelp/Connectors/` | Settings › Apps & skills (`AppsHubView`; a bot's profile has its own Connections): Hermes' connectors as Native App Connections (the inline connect cards in chat, `connection.request`, `ConnectorCardStore`; `ConnectorAppsModel`) and Composio Apps (`Composio/`, [docs/COMPOSIO_APPS.md](docs/COMPOSIO_APPS.md)) |
| `Bighelp/HTMLApps/` | Agents' HTML apps: the `html_app` card, the full-screen page and its `window.bighelp` bridge, the plugin's `html-apps` routes, the demo's sample apps |
| `Bighelp/BotScreen/` | Bot Screen: an agent's Linux screen (Hermes `display.*`) and the computer's own desktop (`ComputerScreen.swift`, the plugin's VNC bridge) in its profile's Computer tab, a native RFB client (`RFB/`, with VNC passwords) and the full-screen viewer with take control and hand back |
| `Bighelp/Driving/` | An agent showing the person a place (`iphone_navigation`, #662): the place catalog and its playbooks (`DriveCatalog`), the navigator that plays one (`DriveNavigator`), and the overlay (island bar, chat dock) in its own window |
| `Bighelp/Usage/` | The Usage page (Settings' first group, the sidebar's More): plans and limits (`ProviderUsageStore`), Hermes' own analytics per agent and computer (`UsageStore`, `HostUsageLoader`), charts |
| `Bighelp/Voice/` | Turn-based and live voice; on-device voices (`OnDevice/`, Phonon in `Packages/PhononTTS`) |
| `Bighelp/Spatial/` | Vision Pro: the agent in the room (`SpatialAvatarModel`, its volume and voice panel, its Settings section) |
| `BighelpWatch/`, `BighelpWatchShared/`, `Bighelp/Watch/` | The Watch app, the Watch–iPhone wire (`WatchWire`), and the iPhone's `WatchRelay` that answers it |
| `Bighelp/CarPlay/` | CarPlay's hands-free voice chat (`CarPlayVoiceSession`) and its scene |
| `Bighelp/DesignSystem/` | `BighelpTheme`, `BighelpTokens`, glass surfaces, fonts, provider logos, `BighelpDeferredSection`, the lifter brand and its motions (`Lifter/`), the Thinking control and its looks (`ThinkingSlider/`) |
| `Bighelp/Hosts/`, `Bighelp/LiveActivity/`, `Bighelp/Notifications/`, `Bighelp/Shortcuts/` | Host setup, Live Activities, notifications, App Intents |
| `Bighelp/Telemetry/` | Usage and crash numbers (Settings › Help & feedback › Share usage and diagnostics): the client, MetricKit, the switch that also tells hosts |
| `BighelpTests/` (Swift Testing), `BighelpUITests/` (XCUITest) | Tests. The UI test base class `BighelpUITestCase` is in `ReferenceHubUITests.swift` |
| `BighelpVisionUITests/` | Vision Pro UI tests, run with the `BighelpVision` scheme |
| `Scripts/` | Real-host probes, logo export, CI helpers, Mac release |
| `services/` | Cloudflare Workers: the notification service (`link`, behind `link.loopdy.app`), the recovered relay and the provider logo site. Only the maintainer deploys them |
| `Design/AvatarKit/` | Source of the avatar characters (`tools/build.py`, `tools/export_native.py`) |
| `docs/` | Contracts and deep dives. Start with `ARCHITECTURE.md`, `NATIVE_TRANSPORT.md`, `DEVELOPMENT.md` |

`DESIGN.md` is the visual and navigation authority, and `PRODUCT.md` covers product direction.

## Build and test

- `project.yml` is the source of truth. Run `xcodegen generate` after adding, moving or removing files, and commit
  the regenerated `Bighelp.xcodeproj`. Never hand-edit the `.pbxproj`.
- The app needs Swift 6 and supports iOS 17 and later, and visionOS 26 and later. Keep Swift 6 concurrency
  correct.
- Unit tests use Swift Testing and UI tests use XCUITest. Run the smallest relevant suite while you iterate.
- **Demo mode:** `-use-demo-fixtures -disable-demo-delays` runs the app with sample data and no host. Fixture clients
  are in `Bighelp/App/AppFixtureClients.swift` and `AppFixtureSetup.swift`. New host features need a demo client too,
  so UI tests and screenshots work without a host.
- **Simulators and the shared Mac:**
  - Never run two `xcodebuild test` sessions on one simulator.
  - Give each worktree its own `-derivedDataPath`, and reuse it for every run there. A fresh one each run is a
    cold build.
  - Run heavy builds, tests and archives through `Scripts/with-build-lock.sh`, so only one runs on the machine
    at a time.
  - Use one simulator per session, and shut down the ones you booted when you stop.
  - Run long suites in the background so you can keep working.
- **Apple CI workflows are off by default.** Build, test and release on a Mac: a local one, or a remote one that
  you can reach. Use a GitHub workflow that builds, tests, signs or uploads an Apple app
  (`ios-ci.yml`, `testflight.yml`, `prepare-signing.yml`, or a new one like them) only when both are true: no Mac is
  available, and the user asked for the workflow in words. Otherwise never start, dispatch, re-run, enable or wait
  on one. "CI is disabled" or "the workflow returned 422" is not a gap to report. Report the local build and test
  results instead. `catalog.yml` and `telemetry.yml` build no Apple app and are not covered.
  - A contributor who has no Mac says so in the PR and lists what they could check. The maintainer then builds
    and tests the PR on a Mac before it merges. Don't dispatch a workflow to fill that gap unless the maintainer
    asks for it.
- **Known failures:** some tests fail on untouched `main` too, for example
  `DirectHermesVoiceMediaTests.nativePCMSilenceActuallySchedulesAndDrains` (simulator audio) and a few old UI tests.
  Check against `main` before calling something a regression.

### UI test traps

- `BighelpUITestCase.makeApp()` returns a `BighelpTestApplication`, which launches with Advanced options on
  (`-loopdy.settings.nerd-mode YES`), `-bighelp.home.migrated-v1 YES` (the one-time settings migration is past),
  `-loopdy.home.landing chats` (pin another place with `bots`, `chats`, `today` or `work`, and the first tab's view
  with `-bighelp.home.view bots|chats` under today or work), `-bighelp.hosts.all-hosts NO` (the computer in use
  only; a test of every computer opts in) and the bot page's swipe tutorial seen. Use its helpers:
  - `openRootTab` (the old shell's tab names, through the home's doors: Chats, Bots, a Today panel, a Work door,
    Settings; any other name fails)
  - `settingsRow`
  - `openChatInfo`
  - `chatNewChatButton` (leaves an open chat through its Back first, then returns the bar's `home.new-chat`)
  - `chatIdentity` (the pill in a chat's header) and `confirmNewChatPicker` (New chat opens with nobody
    picked; it picks a bot)
- The bar's ids are `home.tab.conversations|today|work` and `home.new-chat`; a chat's Back is `chat.back`.
- Launch arguments pin `@AppStorage` values for the whole run, and taps in the UI can't change them. A `NO` launch
  argument is a string, so read flags with `UserDefaults.bool(forKey:)`.
- `app.buttons["x"]` matches accessibility identifiers. SwiftUI menu items use their title as the identifier.
- An `.accessibilityIdentifier` on a container hides its children's identifiers unless the container also has
  `.accessibilityElement(children: .contain)`.
- Chat message text is a text view (`chat.message.inline-selection`). `staticTexts` queries never match it, so a
  "must not show" check written that way passes without testing anything.
- Uninstalling the app from the simulator clears microphone permission.
- Password prompts from iOS can appear late and cover the screen.

## Architecture intricacies

### Talking to Hermes

- **How chat connects:** chat is native Hermes only, over the dashboard's WebSocket JSON-RPC gateway. The plugin's
  routes sit under `/api/plugins/loopdy/native/…`. See [docs/NATIVE_TRANSPORT.md](docs/NATIVE_TRANSPORT.md).
- **Server requests handshake:** send `client.capabilities {server_requests: true}` on every socket, after the
  handlers are registered and again after each reconnect. Without it, Hermes answers clarify, approval, secret and
  sudo requests itself, with blanks, and the prompts never show. `advertiseServerRequests()` in
  `DirectHermesNetworking.swift` does this.
- **Session source:** every `session.create` and `session.resume` sends `source: "bighelp"`
  (`DirectHermesReleaseContract.sessionSource`). Hermes words the agent's instructions by it: left out, the chat
  counts as its terminal UI (no files, cards or reminders), and `"desktop"` promises Hermes Desktop's own tools.
  The plugin (2.20.0+) adds bighelp's brief for this source. The request filter in `DirectHermesWorkspaceClient`
  must list every field the app sends, or the app refuses the request itself.
- **Who is sending:** before each new turn, `DirectHermesChatSpeakerNote` posts `people/speaking` (plugin
  `native-people-v1`): the chat's stored session ID, a person ID from iCloud Keychain (`BighelpPersonID`, one per
  Apple ID) and the name the person saved. The plugin puts the name in the chat brief and, once a chat has had two
  people, a note on each message that only the model sees. Every new turn and queued message sends its own note,
  alongside the pre-send connection check, and only at Send: a note makes this person the chat's speaker at once,
  so opening a chat never sends one. A steer into the running turn sends none. A chat's first message waits for it (capped at 1.2 s; the plugin records the brief's person once), and
  so does any message until the host has taken a note naming this person, with the name they have now, in this
  stored session on this connection (`notedSpeaker`); later turns read the note when they reach the model, so they
  go at once. `UserIdentity.name` is empty until someone saves one; "You" is an on-screen placeholder
  (`displayName`) and must never be sent. Names are at most 40 characters.
- **A lost create never locks an agent out:** every `session.create` sends the creation record's `intentID` as
  `idempotency_key` (Hermes keeps it 5 minutes and answers a retry with the same session). An unfinished first Bot
  Chat retries under that key, or resumes the session Hermes made and asks for its title again; it never blocks
  New Chat (#440).
- **A turn stays pending while it streams:** after `prompt.submit` returns `streaming`, the chat isn't "ready for a
  new turn" until the turn ends. A mid-turn Send must go through the steer/queue path (`sendMidSession`). Steer is
  the default.
- **A reply's time comes from the phone until a reread:** Hermes' live events carry no time, and nothing reads
  the saved history after this device's own turn. A reply segment Hermes completes live takes the time it
  arrived (`DirectHermesProjection.accept(_:arrivedAt:)`); a replay takes none, since it ended at a time the
  phone doesn't know. A reread puts the host's saved time on the same row (#856).
- **Live voice is the agent:** each agent picks its provider (GPT-Live on the Codex
  subscription or an API key, or Gemini Live) and voice (`AgentVoiceChoices`). The plugin's brief names the
  agent, so the voice model speaks as it, never about "your agent". Gemini's media and events stay between the
  phone and Gemini (`GeminiLiveAudioPeer`, a single-use token from the plugin); its work still goes through the
  chat, and results go back as `UPDATE` text (docs/DIRECT_STREAMING_AND_LIVE_VOICE.md). Voice processing makes
  a configuration change right after the engine starts: every restart stops the player first
  (`GeminiLiveAudioPeer.restart`), or it takes Gemini's voice and plays none. A test that only counts bytes
  received can't see that; check what finished playing. The call audio report (`GeminiLiveAudioDiagnostics`,
  log category `LiveVoiceAudio`) shows where the sound stops on a device; Settings › Voice › Advanced (with Advanced options on)
  shows it on the call screen and has Restart sound. Gemini refuses a call by closing the socket with a code
  and its reason; the call screen shows Gemini's words (`GeminiLiveClose`), never a bare "Gemini ended the
  call" (#888).
  With plugin `native-voice-context-v1`, the offer also says who is talking and where
  (`LiveVoiceCallContext`): the agent's shown name, the person's saved name (never "You"), the time zone and,
  only while Device access › Location is usable, a coarse place (`LiveVoicePlace`: city, region, country from
  the last known fix under an hour old, else a city-level fresh fix; the offer waits about 1 s at most, raced
  with `DeviceLocationDeadline`, never a task group, which waits for every child). The brief keeps the phone's language until asked in words.
- **Voice waits for the chat:** live voice needs the chat's session on this connection, and a chat opened a
  moment ago (a cold Start voice chat, a tap right after opening) is still getting it. Every way of opening
  voice in a chat goes through `ChatDestinationView.openVoice`, which waits under the starting cover
  (`ShellFeatureStore.waitForLiveVoice`, 10 s at most) while the reason passes by itself
  (`LiveVoiceUnavailable.passesByItself`: connecting, chat opening). Asked at once, it showed "This chat is
  still opening" about a second before the call could start (#934).
- **Live voice multitasks:** requests from the voice model never wait for each other. One runs as a turn in
  the chat when it's free; one made while the chat works runs at once as a Hermes background task for it
  (`ChatModel.runNativeVoiceRequest`, `prompt.background`) and answers the call on its own. Background tasks
  can't reach the phone's tools.
- **On-device voices** (`Bighelp/Voice/OnDevice/`): Phonon speaks on the iPhone or iPad instead of the
  computer. It's chosen per agent in Voice settings and kept on the device (`OnDeviceVoiceChoices`, by computer
  and agent); the agent's `tts.*` on the computer never changes. `OnDeviceVoiceSettingsClient` adds it to the
  provider list, and `OnDeviceRoutedSpeechOutput` speaks with it in voice chats and Auto TTS once it's
  downloaded, else with the computer's voice. The model downloads when someone picks it, from a pinned release
  checked against its SHA-256 and its `bundle.json`; only Phonon 31m (Apache 2.0), never the CC BY-NC 40m
  models. Phonon needs iOS 18 or later: `Packages/PhononTTS` keeps the app's minimum and marks its API
  `@available`, so never raise the app's minimum for it. Its core has no visionOS or Intel slices, so only
  iPhone and iPad link it (the Mac DMG is universal).
- **Voice mode per agent** (`AgentVoiceChoices`): Live or Take turns, and the live voice, are kept per computer
  and agent on the device; Settings › Voice holds the default for agents without their own, and a bot page's
  Default Voice sets an agent's. Anything that opens voice for an agent reads its effective mode. Voices and
  models are picked from lists (`VoiceOptions`; ElevenLabs from the account, speech plugins from the plugin's
  `voice-catalog`), with a typed Other only where a provider takes any value.
- **Auto TTS** (`ChatReplyReader`): Settings › Voice › Read replies aloud. A chat reads a reply once its
  turn ends, never what it held when it opened, and stops on a new
  message, voice mode or leaving the chat.
- **Browser sign-ins stay signed in:** a Nous Portal sign-in's access token lasts 15 minutes and its refresh
  token rotates. The saved sign-in keeps its refresh token until a renewal succeeds; only a 401 from
  `/auth/native/refresh` ends it (`performRefresh`). Every other failure keeps it for the next try, as Hermes
  Desktop does: dropping it on a lost answer signed people out every day or so (#629). Before sending, the
  stored sign-in is checked, so a stale copy never sends a token another authenticator rotated. While the app
  is away, `BighelpSignInBackgroundRenewal` and the plugin's quiet push renew it.
- **Hermes reaps and prunes app sessions:** 20 s after an app's socket goes, Hermes reclaims the session's
  runtime and, for any source but `desktop`, ends its row (`ws_orphan_reap`); `sessions.auto_prune` then
  deletes ended chats idle past `retention_days`. Plugin 3.18.0 (`durable_sessions.py`) gives `bighelp`
  Desktop's treatment. In the app, a refresh never retires an open chat whose runtime ended: it resumes it
  (`onRetainedStreamsNeedResume`), and a chat route without its model reopens (`reopenChatRoute`).
- **Group chats come on two paths:** a `hermes serve` dashboard answers `groups.*` on the older path,
  v0.22.4's gateway listener on the session path; features, retry and discard, RoomLink and seatable
  profiles differ. Go by what `groups.capabilities` and each pending action say, never the version
  (docs/HERMES_BOT_MODE.md, vectors in `BighelpTests/Fixtures/HermesGroups`).
- **Group chats' settings:** where `groups.state` returns `context`, Group Settings (`GroupSettingsView`,
  `AppRoute.groupSettings`) sets who answers a message that names nobody, the purpose and shared notes through
  `groups.context`, each edit kept with the room under one `event_id` until Hermes answers. Hermes' picks
  (`room.assignment`, `room.routed`) and paused discussions (`room.activity` `bounded`, Continue through
  `groups.continue`) are lines in the chat, kept in `nativeNotices` (docs/HERMES_BOT_MODE.md › Group settings).
- **Hermes makes every Bot Chat:** Hermes delivers other agents' messages into the chat titled "Bot Chat" and
  takes over only its own native chat (`local-…`); a Bot Chat made over the app's socket (source `bighelp`) got
  renamed `Bot Chat (bighelp <id>)` and replaced, context and all, the first time another agent wrote. So the first
  Bot Chat and New Bot Chat's next one come from the plugin's `bot-chat/create` (`native-bot-chat-v1`), which has
  the agent's gateway make it; the socket's `session.create` is only the fallback for older plugins. Hermes stores
  these chats as `local` and the app's resume stamps `bighelp`: identity treats the two as one
  (`DirectHermesIdentity.sameSessionSource`). docs/DIRECT_HERMES_SESSIONS.md › Bot Chats are Hermes' own.
- **Bot Chats can be hidden in Hermes:** the app's used to be (Hermes' own are visible, and the catalog folds
  them into the Bot Chat), and `GET /api/sessions` never returns hidden ones; the catalog list adds each agent's
  (`canonical_session`, `canonicalBotChat`) so a refresh can't drop it. Hermes names it only when
  `profiles.list` asks for the agents' sessions (`include_sessions`, its default), so the catalog asks; without
  them every refresh dropped the saved Bot Chat, and the first tap on a bot waited on a full lookup.
- **Read state** (#862): Hermes' `last_read_at` is a watermark. A chat is unread once anything happens in it after
  that, the person's own messages too, and a chat no client ever marked counts as read. So the app marks a chat read
  each time it's read (`BighelpVisibleChats` → `ChatModel.noteRead` → `SessionCatalogStore.noteRead`): as it shows,
  2 s after a turn ends on screen, and as it stops showing or the app leaves the front. A chat that isn't on screen
  is never marked, and one read again with nothing new isn't marked twice. Rows without `unread` mean the host
  keeps none: Mark Read and Mark Unread hide (`SessionSummary.tracksUnread`). The Bots view shows Hermes' state where
  there is one, else the marks kept on the device (`SimpleBotsReadState`). The Chats list's Draft reads the draft
  journal without observing it (`ChatDraftJournal.pendingDraft`).
- **Archived:** the catalog lists `archived=include` and keeps rows Hermes' idle sweep archived
  (`auto_archived`); deliberately archived chats live in Archived Chats (`archivedChats`), with Restore and, the
  lists having none, Delete. Hermes refuses to delete a chat still open somewhere; the row says so in plain words.
- **Send never waits for the connection:** while a chat has no working connection (back from the background, a
  computer still connecting, a chat still opening or rereading what Hermes saved: `lacksConnection`), or a turn it
  just started isn't live yet, Send, the message box and Stop stay on. A message sent then waits at the bottom of
  the chat with "Sending…" under it (`stagedSends`, `ChatCanvasRow.staged`), outside the transcript: a recovery's
  readback would drop a local row as stale. Staged messages go out in order once the chat can take them, each as
  the row it waited in: a new turn, or a steer once the turn is live. The wait (`waitForConnection`) follows the
  chat's own state through Observation, the app coming and going, and the time left, never a polling timer, so
  whatever decides `takesMessageNow` must be observed (`pendingID` and `waiter` are). Send goes off only after
  25 s without a connection while the app is open (`connectionIsOverdue`, `ChatConnectionGrace`); staged messages
  then go back in the box. Commands (`/…`) and PDF pages still need the connection and wait in the box.
- **A message's connection check:** before `prompt.submit`, `prepareForAdmission` skips its `gateway.ping` only when
  the host sent something on that socket in the last 5 s (`admissionFreshness`). Coming back to the app or a
  network change (`verifyLiveness`) voids that until a ping sent after it is answered: frames from before can sit
  in a dead socket's buffer. A prompt sent on a socket that dies anyway is journaled as uncertain, never resent.
- **App state on the computer:** the Bots view's order, the sections, each group chat's section, pin and hide, the
  primary bot kept for Show every computer and each bot's voice, mark, pet and character are also kept for each
  person on their computers (plugin `native-app-state-v1`, keys `bots.layout` and `bots.settings`; `Bighelp/AppState/`), so a reinstall
  or another device gets them back. The stores stay where screens read them; `BotsAppStateSync` turns their
  changes into patches and puts the newest revision from every computer reached back in them. Items are named
  by the computer's own ID (`<computerId>/<profile>`), never by this phone's host ID or sign-in scope. A value
  lists the computers it covers: a computer reached for the first time gets this phone's part, and a value
  already there wins (a fresh install never sends empty choices). Keep JSON fields the app doesn't know. The
  plugin refuses only values shaped like credentials; links and IDs go as they are.
- **Who's working:** the Bots view, the Chats view, Today and Work show each agent's Bot Chat working or needing
  you from the plugin's `agents/activity` (`native-agents-activity-v1`): Hermes' turn leases in any process
  (the app, `message_agent`, `chat -q`) and the dashboard's open prompts, for up to 64 agents in one read.
  `BotChatActivityStore` reads it while one of those screens shows and the app is active (3 s while something
  works, 6 s idle), keyed by `cacheScopeID`; other gateways come from their all-hosts copies (`FleetBotChat`),
  only while fresh. Without the route it uses the Bot Chats the app knows to be running, and says nothing
  about updating. Never open or resume a chat to learn this.
- **Background work (#890):** an agent keeps working after it answers: subagents (`delegate_task`), background
  commands (`terminal(background=true)`) and scheduled tasks. With `native-agents-background-v1`, `agents/activity`
  rows carry `background` (how many run now, in any chat and any Hermes process, and the newest one's title);
  an idle bot then shows `BotChatActivity.background`, and a turn wins over it. The open chat reads Hermes' own
  `process.list` over its socket (`ChatBackgroundCommandsWatch`; `process.kill` stops one), and its "In the
  background" chip counts its subagents and running commands for everyone; a command's output shows with Advanced
  options on. A bot's Dashboard lists the last week's work by day as Activities from `agents/today`
  (`native-agents-today-v1`, `AgentTodayModel`), asked from the start of the phone's day six days ago (plugin
  3.47.0 takes 48 hours: then today and yesterday). Routines show only with ⋯ › Show routines. A tap opens the
  item's read-out from `agents/today/detail` (`native-agents-today-detail-v1`, `AgentTodayDetail`). In a chat, a
  helper's late `subagent.*` events update the row of the turn that started it (`subagentTurnIDs`), and a helper
  left running doesn't hold its finished turn open: the turn folds as Settings › Chat › Shows as says.
- **The share sheet only saves:** iOS supports `NSExtensionContext.open` only in Today and iMessage extensions,
  so the share sheet can't open bighelp, and it holds no sign-in. It copies the share into the app group whole or
  not at all (`PendingShareDraft`: a staging folder under a lock file, moved into place in one rename) and says to
  open bighelp. There `PendingShareReview` offers it, the person picks an agent and chat on the computer in use,
  and the chat takes it into its message box through the drop path (`ComposerAttachmentDrop.draftAttachment`);
  a new chat's share waits for the chat Hermes makes, never its local canvas (`PendingShareDestination.isTaken`).
  Send works as for anything typed there. From the box on, each chat's `PendingShareLedger` owns its shares: a
  message that leaves the box carrying one gets its own id, and only an outcome naming that message moves it on
  (dispatched, admitted, definitely refused, unknown, back in the box, retired). Its step to sending is saved
  before the message goes (`dispatchShares`); if it can't be, the message goes back in the box unsent. The native
  client binds that id to its own journal entry for the message (`PendingShareCorrelation`, recorded in
  `recordSubmission`) and admits only that entry. Admission marks the share spent on disk before deleting it, so
  it's never listed again even if the deletion has to wait. A send that definitely failed puts the message back in
  the box with its share (never Try again or an automatic branch, which would send it without one); an unanswered
  one keeps its id, so its history (a reference's receipt) still settles it, after a relaunch too. A chat opened
  again after a relaunch takes back, before any Send, each share of words only placed in it that no message took
  and whose words its restored draft still holds (`restoreSharesInBox`, from the share's own saved placement). A
  share with files waits in the list: its words alone would spend files never sent, and Open brings them all
  back, even into a box that has its words already (`PendingShareIntake` places the opened share first). The person
  taking a share's last file or words out of the box lets it go, kept and listed. The saved copy goes only when
  Hermes takes the message carrying it, or when the person deletes it in the list of waiting shares (Today's Shared with bighelp card, Settings' first
  screen or the sidebar's More), never by itself. `PendingShareInboxTests`, `PendingShareLedgerTests`
  and `PendingShareWaitTests` run under any Swift (no UIKit); `PendingShareComposerTests` drive the chat.
- **Plugin routes:**
  - Each route is a `WorkspaceOperation` case plus a `Route(path:feature:isMutation:maximumResponseBytes:)` in
    `DirectHermesNativeContext.swift`.
  - The route only runs when `/native/context` lists its feature. Otherwise it fails as unsupported, and the UI
    should say "update the plugin", never show a raw error.
  - Requests send `If-Match` (the context ETag) and `X-Loopdy-Request-ID`, which must be a lowercase UUID.
  - Context reads send `X-Bighelp-Features: all` (`DirectHermesHTTP.featureListHeader`): plugins list at most 64
    features to apps without it, because older releases refuse a longer list. The app takes up to 256.
  - On a `conflict` (context changed), reload the context and retry once.
- **Plugin releases (no pin):**
  - The app installs and offers the plugin's latest GitHub Release (`Bighelp/Hosts/PluginLatestRelease.swift`).
    Plugin releases are batched: the maintainer ships a release PR and starts the plugin's Release workflow.
    A plugin update never needs an app build.
  - It looks up the release's exact commit, installs it, reads it back, and never replaces a newer or equal
    plugin. An install that may still be running on the host is finished with the commit it asked for.
  - When the app needs a newer plugin feature, gate it on `/native/context` and say "update the plugin".
  - A plugin installed, turned on or updated takes effect only after two restarts: the Hermes dashboard
    (`hermes dashboard` or `hermes serve`, which serves the app's connection and the plugin's routes) and the
    messaging gateway (its own copy: reply alerts, other agents' messages). "Installed and enabled" reads the
    plugin list on disk, not what runs. Every place that installs it asks to restart both
    (`PluginRestartPrompt`), and a computer's page has Restart Hermes Dashboard beside the messaging gateway's. Hermes
    can't restart the dashboard for an app, so the plugin running in it does (`native-host-restart-v1`);
    before the dashboard has loaded the plugin, only the computer can. After an install or a restart,
    `BighelpHostRegistry.noteServicesChanged` has the runtime read the computer again (`reloadAfterHostChange`).
    Live voice that can't start says why (`LiveVoiceUnavailable`), never only "not supported".
  - Test the app against the plugin's `main` on the Mac, not through a CI workflow.
- **Agents talking to each other:** the app reads them from the tool calls Hermes recorded (`AgentTalkCall`:
  `hermes -p <agent> chat -q`, `hermes peer dm`, `message_agent`) and from the messages other agents send in
  (`AgentTalkIncomingMessage`, `AgentTalkDelivery`), never from prose. The plugin's `agents/talk` route reads the
  other agent's own history read-only and matches runs by a SHA-256 of the message (`AgentTalkMessageHash`, same
  normalization on both sides). Each Hermes agent loads only its own plugins, and usually only the default agent
  has bighelp's, so nothing that must reach every agent can be a plugin prompt section: Teamwork writes each
  agent's `platform_hints.bighelp.append` instead.
  Hermes 0.23 runs `message_agent` through the other agent's gateway: the call returns a `delivery_id`, a
  background waiter (`bot_mode_dm.py --run-delivery`) gives up after about 30 minutes, and the agent asked keeps a
  receipt. So the rail reads where each message is from the plugin's `agents/deliveries`
  (`native-agent-deliveries-v1`, `AgentDelivery`), never the waiter's notice (`isStillOut`), and the waiter is no
  background command. Tapped, a delivered message's rail opens in place (`ChatAgentTalkRunPanel`): the agent's
  steps from the plugin's `chat/live` (`native-chat-live-v1`, which relays the gateway's own frames), then its
  answer. The agent's own chat draws a turn its gateway runs as its own (`followGatewayTurn`): from now, since
  saved steps carry no call ID to match a replay against, ended by `running: false` as any turn this device didn't
  send, and Stop goes to `chat/stop`. Hermes saves the delivered message as an `internal_notification`; one that
  is another agent's message shows (`DirectHermesHistoryRow.isVisible`).
- **Files agents send** (`MEDIA:` lines, generated pictures): the plugin's `attachments/resolve` + `attachments/fetch`
  routes serve them in ~3 MB pieces. After the first piece the rest download three at a time, and a dropped piece is
  asked for again from its offset. Finished files are kept on the phone (`AgentAttachmentCache`, Caches, 512 MB, least
  recently opened go first), so a reopened chat shows them at once. Until a file lands, its message shows a loading
  tile (`PendingAgentFilesView`), never the raw line. A reply read from the saved history (back after time away, a
  reread) asks for its files too: every such read ends in `reconcileHydratedSession`, which starts
  `scheduleMessageMedia`, and that reads the rows on screen, not only the live projection's (#665). Hosted image tools (Nous Portal, FAL) report the picture's
  https address instead of a host file; the card reads it from there (public hosts only, no cookies, bounded).
  A loading tile always ends. After its tries (`mediaRetryDelays`), the message shows why in plain words with Try
  again (`AgentFileFailure` on `TimelineMetadata.fileFailure`, kept through rereads by `ChatModel.agentFileFailures`).
  The plugin says why a file didn't come (`unavailable`: missing, refused, too large); with no plugin route, a file
  outside Hermes' caches says to update the plugin. A recovery on the same connection leaves the tries alone: it
  once reset them, and a chat that recovered often kept a failing file loading for good. A new connection or a
  client attached to the chat starts the tries again for every reason but too big; a turn that ends does for
  refused (a reply Hermes hadn't saved yet). A tile with nothing finishing it shows Try again after
  `AgentFileLoad.stallAfter` anyway. The `ChatFiles` log has each try's reason.
- **Big files people send** (over `ChatAttachment.maximumBytes`, 8 MiB, up to 256 MiB; plugin `native-uploads-v1`,
  bighelp-plugin's docs/BIG_FILES.md): Hermes' `file.attach` takes a file in one socket frame, so bigger files go
  to the plugin's `uploads/*` routes in 4 MiB pieces instead (`BigFileUploader`), in any order, from a background
  `URLSession` (`BighelpBackgroundUploads`) that iOS keeps sending while the app is away. The host records a piece
  only once all of it arrived; after a drop the app asks `status` and sends only the rest, and starting the same
  file again gets the same upload back. A proxy in front of Hermes that refuses a piece (`413`; aiohttp and nginx
  take 1 MB a request by default) gets the file again at once in 512 KiB pieces (`chunkBytes`, plugin
  `native-uploads-small-pieces-v1`), never a quiet retry; an older plugin says to update it. The app keeps its own
  copy on disk (`ChatBigFile`, `BigFileStore`, a `.bigFile` draft) and never holds the whole file in memory.
  `finish` checks the SHA-256 and moves the file into the agent's working folder (`uploads/<date>/<name>`, what
  its Files tab shows); stock `file.attach` then takes it by `path` and tells the agent its type, size and place
  on disk, never its bytes. The app's `[Video attached: … (size, length, picture)]` or `[File attached: … (size)]`
  note follows each `@file:` line. One look per file (#721): while it goes up, a tile with a ring and "34 of 80
  MB" (`BigFileUploadTile`, progress in `BigFileUploadBoard` so only the ring redraws), or why it didn't go with
  Try again and Remove; once Hermes takes the message (`onSubmissionAdmitted`, by journal entry), the row takes
  the sent text and shows each file as a line on the rail (`ChatSentFileLine`), exactly what a reread rebuilds. A
  prompt that went with no answer back looks the same, says delivery is unconfirmed and has no Try again
  (`UnconfirmedSend`). A host path or
  `@file:` ref never shows as text; a tap opens the bot's Files on the file (`BotProfileOpening.file`,
  `SimpleBotFilesModel.reveal`), a long press shows the path. Hosts without the feature keep the 8 MiB limit and
  say to update the plugin.
- **Plugins and Hermes' marketplace:** the host's catalog route has no stars, featured picks or dates. The plugin's
  `marketplace/plugins` (`native-marketplace-v1`) reads them from Hermes' marketplace feed and adds Hermes' own
  install check (`installRefusal`), so Install goes off without the app comparing versions. The featured pick
  turns weekly exactly as Hermes' `featuredPicks` does (`PluginStorefront.featuredPicks`), so bighelp, the website
  and Hermes Desktop feature the same plugin. An update can stop and ask (`consent_required`, a caution
  `scan_blocked`): that's a `PluginUpdateQuestion`, never an error, and each retry sends every yes so far. A
  refused plugin change's 400 `detail` shows as Hermes' words (`DirectHermesHTTP.pluginChangeRefusal`).
- **Each agent's own files:** the plugin's `workspace-files/*` routes take an optional `profile` (plugin 3.20.0,
  `native-workspace-files-agents-v1`) and read that agent's working folder with the same refusals. A bot's Files
  tab sends its ID (`DirectHermesManagedFilesClient(agentID:)`); the serving agent never names itself, so older
  plugins keep working for it, and other bots say to update the plugin.
- **Deleting an agent can lose its answer** (#949): Hermes stops an agent's own processes before it removes
  it, which can take ten seconds, and the app's connection can change in that time. The lifecycle steps then
  stop with "the host or connection changed" although the agent is gone. `AgentDeletionRecovery` waits for the
  same computer and reads its agent list: gone is a success, still there is the error. After any deletion
  `closeScreens(ofDeletedAgent:)` closes the agent's editor, profile and chats, and a bot's profile closes itself
  once its bot is gone from a list the computer sent (`knowsProfiles`), so nobody is left on a page for an agent
  that isn't there. The demo's list deletes too (`AgentDirectoryDeleting`).
- **A chat's Files** (••• › Files, `ChatFolderBrowserView`, #944): the chat's working folder on the computer
  as a tree, with a path field for any other folder. The folder is the session's own (`cwd`, from
  `NativeWorkspaceSessionBridge.sessionFolder`), else Hermes' `/api/fs/default-cwd`, else home. Everything is
  Hermes' own `/api/fs/*` as the chat's agent (`LiveHostFolders`), so it needs no plugin: `list` gives only
  names, paths and which are folders; a picture comes whole from `read-data-url`, which has its own response
  limit (`DirectHermesHTTP.responseLimit`). A group chat lists the files in its messages instead
  (`ChatSessionFilesView`). Demo: `DemoHostFolders`.
- **Phone tools** (Settings › Apps & skills › Device access; contract in
  [docs/IPHONE_DEVICE_TOOLS.md](docs/IPHONE_DEVICE_TOOLS.md)): an agent's `iphone_*` call reaches the phone over the
  chat's device-tool channel. `DeviceToolCatalog` lists every operation and which are journaled; each capability with
  its own iOS permission is a `DeviceCapabilityTool` that `DeviceToolRouter` checks before it runs. A new one needs a
  catalog entry, a tool, a plugin feature (`native-device-<kind>-v1`) and the contract text. Every switch starts off
  and then stays on until the person turns it off: one list for the phone, every host and agent
  (`DeviceToolPermissions.grantsKey`); iOS saying no pauses a tool (`isUsable`), never turns its switch off. An agent's
  call to one that's off shows a connect card in the chat (`DeviceAccessCardStore`, plugin
  `native-device-permission-request-v1`): its Turn on flips the same switch, without reopening the channel
  that carried the call, and the call goes on. Apple Health is read only and asks once about sharing first. The
  channel runs while bighelp is active, inactive or in the background grace, and in any agent's chat on a plugin with
  `native-device-tools-agents-v1`; after the grace it closes as `paused` so the host waits for the phone. It
  belongs to the chat opened last (`AppState.deviceToolConversationID`), also after Back to a list while its bot
  still works; `activeConversationID` is only the chat still on the stack.
  A channel the host ended (its 30 s lease ran out while a slow tool ran, the plugin unloaded or started again, a
  lost connection) opens again by itself while the chat keeps its tools, with longer waits each time and a limit
  (`runReopeningWhileHeld`, `reopenWaits`); a late answer the host no longer takes loses only that answer, never
  the channel. Before, any of these left the chat without phone tools until the person left it (#861).
  Two reach past the open chat: Arriving and leaving sends its message from the background (`DeviceGeofenceMonitor`),
  and a Shortcuts run keeps the call alive while Shortcuts is in front (`DeviceToolHandoff`).
- **Agents show the way** (`iphone_navigation`, `Bighelp/Driving/`): a place in `DriveCatalog` is only one the
  navigator can reach for real: a route, a tab, a bot profile tab or sheet (`BotProfileOpening`), or a Settings page
  (`AppState.openSettings(at:)`, `SettingsDestination`). A place that opens only from a view's own `@State` needs a
  way in first. A control a playbook taps or points at carries `.driveTarget(id)` (usually its accessibility id);
  its page carries `.driveScrolls()` when the control can be off screen. A drive never changes a setting.
- **Photo actions** ([docs/IMAGE_DRAFTS.md](docs/IMAGE_DRAFTS.md), plugin `native-image-drafts-v1`): a contact or
  event read from a picture is a `contact_draft` or `event_draft` card, never a write. Only the review's Save writes
  (`ImageDraftStore`): it claims the draft on the host, journals the write (`DeviceToolFileJournal`) and reads it back,
  so a second tap or a relaunch never writes twice; without access it opens Apple's own editor, whose Done is the
  Save. In a chat that holds the person's picture the phone answers `contacts.create` and `calendar.create` with
  `review_required`. Each agent's Photo actions page is in What it can use on a bot's profile.
- **Agents' apps** ([docs/HTML_APPS.md](docs/HTML_APPS.md), plugin `native-html-apps-v1`): an agent's HTML app is an
  `html_app` card (title, description, Open App); the chat never draws the HTML. Open App loads the page from its own
  `bighelp-app://<app id>/` origin in a full-screen web view (`HTMLAppWebView`) and renders it as made: any site or
  library loads, while the camera and microphone are refused. Only a link the person taps, to an `http` or `https`
  address, opens outside; every other way off the page is dropped (`HTMLAppNavigationPolicy`: a script's own
  navigation or `window.open`, and every other scheme, bighelp's own links included). Its only way to
  the app is `window.bighelp` (`HTMLAppBridge`): data the plugin serves (read every 5 s while a live app is open) and
  `sendAnswer`, which shows the exact message and sends only on the person's Send, as their next message.
- **Spaces** ([docs/SPACES.md](docs/SPACES.md), plugin `native-spaces-v1`): a space is a live panel on Today. A bot
  drafts it in a chat as a `space_draft` card (`SpaceDraftCardView`); only the person's Add to Today makes it a space,
  and a routine on the computer then keeps it current. Each computer has one `SpacesStore`, kept by its cache scope
  (`WorkspaceAuthority.cacheScopeID`), so a reconnect keeps it. `TodaySpacesModel` reads them all: the computer in
  use and the ones Show every computer keeps connected live, the rest from the phone's copy. A read sends the card
  hashes the phone has (`known`), so the computer leaves unchanged cards out. A space's size, hiding and place belong
  to its computer (`TodayPanelLayoutStore.ownedChanges` → `SpacesTodayBridge`): a change shows at once
  (`SpacesStore.stage`) and goes with `update`. One still waiting for its answer repeats with the same
  `operationId`; a change on top of it gets a new one, because the plugin refuses an `operationId` it saw with
  another body. A delete the computer hasn't finished stays off Today and repeats at each read, across launches.
  Only the plugin's own context says the feature is missing ("Update the plugin"); a refused route during a
  reconnect never does. A space's page opens in `HTMLAppScreen` on its own computer and never sends a message,
  whatever the plugin says the page may do. Changes to one space go one at a time (`SpacesStore.send`), so the
  computer ends on the last choice. A read asks about every bot the phone holds spaces for, and only the computer
  saying a bot is gone takes its spaces off: a bot list that is short for a moment never does. Removing a computer
  erases its spaces from the phone (`TodaySpacesModel.forget`). A bot's title and description are cut to the wire
  maximums as they are read.
- **Hermes versions never gate connections or features.** Older, newer, custom and absent version strings are
  metadata, not an allowlist. Check actual host capabilities and route responses instead.
  - Hosts differ, so parse leniently: ignore unknown keys and treat most parts as optional.
  - A missing part should hide one row, not break a screen.

### Coding sessions

A coding session starts from New chat (one bot, a project picked in its choices row) and lists on Work. There is no
Code mode.

- Each Send of one runs `CodeLauncher`: the host's stock git makes the worktree (`/api/git/worktree/add` through
  `StockGitManaging` prepare/execute) or switches the local branch, then `session.create` starts the session in
  exactly that folder with a title (`createSession(agentID:folder:title:)`, no fallback folder), then the first
  message goes out the way Shortcuts sends (`submitWithoutWaiting`). Nothing opens, so sends can go back to back.
- Git may act in a project's linked worktrees only when the main folder's latest snapshot lists them
  (`DirectHermesStockGitClient.isProjectWorktree`). No other path is ever a target.
- Hermes puts worktrees in `<repo>/.worktrees/`, which the main checkout sees as an untracked folder (git names
  it `.worktrees/`, trailing slash and all). Changes and Ship leave it out, so a commit never takes the worktrees.
- The model chip (model, reasoning, fast mode) rides in `session.create` (`model`, `provider`, `reasoning_effort`,
  `fast`), so even the first message runs on it; the app checks the session reports that model. A brand-new
  session's own controls can't change it yet (Hermes hasn't built the agent before its first turn).
- Back-to-back sends make their folders and sessions one at a time (`CodeHomeStore.setupTail`): Hermes starts one
  new chat per agent at a time, and each worktree changes the repository the next send reads. Sending and the
  agents' work still run side by side.
- Hermes doesn't remove a worktree when its session ends; Worktrees does (a project's ⋯ on Work, and New chat's
  choices row). Its `create-pr` route takes no title or description (they come from the commits); "Ask the
  agent to open it" sends the session a message.
- Work's coding rows show only what the live chat, the session list or the Dashboard's waiting list says
  (`CodeChatStatusReader`): waiting prompts are "Needs you", also for a session whose chat isn't open, and running
  work shows its tool. Demo mode uses `DemoCodeProjectSource` and `DemoCodeGit`.
- The mode chip (`CodeSessionMode`) uses Hermes' own options: Plan sends the first message as `/plan …` (Hermes
  writes `.hermes/plans/<date>-<slug>.md` and changes no code); YOLO sets the session's `yolo` config (session
  scope, `setYOLO`) before the first message. A refused YOLO sends nothing and says so (`CodeStartError.yoloRefused`).
- A first message that starts with `/` takes the chat's own send path, which runs it as a command (`/plan` expands
  to its planning prompt there); `submitWithoutWaiting` (`prompt.submit`) would send it as plain text. The `/` list
  loads before the session exists: `commands.catalog` with `profile` and `cwd`, no `session_id`.
- Markdown files open in `MarkdownFileSheet` through Hermes' `/api/fs/read-text` and `/api/fs/write-text`
  (`HostTextFileAccess`; demo: `DemoHostTextFiles`). Save re-reads first and never overwrites a file that changed
  without asking. IDE chats link Markdown paths (`HostFileLink`, `opensHostFiles`) against the session's folder.
- Stage (the last chip of New chat's choices row) keeps a job with its chips (`CodeStagedJob`, saved per
  computer), and Send all starts the staged jobs as one `CodeBatch` through the same one-at-a-time setup. The app combines the batch's
  sessions (`CodeBatchChatView`): a message goes to each through `sendCardReply` (it steers a running turn), and
  each session's answer shows under the message by time. `#` mentions route (`CodeBatchRouting`): a session
  mention picks it and drops out of the text; a pull request mention is spelled out with its branch and goes
  to the session on that branch.
- Dev Factory (a project's ⋯ on Work) is Workflows with `schemaVersion: 3` recipes (plugin `native-workflows-code-v1`,
  contract in bighelp-plugin's docs/DEV_FACTORY.md; vectors in `BighelpTests/Fixtures/Workflows/*-code.json`).
  A recipe lists git projects; `startCodeRun` makes one run per project under a `group_id`, each in its own
  worktree. New stage kinds `command` and `pullRequest`, and sign-off on the changes (`signsChanges`,
  approved with `changesSignoff.sha256`). Recipes and their runs show only in Dev Factory: `WorkflowsStore`
  leaves them out. "Look at changes" opens the IDE's Changes screen on the run's worktree, without Ship.

### SwiftUI traps we've hit

- **Environment doesn't reach pushed screens:** values set on `RootShellView` or the NavigationStack root don't
  reach pushed screens (chats from `navigationDestination`, Settings `NavigationLink`s). Pass them at the push site.
- **Root `.task(id:)` pauses:** it doesn't restart while a chat covers the root. Connection upkeep lives in
  `WorkspaceConnectionKeeper`, injected per chat route.
- **`@ObservationIgnored` never refreshes views:** if a menu depends on something like "is a client configured",
  expose an observed flag.
- **A `.sheet` on `EmptyView()` never presents:** hang sheets on
  `Color.clear.allowsHitTesting(false).accessibilityHidden(true)`.
- **Presentation order:** close a popover before presenting a full-screen cover from it.
- **Glass button taps:** glass buttons need `.contentShape` before `bighelpNavigationGlass`, or taps miss.
- **UIKit factory initializers skip Swift properties:** `UITextView(usingTextLayoutManager:)` makes a subclass
  through an initializer Swift doesn't override, so the subclass's stored properties are never set and the first
  read of one crashes (#727). A subclass with stored properties needs a designated initializer of its own
  (`LongTextView(usesTextKit2:)`).
- **Overlays that swallow taps:** full-screen `UIView` helpers in overlays need `isUserInteractionEnabled = false`,
  or they swallow every tap.
- **Chat row environment:** chat rows (`NativeChatTimeline`) copy selected environment values into each row as it's
  built, and a change to them builds every row again. Values that change without changing a row's look (the scene
  phase, card actions) reach rows live instead (`ChatRowLiveValues`): copied, each return to the app built every row
  again and the first scroll up dropped frames. If a row acts stale (for example, animations frozen because it still
  thinks the app is inactive), check what the timeline copies or hands live and whether the representable reads it.
- **Chat redraw cost:** `ChatView` redraws for the keyboard, the message box, the header and each streaming
  delta. Its transcript rows live in `ChatTranscriptCanvasCache`: built again only when something in its key
  changes, and then only for the turns that changed (`ChatTranscriptTurn`; a tool event redoes just the turns
  whose ledger events it touches). A new input to the rows goes in that key, and a new step works a turn at a
  time or falls back to the whole chat, as agent talk does. `ChatLongHistoryTests` checks the kept rows match
  `wholeCanvas`. Checks that run over every message must stay cheap: Foundation's `contains` on message text
  was most of a 1,000-turn redraw (`ChatTextMarker`), and a link card PNG-encoded its picture in its body.
  Never walk the ledger once per turn (`ChatLedgerIndex`) or insert into it one event at a time when building
  it (`ChatActivityLedger.init`). XCUITest queries build every row of a long chat (seconds, over 1 GB at
  300 turns), so time one with `ChatLoadSpeedUITests` (`BIGHELP_SPEED`, `BIGHELP_SPEED_TURNS`) or the DEBUG
  autopilot and probe (`ChatPerformanceAutopilot`, `-test-chat-performance-probe`). The probe's `send_to_answer`
  times each message from Send to its answer's first words on screen (`ChatSendTimings`, local only); the
  autopilot's `send` with `BIGHELP_PERF_SENDS` and demo mode's `-test-first-answer` measure it. `-test-long-chat-heavy`
  (`BIGHELP_SPEED_HEAVY`) makes every turn as big as a chat near half a million tokens. Work done for each
  message as it's drawn must not grow with its text beyond the drawing itself: `MarkdownDocument`'s plain
  text is worked out only when read. The probe's `main_busy_ms` counts main run loop turns over 8.3 ms, a
  dropped frame at 120 Hz; the simulator's frame gaps can't show that.
- **Message box redraws:** `ChatComposer` is `Equatable` and calls back through one `ChatComposerActions`
  that `ChatComposerHost` keeps up to date, so the chat's redraws (each streamed piece of an answer) don't
  redraw the box. A new input that changes how the box looks goes in its `==`. Never keep closures that
  capture a view in an object in that view's own `@State`: the state then keeps the view, and its chat, alive. Send, the placeholder and the mention list
  read `ChatModel.draftShape`, never the draft, so most keys redraw only the text view. A pause in typing
  saves the draft to `ChatDraftJournal`, not the chat list; the chat takes it at its next save
  (`ChatComposerRedrawTests`, `ChatDraftJournalTests`). `ChatDestinationView` must not read the chat's
  messages in its body: then every streamed piece redrew it, and its new `openURL` action updated every
  UIKit view under it, the box's text view too. Read them in a modifier of their own
  (`ProjectChangesRefreshTrigger`). `@Observable` skips a set to an equal value, but an in-place
  change (`removeAll`, `append`, `&+=`) always notifies, even when it changes nothing.
- **New chat's sweep** (`ChatDissolveTransition`): the old chat goes line by line, bottom up, as the Thinking
  look the person picked (`BighelpThinkingLook.selected`) rises through it; the new chat is live underneath.
  The look runs in a view of its own on the window, outside any scene, so `ChatDissolveLookBand` hands it the
  appearance and an active scene phase (without them it draws light, and stands still). New Bot Chat uses
  the same blank canvas and sweep as New chat (`NewChatCoordinator.start(creating:)`).
- **Streaming under a drag:** Hermes sends an answer a few words at a time, and each piece lays the whole answer
  out again, so each timeline update waits 50 ms after the last one's layout, and while the reader drags or the chat
  decelerates (`NativeChatTimeline` `applyPendingUpdate`, `isScrolling`); otherwise a drag got a few touch
  updates a second. Only a turn's first readable words skip the 50 ms, once a turn, while the reader follows
  the newest message and isn't touching the chat (`takesFirstAnswer`). Rows resize without UIKit's 0.3 s self-sizing animation, which piled up and bounced a
  streaming answer. To reproduce by hand, run demo mode with `-test-tool-stream -test-tool-stream-fast-tail`
  and drag while the answer streams at a model's pace; the other fixtures are slower and pause during
  gestures, so they never showed this.
- **A streamed piece costs its own size:** each piece of an answer comes as the whole answer again, so
  anything done per piece must not grow with the answer. Three things did, and made long answers drop frames:
  - SwiftUI proposes several widths while it sizes a row, and `UITextView.sizeThatFits` lays the whole text out
    again on every call. A message on screen is measured through layouts of its own on the same text, one per
    width (`ChatNativeMarkdownSideLayouts`), so each lays out only what was added; they're dropped once the text
    is still. Never measure through the text view's own container: it is only as tall as the view, so a growing
    answer's bubble stopped growing.
  - `ChatNativeMarkdownRenderCache` keeps the blocks before the first one that changed and tells the text view
    where the change starts (`unchangedPrefix`), so finished paragraphs aren't built or compared again.
  - Nothing in a bubble's `body` may read the whole text: Copy's text (`ChatBubbleInteraction.copyText`) and
    VoiceOver's label (`ChatMessageTextHost.accessibilityLabelSource`) are made when asked for.
  Measure with `-test-tool-stream -test-tool-stream-fast-tail` at the bottom of a `-test-long-chat`, and read the
  probe's `text.layout.*`, `message.parse` and `main_busy_ms`.
- **A real computer sends about thirty events a second:** demo mode doesn't run the code a real host's events
  go through, so measure a real answer too (the probe's `send` with `BIGHELP_PERF_SEND_TEXTS`). Work done for
  each event must not grow with the number of chats, and nothing every message reads as it draws may change
  with each event:
  - A message's reactions read `ChatModel.reactionRowItemIDs`, never `items`: `items` changes with every piece,
    and reading it drew every message on screen again each time. `replaceItem` writes the indexes only when
    the ID changed, because a write to an observed property tells its readers even when it changes nothing.
  - A chat's runtime liveness is reconciled only when it changes, the chat list keeps its records until the
    catalog's `presentedRevision` moves, and a notification event asks for its observer before it reads the
    Keychain.
  - Values read many times a draw are worked out once: `WorkspaceAuthority.cacheScopeID`, the theme
    (`BighelpTheme.resolve`), the model summary's reasoning options.
  - A reply that lands is saved with `SessionCatalogStore.checkpointNow()`, which encodes off the main thread;
    `flushPersistence` is for leaving the app or the chat.
- **A computer can list thousands of chats:** one that runs scheduled tasks lists a chat for each run (6,900 on
  the host behind #996). Nothing done at a save, a list read or a draw may cost a file, or a walk of the list, for
  each chat. Measure with that many (`SessionCatalogLargeWorkspaceTests`, a seeded host):
  - A save writes only what changed. Chats with nothing in them share one content revision
    (`SessionContentRepository.emptyContentRevision`), and a loaded chat is known unchanged from what the last
    save wrote for it, not from the six-entry cache. On the first run after an install every chat is loaded and
    empty: each save once wrote a file for each, on the main thread, until the watchdog ended the app.
  - The list of chats is one file, written whole. Automatic saves wait in step with its size
    (`SessionCatalogStore.checkpointDelay`), and a list read rests in step with how long the last one took
    (`NativeWorkspaceInvalidationCoordinator.sessionsRefreshRestFactor`). A send, a reply that lands and leaving
    the app save at once.
  - `recentSummaries` is kept until the records change; many screens read it as they draw.
- **Kept chat rows:** a message row costs more than a 120 Hz frame to build, so the timeline keeps the 40 built
  rows nearest the screen by ID (`ChatTimelineBuiltRows`), never recycles a cell for another row, and builds the
  24 rows above while the chat is still. Cells host SwiftUI as a plain subview (`ChatTimelineCell`), not as their
  `contentConfiguration`: UIKit tells configured content it's hidden for reuse whenever a row goes by, and SwiftUI
  then made the row's text views again when it came back. A row built ahead is built in the table itself, out
  of sight, before it waits in `parking`: first built anywhere else, its views were made again when it showed.
  A kept row is drawn again only when its row value or
  its part of `ChatCanvasRowContext` (grouping, density) changes, so anything else a row takes from `ChatView`
  belongs in that context. Rows off screen hold their loaders still (`bighelpLoaderMotionOverride`). SwiftUI
  updates a hosted row on its own renderer thread while the row animates, so a closure it calls there (an
  environment transform) must not be made on the main actor: it traps (`hostedEnvironment(from:)`).
- **A spacer takes half the room:** in a `VStack`, a `Spacer` and a view with a height range share the free
  height equally. The chat's Skills and commands list got half the room over the message box and showed two
  rows; the list's container takes `layoutPriority(1)` while it shows (`ChatView`).
- **White pages in dark mode:** a page that stays white (the Drawing sheet) draws its own buttons in fixed
  colors and pins `PKToolPicker` to the light style. A navigation bar's buttons follow the app's appearance.
- **Type-checker timeouts:** very large `body`s (`RootShellView`, `BighelpApp`) time out the type checker. Pull
  pieces out into functions or named `ViewModifier`s.
- **Text styling:** styled text in the composer must pass attributes and theme colors. Plain `String` replacements
  lose them.
- **Covers from list headers:** a `.fullScreenCover` hung on a button in a `Form` section header shows, but its text
  editor never gets the keyboard. Keep the button in the header and present from the form's root
  (`focusedTextEditor(isPresented:…)`).
- **Stale incremental builds:** after changing what a `some View` property returns in one file, a Debug build can
  crash in another file that uses it (`EXC_BAD_ACCESS` in `ViewBuilder.buildExpression`, two-frame stack). Touch
  the files that use it and rebuild before chasing it.
- **Live properties read outside `body`:** calling another view's computed property (a section of
  `SettingsView`, say) from elsewhere reads its `@Environment` and `@BighelpThemeReader` with their defaults,
  the light theme, so a page built that way drew white rows and light-mode grays at night. Build such a page
  in the view's own `body`.
- **Light and Dark on open sheets:** `.preferredColorScheme` gives a sheet its style when it opens and doesn't
  change it after, so a switch in Settings left the open sheet's text fields and pickers in the old style.
  `BighelpWindowAppearance` sets every window and presented controller, and each `bighelpSheet` and
  `bighelpFullScreenCover` applies it as it opens.
- **Text size on sheets:** iOS starts a sheet or cover again from the device's own Dynamic Type size, not the
  root's `.dynamicTypeSize`, so Settings once ignored Appearance's text size. `bighelpPresentedAppearance`
  applies `BighelpTextSizing` again; it passes the size it chose down (`bighelpTextSizedTo`), so nothing takes
  two steps.
- **One long-press menu per List row:** a List row shows the first `.contextMenu` in it for every item, so a grid of
  tiles in one row acted on the wrong item (holding a pinned chat offered another chat's Delete). Give each tile a
  `Menu(primaryAction:)` or its own gesture.
- **Owners change on every reconnect:** `WorkspaceOwner` includes the connection generation, so returning to the app
  makes a new one. Keep per-computer state (like "this host has Kanban") by `cacheScopeID`, and don't turn a failed
  check during a reconnect into "unavailable" (`KanbanAvailability`; New Group Chat:
  `BotModeRoomStore.offersNewGroupChat`). The owner is nil while the connection is
  closed: that gap isn't another computer, so a page's data stays (`use(host:)` ignores nil).
- **Each gateway has its own objects:** `AppState`, the stores and the chats belong to one gateway
  (`NativeWorkspaceRuntime`), and a gateway switch keeps `RootShellView` and hands it the new ones. Anything handed
  over once in `.onAppear` keeps the first gateway's: an agent's drive moved a navigation that wasn't on screen
  (#666), and an unsent chat let go on another gateway said "This chat isn't available". Hand it over again
  when they change (`DriveShellHooks`, `watchForLostChats`).

### Crashes that only happen on a real iPhone

Release builds on iPhone have a 1 MB main-thread stack, and the simulator has 8 MB. Big screens with many inlined
sections can crash only on devices ("Thread stack size exceeded").
- Wrap large screen sections in `BighelpDeferredSection`.
- Before shipping a big new screen, run `ReleaseScreensWalkthroughUITests`. It's a Release build linked with
  `-Wl,-stack_size,0x100000` that walks real onboarding through a password proxy. The test file explains its
  environment variables.

### iPad layout

- iPad has no always-open sidebar. At regular width the header's sidebar button slides `HomeSidebar` in from the
  leading edge (`HomeMenuPresentation`); iPhone has no sidebar. The bottom bar (`HomeTabBar`) shows on iPad too.
- The chat lane (messages, message box, status rail) is `ChatCanvasLayout.regularLaneMaximumWidth` wide on iPad
  and Vision Pro. Bubbles take their share of it; don't reintroduce a fixed narrow column.

### iPhone Duo

- `BighelpScreenPostureReader` (on the navigation stack, so pushed chats get it too) sets `\.bighelpScreen`:
  the posture (`cover`, `open`, `openUpright`, `standard`), the trailing status column and the fold, from the window's
  size classes, its size and iOS 27.1's reserved regions (`.occlusion` for the camera column, `.division` for the
  fold, active while half-folded). Go by these, never the device model or the hinge angle (Apple says the hinge
  isn't for layout).
- Cover (466 × 678, or half of the open screen in Split View) and open wide (`usesSideBar`): built with the iOS 27.1
  SDK, iOS lays a screen's navigation bar buttons down the 84-pt status column under its 174-pt camera area. The bar's
  places are toolbar items (`HomeStripTabs`, `.bottomBar`), so iOS stacks them there too; a column of our own
  drawn over the strip lay on top of the screen's own buttons. A chat has no bar, so
  `BighelpChatSwitcher` (Settings › Chat › Chat switcher) takes the strip there.
- Open wide: `BighelpSplitColumn` shows the tab's list in its own `NavigationStack` up to the fold
  (`splitColumnWidth`), and what it opens is pushed on the app's one stack beside it, so `path`, the active chat
  and every top-of-stack rule work as on iPhone. The list is the shell's own view, drawn again from its stores
  (`BighelpLiveColumn`); the stack's root shows `BighelpSplitPlaceholder` instead of a second copy of the list.
- Upright with the fold active (`isLaptop`): `ChatView` keeps everything under the fold for the message box.
- The Duo's simulator needs the iOS 27.1 runtime and starts folded; tests can't open or fold it, and DeviceHub's
  controls don't take scripted clicks. `-bighelp.debug.screen-posture` and `-bighelp.debug.fold-halfway` show the
  open and half-folded layouts on an iPad simulator (`DuoLayoutUITests`).

### Mac

- The Mac app is the iPad app through Mac Catalyst in "Optimize for Mac" mode (family 6, `UIUserInterfaceIdiom.mac`;
  scheme `BighelpCatalyst`): full size, with the Mac's own menus, pickers and sheets. Every change must build for it:
  `xcodebuild -scheme BighelpCatalyst -destination 'platform=macOS,variant=Mac Catalyst'`.
- It ships only as a Developer ID–signed, notarized DMG on GitHub Releases (`Scripts/release-mac.sh`), never
  through App Store Connect. It shares the iPhone app's ID (`app.loopdy.mobile`) because pushes are addressed to
  it; never upload a Mac build. It runs sandboxed (`BighelpCatalyst.entitlements`; `network.server` is for the
  127.0.0.1 browser sign-in callback) and embeds the notification extension for sealed alerts.
- Updates come from Sparkle 2, which is AppKit-only: it lives in a macOS bundle (`BighelpMacUpdater/`) embedded in
  `Contents/PlugIns` and loaded at runtime by `BighelpMacUpdates`. Never link Sparkle into the app target. Each
  public Mac release carries a signed `appcast.xml`; `-bighelp.mac.update-feed-url` points a test copy at a local
  feed.
- `os(iOS)` is true on the Mac, and `canImport(ActivityKit)` and `canImport(AppKit)` are too, though ActivityKit's
  types are unavailable there. Fence with `!targetEnvironment(macCatalyst)` or `BighelpPlatform.isMac`. The Mac has
  no Watch relay, Live Activities, widgets, Siri tips, haptics or edge swipes. `horizontalSizeClass` is always
  regular there.
- Text: the Mac's text styles are fixed (Dynamic Type doesn't reach them). Write `.font(.bighelp(.caption))`, never
  `.font(.caption)`, and `UIFont.bighelp(.body)` in UIKit; `.bighelpFont(role)` already follows. They use the size
  from Settings › Appearance › Text and buttons (`BighelpInterfaceSize`; ⌘+ ⌘− ⌘0). Control sizes come from
  `BighelpTokens.hitTarget` and `BighelpTokens.scaled(_:)`, which follow the Button size there.
- Sheets open as panels at their content's minimum size and ignore detents: put `.bighelpSheetSize(.compact |
  .standard | .large)` on every sheet's content. Prefer popovers for pickers anchored to a button. Menus draw only
  their label (`BighelpMacMenuStyle`). Long-press-only actions need a `.contextMenu` (right-click) on the Mac.
- Present with `.bighelpSheet` and `.bighelpFullScreenCover`, never `.sheet` or `.fullScreenCover`. After a few
  sheets, Catalyst stops closing them: Done runs and the state says closed, but the sheet stays, stops updating
  and blocks the window until Esc. The bighelp versions close it through UIKit (`MacSheetPresentationTests`).
- `HomeSidebar` is the window's sidebar (`BighelpSideMenu`, shared with Vision Pro): it stays open while you pick,
  and the Mac remembers it. The title bar's sidebar button (`MacTitlebarItems`, on every screen), the header's
  sidebar button and ⌃⌘S toggle it. Drag its divider to resize it (remembered; double-click for the default
  width). The bar shows on the Mac too.
- Title bar items are an `NSToolbar` on `scene.titlebar`. An `NSToolbarItem` made from a `UIBarButtonItem` fires
  only the button's target/action; a `primaryAction` closure never runs.
- Keys: Return sends (Settings › Chat › Return sends), Shift-Return adds a line, Command-Return shows the send
  choices while the agent works. ⌘N starts a chat, ⌘, opens Settings and ⌘1–⌘3 pick the three places
  (`BighelpMenuCommands`).
- `BighelpMac` (`BighelpMac/`) is a separate, fixture-only desktop prototype. It isn't the shipping Mac app.
- Mouse and keyboard: plain buttons take clicks only where they draw, toolbar icons only on their glyph and form
  fields only on their line of text. Use the helpers in DESIGN.md › Mac pointer and keyboard.
- Running it: `Scripts/mac-dev-run.sh --name <you>` builds the Debug app and runs it on the demo data as
  `app.loopdy.mobile.dev-<you>` (its own sandbox data, signed ad hoc, so no keychain, pushes or app group);
  `--clean` deletes that copy's build and data.
- Driving the Mac app by hand (`cua-driver`): background key presses don't reach a Catalyst window, and a first
  click on an inactive window only activates it. Use a desktop-scope session and click twice. Sheets are separate
  windows. `.dynamicTypeSize` has no effect on the Mac. A sheet's controls appear in the main window's accessibility
  tree. A Catalyst button's accessibility frame shows its click area (unless a `.contentShape` sits outside the
  Button). Hover needs `move_cursor` with `"scope":"desktop"` while bighelp is in front. Title bar items take only
  desktop-scope clicks. To see a drag's in-between state, run a slow `drag` in the background and capture mid-way.

### Vision Pro

- The app target builds natively for visionOS (`supportedDestinations`), not as the iPad app in a window. Every
  change must build for both: `xcodebuild -destination 'generic/platform=visionOS Simulator'`.
- visionOS lacks Live Activities, Lock Screen widgets, haptics, apps' camera access, keyboard-dismiss-on-scroll and
  iOS 26's `glassEffect`. Home Screen widgets do work there: the widget extension builds for both, with glass
  texture and wall or table mounting (`bighelpWidgetPlacement()`); fence Lock Screen sizes and Live Activities to iOS. Use the shims in `BighelpPlatform.swift` and `#if os(visionOS)`. `if #available(iOS 26, *)` is
  true on visionOS, so it doesn't fence off iOS-only APIs.
- visionOS has its own layered app icon, `AppIconVision.solidimagestack` (the iPhone icon's art split into a
  cream back layer and the orb). Update it when the app icon changes; uploads without it are rejected.
- WebRTC comes from LiveKit's package on visionOS. Its Objective-C names carry an `LK` prefix, mapped back in
  `WebRTCVisionNames.swift`.
- Extra windows need multiple scenes, which only the visionOS Info.plist turns on (generated keys in
  `project.yml`). Conditional settings need both `[sdk=xros*]` and `[sdk=xrsimulator*]`; the first doesn't match
  the simulator.
- An app-wide `.tint` fills every toolbar button with that color on visionOS, so there's none there.
  `theme.canvas` is a light tint so windows stay glass; Appearance › Transparency sets how light
  (`BighelpVisionGlass`). A light window keeps at least a 45% tint: dark text on bare glass vanishes in a dim
  room. Anything painted in `theme.canvas` is see-through there, so it can't hide content scrolling under it
  (the chat masks its messages under the header instead).
- visionOS draws titles, toolbar buttons and segmented pickers' labels white, unreadable in light mode. Titles
  get the app's ink from `BighelpVisionChrome` (UIKit appearance); toolbar buttons and `.secondary` text from
  `BighelpVisionInk`, one fixed color for the app's Light/Dark setting. Adaptive (trait-based) colors fail there:
  text fields, sheet toolbars and pickers resolve them as dark in a light window. Set only the first level:
  explicit secondary and tertiary levels turn field hints and form dividers white on white. Field hints ignore
  it anyway: pass `prompt: Text("…").bighelpFieldHint(theme)`. Light-mode theme greys are darkened there too. Unselected segment labels ignore every color setting,
  so use `bighelpSegmentedPicker()`, which keeps a dark track there. Don't use `toolbarColorScheme` there: it
  overrides the appearance and turns titles white again.
- The three places sit in a leading ornament (`HomeTabOrnament`), not a bar along the bottom by the system's window
  controls. A screen covered by a pushed one hides its ornaments, and a pushed chat has Back instead.
  The sidebar opens as a column beside the page (`BighelpSideMenu`), not a sheet; the Mac uses the same column.
- Eye targets: controls are 56pt or more (`BighelpTokens.hitTarget`), header buttons 52pt glass plus margin.
- Forms on visionOS: section headers don't grow to fit (Agent Studio's hero lives in a row there), a row of
  plain buttons can be laid out zero points tall (pin it with `.fixedSize(horizontal: false, vertical: true)`),
  and a `PhotosPicker` with the default style becomes the whole row's button. A nested sheet that needs room
  uses `.presentationSizing(.page)`; `.fitted` gave a zero-size sheet whose 3D content still floated in view.
- The agent in the room is 3D (`SpatialAvatarRig`, `SpatialAvatarSculpt`), animated with the kit's own
  keyframes. Importing RealityKit makes `Scene` ambiguous; write `SwiftUI.Scene`.
  - Solids: each big shape is swept through shrinking slices (`traceTransforms`), so circles become balls.
    A shape drawn over another sticks out of its front; one drawn behind peeks out of its back.
  - Painted on: a shape at least 85% inside an earlier solid's outline is a shallow cap laid on its curved
    surface and leaned to face the way it does. Painted shading and glare (black under 40%, white under 50%)
    are skipped; real light does that. Outlines around solids are skipped too.
  - The volume opens as a `.utilityPanel`, within reach. It resizes from the corners only because the content
    gives a width, height and depth range with `.windowResizability(.contentSize)`; a fixed depth locks it. The
    agent scales with it and the volume reopens at the last size (`SpatialAvatarVolumeSize`).
  - Headwear (`SpatialAvatarHeadwear`) is built as real objects at the kit's head anchor; the creator's
    pattern is painted into a texture laid flat over the body; the chosen moves play through `BuddyPose`.
  - In windows (the avatar designer, Agent Studio) `SpatialAvatarPreview` shows the same character. A
    RealityView's content origin is its view's center; `convert(_:from: .local, to: .scene)` gives window space,
    so use it only to measure (1360 points a meter at the usual size). `GeometryReader3D` in a form reports a
    half-meter depth; don't place by it. "See it in your room" sets `SpatialAvatarModel.previewAppearance`.
  - Pinches land on a flat layer it stands in. visionOS only targets what's drawn: `Color.clear` with a
    `contentShape` never gets a tap there, so the layer is `Color.white.opacity(0.001)`.
  - Measure a volume with `GeometryReader`, not `GeometryReader3D`: the 3D one pushes flat views to the back,
    where the room can hide them.
  Kit renders for art approval: `VisionReadabilityUITests.testKitCharactersIn3D` (`BIGHELP_KIT_CHARACTERS`,
  `BIGHELP_KIT_SPIN`).
- Anything that must stay beside the agent (its voice panel, the typing box) is an `.ornament` on its volume. A
  separate window placed `.trailing(volume)` landed low and tilted, almost edge-on, until the volume moved.
- The agent in the room (`Bighelp/Spatial/`) talks through `BighelpShortcutService.connectedWorkspace()`, the same
  host path as Shortcuts. Apps can't move windows themselves: people move the volume with the system bar under it,
  and visionOS remembers the spot and snaps it to tables.
- bighelp must always start in its main window: the avatar and voice scenes use `.defaultLaunchBehavior(.suppressed)`
  and `.restorationBehavior(.disabled)`, and the avatar opens only when the person chooses Simple mode or Settings.
  Otherwise visionOS relaunches straight into a lone avatar (for example after a crash).
- Permission prompts (microphone, speech) answer on a background queue. Mark their callbacks `@Sendable`, or a
  MainActor-inherited closure traps in Swift 6 (the 2.3.0 (26)/(27) "allow microphone" crash). Apple headers
  without `NS_SWIFT_SENDABLE` are the ones to watch.
- Vision Pro UI tests: `XCUIScreen` screenshots come back blank, so tests ask the Mac for `simctl io` screenshots
  (see `SpatialAvatarUITests`). `app.swipeUp()` fails with several windows open; swipe the list instead. The speech
  permission can't be pre-granted, and an unanswered prompt comes back on every launch, so reset privacy and reboot
  the simulator before a run.
- XCUITest can't touch a second window on Vision Pro. Tests of a window's content open it inside the main window
  with a DEBUG launch argument (Kanban's `-test-kanban-main-window`).
- `glassBackgroundEffect` inside a `.background { }` floats over the view's content and eats every pinch, even with
  `.allowsHitTesting(false)`. Put the glass on the view itself (`view.glassBackgroundEffect(in:)`).

### Apple Watch

- The Watch never talks to the host. It asks the iPhone (`WatchRelay`), which answers through the Shortcuts host
  path, so it works with bighelp closed. Keep credentials and host addresses off the wire; bound everything that
  crosses (`WatchLimits`) and check it on arrival.
- WatchConnectivity calls back on its own queue: build reply/error handlers in `nonisolated static` functions, or a
  main-actor closure traps.
- A binary property list stores repeated strings once, so size tests need unique text.
- Demo: `-watch-demo` (Watch alone) and `WatchAppUITests` (`BighelpWatch` scheme). `testThroughThePairedIPhone`
  runs the real path when the paired iPhone simulator runs bighelp with `-use-demo-fixtures` and
  `BIGHELP_WATCH_LIVE_PHONE` is set.
- Watch UI test traps: lists only build rows on screen, so scroll first; scroll with
  `XCUIDevice.shared.rotateDigitalCrown`, since `swipeDown` can open a system screen and push the app away.

### CarPlay

- CarPlay voice apps need Apple's CarPlay Voice-Based Conversation entitlement (iOS 26.4+). Apple granted it
  to bighelp's team on 2026-10-23. iPhone and iPad builds, on devices and in the simulator, carry it through
  `BighelpCarPlay.entitlements` (`CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` and `[sdk=iphonesimulator*]`). Vision Pro and
  the Mac have no CarPlay and keep `Bighelp.entitlements`, so a change to the shared keys goes in both files.
- Voice buttons belong to each `CPVoiceControlState` (`actionButtons`); the template only has bar buttons.
- CarPlay calls every handler (`CPButton`, `CPBarButton`, `CPAlertAction`, `CPListItem`) on its own queue. A
  main-actor closure traps there (the 2.6.17 Agents button crash), so make them with `CarPlayCallbacks`, which hop.
- The root is a list (`CPListTemplate`): its header (`CPListTemplateDetailsHeader`) has the agent's face, what it's
  doing (`liveStepPhrase`, as in voice mode) and its last steps; the other agents are under it. The voice screen
  shows over it while you talk (iOS 27's overlay, else presented). A voice template can't be the root, and
  nothing may be pushed over it.
- The car is in use from connect to disconnect: the scene holds the host connection (`holdHostConnection`) so the
  background closers leave it, and `audio` in `UIBackgroundModes` keeps voice going with the iPhone locked. A step
  that doesn't finish in 20 s ends with a message that names it (`CarPlayConnectStep`), never an endless Connecting.
- Settings › Voice › In the car (iPhone) picks the computer and the agent (`CarPlayAgentPreference`); a pick in the car changes it too.
- Tests can't open the simulator's CarPlay window. `CarPlayVoiceUITests` drives the same session through the
  DEBUG `-test-carplay-session` screen on the demo data; `CarPlayTemplateTests` builds the car's templates.

### Connections, widgets and Shortcuts

- The app closes its host connection in the background. A suspended runtime can still report "ready".
- A wake while the phone is locked (Background App Refresh, a Shortcut, the Watch) connects, but the saved
  workspace can't open until it's unlocked (its files refuse reads while locked). That's a wait, not an error:
  unlocking, coming back and Reconnect open it (`NativeWorkspaceSelectionStore.reopenIfClosed`), because the
  wake's connection stays up and no new owner comes to trigger it (#628).
- Shortcuts and widgets first check that the host answers, and reconnect once if it doesn't.
- They wait only for what they need (`BighelpShortcutReadiness`). Ask an agent and the car start a chat, so
  they go on once the connection can make one (`NativeWorkspaceRuntime.chatsOwner`: agents known, open chats
  attached again) while the chat list and the other pages load behind them. Callers that read chats, tasks or
  groups wait for everything. On a computer with many chats the list took longer than the answer (#934).
- Links that start or open one agent's chat (voice, new chat, an agent's chat: `startsAChat`) open at the same
  point (`acceptsChatStarts`). Other links still wait for the whole workspace. Coming back from the background,
  the chat list held Start voice chat for seconds after the computer answered.
- **Widgets never go empty for what the app doesn't know yet.** A launch before the host answers, a gateway
  switch, or bighelp woken in the background (a Shortcut, the Watch, Background App Refresh) has no agents,
  chats or screens yet. Widget writers keep the saved data then: `AgentDirectoryStore.knowsProfiles`, the
  snapshot publisher's `saved` copy and `BighelpWidgetExtras.filled`, the Bots roster's carried gateways,
  and Kanban and Workflows clear only on a switch within one run. A switch shows the next gateway's
  saved copy (`retire(next:)`).
- Background App Refresh (`BighelpWidgetBackgroundRefresh`, iPhone and iPad) wakes the app while a bighelp
  widget is on the device: it connects the way Shortcuts do and publishes the widgets' data. iOS picks when.
- Usage widgets read for themselves (`UsageWidgetPublisher`): each gateway a Usage widget shows (the one in
  use, `BighelpWidgetGatewayList.inUse`, or a chosen one over its own sign-in) has its own file. They read on
  each new connection while bighelp is open, every 15 minutes, and on Background App Refresh; only a read
  where every part worked counts toward the 15 minutes. A read the moment bighelp comes back used the closing
  connection, failed, and then held off every retry.
- A Usage widget's Plans choice (several, in the picked order; styles about one plan show the first) feeds
  every style; the single Plan from before stays as a hidden fallback. Each size's styles show several plans
  as meters or as rings. Names people give plans (Usage › a plan's ••• › Rename…, or Choose) are per
  gateway, since one provider can be another account on another computer: `BighelpPlanNames` keeps them in
  the app group, keyed by `ProviderUsagePreferences.key(for:)`, and the widget puts them on itself
  (`BighelpUsageSnapshot.named`), so a rename only reloads the widgets. Choose also orders the plans: a drag
  saves `ProviderUsagePreferences.orderKey` on the device, by the same key, and Limits, the export and the
  widgets' default list follow it; a provider set up later goes after the placed ones.
- A Shortcut on a gateway that isn't in use switches bighelp to it, and the app starts connecting at once.
  `reconnect()` returns at once while another connection is under way, so the Shortcut waits for that one
  (`BighelpShortcutConnectionWait`). `ShortcutGatewaySwitchHostUITests` checks it on two real hosts.
- A Live Activity or alert tap on another gateway's chat selects that gateway, and the shell opens the chat only
  once it is ready (`ExternalOpenHostWait`, `BighelpExternalSessionOpen.switchedHost`). Opened sooner, the chat
  could fail to prepare and "Unable to open" showed over the chat that then loaded. A gateway that
  doesn't answer in `FleetSwitchFallback.timeout` gives the selection back with the usual message.
- An incoming widget or link tap during startup is queued until the host runtime is ready. Shortcuts that open a
  screen post their link to `BighelpIncomingLinkCenter`, which takes the same path.
- An app may have at most 10 App Shortcuts (`BighelpAppShortcuts`); Xcode's App Intents metadata step refuses
  more. Every other intent is still an ordinary Shortcuts action. Tiles per agent, scheduled task and group chat
  refresh through `BighelpShortcutParameters` when those names change, never on every load.
- Returning to a chat reloads it from the host. Treat the host's saved history as the truth after a turn ends.
  Coming back to the app reads an open chat's newest page again and keeps the earlier pages it holds
  (`refreshHeldHistory`); the next connection's history client takes what the last one read, for the same sign-in
  (`adoptHistory`). A full history read there laid out a long chat's every message on the main thread as you scrolled.
- Every reconnect is a new `WorkspaceOwner` (its `connectionGeneration` changes), and the owner is nil while
  disconnected. To decide whether to close open sheets or screens, compare `owner.signIn`, never the whole
  owner, or coming back after a minute away closes whatever was open (`WorkspacePresentationContinuity`).
- A chat is on the navigation stack at most once. Opening one that's there (a notification, widget or link)
  goes back to it (`AppState.activateConversation`): two copies shared one `ChatModel`, both redrew every
  change, and Back showed the same chat again.
- The chat on screen always gets a connection of its own. One opened while the host was away (its saved copy
  shows), or whose open a reconnect cut short, opens again once the runtime reconnects (`openDetachedChat`); the
  reconnect's recovery reattaches only chats that had one, and Send stayed off until you backed out and back in.
- Opening and coming back never wait for the computer: the workspace opens from what the phone saved for the
  sign-in (`WorkspaceConnectionStore.savedAuthority`, `NativeWorkspaceSelectionStore`), and the connection comes up
  behind it, into the same runtime. Nothing says "Connecting" or "Reconnecting" meanwhile: the pill, the dashboard
  and pages that need the computer (`HostPageWaitingView`) speak only once the keeper's quiet tries fail
  (`WorkspaceConnectionState.disconnected`). A sign-in that ended before it connected once keeps the opening
  screen, which has Sign in again.
- The connection pill at the top (`ConnectionIsland`) has its own pass-through window so it shows over sheets. iOS
  hides an app's own Live Activity while the app is open, so it can't be the real Dynamic Island.

### Notifications and Live Activities

Helpful, never a pile to clear (`BighelpNotificationGrouping`):
- Alerts stack per agent, not per chat. The notification service extension sets the thread from the opened title (the agent's
  name) and keeps the chat in `loopdy.sessionReference`, which the "chat on screen" check reads.
- An alert with a picture shows as a message from its agent (a communication notification,
  `BighelpPushDisplay.communication`): the agent's picture stands where bighelp's icon would. The buttons and
  picture go on the held content first, so a timeout still shows them, and the message keeps the alert's
  interruption level. Alerts the app posts itself while open keep the icon. Apple asks for the Communication
  Notifications entitlement on the app: the iPhone and iPad app (`BighelpCarPlay.entitlements`) and the
  notification service both carry it, and both App IDs need the capability.
- A newer reply for a chat removes that chat's earlier replies; questions and approvals stay until dealt with.
- Helper (subagent) results arrive passive: Notification Center only, no banner or sound.
- A scheduled task's alert opens the chat where its job was made, else the job in Scheduled tasks
  (`BighelpScheduledAlertLinks`). The plugin names them `scheduled.chat.<session>` and `scheduled.job.<job>`, only
  for phones that send `scheduledLinks` in their preferences; never a chat's own reference, because the run's text
  isn't in that chat. Scheduled alerts never replace each other.
- Settings › Notifications splits the push topic "Scheduled tasks and deliveries" into two switches: Scheduled
  tasks and Deliveries (what an agent sends with the plugin's `bighelp_send_notification` tool, outside a reply).
  With Group chats they are switches on each computer (`BighelpAlertKinds`, plugin `preferences.kinds`); the
  shared topic stays on while either is on. "Agents messaging each other" covers only turns another agent
  started: the person's own messages in a Bot Chat alert like any reply.
- Opening a chat, or returning to the app on one, clears its delivered alerts (`BighelpVisibleChats`).
- A chat on screen is quiet for every kind of alert, questions and approvals too: they pop up in the chat itself
  (`BighelpForegroundAlert`). `BighelpVisibleChats` counts chat screens by token (a chat view made again can appear
  before the old one leaves) and knows a chat by every stored ID it has had, also while its connection is made
  again (`formerStoredIDs`, the saved row). Compaction gives a chat a new stored ID and Hermes' alert for that turn
  can name it first, so a chat compacted in the last two minutes answers for its agent's unknown references
  (`lastCompactionAt`).
- One Live Activity holds the active chats as independently linked rows (`BighelpActivityGroupDriver`).
  Attention comes first; the payload holds five rows and a total count. A chat finishing cannot end another chat's card.
  The service aggregates scoped per-turn updates before sending to the shared native token (docs/LIVE_ACTIVITY_GROUPS.md).
  The finished card leaves about 30 seconds after all work ends, and opening the app clears it.
- The card starts when the person taps Send (T3 Code's playbook, `BighelpManagedNativeActivityRuntime.arm`, a
  "Sending your message" row under the chat's own opaque ID): iOS starts a Live Activity only for an app in front,
  and a turn with a file starts once the file is up, often after the person left, so it got no card. A turn that
  starts later joins the card as an update and takes that row's place; a row no turn takes goes after two minutes.
- A card is the computer's to update (pushes, sealed detail) only once the phone has matched it to the computer's
  turn (`BighelpManagedActivityBridge`, the plugin's `work` route). The phone asks as the turn starts, which is
  before the plugin has seen the turn, so it asks again a few times (`snapshotRetryWaits`) while the turn runs.
  Asked once, a card whose first answer named no work moved only while bighelp was open and never got detail.
- The Live Activity uses the app's palette and real host phases, never a guessed percentage. Titles stay in the
  phone's App Group; only opaque row IDs and bounded status reach the push service. Stale rows say Paused.
- The card's first chat shows its work (#960, `BighelpActivityHeroView`): the step in progress, the last steps, a
  timer that runs on the phone, the question that waits, the reply's first lines. All of it comes in the row's
  `sealed` field (`BighelpActivityDetail`, plugin `card_detail.py`, sealed-card-v1): AES-256-GCM under a key for
  that chat row, which the app gives the computer over its own connection (`BighelpActivityCardKey`, the
  registrar's `card-key` PUT). The notification service and Apple carry bytes they can't read; never put new card
  text in a plain field. The Live Activity extension opens it as it draws, with a secret in the keychain group
  `app.loopdy.mobile.card` that only the app and that extension have (readable after first unlock, because the
  card is drawn on a locked phone). A row that doesn't open draws the plain rows. The card is at most 160 points
  tall, so the hero counts its lines (`heroCard`), fewer at larger text. Settings › Notifications › On the card
  picks Status only, Steps, or Steps and text (`BighelpActivityDetailLevel`, in the App Group); Advanced options adds
  context use and the model. The phone words steps from Hermes' tool names (`BighelpActivityStepWords`). A
  registered card is drawn only from pushes (`writesLocally`), so the app never writes detail itself.
- Direct push (`BighelpPushRegistrar`, docs/ARCHITECTURE.md › Direct push registration): a phone that already has a
  notification installation and permission gives the notification service its Apple push address at launch, with
  nothing shown, in addition to BuzzKit (which stays). A 404 means the Worker doesn't have the route yet: no error, ask
  again in a day. Other failures get NS-123 to NS-126 in the log only. The notification service extension shows every
  alert itself (`BighelpPushDisplay`), for BuzzKit pushes and direct ones alike. This release it still sends BuzzKit's
  delivered receipt for a push that has a `bk.messageId`; a direct push gets none. The shared Live Activity's token is
  registered directly under its group ID (the `groupId` of the version 3 registration), never a per-turn or per-chat
  alias, and removed when the physical card ends.
- Notifications are set up per agent. The computer keeps a journal and host key for each agent, and an agent's
  replies alert (and move its Live Activity) only through a grant in its own journal. Every notification route
  names its agent (`?profile=`, `DirectHostNotificationClient(profile:)`); without it a request reached the
  dashboard's own agent. Setup enrolls the agent in use, and opening another agent's chat on a computer with
  notifications on enrolls that agent (`enrollAgentIfNeeded`), never asking for permission.
- A computer drops a grant for good when the notification service answers its check (`GET /enrollments/<grant>`)
  with unknown, retired or changed, while the phone still believes it's set up: nothing alerted until someone
  tapped Set Up Again. The phone asks each computer about its setups (`repairIfDropped`) when it comes to the
  front (at most hourly), when instant alerts answer `live_alerts_not_enrolled` and when a chat's subscription
  is refused, and on `notification_enrollment_*` sets up again by itself: Set Up Again's cleanup, then each agent.
- Every setup failure gets its own code where it happens (`BighelpNotificationErrorCode`, never reused or renumbered);
  the FAQ is [docs/NOTIFICATION_ERROR_CODES.md](docs/NOTIFICATION_ERROR_CODES.md).

### Usage and diagnostics (telemetry)

- On by default, with an off switch in Settings › Help & feedback. What is sent, and what never is:
  [docs/SECURITY_AND_PRIVACY.md](docs/SECURITY_AND_PRIVACY.md). Keep that page and `PrivacyInfo.xcprivacy` true.
- Everything goes through `Telemetry` (`Bighelp/Telemetry/`). Event names, props and values are enums and numbers
  (`TelemetryEvent`); never add a `String` parameter that could carry chat text, a file name or a path. A new event
  also needs a row in the ingestion Worker's allowlist, or the Worker drops it.
- It never runs in tests, UI tests, demo mode or Xcode builds (`TelemetryEnvironment`). Tests use a fake transport.
- The switch (`TelemetryController`) also tells hosts that list `native-host-telemetry-v1` (`PUT …/native/telemetry`).
  The app sends `{"enabled": true}` only when someone turns sharing back on, never when it connects.
- The notification extension only writes receipts (`BighelpDeliveryReceipts`, in the shared app group) and makes no
  network calls. The app sends them.

### Names that must stay "loopdy"

The app was first called Loopdy. The code now says bighelp, but these are stored on phones or used by other systems.
Renaming them would sign people out or break widgets, Shortcuts, pushes or the plugin:
- bundle IDs, app groups and keychain groups (`app.loopdy.*`)
- lowercase settings keys and launch arguments (`loopdy.*`, `-loopdy.*`)
- keychain services and on-device folder names (`Loopdy…`)
- widget kinds (`Loopdy*Widget`)
- `LoopdySessionActivityAttributes`
- Shortcuts types (`SendLoopdyChatIntent`, `StartLoopdyVoiceChatIntent`, `LoopdyShortcut*`)
- the saved card key `"loopdyCard"`
- `X-Loopdy-Request-ID` and `x-loopdy-*` headers
- the plugin id, routes and CLI (`loopdy`, `/api/plugins/loopdy`, `hermes loopdy`)
- the `loopdy://` URL scheme and the `*.loopdy.app` domains

New code uses Bighelp names. Don't "finish" the rename on this list.

### Provider logos

- Logos are bundled SVGs in `Bighelp/Resources/ProviderLogos.xcassets/ProviderLogo*.imageset`, a catalog of
  their own that the widget extension includes too (the Usage widget draws them).
- To add one:
  - Add it to `APPROVED_NAMES` in `Scripts/publish-provider-logos.py`.
  - Record it in `ProviderLogos-PROVENANCE.md` and `ProviderLogos-NOTICES.txt`.
  - Add an `AIProviderBrand` case.
  - Update the lists in `ProviderAssetTests`.
- The SVG exporter is strict. Remove `<title>`, CSS classes and em sizes. Use a 512×512 canvas, since export
  rasterizes at the SVG's own size. Write arc flags with separators (`a4 4 0 0 1 2 3`), because Apple's renderer
  misreads compact flags.
- Logos must have transparent backgrounds. Only use art we have the right to ship.
- Older app builds reject a remote logo manifest that contains names they don't know, so a new logo always needs an
  app build as well.

### Avatars and art

- The brand is the lifter (DESIGN.md › Lifter). His motions are the brand kit's Lottie files in
  `Bighelp/Resources/Lifter`, one for light pages and one for dark, drawn natively by `BighelpLifterView`, which
  reads only what the kit writes (shape layers, rectangles, ellipses, paths, fills, strokes, transforms and the
  intro, loop and outro markers). Replace them with the kit's own output, never hand-edited, and check them in the
  loader gallery. Below 28 points he's the still mark.
- The chat plays one loader at a time, on its newest live folder (`BighelpActivityLoaderFocus`). A new live
  indicator in the chat goes through that focus, not its own animation.
- The avatar kit's source is `Design/AvatarKit`. `tools/export_native.py` writes `Bighelp/Resources/AvatarKit.json`,
  which the app draws natively.
- Edit avatar (`AvatarChooserView`) offers Bot Studio, PetDex (`AvatarCreatorView` with only pets) or a photo.
  **Bot Studio** (`BotStudioView`, `Bighelp/Companion/BotStudio/`) makes every avatar from one recipe
  (`BotLook`): a body from catalog v2 plus eyes, mouth, colors, tilt, lean, taller or wider, size, mirror and an
  idle move. Every body takes every choice, so all packs edit the same way. Bodies are flat outlines in one
  style (`services/avatars/docs/BOT_BODIES.md`): draw new ones there, preview them with
  `scripts/bodies-preview.py`, and run `npm run bodies:app` to refresh the app's copy (`BotBodies.json`).
  `BotBodyLibrary` downloads `/v2/bodies.json` and falls back to that copy.
- A Bot Studio avatar is saved in the agent's `ui_meta["hermes-bots"]` as `studio` (`AgentAvatarLook.studio`)
  with `imageKind: "photo"` and its picture, so it follows the agent; Hermes Desktop and older apps show the
  picture. The recipe keeps its body, so it draws after the body's set leaves the catalog. It plays the same
  moods as every face (`BotLookPlayer`, `BuddyPose`).
- The older characters (`AvatarCatalog`, `Bighelp/Companion/AvatarCatalog/`) still draw for agents that have
  them; a pick saved the character's immutable pack hash (`AvatarCatalogReference`) and kept the pack in
  Application Support. Opening Bot Studio on one starts from its redrawn body. The app ships a copy of both
  catalogs for demo mode and first launch; refresh them before a release.
- Only first-party or permissively licensed art can ship in this Apache-2.0 repo.
- The maintainer approves new character art before it ships.
- An agent's face (`AgentFace`, drawn by `AgentLiveAvatar`, the Bots view's `SimpleBotFace` and its pet
  companion `AgentPet`) is, in order: its saved character (`CompanionStore` override), its petdex pet's moves
  (`PetAvatarStore`), its Hermes face, shape or Bot Studio avatar (`AgentLookStore`, from the profiles' looks), its mark
  (`SimpleBotMarkStore`), then its picture. The first two live on the device, so saving any other kind of
  avatar must clear them (`AgentEditorModel.applySavedLook`), or chats keep the old one. There is no app-wide
  pet: each agent's pet is its own face.
- A petdex pet saves its first frame as the agent's picture (what Hermes Desktop and other devices show). Its
  sheet is fetched from petdex and cut into one strip per move; hatched-on-host pets have no sheet and stay still.

### Agent templates

- Agent templates come from the Template Catalog (`catalog.bighelp.app`, `services/catalog`;
  `TemplateCatalogStore`), with the bundled ones as the fallback.
- A template can declare fill-in fields (`variables`) for its `{{key}}` placeholders. The rules for the app,
  the catalog and the plugin are in
  [services/catalog/docs/TEMPLATE_VARIABLES.md](services/catalog/docs/TEMPLATE_VARIABLES.md).
- The app's side is `TemplateVariables` (parse, check and fill in one pass) and `AgentTemplateFillView`, the
  short form that opens when someone starts an agent from a template that has fields.
- Pickers group templates and blueprints by the catalog's `category` (`TemplateCategory`: the ten agent topics
  and five blueprint topics, in a fixed order; unknown or missing is Other). They share the search row, topic
  chips, section headers and Sort (`TemplatePickerParts.swift`) and one listing (`TemplateTopics.listing`). A new
  catalog topic needs an app build to get its own name; until then it shows under Other.
- Every catalog template is also a file in `catalog/` (see [catalog/README.md](catalog/README.md)). Merging a change
  there to `main` publishes it (`.github/workflows/catalog.yml`). After approving a community submission, run
  `services/catalog/scripts/catalog-sync.py export` and commit, so the repo keeps it.
- My Templates are bots saved as templates on the person's computer (a Simple Bot profile's Share), through the
  plugin's `my-templates` routes (`native-my-templates-v1`, `MyTemplatesStore`) in the catalog's agent shape. They
  show first in every template picker, including New Bot's Templates (`SimpleBotCreation`). A saved template
  that doesn't read is skipped and counted, on the host and in the app, never the whole list.

### Secrets and access

- Nobody shares data with the host and its AI providers before agreeing once (`AIDataConsent`, App Review
  5.1.1(i)/5.1.2(i)). First setup asks before any computer is connected. Anyone else who hasn't agreed (a bighelp
  set up before the agreement existed, likely why App Review rejected Vision Pro 2.3.0 and 2.6.2 under 5.1.1) is
  asked when bighelp opens (`AIDataConsentGate`), and the Shortcuts path (`liveWorkspace`, also the Watch, CarPlay
  and the agent in the room) sends nothing until then. After agreeing, never ask again: not after updates, not for
  new hosts. Never rename its key, and keep its text short and free of company names.

- Credentials live in the Keychain, never in `UserDefaults` or logs.
- Proxy custom headers have their own Keychain service and a list of reserved header names they can't use.
- `Config/Local.xcconfig` (team ID, keys) is git-ignored. See `Config/Local.xcconfig.example`.
- Keep all external input bounded and validated.

## Testing against a real Hermes host

- `Scripts/HostSignInMatrixProbe.py` starts isolated Hermes hosts for the sign-in matrix. Its `--modes tools
  --plugin <plugin checkout>` option runs scripted tool turns for secure input, steering and questions
  (`HostSignInMatrixUITests`).
- `Scripts/NativeWorkspaceAcceptanceProbe.py` covers the workspace and chat acceptance flows.
- `Scripts/RoomLinkProbe.py` starts two isolated hosts and checks a group chat with an agent from each
  (Hermes RoomLink) through the protocol calls. The scratch Hermes needs
  Python 3.14 and its `messaging` extra (the API server serves RoomLink).
- `Scripts/AppStoreScreenshots.sh` takes the App Store screenshots from the real app on an isolated host whose
  agents really run their tools on made-up files. No demo chats in store screenshots.
  `Scripts/AppStorePosters.py` frames them as posters in bighelp.app's style with the app's Ink look (Paper and
  Black, Inter 800 headlines, the Ember Noodle).
- **Never start Hermes with a fresh `HERMES_HOME` against a shared Hermes checkout.** Hermes treats it as an
  unfinished update, rebuilds the checkout and rewrites its launchers to point at your throwaway environment. Instead:
  - Use a separate clone of Hermes.
  - Set `HERMES_DISABLE_LAZY_INSTALLS=1`.
  - Fingerprint the real install's launchers before and after.
- Test hosts need `plugins.enabled: [loopdy]`, or user plugins don't load.
- Never call `/api/gateway/restart` on a test host. On macOS it reaps every gateway process on the machine.
- Ask the maintainer before running anything against their real hosts.

## Git, commits and releases

- **Commits:**
  - Keep them small and logical.
  - The subject says what changed for the user, in plain words, for example "Send during a running tool steers the
    turn" or "Widget New Chat waits for the host instead of failing".
  - Commit your work before you stop.
- **Pull requests:**
  - Explain the visible behavior and any trust-boundary impact.
  - List what you tested, and where: demo, real host or device. Give the results from the Mac, never a CI run, and
    never list a missing CI run as a blocker (see Build and test).
  - The maintainer merges.
- **Versions** live in `project.yml`: `MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` in every target. Regenerate
  after bumping.
- **Releases are batched.** Merge pull requests whenever they're ready; releasing is a separate step the
  maintainer starts:
  - Internal TestFlight builds can go out whenever they're useful.
  - Public TestFlight builds go out only when the maintainer says so. They cover everything since the last public
    build, with one set of notes, because every build notifies every tester.
  - When both repos change, release the plugin first, then the app build that needs it.
  - Builds and uploads run on a Mac (`Scripts/` and the release lane), never through `testflight.yml` unless the
    rule in Build and test allows it.
- **Release notes** for each App Store version live in [docs/RELEASE_NOTES.md](docs/RELEASE_NOTES.md), in ASD-STE100
  plain English. The App Store "What's New", the TestFlight notes and the Mac release notes come from it.
- **TestFlight "What to Test" notes** are plain text. Some symbols (like ☰) are rejected. Write them for testers:
  - new features
  - bug fixes
  - anything they need to do, like updating the plugin
- **This repo is where the work happens.** There's no private copy or mirror. Every change has an issue and lands
  through a squash-merged PR that closes it, so each TestFlight build's issues and PRs are here when it's uploaded.
