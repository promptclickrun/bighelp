# bighelp native iOS presentation

## Authority and scope

The current authority is the **Ember brand kit** (bighelp, a Longview company) and its blended direction:
1a "Messages, evolved" structure, 1b "Center stage" warm cream as light mode, and 1c "After dark" as dark mode.
The app is a simple messaging experience for personal assistant agents. Earlier bighelp/iOS 27 Builder references
are historical (`docs/ui-v3-design.md`).

## Simplicity means hierarchy, not concealment

- Use concise, distinct headers and coherent sections. Group by the person's task, not the code's store or transport boundaries.
- Keep basic options visible and directly editable. Many visible options are appropriate when their grouping makes sense.
- Distinguish advanced options clearly. Do not put every setting behind another menu or create a page per setting.
- Remove repeated headings, instructions that merely restate a control, oversized identity introductions and routine implementation explanations.
- Preserve user-authored names, instructions, content and saved settings. Summarizing a row is not permission to truncate its stored data.
- Keep consequences for credentials, recipients, spending, destructive changes and uncertain saves at the relevant decision. Simplification must not conceal them.
- Aim for understanding setup and ordinary chat in roughly 30 seconds. This is a comprehension target, not a measured authentication-time promise.

## Visual language

- **Ember** (`EmberMark`, `EmberWordmark`, `EmberLockup`) is a perfect coral (#FF8A7A) circle with eyes gazing up. It
  appears only in chrome (root nav bars, icon, splash), never as a chat participant and never in an agent color.
  The wordmark is lowercase SF Pro Rounded heavy and always ends with the coral period: `bighelp.`
- Light: cream canvas #FFF9F5, white cards, #F3ECE6 incoming bubbles, ink #1C1A19. Dark: #121110 canvas,
  #1E1C1B / #292624 surfaces, cream text. Actions are lavender-purple (#7B52E0 light, #C9B6FF dark); outgoing
  bubbles #7B52E0 with white text. All of this lives in `BighelpTheme` so screens read theme tokens, not system colors.
- Settings › **Appearance** (`AppearanceStudioView`) is the one place for the look: a live light/dark preview,
  12 bubble colors (`BighelpBubbleColor`, Lavender is Ember's own), the light page (Cream #FFF9F5 or Paper #FFFFFF),
  the dark page (Graphite #1C1C1F or Black #000000), Automatic/Light/Dark and Chat layout. High contrast keeps its
  own pages. There are no other themes: the old theme list (Nous, Superpilot, custom themes with import, export,
  fonts and logos) was removed because picking a bubble color quietly replaced it. First-run setup offers the same
  bubble colors (`AppearanceBubbleGrid`).
- Agents are organic blobs and glossy orbs in their own palette color (`AgentPersonaAvatar`, via `AvatarView`).
  The avatar is the live status indicator: idle, listening, thinking, replying, all set, has an update
  (`AgentLiveState`). States must come from real data.
- Agent Studio's avatar creator (`AvatarCreatorView`) keeps a pet look simple: pick one of the ten kit
  characters (Pinch, Aeria, Biscuit, Miso, Bolt, Rivet, Sage, Inky, Kit, Ember) or ten Bits (Bop, Blok, Wedge,
  Hexo, Drip, Tic, Puff, Boo, Bloom, Glim), then a colorway or main color, headwear (a Bit instead picks its eyes,
  mouth, top and cheeks), a tone-on-tone pattern, and an idle move. The characters come from `Design/AvatarKit`
  (edit `tools/build.py`, then run `tools/build.py` and `tools/export_native.py`); the app draws them natively
  from `Bighelp/Resources/AvatarKit.json`, acting out the agent's state (listening, thinking, waiting on you,
  talking, happy, sleeping) plus extra moves for its current work. The look is saved as the agent's avatar picture and as its
  chat companion.
- Menu, Hermes tools and Settings icons are bighelp's own line glyphs (`Design/Glyphs`, `BighelpGlyph`): a 24-pt
  grid, round 2-pt strokes and the brand's dot, with agents drawn as the orb with two eyes. Call sites still name SF
  Symbols; ones without a glyph fall back to the symbol. Edit `glyphs.py`, then run `export_assets.py`.
- Product type is SF Pro. Root screens use large titles; section captions are small, bold, letterspaced and muted.
- Attachments in a draft are one small glass tag above the message box, lined up with the field
  (`DraftAttachmentRail`): the count first, then the kinds ("4 attached · 3 photos, 1 PDF"), with photos leading a
  stack of up to three thumbnails. One photo says "1 photo"; one file shows its name and size. While photos or files
  are being read in it says "Adding 2 of 4…" and Send waits; one that couldn't be read says "1 didn't attach" with
  Try again, and Send waits for that too. Tap the tag for the sheet: open, remove or retry each one.

## Navigation and simplicity

iPhone is an agent home. The bottom bar is **Chat, Feed, Ideas, Goals, Files** (the Apps page), all for the selected agent;
it is always open and names each tab under its icon. In a chat, Chat is the lit tab and tapping it does nothing.
Chat opens that agent's latest chat with its live avatar big at the top: tap the avatar for its profile (This chat's
model and reasoning, then Activity, Approvals, Schedules, Identity), tap the name to switch agents or open a group
chat, and ☰ for everything else. ☰'s first screen fits without
scrolling: the host as one switcher row on top, then New chat (Group beside it), Agents, Projects, Kanban, Workflows,
Scheduled tasks, Usage and Settings, then Recent chats with See all. The Secure credential vault and Nerd Mode's folder
sit under More at the bottom.
Keep it that short: a new destination goes where people already look, not on the first screen. A tap on the
header's compose button starts a new chat with this agent right away; touch and hold picks agents: one is a 1:1
chat, two or more a group. On the chat list, New chat floats centered above the bottom bar, which keeps the
same width as on every other screen. The chat list (and the all-hosts view's All sessions) searches from the system
glass search bar along the bottom, like All agents; it matches titles and previews, and a scroll puts the keyboard away. Feed, Ideas, Goals and Apps keep the Chat tab's header: ☰, the avatar, New
chat and ⋯ (the agent's profile, then Files, Memory, Skills & tools and Scheduled tasks). The root's edge-swipe zones
start below that row, so its corner buttons always get the tap. The avatar reacts to what the agent is doing (thinking, writing code, browsing, making
images…), driven by the running tool (`AgentActivityKind`, shared with the island as `BighelpActivityPose`). On
phones with a Dynamic Island, the island names the work. In the app it grows into a stage
(`AgentActivityIsland` + `IslandStage`): the name and the work beside the camera, and underneath, the pet acting
it out (chasing a brain while thinking, code streaming from its laptop, fixing a computer, painting, paper
planes…). The status bar hides while it shows, and the app moves down (root `additionalSafeAreaInsets`) so nothing
is covered. Tap for a compact pill, touch and hold to open the chat. Settings › Chat › Agent in the Dynamic Island
turns it off. Outside the app the Live Activity shows the agent's picture and the same icon (the plugin sends only
a fixed category). Every phone chat uses this big-avatar header and keeps the tab bar under its message box (All
agents' chats excepted). Every chat has ☰ in the top left, like the other root screens; a chat opened from the
list, Agents, Feed or a task goes back to it with the edge swipe. Chat Info lives in ⋯ › People & Chat, and the line under
the name says "Updating…" while a chat reloads from Hermes. iPad works the same way, with no always-open sidebar:
☰ slides the menu in from the leading edge, and chats use the width of the screen. On Vision Pro bighelp always
starts in its own window. The tabs sit in a strip beside the window (`VisionTabOrnament`), clear of the system's
move and close controls under it; ☰ opens the menu as a column inside the window and the page beside it narrows
(`VisionSideMenu`). Everything you look at and pinch is at least 56pt, and Appearance › Transparency sets how much
of the room shows through the window. Titles and toolbar buttons use the app's ink in light mode, since the system
draws them white. The agent can also stand in the room as a 3D character in its own volume (Settings › In your
space): kit characters are sculpted from their own art like vinyl toys, round bodies with faces laid on them
(`SpatialAvatarSculpt`), with no backdrop, a real shadow, the same moods as in the app, and a slow look around.
It opens within reach; pinch it to make it hop, drag to turn it, and drag a corner of its volume to make it
bigger or smaller. It wears the Agent Studio headwear and pattern and plays the chosen moves. The avatar designer
shows the same 3D character beside its choices, with moods to try (listening, thinking, talking, happy, sleepy)
and See it in your room, which puts the look being designed into the room at full size. ☰ › More › Simple mode leaves just
the agent, with Open bighelp under it to come back. The avatar never opens by itself.

Widgets (`BighelpActivityShared`, rendered by the Live Activity extension) use the Colors picks through
`BighelpWidgetSnapshot` palettes and show real agent pictures (`BighelpActivityAvatarStore`). **Your Agent** is the
lead widget: the agent's face ringed while it works with a badge for the work, its latest Feed posts and Goals,
New chat, and Chat/Feed/Ideas/Goals links (`loopdy://agent/<tab>`); it also comes in Lock Screen sizes. Active
Chats, Scheduled Tasks, New Chat and Recent Chats share the same look. Tinted and Lock Screen modes fall back to
system styles. **Kanban** shows cards from the boards, filtered by board, status and agent and grouped by status,
agent or board; tapping a card opens it in the app. **Feed**, **Ideas** and **Goals** each show one board, for an
agent picked in the widget or Auto (the agent picked in the app). The app reads only the boards widgets are set to
(`BighelpWidgetBoardLoader`, a few agents at most) and the widget says so until it has. **Pinned Agents** is a
grid of faces with names under them, like contacts: Current Gateway shows the computer in use's pinned agents,
Multi Gateway every computer's (All agents' pinned row), with a small computer name under each when they're on
more than one. A tap opens that agent's latest chat or a new one (`loopdy://agent-chat?agent=…&host=…`), switching
computers first like All agents. Pictures are copied per agent and computer (`BighelpPinnedAvatarStore`), and a
computer called only by its address shows as "Computer 2". On Vision Pro the same widgets sit on a wall or table as glass,
without the Lock Screen sizes.

Apps: **Artifacts** lists what the agent made or changed lately, newest first, from one plugin request
(`files.recent`, plugin 2.15+): its `write_file`/`patch` history and deliveries plus new top-level files. It never
walks the whole workspace (a real one holds over a million files); older plugins get a shallow, bounded scan that
skips tooling folders and shows files as it goes. **Media** shows the pictures and videos the agent sent or
generated (`attachments.recent`), then pictures from its posts; tap one for the native preview.

The app icon badge means "something arrived while you were away": pushes set it, opening bighelp clears it
(`BighelpAppBadge`). The app never sets a count of its own, so it can't get stuck on items the user can't see.

**Apple Watch** is a remote for bighelp on the iPhone, in the same dark palette (lavender actions and your own
messages, Ember's mark). Home puts **Talk to** your agent first (dictate or type; replies are read aloud unless the
speaker button is off), then **Needs you** (approvals showing exactly what they're for, wider approvals asking
again; questions with their choices or a spoken answer), recent **Chats**, and the agent's **Feed, Ideas and Goals**
with each item's full text. Change agent sits at the bottom. **Open on iPhone** goes straight there when bighelp is
open, or taps through from a notification; Handoff offers it too. Anything too big for the Watch says to answer on
the iPhone.

**CarPlay** is voice only: opening bighelp in the car starts a new chat with the default agent and listens. The
car screen says Connecting, Listening, Thinking or Speaking, with End and Mute; Talk starts again.

Shortcuts run with bighelp closed, in the background or open. The app closes its host connection in the
background, so a Shortcut first proves the host answers (the agent list) and reconnects once if not.
In the Shortcuts app bighelp's actions sit under **Chat** (Ask an agent, New chat, Continue last chat, Open group
chat, Start voice chat), **Automation** (Run scheduled task now, Add Kanban task, Get computer status, Get Feed,
Ideas or Goals), **Navigation** (Open in bighelp) and **Agents** (Switch agent, Open agent). Ten of them are
ready-made Shortcuts, the most an app may have, with a tile per agent, scheduled task, group chat or place.
Actions that open a screen hand bighelp a `loopdy://` link, so they wait for the host like a widget tap.

Touch and hold a message (right-click on the Mac) for Reply: "Replying to Avery: …" sits above the message box with
✕ to cancel and is saved with the draft. The sent message shows the quote small above its bubble, also after the chat
reloads from Hermes, and the agent reads which message it answers (`ChatReplyQuote`; see
[Native chat transport](docs/NATIVE_TRANSPORT.md)).

Reactions use Hermes' own: the app saves them with `message.react`, and with Settings › Chat › "Agents see your
reactions" on (the host's `display.message_reactions`), Hermes tells the agent at its next turn. The app sends no
note or turn of its own. Agents tapback through the plugin's `bighelp_react_to_message`. A reply that is only a
silence marker follows Hermes' rules (`ChatSilentReply`), with one addition: after the agent reacted to the
person's message, a bare marker means the reaction was the whole reply, so it leaves no bubble and no warning.

Feed, Ideas and Goals start empty. They fill only when the user asks the agent for updates; the agent then posts
with the plugin's `bighelp_board` tool, often from a scheduled job it sets up. Feed posts and Ideas are Markdown, drawn
with chat's renderer (`MarkdownMessageView`): headings, lists, quotes, code and tables. Nothing runs on the user's AI
provider by itself. Every item has a long-press menu (and the same VoiceOver actions) with only what fits
it: thumbs up/down on Feed (a thumbs down may ask "Less like this?" with quick reasons, never required), "Turn
into a goal" and "Start a chat" on Ideas, done/active on Goals, and read/unread, Copy and Share everywhere. It ends
with the item's dismiss, which is also a swipe left on the item: **Clear** a Feed post, **Not now** for an idea
(the plugin remembers it), **Remove** a goal. Each hides with Undo (`BoardDismissAction`). The boards are Lists so
rows can swipe, and the root's right-edge New chat strip steps aside on them. New items carry a dot, and a dot on
the Feed, Ideas or Goals tab says something there is unseen. The agent reads the ratings and reasons before it
posts (plugin 2.19.0).
**Blueprints** (beside the page title, and in the empty state) are the 45 starter prompts from
bighelp.app/quick-start, bundled (`BoardBlueprints.json`), 15 per page in five topics. A tap opens a new chat
with that agent and the prompt in the message box to fill in its [brackets]; nothing runs until Send.
**Goals** shows Tracking (the active goals by category: Health, Relationships, Finance, Career, Interests,
Productivity, Other; "Nothing is being tracked yet" when empty), Done, then **Create a goal**: one row per
category with a +, which starts a chat asking the agent to plan a goal in that category (touch and hold for that
category's blueprints). Goals carry the category in the plugin (`native-agent-board-goal-categories-v1`); without
it every goal shows under Other and the page says to update the plugin.

**Projects** (☰ › Projects) are Hermes projects shown the way Claude shows them: cards with the project's emoji
and color, description and recent use; a project page with **New chat in this project**, its chats and its
folders. A chat started there runs in the project's folder (Hermes files chats by folder, and the project becomes
the current one). Folder and Git management stay in Settings › Hermes tools (Nerd Mode). 

**Usage** (☰ › Usage, above Settings) is the one place for what the agents use. Limits come first: each plan,
limit and balance the plugin finds (Choose hides one), with what the agents used through it in the range. With
several computers (All hosts on) a menu beside Choose shows the computer in use, another one, or All computers, where
each computer's plans sit under its own name; it changes only Limits and is remembered on the device. Then 7, 30
or 90 days of Hermes' own numbers (`/api/analytics/usage` and `/api/analytics/models`, per agent): estimated cost or
processed tokens per day as bars (tap one for its day), totals with the cache rate, when you use it (weekdays, and
hours with the plugin's `usage/activity`), and ranked rows by model, by agent and, with All hosts on, by computer.
Tap a row to chart it against everything else. Chat ⋯ › Usage and the context window open the same page; there is
no overlay or Settings copy. Subscriptions report no cost, so a host where nothing cost money opens on Tokens.
Share (top right, beside Refresh) sends the page as a PDF (paged, never cutting a card in two), a PNG (one tall
picture), a web page (one file, inline styles and SVG charts, nothing loaded) or a CSV (one table of full-precision
numbers: days, models, agents, computers, totals, limits), always light, in the range, Cost or Tokens and Limits
computers on screen, with every row listed and the date range and time it was made at the top.

**Kanban** (☰ › Kanban, above Scheduled tasks) is Hermes' Kanban plugin, shown only when the host has it. Five lanes
in plain words: Later (triage, to-do, scheduled), Ready (an agent picks these up next), Working (only Hermes starts
work, so nothing is dropped here), Needs you (blocked or waiting for review) and Done. Cards show who has them with
their avatar, a pulse while they work, and why they need you ("Has a question", "Ready for review", "Got stuck").
Drag a card to another lane (iPhone: onto a lane tab; every move is also in the card's long-press menu); moves show
at once and snap back with a plain reason if Hermes refuses. A card opens a sheet with Approve / Ask for changes,
Answer, Try again or "Give it to another agent", its thread, priority and agent. The board switcher, agent filter
and search sit at the top. New cards default to Later, which spends nothing; Auto plan and Start now say they use
the AI provider. On iPhone the board opens on Needs you as one lane at a time; iPad shows all five. Vision Pro opens
the board in its own glass window beside bighelp: look at a card, pinch and drag it, and it lifts toward you while
the lane under it lights up.

**Workflows** (☰ › Workflows, after Kanban) are the bighelp plugin's: stages that agents run one at a time on the
computer, with your sign-off at the end. The row shows only when the host's plugin has them
(`native-workflows-v1`) and never while All hosts is on; an older plugin gets "Update the bighelp plugin to use
Workflows". Home leads with the service line, then Waiting for you (Review or Later), Active runs (All runs), Your
workflows (Run, or Set up while a role has no agent) and Templates. Build the flow is a vertical list of stages
with the review loop drawn beside it; a stage opens its editor (Setup, Output, Limits) as a large sheet, and a stage
with the terminal says so in warning colors. Nothing runs until you tap Run. At regular width the workflow opens as
a read-only canvas with an inspector inside the page. A run shows each stage's time, Cancel and Try again; Sign-off
shows how the run got here, the reviewer's notes and the exact file (Read, or Changes from the last version), then
Ask for changes or Approve, stacked on iPhone and side by side on iPad. Approving names the file by a short
fingerprint (4f1c…9a2e) and never publishes anything: the file comes to you with Share and Save to Files. The Mac
shows all runs as a three-column monitor (runs with filters, the run, and an inspector). Token counts, attempts,
full fingerprints, the service's heartbeat and the events log are Nerd Mode only. Stage chats (source `workflow`)
stay out of Sessions, recents and widgets.

**All hosts** (the stack button beside ☰'s host switcher) turns home into one list of every agent on every
host, like Messages: pinned agents up top as big pictures with their name and role (no host name; touch and hold
to drag them into a new order, kept on this device across hosts), host filter chips, then each agent with its host's
name, its role and its latest chat, newest first. One big round New chat sits bottom right, above the search bar,
where a thumb rests. A tap opens that agent's own chat (☰ top left, the edge swipe goes back); if it's on another host, the app switches hosts
first while the list stays up. ☰'s recent chats, All chats and Scheduled tasks then list every host's, each with
its host's name. Screens that belong to one host (Settings, Agents, Projects, Kanban, the credential
vault, the folder, New group) ask which host first; Usage instead adds up every host, with a row for each; Settings' pop-up also leads with **Fleet settings**, one page
for every host: Update Hermes (each host's commits behind), Update bighelp Plugin (each host's version → the new
one) and Restart Hermes Gateway, all at once with each host's live status and its own Restart when it needs one.
Each host runs the same flows as its own System page (`HostOperationsStore`, `HostPluginUpdateModel`); hosts that
are offline or signed out say so and are skipped (`Bighelp/Fleet/FleetMaintenance.swift`). The tab bar hides, ☰ › All agents is home, and the button in the list's top bar
turns it off. Other hosts are read at most once a minute over their own saved sign-ins (`Bighelp/Fleet`); one
that can't be reached says so and keeps showing what it had last time. While it's on and the app is open, every
host stays connected, so a switch opens the agent's chat at once from the copy saved on the phone while that
host's details finish loading.

Group chats (Hermes hosted rooms / Bot Mode) live in the switcher, ☰ and Agents. Agents opens on the
**Pinned** agents: each shows its role under the name (one line, trailing off), or what it's doing when it's busy.
Touch and hold lifts an agent: drag it to reorder (the order is kept per host), or let go to see its actions.

**Settings** is one short list where every row opens one page: you, Assistants (default model, providers,
personalities), then Appearance, Chat, Voice and Notifications, then Hosts, Permissions, Apple
Watch, Companion pet and Help. Don't add sections that compete with these; add to the page a row already opens.
Settings › Default model leads with **Agent**: tap it for a rail of cards, one per agent (picture and name, the
chosen one filled with the accent, `BighelpRailCard`), and the page shows and changes that agent's own default.
Settings › Chat starts with **When bighelp opens**: Open on (Agents, Agents (multi), Last chat, Feed, Ideas, Goals,
Kanban, Projects; Last chat, the agent's latest chat, until you pick) and Start with (Automatic, the agent you used
last, or one of this computer's agents, kept per computer; Agents (multi) has none). It applies when the app starts,
not when it comes back; a link, widget or notification that opens the app wins, and Kanban or Projects where the
computer can't open them fall back to Last chat (`BighelpLanding`).
Host administration — files, gateways/messaging, plugins, MCP, memory, logs, activity — is hidden until **Nerd
Mode** is on, which adds a Hermes section at the bottom: **System** (Update Hermes with how many commits behind,
Restart Hermes Gateway, the plugin's Update button, then everything else folded away) and **Hermes tools** (the
searchable list of the host's tools). There's no separate Hermes Tools entry in ☰. Pages lead with the action
people come for (`BighelpActionRow`) and keep explanations to one line. **Hosts** lists your computers (the one in
use checked) and Add a computer; a computer's page leads with Use this computer, Rename and Sign in again, then its
plugin and notifications, with its address and access folded away and Remove at the bottom.

Nerd Mode (`settings.nerdModeEnabled`, also the `nerdModeEnabled` environment value) also gates technical detail
inside everyday screens: the chat ⋯ Advanced submenu, the chat Info sheet's visibility toggles and host details,
Project Changes, the context window (⋯ › Context window, between Model & reasoning and provider usage; nothing sits
above the message box for it) and the subagent rail, Skills/Workspace/Session rows in the + sheet, Agent
Studio's Advanced page and templates, the task editor/detail Advanced groups, and the extra sections on
Settings › Chat. Everyday controls must never live only behind it.

A chat's model and reasoning (`ChatModelSummaryRow`) show in the avatar's profile, at the top of Info and at the top of
the context pop-up, each with Change into Model & reasoning. Showing them reads the reasoning once, never while the agent
is replying. Deleting an agent stops its reply and clears its unsent drafts on this device instead of refusing; only a
group chat that includes it holds the delete back, by name.

Long instructions (an agent's SOUL, a personality) have an expand icon that opens them full screen
(`FocusedTextEditorButton` + `focusedTextEditor`). Edits go straight into the form; Done keeps them and Save saves the
form. Present that editor from the form's root: a full-screen cover hung on a list section header never got the
keyboard.

## Mac pointer and keyboard

The Mac app is used with a mouse and keyboard. These helpers (`BighelpPointer.swift`) change only the Mac;
iPhone, iPad and Vision Pro stay exactly as they are.

- **Click areas.** On the Mac a plain button takes clicks only where its label draws: a glyph's pixels, a line
  of text. Write `.bighelpPlainButtonStyle()` instead of `.buttonStyle(.plain)` (or
  `.bighelpPointerButtonStyle(.borderless)` and the like for other styles): the label's whole frame takes the
  click, grown to at least 28 points each way (`BighelpPointer.minimumTarget`, which follows the Button size), and
  lights up under the pointer. Inside a label or before `.onTapGesture`, `.bighelpPointer()` does the same. A
  `.contentShape` outside a Button changes what VoiceOver measures, not what takes the click.
- **Names.** Icon-only controls use `.bighelpIconLabel("New chat", shortcut: "⌘N")`: VoiceOver everywhere, a
  tooltip on the Mac. `.bighelpHelp` adds just the tooltip.
- **Toolbars.** An icon toolbar button takes clicks only on its glyph inside the glass: put
  `.bighelpToolbarIcon()` on the label's image.
- **Fields.** Form text fields take clicks only on their line of text. `.bighelpMacField()` on the `TextField`
  lets its row height take the click (the caret goes to the end) and uses bighelp's text size;
  `.bighelpMacFieldArea()` does it for a container with one field, like a search capsule.
- **Return and Esc.** Sheets close on Esc by themselves. A sheet's or dialog's main button gets
  `.bighelpDefaultAction()` so Return presses it (`.confirmationAction` placement doesn't); a Cancel that does
  more than close, and every full-screen cover, gets `.bighelpCancelAction()`.
- **Menus.** Every menu's label is at least 28 points each way (`BighelpMacMenuStyle`), so don't set another
  `menuStyle`. Actions behind a long press or a swipe also need a `.contextMenu` (right-click).
- **Hover.** The highlight shows in plain SwiftUI layouts: the tab bar, headers, cards, chips. List and Form
  rows, menus, toolbar items and views with a `.contextMenu` are UIKit on the Mac and don't report hover; they
  rely on their click area.
- **Keys.** ⌘N new chat, ⌘, Settings, ⌃⌘S sidebar, ⌘1–⌘5 the bottom bar's tabs (`BighelpMenuCommands`).
- **Sidebar.** A sidebar button sits in the title bar right after the window controls, as in Mail and Finder, so
  the sidebar opens and closes from every screen, including pages with no ☰. Drag the line between the sidebar
  and the page to make it narrower or wider (the page keeps at least 380 points); the width is remembered, and a
  double-click on the line goes back to the usual width.

## Protected behavior

The [Chat interaction contract](docs/CHAT_INTERACTION_CONTRACT.md) remains authoritative. Preserve the native recycling canvas, canonical ordering, retained draft and editor ownership, reader-controlled scrolling, live/history reconciliation, prepared model, grouped activity and explicit media/voice controls. Do not replace backend clients, authentication, notification delivery, profile ownership or saved data as a styling shortcut.

Existing host capability gates, uncertain outcomes, review/confirmation boundaries and optional permissions remain intact. Unsupported and inherited values must not masquerade as editable effective settings.

## Qualification and release

Record a disposition for each source surface, but never call declaration counts shipping-screen counts. Verify the running result and real controls, including both basic and advanced paths. Label fixture-only, host-backed and hardware-only evidence separately.
