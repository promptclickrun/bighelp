# iPhone tools for Hermes

> Current transport contract: [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md). Its Link delivery discussion is historical; current native tools use the authenticated native device-tools bridge. Where transport details differ, use the versioned native contract and its source links.

Requires bighelp plugin 2.11.0 or later on the Hermes host.

Host plugin 2.11.2 is required for the corrected phone-tool delivery path.
Version 2.11.1 accepts Hermes' canonical composite turn IDs; 2.11.2 schedules the
whole tool operation on the gateway's Link event loop. Hermes async tools run on
separate worker loops and cannot directly acquire the gateway connection's send
lock or own its response futures. Update the host plugin and restart the gateway
to activate these fixes. Build 13 and existing iOS permissions remain compatible.

## User contract

EventKit reminder fetch completions run on EventKit's queue. Their closure must
be explicitly `@Sendable`, use nonisolated value projection, and resume only a
Sendable result into the main-actor owner. Implicit main-actor inheritance caused
a verified device crash when filtering reminders. The background-callback test
in `AppleDeviceToolServiceTests` reproduces that crash before the correction;
keep the post-fetch authorization check. See Apple's
[asynchronous reminder retrieval](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders).

Device access has independent switches for Calendar, Reminders, Contacts, Photos,
Location, Arriving and leaving, Alarms and timers, Music, Focus and Shortcuts. Apple Health
access was removed in 2.3.0 (105): App Review (guideline 2.5.1) refuses HealthKit in an app
whose main features don't need health data. The phone never lists or runs `health.read`, so
the plugin's `iphone_health` tool answers `authorization_required`; a saved Health grant is
dropped when read.
Every data control starts off. Enabling one requests its native iOS permission from
that explicit foreground action. Appearance ("Let agents change how bighelp looks") is
the exception: it shares no data and Appearance undoes any change, so it's on until the
person turns it off, and it needs no iOS permission. Calendar and Reminders authorize direct reads,
creation, updates and deletion after enablement, with no per-operation approval.
Location is read-only. OS permission by itself never enables agent access.

