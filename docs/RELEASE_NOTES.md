# Release notes

These notes tell people what is new in each bighelp release. They use ASD-STE100 Simplified Technical English:
short sentences, one instruction in each step, and the active voice.

## 2.6.83

### New

- **Needs you:** one sheet shows each approval, question and workflow sign-off that waits on you. Each one has a tab, and you answer it there. The menu shows a Needs you row only while something waits. A question in a chat opens the same sheet.
- **Read before you approve:** a long command, or the file of a workflow sign-off, opens in full before Approve works. Tap Show all.
- **Starters on an empty Feed or Ideas page:** the page shows three starter blueprints. Tap one to put it in the message box.
- **Blueprints in the message box:** each blank of a blueprint is now a chip in your message. Tap a chip and type its value, or select one of its choices. Send stays off until each blank has a value. To change the full text, tap the pencil.

### Changed

- **Settings › Modes:** one picker sets the home that bighelp opens in: Bots, Chat or Code. Code mode has its own switch. You can keep Code mode on with a Chat home, or turn it off.
- **Blueprints:** a blueprint from each page now goes to the message box. The separate fill-in page is gone.

### Fixed

- **Text for a new chat:** tap Ask, Discuss or a blueprint on Feed, Ideas or Goals. The new chat now always has the text in its message box. Before, the message box was sometimes empty.

## 2.6.82

### New

- **Delete an archived chat:** in Archived Chats, each chat has a More button with Restore and Delete. Delete asks you first, then removes the chat and its history from your computer. If the chat is still open in a different app, the row tells you.

### Fixed

- **Skills and commands list:** when you type a slash in a chat, the list now uses the room above the message box. Before, it showed approximately two rows.
- **Drawing in dark mode:** the Cancel and Add buttons are now easy to read on the white page. The tool palette is light, and black stays black.

## 2.6.81

### Fixed

- **Context page:** in Model settings, a tap on Context window now opens the Context page on a computer with a new Hermes. Before, the page showed "Context didn't load".
- **Delete Agent:** after you delete an agent, the app closes the pages of that agent and goes back to the screen that you used before, for example the Bots home. Before, the app stayed on a page of the deleted agent.
- **Delete Agent error:** the app no longer shows "The selected host or connection changed" when the computer deleted the agent. If the connection changes during the deletion, the app reads the agent list of the computer to see the result.

## 2.6.80

### New

- **Files on your computer:** in a chat, tap ••• and choose Files. The page shows the folder where the chat works on your computer. Tap a folder to open it. Tap a text file or a picture to see it. To see a different folder, type its path at the top. Search finds names in the folders that you opened.
- **Reasoning as its own message:** the reasoning of an agent now shows as one outlined message above its work. It says "Reasoning…" while the agent thinks, then "Thought for 12s". To put reasoning back between the steps, go to Settings › Chat › Reasoning shows. To close finished reasoning to one line, turn off Keep reasoning open.
- **Drawing:** in a chat, tap + and choose Drawing. Draw with your finger or Apple Pencil, then tap Add. The drawing goes into your message as a picture. Drawing is on iPhone and iPad.
- **Context window in Model settings:** below the Thinking control, a bar shows how full the context window of the chat is.

### Changed

- **Tool calls:** an open tool call is now one block. The request is at the top and the answer is below it. Copy and Show raw are below the block.
- **Finished turns:** a finished turn now says what the agent did, for example "Read 2 files, ran tests". The time and the number of steps are on a small line below it.
- **The + menu is shorter:** it has Camera, Scan Document, Photo Library, Files and Drawing.
- **New Bot Chat:** the empty chat shows immediately. The old chat goes away with the look that you selected for the Thinking control.

### Fixed

- **Ask an agent from Shortcuts:** when bighelp is closed, the shortcut sends your message sooner.
- **Voice from a shortcut or CarPlay:** a voice chat that you start while bighelp is closed now opens. Before, it showed "This chat is still opening" or said that live voice was unavailable.

## 2.6.79

### New

- **Model settings:** a model button is in the message box, before the microphone. Tap it to see the model of the chat, the Thinking control and Fast Mode on one short sheet. The app sends each change immediately. There is no Apply button.
- **Thinking control:** drag it sideways to set how hard the agent thinks. You feel a tick at each level, and the change goes to the agent when you lift your finger. You can also tap the track or the name of a level.
- **Six looks for the Thinking control:** Noodle, Train of Thought, Clockwork, Meadow, Ink Bloom and Wide Awake. Go to Settings › Appearance › Thinking to try each one and select yours. The colors of a look change as the level goes up.
- **All models:** in Model settings, tap the model. Each provider has a section that you can open and close. Tap the star of a model to keep it at the top. You can search all models.

### Changed

- **Smoother chats:** a long answer no longer makes the chat slow while it arrives or immediately after it arrives. The app now does the same small quantity of work for each new piece of an answer, also in a long chat and when the computer has many chats.
- **Names:** "Model & reasoning" is now "Model settings", and a chat shows "Thinking" where it showed "Reasoning".

## 2.6.78

### Fixed

- **Stop button:** in an agent's chat that another agent sent work to, the Stop button no longer flashes on and off while that agent works.
- **Default Model:** a second change on a bot's Default Model page, for example a model from another provider, now saves. Before, it showed "This host request is invalid."

## 2.6.77

### New

- **Share from other apps:** in another app, tap Share and choose bighelp. You can share a link, text, photos, a video or a file, and add a note. Then open bighelp, choose the agent and the chat, look at the message, and send it. A shared item stays on your iPhone or iPad until the message with it goes to the agent, or until you delete it in ☰ › Shared with bighelp.
- **Code in a notebook cell:** when you open a step where an agent ran Python or a shell command, the code shows with line numbers and colors, and its output shows below it in the same card. You can copy the code or the output, or open the cell full screen.
- **Live work between agents:** when an agent sends work to another agent, the "Waiting on" line shows when the other agent works and when it answers. Tap the line to see that work as it happens. The other agent's chat shows that it is working. This needs bighelp plugin 3.51.0 and Hermes 0.23.

### Fixed

- **Steps with code:** the app no longer closes when you open a step whose code printed only one number or one word.
- **Big files through a proxy:** a file over 8 MB now goes through a proxy that takes only 1 MB in each request. This needs bighelp plugin 3.50.0 or later. You can now remove a big file that did not go.

## 2.6.76

### New

- **Projects in the chat list:** a chat in a project shows the name of the project under its preview. To hide it, go to Settings › Chat and turn off Projects in the chat list.
- **Sort projects:** in Projects, tap the sort button and choose Recently used or Name.
- **Helper steps in one folder:** when a helper agent finishes, its steps go into one folder, and its reply shows below the folder. Tap the folder to see the steps.

### Changed

- **Newest step first:** in a bot's Activity, a subagent shows its newest step at the top. A step that runs now is at the top.
- **Reactions:** a reaction shows to the right of the time under the message. It does not cover the message.
- **Move to Project:** when you hold a chat, the menu shows the project of the chat. The list of projects shows that project first.
- **Scheduled tasks with a script:** you can edit them. Their instructions can be empty. Advanced shows the name of the script.

### Fixed

- **Time of each message:** when an agent sends two messages a long time apart, each message shows its time. Before, the two messages showed as one message with one time.

## 2.6.75

### Fixed

- **Group chats:** a message that you send in a group chat shows at once. Before, it showed 3 to 5 seconds later.

## 2.6.74

### New

- **See what a background item did:** on a bot's **Dashboard**, tap an item in **Activities**. For a subagent, you see each step in order on a timeline, and then its answer. For a command, you see the command and its output. For a routine, you see how the run went and its result. While the work runs, the view updates by itself.
- **Notifications from your agents:** an agent can send you a notification at any time, without a scheduled task. bighelp calls these notifications **Deliveries**.
- **More notification switches:** in Settings › Notifications, **Scheduled tasks** and **Deliveries** are now two switches. You can turn on one and turn off the other. A new **Group chats** switch controls the notifications from group chats. Questions and approvals always notify you.
- **Your order for plans:** in Usage, tap **Choose** next to Limits. Drag a plan to put it where you want it. Usage shows the plans in your order.

The first three items need the bighelp plugin 3.49.0 on your computer.

### Fixed

- **Your own replies notify you:** with **Agents messaging each other** off, a reply to your own message in a bot's chat did not notify you. Now it does. This needs the bighelp plugin 3.49.0.
- **New Group Chat:** in Bots mode, **New Group Chat** is in the + menu as soon as you open bighelp. Before, it could take 10 seconds or more.
- **Subagents in a chat:** when a subagent works in the background, the chat now shows the finished turn in the style that you chose (Card, Minimal or Full). Before, the turn showed every step. The subagent's row also updates when it reports during your next message.

## 2.6.73

### New

- **See and control your computer:** on a bot's **Computer** tab, **Your computer** shows the desktop of the computer that runs Hermes. This works on macOS, Linux and Windows. Tap **Open your computer**, then tap **Take control** to use it. First, turn on screen sharing with a password on the computer. On a Mac, go to System Settings › General › Sharing › Screen Sharing. Then turn on "VNC viewers may control screen with password". bighelp asks for this password one time. This needs the bighelp plugin 3.48.0.
- **Activities:** on a bot's **Dashboard**, **Activities** replaces **Today**. It shows the background work of the last seven days, by day. To see routines in the list, tap ⋯ and then **Show routines**.

### Fixed

- **Zoom on a screen:** you can pinch to zoom on a screen while you are in control. Before, zoom worked only while you watched.

## 2.6.72

### New

