# Agents' HTML apps

An agent can make an interactive app for the person: a small tool, a dashboard, a planner. The
agent writes the app as one HTML page. The chat shows a native card for the app, and **Open App**
shows the page full screen. The chat never draws the HTML, so a big app cannot slow the chat down.

The plugin feature is `native-html-apps-v1`. The plugin's side is in bighelp-plugin's
docs/HTML_APPS.md.

## How an app gets to the chat

1. The agent calls the plugin's `bighelp_show_app` tool with a title, a description and the HTML
   (or an HTML file it wrote). It can also give data for the app, and it can let the app send
   answers.
2. The plugin keeps the app on the computer and gives the agent a small `loopdy.card` to put in its
   answer, the same as other cards. The HTML is not in the answer.
3. The plugin accepts an app card only in a chat whose app says that it can show one: the speaker
   note's `renders` has `html_app` when the plugin lists the feature. Older bighelp apps never get
   the card. The agent is told to ask the person to update bighelp.

## The card

The card has one element, `html_app`, with exactly these props:

| Prop | Value |
|---|---|
| `app_id` | `a_` and 32 lowercase hex digits |
| `description` | 1 to 240 characters |
| `sends_answers` | The app can send the person's answer to the agent |
| `live` | The app has data that can change while it is open |

The card's `title` is the app's title. An app is its card's only element. `HTMLAppCard` reads the
props, and the card validator uses the same reader, so a card that validates always opens.

`HTMLAppCardView` shows an icon, the title, the description, a "Sends answers" or "Live data" tag,
and **Open App**. After the person sent an answer from the app, the card says "You sent an answer".

## The page

`HTMLAppScreen` shows the app full screen, with **Done**, the title, and "Live, updated 2:14 PM"
for an app with data. The ••• menu has **Reload**.

`HTMLAppWebView` loads the page from its own origin, `bighelp-app://<app id>/`, through a URL scheme
handler. bighelp renders what the agent made:

- The page can load any script, style, font, picture or API. bighelp does not limit sites or
  libraries.
- Each app has its own origin, so its storage is its own. All apps share one website data store,
  apart from the rest of bighelp's web views.
- Links and new windows open outside bighelp. The page cannot replace itself with another site.
  Frames in the page load as the page asks.
- The camera and the microphone are refused. `alert` and `confirm` show as iOS alerts.
- The page follows the app's light or dark look through `prefers-color-scheme`. A page without a
  viewport tag gets `width=device-width`.

The phone keeps the last HTML of each app in Caches (`HTMLAppCache`, 40 apps). When the person opens
an app, bighelp sends the hash of its copy, and the plugin sends the HTML again only when it changed.
Away from the computer, the copy on the phone still opens.

## The page API

bighelp adds `window.bighelp` to the page before the page's own scripts run (`HTMLAppBridge`):

| Call | What it does |
|---|---|
| `await bighelp.getData()` | The app's latest data, or `null` |
| `bighelp.onData(fn)` | Calls `fn(data)` once when there is data, and again each time it changes while the app is open. Returns a function that stops it. |
| `await bighelp.sendAnswer(answer)` | Only for an app with `sends_answers`. `answer` is text, or an object of names with text, numbers, yes or no, or lists of text. bighelp shows the exact message and waits for **Send**. Returns `true` when sent, `false` when the person cancels. |
| `bighelp.close()` | Closes the app |

While a live app is open and bighelp is in front, bighelp reads the app's data every 5 seconds and
gives the page the data when it changes.

## Answers

An answer goes to the agent as the person's next message, through the chat's normal send path
(`ChatCardInteractionHandler.reply`), the same as a form answer. It steers a running turn, or waits
as a staged message while the chat has no connection.

An object answer reads like a form answer:

```
My answers to “Trip budget”:
- Travel: $1,100
- Food: $800
- Fun: $500
```

A text answer:

```
My answer from “Trip budget”:
Let's do the mountains.
```

The page cannot send a message by itself: the panel shows the message, and nothing goes until the
person taps **Send**.

## Routes

Both routes are reads, `POST /api/plugins/loopdy/native/html-apps/{operation}`:

- `html-apps/get` with `{"agentId", "appId", "knownSha256"?}` answers
  `{"app": {"appId", "title", "description", "sendsAnswers", "live", "revision", "updatedAt",
  "htmlSha256", "htmlBytes"}, "html"?}`. `html` is base64 and is left out when `knownSha256` is the
  same as `htmlSha256`. The app checks the size and the hash of the HTML.
- `html-apps/data` with `{"agentId", "appId"}` answers
  `{"appId", "data", "updatedAt", "dataSha256", "problem"}`. `problem` is `missing`, `invalid` or
  `too_large` when the data file cannot be read.

`app_not_found` means the app is not this agent's, or is gone. A host without the feature makes the
app say to update the plugin.

## Demo and tests

Demo mode's computer (`DemoHTMLAppsClient`) has two sample apps: Trip budget, which sends answers,
and Garden watch, whose data changes every few seconds. `-test-html-apps` opens a chat with a card
for each. `HTMLAppTests` covers the card, the answer text, the routes and the speaker note.
