# Spaces

A space is a live panel on Today. A bot drafts it in a chat. The person adds it with **Add to
Today**. A routine on the computer then keeps it current. Each space has a card (what the panel
shows) and an HTML page (what a tap opens).

The plugin feature is `native-spaces-v1`. This page is the app's side. The wire contract (routes,
the space object, errors, the routine) is bighelp-plugin's docs/SPACES.md. Do not copy it here.

The code is in `Bighelp/Spaces/`. Today's grid is in `Bighelp/Today/`.

## Where the spaces come from

- `SpacesHost` lists the person's computers (`SpacesComputer`). The computer in use is first. The
  app sets it up in `BighelpApp.wireSpaces`.
- The computer in use, and the others that the all-hosts view or Multi-gateway keeps connected, are
  read live. Every other computer shows what the phone kept.
- Each computer has one `SpacesStore`, kept by its cache scope (`WorkspaceAuthority.cacheScopeID`).
  A reconnect is a new owner with the same scope, so it keeps the same store.
- `TodaySpacesModel` reads all the stores together, in one order: by position, then the computer,
  then the title.
- Demo mode uses `DemoSpacesClient` for the spaces and `DemoHTMLAppsClient` for their pages.

## Reading

- Today reads every computer when it shows, when the app comes back, and every minute while it
  shows (`TodaySpacesModel.watch`).
- A read names the computer's bots (64 at most a call). Before the bots are known, nothing is read.
- The read sends the card hashes the phone has (`known`). The computer leaves those cards out.
  Cards it left out to keep the answer small (`cardOmitted`) are read with `get`, 24 at most a read.
- The phone keeps a copy of each computer's spaces in Caches (`BighelpSpaces`). Today draws it at
  once. A copy over 6 MiB is kept without its cards.
- A computer that is not connected keeps its panels. Each panel says "Not connected".
- Only the plugin's own context says the feature is missing. Then Today shows "Update the plugin on
  <computer> to see its spaces." A refused route during a reconnect never says that.

## Adding

- The chat draws the `space_draft` card (`SpaceDraftCardView`). It reads the draft with `get` and
  shows the panel as Today will draw it.
- The person picks Small, Wide or Tall. Add sends the revision the card shows.
- Add puts the space after every space on Today. If Today did not show yet, the model reads the
  computer first, so the space is on Today at once.
- The answers the card acts on:

| Answer | The card |
|---|---|
| The space | On Today, with Open Today |
| `draft_changed` | Reads the draft again: "The bot changed this space. Check it, then add it." |
| `invalid_request` (422) | "This space's script is missing. Ask the bot to make it again." |
| `spaces_full` | "This bot has as many spaces as it can keep. Delete one on Today first." |
| `schedules_unavailable` | "Your computer can't run scheduled tasks right now." |
| `space_not_found` | Removed |
| No answer | "Could not reach your computer. Try again." |

- Open Today calls `SpaceDraftCardHost.openToday`. The shell sets it.

## Size, hide and order

- A space's size, hidden state and place belong to its computer, not to this phone. Its panel
  descriptor has `keepsOwnLayout`, and `TodayPanelLayoutStore.ownedChanges` sends the person's
  changes to `SpacesTodayBridge`.
- A change shows at once (`SpacesStore.stage`), then goes to the computer with `update`.
- A refusal undoes it. No answer keeps it, and the next read sends it again.
- A change waiting for its answer is sent again only as the same request, with the same
  `operationId`. A change on top of it is a new request with a new `operationId`. The plugin refuses
  an `operationId` it saw with another body.
- Edit's drag gives every space a new place, 1,024 apart. The new order shows before any computer
  answers, so a panel never jumps back.
- A hidden space keeps updating. Edit lists it under Hidden.

## Update now

- Update now (the panel's menu) and Try again (a stopped panel) call `refresh`.
- A script runs at once (`ran: "now"`). An AI routine runs on the computer's next tick (`queued`).
- A paused AI routine runs nothing (`paused`). The panel says "Paused in Scheduled tasks".
- `routine_failed` (502): the run failed. The panel shows the space as the computer read it, with
  "Its update failed".
- `refresh_too_soon`: "Try again in a minute".

## Deleting

- Delete asks first ("Delete this space?"). The space goes off Today at once.
- No answer, no connection, or `schedules_unavailable` (503): the computer has not finished. The
  space stays off Today, and the same request (same `operationId`) goes again at each read until
  the computer answers. The phone keeps the waiting delete across launches.
- A definite refusal brings the space back, in its place.

## What a panel shows

`SpacePanelView` draws the title, the bot (and the computer with two or more), the card at the
panel's size in a fixed frame, and one footer line (`SpacePanelFooter`):

| State | Footer |
|---|---|
| Fresh or stale | "Updated 2:14 PM" (the space's own `updatedAt`), and "Uses AI" when it does |
| Stopped (`missing`, `failed`, `late`, unknown) | "Stopped updating" and Try again |
| Paused in Scheduled tasks | "Paused in Scheduled tasks", no Try again |
| `script_changed` | "Stopped: its script changed", no Try again. The bot drafts it again and the person adds it again. |
| Not connected | "Not connected"; the last card stays |
| Card not read yet | A still placeholder |
| Card the app can't draw | "Can't show this" |

A tap opens the space's page in `HTMLAppScreen`, on the space's own computer
(`TodaySpacesModel.pageConnection`). A space's page never sends a message.

## Demo and tests

- `-use-demo-fixtures -test-spaces` opens the finance bot's chat with a space draft.
- `-test-spaces-today` shows Today's grid alone with the demo computer's spaces
  (`SpacesTodayFixture`).
- `DemoSpacesClient` answers as the plugin does: the draft's revision, an `operationId` that only
  repeats the same request, the refresh gap, a paused AI routine, a changed script, a script that is
  gone (`missingScripts`) and a delete Hermes can't finish yet (`stuckTasks`).
- Unit tests: `SpacesWireTests`, `SpacesStoreTests`, `TodaySpacesModelTests`,
  `SpacePanelStateTests`, `SpaceDraftCardStateTests` and `TodayPanelLayoutTests`. The shared card
  example is `BighelpTests/Fixtures/CardExamples/static-space-draft.json`, the same bytes as the
  plugin's.