A grant belongs to this phone (`DeviceToolPermissions.grantsKey`): every host and
every agent on it can use it, and it stays through app updates, reconnects and new
sign-ins until the person turns the switch off. Grants saved for each host before
2.6.15 (`loopdy.device-tools.v1.<scope hash>`) are merged into the phone's list once.
iOS saying no (access taken back in iOS Settings, Location Services off) never turns a
switch off: the tool is paused (`isUsable` is false, it isn't offered to the host) and
the row says to allow access in iOS Settings; it comes back when iOS allows it again.
Turning a control off invalidates active work immediately. Switching host, signing
out, the background grace ending or losing protected-data access invalidates in-flight
operations. Account erasure deletes persisted grants and mutation outcomes.
Re-enabling a grant cannot revive a read started under an older grant revision.

The phone must be unlocked and connected, and bighelp open: active, or inactive (a
notification pulled down, Control Center, a system question), or within the background
grace (`BighelpBackgroundGrace`, 25 seconds) after it goes to the background. iOS asks
its permission questions only while bighelp is active. After the grace the channel
closes with `reason: "paused"` (plugin `native-device-tools-wait-v1`), so the host keeps
a call waiting for the phone to come back instead of failing it at once. No wake-up
guarantee is offered. Unavailable or denied access is a failure, never fabricated
empty data.

Requested data is sent to the selected Hermes host and its AI provider. It may
be retained in the ordinary conversation/tool history. It is not used for
advertising or analytics. bighelp's mutation journal stores only request hashes,
expiry and identity/reconciliation metadata, never event text,
reminder text or request arguments. The journal is protected, atomically written,
excluded from backups and bounded to 512 records / 2 MB. No raw Apple data should
be added to diagnostics.

Hermes and the future bighelp Native harness remain complementary. The unfinished
Native harness is not required and is not treated as operational.

## Components and required versions

| Component | Responsibility |
| --- | --- |
| Hermes `ToolExecutionContext` extension | Carries immutable authenticated ingress ownership to official plugin handlers and hooks, with official session/turn/tool-call IDs. |
| bighelp plugin 2.11.2 | Registers `iphone_calendar`, `iphone_reminders` (and `iphone_health`, which the app no longer offers); uses the gateway connection loop to target the verified phone and correlate canonical Hermes turn IDs. |
| Link relay with `directed-frames-v1` | Negotiates exact-recipient delivery and queues only for that active paired device. Legacy sockets never receive a broadcast fallback. |
| iOS `DeviceToolPermissions` | Persists opt-in grants and fences asynchronous work by scope/revision. |
| iOS `DeviceToolCoordinator` | Validates envelopes, deadlines, ownership and grants; bounds concurrency and journals mutation outcomes. |
| iOS `AppleDeviceToolService` | Executes the finite EventKit and location operations with authorization checks around native boundaries. |
| iOS live socket | Receipts authenticated requests before native execution and sends directed correlated results without blocking chat streaming. |

The generic Hermes source extension is documented in
`docs/TOOL_EXECUTION_CONTEXT.md` in the Hermes checkout. It is required: plugin
registration omits phone tools on older Hermes versions. The context is
runtime-only, excluded from prompts, tool schemas, transcripts and session
persistence. Queued events retain exact ownership; different owners are not
merged or steered into each other's turns. CLI, cron, restart-recovered events
and delegated children lack phone context and fail closed. Never infer a phone
from the last active chat or model-provided arguments.

The plugin constructs context from the verified Link frame's phone ID and
phone epoch, with the authenticated host ID as an attribute and profile as
scope. Phone and host authorization epochs are independent.

Every agent on the host has the phone tools when the plugin lists
`native-device-tools-agents-v1` (plugin 3.30.0): Hermes loads a separate copy of the
plugin for each profile in the dashboard process, and they share one tool hub, so any
agent's chat opens its own channel. An older plugin gives them only to the agent it
serves (`servingProfileId` in `/native/context`, usually `default`) and refuses a
channel for any other agent (`profile_not_served`); with it, the phone opens a channel
only while that agent's chat is open (`NativeDeviceToolSession.servingAgentID`),
another agent's chat sends nothing after the context check, and Device access names
the agent that can use the shared data.

One chat has one phone. The plugin refuses a second channel for a chat
(`channel_ambiguous`) and never picks a phone by which one came last. A channel
can outlive its app: killed or relaunched (an Xcode run, a crash), or with its
close lost on a reconnect, it stays until its 30-second lease ends. A newer
plugin lets the same phone (the same person, `deviceId` and `hostId`) replace
its own channel at once. With an older one, the phone sends no close for the
refused channel and tries again after the lease, up to three more times 32
seconds apart (`NativeDeviceToolSession.runReopeningWhileHeld`); any change to
the chat or connection cancels the wait. While it waits, Device access says it
connects again in a moment; if another device keeps the chat, it says so.

## Transport and ownership

The existing encrypted Link connection carries version-1
`device.tool.status`, `device.tool.request` and `device.tool.result` payloads.
The outer frame's `targetDeviceId` must identify an active opposite-role device
in the same account. Unknown, revoked, wrong-role, self or unsupported targets
are rejected without fan-out. This controls routing; existing account content
encryption is shared across paired account participants, not a new
recipient-specific encryption scheme.

Requests and results bind `requestId`, `deviceId`, `hostId`,
`authorizationEpoch`, `sessionId`, `agentId`, `turnId`, `operation` and
`sentAt`; requests also carry `expiresAt` and bounded arguments. Official
tool-call coordinates generate a stable request ID. Reusing that ID with
different arguments produces a conflict. The native request limit is 20 KB;
the plugin additionally limits arguments to 16 KB. Native results are bounded
to 128 KB. Host timeout is normally 30 seconds (bounded to 20–60 seconds);
the native envelope permits no more than 120 seconds.

Status is advisory. Every operation still checks the live native grant,
open (active, inactive or background grace)/protected-data state, selected host,
account and expiry. Results
recheck those conditions after native execution and while waiting for the
outbox. Reconnect or backpressure cannot replay private results after permission
revocation, ownership change or downgrade to a legacy relay. A pending private
result without its original in-memory authorization guard is retired through
authenticated outbox reconciliation.

Native work permits at most four active operations and one mutation. The plugin
keeps bounded pending requests and metadata-only mutation outcomes; read payloads
are returned only to their active caller, not cached for later retries.

## Supported operations

| Tool | Operations and constraints |
| --- | --- |
| `iphone_calendar` | List events in a bounded date range; create; update/delete an exact ID with expected revision. |
| `iphone_reminders` | List with optional list IDs, completion and undated filters; create; update/delete an exact ID with expected revision. An optional date filter requires start, end and time zone together. |
| `iphone_location` | `current` only, with no other arguments: where the phone is right now. Needs plugin feature `native-device-location-v1`. |
| `iphone_appearance` | `get` (no arguments) or `set` with `mode` and/or `color`: light or dark mode and the chat color. Needs plugin feature `native-device-appearance-v1`. |
| `iphone_navigation` | `places` (optional `query`, `limit`) or `open` with `place`, optional `bot` and `note`: shows the person a page or setting in bighelp. Needs plugin feature `native-device-navigation-v1`. |
| `iphone_contacts` | `list`, `create`, `update`, `delete`. Needs `native-device-contacts-v1`. |
| `iphone_photos` | `list`, `albums`, `get`, `save`, `update`, `createAlbum`, `delete`. Needs `native-device-photos-v1`. |
| `iphone_geofences` | `list`, `create`, `delete`: places the phone watches, and a message to the chat on arrival or departure. Needs `native-device-geofences-v1`. |
| `iphone_alarms` | `list`, `create`, `update`, `delete`: alarms and timers (AlarmKit, iPhone and iPad on iOS 26 and later). Needs `native-device-alarms-v1`. |
| `iphone_music` | `nowPlaying`, `search`, `library`, `play`, `control`, `createPlaylist`, `addToPlaylist`, `addToLibrary`. Needs `native-device-music-v1`. |
| `iphone_focus` | `current`: the Focus filter that's on and the person's note for agents. Needs `native-device-focus-v1`. |
| `iphone_shortcuts` | `list`, `run`: only the shortcuts the person picked. Needs `native-device-shortcuts-v1`. |

Each tool sends `operation` plus the arguments below; the phone's operation is
`<kind>.<operation>` (`iphone_photos` `createAlbum` is `photos.createAlbum`).
`DeviceToolCatalog` lists them all, with which ones are journaled. Dates are
ISO-8601 with an offset or `Z`. IDs are opaque strings of at most 512
characters. Unknown keys, a wrong type or an out-of-range value is
`invalid_arguments`, checked by the plugin before the call leaves the host and
again by the phone before it touches anything. An `update` that changes nothing
is `invalid_arguments` too. Results are bounded to 128 KB on both sides.

Calendar creation accepts title/start/end/time zone and optional calendar,
location, notes and URL. Recurring event results carry `occurrenceStart`;
updates/deletes of recurring events require that exact occurrence and use
EventKit's single-occurrence span. Whole-series writes are not exposed.
Read-only calendars and stale revisions fail explicitly.

Reminders accept title, list, start/due date, time zone, notes and priority;
updates also accept completion. Both native APIs recheck system authorization
before execution. Neither API is bridged through arbitrary selectors, an
additional HTTP service or model-supplied executable code.

## Location

`location.current` (`DeviceLocationTool`) returns `latitude` and `longitude`
(six decimals), `horizontalAccuracyMeters`, an ISO-8601 UTC `timestamp`,
`precise`, and when Apple can name the spot a `place` with any of `street`,
`neighborhood`, `city`, `region`, `country` and `postalCode` (each trimmed,
control characters removed, at most 100 characters). On iPhone, iPad and Mac the
address comes from `CLGeocoder`, which gives it in parts back to iOS 17; on
Vision Pro, where that's deprecated, MapKit's `MKReverseGeocodingRequest` names
only the city and country. A fix takes at most 15 seconds and an address 5.

- The Location switch asks iOS for While Using the App, never Always. A call while
  bighelp isn't open fails like the other tools (`device_unavailable` on the phone,
  `phone_unavailable` on the host); in the background grace iOS may give no fix
  (`unavailable`).
