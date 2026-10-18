# Release notes

These notes tell people what is new in each bighelp release. They use ASD-STE100 Simplified Technical English:
short sentences, one instruction in each step, and the active voice.

## 2.5.1

This release adds Simple Bot mode, Teamwork, the Bots widget, and many changes to chats.

### Before you start

- Update the bighelp plugin on each computer to version 3.17.0 or later. The app shows the update.
- Teamwork, the live status of other agents, and the Stop button for busy chats need plugin 3.16.0 or later.
- Alerts for messages between agents need plugin 3.17.0 or later.

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
- Each message from a bot shows as a normal message. The messages do not turn gray and do not go away when the
  bot continues to work.

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
- The Send button stays on while the chat gets new messages from your computer. Before, it was gray for a short
  time each time the chat checked for new messages.
