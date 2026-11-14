# bighelp native iOS presentation

## Authority and scope

The current authority is the **Noodle brand kit** (`BighelpBrand`, the Ember palette) and its blended direction:
1a "Messages, evolved" structure, in the **Ink** look the Bots view started (#622): white by day, black at night, ink
controls in the person's own color. Cream ("Center stage") and Graphite ("After dark") stay as page choices.
The app is a simple messaging experience for personal assistant agents. Earlier bighelp/iOS 27 Builder references
are historical (`docs/ui-v3-design.md`).

In anything a person reads (the name under the icon, copy, alerts, widgets, permission prompts, the plugin's
messages), the app's name is **Bighelp**, with a capital B (`BighelpBrand.appName`). Values that are stored or sent
stay lowercase: the session source `bighelp`, settings keys, IDs, the `window.bighelp` bridge, URLs and domains
(bighelp.app). The Noodle's lowercase b is the logo, not the name.

## Simplicity means hierarchy, not concealment

- Use concise, distinct headers and coherent sections. Group by the person's task, not the code's store or transport boundaries.
- Keep basic options visible and directly editable. Many visible options are appropriate when their grouping makes sense.
- Distinguish advanced options clearly. Do not put every setting behind another menu or create a page per setting.
- Remove repeated headings, instructions that merely restate a control, oversized identity introductions and routine implementation explanations.
- Preserve user-authored names, instructions, content and saved settings. Summarizing a row is not permission to truncate its stored data.
- Keep consequences for credentials, recipients, spending, destructive changes and uncertain saves at the relevant decision. Simplification must not conceal them.
- Aim for understanding setup and ordinary chat in roughly 30 seconds. This is a comprehension target, not a measured authentication-time promise.
- A Settings row's title is the thing, in one to three words. Its second line is the control's value; a hint only when the title can't carry it, six words at most (`settingTitle`, `settingLabel`).
- A section has a sentence-case header, two to seven rows where it can, and one footer of one sentence. Longer detail goes behind a tap on the row (Device access's info button), never under it.
- Advanced groups come last on the page they belong to, with the header "Advanced" or "Advanced · <name>", and show only with Advanced options (`settings.nerdModeEnabled`) on. The setting's code name is still Nerd Mode; people read Advanced options.

## Visual language

- **The Noodle** (`BighelpNoodleMark`, `BighelpWordmark`) is one continuous Ember (#FF8A7A) stroke that writes a
  lowercase b and kicks out at the bottom left as a chat-bubble tail. It appears in chrome (root nav bars, icon,
  setup) and as the app's loaders, never as a chat participant and never in an agent color. In the wordmark the mark
  stands in for the b, then "ighelp" in the kit's outlined Nunito: ink by day, cream after dark. See **Noodle** below.
- **Ink** is the default look, the one the Bots view always had: Classic's Paper page (#FFFFFF) by day and Black at night,
  black bubbles by day (dark gray #3A3A3F after dark), and buttons and tinted text in the page's ink. Its switches
  are green, since an ink switch would be white on white after dark. Every control that acts (New chat, the
  selected tab, buttons, chips, row icons) takes the color picked in Appearance (`theme.action` and
  `theme.actionForeground`), never a fixed color, just as the bubbles do. Feed, Ideas and Goals color their content
  with `BighelpBlockColor` (lime, lilac, sky, peach, and a deep green for what's new today); those are content
  colors, like an agent's mark, not controls. All of this lives in `BighelpTheme` so screens read theme tokens, not
  system colors.
- Settings › **Appearance** (`AppearanceStudioView`) is the one place for the look: a live light/dark preview,
  Color scheme (System, Light, Dark, each a small phone in the picked themes), Themes, Agent messages, Bubble
  color, Text and buttons, and Chat layout. Its Color scheme row and Themes grid follow T3 Code's Appearance
  screen (MIT; credit in `Bighelp/Resources/ThirdParty-NOTICES.txt`).
  - **Themes** (`BighelpThemePreset`) is a grid of cards, each with a light orb and a dark orb. Tapping an orb
    picks that theme for that mode, so light and dark can come from different themes; the picked orbs carry
    the accent ring and a sun or a moon. At the largest text sizes each card takes a whole row. Classic (Paper
    #FFFFFF and Black #000000, the default) and Warm (Cream #FFF9F5 and Graphite #1C1C1F) are bighelp's own
    pages and keep your bubble color. Steel, Berry, Moss, Harbor, Clay and Violet set the page, cards, text,
    muted text, borders, the agent message color and an accent together; their palettes come from
    `Scripts/theme-presets.py`. A theme fills the light and dark background settings people already had, so
    the old values (cream, paper, graphite, black) still mean the same pages. High contrast keeps its own
    pages over any theme.
  - **Bubble color**: 12 colors (`BighelpBubbleColor`: Ink, the default and saved as no choice, first; Lavender
    is Ember's own violet), Custom, and Theme, shown when a picked theme has an accent: your bubbles and buttons
    then take each mode's theme accent. Picking a theme with an accent selects Theme; picking any other color
    replaces it. First-run setup offers the same bubble colors (`AppearanceBubbleGrid`).
  - **Agent messages** (`ChatAgentMessageStyle`): Bubble, the default, or On the page, where agent replies sit
    on the page at the chat lane's full width with no fill, border or bubble padding. Your own messages keep
    their bubble; cards, tool rows, files and link previews keep their own surfaces. The choice is in
    `ChatCanvasRowContext`, so a change draws the rows again once.
- Agents are organic blobs and glossy orbs in their own palette color (`AgentPersonaAvatar`, via `AvatarView`).
  The avatar is the live status indicator: idle, listening, thinking, replying, all set, has an update
  (`AgentLiveState`). States must come from real data.
- Edit avatar opens a choice: **Bot Studio** or **PetDex**, with "Use a photo instead" under them
  (`AvatarChooserView`). Bot Studio (`BotStudioView`) is one editor for every avatar: the avatar fills the top
  and plays its move, with Undo and Surprise me; a drawer below shows one row of choices at a time, picked from
  the rail (Body, Eyes, Color, Shape, Moves), so no choice pushes the others off screen. On Body, a swipe up on
  the row (or a tap on the drawer's handle) opens every body in a grid, by set, with the avatar small above it;
  the handle or another tab shows one row again. Every body is drawn in
  one style: one flat main color, tilted, two small slanted eyes up and to the right, and at most a small
  second-color part (`services/avatars/docs/BOT_BODIES.md`). PetDex opens the creator with only pets.
- The older avatar creator (`AvatarCreatorView`) keeps a pet look simple: pick one of the ten kit
  characters (Pinch, Aeria, Biscuit, Miso, Bolt, Rivet, Sage, Inky, Kit, Ember) or ten Bits (Bop, Blok, Wedge,
  Hexo, Drip, Tic, Puff, Boo, Bloom, Glim), then a colorway or main color, headwear (a Bit instead picks its eyes,
  mouth, top and cheeks), a tone-on-tone pattern, and an idle move. The characters come from `Design/AvatarKit`
  (edit `tools/build.py`, then run `tools/build.py` and `tools/export_native.py`); the app draws them natively
  from `Bighelp/Resources/AvatarKit.json`, acting out the agent's state (listening, thinking, waiting on you,
  talking, happy, sleeping) plus extra moves for its current work. The look is saved as the agent's avatar picture.
- Every surface draws an agent's face in one order (`AgentFace`): its kit character, its petdex pet, its Hermes face
  or shape (the look Hermes keeps in its profile, drawn live and played with the avatar designer's states), its
  mark, then its picture. Each agent's pet companion is that same face (`AgentPet`); Settings › Appearance ›
  Companion pet holds only Show pet companion, Pet size and Adventurous Pet.
- Menu and Settings icons are bighelp's own line glyphs (`Design/Glyphs`, `BighelpGlyph`): a 24-pt
  grid, round 2-pt strokes and the brand's dot, with agents drawn as the orb with two eyes. Call sites still name SF
  Symbols; ones without a glyph fall back to the symbol. Edit `glyphs.py`, then run `export_assets.py`.
- Product type is SF Pro. Root screens put a bold title (Today, Work) or the Bots | Chats switch in the home header; section captions are small, bold, letterspaced and muted.
- The message box: + beside it, and one pill inside it at its end: voice mode (a waveform) while it's empty,
  Send once there's text, Stop while the agent works. No other microphone button. Once a draft has three
  lines, a small, quiet rail shows centered above the box: the expand icon and "Expand", in a glass pill
  (`ComposerExpandRail`). It opens the expanded editor. Its touch area is the full hit target, reaching into
  the gaps around the pill, and it never changes the box. The text uses the box's full width.
- Links in a chat open where they belong (`ChatLinkRoute`): Maps, Music, the App Store, Podcasts, TV, Books and
  News links in those apps, any other link in an installed app that claims it, and only web pages in the browser
  picked in Settings › Chat. A card's Directions opens Apple Maps, never a map website.
- Object cards look like Apple's own: a music card leads with the item's real artwork, large and rounded like a
  Music cell (round for an artist), on a wash of the artwork's color, with the kind, title and artist beside it;
  a place card leads with a still map of the spot (`BighelpCardMapPicture`, light or dark with the app) that
  opens Maps; a contact shows the saved person's photo when Contacts already allows it, else their initials.
  Artwork comes from MusicKit when Music is allowed, else Apple's public lookup and search with a name match
  (`BighelpCardMusicLookup`), kept in memory and Caches; until then, and when there is none, a quiet tile with
  the kind's symbol. Showing a card never asks for a permission.
- Photo drafts: ask an agent to save a business card or event poster you sent, and it answers with a draft card
  (the photo, the name or title, what to check, Review). The review is a sheet with the photo on top, every field
  editable, an app-owned box of what to check (Missing, Check, Guess, You changed beside each field), where it goes
  (iOS's own pop-up menu of accounts or calendars, or the default one until bighelp may list them), anything already
  saved that looks like it (read only), and Discard and Save in the bar. The agent's review note sits at the top as
  its quote. After a decision the same card says what happened. Each agent's Photo actions page (in What it can use on a
  bot's profile) sets the offer, how to read each kind, the question for unclear pictures and the review messages,
  with Preview and Reset to defaults ([Image drafts](docs/IMAGE_DRAFTS.md)).
- Agents' apps: an app an agent made is a card in the chat, never its page: an icon tile in the action color, the
  title, the agent's description, small "Sends answers" and "Live data" tags, and a full-width Open App. Open App
  covers the screen: Done, the title with "Live, updated 2:14 PM" under it for an app with data, a ••• menu with
  Reload, and the page. When the page sends an answer, a panel rises from the bottom with the exact message, Cancel
  and Send; nothing goes until Send ([Agents' HTML apps](docs/HTML_APPS.md)).
- Attachments in a draft are one small glass tag above the message box, lined up with the field
  (`DraftAttachmentRail`): the count first, then the kinds ("4 attached · 3 photos, 1 PDF"), with photos leading a
  stack of up to three thumbnails. One photo says "1 photo"; one file shows its name and size. While photos or files
  are being read in it says "Adding 2 of 4…" and Send waits; one that couldn't be read says "1 didn't attach" with
  Try again, and Send waits for that too. Tap the tag for the sheet: open, remove or retry each one.

## Navigation and simplicity

bighelp is one home with three places and no modes. The bottom bar is the same for everyone: **the first tab, Today and
Work**, with the round New chat button beside it. The first tab shows the Bots view or the Chats view and takes the name
of the person's default view; the header's Bots | Chats switch changes the view for this run. The bar is always open and
names each place under its icon; the current one is a pill in the picked color, and a dot on Today means something
needs you. New chat is a round button in the picked color. The bar shows on roots only and goes while the keyboard is
up: a pushed page, a chat included, has Back and no bar. The app opens on Settings › Chat › Opens on (Bots, Chats,
Today or Work), when it starts and not when it comes back, and a link, widget or notification that opens the app wins.
No chat opens by itself.

Every root draws the same header and no navigation bar, so nothing moves between places: the person's circle at the
left, which opens Settings (iPhone has no menu and no sidebar); in the middle the Bots | Chats switch, or the title
(Today, Work); at the right search, the computer menu (Today and Work, with two or more computers), the place's own
control (Today's Edit) and +. When the switch or the title doesn't fit beside the buttons (large text), it takes a row
of its own. The root's edge-swipe zones start below that row, so its corner buttons always get the tap.

**Bots** is one row per bot and group chat (Bots view, below). **Chats** is every chat on every computer in one list,
newest first, Pinned on top, then Today, Yesterday and Earlier, with search over it and one row of chips: All, Unread
and, with two or more computers, one for each. Touch and hold a chat for Pin, Mark read or unread, Rename and
Archive; only the computer in use's chats pin or mark read, while another computer's rename and archive. A chat with
something new since it was last read has a bold title and a dot after its time, and a chat whose message box holds
an unsent message shows Draft before its preview. Chats › This computer opens that computer's own Sessions page:
its projects, imports from other apps and one bot's chats. There, with Settings › Chat › Projects in the chat list on
(on by default, saved on each device), a chat in a project shows the project's name on a line of its own under the
preview, never beside it, so the preview stays whole at large text; a list grouped by project leaves it out. The
row's menu shows the chat's project beside Move to Project…, and the move sheet lists that project first, then the
rest by name. Projects sorts by Recently used or Name, saved on the device. Where the computer keeps read state, the
row's menu and leading swipe have Mark Read and Mark Unread.

**Today** is a grid of panels under the header: Needs you on top while something waits (a card with the count and the
first entry, which opens the Needs you deck), the Shared with bighelp card while a share waits, then the person's
panels in three sizes (Small, Wide, Tall), and a Make a space box below them that starts a chat with a bot to draft
one. One panel holds Feed, Ideas and Goals for every bot (See all opens a page with a chip for each bot); each space
is a panel of its own ([Spaces](docs/SPACES.md)). Edit turns the grid into a list where each panel is moved, hidden
and sized; hidden panels come back from there. **Work** is one list of what the bots are doing, each row from the
store that holds it: coding sessions, chats and background work running now, workflow runs, Kanban tasks and
scheduled tasks. Chips filter it: All, Needs you, Working, Done. Four doors lead on: Projects, Tasks (Kanban),
Workflows and Schedules, each only where the computer has it. Today and Work show the computer in use; with two or
more computers the header's computer menu switches it. A project's page is Work filtered to that project, with Back,
its name and ⋯ (pull requests, worktrees, Dev Factory).

**New chat** is the new chat's own screen: the ordinary chat with a To row under Back and ⋯, where the bot's name
would be. Picked bots are chips, and a field filters the list of bots and group chats over the empty messages. One
bot is a chat, two to six are a group chat, and a group chat the person already has can be picked at the end of the
list. With nobody picked the message box is the primary bot's; picking another single bot makes it that bot's. For one
bot on a computer that can run coding sessions, one row under the message box scrolls sideways and never wraps:
Project (none is an ordinary chat), then, once a project is picked, where it runs (a new worktree or local), the
branch, the mode (Default, Plan, YOLO) and Stage. A project makes Send start a coding session, which Work lists;
Stage keeps the message as a job, and Send all starts the staged jobs as one batch. A group chat and a coding
session take text only, so + offers no attachments for them. The To row, the list and the choices row leave once the
first message is sent.

A chat is a pushed page with one header: Back, the bot (its face and name; a tap opens its bot page) and ⋯. Tapping a
bot on the Bots view opens what Settings › Chat › A bot opens says: its ongoing Bot Chat (the same conversation as
Hermes Desktop's bot entry), your last chat with it, or a new chat; Ask and Needs you open the Bot Chat. A group
chat's name opens its Group Settings (Chat Info for a group Hermes doesn't run). The line under the name says the
agent's activity while it works, and otherwise the chat's title when Settings › Chat › Chat title is on (off by
default; never "New chat" or "Bot Chat"). The bot page is the same for every bot from every door: a chat's header,
Bot Profile in a bot's menu, a bot chip on a Today board.

iPad at regular width works the same way, with a sidebar behind a button in the header: it slides in from the
leading edge, and chats use the width of the screen. The sidebar lists the three places, Settings, New chat, recent
chats (See all opens Chats) and More: Needs you while something waits, Shared with bighelp while a share waits, and
Usage. The Mac and Vision Pro keep that sidebar open as a column beside the page.

A bot's face reacts to what the agent is doing (thinking, writing code, browsing, making
images…), driven by the running tool (`AgentActivityKind`, shared with the island as `BighelpActivityPose`). On
phones with a Dynamic Island, the island names the work. In the app it grows into a stage
(`AgentActivityIsland` + `IslandStage`): the name and the work beside the camera, and underneath, the pet acting
it out (chasing a brain while thinking, code streaming from its laptop, fixing a computer, painting, paper
planes…). The status bar hides while it shows, and the app moves down (root `additionalSafeAreaInsets`) so nothing
is covered. Tap for a compact pill, touch and hold to open the chat. Settings › Chat › Dynamic Island
turns it off. Outside the app, one Live Activity holds the active chats as compact rows: title, agent and a
fixed status icon. Chats needing attention come first. Each row opens its own chat; extra chats show as a count.
The expanded Dynamic Island shows three rows, while the compact island keeps a quiet work or attention symbol.

The iPhone Duo follows how it's held (`BighelpScreenPosture`). Folded, the cover screen is wide and short, with the
camera and status in a column on its trailing edge: the places go down that column as iOS's own toolbar items
(`HomeStripTabs`), under the screen's own buttons, which iOS moves there too, so chats get their height back, and
a chat's column holds the chat switcher instead (`BighelpChatSwitcher`: the bots on top of the Bots view, or a coding
session's other sessions, each with its live state; Settings › Chat › Chat switcher, on by default there and opt-in on
iPad and Mac in landscape). Open and held wide, the first tab's list (the Bots view or the Chats view) sits left of the
fold and what it opens sits right of it, like a book (`BighelpSplitColumn`); nothing crosses the fold. Held upright
it's a big phone, never the cover screen's layout, and half-folded like a small laptop a chat keeps its messages
above the fold and its message box and keyboard below it. Half of the open screen in iOS's Split View gets the cover
screen's layout. On Vision Pro bighelp always starts in its own window. The three places sit in a strip beside the
window (`HomeTabOrnament`), clear of the system's move and close controls under it; the sidebar opens as a column
inside the window and the page beside it narrows. Everything you look at and pinch is at least 56pt, and Appearance › Transparency sets how much
of the room shows through the window. Titles and toolbar buttons use the app's ink in light mode, since the system
draws them white. The agent can also stand in the room as a 3D character in its own volume (Settings › In your
space): kit characters are sculpted from their own art like vinyl toys, round bodies with faces laid on them
(`SpatialAvatarSculpt`), with no backdrop, a real shadow, the same moods as in the app, and a slow look around.
It opens within reach; pinch it to make it hop, drag to turn it, and drag a corner of its volume to make it
bigger or smaller. It wears the Agent Studio headwear and pattern and plays the chosen moves. The avatar designer
shows the same 3D character beside its choices, with moods to try (listening, thinking, talking, happy, sleepy)
and See it in your room, which puts the look being designed into the room at full size. The sidebar's More › Simple mode leaves just
the agent, with Open bighelp under it to come back. The avatar never opens by itself.

Widgets (`BighelpActivityShared`, rendered by the Live Activity extension) use the Colors picks through
`BighelpWidgetSnapshot` palettes and show real agent pictures (`BighelpActivityAvatarStore`). **Your Agent** is the
lead widget: the agent's face ringed while it works with a badge for the work, its latest Feed posts and Goals,
New chat, and Chat/Feed/Ideas/Goals links (`loopdy://agent/<tab>`); it also comes in Lock Screen sizes. Active
Chats and Recent Chats keep working chats ahead of replies, show compact title/status rows with agent pictures,
and mark stale status as Updates paused without removing the chat. Their links retain the correct gateway.
Scheduled Tasks and New Chat share the same palette. Tinted and Lock Screen modes fall back to
system styles. **Kanban** shows cards from the boards, filtered by board, status and agent and grouped by status,
agent or board; tapping a card opens it in the app. **Feed**, **Ideas** and **Goals** each show one board, for an
agent picked in the widget or Auto (the agent picked in the app). The app reads only the boards widgets are set to
(`BighelpWidgetBoardLoader`, a few agents at most) and the widget says so until it has. **Pinned Agents** is a
grid of faces with names under them, like contacts: Current Gateway shows the computer in use's pinned agents,
Multi Gateway every computer's (the Bots view's pinned row), with a small computer name under each when they're on
more than one. A tap opens that agent's canonical Bot Chat (`loopdy://agent-chat?agent=…&host=…`), switching
computers first, as the Bots view does. Pictures are copied per agent and computer (`BighelpPinnedAvatarStore`), and a
computer called only by its address shows as "Computer 2". **Bots** shows one, two or four chosen bots (small,
medium, large) on a chosen gateway, on the plain page color: each bot's face (a Simple Bot shape standing free, a
photo in a circle, its default shape without a picture) over its name, and a tap opens its Bot Chat on that gateway.
The app writes every gateway's bots and faces into the app group (`BighelpBotsWidgetFeed`, the computer in use live
and the others from their all-hosts copies), so the widget keeps them with bighelp closed. **Usage** shows each plan's limits as
the plugin reports them, for the gateway in use or a chosen one. Each size lists only its own styles: small (Ring,
Two meters, What's left, Four plans, Closest to limit), medium (One plan, Every plan, Next resets, Side by side),
large (Every plan, One plan), extra large (a column per plan), Cost and tokens in the first three, and the Lock
Screen (a line over the clock, a gauge, and a rectangle with one plan, every plan or the next reset). Automatic
picks one plan or several by what there is. A share turns amber at 80% used and red at 100%, and a used-up limit
shows a lock and the countdown to its reset in every style. Logos come from `ProviderLogos.xcassets` and each
provider's color shows in full color only; tinted, clear and Lock Screen looks draw one ink, so meters and locks
carry the meaning. It shows only what Hermes and the plugin report: no pace, no daily share of a limit, no API-rate
value. On Vision Pro the same widgets sit on a wall or table as glass, without the Lock Screen sizes.

**Media** (a bot page's tab) shows the pictures and videos the agent sent or generated (`attachments.recent`), then
pictures from its posts; tap one for the native preview.

The app icon badge means "something arrived while you were away": pushes set it, opening bighelp clears it
(`BighelpAppBadge`). The app never sets a count of its own, so it can't get stuck on items the user can't see.

**Apple Watch** is a remote for bighelp on the iPhone, in the same dark palette (lavender actions and your own
messages, the Noodle mark). Home puts **Talk to** your agent first (dictate or type; replies are read aloud unless the
speaker button is off), then **Needs you** (approvals showing exactly what they're for, wider approvals asking
again; questions with their choices or a spoken answer), recent **Chats**, and the agent's **Feed, Ideas and Goals**
with each item's full text. Change agent sits at the bottom. **Open on iPhone** goes straight there when bighelp is
open, or taps through from a notification; Handoff offers it too. Anything too big for the Watch says to answer on
the iPhone.

**CarPlay** is voice first: opening bighelp in the car starts a new chat with the agent from Settings › Voice › In the car
(else the last one picked in the car, else the default) and listens. The home shows that agent's face, what it's
doing in one line and its last steps, with Talk (and End while you talk), and the other agents under it. Talk, or
tapping the agent you talk to, opens the voice screen: a new conversation, or back to the one that's on. The voice
screen shows the face in a ring that moves with Connecting, Listening, Working and Speaking, with End, Agents and
Mute. If the computer doesn't answer, it says which step failed instead of connecting forever.

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

The same menu's Share… (after Copy) opens one sheet (`ChatMessageShareSheet`): pick Messages, Markdown, Plain text or
PDF (the last pick is kept), see exactly what goes out, then Copy or Share…. Messages styles bold, italics and code
with Unicode letters for apps that show no Markdown, with a note that some apps and screen readers can't read them;
the PDF is named for the agent ("Message from Avery Park.pdf"). The converter is `ChatMessageExport`.

Holding a message lifts the whole bubble and offers the six common reactions, then a + More reactions row for any emoji
(`ChatReactionBarProjection`, `ChatMessageMenuDriver`). Reactions are the native menu's first row of icons on every
platform, so UIKit fits them and the actions together even beside a screen-height message. A tap reacts and closes
the menu; the person's reaction shows chosen and a second tap takes it away. A chosen custom emoji gets its own row,
so UIKit never clips a seventh palette item. + waits for the menu to close, then
opens Apple's emoji keyboard; choosing one emoji reacts immediately. There is no custom emoji grid. Mac and
Vision Pro use their system text input for that same choice.

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
with the item's dismiss: **Clear** a Feed post, **Not now** for an idea (the plugin remembers it), **Remove** a goal.
Each hides with Undo (`BoardDismissAction`). An item with a List row of its own also dismisses with a swipe left
(Feed's Earlier rows, goals, and tiles at accessibility text sizes); tiles two to a row share one, so theirs is in
the menu only. The root's right-edge New chat strip steps aside on the boards. New items carry a dot, and a dot on
the Feed, Ideas or Goals tab says something there is unseen. The agent reads the ratings and reasons before it
posts (plugin 2.19.0).
The boards are **color blocks** (`BoardBlocks.swift`): the agent's face and name on the page with no backing, then
items as rounded tiles in a pastel (`BighelpBlockColor`, the same color for the same item or category every time)
with dark ink on them. **Feed** leads with what's new in a deep green block (only while something is new), the
newest posts as tiles two to a row, then Earlier as rows in a card. **Ideas** has chips by the agent's sections
over a tall newest idea with **Let's do it** beside two short ones, then the rest as tiles. A tile opens the item
on a tap and its menu on a long press (`Menu(primaryAction:)`; a ⋯ on the Mac). Buttons and chips on the blocks
take the person's color (`theme.action`).
**Blueprints** (beside the page title; an empty Feed or Ideas shows three as starters) are the 45 starter
prompts from bighelp.app/quick-start, bundled (`BoardBlueprints.json`), 15 per page in five topics. A tap opens a
new chat with that agent and the prompt in the message box, each of its [brackets] a chip to fill in (dashed
until filled, a row over the box for the one in hand); Send waits for them, and nothing runs until Send.
Every template picker (Blueprints, Agents' Browse all, New Bot's Templates) is one list by topic: the search row,
topic chips under it (All, My Templates when there are some, then each topic that has templates, with its icon), a
section per topic with its icon and count, and Sort in the top bar (For you; Newest and Most used rank everything
in one list; bighelp only when the catalog has community ones). My Templates come first. Topics are the catalog's
`category` with fixed names and order (`TemplateCategory`); one the app doesn't know is Other, never hidden. New
agent's Templates rail has the same chips over it. A search that finds nothing says so, with Search all when a
chip narrowed it.
**Goals** shows Tracking (the goal the agent touched last in a block of its category's color with **Mark done**,
then the other active goals by category in a card: Health, Relationships, Finance, Career, Interests,
Productivity, Other; "Nothing is being tracked yet" when empty), Done, then **Create a goal**: one row per
category with a +, which starts a chat asking the agent to plan a goal in that category (touch and hold for that
category's blueprints). Goals carry the category in the plugin (`native-agent-board-goal-categories-v1`); without
it every goal shows under Other and the page says to update the plugin.

**Projects** (Work › Projects) are Hermes projects shown the way Claude shows them: cards with the project's emoji
and color, description and recent use; a project page with **New chat in this project**, its chats and its
folders. A chat started there runs in the project's folder (Hermes files chats by folder, and the project becomes
the current one). With Advanced options on, a project's ⋯ menu has Folders and Git for the folder and Git pages. 

**Usage** (the first group of Settings, and the sidebar's More) is the one place for what the agents use. Limits come first: each plan,
limit and balance the plugin finds (Choose hides one), with what the agents used through it in the range. With
several computers (Show every computer on) a menu beside Choose shows the computer in use, another one, or All computers, where
each computer's plans sit under its own name; it changes only Limits and is remembered on the device. Then 7, 30
or 90 days of Hermes' own numbers (`/api/analytics/usage` and `/api/analytics/models`, per agent): estimated cost or
processed tokens per day as bars (tap one for its day), totals with the cache rate, when you use it (weekdays, and
hours with the plugin's `usage/activity`), and ranked rows by model, by agent and, with Show every computer on, by computer.
Tap a row to chart it against everything else. Chat ⋯ › Usage › Usage and the context window open the same page; there is
no overlay or Settings copy. Subscriptions report no cost, so a host where nothing cost money opens on Tokens.
Share (top right, beside Refresh) sends the page as a PDF (paged, never cutting a card in two), a PNG (one tall
picture), a web page (one file, inline styles and SVG charts, nothing loaded) or a CSV (one table of full-precision
numbers: days, models, agents, computers, totals, limits), always light, in the range, Cost or Tokens and Limits
computers on screen, with every row listed and the date range and time it was made at the top.

**Kanban** (Work › Tasks) is Hermes' Kanban plugin, shown only when the host has it. Five lanes
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

**Workflows** (Work › Workflows) are the bighelp plugin's: stages that agents run one at a time on the
computer, with your sign-off at the end. The door shows when the computer's plugin has them (`native-workflows-v1`)
or lists them under `unavailable` with a reason; then the screen says in plain words why this computer can't run
them and what to do, never the code. Plugins with neither keep the door hidden. An older plugin gets "Update the bighelp plugin to use Workflows".
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
are Advanced options only, and runs on Hermes' fallback runner (which can't count tokens) show none rather than 0. Stage
chats (source `workflow`) stay out of Sessions, recents and widgets.

**Show every computer** (Settings › Your computers, on until turned off) puts every computer's bots and chats in the
Bots view, the Chats view and New chat's list of bots, like Messages with several accounts: each chat says which
computer it is on, and the Chats view's chips filter by computer. A tap on another computer's bot or chat makes that
computer the one in use first, while the list stays up (the Bots view shows the Noodle loader, with Cancel, until the
bot opens). Today and Work show the computer in use, and their header's computer menu switches it. Usage instead adds
up every host, with a row for each. Settings' Your computers group also has **Update every computer** (with two or
more), one page for every host: Update Hermes (each host's commits behind), Update bighelp Plugin (each host's
version → the new one) and Restart Hermes Gateway, all at once with each host's live status and its own Restart when
it needs one. Each host runs the same flows as its own computer page (`HostOperationsStore`,
`HostPluginUpdateModel`); hosts that are offline or signed out say so and are skipped
(`Bighelp/Fleet/FleetMaintenance.swift`). Other hosts are read at most once a minute over their own saved sign-ins
(`Bighelp/Fleet`); one that can't be reached says so and keeps showing what it had last time. While it's on and the
app is open, every host stays connected, so a switch opens the agent's chat at once from the copy saved on the phone
while that host's details finish loading.

Group chats (Hermes hosted rooms / Bot Mode) live in the Bots view and the Chats view. A group's **Group Settings**
(`GroupSettingsView`, a pushed page any screen can open: `AppRoute.groupSettings`) shows its name and "3 bots",
its members' faces with a small Lead badge on the lead, then, where Hermes keeps settings for the room
(`groups.state` has `context`): WHEN A MESSAGE NAMES NOBODY, three radio rows with a hint each (Everyone answers;
Pick who answers, only where the room's runtime runs it; A lead passes it on, with the lead's name and a chevron to
the member list) and the note that @mentions and @everyone go straight to the bots you name; and WHAT EVERY BOT
KEEPS IN MIND, a one-line Purpose and Shared notes with a counter ("212 of 4,096"). Changes save as they're made
and when the page closes; an edit Hermes doesn't save stays with the reason, Try again and Discard changes. A
group Hermes doesn't run shows only its name and members. New Group Chat offers the same choice and a Purpose.
In the chat, Hermes' picks are one quiet centered line ("Pixel gave this to Scout", "Assigned to Scout and
Echo", "Couldn’t choose who answers, so everyone will"), the header says "Lead: Pixel" under the name, and a
discussion Hermes paused at its cap is a small card ("Paused after 10 messages.") with Continue and Stop until
something moves it on or it has used every Continue.

**Settings** is one short list where every row opens one page, and the person's circle in every root's header opens
it. The first screen has you (name and photo), Usage and, while a
share waits, Shared with bighelp; **Your bots** (Models, Apps & skills, Voice, Personality and the Teamwork
switch); **This app** (Appearance, Chat, Notifications); on Vision Pro, In your space; **Your computers**
(one row per computer, Add a computer, Show every computer, Time zone and, with two or more computers, Update
every computer); then Help & feedback and the Advanced options switch. Don't add sections that compete with these;
add to the page a row already opens (Help & feedback also holds Share usage and diagnostics, on by default, and
the Apple Watch's status).
Settings › Models is the AI providers first, then **Default model** with one row per bot (its face, its name and
its model under it); a row opens that bot's own Default Model page, the one its profile opens. Advanced comes last.
Settings › Chat reads in named groups: **Opening**, **A bot's work**, **In a chat** and **Chat list**, then the
Advanced groups. Opening has Opens on (Bots, Chats, Today, Work; Chats until you pick), First tab shows (Bots or Chats, only
when Opens on is Today or Work) and A bot opens (Its ongoing chat, Your last chat, A new chat). It applies when the
app starts, not when it comes back; a link, widget or notification that opens the app wins.
**Apps & skills** (Settings › Your bots) is for everyone: This device (Device access) first, then Apps (Built-in
apps and Composio), Skills and plugins (with this week's featured plugin, the pick Hermes' marketplace and Desktop
show), Talk anywhere (Messaging apps) and Logins (the credential vault); with Advanced options on, an Advanced group
adds MCP servers and Toolsets. Each bot's profile has its own **Marketplace** with the same pages for that bot, and
its own Connections. A bot's profile also lists **Core Files** (SOUL.md, USER.md, MEMORY.md and the AGENTS.md Hermes
loads for its chat, each opening in the Markdown viewer to read or edit) and **Active Project** (the project its new
chats start in, a checked list). Host administration is hidden until
**Advanced options** is on, and each part sits on the page it tunes: a computer's page, Chat, Models, Apps & skills
and a bot's Advanced Options. There is no Hermes tools list and no System page. Pages lead with the action people come
for (`BighelpActionRow`) and keep explanations to one line. **Your computers** lists each computer (the one in use
says so) and Add a computer. A computer's page leads with Use this computer, when it isn't the one in use, then
Updates (Hermes and the bighelp plugin, with how far behind each is), Restart (messaging and the dashboard), This
computer (its name, AI providers and notifications), Access (its address and Sign in again), the Advanced groups
(Messaging, Upkeep and Setup: logs, backups, diagnostics, webhooks, tool backends, config.yaml, shell hooks,
Kanban boards and the computer voice test) and, last, Remove this computer.

Advanced options (`settings.nerdModeEnabled`, also the `nerdModeEnabled` environment value; the code name is still Nerd Mode) also gates technical detail
inside everyday screens: the chat Info sheet's visibility toggles and host details, a background command's output,
Skills/Session rows in the + sheet, Agent Studio's Advanced page and templates, the task editor/detail Advanced groups, and the extra sections on
Settings › Chat. Everyday controls must never live only behind it.

The chat's ⋯ menu is one list, the same with Advanced options on or off: New Bot Chat in an agent's Bot Chat; then This chat (a group chat's Group Settings and Chat info, where its members are, Rename…, Move to Project… with
the chat's project, Files, and File changes when available); then Model (Model & speed, Usage); then More (Bot
page, Advanced). Model & speed contains Model settings and Fast Mode. Usage contains provider usage, Context
window and Compact. Existing technical controls stay in Advanced. The groups have lines between them, not titles:
iOS keeps a menu under about 60% of the screen's height, and titles made the list scroll. Keep every level short
enough to navigate without scrolling, File changes included (`CompactChatMenuUITests`). iOS draws the menu at the
device's text size, not bighelp's, and the whole list fits at the default size; from the device's XL, keep the full
font size and fold the top level into Model (Model & speed), This chat (Rename…, Move…, Files; a group's Chat
info), Agent (New Bot Chat, Bot page) and More (File changes, Usage and Advanced). At accessibility
sizes, Advanced also groups its visibility switches under Display, and secondary summaries are left out and labels
shortened.

Move to Project… (`MoveChatToProjectSheet`) also sits in a chat's hold menu on a computer's Sessions page,
wherever the computer can move chats (`sessionWorkspaceEdit`). It lists the agent's
projects with a tick on the chat's own, and moves the chat only once Hermes confirms it; then Chats, the open
chat and File changes show the new project. Chats have no backgrounds of their own: Settings › Appearance sets the
look of every screen.

Fast Mode is explicit about scope: the chat menu changes only this chat; Settings › Models › Default model changes the
selected agent's default for new chats. Fast Mode may cost more. Read the host's current value and verify saves;
unknown modes stay labeled as host-managed. A model/provider without verified support shows Unavailable and a
reason, not an effective On switch. A running reply locks chat speed changes just like model and reasoning.

Agent entries (including the Bots view and Show every computer) use the canonical Bot Chat resolver. New chat still
creates an ordinary conversation, and picking a saved chat still opens that exact conversation. A failed Bot Chat
lookup offers a retry rather than silently falling back to an unrelated chat; stale navigation results are ignored.

A chat's model and thinking level (`ChatModelSummaryRow`) show at the top of a chat's Info and at the top of
the context pop-up, each with Change into Model settings. Showing them reads the level once, never while the agent
is replying. Deleting an agent stops its reply and clears its unsent drafts on this device instead of refusing; only a
group chat that includes it holds the delete back, by name.

Agents talking to each other (`hermes -p <agent> chat -q …`, `hermes peer dm`, `message_agent`, and the
messages and answers other agents send in) are one quiet centered line in the chat, not a tool step
(`ChatAgentTalkRail`): the agents' faces stacked, then "4 messages with Nova", "Asking Nova…" or, from the
plugin's `agents/talk` feed, "Nova is searching the web…". Back-to-back messages share one line. It stays
out of the finished-turn fold and shows with tool calls and reasoning hidden, because it's conversation. A tap
opens what they said as a short chat between them, with "What Nova did" from Nova's own chat. A `message_agent` message and its later answer are two lines, each where it
happened: "Asked Nova" and "Nova answered"; the delivery notice that only repeats the answer stays out. Hermes
runs some turns on its own (another agent wrote in, a background process finished), and other Hermes processes
write some messages, so neither streams here: the chat reads what Hermes saved when such a turn ends, and while
an answer is due. When another Hermes process runs the open chat (an agent another one asked, in its Bot Chat),
the plugin's `chat/activity` says so: the agent shows typing, with Stop (`chat/stop`, Ctrl-C to that process).
Settings › Teamwork (opt-in, plugin `native-team-v1`) tells every agent who the others are and to
hand them the work their roles cover, without being asked.

An opened "Worked for…" fold shows its tools directly, never a "Called N tools" folder inside it.

A tapped tool call unfolds as one block (`ChatToolBlockView`): what the agent asked for on top, what came back
under a line, never JSON. Short values share one line ("notes.md · Limit 200"), and text keeps its line breaks,
cut short with View full. Copy and Show raw (Hermes' own input or result) sit under the block. There are no
Summary, Input and Result boxes. Code it ran (Hermes' `execute_code`, Python, and `terminal`, Shell) unfolds as one notebook cell
(`ChatToolCodeCellView`): the language with Copy and full screen, the code with line numbers and colors, folded
after 10 lines behind Show all, then under a line in the same card what it printed, with a dot for how it ended
(Output, or Exit code 1 in red) and its own Copy. View raw under the card opens Hermes' own input or result.

Settings › Chat › Shows as (`ChatWorkStyle`) picks how one-to-one chats show an agent's work; group chats
keep their folders. **Card** (the default): while the agent works, one soft card says who's working, how long and
how many steps, with its newest four steps under that, older ones fading out at the top (`ChatLiveWorkView`).
While the answer streams it says what the agent did, still; when the turn ends it becomes a card above the
answer that says what the turn did ("Read 2 files, ran tests"), with "18s · 4 steps" on a small line under it.
A turn with no steps to name says "Worked for 18s". **One line**: one line with the
current step and the agent's newest note under it; when the turn ends, a small "18s · 4 steps" receipt sits under
the answer (`ChatWorkReceipt`). **Everything**: every note, tool call and thought shows in place and open as it
happens, then folds under "Worked for…". A tap on the card, line or receipt lists every step under it, each its
own row. The agent's notes between steps go with Show thinking; Show thinking (on by default) and Show tool
calls decide what's in the work, and Fold finished turns (off) leaves finished work open in the chat.

Settings › Chat › Thinking (`ChatReasoningPlacement`) picks where a one-to-one chat puts its agent's
thinking. **Above the work** (the default): one outlined message above the turn's work
(`ChatReasoningMessageView`), so the steps hold only tool calls. It's outlined, never filled, so it doesn't read
as the answer. While the agent thinks it says "Reasoning…" over the newest words; once the turn's thinking is
done, "Thought for 12s" over all of it, cut at six lines with Show more. **Between steps**: thinking rows between
the tool calls, as before. Keep thinking open (on by default) keeps finished reasoning's words in view in both;
off, it closes to one line. A tap on the heading opens or closes it, and the reader's choice wins over the
setting. Group chats keep reasoning in the steps.

A chat's ••• › Files (`ChatFolderBrowserView`) shows the chat's working folder on the computer. A path field on
top shows any other folder when Return is pressed (a full path, a `~` path, or a name inside the folder on
show); beside it, the folder above and the working folder. Under a search field, the folder is a tree with
folders first: a tap opens a folder in place, and its names are read then. Search finds names in every folder
opened so far and says where each one is. Names that start with a dot stay behind one line under the tree
("Show 12 hidden items"), or a search that starts with a dot. A tap on a file pushes it: Markdown rendered, other text as it is in
monospace with Copy, a picture fitted to the page. Nothing here changes a file but the Markdown viewer's own
Edit. A group chat's Files lists the files in its messages.

A file in a chat opens in the native preview with Save and Share. A Markdown file opens rendered
(`MarkdownMessageView`, as chat messages are), with a Preview and Raw switch under its name.

Compacting (⋯ › Usage › Compact, or Hermes on its own when the context fills) shows `ChatCompactionRail` above the
message box: a chip whose four-step bar moves once a second (still with Reduce Motion), then Compacted with the tokens
before and after for two seconds before it shrinks away. Hermes' own status starts and ends it.

Model settings (`ChatModelSettingsSheet`) is a short sheet: the chat's model, the Thinking control, how full the
context window is and, when the model has it, Fast Mode. The context window is one meter with plain words
("34% used", "Plenty of room left"), in the warning color from 85%, and it shows only once Hermes reports the
window. Advanced options swaps the words for the token counts and makes the line open the Context page. The model chip in the message box opens it (the provider's mark and a chevron, before the
microphone), and so do ⋯ › Model & speed and Change beside a chat's model. Every choice is sent as it's made; there
is no Apply, and a refused choice falls back with the reason on top. The model row opens All models
(`ChatAllModelsView`): search, Starred, then one folding section per provider with its plan, a star on every model
and the model in use filled in. The chat's own provider starts unfolded. A failed turn's Use another model opens
All models directly.

The Thinking control (`BighelpThinkingControl`, `Bighelp/DesignSystem/ThinkingSlider/`) works as hermex's Thinking
slider does: a tap on the track or a level's name picks it, a sideways drag follows the finger with a tick per level
and sends one change on release, a vertical swipe scrolls the sheet, VoiceOver adjusts it, the Mac's arrow keys step
a level, and the largest text sizes get a plain list. Hermes' automatic level is the Auto button beside the value,
not a point on the track. It wears one of six looks of our own (`BighelpThinkingLook`: Noodle, Train of Thought,
Clockwork, Meadow, Ink Bloom, Wide Awake), picked in Settings › Appearance › Thinking, where each can be tried.
A look's colors climb with the level (Noodle and Train of Thought turn from the person's color toward its opposite)
and every look stands still at the lowest level. These drawings repaint while they show, which bighelp avoids
everywhere else: at most 60 frames a second, only on screen, never under Reduce Motion, and paused once the control
rests at the bottom.

Long instructions (an agent's SOUL, a personality) have an expand icon that opens them full screen
(`FocusedTextEditorButton` + `focusedTextEditor`). Edits go straight into the form; Done keeps them and Save saves the
form. Present that editor from the form's root: a full-screen cover hung on a list section header never got the
keyboard.

## Bots view

The first tab's calm view: just your bots and their chats (the default for people who pick "With a bot" at first run;
the header's switch moves between it and Chats). The page is the light and dark theme picked in Appearance, your
bubbles are black (ink after dark) unless you picked a bubble color in Appearance, and buttons and tinted text are the
page's ink (white after dark). The text is SF Pro, as everywhere.

- **Home**: the home header (your circle top left, the Bots | Chats switch, then search, a round button that opens a
  search page, and +). + is a short menu: New Bot, New Group
  Chat and New Section, each only where it can work (a computer that can't make group chats leaves New Group Chat
  out). The primary bot (no badge), pinned bots and pinned group chats (up to three of their members' faces) share
  the top, all the same size: one large, else two or three across, six at most in two rows. Only pins the top
  shows count toward the six, not the primary bot, hidden bots or ones this computer no longer has. Their marks
  blink now and then (never with Reduce Motion). Under them, only once a section exists, a SECTIONS caption and a
  card for each section, two across (one at the largest text sizes): a 2 × 2 folder of its members' faces (a
  group chat as its members' faces together, all still), its name and how many are in it, and a dot while one
  is unread. Then every other bot and group chat in no section, with the latest message and its time; a bot's
  role is a small gray label after its name. Rearrange (in each menu) turns the home into an arranging mode: Cancel and Save in the header, no
  menus, chats or blinking, and every bot and group chat drags into place, on top (the primary bot too) or in
  the list. Save keeps the order per computer (`SimpleBotsOrderStore`), and on the computer too, so a reinstall or
  another device gets it back (`BotsAppStateSync`; on a computer whose plugin can't keep it, on this device only,
  and the Rearrange hint says to update the plugin); a bot or group chat not placed yet leads the list, by its
  latest message. Hidden bots and group chats stay off the home; search's filter shows them, with Show on
  Home.
- **Working and Needs you**: a bot whose Bot Chat is on a turn acts the work out on its face: a mark or kit
  character plays the mood for it (`AgentActivityKind.moodID`: scanning for code, looking around while it
  browses), a Hermes face or shape the designer's state for it (`hermesPlayState`), a pet its move. In the list,
  a line takes the place of its latest message ("Browsing the web…", "Working…"). A face that can't act it out
  (a photo, or any face with Reduce Motion or Low Power Mode) gets a still badge for the kind of work instead
  (a globe while it browses, in the page's ink). One waiting on you (an approval, a question) gets a raised hand
  in ember and "Needs you", which wins over working. A bot with no turn running but work in the background
  (subagents, background commands, a scheduled task, from any Hermes process) keeps a calm face with a still stack
  badge, and its row says "In the background: Preview server" in plain ink; a turn wins over it. It's only what
  the computer says (`BotChatActivityStore`): unknown or out of date shows nothing, and it clears when the work ends.
- **Touch and hold** a bot: its latest message, then New Chat, Pin (Unpin when pinned), Rearrange, Move to
  Section (each section, No section, New Section…), Mark Read/Unread (its Bot Chat's, on the computer; kept on this device where the
  computer keeps no read state), Bot Profile, a divider, and Hide. Actions stay in that order; the primary bot has no Pin or Hide. Primary selection stays in
  Chats settings, and Routines in Bot Profile. A group chat: its latest message, then Pin, Rearrange, Move to
  Section, Mark Read/Unread, Group Settings, a divider, Hide and Delete Group Chat (it asks first). A section's
  card: Open, Rename, Edit Members, Edit Sections, a divider, Delete Section.
- **Sections** are folders, like Home Screen folders. A card opens the section's page: Back, its name (and
  "On Home Mac and Studio Mac" when its members are on more than one computer), ⋯ (Rename, Edit Members, Delete
  Section), a big folder of faces, its members as home rows (their role line names the computer when the section
  spans several), then Add Bots or Group Chats. New Section and Edit Members are one sheet: the name, then every
  bot and group chat with a check (by computer with Show every computer; "In Work", or "Moves from Work" once picked).
  A bot is in one section at a time. Edit Sections (a card's menu, search's filter) renames, drags into order
  and deletes; Done keeps it all, and Delete asks first and keeps every member, in No section. With Show every
  computer on, a section holds any computer's bots and group chats; with it off (or one computer filtered) a
  section shows only that computer's members, and one with all its members elsewhere doesn't show. Bots' sections
  are Hermes Desktop's own field, so Desktop shows them too.
- **Marks**: thirteen shapes in eleven colors with two white eyes (`SimpleBotMark`), from before Bot Studio.
  A bot that has one keeps it until another avatar is saved; one with no picture, character or pet shows a
  mark made from its ID.
- **Create New Bot**: the bot's face with Surprise me on it, its name, a body from each of Bot Studio's sets
  (each as it comes) and More, eight colors (the body's own first) and Eyes, shape and moves. More and that row
  open Bot Studio over it, on Body or Eyes; its Done brings the look back. Templates, top right, fills in the
  role and instructions. Create saves the look as Edit avatar does: the picture on its computer and the Bot
  Studio look beside it (`SimpleBotCreation.use`).
- **Chat**: the one chat header (Back, the bot's name, which opens its bot page, and ⋯; see Navigation). The bot's
  work shows as Settings › Chat › A bot's work says, as in every one-to-one chat: the notes it writes on the way to
  its answer go with its steps, in order, and the answer always shows.
- **Dashboard** opens with **Activities**, one line ("2 running · 4 done today") until it's tapped, so Feed, Ideas
  and Goals stay where they were. Open, it lists the bot's subagents and background commands of the last seven days
  by day (Today, Yesterday, then weekdays), running first, each with how it went and when (`DashboardTodaySection`,
  plugin `native-agents-today-v1`). Routines (scheduled task runs) show only with ⋯ › Show routines, which the ⋯
  menu offers on the Dashboard tab and which is off by default. A tap on an item opens its read-out
  (`DashboardActivityDetailView`, plugin `native-agents-today-detail-v1`): a subagent's steps on a timeline (the
  time, a dot on a rail, what it did in plain words, in order) and its answer as formatted text; a command and its
  output, laid out to read; a routine run's status and its result, with the rest of the run's record behind Run
  details. It reads again every few seconds while the work runs. Templates open from an empty pile and from each
  pile's See all page.
- **Computer** (the profile's screen tab) also has **Your computer**: the computer's own desktop (macOS, Linux or
  Windows) through its own VNC server, bridged by the plugin (`native-computer-screen-v1`). Open your computer
  shows it in the same viewer as the agent's screen; Take control drives it, and the computer's screen sharing
  password is asked once and kept in this phone's Keychain. Without a VNC server it says how to turn one on. Pinch
  zooms whether watching or in control; zoomed in while in control, two fingers move the view.
- **Profile**: the mark, name and role over every tab (Dashboard too), then the tabs: Dashboard, Info, Computer (its
  screen, when the host has one), Files and Media. It is the same page for every bot, from a chat's header, a bot's
  menu or a Today board. ⋯ holds what is done to the bot: New chat, Chats with this bot, Pin, Use with Siri,
  Duplicate, Manage bots and Delete bot (Show routines is on the Dashboard tab). Info is in named groups: About
  (Name, Role and Summary, each edited in place, and the Handle, which is only read), Personality (Character,
  Instructions, Core Files), Defaults (Default Model, Default Voice, Active Project), What it can use (Connections,
  Marketplace, Credential Vault, Photo actions, Approvals) and Routines (Add routine first, then the bot's routines), with Advanced Options
  alone at the end. A group shows only the rows the computer offers. Holding a tab shows a glass bar above it with Set Default (the tab profiles open on;
  Dashboard until one is set; a note confirms it) and Rearrange (the tabs become glass chips to drag where they
  are, the tab below fades, Done in the header). Both are one choice for every bot (`SimpleBotProfileTabs`); the
  Mac also offers them on a right-click. Character is Info's first row, with the bot's face at its end; it opens Edit avatar at once
  (`AvatarChooserView`: Bot Studio, PetDex or a photo), and Save applies the pick at once. An avatar starts Calm:
  a move plays only once the person picks one, and Surprise me never adds one. Default Model is the
  model and reasoning picker, saved as the bot's default for chats. Default Voice picks this bot's Live or Take turns
  and its provider, model and voice from lists (saved per bot). Advanced Options is the bot's one simple doorway
  to its expert settings: plain rows with a tip each (Approvals: Smart, Manual or Off), and links to its
  Advanced pages under For experts, without Advanced options turned on.
- **Credential Vault** (a bot's Info, with how many websites; Settings › Apps & skills › Credential vault opens the same screens
  for any agent): the Wallet on top, a row of saved cards (small dark cards with their last digits) and addresses
  (gray tiles), each once however many websites use it; then Websites, each with its letter, its login and small
  icons for what's saved there; Password managers and Import from a file under them; Add a Website at the bottom.
  Add a Website is two steps: the website and three tiles to pick (Login, Card, Address), then their details with
  one Save. A card or address can be a saved one (its tile, ringed) or a new one; a saved one is copied on the
  computer, never typed again. If one part doesn't save, the others show Saved and only that part stays open, its
  fields kept. A website's page lists what's there, Add to this website and Remove this website; a card's or
  address's page shows its face, Used on (Stop beside each but the last) and Use on another website.
- **Settings**: the person's circle opens Settings (see Settings above).

## An agent showing the way

When the person asks where something is, the agent can open it (`iphone_navigation`). The look is
"Island and dock" (#662):

- **The bar** grows out of the Dynamic Island (a capsule at the top where there's none): the agent's
  mark beside the camera, then "{Agent} is driving" and the steps as a trail that lights as each one
  happens, and Return to chat. At the place it reads "{Agent} brought you here", with Stay here (✕).
  The camera's spot stays clear; the status bar hides while it shows.
- **The dock**: the chat steps aside into a card at the bottom (its picture shrinks into it). It
  shows the agent's newest words, still arriving, and the chat's own message box: a message sent
  there steers the running answer as Send does in the chat. At the place, the agent's note leads it.
- **Between them** the app runs edge to edge. One still dot moves to each control and presses it
  once; the drive ends on a still spotlight (the rest dims a little) around the place, scrolled into
  view if it was further down. Nothing loops. With Reduce Motion the screens cross-fade, there's no
  dot and no shrinking picture.
- Return to chat puts back exactly the tab and pages the person had; the chat's draft and place
  are its own and never change.

## Coding sessions

There is no Code mode. A coding session starts from New chat: pick one bot, pick a project in the choices row under the
message box, and Send starts it. Under the box the row's chips choose the project, where it runs (New worktree, the
default, or Local checkout), the branch and the mode (Default, Plan, YOLO); they stay set, so each send starts the next
session at once. The box's own model chip (model, reasoning, fast mode; a long name truncates, never the buttons beside
it) sets what the new session runs on. Work lists the sessions with the rest of the bots' work: one card per session
(a still status dot, its name, its branch in code type, what it's doing now), and a card opens the session's ordinary
chat, where steer, queue and approvals work as in every chat. Touch and hold a card (right-click on the Mac) for
Changes: uncommitted files, then the branch's commits, and Ship (commit, push, pull request). A project's page is Work
filtered to that project, with ⋯ for pull requests, worktrees and Dev Factory. Nothing animates on the cards.

Stage (the last chip) keeps the message, with the chips as they are, in a tray above the choices row, and Send all with its count starts them all as one batch. A batch is one card on Work with a line per
session, and opens one chat for all of them: colored pills (each opens that session's own chat), your messages on the
right, and under each one every session's answer in a single block. `#` lists the batch's sessions, then the
project's open pull requests; the chip and a line over the box say who gets it.

Dev Factory (a project's ⋯ on Work): coding recipes across projects. Its home lists what runs now
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
- **Keys.** ⌘N new chat, ⌘, Settings, ⌃⌘S sidebar, ⌘1–⌘3 the three places (`BighelpMenuCommands`).
- **Sidebar.** A sidebar button sits in the title bar right after the window controls, as in Mail and Finder, so
  the sidebar opens and closes from every screen. Drag the line between the sidebar
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
| launch | Connecting (host setup, live voice), restoring a session |
| spring | Reconnecting (Your computers, a plugin update waiting for Hermes) |
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

**The chat plays one loader at a time**: on its newest live tool folder, thinking row or running turn's block
(`ChatCanvasTranscriptProjection.activeLoaderID`, `BighelpActivityLoaderFocus`). Every other row, and each tool step
inside a folder, stays still.

## Protected behavior

The [Chat interaction contract](docs/CHAT_INTERACTION_CONTRACT.md) remains authoritative. Preserve the native recycling canvas, canonical ordering, retained draft and editor ownership, reader-controlled scrolling, live/history reconciliation, prepared model, grouped activity and explicit media/voice controls. Do not replace backend clients, authentication, notification delivery, profile ownership or saved data as a styling shortcut.

Existing host capability gates, uncertain outcomes, review/confirmation boundaries and optional permissions remain intact. Unsupported and inherited values must not masquerade as editable effective settings.

## Qualification and release

Record a disposition for each source surface, but never call declaration counts shipping-screen counts. Verify the running result and real controls, including both basic and advanced paths. Label fixture-only, host-backed and hardware-only evidence separately.
