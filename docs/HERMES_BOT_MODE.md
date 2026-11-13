# Hermes Bot Mode

> Transport: [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md). Group chats use Hermes' own `groups.*` JSON-RPC methods over
> the app's native WebSocket connection to the dashboard. The retired bighelp Link relay plays no part. Some type
> names still say `Link` (for example `BighelpLinkHermesBotModeClient`, aliased as `HermesHostedRoomClient`); they
> are legacy names only.
>
> The name: "Bot Mode" is Hermes' word for its hosted group chats, and file and type names keep it (`BotModeRoom`,
> `BotModeRoomStore`). It is not the app's old Bots mode, which is gone. Today the first tab's Bots view lists bots
> and group chats, and every group chat is also a row in the Chats view.

## Product boundary

Group chats run on Hermes. The local Bot Mode fixture runner
(`BotModeFixtureClient`) only drives fixtures and tests; it is not a production
engine.

Hermes owns room membership, routing, task execution, idempotency, fencing and
the durable event log. The iOS app presents that state through one typed
`groups.*` client (`HermesHostedRoomClient`, made in `NativeWorkspaceRuntime`).
It sends each operation as a `WorkspaceOperation` that
`DirectHermesWorkspaceClient` maps to a core Hermes JSON-RPC call on the
signed-in socket, with a fixed list of allowed fields per method. No bighelp
account, second daemon, private database adapter or synthesized member-turn
prompt is needed. The plugin is needed only for the optional room activity and
typing feed (see below), which reads Hermes' own room state through its
`tui_gateway.server.handle_request` dispatcher.

## Readiness and ownership

The client is bound to the current `WorkspaceOwner`: the selected host, its
sign-in and its connection generation. Only that host's rooms are listed;
switching hosts retires old catalog results, observers and actions before the
replacement context is exposed.
Check ownership and cancellation around every await. A stale completion must
never update a newly selected instance. Negotiate `groups.capabilities` once the
connection is signed in. Execution requires protocol 2, a running driver, an authority
identifier, the necessary methods and the `room_identity` and `monotonic_log`
features. Advertising methods alone does not prove that the driver runs. Peer
room-link enablement is not required for local hosted rooms.

Hermes answers `groups.*` on one of two paths, and the app goes by what each
advertises, never by version. A dashboard started with `hermes serve` (every
v0.22.2 host, and v0.22.4's standalone dashboard) uses the older path
(`tui_gateway/methods_groups.py`). From v0.22.4 the gateway's own listener uses
the session path (`gateway/session_group_controls.py`). The differences, recorded
from a real v0.22.4 host in `BighelpTests/Fixtures/HermesGroups`:

| | Older path | Session path |
|---|---|---|
| `features` | ten, incl. `typed_events`, `idempotent_send`, `coordinator_fencing` | `room_identity`, `monotonic_log`, `replayable_disband` |
| `seatable_profiles` | absent: any profile | the profiles a new room may seat; New group chat lists only those |
| RoomLink | `room_link.enabled`, `groups.peer.*` | `{enabled: false, reason: canonical_driver_required}`, no `groups.peer.*`: hidden |
| retry action | `{kind: retry, task_id}` | `{kind: retry, member_id, task_id, execution_generation}` |
| `groups.retry` | `room_id`, `task_id`; refuses any other key (4000) | also needs `member_id`, `execution_generation` (else `invalid_params`) |
| `groups.discard` | absent | for a turn it lost track of, while it lists `{kind: discard, ...}` |
| `groups.list` cursor | `offset + limit` | may skip rooms this connection can't see |

Send, log events, stop (`{cancelled}` then `room.stop_requested` with the
`cancel_id`), approvals and disband read the same on both. Every event carries
an extra `idempotent` key; read-only replies ignore keys the app doesn't use.

An older plugin or unavailable driver leaves saved rooms readable. Do not enable
action controls that cannot execute, and do not silently fall back to local
sequential direct chats. Existing local harness interfaces remain available for
fixtures and future separately qualified runtimes.

Native room discovery uses every bounded `groups.list` page. Room names,
member IDs, profile IDs, targets and revisions remain distinct server facts.
Unavailable profiles stay in the roster and its count. A member without a
`target` is local to its profile, as Hermes reads it (`_validate_member_target`);
rooms Hermes saved before it stored targets have none. Hidden member session
IDs are not present in the normal room contract and must not be fabricated.
Rename uses `groups.rename`, not ordinary session-title mutation. Show tool
calls is a device-local presentation preference, not a host logging setting.

Native room caches use schema 2 under the distinct
`bot-mode-rooms-native-v2` repository basename. The legacy physical file remains
untouched: a version check in new code cannot stop an already-shipped old binary
from writing the filename it knows. Modern readers and writers also reject
unsupported envelope versions. Native storage is checked before remote
creation/sends, so a misconfigured v1 repository cannot receive sessionless
native member records. An identity v1-to-v2 migration is available for explicitly
verified same-owner data; no automatic cross-owner or cross-transport pending
intent import is authorized. Hermes history is normally recovered through its
room catalog and log.

Native log authority is validated at its exact schema path; this never permits
gateway or secret-bearing keys in arbitrary workspace payloads. Event bytes are
never truncated to fit transport.

## Agents on other computers

A room can hold agents from any number of the person's computers (Hermes
RoomLink). Cross-gateway links are direct gateway-to-gateway connections; the
app only carries the setup. New chat's To row takes two to six bots from any computer
while Show every computer is on, and the first bot's computer is the room's
home. For each agent on another computer:

1. That computer: `groups.capabilities {profile}` gives `room_link.catalog`
   (installation ID, catalog digest, `endpoint`). No `room_link_url` there
   means `endpoint.available: false`; the app says so before anything is made.
2. The home: `groups.create` with that member's
   `target: {kind: "peer", peer_id, installation_id, profile, capability_digest}`.
   `peer_id` is the computer's name as an identifier, and the member's handle
   is device-qualified (`@rio-studio-mac`), as in Hermes Desktop.
3. That computer: `groups.peer.invite` for the room, home and member.
4. The home: `groups.peer.register` with the grant, the catalog unchanged and
   the endpoint URL. Hermes probes the other computer before it answers.

A grant is a credential: it stays in memory between steps 3 and 4 and is never
logged or saved. Links still to make are saved with the room
(`nativePendingPeerLinks`) and retried when it opens; `driver_status.peer_routes`
reports each link's health. Other computers are reached with their own saved
sign-ins (`RegistryRoomPeerHosts`). A peer member never takes a local
profile's name or picture, even one with the same profile ID.
`Scripts/RoomLinkProbe.py` checks the whole flow on two isolated real hosts.

A peer member shows its own computer's current name and picture: Show every computer
keeps a copy of each computer's agents
(`FleetStore.peerAgent`, found by `peer_id`), and a room with peers on screen
reads those computers again when the copy is old. While such a room is on
screen, the app holds a connection to each of those computers
(`BighelpHostRegistry.holdConnection`) and opens that computer's plugin feed
for its agents (`native-room-peer-typing-v1`), so they show "is typing" too.
A Team Call includes peer members; each speaks with its own computer's voice
(`TeamCallPeerVoices`, `voice.speak` on that computer, keyed `peer_id/profile`
so a local and a peer `default` never share a voice).

## Durable interaction contract

- Create one stable room with selected profile members. Hermes' `groups.*` has
  no operation to edit that roster after creation; the app must reflect that limit.
  Persist the create intent before dispatch. Recover a lost receipt by room ID:
  reissuing an old create name can conflict after another client renames the room.
- Persist the client event ID, exact text and thread ID before sending. An
  uncertain retry reuses that identity. Do not generate a second event merely
  because the phone lost a response.
- Preserve the server's user-event identity. Replay contiguous `groups.log`
  pages from the last persisted cursor, including all pages, never asking for
  more than the advertised `max_log_limit`. A log page ignores fields the app
  doesn't use; send, retry and approval receipts must match exactly, so an
  unknown receipt field never reads as a confirmed send. A room snapshot's
  latest sequence and a send receipt do not establish that earlier log entries
  have been consumed.
- Validate room, cursor, sequence and authority before publishing a page.
  Deduplicate by server event identity while preserving server order.
- Reopening or reconnecting replays durable history and reconciles running state.
  Screen dismissal and task cancellation do not stop Hermes work. Only the
  explicit Stop action sends `groups.stop`.
- Stop saves its `cancel_id` with the room before it asks. Hermes writes one
  `room.stop_requested` event per cancel ID (its `payload.cancel_id`; a repeat
  returns the same event), and each new one ends every earlier message in the
  room. So the saved ID stays until Hermes answers or the room log shows that
  event, and Stop again reuses it. Stop again reads the log first and doesn't
  ask when the stop is already there; a repeat would also cancel newer work.
  Any answer to `groups.stop` is success: fields the app doesn't use are
  ignored. The room shows a stop it couldn't confirm with one action, Stop
  again. A saved ID never holds Send: the next message reads the log first,
  and a stop that isn't there never reached Hermes. Only a stop still on its
  way holds Send. Reconnecting reads the log for every room with a saved ID.