- `NSLocationDefaultAccuracyReduced` keeps approximate location the default.
  When a call finds approximate access, iOS asks once for precise location
  (`requestTemporaryFullAccuracyAuthorization`, purpose key `AgentRequest` in
  `NSLocationTemporaryUsageDescriptionDictionary`). The question is asked only
  while bighelp is active and after the call is re-authorized (switch, chat, open),
  and the grant is re-checked after it. Otherwise the call keeps approximate. If the person keeps approximate, `precise` is false, a
  `note` says it's a rough area, and `place` has no street, neighborhood or
  postal code.
- It's a read: never journaled, never kept by the plugin for a retry.
- Older plugins reject `location` in the channel's `enabled` list, so the phone
  sends it only when `/native/context` lists `native-device-location-v1`, and
  Device access says to update the plugin.
- Demo mode (`-use-demo-fixtures`) answers from `DemoDeviceLocationProvider`, a
  made-up place, and never asks iOS.

## Appearance

`appearance.get` and `appearance.set` (`DeviceAppearanceTool`) read and change
`SettingsStore`, the same values Settings › Appearance changes, so the person's
next pick there wins.

- `get` returns `mode` (`system`, `light` or `dark`), `color` (a color name, or
  `#RRGGBB` for a custom color), and the choices: `modes` and `colors` (each
  `BighelpBubbleColor`'s name as Appearance shows it, lowercased: `lavender` …
  `ink`).
