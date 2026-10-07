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
  - Anything that looks like host administration goes behind Settings › Nerd Mode: files, gateways, plugins, MCP,
    logs, raw IDs, token counts. Nerd Mode is `settings.nerdModeEnabled`, also the `nerdModeEnabled` environment
    value.
  - Everyday controls must never live only behind Nerd Mode.
- **One place for each thing.**
  - There's one ☰ menu (`BighelpMenu`) and one Settings. Settings is a short list of rows that each open one page;
    Nerd Mode adds its Hermes section (System, Hermes tools) at the bottom.
  - Don't add a second menu, drawer or settings copy for a feature. Add a row where people already look.
  - People choose the bottom bar (Chat plus up to four) and ☰'s order in Appearance › App layout
    (`BighelpAppLayout`). ☰ lists every place the bar doesn't hold, so nothing is out of reach, and Agents
    and Settings always (`staysInMenu`): quick screens hide the bar. A new place
    in ☰ is a `BighelpPlace` case; a page that can be pinned also needs an `AppTab` and a root in `rootTabs`.
  - Long-stay screens (Chat, Agents, Projects, Kanban, Workflows, Scheduled tasks) open from ☰ as screens of
    their own, with ☰ in the corner (`AppTab.isLongStay`). Quick ones (Usage; Feed, Ideas, Goals and Files when
    the bar doesn't hold them) slide in over where you are, with Back. Settings is a sheet: Back steps through
    it, Done closes it. Whatever the bar holds is a tab. Headers drawn by the app place ☰ with
    `bighelpHeaderButtonsPlacement()`, so it sits where the top bar puts it on every screen
    (`MenuButtonPlacementUITests`).
  - Main screens look the same whichever tab you came from (`SearchPlacementUITests`). Their title is the
    bar's small one (a large title kept the size of the tab before). Search uses the system's place, never
    `.navigationBarDrawer`: along the bottom on iOS 26, under the bottom bar, which keeps the same gap above
    it (`tabsClearBottomSearch` lists the tabs).
  - Never show "bighelp account" or "Link" wording. That pairing system is retired.
- **Real data only.**
  - Avatars, activity poses and badges must come from what the agent is actually doing.
  - Never fake progress.
- **No AI spending by default.**
  - Feed, Ideas and Goals start empty, with no default scheduled jobs.
  - Content appears only after the user asks their agent for it.
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
| `Bighelp/App/` | App composition, `RootShellView`, routes (`AppRoute`, `RootDestinations`), ☰ menu, connection keeper, widget/Shortcut entry points |
| `Bighelp/Chat/` | Chat screen, composer, `ChatModel` (+ `ChatModel+Submission`), the native chat timeline |
| `Bighelp/DirectHermes/` | The Hermes client: sign-in, WebSocket JSON-RPC, dashboard REST, plugin routes (`DirectHermesNativeContext.swift`), access credentials |
| `Bighelp/Workspace/` | `WorkspaceOperation` (every host operation) and workspace stores |
| `Bighelp/Settings/` | Settings screens and `SettingsStore` |
| `Bighelp/Agents/`, `Board/`, `Companion/` | Agents, Feed/Ideas/Goals, the avatar kit renderer |
| `Bighelp/Kanban/` | Kanban on Hermes' Kanban plugin: board model, lanes, cards, Vision Pro window and pinch-drag |
| `Bighelp/Usage/` | The Usage page (☰ › Usage): plans and limits (`ProviderUsageStore`), Hermes' own analytics per agent and computer (`UsageStore`, `HostUsageLoader`), charts |
| `Bighelp/Voice/` | Turn-based and live voice |
| `Bighelp/Spatial/` | Vision Pro: the agent in the room (`SpatialAvatarModel`, its volume and voice panel, its Settings section) |
| `BighelpWatch/`, `BighelpWatchShared/`, `Bighelp/Watch/` | The Watch app, the Watch–iPhone wire (`WatchWire`), and the iPhone's `WatchRelay` that answers it |
| `Bighelp/CarPlay/` | CarPlay's hands-free voice chat (`CarPlayVoiceSession`) and its scene |
| `Bighelp/DesignSystem/` | `BighelpTheme`, `BighelpTokens`, glass surfaces, fonts, provider logos, `BighelpDeferredSection` |
| `Bighelp/Hosts/`, `Bighelp/LiveActivity/`, `Bighelp/Notifications/`, `Bighelp/Shortcuts/` | Host setup, Live Activities, notifications, App Intents |
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
- **Simulators:**
  - Never run two `xcodebuild test` sessions on one simulator.
  - Give parallel builds their own `-derivedDataPath`.
  - Run long suites in the background so you can keep working.
- **Known failures:** some tests fail on untouched `main` too, for example
  `DirectHermesVoiceMediaTests.nativePCMSilenceActuallySchedulesAndDrains` (simulator audio) and a few old UI tests.
  Check against `main` before calling something a regression.

### UI test traps

- `BighelpUITestCase` launches with Nerd Mode on and `-loopdy.home.opens-chat NO`. Use its helpers:
  - `openRootTab`
  - `settingsRow`
  - `openChatInfo`
  - `chatNewChatButton`
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
  people, a note on each message that only the model sees. The wait is capped (1.2 s), so a slow host sends the
  message without a name. `UserIdentity.name` is empty until someone saves one; "You" is an on-screen placeholder
  (`displayName`) and must never be sent. Names are at most 40 characters.
- **A turn stays pending while it streams:** after `prompt.submit` returns `streaming`, the chat isn't "ready for a
  new turn" until the turn ends. A mid-turn Send must go through the steer/queue path (`sendMidSession`). Steer is
  the default.
- **Plugin routes:**
  - Each route is a `WorkspaceOperation` case plus a `Route(path:feature:isMutation:maximumResponseBytes:)` in
    `DirectHermesNativeContext.swift`.
  - The route only runs when `/native/context` lists its feature. Otherwise it fails as unsupported, and the UI
    should say "update the plugin", never show a raw error.
  - Requests send `If-Match` (the context ETag) and `X-Loopdy-Request-ID`, which must be a lowercase UUID.
  - On a `conflict` (context changed), reload the context and retry once.
- **Plugin releases (no pin):**
  - The app installs and offers the plugin's latest GitHub Release (`Bighelp/Hosts/PluginLatestRelease.swift`).
    Plugin releases are batched: the maintainer ships a release PR and starts the plugin's Release workflow.
    A plugin update never needs an app build.
  - It looks up the release's exact commit, installs it, reads it back, and never replaces a newer or equal
    plugin. An install that may still be running on the host is finished with the commit it asked for.
  - When the app needs a newer plugin feature, gate it on `/native/context` and say "update the plugin".
  - CI tests against the plugin's `main`.
- **Files agents send** (`MEDIA:` lines, generated pictures): the plugin's `attachments/resolve` + `attachments/fetch`
  routes serve them in ~3 MB pieces. After the first piece the rest download three at a time, and a dropped piece is
  asked for again from its offset. Finished files are kept on the phone (`AgentAttachmentCache`, Caches, 512 MB, least
  recently opened go first), so a reopened chat shows them at once. Until a file lands, its message shows a loading
  tile (`PendingAgentFilesView`), never the raw line. Hosted image tools (Nous Portal, FAL) report the picture's
  https address instead of a host file; the card reads it from there (public hosts only, no cookies, bounded).
- **Supported Hermes versions:** 0.21.2 to 0.21.5.
  - Hosts differ, so parse leniently: ignore unknown keys and treat most parts as optional.
  - A missing part should hide one row, not break a screen.

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
- **Overlays that swallow taps:** full-screen `UIView` helpers in overlays need `isUserInteractionEnabled = false`,
  or they swallow every tap.
- **Chat row environment:** chat rows (`NativeChatTimeline`) copy selected environment values into each row. If a row
  acts stale (for example, animations frozen because it still thinks the app is inactive), check what the timeline
  copies and whether the representable reads it.
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
- **One long-press menu per List row:** a List row shows the first `.contextMenu` in it for every item, so a grid of
  tiles in one row acted on the wrong item (holding a pinned chat offered another chat's Delete). Give each tile a
  `Menu(primaryAction:)` or its own gesture (`AgentPinnedGrid`).
- **Owners change on every reconnect:** `WorkspaceOwner` includes the connection generation, so returning to the app
  makes a new one. Keep per-computer state (like "this host has Kanban") by `cacheScopeID`, and don't turn a failed
  check during a reconnect into "unavailable" (`KanbanAvailability`). The owner is nil while the connection is
  closed: that gap isn't another computer, so a page's data stays (`use(host:)` ignores nil).

### Crashes that only happen on a real iPhone

Release builds on iPhone have a 1 MB main-thread stack, and the simulator has 8 MB. Big screens with many inlined
sections can crash only on devices ("Thread stack size exceeded").
- Wrap large screen sections in `BighelpDeferredSection`.
- Before shipping a big new screen, run `ReleaseScreensWalkthroughUITests`. It's a Release build linked with
  `-Wl,-stack_size,0x100000` that walks real onboarding through a password proxy. The test file explains its
  environment variables.

### iPad layout

- iPad has no always-open sidebars. ☰ opens the one menu, which slides in from the leading edge
  (`HomeMenuPresentation`); iPhone shows the same menu as a sheet. The bottom tab bar shows on iPad too.
- The chat lane (messages, message box, status rail) is `ChatCanvasLayout.regularLaneMaximumWidth` wide on iPad
  and Vision Pro. Bubbles take their share of it; don't reintroduce a fixed narrow column.

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
- ☰ is the window's sidebar (`BighelpSideMenu`, shared with Vision Pro): it stays open while you pick, and the Mac
  remembers it. The title bar's sidebar button (`MacTitlebarItems`, on every screen), ☰ and ⌃⌘S toggle it. Drag
  its divider to resize it (remembered; double-click for the default width).
- Title bar items are an `NSToolbar` on `scene.titlebar`. An `NSToolbarItem` made from a `UIBarButtonItem` fires
  only the button's target/action; a `primaryAction` closure never runs.
- Keys: Return sends (Settings › Chat › Return sends), Shift-Return adds a line, Command-Return shows the send
  choices while the agent works. ⌘N starts a chat and ⌘, opens Settings (`BighelpMenuCommands`).
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
- Tabs sit in a leading ornament (`VisionTabOrnament`), not a bar along the bottom by the system's window
  controls. A screen covered by a pushed one hides its ornaments, so the pushed home chat carries its own.
  ☰ opens as a column beside the page (`BighelpSideMenu`), not a sheet; the Mac uses the same column as its sidebar.
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

- CarPlay voice apps need Apple's CarPlay Voice-Based Conversation entitlement (iOS 26.4+), requested at
  developer.apple.com/contact/request/carplay. Until it's granted only simulator builds carry it
  (`CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]` → `BighelpCarPlay.entitlements`). Once granted, move the key
  into `Bighelp.entitlements` and drop the simulator override.
- Voice buttons belong to each `CPVoiceControlState` (`actionButtons`); the template only has bar buttons.
- Tests can't open the simulator's CarPlay window. `CarPlayVoiceUITests` drives the same session through the
  DEBUG `-test-carplay-session` screen on the demo data.

### Connections, widgets and Shortcuts

- The app closes its host connection in the background. A suspended runtime can still report "ready".
- Shortcuts and widgets first check that the host answers, and reconnect once if it doesn't.
- An incoming widget or link tap during startup is queued until the host runtime is ready. Shortcuts that open a
  screen post their link to `BighelpIncomingLinkCenter`, which takes the same path.
- An app may have at most 10 App Shortcuts (`BighelpAppShortcuts`); Xcode's App Intents metadata step refuses
  more. Every other intent is still an ordinary Shortcuts action. Tiles per agent, scheduled task and group chat
  refresh through `BighelpShortcutParameters` when those names change, never on every load.
- Returning to a chat reloads it from the host. Treat the host's saved history as the truth after a turn ends.
- Every reconnect is a new `WorkspaceOwner` (its `connectionGeneration` changes), and the owner is nil while
  disconnected. To decide whether to close open sheets or screens, compare `owner.signIn`, never the whole
  owner, or coming back after a minute away closes whatever was open (`WorkspacePresentationContinuity`).
- The connection pill at the top (`ConnectionIsland`) has its own pass-through window so it shows over sheets. iOS
  hides an app's own Live Activity while the app is open, so it can't be the real Dynamic Island.

### Notifications and Live Activities

Helpful, never a pile to clear (`BighelpNotificationGrouping`):
- Alerts stack per agent, not per chat. The notification service extension sets the thread from the opened title (the agent's
  name) and keeps the chat in `loopdy.sessionReference`, which the "chat on screen" check reads.
- A newer reply for a chat removes that chat's earlier replies; questions and approvals stay until dealt with.
- Helper (subagent) results arrive passive: Notification Center only, no banner or sound.
- Opening a chat, or returning to the app on one, clears its delivered alerts (`BighelpVisibleChats`).
- One Live Activity at a time: a new chat's card replaces the older one (`BighelpManagedNativeActivityRuntime`).
  Finished cards leave the Lock Screen about 30 seconds after the end (the Link service sends a dismissal date),
  and opening the app clears any still there.
- The Live Activity uses the app's palette from the widget snapshot, like the Home widgets. Its four steps come from
  the phase Hermes reports, never a guessed percentage.

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

- Logos are bundled SVGs in `Bighelp/Resources/Assets.xcassets/ProviderLogo*.imageset`.
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

- The avatar kit's source is `Design/AvatarKit`. `tools/export_native.py` writes `Bighelp/Resources/AvatarKit.json`,
  which the app draws natively.
- The avatar picker's characters come from the avatar catalog (`avatars.bighelp.app`, `services/avatars`;
  `Bighelp/Companion/AvatarCatalog/`): bighelp, hermes (the app's own Faces and Shapes), petdex and other.
  A pick saves the character's immutable pack hash (`AvatarCatalogReference`) and keeps the pack in
  Application Support, so it keeps drawing after its set expires. Expiry only hides choices. The app ships a
  copy of the catalog (`AvatarCatalog.json`, `AvatarCatalogKit.json`) for demo mode and first launch;
  refresh it before a release.
- Only first-party or permissively licensed art can ship in this Apache-2.0 repo.
- The maintainer approves new character art before it ships.
- An agent's face (`AgentLiveAvatar`) draws, in order: its saved character (`CompanionStore` override), its
  petdex pet's moves (`PetAvatarStore`), then its picture. Both stores live on the device, so saving any other
  kind of avatar must clear them (`AgentEditorModel.applySavedLook`), or chats keep the old one.
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

### Secrets and access

- Credentials live in the Keychain, never in `UserDefaults` or logs.
- Proxy custom headers have their own Keychain service and a list of reserved header names they can't use.
- `Config/Local.xcconfig` (team ID, keys) is git-ignored. See `Config/Local.xcconfig.example`.
- Keep all external input bounded and validated.

## Testing against a real Hermes host

- `Scripts/HostSignInMatrixProbe.py` starts isolated Hermes hosts for the sign-in matrix. Its `--modes tools
  --plugin <plugin checkout>` option runs scripted tool turns for secure input, steering and questions
  (`HostSignInMatrixUITests`).
- `Scripts/NativeWorkspaceAcceptanceProbe.py` covers the workspace and chat acceptance flows.
- `Scripts/AppStoreScreenshots.sh` takes the App Store screenshots from the real app on an isolated host whose
  agents really run their tools on made-up files. No demo chats in store screenshots.
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
  - List what you tested, and where: demo, real host or device.
  - The maintainer merges.
- **Versions** live in `project.yml`: `MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` in every target. Regenerate
  after bumping.
- **Releases are batched.** Merge pull requests whenever they're ready; releasing is a separate step the
  maintainer starts:
  - Internal TestFlight builds can go out whenever they're useful.
  - Public TestFlight builds go out only when the maintainer says so. They cover everything since the last public
    build, with one set of notes, because every build notifies every tester.
  - When both repos change, release the plugin first, then the app build that needs it.
- **TestFlight "What to Test" notes** are plain text. Some symbols (like ☰) are rejected. Write them for testers:
  - new features
  - bug fixes
  - anything they need to do, like updating the plugin
- **This repo is where the work happens.** There's no private copy or mirror. Every change has an issue and lands
  through a squash-merged PR that closes it, so each TestFlight build's issues and PRs are here when it's uploaded.
