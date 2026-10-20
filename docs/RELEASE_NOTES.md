# Release notes

These notes tell people what is new in each bighelp release. They use ASD-STE100 Simplified Technical English:
short sentences, one instruction in each step, and the active voice.

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