- **Work in the background:** an agent can continue to work after it answers. For example, it can run subagents, a command such as a preview server, or a scheduled task. Now bighelp shows this work in three places:
  - In a chat, **In the background** shows above the message box while subagents or commands run. Tap it to see each one. You can stop a command there.
  - In Bots mode, a bot with work in the background shows a stack on its face. Its row tells you what runs.
  - On a bot's **Dashboard**, **Today** lists the work of the day. Tap **Today** to open the list. **Today** replaces the **Templates** row. To open templates, go to **See all** on Feed, Ideas or Goals.

  Bots mode and **Today** need the bighelp plugin 3.47.0 on your computer.
- **Restart the Hermes dashboard:** in Settings › System, tap **Restart Hermes Dashboard**. After you install the plugin, bighelp asks you to restart Hermes, because the plugin starts to work only after the restart.
- **Agent pictures in alerts:** an alert from an agent shows the agent's picture, as a message from a person does.

### Fixed

- **Live voice:** when live voice cannot start, the call screen tells you why. Tap **Try Again** to try again. When a Gemini call stops at once, the call screen shows the reason that Gemini gave.
- **Plugin install:** if you remove the plugin on your computer, you can install it again from bighelp. Before, bighelp showed "The plugin install may still be running".
- **New chats:** a new chat that has no messages opens again after a reconnect. Before, it could say "This chat isn't available right now".

## 2.6.71

### Fixed

- **Apps open:** in 2.6.70, an agent's app showed its card, but **Open App** said "The app didn't open." Now the app opens. An app's page can be up to 16 MB. Update the bighelp plugin on your computer to 3.46.1.

## 2.6.70

### New

- **Apps from your agents:** ask an agent for a small app, for example a budget planner or a dashboard. The agent makes the app, and the chat shows a card for it. Tap **Open App** to use the app on the full screen. An app can show live data, which changes while the app is open. When the agent allows it, the app can send your answer back: bighelp shows you the message first, and sends it only when you tap **Send**. Update the bighelp plugin on your computer to 3.46.0 to use apps.

## 2.6.69

### Fixed

- **Dark mode in an open chat:** when your iPhone changes from Light to Dark while a chat is open, the agent's messages change too. Before, they kept their Light colors and were almost invisible until you opened the chat again.
- **Sections on more than one computer:** when you rename or delete a section that holds bots from more than one computer, the change gets to every bot. Before, the old section could stay or come back, and you had to do the action again.

## 2.6.68

### New

- **Sections in Bots mode:** put bots and group chats in sections, like folders on the Home Screen. Tap + and then New Section. Each section shows as a card with the faces of its members. Tap a card to open the section. A section can hold bots from more than one computer. Chat mode's Agents and Code mode's agent list show the same sections.
- **Group chats in Bots mode:** tap + and then New Group Chat. You can pin, hide, arrange and move a group chat, as you do with a bot.
- **Who answers in a group chat:** in Group Settings, pick who answers a message that names nobody. The choices are every bot, a lead bot that gives the message to the right bots, or an automatic pick. Each group chat also has a purpose and shared notes that every bot keeps in mind. A long discussion stops after 10 messages, and you can tap Continue.
- **Unread chats:** a chat with a new answer that you did not read shows a dot, and its title is bold. A chat that holds a message that you did not send shows "Draft".

### Changed

- **Your order on every device:** bighelp keeps your bot order, your sections, your pins and each bot's settings on your computer. Another phone, an iPad or a new install of bighelp gets them again. This needs bighelp plugin 3.45.0.

### Fixed

- **Phone tools stay on:** when a phone tool ran a long time (for example Location), the chat lost its phone tools until you left it. Now bighelp connects them again by itself. With plugin 3.45.0, Location also gets more time.
- **The time of an answer:** an answer from an agent shows its time as soon as it ends. Before, the time showed only after you opened the chat again.

## 2.6.67

### Changed

- **Answers show sooner:** after you send a message, the first words of the answer show on the screen sooner.
- **Waiting messages go at once:** a message that waits for the connection goes as soon as bighelp can send it.
- **Faster return to long chats:** when you go back to a long chat, bighelp reads only its newest messages again. The older messages that you loaded stay.

### Fixed

- **The agent knows who writes:** on a computer that several people share, the agent knows again who sends each message.
- **Waiting messages stay:** a message that waits for the connection stays when you open many other chats.

## 2.6.66

### Fixed

- **Group chats open again:** a newer Hermes sends more facts about a group chat. bighelp did not accept them, and no group chat opened. Now group chats open. When Hermes cannot do a group request, bighelp shows the reason of Hermes.

## 2.6.65

### New

- **All bodies in Bot Studio:** swipe up on the row of bodies to see all of them in a grid, in their sets. Tap a body to use it. Your avatar stays at the top. To see one row again, tap the handle above the bodies.

### Changed

- **The bar keeps your place:** leave a chat for Feed, Ideas or another place. The tab that you left then opens the same chat again. With Sessions in the bar, Sessions opens the chat that you picked from its list. When you change the agent, Chat opens the chat of that agent.
- **New Bot in Bots mode:** the + button opens New Bot. The gray New Group Chat item is gone. You make group chats in Chat mode.

## 2.6.64

### Fixed

- **No crash with Arriving and leaving:** when an agent saved a place to watch, bighelp crashed. After that, bighelp crashed every time it opened. Now bighelp opens again, and the places that your agents saved work.

## 2.6.63

### New

- **Bot Studio in Create New Bot:** when you make a bot, pick a body from Bot Studio and a color, or tap Surprise me. To change the eyes, shape or moves, tap Eyes, shape and moves. To see all bodies, tap More. The bot keeps its look on your other devices and in Hermes Desktop.

### Changed

- **Groups on a bot's Info page:** the rows are in groups: Personality, Defaults, What it can use and Routines. Add routine is at the top of Routines. Advanced Options is at the bottom.
- **A clear order in the chat ⋯ menu:** New Bot Chat is at the top. Then come the items for this chat, then Model & speed and Usage, then Edit agent and Advanced. You do not have to scroll when File changes shows. If your iPhone uses a large text size, the menu shows This chat, Agent and More.

## 2.6.62

### New

- **Active Project for each bot:** open a bot's profile and tap Active Project. It shows the project where the bot starts new chats. Tap a different project to change it for that bot. Before, you could change it only in Chat mode, in Projects.

### Fixed

- **The correct AGENTS.md in Core Files:** Core Files shows the AGENTS.md that the bot uses for its chat. When you move a chat to a different project, Core Files shows the AGENTS.md of the new project. This needs bighelp plugin 3.44.1 on your computer.
- **Popular plugins have room:** on the Marketplace page, the rows under Popular plugins are taller. The names, stars and icons do not touch.

## 2.6.61

### New

- **Core Files for each bot:** open a bot's profile and tap Core Files. You can read and change SOUL.md, USER.md and MEMORY.md. You can also change the AGENTS.md of the bot's project, if the project has one. The bot reads these files when a chat starts. This needs bighelp plugin 3.44.0 on your computer.
- **Connections for each bot:** a bot's profile has Connections. It shows the bot's apps and Device access.

### Changed

- **One Marketplace on a bot's profile:** the Skills Hub, Plugins and MCP servers are in the bot's Marketplace. They are not separate rows on the profile.
- **bighelp opens directly in your home:** when you open bighelp, your home shows with the data that your phone saved. bighelp connects to your computer in the background. The "Reconnecting to your selected host" screen does not show.
- **Connection messages only for problems:** bighelp does not show "Connecting…", "Reconnecting…" or "Updating…" while it connects. It shows "Not connected" or "No internet" only when the connection fails.

### Fixed

- **Plugins and the Skills Hub open fast:** these pages show the last list immediately and update it in the background. Before, the first load could take 20 seconds or more.
- **Recent runs of scheduled tasks:** Recent runs shows the runs again. Before, it showed "Hermes returned an unsupported or invalid response." Last run shows the time of the newest run.

## 2.6.60

### New

- **Marketplace:** open Settings and tap Marketplace, under Agents. The Marketplace shows the featured plugin of this week and the plugins with the most stars. It has four parts: Apps, Skills, Plugins and Talk anywhere. Talk anywhere connects your agent to messaging apps such as Telegram and Discord. You do not need Nerd Mode.
- **Marketplace for each bot:** open a bot's profile and tap Marketplace. The skills, apps and messaging apps are for that bot. Plugins are for all agents on the computer.
- **Move a chat to another project:** in a chat, tap ⋯ and then Move to Project…. You can also touch and hold a chat in Chats. The chat moves when Hermes confirms the move.
- **More on the Plugins page:** the page shows the featured plugin of this week, the same as the Hermes marketplace. It has the shelves Popular and New this month. Each plugin shows its GitHub stars. This needs bighelp plugin 3.43.0 on your computer.

### Changed

- **A shorter ⋯ menu in chats:** the ⋯ menu is one list, with or without Nerd Mode. It has Model & speed, Rename…, Move to Project…, Files, Edit agent, Usage, File changes and Advanced.

### Fixed

- **Plugin updates that ask first:** an update can add tools or hooks, or the security check of Hermes can find problems. Then the plugin's page shows what Hermes asks. Tap Update and allow them, or Update anyway, to continue. Before, the update stopped with an error.
- **The reason for a refused install:** when Hermes does not install a plugin, the page shows the reason from Hermes. If your computer cannot install a plugin, its Install button is off and the page tells you why.

## 2.6.59

### Fixed

- **Character opens Bot Studio:** in a bot's profile, tap Character to open Edit avatar. You can then choose Bot Studio, PetDex or a photo.
- **Avatars do not move until you choose a move:** a new avatar is Calm. Surprise me does not add a move.
- **A new body starts with its own defaults:** a different body does not keep the eyes, tilt, lean, size or move of the last body.

### Changed

- **Primary bot:** the star on the primary bot is gone.

## 2.6.58

### New

