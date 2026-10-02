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

## Navigation and simplicity

iPhone is an agent home. The bottom bar is **Chat, Feed, Ideas, Goals, Apps**, all for the selected agent.
Chat opens that agent's latest chat with its live avatar big at the top: tap the avatar for its profile (This chat's
model and reasoning, then Activity, Approvals, Schedules, Identity), tap the name to switch agents or open a group
chat, and ☰ for everything else. ☰'s first screen fits without
scrolling: the host as one switcher row on top, then New chat (Group beside it), Agents, Projects, Kanban, Scheduled
tasks and Settings, then Recent chats with See all. Provider usage, the Secure credential vault and Nerd Mode's folder
sit under More at the bottom.
Keep it that short: a new destination goes where people already look, not on the first screen. A tap on the
header's compose button starts a new chat with this agent right away; touch and hold picks agents: one is a 1:1
chat, two or more a group. On the chat list, New chat floats centered above the bottom bar, which keeps the
same width as on every other screen. Feed, Ideas, Goals and Apps keep the Chat tab's header: ☰, the avatar, New
chat and ⋯ (the agent's profile, then Files, Memory, Skills & tools and Scheduled tasks). The root's edge-swipe zones
start below that row, so its corner buttons always get the tap. The avatar reacts to what the agent is doing (thinking, writing code, browsing, making
images…), driven by the running tool (`AgentActivityKind`, shared with the island as `BighelpActivityPose`). On
phones with a Dynamic Island, the island names the work. In the app it grows into a stage
(`AgentActivityIsland` + `IslandStage`): the name and the work beside the camera, and underneath, the pet acting
it out (chasing a brain while thinking, code streaming from its laptop, fixing a computer, painting, paper
planes…). The status bar hides while it shows, and the app moves down (root `additionalSafeAreaInsets`) so nothing
is covered. Tap for a compact pill, touch and hold to open the chat. Settings › Chat › Agent in the Dynamic Island
turns it off. Outside the app the Live Activity shows the agent's picture and the same icon (the plugin sends only
a fixed category). Every phone chat uses this big-avatar header; only the Chat tab's first page has ☰ and the tab
bar, any other chat (from the list, Feed, a task) has Back. Chat Info lives in ⋯ › People & Chat, and the line under
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
(`BighelpWidgetBoardLoader`, a few agents at most) and the widget says so until it has. On Vision Pro the same widgets sit on a wall or table as glass,
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
into a goal" and "Start a chat" on Ideas, done/active on Goals, and read/unread, Copy, Share and Delete everywhere.
Delete hides with Undo. New items carry a dot, and a dot on the Feed, Ideas or Goals tab says something there is
unseen. The agent reads the ratings and reasons before it posts (plugin 2.19.0).

**Projects** (☰ › Projects) are Hermes projects shown the way Claude shows them: cards with the project's emoji
and color, description and recent use; a project page with **New chat in this project**, its chats and its
folders. A chat started there runs in the project's folder (Hermes files chats by folder, and the project becomes
the current one). Folder and Git management stay in Settings › Hermes tools (Nerd Mode). 

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

**All hosts** (the stack button beside ☰'s host switcher) turns home into one list of every agent on every
host, like Messages: pinned agents up top as big pictures with their name and role (no host name; touch and hold
to drag them into a new order, kept on this device across hosts), host filter chips, then each agent with its host's
name, its role and its latest chat, newest first. One big round New chat sits bottom right, above the search bar,
where a thumb rests. A tap opens that agent's own chat with Back; if it's on another host, the app switches hosts
first while the list stays up. ☰'s recent chats, All chats and Scheduled tasks then list every host's, each with
its host's name. Screens that belong to one host (Settings, Agents, Projects, Kanban, Provider usage, the credential
vault, the folder, New group) ask which host first. The tab bar hides, ☰ › All agents is home, and the button in the list's top bar
turns it off. Other hosts are read at most once a minute over their own saved sign-ins (`Bighelp/Fleet`); one
that can't be reached says so and keeps showing what it had last time. While it's on and the app is open, every
host stays connected, so a switch opens the agent's chat at once from the copy saved on the phone while that
host's details finish loading.

Group chats (Hermes hosted rooms / Bot Mode) live in the switcher, ☰ and Agents. Agents opens on the
**Pinned** agents: each shows its role under the name (one line, trailing off), or what it's doing when it's busy.
Touch and hold lifts an agent: drag it to reorder (the order is kept per host), or let go to see its actions.

**Settings** is one short list where every row opens one page: you, Assistants (default model, providers,
personalities), then Appearance, Chat, Voice, Notifications and Provider usage, then Hosts, Permissions, Apple
Watch, Companion pet and Help. Don't add sections that compete with these; add to the page a row already opens.
Host administration — files, gateways/messaging, plugins, MCP, memory, logs, activity — is hidden until **Nerd
Mode** is on, which adds a Hermes section at the bottom: **System** (Update Hermes with how many commits behind,
Restart Hermes Gateway, the plugin's Update button, then everything else folded away) and **Hermes tools** (the
searchable list of the host's tools). There's no separate Hermes Tools entry in ☰. Pages lead with the action
people come for (`BighelpActionRow`) and keep explanations to one line. **Hosts** lists your computers (the one in
use checked) and Add a computer; a computer's page leads with Use this computer, Rename and Sign in again, then its
plugin and notifications, with its address and access folded away and Remove at the bottom.

Nerd Mode (`settings.nerdModeEnabled`, also the `nerdModeEnabled` environment value) also gates technical detail
inside everyday screens: the chat ⋯ Advanced submenu, the chat Info sheet's visibility toggles and host details,
Project Changes, the token-context ring and subagent rail, Skills/Workspace/Session rows in the + sheet, Agent
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