- `set` takes `mode`, `color` (a name in any case, or `#rrggbb`) or both, and
  returns the `mode` and `color` the app shows now. A name goes through
  `pickBubbleColor`, so it replaces a custom color; a hex becomes the custom
  color. The page colors don't change.
- Every value is checked before anything changes: no fields, an unknown field,
  mode or malformed hex is `invalid_arguments`; a name the app doesn't have is
  `unknown_color`. The change is applied only after the coordinator's
  authorization passes again (switch on, chat current, app in front).
- It's never journaled: setting a look twice is the same as once.
- The switch is one setting for every host (`bighelp.device-tools.appearance`,
  missing means on). Off, the phone leaves `appearance` out of the channel's
  `enabled` list, so the plugin answers `authorization_required`; a call already
  on the phone gets `permission_disabled`.
- Older plugins reject `appearance` in `enabled`, so the phone sends it only when
  `/native/context` lists `native-device-appearance-v1`. On its own, Appearance
  never puts "open a chat" or "check the plugin" in Device access; it only says
  when the plugin needs an update. A channel with only Appearance polls every
  8 seconds instead of 0.75, since it opens for every chat with the served agent.
- Demo mode: `-test-agent-appearance '{"mode":"dark","color":"rose"}'` sends that
  one call through the real coordinator and tool when the first chat opens
  (`DeviceAppearanceFixture`, `AgentAppearanceUITests`).

## Navigation

