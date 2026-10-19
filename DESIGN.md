# bighelp native iOS presentation

## Authority and scope

The current authority is the **Noodle brand kit** (`BighelpBrand`, the Ember palette) and its blended direction:
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

- **The Noodle** (`BighelpNoodleMark`, `BighelpWordmark`) is one continuous Ember (#FF8A7A) stroke that writes a
  lowercase b and kicks out at the bottom left as a chat-bubble tail. It appears in chrome (root nav bars, icon,
  setup) and as the app's loaders, never as a chat participant and never in an agent color. In the wordmark the mark
  stands in for the b, then "ighelp" in the kit's outlined Nunito: ink by day, cream after dark. See **Noodle** below.
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
- The message box: + beside it, and one pill inside it at its end: voice mode (a waveform) while it's empty,
  Send once there's text, Stop while the agent works. No other microphone button. A long draft's expand
  button sits beside the box, so the pill never covers it.
- Attachments in a draft are one small glass tag above the message box, lined up with the field
  (`DraftAttachmentRail`): the count first, then the kinds ("4 attached · 3 photos, 1 PDF"), with photos leading a
  stack of up to three thumbnails. One photo says "1 photo"; one file shows its name and size. While photos or files
  are being read in it says "Adding 2 of 4…" and Send waits; one that couldn't be read says "1 didn't attach" with
  Try again, and Send waits for that too. Tap the tag for the sheet: open, remove or retry each one.

## Navigation and simplicity

iPhone is an agent home. The bottom bar is **Chat, Feed, Ideas, Goals, Files** (the Apps page), all for the selected agent;
it is always open and names each tab under its icon. In a chat, Chat is the lit tab and tapping it does nothing.
Chat opens that agent's canonical Bot Chat (the same conversation as Hermes Desktop's bot entry) with its live avatar big at the top: tap the avatar for its profile (This chat's
model and reasoning, then Activity, Approvals, Schedules, Identity), tap the name to switch agents or open a group
chat, and ☰ for everything else. ☰'s first screen fits without
scrolling: the host as one switcher row on top, then New chat (Group beside it), Agents, Projects, Kanban, Workflows
(where the computer's plugin has them or says why it can't run them; with All hosts on it asks which computer),
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
list, Agents, Feed or a task goes back to it with the edge swipe. A group chat's name opens its Chat Info. The line under
the name says "Updating…" while a chat reloads from Hermes, the agent's activity while it works, and otherwise the
chat's title when Settings › Chat › Session title is on (off by default; never "New chat" or "Bot Chat"). iPad works the same way, with no always-open sidebar:
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
more than one. A tap opens that agent's canonical Bot Chat (`loopdy://agent-chat?agent=…&host=…`), switching
computers first like All agents. Pictures are copied per agent and computer (`BighelpPinnedAvatarStore`), and a
computer called only by its address shows as "Computer 2". **Bots** shows one, two or four chosen bots (small,
medium, large) on a chosen gateway, on the plain page color: each bot's face (a Simple Bot shape standing free, a
photo in a circle, its default shape without a picture) over its name, and a tap opens its Bot Chat on that gateway.
The app writes every gateway's bots and faces into the app group (`BighelpBotsWidgetFeed`, the computer in use live
and the others from All agents), so the widget keeps them with bighelp closed. On Vision Pro the same widgets sit on
a wall or table as glass, without the Lock Screen sizes.

Apps: **Artifacts** lists what the agent made or changed lately, newest first, from one plugin request
(`files.recent`, plugin 2.15+): its `write_file`/`patch` history and deliveries plus new top-level files. It never
walks the whole workspace (a real one holds over a million files); older plugins get a shallow, bounded scan that
skips tooling folders and shows files as it goes. **Media** shows the pictures and videos the agent sent or
generated (`attachments.recent`), then pictures from its posts; tap one for the native preview.

The app icon badge means "something arrived while you were away": pushes set it, opening bighelp clears it
(`BighelpAppBadge`). The app never sets a count of its own, so it can't get stuck on items the user can't see.