- **Bot Studio:** open an agent, tap its avatar and then tap Edit avatar. Choose Bot Studio, PetDex or a photo. In Bot Studio, the avatar fills the top of the screen. Below it, a drawer shows one row of choices at a time: Body, Eyes, Color, Shape and Moves. Every body changes in the same ways: eyes, mouth, colors, tilt, lean, height, size, mirror and how it moves. Tap Surprise me for a new avatar, and tap Undo to remove your last change.
- **New art for all avatar packs:** every pack has new art in one style, with flat colors, a small tilt and two small eyes. This includes bighelp, the classic characters, Bits, Pocket Curios, Bitty Bots and the seasonal packs.
- **Avatars that follow your agent:** bighelp saves a Bot Studio avatar on your computer, so the avatar is the same on all your devices. Hermes Desktop shows its picture.
- **Results from helpers:** when helpers or a background command finish, the chat shows a small card. The card tells you what finished, with one line for each task. Tap See results to read the full results. Before, the chat showed the full report as a message from you.

### Changed

- **PetDex:** pixel pets have their own page. They keep their own look and moves.
- **Other:** the empty "Other" section is gone.

## 2.6.57

### Changed

- **Simpler Settings:** Settings has short groups now. Your name and photo are one row at the top. Under Agents, Connections replaces Apps. Under App, Modes holds the switches for Bots mode, Code mode and the Unified Mode Toggle.
- **Connections:** Device access is in Settings › Connections, above your apps. The Secure credential vault is on the same page. It is no longer in ☰.
- **Other settings that moved:** the companion pet is in Settings › Appearance. The "Share usage and diagnostics" switch is in Settings › Help & feedback.

## 2.6.56

### Fixed

- **Commands that do not finish:** when a command on your computer stops with an error, the chat shows the reason from Hermes. For example, a quick command can stop after 30 seconds. You can send your next message at once. Before, the chat said "Command delivery is unconfirmed" and Send did not work until you opened the chat again.
- **Messages in a Bot Chat:** when another agent writes in a chat that is open, your last message and the last reply of your agent stay on the screen. Before, they sometimes went away until you refreshed the chat.

## 2.6.55

### Fixed

- **Notifications for every agent:** replies from all your agents send notifications. Before, only the agent that you used when you set up notifications sent them. Open a chat with an agent one time, and its replies send notifications.
- **Notifications that stopped:** when your computer no longer has the notification setup of your phone, bighelp sets up notifications again by itself. You do not have to tap Set Up Again.
- **Live Activity:** the Live Activity shows when you tap Send. It also shows the work of your agent when you leave the app right after you send. This is true for a message with a photo or a file too.

## 2.6.54

### New

- **Default Model has Advanced models:** open a bot's profile and tap Default Model. The chat model is first, with its thinking level and Fast. Tap Advanced to choose a model for subagents, scheduled tasks and helper tasks. An example of a helper task is "Naming chats". Each one can use the same model as the chat.
- **Choose models on the page:** the list of models and the thinking levels open below the row that you change. They do not open in a separate window. The change saves when you tap a model.

### Changed

- **Hermes tools (Nerd Mode):** MCP servers, Toolsets, installed plugins and skills, Webhooks, Messaging, Memory and Shell hooks look like Native App Connections. Each list has search, filters, logos and a switch on each row.
- **Test notification:** the test notification says "This is your successful test notification from bighelp!".

### Fixed

- **Plugins:** when you turn a plugin off or remove it, the change shows at once and the screen does not freeze.
- **Plugins and Skills Hub:** the pages open faster. When you open a page again, it shows at once.
- **Gemini Live:** when you ask for something in your home, for example "turn my TV off", your agent does the work. Before, Gemini sometimes said that it cannot control your home. To get this fix, update the bighelp plugin to 3.42.1.

## 2.6.53

### Fixed

- **Native App Connections:** when Hermes on your computer is not signed in to Nous Portal, the page shows a Sign in button with the Nous Portal logo. Sign in, and your apps show.
- **Bot avatars:** a face that you recolor keeps its new color on every screen. Before, some screens showed the old color, also after you changed between bots.
- **Agent talk:** a message from one agent to another shows as agent talk in more cases.

## 2.6.52

### Changed

- **Native App Connections:** the list opens at once, with app logos, category sections and filters. Connect an app from its row.
- **Pet companions:** each agent uses its own avatar. Settings has three controls: Show pet companion, Pet size and Adventurous Pet.
- **Working bots:** Hermes faces and bighelp characters play their animations while the agent works. With Reduce Motion, a badge shows the activity instead.
- **Bot menu:** New Chat, Pin, Rearrange, Mark Read or Unread, Bot Profile and Hide are in one long-press menu.

### Fixed

- **Tool calls:** long tool names shorten to keep the disclosure arrows in place.
- **Gemini Live:** the microphone gate clears leftover speech when the agent starts a reply.

## 2.6.51

### New

- **Apple Health:** your agent can read the Health data that you allow, for example your sleep, steps and heart rate, and answer with a chart. Go to Settings › Device access › Apple Health, or ask your agent, for example "How did I sleep this week?". bighelp never changes your Health data. To use this, update the bighelp plugin to 3.42.0.
- **Turn on a tool from the chat:** when your agent needs a Device access tool that is off, for example Calendar or Reminders, the chat shows a card. Tap **Turn on**, and the agent continues. Tap **Not now** to keep the tool off. This needs bighelp's plugin version 3.42.0 or later.
- **Search, sort and filter files:** a bot's Files tab and the Files page have a search field, Sort (name, date changed, date made) and Filter (folders, documents, images, video, audio).
- **Numbered sources:** in an agent's answer, tap a number such as [1] to open its source.

### Fixed

- **Answers stay in view:** when more work follows an agent's answer, the answer keeps its bubble. It does not fold into the agent's notes.
- **iPad:** the bot switcher stays below the battery and Wi-Fi icons.

## 2.6.50

### Fixed

- **Chat files:** pictures and files can load in saved chats with long message IDs.

## 2.6.49

### Changed

- **Smoother chat:** typing while the agent answers is smoother, and the chat does not stop for a moment after you stop typing.

### Fixed

- **Agent instructions:** long instructions scroll and type smoothly, in the small box and in the full-screen editor. The line that you type stays in view above the keyboard.

## 2.6.48

### New

- **Big files:** send videos and other files of up to 256 MB to your agent. bighelp sends them in pieces in the background and continues after a lost connection. The file shows its progress, then a line that opens it in Files. To use this, update the bighelp plugin to 3.41.0.

### Fixed

- **Unconfirmed sends:** when bighelp cannot confirm that a message with a file was delivered, the chat now always tells you, and it does not send the message again by itself.

## 2.6.47

### New

- **Themes:** Settings › Appearance has a grid of themes. Each theme has a light version and a dark version. Pick a theme for light mode and a theme for dark mode. Bots mode uses the themes too.
- **Agent messages on the page:** in Settings › Appearance, you can show agent messages on the page, without a bubble. Your own messages keep their bubble. Hold a message to open its menu, with a bubble or on the page.
- **Avatar designer:** the avatar designer shows how a face moves in each state. It has shape controls with Undo, named palettes and ready-made face sets.
- **Expand:** when your message has 3 or more lines, an Expand button shows above the message box. Tap it to open a bigger editor. The text now uses the full width of the message box.

### Changed

- **Text size:** text in bighelp is now one step smaller by default, and chat messages are one step smaller too. A text size that you picked does not change. Settings › Appearance has a new Small size. Settings and other sheets now follow your text size.

### Fixed

- **Return to latest:** one tap on Return to latest goes to the newest message, also while the chat still moves after a flick.

## 2.6.46

### Fixed

- **Steer after a photo or file:** when you send a photo or a file, you can steer the agent while it works. Send stays on.
- **Bots mode at night:** Bots mode uses the dark background, Graphite or Black, that you pick in Settings › Appearance.

## 2.6.45

### New

- **Live voice:** the agent speaks the language of your phone for the full call. It changes the language only when you ask it to. It knows its own name and your name. While you share your location with bighelp, it also knows your city, so it can tell you the weather. To use this, update the bighelp plugin to 3.40.0.

### Nerd Mode

- **Call sound report:** the Gemini Live call screen does not show the report now. To show it, go to Settings › Voice › Debug and turn on **Show call sound report**. To copy it, turn on **Copy report button**. **Restart sound** is in the same section.

## 2.6.44

### Fixed

- **Gemini Live voice:** you hear the agent from the first reply. Before, the agent's words showed on the screen, but its voice did not play.

### Nerd Mode

- **Call sound report:** with Nerd Mode on, a Gemini Live call shows what the phone received and played. Tap **Copy report** to share it. In Bots mode, **Copy report** is in the voice bar's gear menu.

## 2.6.43

### Usage widgets

- **New designs:** each Usage widget size has new styles. Touch and hold a widget, tap **Edit Widget**, and select a **Style**. **Automatic** shows one plan or all of them.
- **Lock Screen:** you can put Usage on the Lock Screen. Select a line above the clock, a gauge or a rectangle.
- **iPad and Vision Pro:** the extra large size shows a column for each plan.
- **Plans that you select:** in **Edit Widget**, select **Plans**. The widget shows them in your order, as meters or as rings.
- **Near the limit:** a plan turns amber at 80% used and red at 100%. A used-up plan shows a lock and the time until it resets.
- **Plan names:** you can give a plan a name. In **Usage**, tap **•••** on a plan, and then tap **Rename…**. The widgets show the name too.

### Changed

- **Cost and tokens:** the **Show** choice is gone. A Usage widget that showed Cost, Tokens or Top models now starts on **Automatic**. To show them again, select the **Cost and tokens** style in **Edit Widget**.

### Fixed