`navigation.places` and `navigation.open` (`DeviceNavigationTool`) let an agent show the
person where something is in bighelp (#662). The app holds the list of places
(`DriveCatalog`): each has an id, a title, one sentence on what it's for, search words, and a
playbook per mode (Bots, Chat, Code). The plugin never holds a copy, so a new place ships with
the app.

- `places` takes an optional `query` (1–120 characters, the person's own words) and `limit`
  (1–20, default 8). It answers `places` (each `id`, `title`, `what`, `steps`, and `needs`:
  `"bot"` for a place inside one bot, else null) and `total`, for the mode the app is in. Nerd
  Mode places are listed only while Nerd Mode is on.
- `open` takes `place` (1–96 characters, lowercase letters, digits, `.` and `-`), and optional
  `bot` (an agent id, 1–96 characters) and `note` (1–160 characters, shown beside the place).
  A place inside one bot opens for `bot`, else for the agent in the chat. It answers `opened`,
  the trail's `steps` and `mode` as soon as the drive starts. It fails with `unknown_place`,
  `not_in_this_mode`, `needs_nerd_mode`, `needs_bot` (no bot with that id on this computer) or
  `busy` (the app isn't ready to drive), before anything moves.
- The drive (`DriveNavigator`) only moves between pages and points at controls. It never taps
  Save, Send or Delete, never changes a switch, and never changes a setting on the way (a bot
  it opens doesn't become the primary bot). Each step lights only once the screen shows it
  happened; a control it points at that never shows leaves the trail where the screen
  stopped. Return to chat puts back the tab and pages the person had; Stay here leaves them on
  the place.
- Like Appearance it shares nothing and needs no iOS permission: its switch ("Let agents show
  you around bighelp", `bighelp.device-tools.navigation`, missing means on) is one setting for
  every host. Neither operation is journaled. The phone sends `navigation` in `enabled` only
  when `/native/context` lists `native-device-navigation-v1`.
- A channel with only Appearance and Navigation polls every 8 seconds, except while the chat's
  turn runs: an agent calls tools only while it answers, and the person who asked to be shown
  is waiting, so then it polls every 0.75 seconds.
- Demo mode: `-test-agent-drive <place id>` (and `-test-agent-drive-note "…"`) plays that drive
  in the first chat that opens (`DriveFixture`, `AgentDriveUITests`).

## Contacts

`contacts.*` (`DeviceContactsTool`), iOS permission `NSContactsUsageDescription`.
With limited access (iOS 18) the agent sees only the people the person shared;
results say `access: "full"` or `"limited"`.

- `list`: `query` (optional, 1–200 characters: matches names, and emails or
  phone numbers when it looks like one), `limit` (1–50, default 20). Returns
  `contacts`, each with `id`, `revision`, and when set `givenName`,
  `familyName`, `nickname`, `organization`, `jobTitle`, `birthday`
  (`YYYY-MM-DD`, or `--MM-DD` without a year), and lists `phones`, `emails`,
  `urls` (`{label, value}`) and `addresses` (`{label, street, city, region,
  postalCode, country}`); plus `truncated` and `access`.
- `create`: at least one of `givenName`, `familyName`, `organization`
  (each ≤ 200); optional `nickname`, `jobTitle`, `birthday`, `phones` (≤ 10),
  `emails` (≤ 10), `urls` (≤ 5), `addresses` (≤ 5). A label is `home`, `work`,
  `mobile`, `iPhone`, `main`, `other` or any text up to 40 characters.
  Returns `{id, revision}`.
- `update`: `id`, `expectedRevision`, and any `create` field. A list given
  replaces the whole list; an empty string or list clears it. Returns
  `{id, revision}`.
- `delete`: `id`, `expectedRevision`. Returns `{id, deleted: true}`.
- `revision` is a hash of the fields the tool reads (Contacts keeps no
  modification date). A changed contact is `stale_revision`; a missing one is
  `not_found`. Notes are never read or written: Apple gives contact notes only
  to apps with a special entitlement.

## Photos

`photos.*` (`DevicePhotosTool`), read and write library access
(`NSPhotoLibraryUsageDescription`). With limited access the agent sees only the
photos the person picked. Attaching a photo in chat still uses Apple's private
picker and needs none of this.

- `list`: `start` and `end` together (creation date), `albumID`, `mediaType`
  (`image`, `video` or `any`, default `any`), `favorites` (bool), `limit`
  (1–100, default 30), newest first. `photos` lists each item: `id`, `revision`, `mediaType`,
  `created`, `width`, `height`, `favorite`, `durationSeconds` for videos, and
  `latitude`/`longitude` (4 decimals) when the photo has a place. Plus
  `truncated` and `access`.
- `albums`: the person's albums and the main smart albums (Favorites, Recents,
  Screenshots, Selfies, Videos): `albums` of `{id, title, count, kind}` (`album`
  or `smart`).
- `get`: `id`, `maxPixels` (256–1024, default 768). Returns the item's fields
  and `image: {format: "jpeg", width, height, data}` (base64, at most 90 KB of
  JPEG, quality stepped down to fit; a video gives its first frame). The plugin
  writes the picture to a file on the host (`bighelp/phone-photos/` in the
  Hermes home, the newest 50 for 7 days) and gives the agent
  `image: {format, width, height, path}` instead of the data, so the agent can
  look at it with its vision tool.
- `save`: `path`, a file on the host (checked by the plugin like
  `attachments/resolve`: an image or video of at most 50 MB), optional
  `albumID`. The plugin grants that path to the calling chat for 10 minutes,
  and the phone downloads it through `attachments/resolve` (as
  `MEDIA:<path>`) and `attachments/fetch`, like a file the agent sent
  (`DirectHermesDeviceHostFiles`). Returns `{id}`.
- `update`: `id`, `expectedRevision` (the item's modification date), and any
  of `favorite`, `addToAlbumIDs`, `removeFromAlbumIDs` (≤ 20 each). Returns
  `{id, revision}`.
- `createAlbum`: `title` (1–200). Returns `{id}`.
- `delete`: `ids` (1–50). iOS asks the person to confirm; Don't Allow is
  `cancelled`. Returns `{deleted: true, count}`.
- Codes: `not_found`, `stale_revision`, `cancelled`, `unsupported_media`,
  `file_too_large`.

## Arriving and leaving

`geofences.*` (`DeviceGeofenceTool`). The switch asks for location While Using,
then Always (`NSLocationAlwaysAndWhenInUseUsageDescription`). With only While
Using, places are watched only while bighelp is open; `background` says which.

- `list`: this host's places: `geofences` of `{id, name, latitude, longitude,
  radiusMeters, on, note, repeats, created, agentId}`, plus `background` and
  `limit` (20, iOS's most for one app).
- `create`: `name` (1–100), `latitude` and `longitude`, or `here: true` for
  where the phone is now; `radiusMeters` (100–5000, default 150); `on`
  (`arrive`, `leave` or `both`, default `arrive`); `note` (≤ 1000, what the
  agent wanted to do then); `repeats` (default false: the place is removed after
  its first event). Returns `{id}`. Full is `limit_reached`. iOS watches places
  only with precise location, so approximate location is
  `precise_location_required`.
- `delete`: `id`. Returns `{id, deleted: true}`.
- When the person arrives or leaves, bighelp sends a message to the chat that
  made the place (same host, agent and session) through the Shortcuts host path,
  even with bighelp closed when Always is allowed: the place, arrived or left,
  the time and the note. If that fails, a notification tells the person.
  One event per place per 5 minutes. Places live on the phone
  (`DeviceGeofenceMonitor`), readable once it has been unlocked after a restart;
  an unreadable store is `storage_unavailable`. A place whose switch was turned
  off is removed at its next event.

Reminders take a place too, with no location permission (iOS Reminders watches
it): `reminders.create` and `reminders.update` accept `locationTrigger`
`{name, latitude, longitude, radiusMeters (100–5000), proximity: "arrive" |
"leave"}`, and `reminders.update` accepts `clearLocationTrigger: true`.
`reminders.list` returns `locationTrigger` when a reminder has one.

## Alarms and timers

`alarms.*` (`DeviceAlarmsTool`), AlarmKit (`NSAlarmKitUsageDescription`), iPhone
and iPad on iOS 26 and later. Device access hides the row elsewhere. The agent
sees and changes only bighelp's alarms, never the Clock app's. A timer counts
down in a Live Activity (`BighelpLiveActivity`).

- `list`: `alarms` of `{id, label, kind (alarm or timer), state (scheduled,
  countdown, paused or alerting), time {hour, minute}, weekdays, date,
  timerSeconds}` (fields as set).
- `create`: `label` (1–60) and exactly one of: `time` `{hour, minute}` with
  optional `weekdays` (`monday` … `sunday`, repeats weekly; without it, rings
  once at the next such time), `date` (one time), or `timerSeconds`
  (5–86,400). Returns `{id}`.
- `update`: `id` and any `create` field; the new schedule replaces the old one
  under the same `id`. Returns `{id}`.
- `delete`: `id`. Returns `{id, deleted: true}`. Missing is `not_found`.
- AlarmKit keeps no label, so the phone keeps each alarm's label beside its id.
  It has no edit either: `update` cancels and schedules again, and puts the old
  alarm back if the new one is refused. When AlarmKit holds no more alarms the
  code is `alarm_limit_reached`.

## Music

`music.*` (`DeviceMusicTool`), MusicKit and the Music app
(`NSAppleMusicUsageDescription`). Playing the Apple Music catalog needs the
person's subscription; without one, `search` and `play` use their library.
The App ID needs the MusicKit app service for catalog requests; without it they
fail as `music_service_unavailable`.

- `nowPlaying`: `{state (playing, paused or stopped), item {id, title, artist,
  album, durationSeconds}, positionSeconds}`.
- `search`: `query` (1–200), `types` (`songs`, `albums`, `playlists`,
  `artists`; default the first three), `source` (`catalog` or `library`,
  default catalog with a subscription), `limit` (1–25, default 10). Returns
  `results` of `{id, type, title, artist, album, source}` (`type` is
  `song`, `album`, `playlist` or `artist`; requests take either form) and
  `subscription` (`canPlayCatalog`). An explicit `source: catalog` without a
  subscription is `subscription_required`; without `source` it falls back to
  the library.
- `library`: `type` (`playlists` or `recent`, default playlists), `limit`
  (1–50). Returns `items` like `search`.
- `play`: `id`, `type` and `source` from a result, or `query` (plays the best
  song match); optional `shuffle`. Returns `nowPlaying`'s fields.
- `control`: `action` (`pause`, `resume`, `next`, `previous`, `stop`). Returns
  `nowPlaying`'s fields.
- `createPlaylist`: `name` (1–100), `description` (≤ 300), `itemIDs` (≤ 100
  songs). Returns `{id}`.
- `addToPlaylist`: `playlistID`, `itemIDs` (1–100). Returns `{id}`.
- `addToLibrary`: `id`, `type`. Returns `{id}`.
- Codes: `subscription_required`, `not_found`, `music_service_unavailable`.

## Focus

`focus.current` (`DeviceFocusTool`) reads bighelp's Focus filter
(`BighelpFocusFilter`, a `SetFocusFilterIntent`). The person adds it to a Focus
in iOS Settings › Focus › Focus filters and fills in a name, a note for agents
and Quiet agent alerts. iOS gives the app only its own filter's values, so a
Focus without bighelp's filter reads as `active: false`. No app can turn a
Focus on or off.

- `current`: `{active, name, note, quietAlerts, since}` (`name`, `note` and
  `since` only while active) and `hint` saying the person sets it up in Focus
  settings.
- While a filter with Quiet agent alerts is on, the notification service
  extension delivers agent alerts passively (no sound or banner); the filter is
  kept in the app group (`bighelp.focus-filter.v1`).

## Shortcuts

`shortcuts.*` (`DeviceShortcutsTool`). iOS gives apps no list of shortcuts, so
the person types the names their agents may run in Device access › Shortcuts
(up to 50, kept on the device).

- `list`: `shortcuts` of `{name}`.
- `run`: `name` (exactly one from the list, else `not_allowed`), `input`
  (optional text, ≤ 4000). bighelp opens Shortcuts with
  `shortcuts://x-callback-url/run-shortcut`, which runs it and comes back to
  bighelp with its output. Returns `{id, status (completed, cancelled or
  failed), output, truncated}` (output ≤ 8000 characters; a failed run's
  output is Shortcuts' `errorMessage`). The journal keeps only `id`, so a retry
  never runs it twice. The host waits up to 60 seconds and holds the channel's
  lease meanwhile; a run that doesn't come back in time is `outcome_unknown`.
  A second run while one is out is `device_busy`.
- While the run is out in Shortcuts (at most 60 seconds), bighelp counts as
  open for the phone tools (`DeviceToolHandoff`): leaving for Shortcuts doesn't
  close the channel or retire the call. It holds a background task and the host
  connection, and still retires the call on everything else (switch off, host
  or chat change, sign-out). The callback is
  `loopdy://device-tool/shortcuts/<success|cancel|error>/<run id>`; callbacks
  for unknown or finished runs are ignored.

## Pictures need the person's review

A contact or event read from a picture goes through a reviewed draft
([Image drafts](IMAGE_DRAFTS.md)), never straight to Contacts or Calendar. So in
a chat that holds a picture the person sent, or one where `photos.get` gave the
agent a photo, the phone answers `contacts.create` and `calendar.create` with
`failed` and code `review_required` before it journals or touches anything, and
`payload.note` tells the agent to use `bighelp_draft_contact` or
`bighelp_draft_event`. Lists, updates, deletes, every other tool, and every chat
without a picture behave as before, standing grants included.

## Mutation reconciliation

Persist the request fingerprint as started before calling EventKit. Completed
mutations retain only ID/revision/deleted metadata. A duplicate completed request
returns the known result. A started request without a confirmed outcome returns
`outcome_unknown` and is never automatically executed again. A callback failure
after a possible commit is also uncertain; inspect current native state before
proposing a fresh change. The host must never turn a timeout into a blind write
retry with a new identity.

Permission, stale-owner, expired, unsupported, busy, stale-revision, unavailable,
persistence and uncertain outcomes remain distinct. Error strings must be bounded
and sanitized. No operation should make the chat composer unusable or block the
socket receive loop while an Apple permission prompt/query is pending.

## Release metadata

The app links no HealthKit: no HealthKit entitlement, no `NSHealth…` usage descriptions and
no HealthKit calls. App Review rejects any of them in an app without a main health feature.

## Regression and acceptance requirements

Native suites:
`DeviceToolPermissionsTests`, `AppleDeviceToolServiceTests`,
`DeviceToolCoordinatorTests`, `DeviceToolFileJournalTests`, `DeviceLocationToolTests`,
`DeviceAppearanceToolTests`, `AgentAppearanceUITests`,
`BighelpLinkDirectedDeviceToolTests`, existing socket/backpressure and account
erasure suites, and `DeviceToolPermissionsUITests`.

Plugin tests exercise registration with/without supported Hermes context,
authenticated ownership, independent phone/host epochs, same-second grant
transitions, directed frames, correlation, timeouts, concurrent identities,
mutation deduplication, uncertain writes and non-caching of private reads.
Hermes tests cover runtime-only context propagation, queued owner separation,
delegation isolation and official tool-call identifiers. Relay tests verify
single-device queues and negative routing without legacy fallback.

The registered Calendar handler must also be tested from a separate worker loop
with the real encrypted Link client and a contended gateway send lock. Verify
one directed request, gateway-owned result futures, permission disable and
disconnect during a pending call, and a stopped gateway loop. Same-loop fake
clients do not establish the Hermes-to-phone delivery boundary.

Run iPhone and iPad composer interaction checks alongside this integration.
Preserve the full visible input focus target and microphone/Send alignment in
`ComposerInteractionUITests` and the chat interaction contract.

Physical-device acceptance requires real, explicitly enabled OS permissions:
list and create/update/delete disposable Calendar
and Reminders records; verify exact revision conflicts; turn each permission
off during a pending read; switch host; lock/background; reconnect. Simulator
and injected-boundary tests do not establish those real-data outcomes.

Apple references:
[EventKit calendar access](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui).