- Show exact hosted-room approval requests from `driver_status.pending_actions`.
  Resolve only that task, execution generation and request through
  `groups.approve`, using Allow Once or Deny. Ordinary device approvals are a
  separate contract. Do not silently approve or offer unsupported persistent grants.
  Command text is optional in Hermes: show it verbatim when present and keep a
  valid request actionable when Hermes supplies only the request identity.
- Retry eligible deferred/indeterminate tasks with their server task IDs through `groups.retry`.
  `driver_status.pending_actions` may advertise a retry before any failure event
  is available. Present that task action without inventing a member or failure.
  Send back the attempt the host's action names (`member_id`,
  `execution_generation`) only when it names one: each path refuses the other's
  shape. Keep each retry receipt and match terminal events by task ID, thread ID
  and turn ID, and by execution generation when the event names one: Hermes puts
  it on `turn.deferred` only, so the retried attempt's `turn.settled` has none
  (on both paths). All retried tasks must settle before the
  turn completes; unrelated room activity or the latest human message is not
  sufficient. A polling timeout is not an authoritative task failure. Preserve
  uncertain work until the host resolves it.
  Retain the batch, received task receipts and uncertain dispatches across
  relaunch. Hermes has no retry-idempotency token or public task-receipt lookup;
  a missing receipt is not permission to replay the batch.
- A host that stops mid-turn leaves that turn uncertain. The older path lists it
  as a retry and runs it again. The session path blocks the room and lists a
  `discard` action for about a minute; Discard (`groups.discard` with the exact
  listed attempt, after the person confirms) cancels it and the room goes on.
  Past that window Hermes defers the turn and lists a retry it then refuses
  (`unknown_execution`), and that agent can't answer in the room again, so the
  Discard card shows as soon as Hermes lists it.
- Show agent messages and supported activity from typed events. Do not invent
  tool calls or claim token streaming when the hosted-room log only provides
  completed member messages.

## Group settings, routing and Continue

Hermes 0.23 keeps settings for the rooms it runs itself (`gateway/hosted_room_context.py`),
in one `room.context_set` event: `purpose` (one line, at most 500 characters; Hermes
collapses whitespace), `notes` (at most 4,096 bytes, trimmed), `routing` (`everyone`, the
default; `lead`; or `auto`) and `lead_member_id` (only with `lead`, a seated member). The app
goes by what each room returns, never by version:

- `groups.state` returns them as `context`. A room without it has none of these settings,
  and Group Settings shows only its name and members. A context without `routing`, or with a
  routing the app doesn't know, hides that choice, and a save leaves `routing` out so Hermes
  keeps it. `driver_status.routing_modes` says what the room's runtime runs: "Pick who
  answers" shows only where it lists `auto` (or the room already uses it).
  `driver_status.max_continues` is how many times one discussion may continue.
- `groups.context` `{room_id, event_id, purpose, notes, routing?, lead_member_id?}` answers
  `{context, event}`. An omitted routing field keeps Hermes' value. The edit is saved with the
  room first (`nativePendingContext`) and keeps its `event_id` until Hermes answers, so a
  retry after a lost answer gets the first save back. A refusal keeps the edit and says why
  (another computer runs the room: "This Group Chat is managed by another gateway."). New
  Group Chat saves its choice the same way once the room exists.