- **Gemini Live:** the agent's replies play to the end. Before, the first replies of a call often showed their words but made no sound, and noise in the room cut later replies off. You can still talk over the agent to stop it.
- **Pictures in chat:** a picture that an agent sent shows, or the message tells you why it did not come, with **Try again**. Before, some pictures stayed on the loading animation. The reason needs bighelp's plugin version 3.39.0 or later on the computer.

## 2.6.42

### Chat

- **Send while the chat connects:** when you return to bighelp, or open an agent on a different gateway, Send and the message box stay on. If you send before the chat connects, the chat shows your message at once. "Sending…" shows below it. bighelp sends the message when the chat connects.
- **Two messages in a row:** if you send two messages before the chat connects, bighelp sends them in order. The second message steers the agent's answer to the first.
- **No connection:** if the chat cannot connect in 25 seconds, Send goes off. bighelp puts the messages that wait into the message box again, so you do not lose them.

## 2.6.41

### Fixed

- **Gemini Live voice:** on a Gemini call, you hear the agent every time. Before, the agent's words sometimes showed on the screen, but its voice did not play.
- **Usage widget:** the Usage widget shows your numbers again, also when bighelp is closed. Each Usage widget can show one gateway: touch and hold the widget, tap **Edit Widget**, and select a **Gateway**.

## 2.6.40

### Full Duplex voice

- **One answer when you ask:** on a Gemini call, the agent says "On it" one time. Before, it often said it two times. This also applies when you add to a request during the call.
- **Results one at a time:** when work finishes, the agent waits until nobody speaks. Then it tells you. It does not stop one result to start the next one.
- **Starts at once:** tap the voice button, and Full Duplex starts. You do not tap **Start**. Tap **End** to go back to the chat.
- **Your language:** the agent speaks the language of your phone. It changes language only when you speak a different language to it. This needs bighelp's plugin version 3.38.0 or later on the computer.
- **One voice choice for each agent:** **Settings › Voice**, the bot's **Default Voice** in Bots mode and the voice button in a chat change the same choice. In **Settings › Voice**, select an agent at the top, or select **All agents** for the default.
- **Bots mode:** the voice bar shows what the call does, or why it did not start.

### Fixed

- **Settings › Voice:** the page has no long text under each setting.
- **Mac:** after you select Gemini Live, the **Voice** row in Settings shows Gemini Live. Before, it showed GPT-Live.

## 2.6.39

### Full Duplex voice

- **New name:** live voice is now **Full Duplex**. You can talk over the agent, and it keeps talking while it works.
- **The agent talks as itself:** on a call, the agent uses its own name and character. It says "I am on it" and "I finished it". It does not talk about "your agent". This needs bighelp's plugin version 3.37.0 or later on the computer.
- **Gemini Live:** you can now use Gemini Live for Full Duplex. The agent needs a Gemini API key on the computer (`GEMINI_API_KEY`). Free Google AI Studio keys work. Gemini Live needs bighelp's plugin version 3.37.0 or later.
- **A provider and a voice for each agent:** open a bot's profile, tap **Default Voice**, and select **Full Duplex**. Select a **Provider** and a **Voice**. They are only for that bot. **Settings › Voice** sets them for all other agents.
- **News during the call:** when work that you started on a Gemini call finishes, the agent tells you at once. If the agent cannot confirm the work, it does not say that the work finished.

## 2.6.38

### Credential Vault

- **In each bot's profile:** open a bot's profile, tap **Info**, then tap **Credential Vault**. The row is above **Advanced Options**. It shows the number of websites that the bot can use.
- **Wallet and websites:** the vault shows your saved cards and addresses in a wallet. Below the wallet, it shows each website and the items that you saved for it.
- **Add a website in one step:** tap **Add a Website**. Type the website, and select **Login**, **Card** or **Address**. Tap **Next**, type the details, and tap **Save**. One Save keeps all of the items.
- **Use a saved card again:** when you add a website, you can select a saved card or address. You do not type it again. This needs bighelp's plugin version 3.36.0 or later on the computer.
- **If one item does not save:** the other items stay saved. Only the item that did not save stays open, with its details. Tap **Save** again.

## 2.6.37

### Skills and plugins

- **Plugins:** the plugin catalog opens on an official pick, a shelf of official and verified plugins, and a shelf for each topic. Tap **See all** to see all the plugins in a topic. Tap a plugin to see what it adds, the keys that it needs and the version that installs. Then tap **Install**, and confirm.
- **Skills Hub:** the Skills Hub shows your agent's skills, the official skills from Hermes in a shelf, and the hubs that you can search. Tap a skill to see its files and the result of the safety check. Then tap **Add**, and confirm. If the check blocks a skill, you cannot add it.
- **Pictures:** official and verified plugins show their banner in the catalog. A community plugin shows its pictures only when you open its page.

## 2.6.36

### Fixed

- **Bot profile tabs:** each tab name in a bot's profile shows whole, also with larger text. Tabs that do not fit on one line go onto a second line. Before, the last tab name was cut at the edge of the screen.

## 2.6.35

### Skills

- **Import a skill:** in an agent's **Skills & Tools**, tap **+**, then **Import SKILL.md or ZIP**. Choose a SKILL.md file, or a skill folder in a .zip file. The agent gets the skill. Before, each import showed "This host supports browsing only".
- **Skill folders:** a .zip can have the folders scripts, references, templates and assets. The computer checks each file and scans the skill before the agent can use it. A skill folder needs bighelp's plugin version 3.35.0 or later on the computer. A SKILL.md file works with all versions.

## 2.6.34

### Fixed

- **Pictures from agents:** pictures that an agent sends now show in the chat when the reply arrives while bighelp is in the background. Before, the chat showed the loading tile and did not show the pictures.
- **Show me where with more than one computer:** when bighelp shows the bots of all your computers, the agent now opens the place on the computer that you use. The bar shows the correct agent name. Before, the page did not change, and the bar could show the name of an agent on a different computer.

## 2.6.33

### Agents

- **Show me where:** ask your agent where a page or setting is. For example, ask "How do I see what my Feed can do?" The agent opens that place in bighelp and points at it.
- **Watch the way:** a bar grows out of the top of the screen. It shows the agent's name and each step as it happens. Your chat stays at the bottom of the screen, and you can still send messages there.
- **Return to chat:** tap **Return to chat** to see your chat again as it was. Tap **x** to stay on the page.
- **Only moves:** the agent never changes a setting and never taps Save, Send or Delete for you.
- **To stop it:** in **Settings > Permissions**, set **Let agents show you around bighelp** to off.
- This needs bighelp's plugin version 3.34.0 or later on the computer.

## 2.6.32

### Bots

- **One look for each tab:** in a bot's profile, the Dashboard tab shows the bot's picture, name and role the same as the other tabs.
- **Character:** in a bot's profile, select **Info > Character** to change the bot's shape and color. **Reset to default** and **More avatars** are there too.
- **Set Default:** touch and hold a tab in a bot's profile, then select **Set Default**. The next profile that you open starts on that tab. This setting is the same for all bots.
- **Rearrange:** touch and hold a tab, then select **Rearrange**. Drag the tabs into a new order, then tap **Done**. This order is the same for all bots.

### Fixed

- **Chats on a computer:** if one saved chat record is incorrect, bighelp ignores only that record. Before, no chat on that computer opened or started.

## 2.6.31

### Fixed

- **New Bot Chat:** after you start a new Bot Chat, bighelp opens it again when you return to the app. New chats with that bot also start again. Before, bighelp showed "Unable to open" for both, also after a restart.

## 2.6.30

### Bots

- **Bot Chats stay put:** your computer now makes each agent's Bot Chat itself. Before, when one agent sent a message to another agent, Hermes could replace the agent's Bot Chat with a new one, without its earlier messages. This needs bighelp's plugin version 3.33.0 or later on the computer.
- **New Bot Chat:** this still starts a new Bot Chat. The old one stays in the chat list with its date.
- **Default Voice:** in Bots mode, open a bot's profile and select **Default Voice**, below **Default Model**. Choose TTS or GPT Live for that bot only. Then choose the provider, the model and the voice from lists.
- **Advanced Options:** below **Default Voice**, select **Advanced Options** to change that bot's settings in plain words. For **Approvals**, choose **Smart**, **Manual** or **Off**. Tap **(i)** to see what each choice does.

### Voice

- **Voices from lists:** in **Settings > Voice**, you choose voices and models from lists. Before, you typed them.
- **Team calls:** each bot in a team call speaks with its own voice, also with Phonon on your iPhone. Before, the bots could all use one voice.

### Fixed

- **Unable to open:** if a chat cannot open, bighelp tries again while the chat is on screen and each time you return to it. Before, you could not send in that chat until you closed and opened the app again.

## 2.6.29

### Voice

- **Voices on your iPhone:** an agent can speak with Phonon, a voice that runs on your iPhone or iPad. It needs no account, no key and no internet connection. To use it, open **Settings > Voice**, select an agent and select **Provider**. Then select **Phonon** and tap **Download voice**. The download is approximately 137 MB. Phonon needs iOS 18 or later.
- **Hear the voices:** Phonon has a default voice and 37 other voices. 12 of them are character voices. Tap **Play** next to a voice to hear it before you choose it. Then tap **Save**.
- **Auto TTS:** turn on **Use TTS on every response** in **Settings > Voice** to hear each reply when it arrives. You can also turn it on or off from **+** in a chat with **Auto TTS**. A new message, voice mode or a different screen stops the speech.
- **Hold music:** turn off **Hold music** in **Settings > Voice** for a silent wait while your agent works on a reply.

## 2.6.28

### Fixed

- **Bot profile tabs:** the tabs in a bot's profile fit on one line. Before, a tab could be cut off at the edge of the screen.

## 2.6.27