**Apple Watch** is a remote for bighelp on the iPhone, in the same dark palette (lavender actions and your own
messages, the Noodle mark). Home puts **Talk to** your agent first (dictate or type; replies are read aloud unless the
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

Holding a message lifts the whole bubble and floats a reaction bar over it, like Messages' tapback: the six common
reactions in a solid pill (the raised surface; nothing under it shows through), then + for any emoji
(`ChatReactionBarProjection`, `ChatMessageMenuDriver`). The menu below has no React item. A tap reacts and closes the
menu; the person's reaction shows chosen and a second tap takes it away. The pill lifts with the bubble, so the system
fits both on screen and everything else stays under the menu's blur; the emoji sit in the bar's own pass-through
window over that pill (`ChatReactionBarOverlay`). The Mac, Vision Pro and VoiceOver get the
same reactions as the menu's first row of icons instead.

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
Tap a row to chart it against everything else. Chat ⋯ › Usage › Usage and the context window open the same page; there is
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
computer, with your sign-off at the end. The row shows when the computer's plugin has them (`native-workflows-v1`)
or lists them under `unavailable` with a reason; then the screen says in plain words why this computer can't run
them and what to do, never the code. Plugins with neither keep the row hidden. With All hosts on the row asks which
computer first, then opens that one's Workflows. An older plugin gets "Update the bighelp plugin to use Workflows".
Home leads with the service line, then Waiting for you (Review or Later), Active runs (All runs), Your workflows
(pinned first; Run, or Set up while a role has no agent) and Templates: Create from scratch on top, then Built-in
and Yours. Touch and hold a workflow for Open, Run, Pin or Unpin, Save as template and Archive; Archived workflows
at the end of the list opens the archived ones, each with Unarchive. Touch and hold one of your templates to delete
it. Save as template (also in a workflow's ⋯) asks for a name and keeps the stages and inputs, not who does each
role. Editing the flow, Create from scratch, your templates and pins need `native-workflows-edit-v1`; older plugins
show the flow as it is.

At compact width (iPhone, and any narrow window) a workflow is one vertical line of stages, so nothing is lost off
screen; places saved on the canvas don't apply there. Ways out that don't go to the stage below are drawn beside
the line, the review loop in gold. Touch and hold a stage for its menu (Edit, Add a stage after, Move up, Move down,
End the flow here, Delete); drag it up or down to reorder (the stages around its old place join up). A drag toward
the open menu picks from it, as everywhere in iOS, so Move up and Move down are there too. Drag a stage's port to another
stage to rewire it. + between stages and at the end adds an agent stage, a check, a decision or a sign-off; Inputs
(tap the Inputs card) adds and changes the fields a run asks for. A stage opens its editor (Setup, Output, Limits)
as a large sheet, and a stage with the terminal says so in warning colors. Nothing runs until you tap Run.

At regular width (iPad, Mac, Vision Pro) the workflow opens as a free canvas: a dotted grid you pan and pinch to
zoom (zoom in, zoom out and Fit at the bottom left), rounded node cards at their saved places with a port on each
edge, and curved wires between ports; a decision lists Pass and Changes as rows, each with its own port. Touch and
hold a node to see its menu, then drag to move it anywhere (the menu goes away as the drag starts; on the Mac just
drag it). Drag an output port, or a wire's end at a node, to another node to rewire. A new stage goes after the
selected one (or at the end of the flow) on a clean grid, never on top of another, and is wired in; after that the
person decides. Places save into `layout` and wiring into `next` and the decision's targets, a moment after the last
change. What's wrong (a stage nothing reaches, a loop that isn't a decision's changes, no end) shows plainly in a
card on the canvas and in red on the node, and the selected stage's details sit in an inspector inside the page.
A run shows each stage's time, Cancel and Try again; Sign-off
shows how the run got here, the reviewer's notes and the exact file (Read, or Changes from the last version), then
Ask for changes or Approve, stacked on iPhone and side by side on iPad. Approving names the file by a short
fingerprint (4f1c…9a2e) and never publishes anything: the file comes to you with Share and Save to Files. The Mac
shows all runs as a three-column monitor (runs with filters, the run, and an inspector); the computer's name in
the top bar stays on one line. Token counts, attempts, full fingerprints, the service's heartbeat and the events log
are Nerd Mode only, and runs on Hermes' fallback runner (which can't count tokens) show none rather than 0. Stage
chats (source `workflow`) stay out of Sessions, recents and widgets.

**All hosts** (the stack button beside ☰'s host switcher) turns home into one list of every agent on every
host, like Messages: pinned agents up top as big pictures with their name and role (no host name; touch and hold
to drag them into a new order, kept on this device across hosts), host filter chips, then each agent with its host's
name, its role and its latest chat, newest first. One big round New chat sits bottom right, above the search bar,
where a thumb rests. A tap opens that agent's canonical Bot Chat (☰ top left, the edge swipe goes back); if it's on another host, the app switches hosts
first while the list stays up. ☰'s recent chats, All chats and Scheduled tasks then list every host's, each with
its host's name. Screens that belong to one host (Settings, Agents, Projects, Kanban, Workflows, the credential
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
Project Changes, the context window (⋯ › Usage › Context window; nothing sits
above the message box for it) and the subagent rail, Skills/Workspace/Session rows in the + sheet, Agent
Studio's Advanced page and templates, the task editor/detail Advanced groups, and the extra sections on
Settings › Chat. Everyday controls must never live only behind it.

The chat's ⋯ menu has at most five rows: File changes when available, Model & speed, This chat, Usage and
Nerd Mode's Advanced. Model & speed contains Model & reasoning and Fast Mode. This chat contains Rename chat,
Compact, New Bot Chat (in an agent's Bot Chat), Chat files, Chat appearance and Edit this agent. Usage contains provider usage and Nerd Mode's Context window.
Existing technical controls stay in Advanced. Keep every level short enough to navigate without scrolling.
At accessibility text sizes, keep the full font size: the top level is Model & speed, This chat and More.
More holds File changes, Usage and Advanced; This chat groups Rename and Appearance under Settings, and
Advanced groups its visibility switches under Display. Omit secondary summaries and shorten redundant labels.

Fast Mode is explicit about scope: the chat menu changes only this chat; Settings › Default model changes the
selected agent's default for new chats. Fast Mode may cost more. Read the host's current value and verify saves;
unknown modes stay labeled as host-managed. A model/provider without verified support shows Unavailable and a
reason, not an effective On switch. A running reply locks chat speed changes just like model and reasoning.

Agent entries (including Agents → Message and All hosts) use the canonical Bot Chat resolver. New chat still
creates an ordinary conversation, and picking a saved chat still opens that exact conversation. A failed Bot Chat
lookup offers a retry rather than silently falling back to an unrelated chat; stale navigation results are ignored.

A chat's model and reasoning (`ChatModelSummaryRow`) show in the avatar's profile, at the top of Info and at the top of
the context pop-up, each with Change into Model & reasoning. Showing them reads the reasoning once, never while the agent
is replying. Deleting an agent stops its reply and clears its unsent drafts on this device instead of refusing; only a
group chat that includes it holds the delete back, by name.

Agents talking to each other (`hermes -p <agent> chat -q …`, `hermes peer dm`, `message_agent`, and the
messages and answers other agents send in) are one quiet centered line in the chat, not a tool step
(`ChatAgentTalkRail`): the agents' faces stacked, then "4 messages with Nova", "Asking Nova…" or, from the
plugin's `agents/talk` feed, "Nova is searching the web…". Back-to-back messages share one line. It stays
out of the finished-turn fold and shows with tool calls and reasoning hidden, because it's conversation. A tap
opens what they said as a short chat between them, with "What Nova did" from Nova's own chat. Simple Bot
mode draws the faces as marks. A `message_agent` message and its later answer are two lines, each where it
happened: "Asked Nova" and "Nova answered"; the delivery notice that only repeats the answer stays out. Hermes
runs some turns on its own (another agent wrote in, a background process finished), and other Hermes processes
write some messages, so neither streams here: the chat reads what Hermes saved when such a turn ends, and while
an answer is due. When another Hermes process runs the open chat (an agent another one asked, in its Bot Chat),
the plugin's `chat/activity` says so: the agent shows typing, with Stop (`chat/stop`, Ctrl-C to that process).
Settings › Assistants › Teamwork (opt-in, plugin `native-team-v1`) tells every agent who the others are and to
hand them the work their roles cover, without being asked.

An opened "Worked for…" fold shows its tools directly, never a "Called N tools" folder inside it.

A file in a chat opens in the native preview with Save and Share. A Markdown file opens rendered
(`MarkdownMessageView`, as chat messages are), with a Preview and Raw switch under its name.

Compacting (⋯ › Advanced › Compact, or Hermes on its own when the context fills) shows `ChatCompactionRail` above the
message box: a chip whose four-step bar moves once a second (still with Reduce Motion), then Compacted with the tokens
before and after for two seconds before it shrinks away. Hermes' own status starts and ends it.

Model & reasoning (`ChatSessionControlsPopover`) never makes people scroll for reasoning. The chosen model and the
reasoning slider (`BighelpReasoningSlider`: one notch per level, the fill covers the notches up to the choice) stay
at the top. Search and the filter chips (Pinned, Recent, then each provider) sit under them, and only the short list
of models scrolls. Picking a model or level changes nothing until Apply.

Long instructions (an agent's SOUL, a personality) have an expand icon that opens them full screen
(`FocusedTextEditorButton` + `focusedTextEditor`). Edits go straight into the form; Done keeps them and Save saves the
form. Present that editor from the form's root: a full-screen cover hung on a list section header never got the
keyboard.

## Simple Bot mode

An opt-in calm home (Settings › Experience › Simple Bot mode): just your bots and their chats. No tab bar
and no ☰. The page is white by day and black at night, your bubbles are black (ink after dark) unless you
picked a bubble color in Appearance, and buttons and tinted text are the page's ink (white after dark). The
text is SF Pro, as everywhere.

- **Home**: your circle top left opens Settings; search and + (New Bot, New Group Chat) top right. The
  primary bot (with a star) and pinned bots share the top, all the same size: one large, else two or three
  across, six at most in two rows. Only pins the top shows count toward the six, not the primary bot, hidden bots
  or ones this computer no longer has. Their marks blink now and then (never with Reduce Motion). Under them every
  other bot and each group chat, with the latest message and its time; a bot's role is a small gray label after
  its name. Rearrange (in each menu) turns the home into an arranging mode: Cancel and Save in the header, no
  menus, chats or blinking, and every bot and group chat drags into place, on top (the primary bot too) or in
  the list. Save keeps the order per computer (`SimpleBotsOrderStore`); a bot or group chat not placed yet leads
  the list, by its latest message. Hidden bots stay off the home; search's filter shows them.
- **Touch and hold** a bot: its latest message, then Mark Unread (kept on this device), Pin, Replace
  Primary Bot… or Make Primary Bot, Rearrange, and More (profile, new chat, routines, then Hide at the bottom).
  A group chat's menu has Mark Unread and Rearrange.
- **Marks**: thirteen shapes in eleven colors with two white eyes (`SimpleBotMark`). Picking one in a
  bot's profile or in Create New Bot saves it as the bot's picture on its computer, so every screen,
  device and Hermes Desktop shows it, and drops a character or pet drawn over the picture. A bot that
  already has a picture, character or pet keeps it until a mark is picked; one with none starts on a
  mark made from its ID.
- **Chat**: Back, the bot's name (its profile) and ⋯; no New chat button. Voice is a bar over the chat, under
  its header (`SimpleBotVoiceBar`), and the chat stays in use: the bot's face, a visualizer from the real audio
  levels (your voice in the page's ink, the bot's in its color, dots while nobody speaks), voice choices (live
  or TTS, the bot's voice on or off), the microphone and End.
- **Swipes**: from the left edge back to your bots; from the right, this bot's profile (the primary bot's on
  the home). The full app's swipe choices lead to places this mode hides, so they don't apply here.
- **Profile**: the mark, name and role, then Info (Character, Instructions, Default Model, Routines) and
  Computer (its screen, when the host has one). More avatars opens the full avatar studio (`AvatarCreatorView`)
  with the marks as its Bots section; Save applies the pick at once. Default Model is the model and reasoning
  picker, saved as the bot's default for chats.
- **Settings**: you and Usage (your tightest plan limit); Connect apps; the primary bot's Auto-review
  (Hermes' smart approvals on, manual off; never off), its rules, and the time zone every bot works in
  (or this device's, automatically); Teamwork; Bot Computer; Notifications and Appearance; then the
  switch back and All Settings.

## Bighelp IDE

An opt-in second home for coding (Settings › Bighelp IDE; Bighelp Chat stays the default). Its home is the
Launchpad: filter chips (All, Running, Needs you, Ready), one card per session (a still status dot, its name, its
branch in code type, what it's doing now) and a message box pinned at the bottom in place of the bottom bar. Under
the box, three chips choose the project, where it runs (New worktree, the default, or Local checkout) and the
branch; they stay set, so each send starts the next session at once and adds its card. Inside the box, the agent's
face, a model chip (model, reasoning, fast mode; a long name truncates, never the buttons beside it) and a mode
button (Default, Plan, YOLO) set what new sessions run on. A card opens the session's ordinary
chat, where steer, queue and approvals work as in every chat; it has no bottom bar while Bighelp IDE is the home.
Touch and hold a card (right-click on the Mac) for Changes: uncommitted files, then the branch's commits, and Ship
(commit, push, pull request). ☰ keeps one menu: a Bighelp Chat / Bighelp IDE switch on top, then Sessions, Projects, Pull
requests, Worktrees, Kanban and Settings. Nothing animates on the cards.

Orchestration mode: Stage (beside Send; an icon once something is staged) keeps the message, with the chips as
they are, in a tray over the box, and Send all with its count starts them all as one batch. A batch is one card
on the home with a line per session, and opens one chat for all of them: colored pills (each opens that session's
own chat), your messages on the right, and under each one every session's answer in a single block. `#` lists
the batch's sessions, then the project's open pull requests; the chip and a line over the box say who gets it.

Dev Factory (☰ › Dev Factory in Bighelp IDE): coding recipes across projects. Its home lists what runs now
(one card per start, a line per project), the recipes (projects as small code chips, a Run button), then the
templates new recipes start from. A start's screen has one card per project: its step track, what it does now
in the computer's own words, and only the buttons it needs (Approve and Look at changes, Try again, the pull
request). A recipe shows its projects, where runs work and its steps; Run asks for its inputs and projects.

Markdown files open rendered, never as raw text: from Changes (a Preview tab beside the diff) and from paths in an
IDE chat's messages, which are links. Edit shows the text; Save asks before replacing a file that changed meanwhile.

### Lists over the message box

The `/` list (every chat, and the IDE's message box) and the `#` list share one look (`BighelpSuggestionList`): one
header line (filters or a title, the match count), then rows of an icon, the name after its `/` or `#` in the
action color, one line of detail, and a small capitals tag (SKILL, COMMAND, NEEDS YOU, OPEN). The list takes the
room between the top bar and the message box, up to about eight rows (about five with the iPhone keyboard up), and
shrinks to fit a short list. Hold a row (right-click on the Mac) for its details.

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

## Noodle

The kit's 19 motions ship as its Lottie files (`Resources/Noodle`) and are drawn natively (`BighelpNoodleView`,
no Lottie library): at most 30 frames a second, only on screen, and the still mark with Reduce Motion, in Low Power
Mode and in the background. The loader gallery (`-bighelp-loader-gallery`, Noodle) shows each one. Where they play:

| Motion | Where |
|---|---|
| loader | Anything loading: every indeterminate `ProgressView` (`BighelpNoodleProgressStyle`, set at the app's root), `BighelpSpinner`, the chat's active tool folder |
| thinking | Reasoning: the chat's active thinking row, a folder between calls, voice while the agent works |
| listening, talking, resting | The voice pill: the microphone is open, the agent speaks, the call is paused or muted |
| launch | Connecting (host setup, the connection pill, live voice), restoring a session |
| spring | Reconnecting |
| lasso | Searching (models, skills, chats) |
| infinity | Helper agents running in the chat's active folder |
| squiggle | Sending from the message box |
| question | A page that can't open, voice that isn't available |
| exit | Ending a voice call |
| reveal, then hello | The first run's welcome |
| idle | Empty places (no agents yet) |
| done | An IDE session or a Dev Factory run that finishes while you watch (`bighelpNoodleMoment`) |
| heart | Pinning a favorite model |
| bunny | Three taps on the wordmark under Settings › Help & feedback |
| pull | Pull to refresh (`bighelpRefreshable`): its frames follow the pull, then the loader plays |

**The chat plays one loader at a time**: on its newest live tool folder or thinking row
(`ChatCanvasTranscriptProjection.activeLoaderID`, `BighelpActivityLoaderFocus`). Every other row, and each tool step
inside a folder, stays still.

## Protected behavior

The [Chat interaction contract](docs/CHAT_INTERACTION_CONTRACT.md) remains authoritative. Preserve the native recycling canvas, canonical ordering, retained draft and editor ownership, reader-controlled scrolling, live/history reconciliation, prepared model, grouped activity and explicit media/voice controls. Do not replace backend clients, authentication, notification delivery, profile ownership or saved data as a styling shortcut.

Existing host capability gates, uncertain outcomes, review/confirmation boundaries and optional permissions remain intact. Unsupported and inherited values must not masquerade as editable effective settings.

## Qualification and release

Record a disposition for each source surface, but never call declaration counts shipping-screen counts. Verify the running result and real controls, including both basic and advanced paths. Label fixture-only, host-backed and hardware-only evidence separately.
