# Localization

bighelp uses Apple's String Catalog at `Bighelp/Resources/Localizable.xcstrings`.
English (`en`) is the development language and the readable source key. Simplified
Chinese (`zh-Hans`) is the first additional language. This is a staged foundation,
not a claim that the whole app is translated.

## Initial coverage

- First-run welcome, optional appearance controls, AI data consent, connection
  headings and sign-in controls, plugin introduction, notification introduction,
  and mode selection.
- Main bottom-bar labels, menu destinations, host-switcher controls, recent-chat
  controls, and the equivalent Mac menu-bar tab names.
- Core chat composer placeholders and accessibility labels, send/stop/voice
  controls, mid-turn send choices, and attachment/action-menu labels.
- Top-level Settings rows, identity controls, experience switches, appearance
  summary, assistant rows, and Nerd Mode entry.

The second stage (#527) adds:

- Bots mode (Simple Bot mode before 2.6.11): the home (pinned bots, the list, search,
  the + menu, a bot's long-press menu, Rearrange, the gateway filter), New Bot and its
  Templates sheet, New Group Chat, a bot's profile (Info, Computer, Files and Media tabs,
  Instructions, Default Model, Routines), the voice bar, the opening loader, and its
  short Settings.
- Teamwork: the line where agents talk to each other ("Asked …", "… answered",
  "N messages with …"), its sheet, the working and typing states, and the Teamwork
  switch with its line. In Bots mode the switch says bots in sentences of its own.
- The Settings pages these lead to: Experience, Assistants, Notifications (topics,
  "Agents messaging each other", channels, workflows, Quiet Hours, test and turn-off),
  Chat (with Nerd Mode's sections), and Appearance with Chat layout and App layout.
- The modes after their 2.6.11 rename: Bots, Chat and Code, the Unified Mode Toggle,
  and the mode edge swipes.

The Chinese text is an AI-assisted draft and remains `needs_review` in
the catalog. It has not received professional or fluent-speaker approval. Screenshots
and automated checks establish rendering and lookup, not linguistic certification.
Keep `bighelp`, `Hermes`, provider/model names, and product names intact. Terminology:
the modes are Bots = 机器人, Chat = 聊天 and Code = 代码 (Bots mode = 机器人模式,
Code mode = 代码模式; the Chat mode was called Sessions before 2.6.11). A list of
chats is still Sessions = 会话. Agents = 智能体, Feed = 动态, Ideas = 灵感,
Goals = 目标, host/computer = 电脑, Teamwork = 团队协作, primary bot = 主机器人,
gateway = 网关, template = 模板, routine = 例行任务, pin = 置顶, Quiet Hours = 勿扰时段,
channel = 渠道, Live Activities = 实时活动, Dynamic Island = 灵动岛.

## Adding copy

Use a SwiftUI localized literal where the API accepts one:

```swift
Text("Choose your mode")
Button("Continue", action: next)
```

Plain `String` helpers and model properties do not get translated just because
they eventually reach `Text`. Resolve app-owned copy at its definition:

```swift
var title: String { String(localized: "Settings") }
let prompt = String(localized: "Message \(agentName)")
```

For a reusable view that only takes app copy, accept `LocalizedStringKey` (as the
first-run feature rows do). For a mixed input such as a menu row's title/detail,
keep `String` and explicitly localize only app-owned literals at the call site.
Never turn arbitrary `String` inputs into `LocalizedStringKey` inside a shared
component: a user could name a chat "Settings", and that title must stay exactly
as they wrote it. Preserve messages, drafts, agent/host/project names, model names,
file paths, identifiers, enum raw values, JSON keys, URL routes, and saved settings.
Do not persist localized display text in place of stable IDs.

Keep the whole sentence in the localizable call. Do not concatenate translated
fragments. The catalog records interpolation as `%@`, `%lld`, etc.; retain every
argument's type/count. Positional forms such as `%2$@` may reorder arguments.
Use catalog plural variations for counts: English needs `one` and `other`, while
Simplified Chinese uses `other`. The Teamwork summary is a working example.
Use Foundation format styles for numbers and dates; do not derive storage
identifiers from display labels. Lists of names go through catalog keys
(`%@ and %@`, `%@, %@ and %@`, the `, ` separator) because English keeps its
existing "A, B and C" without a serial comma.

A word swap can't be translated. When one screen says bots where another says
agents, give it whole sentences of its own (Teamwork's `detail(saysBots:)`).
When the same English means two things, give one of them its own key and keep the
English with `defaultValue:` (the Bots mode + button's "New" is not the unread
badge's "New").

## Catalog and build workflow

`project.yml` sets `developmentLanguage: en`, disables unused Base
internationalization, and enables `SWIFT_EMIT_LOC_STRINGS` plus
`LOCALIZATION_PREFERS_STRING_CATALOGS` for the main app target. XcodeGen discovers
`en` and `zh-Hans` from the catalog and writes the project's known regions. The
main app resource is shared by iPhone, iPad, Mac Catalyst, and Vision Pro; it is
not included in Watch, widget, notification-extension, or fixture Mac targets.

1. Add or change the English literal at the source. Build in Xcode to extract
   localizable strings. Review extraction changes; do not translate runtime data.
2. Add the translation in the catalog with context for ambiguous terms. Leave
   drafts `needs_review`; only mark them `translated` after language review.
   English-only entries are allowed and fall back to readable English.
3. Run `python3 Scripts/check-localization.py`. It checks representative surface
   keys, source language, argument preservation, plural categories, and accidental
   protocol/storage IDs. For the second stage's screens it also fails when bare
   English reaches a plain-`String` helper (`SimpleBotsRow`, `settingLabel`, error and
   status state, `?? "Fallback"`). It is not an exhaustive scanner of every screen.
4. Run `xcodegen generate` whenever adding/removing resource or test files; commit
   the generated project. Never edit `project.pbxproj` by hand.
5. Run `LocalizationTests` and `LocalizationUITests` with the `Bighelp` scheme on
   an isolated iPhone simulator, plus affected tests. The UI suite launches with
   `-AppleLanguages (en)` / `-AppleLanguages (zh-Hans)` and `-AppleLocale en_US` /
   `-AppleLocale zh_CN`, in light and dark mode, and attaches screenshots. Inspect
   the screenshots for truncation, overlapping controls, and mixed-language gaps.

The system chooses the app language at launch. Use the device's app-language
setting or Xcode's scheme language; there is no separate in-app language setting.
Changing only SwiftUI's environment locale in a preview does not test Foundation
`String(localized:)` model properties. Bundle tests explicitly load the compiled
English and Chinese resources, test fallback and plurals, and preserve interpolated
names that happen to match catalog keys.

## Follow-up scope

Deeper Settings pages, chat history/status/error copy, expanded chat tools and
advanced model controls, host/proxy/plugin error messages, connection progress
details, feature pages (Feed, Ideas, Goals, Files, Projects, Kanban, Workflows,
Usage, IDE), and server-owned descriptions remain partially or wholly English.
Within the second stage's screens these stay English for now: the model and
reasoning picker behind Default Model, a bot's screen (the Computer tab's
contents), the routine editor, the avatar studio, Archived Chats, Apps, Usage,
Notifications › Advanced › Provider details and the notification setup's status
and error messages, catalog template text, and chat tool phrases (so a running
agent-talk line reads "Nova：searching the web…"). The notification service names
its topics in English; English shows those names and other languages show the
app's own words for the same topics. Onboarding mode-preview images still contain English
demo text; localize those assets in a later screenshot pass. A translated menu
entry does not imply its entire destination is translated.

Watch, widgets, Live Activities, notification extension copy, Shortcuts, CarPlay,
spatial-only controls, privacy usage descriptions in Info.plist, and App Store
metadata need their own resource/target audit. Additional locales, right-to-left
layout, large Dynamic Type, iPad/Catalyst/Vision Pro language screenshots, and
fluent-speaker review are follow-up work. Do not include real host data in fixtures
or localization screenshots.

References: Apple's [String Catalog guide](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
and [preparing SwiftUI views for localization](https://developer.apple.com/documentation/swiftui/preparing-views-for-localization).