### Fixed

- **Dashboard after time away:** a bot's Dashboard loads when you come back to the app. Before, it could say that the connection changed, and the piles stayed empty until you opened the bot again.

## 2.6.26

### Highlights

- **Bot dashboard:** in Bots mode, a bot's profile opens on **Dashboard**. It shows the bot's Feed, Ideas and Goals as piles of cards. Swipe a card right to act on it: ask about a post, do an idea or mark a goal done. Swipe a card left to put it away. **Undo** shows after each swipe. Touch and hold a card to see all its actions. The first time, a short tutorial shows how to swipe.
- **Templates:** on **Dashboard**, select **Templates** to swipe through starter prompts for Feed, Ideas and Goals. Swipe right to put a prompt in the bot's message box. Nothing runs until you tap **Send**.

### Chat

- **Faster answers:** bighelp sends your message to your computer at once. Before, it waited to tell the computer who was sending.
- **Smoother typing:** the message box does less work for each key that you type.
- **Smoother chats in Chat mode:** a chat in Chat mode does not draw itself again when other parts of the app change.
- **New chat transition:** when you start a new chat, the old messages fade away line by line, from the bottom up.

### Fixed

- **Alerts for the chat on screen:** in Chat mode, bighelp no longer shows alerts for the chat that you are reading. Before, this happened after you started a new chat.

## 2.6.25

### Chat

- **A compact header:** Chat mode uses the same glass pill for the agent's name and picture as Bots mode. Text also blurs at the top and bottom edges in the same way.
- **Open saved chats at once:** select a chat that bighelp has saved on your device to open it at once. The loading screen shows only when the chat has no saved copy.
- **More room to read:** the smaller **Return to latest** button sits on the right side of the chat.
- **A new chat transition:** the current messages fade away when you select **New chat** or **New bot chat**. If Reduce Motion is on, the messages clear without the effect.

### Fixed

- **Find scheduled tasks:** search scheduled tasks across all your computers. Search stays available when there are no matches. You can also reach Tasks from Kanban when Kanban is in the bottom bar.
- **Sign in again:** if a computer rejects your saved sign-in, **Sign in again** replaces **Reconnect**. Tap it to start the sign-in for that computer.

## 2.6.24

### Fixed

- **Signed out every day:** bighelp no longer signs you out of a computer that uses browser sign-in, for example with Nous Portal. Before, a renewal that was cut off (for example, when the phone locked or the network changed) could end the sign-in. bighelp also renews the sign-in in the background.
- **Workspace after time away:** bighelp opens your computer's workspace when you come back to it. Before, after some time in the background, it could show "Saved native workspace data could not be opened", and Reconnect did nothing.

## 2.6.23

### Highlights

- **A new look:** Chat mode has the clean look of Bots mode. The page is white by day and black at night. Your bubbles and buttons are ink. To use a color, go to **Settings › Appearance** and select one. Your bubbles, **New chat** and the other buttons then use that color.
- **New chat in the bottom bar:** **New chat** is the round button in the middle of the bottom bar. Tap it to start a chat with your agent. Touch and hold it to select an agent or a group.
- **Feed, Ideas and Goals:** posts, ideas and goals show as color blocks. New posts show in a green block at the top. The goal that your agent changed last shows in its own block, with **Mark done**. Tap an item to open it. Touch and hold an item to see its actions.
- **Menu and Settings:** the rows have round icons in your color.

### Changed

- **Files:** Files moved from the bottom bar to the menu. To put it back in the bar, go to **Settings › Appearance › App layout**.
- **Lavender:** if you selected Lavender before, bighelp now shows Ink. To use Lavender again, go to **Settings › Appearance** and select **Lavender**.

## 2.6.22

### Chat

- **Scrolling while an answer arrives:** you can scroll up while your agent writes its answer. The chat no longer moves up and down while you read an earlier part.

## 2.6.21

### Fixed

- **Cloudflare Access:** bighelp connects when you open it after a long time in the background. Before, it could show "Cloudflare Access didn't let bighelp through" until you closed bighelp and opened it again. The same fix applies to a proxy password and to custom headers.

### Chat

- **Tapbacks:** when you hold a message, one menu holds the tapbacks and the actions. On a long message, the tapbacks no longer cover **Reply**, **Copy** or **Share**.
- **More reactions:** this opens the Apple emoji keyboard. Select an emoji to add it as a tapback.

## 2.6.20

### Highlights

- **Share usage and diagnostics:** a new switch in **Settings** › **Permissions** › **Device access**. It is on by
  default. You can turn it off at any time. Details are under **Privacy** below.
- **One Live Activity:** one Live Activity holds all your active chats. A tap on it opens the chat, also a Bot Chat.
- **Faster chats:** Send stays on while a chat opens. Bot Chats open from their saved copy. Scrolling up right after
  you return to bighelp is smooth.
- **Voice:** live voice keeps talking while earlier work runs. In CarPlay, **Talk** and a tap on an agent open the
  voice call.

### Privacy

- **Share usage and diagnostics:** to see the switch, go to **Settings** › **Permissions** › **Device access**. The
  switch is on by default. It sends:
  - counts of the features that you use
  - launch times and reply times
  - crash reports and hang reports
  - the time that an alert takes to arrive
- bighelp ties each item to a random ID. It never sends your messages, files or names.
- When you turn the switch off, bighelp stops at once. It deletes the items that it did not send yet, and it deletes
  the random ID. If you turn the switch on again, bighelp makes a new random ID.
- A computer with bighelp plugin 3.31.0 or later also stops its own sharing when you turn the switch off.

### Live Activities and widgets

- **One Live Activity:** one Live Activity holds all your active chats. The chats that need you are first. If
  there are more chats than the Live Activity can show, it tells you how many more there are. Before, a text-only
  turn could miss its Live Activity.
- **Tap to open:** a tap on a Live Activity opens its chat. This also works for a Bot Chat. Before, bighelp showed
  "Unable to open" for a Bot Chat.
- **Widgets:** **Active Chats** and **Recent Chats** show your working chats first. When updates pause, the
  widgets say so.

### Chat

- **Send stays on:** Send no longer stays off when you open a chat around a reconnect. If the chat is not yet
  connected, your message waits in the message box. It goes out when the chat is ready.
- **Bot Chats open faster:** a Bot Chat opens from the copy that your iPhone saved. In Bots mode, the first tap
  on a bot after you start bighelp is faster.
- **Smooth scrolling up:** after you return to bighelp, you can scroll up at once. Before, the chat could drop
  frames for a few seconds.
- **Windows:** **New Chat** starts in project folders on a Windows computer, for example `D:\Projects\app`. Before,
  bighelp showed "New chat could not be opened" for an agent with such a project. If bighelp cannot use a project
  folder, it now says so.

### Voice

- **Earlier work:** you can ask for something new while your agent does earlier work. Live voice
  does not wait. If the chat is busy, the new request runs as a background task in that chat.
- The chat shows the background task and its answer.

### CarPlay

- **Talk and agent taps:** **Talk** and a tap on the agent at the top of the list open the voice call. Before, the
  voice screen did not appear.
- **During a call:** the home screen has **Talk** and **End**. A tap on the agent in the call shows the call again.
  A tap on a different agent starts a call with that agent.

### Notifications

- Alerts arrive the same way as before. bighelp now gives its notification service the push address of your iPhone,
  for faster alerts in a later release. You see no change now.

### Photos

- **Photo drafts:** send your agent a photo of a business card or an event poster. Your agent makes a draft contact or a draft event. You check the draft, then you save it. Your agent cannot save it without you. This needs bighelp plugin 3.31.0 or later on your computer.

### Fixed in build 161

- **Live Activities:** the Live Activity shows again and follows your chats. Before, after an error on the notification service, the Live Activity could stop updating or not show at all. The phone now recovers on its own.
- **Apple Music cards:** an Apple Music card no longer freezes bighelp when Apple Music cannot answer. The card shows without its picture, and **Open in Music** still works.

### Fixed in build 162

- **GPT Live:** the thinking music no longer plays during a GPT Live call. Before, it played over the voice. Live voice also keeps answering after its first request. Before, it could stop answering until you started the call again.
- **Taps on another computer's chats:** a tap on a Live Activity or an alert for a chat on a different computer opens that chat. Before, bighelp showed "Unable to open" for a moment.
- **Tapbacks:** tapbacks show on their messages when you open a chat again. Before, they did not show until you added a tapback.
- **With bighelp plugin 3.32.0:** GPT Live says a short line before it starts work, for example "On it, checking now". A GitHub Copilot sign-in in **Provider Keys** shows as signed in at once.

## 2.6.19

### Highlights

- **Smooth scrolling:** long chats scroll smoothly. Details are under **Chat** below.
- **Your agent's work:** go to **Settings** › **Chat** › **Agent's work** and choose **Card**, **Minimal** or
  **Full**.
- **iPhone Duo:** on the folded Duo, your places move into the column beside the cover screen. The faces of your
  top bots show beside each chat. On the open Duo, your chats show on one side of the fold and the chat that you
  open shows on the other side. Details are under 2.6.16 and 2.6.17.
- **CarPlay:** talk to your agent in the car. bighelp connects in CarPlay without you opening the app on your
  iPhone. Voice works when your iPhone is locked. Details are under 2.6.18.

### Chat

- **Smooth scrolling:** chats scroll smoothly, also long chats. A message that you saw before shows again at once.
  When the chat is still, bighelp prepares the messages above the screen, so they are ready when you scroll up.
- **Your agent's work:** to choose how a chat shows the work of your agent, go to **Settings** › **Chat** ›
  **Agent's work**.
  - **Card:** while your agent works, one card shows the newest steps. When the turn ends, the card becomes one
    line above the answer, for example "Worked for 18s · 4 steps".
  - **Minimal:** while your agent works, one line shows the current step. When the turn ends, a small line shows
    under the answer.
  - **Full:** while your agent works, the chat shows every message, tool and thought where it occurs.
  - In all three, tap the card or the line to see each step.