- A lead's pick is `room.assignment` `{lead_member_id, member_ids, fallback}` (`fallback`: the
  lead's answer named nobody, so the lead takes it); the automatic pick is `room.routed`
  `{member_ids, everyone, fallback}` (`fallback`: the pick failed, so everyone answers).
  @mentions, @all/@everyone, scheduled posts and replies in a thread skip both. Hermes
  writes them as the room's gateway; the app keeps them, a pause (`room.activity` with
  `bounded`), `room.continued` and `room.stop_requested` beside the messages
  (`nativeNotices`, a key older builds don't read) and shows each as one centered line. A
  line names only members still in the room, and one naming nobody is left out. Which bots an
  @mention reached isn't in the log, so the app doesn't say it.
- A discussion pauses after 10 member messages or 3 rounds. `groups.continue`
  `{room_id, discussion_event_id}` answers `{continued, event}` with a `room.continued` and
  grants one more budget, at most `max_continues` times. The pause's card offers Continue and
  Stop (`groups.stop`) until a later Continue or pause for that discussion, a Stop after its
  message, a newer message in its thread, or the last Continue moves it on (Hermes'
  `paused_discussion`).

Vectors: `BighelpTests/Fixtures/HermesGroups/room-settings.json`, from the Hermes 0.23.0
source, not a recording. Tests: `HermesGroupRoomSettingsTests`. Demo: `-preview-group-settings`
(`GroupSettingsDemoClient`; `-preview-group-settings-refused` refuses every save).

## Mentions, authors and optional live activity

The hosted driver, not the local fixture parser, chooses recipients. It matches
the frozen room handles with its native ASCII mention expression. `@all` and
`@everyone` select all; no recognized handle defaults to all. Do not promise
email/code exclusions, display-name aliases or special `@user` routing that the
native resolver does not implement. A selected member may choose to pass.

Persist server actor provenance. Only an exact locally persisted send intent
and canonical receipt can associate a message with its local display snapshot.
Other generic human events must not be attributed to whichever person is using
this phone now. Display identity never grants access to a person's data.
Hermes Desktop groups can add and remove members while the room keeps its
history, so a member message's author may no longer be in the roster. Keep it
in the cache (the cursor is past it) and show it under the actor's
`display_name`, or "Former member"; never attribute it to a current agent.

The existing plugin supplies device-bound person context on normal bighelp
platform turns through its public pre-LLM hook. Native hosted groups do not
currently expose the same authenticated sender-to-first-member-turn association
to that hook. Its session/task identifiers are not hosted discussion-task
coordinates. This precise integration requires public-contract proof; do not
infer it from message text, titles, timing or private runtime state. Ordinary
rooms remain usable with truthful generic provenance. No Hermes core changes
or fabricated person context are part of this implementation.

The optional `on_room_member_activity` hook is a current-runtime, lossy plugin
observation surface, not durable history or a stock Direct subscription.
Real tool details require separately negotiated authenticated delivery with
exact room/member/task/generation coordinates and explicit loss/reset behavior.
An enabled display preference alone does not establish that support.

The optional `native-room-activity-v1` integration opens a disposable feed only
while a room view is visible, through fixed authenticated plugin open/poll/close
operations. Its observation cursor is separate from the source session sequence
and the durable room-log cursor. Upstream drops cannot be counted; every feed
discloses that source loss is unobservable. Measurable plugin drops or reset
responses clear transient rows and reconcile room history. They do not fabricate
missing tool activity.

With `native-room-typing-v1` the app opens the feed with
`include: ["member.responding"]`. Each report says a member is writing (no
text), at most every 2 seconds per member turn. The chat shows one
"{name} is typing…" row per such member, stacked, and drops it when that
member's message or terminal turn event reaches the room log, or after 6
seconds without a report. These rows are never stored. Without reports (an
older plugin, or a member in a long tool call) one unnamed typing bubble shows
while the room works; there is no "Agents are collaborating" line.

Observed tool rows use native tool/member/task/generation coordinates and remain
separately recyclable in the existing canvas. Started is an observation, not a
claim that the tool is still running; Finished does not assert success. Optional
arguments and results retain explicit unavailable, size-omitted or
sensitive-omitted states. They reuse the bounded tool preview and full reader.
Disclosure choices belong to the room activity store, not recycled rows.
Activity observations are never written into authoritative transcript or
approval state. View exit, owner changes and runtime replacement retire them;
an unconfirmed close relies on the host's bounded inactivity lease.

## Verification and release

Run `HermesBotModeContractTests`, `HermesGroupsHostPathTests` (both paths' recorded replies), `HermesGroupRoomSettingsTests`, `BighelpLinkHermesBotModeClientTests`,
`BighelpLinkHermesBotModeApprovalTests`, `NativeHermesGroupFlowTests`, `BotModeRoomStoreTests` and
`ChatBotModeIntegrationTests` along with the chat interaction regression gate.
The `BighelpLinkHermesBotModeClient` tests (a legacy name) cover request shapes, cancelled/stale results, idempotency,
cursor validation and driver status. Store checks cover persistence, replay,
capability gating and room execution. Preserve the separate local fixture tests.

Run the plugin's room activity tests (`tests/test_room_activity.py`) with the
official Hermes source on `PYTHONPATH`. Publish the matching plugin separately from the iOS
archive, then activate it using Hermes' supported installer/updater. An app
upload does not activate a plugin on a user's host. Record source, simulator,
live host and TestFlight evidence separately; none substitutes for the others.
`Scripts/RoomLinkProbe.py` checks a room across two isolated real hosts.

Room discovery on the Hermes host must exclude invalid profile directories and
deleted-profile tombstones. In the September 10 host version, enumerating every
directory included `profiles/.deleted` and made `groups.create` reject all local
rooms. The host fix uses Hermes' profile validator and tombstone helper; retain
the hosted-room integration regression when updating Hermes. This is a host
prerequisite, not something the iOS client should bypass or repair through a
private filesystem API.