- **Fixed:** when a new message from the same agent arrives, the message above it now moves closer to it.

## 2.6.18

### CarPlay

- **Connects without your iPhone:** in CarPlay, bighelp now connects to your computer when you do not open the app
  on your iPhone. Voice works when your iPhone is locked.
- **Clear problems:** if your computer does not answer, CarPlay tells you which step failed. It does not show
  **Connecting** without end.
- **Choose the agent:** to choose the computer and the agent for CarPlay, go to **Settings** › **CarPlay**.
- **Your agent's face and steps:** CarPlay shows the face of your agent. While your agent works, CarPlay shows each
  step in one line, the same as voice mode in the app.
- **Fixed:** the app no longer stops when you tap **Agents** on the voice screen in CarPlay.

### Cards

- **Album artwork:** music cards in your chats now show the artwork of the song, album or playlist.
- **Contact photos:** if bighelp can use your contacts, contact cards show the saved photo of the person.

## 2.6.17

### Links

- **Maps and Music open in their apps:** if you picked a browser in **Settings** › **Chat**, links to Maps, Music and
  other Apple apps now open in those apps. A card's **Directions** opens Apple Maps, and **Open in Music** opens Apple
  Music. If another app on your phone can open a link (for example Spotify or YouTube), that app opens it. Only web
  pages open in your browser.

### iPhone Duo

- **Dots for new items:** on the folded Duo, **Feed**, **Ideas** and **Goals** in the side column show a dot again
  when they have something new.

## 2.6.16

### iPhone Duo

- **Folded:** the bottom bar's places move into the column on the right side of the cover screen, under the clock.
  Your chats get more space for messages.
- **Switch chats from the side:** in Bots mode, the faces of your top bots show beside each chat. Tap a face to go to
  that bot's chat. In Code mode, your sessions show there. Each face or tile shows when it is working or needs you. To
  turn this off, go to **Settings** › **Experience** › **Chat switcher**.
- **Open:** your bots, your chats or your Code sessions show on the left side of the fold. The chat that you open
  shows on the right side. Nothing goes across the fold.
- **Like a small laptop:** when you fold the phone halfway and hold it upright, the messages stay above the fold. The
  message box and the keyboard stay below it.

### iPad and Mac

- **Chat switcher:** to see your bots or sessions beside each chat in landscape, go to **Settings** › **Experience**
  and turn on **Chat switcher**.

### Share a message

- **Share in the right format:** touch and hold a message, then tap **Share…**. Choose **Messages**, **Markdown**,
  **Plain text** or **PDF**, then tap **Copy** or **Share…**. **Messages** shows bold, italic and code with styled
  letters, for apps that do not show Markdown.

## 2.6.15

### Phone tools

- **Approvals stay on:** a switch in **Settings** › **Device access** now stays on until you turn it off. It is for
  this device, and all your agents and computers can use it. If iOS takes access away, the switch stays on and
  bighelp shows **Allow access in iOS Settings**.
- **Every agent:** each agent's chat can now use the phone tools, not only your main agent's chat. This needs bighelp
  plugin 3.30.0 or later.
- **Fewer interruptions:** the phone tools keep working when you pull down a notification, open Control Center or
  answer a system question. After you leave bighelp, they keep working for about 25 seconds. With plugin 3.30.0, a
  request waits a short time for you to come back, instead of failing at once.

### CarPlay

- **CarPlay on your iPhone:** voice chat with your agents now works in CarPlay on a real iPhone. Before, it worked
  only in the simulator.

### Message box

- **Expand inside the box:** the Expand button is now inside the message box, in its top corner. The text no longer
  moves when the button appears.

## 2.6.14

### Sessions

- **Sessions in the menu:** the menu (☰) now has a **Sessions** row below **Agents**. It opens the list of all your
  chats. If you changed **App layout** before, **Sessions** is at the end of the menu.
- **Sessions in the bottom bar:** to put it there, go to **Settings** › **Appearance** › **App layout** and tap the
  plus button beside **Sessions**. **Chat** still opens your agent's chat.

### Fixes

- **Faster after you come back to bighelp:** bighelp now gets your chat list from your computer with up to four
  requests at the same time. Before, it sent one request at a time. When you open bighelp again, it gets the full list
  before it opens a notification, a widget or a Shortcut. On a remote computer with many chats, this wait is now
  shorter.

## 2.6.13

### Fixes

- **New Bot Chat:** **New Bot Chat** works again on Hermes 0.22.3 and later. Before, bighelp showed "bighelp couldn't
  start a new Bot Chat".
- **Rename, archive, hide and delete:** these work again on Hermes 0.22.3 and later. bighelp now makes these changes
  through its own connection to the chat.
- **Pin and Mark Unread:** if Hermes refuses one of these, bighelp now shows the reason from Hermes.
- **Alerts:** you no longer get an alert for the chat that you look at. This is also true while the chat connects,
  after its history is compacted, and for questions and approvals.

## 2.6.12

### Device access

Seven new switches in **Settings** › **Device access**. Each switch is off until you turn it on. When it is on, your
agent can use it while you have its chat open. These need bighelp plugin 3.29.0 or later.

- **Contacts:** your agent can find, add, change and delete people in your contacts. If you share only some contacts
  with bighelp, your agent sees only those.
- **Photos:** your agent can find and look at your photos, save pictures that it makes, mark favorites and sort photos
  into albums. Before a photo is deleted, iOS asks you.
- **Arriving and leaving:** your agent can watch places that you name. When you arrive or leave, bighelp tells the
  chat that set the place. To get this when bighelp is closed, allow location **Always**. Reminders can also ring
  when you arrive at or leave a place.
- **Alarms and timers:** your agent can set, change and turn off alarms and timers. They ring also when your iPhone is
  on silent. This needs iOS 26 on iPhone or iPad.
- **Music:** your agent can tell what is playing, play and pause music, and make playlists in Apple Music.
- **Focus:** add the bighelp filter to a Focus in iOS **Settings** › **Focus**. Then your agent knows when that Focus
  is on and reads the note that you write for it. You can also make agent alerts quiet during that Focus.
- **Shortcuts:** type the names of the shortcuts that your agent can run. To run one, bighelp opens Shortcuts and then
  comes back with the result.

### Chat

- **Cards for people, places and music:** your agent can show a person, a place or music as a card in the chat.
  - A person card has **Call**, **Message**, **Email**, **Directions** and **Contacts**.
  - A place card shows a map, with **Directions** and **Open in Maps**.
  - A music card has **Play** and **Open in Music**.
  - These cards need bighelp plugin 3.29.0 or later.

### CarPlay

- **Agents:** in CarPlay, tap **Agents** to pick the agent that you talk to. bighelp remembers it for the next drive.
- **Talk:** after a pause, **Talk** continues the same chat.

### Languages

- **Simplified Chinese:** Bots mode, Teamwork and their Settings pages now show in Simplified Chinese. This text is a
  draft. Tell us on GitHub if a word is wrong.

## 2.6.11

### Modes

- **New names:** the three modes are now **Bots**, **Chat** and **Code**. Simple Bot mode is now **Bots mode**. Bighelp IDE
  is now **Code mode**.
- **Unified Mode Toggle:** a new switch in **Settings** › **Experience**. It is off by default. Turn it on to show a pill
  with Bots, Chat and Code at the top of each home. Tap a mode to switch to it.
  - Code shows in the pill only when **Settings** › **Code mode** is on.
  - In Bots mode, **Search** and **Filter by Gateway** move to a row under the pill.
  - On the Mac, press ⌃⌘1, ⌃⌘2 or ⌃⌘3 to switch modes.
- **Edge swipes:** a swipe from the edge of the screen can switch modes. Pick **Next mode**, **Bots mode**, **Chat mode**
  or **Code mode** in the edge swipe settings. A mode swipe also works in Bots mode.

## 2.6.10

### Group chats

- **Stop:** if bighelp cannot confirm a Stop, the group chat no longer blocks **Send**. The chat shows **Stop again**.
  bighelp sends the same stop again and reads the room log to confirm it. Before, the chat stayed blocked, also
  after you closed and opened bighelp again.
- **Hermes 0.22.4:** group chats work on computers with Hermes 0.22.4.
- **Discard:** if a member task stops when the computer restarts, the member row shows **Discard**. Then the member
  answers again.
- **Who is typing:** on Hermes 0.22.4, the chat shows the names of the members that type. This needs bighelp plugin
  3.28.0 or later.

### Simple Bot mode

- **Working:** each bot shows when it works on a turn, and **Needs you** when it waits for your approval. This also
  shows when another agent asks the bot for help. This needs bighelp plugin 3.28.0 or later.

### Fixes

- **Chat box:** the chat box no longer shakes while you type a long message. Thank you, @sachsom95.
- **Form cards:** forms with limits on a field show correctly. Before, they showed "This card couldn't be shown".
  Date fields show and send the day that you see. Thank you, @sachsom95.
- **Files:** in Bighelp Chat, **Files** shows the files of the agent that you selected. Before, it showed the files
  of your default agent. Thank you, @jochenvoehringer.
- **Notifications:** on iPhone and iPad, notification setup no longer stops when iOS asks for permission. If setup
  stops for a different reason, it shows a code.

Update the plugin in bighelp to get all of these features.

## 2.6.9

### Notifications

- **Channels:** a new section in **Settings** › **Notifications**. Pick the channels that send you notifications:
  - **All channels:** chats on iMessage, Telegram, a terminal and the other channels of your agents notify you too.
    This is the default, and it is the same as before.
  - **Only bighelp:** only your chats in bighelp notify you.
  - **Choose:** turn each channel on or off. **New channels** sets the channels that your agents start to use later.
- Chats in bighelp always notify you.
- Questions and approvals follow their channel. A question in iMessage stays in iMessage when iMessage is off.
- A scheduled task follows the place where it delivers its result.
- All your computers get the same choice for this device.

This feature needs bighelp plugin 3.27.0 or later. Update the plugin in bighelp.

## 2.6.8

### Fixes

- **Chat:** bighelp no longer closes when you open a chat. This mostly occurred when you opened an agent on a
  different gateway in Simple Bot mode.
- **New agents:** **Create** finishes as soon as your computer makes the agent. The plugin links the plugins of the new
  agent in the background.

### Settings

- **Simple Bot mode:** Settings has a **Chat** row. It opens the same page as **All Settings** › **Chat**.
- **Manage all gateways:** with more than one gateway, a new switch in **Settings** › **System** shows all your
  gateways. You can update Hermes and the bighelp plugin, and restart the gateway, on all of them at once.

## 2.6.7

### Agents

- **Agents that work together:** when an agent asks another agent for help, the work continues after you close
  bighelp. Before, the other agent stopped about 20 seconds after you left the app.
- **Plugin installs:** a new agent shares the plugins of your default agent. Before, it got copies of them. Two copies
  of one plugin package stopped all plugin installs on the computer, including bighelp plugin updates. The plugin
  also repairs agents that already have copies.

These fixes need bighelp plugin 3.26.0 or later. Update the plugin in bighelp.

## 2.6.6

### Chat

- **Expand reasoning:** a new switch in **Settings** › **Chat**. While a turn runs, the reasoning folders stay open.
  The switch shows only when **Show reasoning** is on.
- **Expand tool calls:** a new switch in **Settings** › **Chat**. While a turn runs, the folders of tool calls stay
  open. Each tool call stays closed until you open it. The switch shows only when **Show tool calls** is on.
- Both switches are off by default. To see them, turn on **Nerd Mode**.
- When the turn ends, **Fold finished turns** folds the turn as before.

This build does not need a new plugin update.

## 2.6.5

### Simplified Chinese

- The app has a first set of Simplified Chinese text. It covers setup, main navigation, core chat controls and
  the top level of Settings.
- Other screens can still show English. The Chinese text is a draft for community review.
- The app uses the language selected in the device settings. Your messages, names and saved settings do not change.
- Contributors can add translations through the new String Catalog. See `docs/LOCALIZATION.md` for the steps.

### Fixes

- **Chat list:** a list with thousands of chats refreshes with less work on the main thread. The app prepares large
  saves in the background and skips a save if nothing changes.
- **Scheduled work:** repeated chat-list updates share one refresh. Scheduled tasks can still refresh while the
  chat list waits. Switching computers cancels updates for the previous computer.
- **Removed chats:** a refresh no longer brings a removed chat back from an older saved copy. Drafts and chat
  history stay intact.
- **Long answers:** the app does less work to find the width of a long message. The full text remains available to
  read, select and copy.
- **Avatars:** the built-in catalog includes the approved Pocket Curios set for first launch and offline use.

This build does not need a new plugin update.

## 2.6.4

This release fixes agent reactions, answers that went away, and the loader in Simple Bot mode. It also makes heavy
chats smoother.

### Fixes

- **Reactions:** when an agent reacts to a message, the reaction shows in the open chat at once. This needs plugin
  3.24.0 or later.
- **Answers:** an answer of an agent stays in the chat when the agent continues to work after it. The answer no
  longer goes away or changes into a note.
- **Simple Bot mode:** when you open the chat of an agent, the loader shows until the chat is ready. This applies to
  all agents.
- **Heavy chats:** chats with very long history stream and scroll more smoothly.
- **Mac:** **Compact** is under **Usage** in the chat menu without Nerd Mode. In the iPad app on a Mac, right-click a
  message to react to it.
- **Data agreement:** if you did not agree to share data with your Hermes computer and its AI providers, bighelp
  asks you one time when it opens. bighelp sends nothing until you agree.

## 2.6.3

This release makes long chats fast again and fixes alerts of scheduled tasks, phone tools, the chat list and the
chat header.

### Fixes

- **Long chats:** long chats are fast again when you type, read a streamed answer, scroll and open them.
- **Chat list:** new chats show again when an older chat has an invisible character in its preview.
- **Chat header:** the messages no longer move when "Updating…" shows under the name of the agent.
- **Scheduled task alerts:** a tap on the alert opens the chat where the agent made the task. If no chat has the
  task, the tap opens the task in **Scheduled tasks**. This needs plugin 3.23.0 or later.
- **Phone tools:** after the app restarts, a chat gets its phone tools back.

## 2.6.2

This release shows templates by category and puts the reasoning of a bot into one folder.

### Templates by category

The template lists now show the templates in groups by category. This applies to Agent Studio, **Browse all**,
**New Bot** › **Templates** in Simple Bot mode, and the **Blueprints** of Feed, Ideas and Goals.

- Type in the search field to find a template.
- Tap a category chip to show only that category. Tap it again to show all.
- Your own templates (**My Templates**) show first.
- Use the **Sort** button to sort by **For you**, **Newest** or **Most used**.

### Reasoning in one folder

In Simple Bot mode, with **Show reasoning** on, the notes that a bot writes before its answer are in one folder.

- The folder is open while the bot works.
- When the bot answers, the folder closes in the same place.
- Tap the folder to open it or close it at any time.

## 2.6.1

This release adds an optional chat title and error codes for notification setup. It also fixes problems with
Chat Info, bots on other computers, new Bot Chats, Composio Apps, phone tools, and the Mac app.

### Show the title of the chat

You can show the title of the chat under the name of the agent. This setting is off by default.

1. Open **Settings**.
2. Select **Chat**.
3. Turn on **Session title**.

### Error codes for notification setup

If notification setup stops, the app shows a short code (for example **NS-102**) and a message that tells you what
to do. Select **Copy Details** to copy the code and the step. Send them to us when you ask for help. The details
do not include addresses, names or keys.

### Fixes

- **Chat Info:** You can open Chat Info from every chat again. Select **⋯**, then **This chat**, then
  **Chat info**.
- **Bots on other computers:** In Simple Bot mode with **Multi-gateway** on, a bot on another computer opens with a
  loading animation. Select **Cancel** to stop. If the other computer does not answer in 20 seconds, the app goes
  back to the computer that you used before and tells you.
- **New Bot Chats:** If the connection stops while the app makes the first Bot Chat of an agent, the app tries
  again. You can always start new chats with that agent.
- **Composio Apps:** The app tests that your agent can reach Composio before it shows "can use these apps". If the
  test fails, select **Sign in for my agent**. Use your Composio apps in a new chat. A chat that was open before you
  turned on Composio does not get them.
- **Phone tools:** The app connects the phone tools only in chats with the agent that has the bighelp plugin.
  **Settings** › **Permissions** tells you which agent that is.
- **Mac:** The ☰ menu and the Settings rows show a highlight under the pointer. Settings uses switches. Sheets do
  not show a drag bar.

## 2.6.0

This release makes the first setup easier and adds a new reaction bar, bot templates, and Files and Media for
each bot.

### A simpler first setup

After you connect your computer, the app shows these steps:

1. **Add the bighelp plugin.** This step is optional. The screen shows what the plugin adds. Select
   **Install Plugin** to install it with one tap, or select **Skip**.
2. **Turn on notifications.** The app shows this step only after it installs the plugin. Select
   **Turn On Notifications**, or select **Skip**.
3. **Choose your mode.** Swipe through the 3 cards: **Bots**, **Sessions**, and **Code**. Tap a card to see a
   preview of the mode. Then select **Use** and the name of the mode.

- **Bots** opens Simple Bot mode.
- **Sessions** opens the full app with its usual settings.
- **Code** opens Bighelp IDE.

You can change the mode later in Settings.

### Before you start

- Update the bighelp plugin on your computer to version 3.20.0 or later. The app shows the update. Templates need
  3.19.0 or later, and Files for each bot needs 3.20.0 or later.

### A new reaction bar

Touch and hold a message. A bar of reactions shows above the message, and the menu shows below it, as in Messages.

- Tap a reaction to send it. The menu closes.
- Your reaction has a highlight. Tap it again to remove it.
- Tap **+** to see all the reactions.
- The menu has no **React** item now.

On a Mac and on Apple Vision Pro, the reactions are the first row of the menu.

### Templates for new bots

In Simple Bot mode, **Create New Bot** has a **Templates** button at the top right.

1. Select **Templates**.
2. Select a template. If the template has fields, fill them in.
3. Type a name for the bot and select a picture.
4. Select **Create**.

The template gives the bot its role, its vibe, and its instructions. The name of the template shows under
**Templates**. To remove the template, select the **x** on it.

### Save a bot as a template

1. Open the profile of a bot.
2. Select the **Share** button.
3. Type a name for the template.
4. Select **Save**.

The app saves the template on your computer, not on your phone. The template keeps the role, the vibe, and the
instructions of the bot. It does not keep the picture.

**My Templates** at the top of the template list shows your templates. To delete a template, touch and hold it.
The app does not show a damaged template. The other templates stay available.

### Files and Media for each bot

The profile of a bot has 2 new tabs after **Computer**:

- **Files** shows the work folder of the bot on your computer. Select a folder to open it. Select a file
  to see it. The app shows pictures, PDF files, videos, and text. Markdown files show with their format.
- **Media** shows the photos and videos from your chats with the bot. Select a photo to see it, or a video to
  play it.

Each bot shows its own work folder. To see the files of all your bots, update the bighelp plugin to version 3.20.0 or
later. With an older plugin, only the bot that runs the plugin shows its files.

### Fixes

- The compaction bar above the message box shows only while Hermes compacts the chat. Before, it showed for
  notices about compaction and for compaction attempts that did nothing, also in chats with most of their context
  window left. This occurred with the default compressor and with context engines such as LCM.
- The bar shows "Compacted" only when Hermes confirms that it compacted the chat.

## 2.5.1

This release adds Simple Bot mode, Teamwork, the Bots widget, and many changes to chats.

### Before you start

- Update the bighelp plugin on each computer to version 3.18.0 or later. The app shows the update.
- Teamwork, the live status of other agents, and the Stop button for busy chats need plugin 3.16.0 or later.
- Alerts for messages between agents need plugin 3.17.0 or later.
- Plugin 3.18.0 keeps your chats open when your phone loses its connection, as Hermes keeps the chats of
  Hermes Desktop. Before, Hermes closed them, and a computer that removes old closed chats deleted them.

### Simple Bot mode

Simple Bot mode is a calm home screen that shows only your bots. It is off by default.

To turn on Simple Bot mode:

1. Open Settings.
2. Select **Experience**.
3. Turn on **Simple Bot mode**.

To return to the full app, open Settings in Simple Bot mode and set **Simple Bot mode** to off.

**The home screen**

- The top of the home screen shows your primary bot and your pinned bots. All of them have the same size.
- The top holds 6 bots at most: 3 in each row, and 2 rows.
- A star shows your primary bot. New chats start with this bot.
- The list under the top shows your other bots and your group chats. Each row shows the role of the bot, its last
  message, and the time.
- Your circle at the top left opens Settings. The magnifying glass finds a bot. The plus sign makes a new bot or
  a new group chat.

**Change the order of your bots**

1. Touch and hold a bot or a group chat. The menu opens.
2. Select **Rearrange**.
3. Drag the bots and the group chats to the places that you want. You can change the order of the bots at the
   top too, the primary bot also.
4. Select **Save**. To keep the old order, select **Cancel**.

The app keeps the order for each computer. A new bot or group chat goes to the top of the list.

**The menu for a bot**

Touch and hold a bot. The menu shows the last message of the bot and these items:

- Mark Unread
- Pin or Unpin
- Make Primary Bot, or Replace Primary Bot
- Rearrange
- More: the bot profile, a new chat, routines, and Hide

**Make a bot**

1. Select the plus sign.
2. Select **New Bot**.
3. Type a name.
4. Select a shape and a color.
5. Select **Create**.

**The bot profile**

Select the name of a bot at the top of its chat. The profile shows:

- The character of the bot. Select **More avatars** to use all avatars, the Simple Bot shapes too.
- **Instructions**: what the bot does.
- **Default Model**: the model and the reasoning level that the bot uses.
- **Routines**: tasks that the bot does at set times.
- **Computer**, when the bot has a screen.

**Chats in Simple Bot mode**

- The chat has a Back button, the name of the bot, and a menu.
- Your messages use the bubble color that you select in Appearance.
- The message box says "Ask" and the name of the bot.
- Swipe from the left edge to go to your bots. Swipe from the right edge to open the bot profile.
- The last message of each reply always shows as a normal message.
- The messages that a bot writes while it works go under one "{Bot}'s reasoning" line. When **Show
  reasoning** is on for the chat, the line is open and you see these messages as the bot works. Their text
  is gray. When Show reasoning is off, these messages do not show.

**Voice in Simple Bot mode**

- Voice opens as a bar on top of the chat. The chat stays open and you can type.
- The bar shows the face of the bot and a visualizer. The visualizer shows when you speak and when the bot speaks.
- The bar has buttons to change voice settings, to mute, and to end the call.

**Settings in Simple Bot mode**

Settings in Simple Bot mode is short. It has:

- Your name and photo
- Usage
- Connect apps
- Auto-review and its rules
- Time zone
- Bot Computer
- Notifications and Appearance
- Multi-gateway, with Filter by Gateway, and Active gateway when Multi-gateway is off
- The Simple Bot mode switch and All Settings

**Multi-gateway** shows the bots of all your gateways on the home screen:

- On: the home screen shows the bots of all your gateways. Each bot shows its role. Select a bot to open its
  chat. You can pin bots from all gateways, and your primary bot can be on any gateway.
- The app keeps all your gateways connected while you use Multi-gateway, so a chat opens without a wait.
  When you return to the app, the gateways connect again. While a gateway connects, your bots stay on the
  screen and a line shows that the gateway connects.
- **Filter by Gateway** (on or off): when it is on, a filter button shows next to Search. Select a gateway
  to see only its bots, or select **All Gateways**.
- Off: the home screen shows the bots of one gateway. Select **Active gateway** to change the gateway.

When Simple Bot mode is on, the app always opens on your bots. The **Open on** setting has no effect.

**Auto-review** changes the approvals setting of Hermes for your primary bot:

- On: a reviewer approves routine actions and asks you about risky actions.
- Off: the bot asks you before each action.

Auto-review never turns approvals off.

### Teamwork

Teamwork lets the agents on a computer know each other and ask each other for help. Teamwork is off by default.
It needs the bighelp plugin.

To turn on Teamwork:

1. Open Settings.
2. Select **Assistants**.
3. Turn on **Teamwork**.

In Simple Bot mode, Teamwork is in Settings too.

When Teamwork is on:

- Each agent gets a short brief in bighelp chats. The brief gives the name and the role of each other agent.
- The brief tells the agent to send work to the agent whose role is a match, without a request from you.
- The brief tells the agent how to ask another agent, what to send, and to ask some agents at the same time when
  the questions do not depend on each other.
- The brief also gets to chats that are open. Your main agent gets it in its next reply. Other agents get it when
  their chat starts again.
- The brief changes when you add or remove an agent.

When you set Teamwork to off, the plugin removes only its own text.

Give each agent a clear role in its profile. The roles help your agents send work to the correct agent.

### Agents that talk to each other

- When an agent sends a message to another agent, the chat shows one line with their faces. For example: "Asked
  Big Bob" and then "Big Bob answered".
- Select the line to read what the agents said.
- The line shows when tool calls and reasoning are hidden. The line stays outside the "Worked for" fold.
- The answer shows when it arrives. You do not need to refresh the chat.
- When you open the chat of an agent that works on a request from another agent, the chat shows the typing
  bubbles. The Stop button stops the agent.
- The chat list shows the answer of the other agent, not the raw message text.

You can get an alert when one agent sends a message to another agent. For example, you get the answer that
Big Bob sends after your primary bot gives work to Big Bob. The alert shows the name and the picture of Big
Bob, and opens the chat of your primary bot. To turn on these alerts:

1. Open **Settings**, then **Notifications**.
2. Turn on **Agents messaging each other**.

### The Bots widget

The Bots widget shows bots on your Home Screen. Select a bot to open its chat.

- The small widget shows 1 bot. The medium widget shows 2 bots. The large widget shows 4 bots.
- You select the gateway and the bots.
- The widget keeps your bots when you close the app. Select a bot to open bighelp at the chat of that bot.
- When a widget is on your Home Screen, iOS lets bighelp get new data from your computer from time to time,
  also when the app does not run. iOS decides when. To allow this, keep **Background App Refresh** on for bighelp
  in the Settings app of your iPhone.

To add the widget:

1. Touch and hold your Home Screen.
2. Select **Edit**, then **Add Widget**.
3. Find **bighelp** and select **Bots**.
4. Select the size, then **Add Widget**.
5. Touch and hold the widget and select **Edit Widget**.
6. Select the gateway and the bots.

### Chats

- The voice mode button is in the message box. When you type, it changes to Send. There is no other microphone
  button.
- The expand button is next to the message box. It shows when your text has more than one line.
- The Stop button is black with a white square in light mode, and white with a black square in dark mode.
- A Markdown file in a chat opens formatted. Use the Preview and Raw switch to see the text without format.
  Save and Share stay.
- When you open a "Worked for" fold, the tools show directly. There is no second fold in it.

### Fixes

- When you select a notification for a chat that is open, the app goes back to that chat. Before, it opened a
  second copy that scrolled slowly. Widgets and links work the same way.
- Long chats with many tool calls redraw much faster, for example while a reply streams in.
- When you change between light and dark mode, the screen and its sheets change at the same time.
- In Simple Bot mode, the text in Settings is easy to read in dark mode.
- Pinned bots in Simple Bot mode: you can pin 5 bots next to your primary bot. Before, pins that the home screen
  did not show used some of the space.
- In the plugin: the names of agents show correctly on Hermes 0.22 and later, and plugin updates work there.
- In Simple Bot mode, a message from your primary bot stays in the chat while other agents work. Before, some
  messages went away until you refreshed the chat.
- In the all-agents view, the other computers stay connected for a short time when you leave the app. When
  you return, they connect again at once.
- Widgets keep their content when you open or close the app, when you change the gateway, and when a
  Shortcut or your Apple Watch uses bighelp. Before, some widgets went empty, for example the Bots widget
  showed "Add bots in bighelp".
- Your chats do not go away when Hermes closes their connection. Before, an open chat could show "Route
  unavailable", and a chat could go away from your list until you refreshed it.
- The chat of each bot stays in your list. Before, it went away after the app was in the background.
- Chats that Hermes archives because nobody used them for some days stay in your lists.
- **Archived Chats** shows the chats that someone archived, with the app or channel of each chat (for
  example iMessage). Select a chat to restore and open it. Find it in the options menu of Sessions, and in
  Settings in Simple Bot mode.
- Add Host in Settings opens correctly. Before, Settings covered it.
- The Send button stays on while the chat gets new messages from your computer. Before, it was gray for a short
  time each time the chat checked for new messages.
