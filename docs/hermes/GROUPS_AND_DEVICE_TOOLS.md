# Hosted groups, device tools, and interactive extensions

This document describes the contracts exercised by the current native client. The
JSON names, identity boundaries, replay rules, and negotiated features are useful
for an Android or other non-Apple client. Swift type names below are source
references, not protocol requirements. Examples use invented identifiers.

Core `groups.*`, `display.*`, and connector methods run on the authenticated
Hermes JSON-RPC WebSocket. Device tools and optional group observations use the
bighelp plugin's authenticated HTTP routes under `/api/plugins/loopdy/native/`.
These are separate capability surfaces. The current groups client is named
`BighelpLinkHermesBotModeClient` for historical reasons; its
`WorkspaceOperationPerforming` initializer uses direct Hermes operations.
Neither its name nor old Link transport sections in other documents imply that
an Android client needs pairing, a relay, or a bighelp account.

Sources: [groups client](../../Bighelp/BotMode/HermesBotModeClient.swift),
[core route allowlist](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift),
[plugin routes](../../Bighelp/DirectHermes/DirectHermesNativeContext.swift), and
[current device channel](../../Bighelp/Permissions/NativeDeviceToolSession.swift).

## 1. Hosted room ownership and readiness

Hermes owns the room, roster, routing, task execution, fencing, idempotency, and
durable event log. A client presents that state. It must not synthesize member
turns by creating sequential ordinary chats, invent hidden member session IDs,
or stop host work because a view disappeared.

Bind all state and requests to the selected host authority, authentication
generation, and connection generation. Check those coordinates and cancellation
before dispatch and after every asynchronous boundary. Results from a retired
connection cannot mutate a replacement host's cache or controls. Cache ownership
must survive process restarts; a room ID alone does not prove ownership.

Send `groups.capabilities` with `{}` after connecting or replacing the connection.
The current execution gate requires all of:

- `protocol_version == 2`, `driver == true`, and a valid `authority_gateway_id`.
- Methods `groups.capabilities`, `groups.create`, `groups.state`, `groups.send`,
  `groups.log`, `groups.stop`, `groups.retry`, and `groups.approve`.
- Features `room_identity` and `monotonic_log`.

`persistent_process` is reported but is not an additional gate in the current
client. RoomLink is optional; it is not needed for local rooms. An unavailable
driver or an older host can leave saved history readable while disabling actions.
Gate rename, disband, discard, and RoomLink independently on their methods.

Capability result fields:

| Field | Type and meaning |
| --- | --- |
| `protocol_version` | Integer; execution requires 2. |
| `driver` | Boolean; methods alone do not prove the driver is running. |
| `persistent_process` | Boolean. |
| `authority_gateway_id` | Identifier for this room authority. |
| `room_link` | Object; described in section 7. |
| `features`, `methods` | Arrays of strings, each at most 128 entries. |
| `max_log_limit` | Integer 1–500; use it when paging logs. |
| `seatable_profiles` | Optional string array, at most 512. When present, only these local profiles can be selected for a new room; absence means no client-side restriction. |

Read-only capability decoding ignores additional fields. Current validation
requires method/feature strings to be nonempty labels of at most 128 Unicode
scalars, seatable profiles to satisfy the same bound, and a valid authority ID.

### Two host implementations

Choose behavior from capabilities and each pending action, not a version string.
Recorded real-host vectors for Hermes v0.22.4 are checked into
[legacy-path.json](../../BighelpTests/Fixtures/HermesGroups/legacy-path.json) and
[session-path.json](../../BighelpTests/Fixtures/HermesGroups/session-path.json).
Their host used scripted model replies; they establish host transport behavior,
not production model behavior.

| Contract | Standalone dashboard / older path | Gateway listener / session path |
| --- | --- | --- |
| Hermes implementation | `tui_gateway/methods_groups.py` | `gateway/session_group_controls.py` |
| Features | Includes `typed_events`, `idempotent_send`, `coordinator_fencing`, and others | Advertises `room_identity`, `monotonic_log`, `replayable_disband` |
| `seatable_profiles` | Absent | Present |
| RoomLink | Can advertise enabled catalog and `groups.peer.*` | Recorded result is `{enabled:false, reason:"canonical_driver_required"}`; peer methods absent |
| Retry action | `{kind:"retry", task_id}` | Also identifies `member_id` and `execution_generation` |
| Retry request | Only `room_id`, `task_id`; extra attempt keys rejected with 4000 | Exact listed attempt required; missing keys rejected as `invalid_params` |
| Discard | Absent | `groups.discard` and a temporary discard pending action |
| List cursor | Commonly `offset + limit` | Can skip rooms this connection cannot see |

Both recorded paths use the same send receipts, room events, stop result
(`{cancelled: n}`), and disband tombstone. Events include an additional
`idempotent` field, which the current decoder ignores. Do not demand that the
session path advertise every older feature name before accepting its already
validated events or receipts.

## 2. Common JSON schemas and bounds

In the schemas below, `?` means an optional field, `object` is a JSON object,
and `number` means a finite JSON number. This is notation, not literal JSON.
Required fields must be present with the stated type; unknown-key behavior is
specified per response. All identifiers are case-sensitive protocol identities;
never substitute display names for them.

The groups validator's identifier grammar is
`^[A-Za-z0-9][A-Za-z0-9._:-]*$`, at most 128 UTF-8 bytes. A label is nonblank,
contains no control characters, and is at most 200 Unicode scalars unless a
smaller limit is stated. Timestamps are Unix seconds, including fractional
seconds, finite and between 0 and 253402300799.

```text
RoomMember = {
  member_id: identifier,
  profile: identifier,
  handle: identifier,                 // store without the displayed @
  display_name?: label,
  target: LocalTarget | PeerTarget
}
LocalTarget = {kind:"local", profile:identifier}
PeerTarget = {
  kind:"peer", peer_id:identifier, installation_id:identifier,
  profile:identifier, capability_digest:nonblank_string
}
Room = {
  room_id:identifier, name:label, members:[RoomMember],
  authority_gateway_id:identifier, authority_epoch:positive_integer,
  revision:positive_integer, created_at:number, updated_at:number,
  latest_seq?:nonnegative_integer, disbanded_at?:number,
  driver_status?:object
}
```

Targets have exactly the listed keys, and their profile equals the member's
`profile`. Peer capability digests are at most 256 Unicode scalars in member
validation; RoomLink catalog parsing additionally checks its SHA-256 digest.
A missing or null member target is interpreted as
`{kind:"local", profile:<member.profile>}` when reading older saved rooms.
Do not drop an entire catalog because one older room omitted targets.

Creation accepts 2–6 members in this client. Readback accepts 1–128 members, with
unique member IDs, because host-side state can outlive client UI limits.
`updated_at >= created_at`; optional `latest_seq >= 0`. Unknown room/member
fields are ignored, but read fields and targets remain validated. An unavailable
local profile remains a roster member and counts toward the roster. A peer with
the same profile ID as a local agent remains a different identity.

`driver_status` normally sits beside `room` in `groups.state`, not inside it:

```json
{
  "room": {"room_id":"room-demo","name":"Planning","members":[{"member_id":"writer","profile":"writer","handle":"writer","target":{"kind":"local","profile":"writer"}}],"authority_gateway_id":"install:demo","authority_epoch":1,"revision":1,"created_at":1700000000,"updated_at":1700000000},
  "driver_status": {
    "running":true,"working":false,"blocked":false,
    "counts":{},"peer_routes":[],"pending_actions":[]
  }
}
```

The one-member readback above illustrates envelope placement; new-room creation
still requires 2–6 members. `driver_status` is extensible. `working` reports current
work, `pending_actions` supplies actionable attempts, and `peer_routes` reports
RoomLink health. Do not persist this transient status as authoritative room
metadata or treat `running:true` as proof that a particular turn is working.

Sources: [models](../../Bighelp/BotMode/BotModeModels.swift),
[validation and text canonicalization](../../Bighelp/BotMode/HermesBotModeWireCodec.swift).

## 3. Core groups methods

These tables give the exact payloads the typed client sends, not every optional
field some Hermes release might support. The generic workspace route allowlist
may allow more fields; copying that allowlist is not a reason to send them.

| Method | Params sent | Result and acceptance |
| --- | --- | --- |
| `groups.capabilities` | `{}`; or `{profile}` for a remote agent's RoomLink offer | Capability object in section 1; additional keys accepted. |
| `groups.list` | `{offset, limit, include_disbanded:false}` | Exactly `{rooms:[Room], next_offset:integer_or_null}`. `offset >= 0`, `limit` 1–500. |
| `groups.create` | `{room_id, name, members:[RoomMember]}` | Outer `{room:Room}` only. Room ID, name, and members must equal the request. |
| `groups.state` | `{room_id, include_disbanded:boolean}` | Outer `{room:Room, driver_status?:object}` only. Room ID must match. Merge the outer status into the in-memory snapshot. |
| `groups.rename` | `{room_id, event_id, name}` | Outer `{room:Room}` only; the raw room also contains an `event` whose ID equals `event_id`, kind is `room.renamed`, room matches, and `payload.name` equals the requested name. |
| `groups.send` | `{room_id, event_id, payload:{text, thread_id}}` | Exact receipt schema below. |
| `groups.log` | `{room_id, since_seq, limit, include_disbanded:boolean}` | Log page in section 4; extra read-only fields accepted. `since_seq >= 0`, `limit` 1–500 and no larger than negotiated maximum. |
| `groups.stop` | `{room_id, cancel_id}` | Any successful RPC answer confirms stop; the client does not interpret its fields. The recorded host answers `{cancelled:integer}`. |
| `groups.disband` | `{room_id}` | An object with `tombstone.room_id` matching and finite `tombstone.disbanded_at > 0`. If `history_expired:true`, the tombstone is sufficient; otherwise reread state with `include_disbanded:true` and require `disbanded_at`. |
| `groups.retry` | `{room_id, task_id}` plus listed attempt fields only when supplied by the pending action | Exactly `{retried:true, task:TaskReceipt}`. See section 5. |
| `groups.discard` | `{room_id, member_id, task_id, execution_generation}` | Exactly `{discarded:true, task:TaskReceipt}`; same room/task/generation, `status:"cancelled"`. |
| `groups.approve` | `{room_id, member_id, task_id, execution_generation, request_id, choice}` | Exactly `{approved:true, result:object}`. `result` is opaque to the client; do not infer an extra required `resolved` shape from a test fixture. |

List pagination must exhaust `next_offset`. Require no duplicate room IDs in one
page, `rooms.length <= limit`, and a non-null cursor only when the page is full.
For a non-null cursor, require `next_offset > offset` and
`next_offset >= offset + rooms.length`. Do not force equality: the session path
can skip invisible rooms. Validate every room before publishing the page.

There is no roster edit operation in this client's `groups.*` surface. Reflect
that limit in a new client. Readback can still contain former members' messages
or server-authored membership events from other clients.

The recorded capability lists also advertise methods outside this client's
implemented surface: older-path replication/takeover operations and session-path
`groups.attachment.upload` / `groups.attachment.download`, for example. This
document does not define their payloads. Advertising one is not proof that the
client supports it; do not infer group attachment schemas from ordinary chat
attachment routes.

### Send receipt and text identity

```text
SendReceipt = {
  event:Event, client_event_id:identifier,
  accepted:true, driver_started:true
}
TaskReceipt = {
  room_id:string, task_id:string, thread_id:string, turn_id:string,
  status:string, execution_generation:positive_integer,
  cancel_generation:nonnegative_integer
}
```

The send receipt has exactly four top-level keys. Require the requested room,
the original client `event_id` in `client_event_id`, `event.kind == "message.user"`,
`event.actor.kind == "user"`, and the requested thread. The event's server ID
can differ from the client idempotency key; keep both. Text is at most 64 KiB
UTF-8 and must contain nonwhitespace text. Hermes stores Python `str.strip()`
canonical text. The client compares the receipt to that canonicalization,
including Unicode whitespace and U+001C–U+001F, while retaining the exact original
request for retry. Do not silently replace the persisted retry body with its
normalized receipt text.

The current default main thread is `loopdy-<room_id>` when it satisfies the
identifier grammar, otherwise `loopdy-` plus lowercase SHA-256 hex of the room
ID. This is a client convention, not a host-generated thread identity.

An unknown send/retry/discard/approval top-level receipt key makes that receipt
unconfirmed in the current client. Do not advance a log cursor from a receipt,
even when it contains an event at a later sequence.

## 4. Durable events and log replay

```text
Event = {
  room_id:identifier, seq:positive_integer, event_id:identifier,
  kind:string, actor:Actor, authority_epoch?:positive_integer,
  payload:object, created_at:number
}
Actor = {
  kind:"user"|"member"|"gateway"|"system", id:identifier,
  display_name?:label, profile?:identifier, connection_id?:identifier
}
LogPage = {
  events:[Event], cursor:nonnegative_integer, latest_seq:nonnegative_integer,
  has_more:boolean, authority:{gateway_id:string, epoch:positive_integer}
}
```

Actor objects accept only the five listed keys. Event kinds match
`^[a-z][a-z0-9_.-]*$`, at most 64 UTF-8 bytes. Event and payload objects may
contain fields a reader does not use, such as host `idempotent`. Preserve known
server provenance and allow unknown event kinds without fabricating a visual
message. Event text, when required, is at most 64 KiB and contains no control
characters except newline, carriage return, and tab.

| Kind | Actor | Payload fields used by this client |
| --- | --- | --- |
| `message.user` | `user` | `text`, `thread_id`; its `event_id` anchors the discussion. |
| `message.member` | `member` | `member_id` equals `actor.id`; `text`, `discussion_event_id`, `thread_id`, `turn_id`, `task_id`; may include `member_index`, `round_index`. |
| `turn.settled` | `gateway` | Attempt coordinates above; often `seen_through_seq`, `message_event_id`, `passed`. A pass can settle without a member message. |
| `turn.failed`, `turn.cancelled`, `turn.deferred` | `gateway` | Attempt coordinates, optional reason and generation. Deferred events can name `execution_generation`; a later settled event often omits it. |
| `room.activity` | `gateway` | `discussion_event_id`, `thread_id`, `status`, `reason_code`; recorded settlement reason is `silent_round`. |
| `room.stop_requested` | `gateway` | `cancel_id`. |
| `room.renamed` | `system` | `name`; rename confirmation also requires its event ID. |
| `room.disbanded` | `system` | Recorded payload includes `room_id`; disband also has a tombstone. |
| `room.created`, `room.members_changed`, `authority.claimed`, `authority.lost` | `system` | Preserve the event; do not invent unspecified payload fields. |
| `member.unavailable`, `turn.started`, `turn.reassigned` | `gateway` | Preserve supported coordinates; do not infer a text stream. |

The table lists fields actually read and observed; it does not assert that every
optional lifecycle coordinate is always emitted. Only user/member message kinds
map to durable transcript text. The room log provides completed member messages,
not token deltas. Optional live tool observations are a different feed.

For `groups.log(room, since_seq=S, limit=L)`:

1. Validate the complete page before making any row visible or changing storage.
2. Require at most `L` events, each from the requested room. Starting at `S+1`,
   every event must have the next contiguous sequence, with overflow checks.
3. Require `cursor` to equal the last returned sequence, or `S` if empty;
   `latest_seq >= cursor`; `has_more == (cursor < latest_seq)`; a page claiming
   more data cannot be empty.
4. Require nonempty `authority.gateway_id`, positive epoch, and any event epoch
   to be positive and no greater than the page epoch. The room store additionally
   requires the page gateway and epoch to equal the reconciled room authority.
   A later state may advance the same gateway's epoch; it must not silently
   replace it with a different gateway or roll its epoch back.
5. Persist accepted events and the consumed cursor atomically. Deduplicate by
   server `event_id`, keep server order, then request the next page while
   `has_more`. A snapshot's `latest_seq` is a target, not consumed history.

Keep an event from a member no longer in the current roster; the cursor has
already crossed it. Display the actor's `display_name`, or a neutral former
member label, rather than attributing it to a current member. A generic user
actor such as `desktop` is not proof that the current device's person sent the
message. Only a matching persisted local intent and canonical receipt allow
association with a local sender snapshot.

The host chooses recipients using frozen handles and its native ASCII mention
expression. `@all` and `@everyone` select everyone; no recognized handle defaults
to everyone. Do not add local routing assumptions about email/code exclusions,
display-name aliases, or special `@user` handling.

Sources: [event application](../../Bighelp/BotMode/BotModeRoomStore+NativeEvents.swift),
[recovery and authority validation](../../Bighelp/BotMode/BotModeRoomStore+NativeRecovery.swift).

## 5. Pending actions: retry, discard, and approval

Always obtain actions from the current `groups.state.driver_status.pending_actions`
and revalidate before dispatch. Old cards are not authority to act on a new
attempt. Unknown action kinds are left to their own feature.

```text
OlderRetryAction = {kind:"retry", task_id:identifier}
AttemptRetryAction = {
  kind:"retry", task_id:identifier, member_id:identifier,
  execution_generation:positive_integer
}
DiscardAction = {
  kind:"discard", task_id:identifier, member_id:identifier,
  execution_generation:positive_integer
}
ApprovalAction = {
  kind:"approval", member_id:string, task_id:string,
  execution_generation:positive_integer, request_id:string,
  approval:{
    request_id:string, choices:["once"|"deny"],
    command?:string_or_null, description?:string
  }
}
```

Retry sends exactly the shape advertised by that task. Adding member/generation
keys to an older host is as wrong as omitting them for the session path. A
pending retry may exist before its failure event reaches the local cache. Show
that task action without inventing a member failure.

A retry result must identify the requested room/task, nonempty thread/turn,
positive execution generation, nonnegative cancel generation, and status one of
`queued`, `settled`, `failed`, `cancelled`. Persist the batch, each received task
receipt, each dispatch awaiting a receipt, and task terminal state. Match terminal
events by task, thread, and turn, plus execution generation when the event has
one. Both recorded paths omit generation from the retried `turn.settled`; do not
reject that event just because a preceding `turn.deferred` named a generation.
A batch finishes only when every retried task settles. New human messages,
unrelated room activity, and a local polling timeout are not terminal proof.
The typed transport accepts those four status values; the current room runner
additionally requires `queued` before starting its retry observation loop.

Hermes exposes no retry idempotency token or public task-receipt lookup. If a
retry response is lost, keep the dispatch uncertain; do not replay a whole batch
and assume no work occurred.

After a host stops mid-turn, the older path offers retry and can rerun it. The
recorded session path temporarily blocks the room with a discard action, for
about a minute. Offer discard as soon as the host offers it, after explicit
user confirmation of abandoning that uncertain turn, using the exact attempt.
After that window, the recorded host can defer the turn yet refuse its listed
retry with `unknown_execution`. This is a host limitation, not a reason to
fabricate success or retry a different attempt.

Approval choices for hosted groups are only `once` and `deny`. The nested
request ID must equal the outer `request_id`; choices must be a nonempty array
containing only those strings. `command` may be absent or null; when present
it is nonblank and displayed verbatim. A missing command must not make a valid
identity-only approval disappear. Optional `description`, when present, must be
a string. A malformed recognized approval fails validation; unknown kinds are
ignored. Hosted approval actions are separate from ordinary chat server requests
and from device access switches. Do not offer persistent grants here.

Sources: [approval model](../../Bighelp/BotMode/HermesBotModeApproval.swift),
[discard model](../../Bighelp/BotMode/HermesBotModeDiscard.swift),
[pending action reconciliation](../../Bighelp/BotMode/BotModeRoomStore+NativeRecovery.swift),
[retry persistence](../../Bighelp/BotMode/HermesBotModeCatalog.swift).

## 6. Persistent intents and reconnect behavior

Persist the create intent before `groups.create`: room ID, exact name, member
roster, and dispatch state. After an uncertain create, recover by room ID through
state/catalog. Reissuing its old name can conflict after another client renames
the room. Persist rename `event_id` and exact name until receipt or matching log
event confirms it.

Before send, persist client event ID, exact text, thread ID, and optional local
sender display snapshot. On a lost response, resend the same intent and key;
record the returned server event identity. Follow-up messages sent while the
room works have their own discussion identities. Never attach their failures
to whichever message happens to be newest on screen.

Before Stop, persist a stable `cancel_id`. Hermes logs one
`room.stop_requested` per cancel ID. Retain that ID until a successful stop
answer or matching log event confirms it. Reconnect and an explicit Stop again
read the log first. If confirmed, clear the intent without sending the stop
again: another stop could cancel newer work. If unconfirmed, reuse the same
cancel ID. A saved uncertain ID by itself does not block Send; an active stop
request does. Read the log before the next message to resolve prior uncertainty.
Only an explicit stop action sends `groups.stop`; navigation cancellation does
not.

Reopen by fetching authoritative room state, checking authority, draining all
log pages from the persisted cursor, reconciling receipts and pending actions,
and then resuming observation. A receipt or newest state sequence cannot skip
older log entries. Preserve uncertain work across relaunch instead of turning a
network timeout into a task failure.

The Apple implementation uses a separately versioned native room cache
(`bot-mode-rooms-native-v2`, schema 2), validates storage before remote mutation,
and does not automatically import pending intents from another host or a legacy
transport. The portable requirement is isolated, versioned, owner-scoped durable
storage with atomic cursor/event/intent updates; an Android app can choose its
own database and filenames.

Sources: [submission and stop](../../Bighelp/BotMode/BotModeRoomStore+NativeSubmission.swift),
[recovery](../../Bighelp/BotMode/BotModeRoomStore+NativeRecovery.swift),
[persistence tests](../../BighelpTests/HermesBotModePersistenceTests.swift).

## 7. RoomLink: agents on other hosts

RoomLink connects gateways directly. The app carries setup messages; it is not
a relay for member turns. Choose one host as the room's home, keep every peer's
sign-in distinct, and do this for each remote agent:

1. On the peer, send `groups.capabilities {profile}`. Require protocol 2,
   `groups.peer.invite`, `room_link.enabled:true`, and a usable catalog endpoint.
2. On the home, create the room with a peer target using the peer's installation
   ID and catalog digest. Keep local and peer profile identities distinct.
3. On the peer, request the grant using the home's room authority coordinates.
4. On the home, register that grant and the unchanged peer catalog. Hermes
   probes the peer before success.

```text
PeerInviteParams = {
  profile, room_id, home_install_id, authority_gateway_id,
  authority_epoch:positive_integer, member_id
}
PeerInviteResult = {grant:string, target_profile:string, catalog:object, endpoint:any}
PeerRegisterParams = {
  room_id, member_id, target_url:string, catalog:object,
  target_profile:string, grant:string
}
PeerRegisterResult = {
  registered:true, target_install_id:string, target_profile:string, ...
}
```

The typed invite requires exactly the four listed top-level result keys, checks
`target_profile` against the requested profile, then parses the catalog.
`endpoint` is required by that exact envelope but the URL comes from
`catalog.endpoint`, not from this outer field. The workspace route also permits
`ttl_seconds` on invite, but the current typed client does not send it. Register
checks `registered:true` and the returned installation/profile; additional
register result keys are ignored.

Required catalog facts:

- `installation_id`: valid groups identifier.
- `catalog_digest`: exactly 64 lowercase hexadecimal characters.
- `execution_policy.target_profile`, if present, equals the requested profile.
- Catalog JSON is at most 32768 bytes and is returned unchanged to register.
- `endpoint.available:true` and `endpoint.url` valid; absence/unavailability
  reports `not_configured` or the endpoint's safe reason.

A RoomLink address is at most 2048 UTF-8 bytes, has no user/password, query, or
fragment, and uses HTTPS. HTTP is allowed only for loopback (`localhost`, a
`.localhost` name, `127.*`, or `::1`). `room_link.enabled:false` means unavailable;
a catalog with no reachable configured address cannot participate yet.

The grant is a credential: nonempty, no control characters, at most 8192 UTF-8
bytes. Hold it in memory only between invite and register; never persist or log
it. Persist unfinished peer-link setup metadata without grants so opening the
room can obtain a fresh grant. Keep peer names/pictures scoped by host and
profile. The current client creates unique device-qualified member IDs and
handles; `peer_id` is the chosen host slug used for peer lookup, not the
local profile ID.

Current app enrichment can read peer agents and hold their host connections
while a room is visible. Optional peer typing requires that peer's plugin
feature `native-room-peer-typing-v1`; it is not durable room history.

Sources: [RoomLink parsing and identities](../../Bighelp/BotMode/HermesBotModeRoomLink.swift),
[peer tests](../../BighelpTests/HermesBotModePeerTests.swift),
[two-host probe](../../Scripts/RoomLinkProbe.py).

## 8. Optional group activity and typing feed

This plugin feature is separate from `groups.log` and core `groups.*` methods.
Negotiate `native-room-activity-v1` through native context. The fixed HTTP routes
are POST `/api/plugins/loopdy/native/groups/activity/open`, `/poll`, and `/close`,
with native context `If-Match` and correlated request IDs. Maximum response size
is 196608 bytes. Schema names here are deliberately camelCase, unlike core groups.

| Action | Request body |
| --- | --- |
| open | `{roomId}`; add `include:["member.responding"]` only with `native-room-typing-v1`. |
| peer open | Also add `peer:{homeInstallId, members:[{memberId,profile}]}`; requires `native-room-peer-typing-v1` on the peer and requests responding observations. |
| poll | `{roomId, streamId, after, limit}`; `after >= 0`, `limit` 1–8. |
| close | `{roomId, streamId}`. |

```text
ActivityPage = {
  schemaVersion:1, runtimeId:string, roomId:string, streamId:string,
  sourceState:"registered_unobserved"|"observed"|"unsupported_payload",
  upstreamLoss:"unobservable", openedAt:integer, expiresAt:integer,
  cursor:integer, highWater:integer, hasMore:boolean,
  resetRequired:boolean, resetReason:null|"buffer_loss"|"projection_loss",
  droppedTotal:integer, projectionDrops:integer, events:[Observation]
}
ObservationCoordinates = {
  observationSequence:integer, observedAt:integer, roomId, memberId,
  threadId, turnId, taskId, executionGeneration:positive_integer,
  sourceSequence:integer_or_null, kind:string
}
ToolObservation = ObservationCoordinates + {
  kind:"tool.started"|"tool.completed",
  tool:{id:string, name:string, durationMs:integer_or_null},
  arguments:{state:DetailState, text:string_or_null},
  result:{state:DetailState, text:string_or_null}
}
RespondingObservation = ObservationCoordinates + {kind:"member.responding"}
DetailState = "available"|"unavailable"|"omitted_size"|"omitted_sensitive"
CloseResult = {schemaVersion:1, roomId, streamId, closed:true}
```

These objects use exact key sets. Each observation is at most 20480 encoded
bytes. Available detail text is at most 8192 UTF-8 bytes and forbids controls
except newline/carriage return/tab; any other detail state requires null text.
Tool IDs are nonempty safe text at most 512 UTF-8 bytes, names at most 128.
Both tool and responding observations share one contiguous
`observationSequence`. The poll cursor equals the last consumed observation,
`highWater >= cursor`, and `hasMore == (cursor < highWater)`; a page claiming
more cannot be empty. Coordinates must match the room and current feed, with
positive generation. Counters/cursors are bounded to JSON-safe integers
(9007199254740991). Opening starts with no events and zero cursor/high-water.

`sourceSequence` is not the observation cursor; gaps do not prove loss. Upstream
loss is explicitly unobservable. On `resetRequired:true`, require a non-null
reset reason, empty events, and `cursor == highWater`; clear transient rows and
reconcile the authoritative room log. Measured drops do not justify fabricating
missing tool activity. Runtime changes, host changes, view exit, and close
retire this feed; a lost close relies on the host's bounded inactivity lease.

Typing means only that a member is responding, never that text was delivered.
The current UI expires it after six seconds without a report or removes it when
a matching member message/terminal event arrives. Tool started is an
observation, and tool completed does not itself prove success. Never persist
these rows as transcript text, approval state, or task completion proof.

Sources: [feed client and decoder](../../Bighelp/BotMode/HermesBotModeActivityClient.swift),
[activity tests](../../BighelpTests/HermesBotModeActivityTests.swift).

## 9. Native device-tool HTTP bridge

The current native path is a foreground client channel on the selected host's
bighelp plugin. It is independent of the ordinary JSON-RPC server-request
response mechanism. No model-provided device identifier should select a phone.
The channel binds device, host, authorization epoch, agent, and runtime session
before any request executes.

Load native context first and require `native-device-tools-v1`. Do not offer a
capability whose feature is absent. Before `native-device-tools-agents-v1`, only
`servingProfileId` from context can open a channel; a different agent's chat
must stop after the context check. With that feature, agents share the host's
device-tool hub, while each channel still binds its own agent and session.

All four actions POST JSON to
`/api/plugins/loopdy/native/device-tools/<action>`. They use normal native HTTP
authentication and a context guard: `If-Match` for the context ETag and a lowercase
UUID `X-Loopdy-Request-ID`. Require the response request ID to match. A 200
response must carry the same normalized ETag. Other statuses are refusals and
can lack an ETag; their code is read from `error.code` if it is 1–64 lowercase
ASCII letters/digits/underscores. The channel caps response bodies at 262144 bytes.

| Action | Body | Required result fields |
| --- | --- | --- |
| `connect` | `{channelId, deviceId, hostId, authorizationEpoch, agentId, sessionId, enabled:[capability_names]}` | `{channelId:<same>, connected:true, ...}`. Channel ID is a new lowercase UUID; enabled names are sorted. |
| `poll` | `{channelId, after:<consumed_sequence>}` | `{channelId:<same>, next:integer, requests:[{sequence:integer, request:DeviceToolRequest}], ...}`; at most eight rows. |
| `result` | `{channelId, result:DeviceToolResult}` | `{accepted:true, ...}`; otherwise outcome is unknown. |
| `close` | `{channelId}` | No result fields interpreted. Only when backgrounding and `native-device-tools-wait-v1` is present, add `reason:"paused"`. |

```json
{
  "version":1,
  "type":"device.tool.request",
  "requestId":"tool-call-demo",
  "deviceId":"device-demo",
  "hostId":"host-demo",
  "authorizationEpoch":1,
  "sessionId":"runtime-demo",
  "agentId":"default",
  "turnId":"turn-demo",
  "operation":"location.current",
  "arguments":{},
  "sentAt":1700000000,
  "expiresAt":1700000030
}
```

The result echoes all identity fields and the operation, changes
`type` to `device.tool.result`, omits `arguments` and `expiresAt`, and adds
`status` (`completed` or `failed`), optional `code`, `payload:object`, and its own
`sentAt`. Dates in these envelopes are integer Unix seconds. Native operation
arguments/results have their own date fields and schemas.

```json
{
  "version":1,"type":"device.tool.result",
  "requestId":"tool-call-demo","deviceId":"device-demo","hostId":"host-demo",
  "authorizationEpoch":1,"sessionId":"runtime-demo","agentId":"default",
  "turnId":"turn-demo","operation":"location.current",
  "status":"failed","code":"request_expired","payload":{},"sentAt":1700000031
}
```

Validate a whole poll batch before executing any row. Require contiguous row
sequences from `after + 1`, unique request IDs in that batch, and `next` equal
to its last sequence (or `after` for empty). Each request must be version 1 of
the exact type, at most 20480 encoded bytes, match the channel's scope/agent/
session, name an offered capability, have `sentAt > 0` no more than five seconds
in the future, and satisfy `expiresAt > now`, `expiresAt > sentAt`, and a maximum
120-second interval. Coordinator identifiers are nonempty, at most 512 UTF-8
bytes, and contain no control characters. Authorization epoch must be positive.

Execute validated rows in order. A later row can expire while an earlier one
runs: answer it `failed/request_expired`, keep the channel, and advance only
after the result is accepted. Never advance the cursor merely because a request
was polled or native work ran. Before delivery, require the result to echo the
entire request identity, scope, turn, and operation. The channel caps encoded
result envelopes at 256000 bytes; the coordinator caps the payload at 128000.

### Availability, reconnect, and mutation reconciliation

Device access switches express the person's opt-in; OS permission alone does
not authorize agent access. Current switches are device-wide across saved hosts
and agents. Host/session ownership and grant revision still fence every active
call. Most capabilities start disabled. Appearance is enabled by default until
the person disables it. Refreshing system permissions must never enable an app
grant or prompt on behalf of a tool call.

Recheck current owner, scope, grant/revision, expiry, cancellation, unlocked/
protected-data availability, and app availability before execution, after every
native asynchronous callback, before mutation, and before result delivery. A
revoked grant cannot deliver an earlier private read. Current Apple foreground
behavior includes inactive UI and a bounded background grace, plus a specifically
tracked external-app handoff; Android must implement its own lifecycle rules
without promising execution while the app is suspended.

Open one channel for a chat. `channel_ambiguous` means it is held elsewhere;
never select a device by most recent activity. A killed app can leave its own
channel until the host's 30-second lease expires. A newer plugin can replace a
channel belonging to the same device/host. The current client otherwise retries
up to four total channel attempts, 32 seconds apart, cancelling on ownership/
chat change. It sends no close after pre-open refusals `channel_ambiguous`,
`profile_not_served`, `profile_not_found`, `session_not_found`, `channel_capacity`,
or `channel_id_consumed`. Serialize replacement behind cleanup of the previous
channel; a cleanup must close only its captured old authority/channel.

Current polling is every 750 ms, or eight seconds when appearance is the sole
offered capability. Polling keeps the lease alive. A paused close is capability
negotiated because older plugins reject that extra key; it tells a newer host
to wait for the temporarily absent phone instead of immediately failing a call.
It does not guarantee a wake-up.

The coordinator allows at most four active operations and one journaled mutation.
Before a mutation, atomically save a SHA-256 fingerprint of the full sorted-key
request plus a pending result. For the same request ID and scope:

- A different fingerprint fails `request_conflict`.
- A completed journal entry returns its recorded outcome without running again.
- A pending entry returns `outcome_unknown`; it is not permission to repeat a write.

Journal durable outcomes before confirming them. Store only reconciliation
metadata and allowed result keys, never arguments, private read payloads,
calendar/reminder text, or a shortcut's output. Default durable keys are `id`,
`revision`, `deleted`; shortcut run also retains `status`. Photos delete's
`count` and shortcuts' `output`/`truncated` are live-only. Uncertain native
commits or failed journal verification answer `outcome_unknown`. Keep journal
writes atomic, owner-scoped, protected, excluded from backup, and bounded; the
current file implementation uses 512 records / 2 MB.
It retains mutation tombstones for one day past the request deadline and refuses
new writes at capacity rather than evicting an in-flight mutation.

Useful failure codes include `invalid_request`, `request_expired`,
`owner_changed`, `permission_disabled`, `device_unavailable`, `request_cancelled`,
`request_conflict`, `persistence_unavailable`, `device_busy`,
`result_limit_exceeded`, `outcome_unknown`, and tool-specific failures. Unavailable
private data must be an explicit failure, not a fabricated empty result.

Sources: [channel](../../Bighelp/Permissions/NativeDeviceToolSession.swift),
[envelopes, validation, journal coordination](../../Bighelp/Permissions/DeviceToolCoordinator.swift),
[permissions](../../Bighelp/Permissions/DeviceToolPermissions.swift),
[file journal](../../Bighelp/Permissions/DeviceToolFileJournal.swift),
[handoff lifecycle](../../Bighelp/Permissions/DeviceToolHandoff.swift).

## 10. Device capability names and platform boundaries

The current plugin's model-facing tools use `iphone_*` names; their wire
operations use the capability prefix shown below. Those existing names are a
compatibility fact, not an Android API implementation. Offer only capabilities
whose actual platform implementation can meet the contract. Replacing Apple
Music, Focus filters, or Shortcuts with an unrelated Android service under an
unchanged name requires deliberate host/client agreement.

| Capability / host tool | Wire operation suffixes | Required extra plugin feature | Portability and current implementation |
| --- | --- | --- | --- |
| `calendar` / `iphone_calendar` | `list`, `create`, `update`, `delete` | None beyond base | Portable data model; current backend is EventKit. Bounded date-range reads, opaque IDs/revisions, exact recurring occurrence writes. |
| `reminders` / `iphone_reminders` | `list`, `create`, `update`, `delete` | None beyond base | Task model can be ported; current backend is Apple Reminders/EventKit, including native location triggers. |
| `contacts` / `iphone_contacts` | `list`, `create`, `update`, `delete` | `native-device-contacts-v1` | Portable concept; implement Android permission/limited-access rules and stable revision semantics. Current Contacts backend never accesses notes. |
| `photos` / `iphone_photos` | `list`, `albums`, `get`, `save`, `update`, `createAlbum`, `delete` | `native-device-photos-v1` | Portable media concept; current implementation uses PhotoKit, limited-library scope, and system deletion confirmation. Host image transfer uses existing authenticated attachment routes. |
| `location` / `iphone_location` | `current` | `native-device-location-v1` | Portable location contract; backend, accuracy permission, and geocoding are platform-specific. No arguments. |
| `geofences` / `iphone_geofences` | `list`, `create`, `delete` | `native-device-geofences-v1` | Portable concept with OS-specific background/precision/region limits and delivery. Current Apple maximum is 20, and radius is 100–5000 m. |
| `alarms` / `iphone_alarms` | `list`, `create`, `update`, `delete` | `native-device-alarms-v1` | Current semantics use AlarmKit, only iOS/iPadOS 26+ and only alarms owned by this app. Android requires its own exact-alarm permissions and supported semantics. |
| `music` / `iphone_music` | `nowPlaying`, `search`, `library`, `play`, `control`, `createPlaylist`, `addToPlaylist`, `addToLibrary` | `native-device-music-v1` | Current contract is Apple Music/MusicKit, library IDs and catalog subscription behavior. Not a generic media-session contract. |
| `focus` / `iphone_focus` | `current` | `native-device-focus-v1` | Apple app Focus-filter values; only reads this app's filter, never changes system Focus. Android DND is not automatically equivalent. |
| `shortcuts` / `iphone_shortcuts` | `list`, `run` | `native-device-shortcuts-v1` | Apple Shortcuts allowlist and callback execution. Needs a separately agreed Android automation implementation or remains unavailable. |
| `appearance` / `iphone_appearance` | `get`, `set` | `native-device-appearance-v1` | Portable app setting behavior; bind it to the same settings the person controls. Current get/set cover mode and chat color. |

Journal create/update/delete mutations except appearance (idempotent setting).
Also journal photos save/createAlbum, music createPlaylist/addToPlaylist/
addToLibrary, geofence writes, alarm writes, and shortcut run. Music play/control
are intentionally unjournaled idempotent actions; the catalog calls these
"reads" for coordinator purposes, which does not imply they lack side effects.

`location.current` returns latitude/longitude (six decimals),
`horizontalAccuracyMeters`, UTC ISO-8601 `timestamp`, `precise`, and optional
`place` fields (`street`, `neighborhood`, `city`, `region`, `country`, `postalCode`).
Approximate results disclose roughness and omit fine address parts.
`appearance.get` returns mode, color, and choice lists; set validates only mode
and/or color against app settings. Do not add a data-sharing permission to these
appearance operations.

Dates in native data arguments are ISO-8601 with an offset or `Z`; resource IDs
and revisions are opaque. Update/delete require the exact current resource ID
and expected revision where the operation defines one. Unknown arguments and
empty updates fail `invalid_arguments`. Calendar recurrence changes affect one
occurrence, not a whole series. Photo get transfers a bounded JPEG thumbnail;
photo save resolves/fetches a host-granted file, rather than fetching arbitrary
model-supplied URLs. A shortcut can do arbitrary work, so an uncertain or
completed request ID must never run it a second time.

For full existing per-tool argument/result schemas, consult the supported
operation sections of [iPhone tools](../IPHONE_DEVICE_TOOLS.md#supported-operations)
and the actual validators below. Its older transport/version sections describe
historical Link delivery; section 9 here and `NativeDeviceToolSession` describe
the current direct native bridge. Some prose there is older than the catalog:
for example the current shortcut journal retains `status` as well as `id`.

Source implementations:
[operation and journal catalog](../../Bighelp/Permissions/DeviceToolCatalog.swift),
[calendar/reminders](../../Bighelp/Permissions/AppleDeviceToolService.swift),
[contacts](../../Bighelp/Permissions/DeviceContactsTool.swift),
[photos](../../Bighelp/Permissions/DevicePhotosTool.swift),
[location](../../Bighelp/Permissions/DeviceLocationTool.swift),
[geofences](../../Bighelp/Permissions/DeviceGeofenceTool.swift),
[alarms](../../Bighelp/Permissions/DeviceAlarmsTool.swift),
[music](../../Bighelp/Permissions/DeviceMusicTool.swift),
[Focus](../../Bighelp/Permissions/DeviceFocusTool.swift),
[Shortcuts](../../Bighelp/Permissions/DeviceShortcutsTool.swift),
[appearance](../../Bighelp/Permissions/DeviceAppearanceTool.swift).

## 11. Display transport reference

Bot Screen is a host Linux display observed through core RPC and a separate
binary RFB WebSocket. It is not the mobile device's own screen or a plugin
device-tool result. Unsupported `display.*` should hide the feature cleanly.

| RPC | Params | Read fields |
| --- | --- | --- |
| `display.status`, `display.start`, `display.stop` | `{profile}` | `supported`, `installed`, `running`, `missing`, `geometry`, `install_command`, `blocker`, `placement`, `lease`, `profile_key`; fields are optional and unknown fields ignored. |
| `display.thumbnail` | `{profile}` | `data_url` image data, or `suppressed` reason; suppressed thumbnails must not reveal a human-controlled display. |
| `display.observe` | `{profile, viewer_id?}` | Nonempty `ticket` (≤1024 UTF-8 bytes), `viewer_id` (≤256), optional `path` which must be `/api/display/ws`, plus status fields. |
| `display.lease.acquire`, `display.lease.release` | `{profile, viewer_id}` | `{lease:{holder, viewer_hash?, epoch, reason?}, ...}`. |

A lease holder is `agent` or `human`. A human holder is recognized locally by
`viewer_hash`, the first 12 lowercase hex characters of SHA-256 of the viewer
ID. Lease epoch never moves backwards. Treat viewer ID as a capability: display
only its hash, retain it for same-sign-in reconnects, and retire it on host/sign-in
change. Events `display.lease` contain `{profile_key, lease}`;
`display.status` carries a status with `profile_key`. Scope both to the selected
host and exact profile key, not a display name.

Observe issues a single-use ticket expiring in 30 seconds. Open
`wss://<same-host>/api/display/ws?display_ticket=<ticket>` (or WS for an HTTP
endpoint) using the same endpoint, TLS trust/redirect policy, proxy and access
headers as the core socket. Preserve any configured endpoint base-path prefix.
The stream request intentionally omits gateway
bearer/session-cookie login and disables automatic cookies; the ticket is its
only Hermes credential. Do not accept an arbitrary path or origin supplied by
an observation. Redact ticket-bearing URLs.

The socket carries binary RFB bytes only, with no assumption that a WebSocket
message equals an RFB message. The Apple wrapper caps WebSocket messages at
1 MiB. Implement RFC 6143 RFB 3.3/3.7/3.8, shared ClientInit, None security (the
Hermes ticket authenticates the bridge), 32-bit little-endian true color BGRX,
and encodings ZRLE (16), CopyRect (1), Raw (0), DesktopSize (-223). Request
updates incrementally after initial/full or resized frames. Current bounds are
8192 pixels per dimension and 4096×4096 total pixels. Unsupported security and
malformed rectangles/lengths fail instead of overallocating. The current client
ignores server clipboard text and does not send clipboard content.

Send keysyms and pointer/button messages only while this viewer holds the
human lease. Release held keys/buttons before handing back or disconnecting.
A deliberate close uses code 1000, telling Hermes the viewer closed and should
hand control back; a dropped connection preserves reconnect semantics. The
current viewer also explicitly releases its own lease on close. Close codes:

| Code | Meaning / recovery |
| --- | --- |
| 4000 | Another viewer took control; observe again for a fresh ticket. |
| 4001 | Screen stopped; stop reconnecting. |
| 4401 | Ticket expired/spent; observe again. |
| 4403 | Host denied address/origin; stop reconnecting. |
| Other/drop | Back off; current client uses 1, 2, 4, 8, 8 s, at most five retries. |

Takeover/ticket retries are immediate but bounded (three within ten seconds in
the current client). Never reuse a spent ticket. Lease and status events can
arrive before an RPC response; an older lease epoch must not undo a new one.
Thumbnails decode only bounded image data (current data URL limit 6 MB and
maximum dimension 8192), and a suppressed thumbnail is hidden, not cached as an
older visible picture.

Sources: [RPC service](../../Bighelp/BotScreen/BotScreenService.swift),
[status and ticket decoding](../../Bighelp/BotScreen/BotScreenStatus.swift),
[stream authentication](../../Bighelp/DirectHermes/DirectHermesBotScreenStream.swift),
[RFB bytes](../../Bighelp/BotScreen/RFB/RFBMessages.swift),
[RFB session](../../Bighelp/BotScreen/RFB/RFBSession.swift),
[lease and reconnect rules](../../Bighelp/BotScreen/BotScreenControl.swift).

## 12. App connection cards reference

Hermes `manage_connections` can pause a tool for a person to connect an app or
approve an MCP operation. On current hosts, cards arrive as `connection.request`
and `connection.update` events, recover from a resumed session's
`pending_connection`, and refresh through `connectors.operation.status`.
These are event snapshots followed by client RPC calls; they are not answered
by echoing a JSON-RPC server-request ID. Several operations may wait at once.
The documented current wait is five minutes; use the supplied deadline.

```text
ConnectionOperation = {
  op_id:string, seq:integer, targets:[Target],
  deadline_at?:unix_seconds, timeout_seconds?:number, tool_call_id?:string,
  settled?:boolean, settled_at?:unix_seconds, owner?:object, display?:object
}
Target = {
  name:string, kind:"connector"|"mcp"|"plugin"|"skill"|other,
  action:"connect"|"reconnect"|"install"|"enable"|"authorize"|other,
  state:"pending"|"initiated"|"connected"|"skipped"|"failed"|"expired"|"not_connected"|other,
  resolved?:boolean, detail?:string, instructions?:string,
  connect_url?:https_url, alias?:string,
  required_env?:[{name, required?:boolean, secret?:boolean, default?:string, prompt?:string}],
  tools?:[string]
}
```

Require a nonempty safe `op_id` ≤128 UTF-8 bytes, integral sequence, at most 32
targets, and unique safe target names ≤128 bytes. Apply only newer sequences
for an operation. Unknown kind/action/state becomes an unknown value, not an
authorization shortcut. `resolved` is authoritative when supplied; otherwise
connected/skipped/not_connected count as resolved. A target is open only when
unresolved and pending/initiated/failed/expired. `settled_at` supplies settlement
when `settled` is absent. A `display` object is the host's directory display,
not an actionable connection card in this client.

Accept only events for the current connection and bound runtime session.
An explicit `owner.type` other than `session` belongs to account settings and
must not appear in a chat card. Keep visible stored session ID distinct from
the runtime ID. All card calls below add
`owner:{type:"session",session_id:<current_runtime_id>}` and the bound `profile`:

| Action | Method and other params |
| --- | --- |
| Skip selected targets | `connection.respond {op_id, result:{targets:[{name,status:"skipped"}]}}`. |
| Approve MCP target | `connection.respond {op_id, result:{targets:[{name,status:"approved",env?:object}]}}`; send only requested nonempty environment fields. |
| Retry failed/expired sign-in | `connectors.connect {connectors:[name], reconnect?:true, alias?:string}`; reconnect only for a reconnect action. Adopt a returned operation snapshot. |
| Sign-in page closed | `connectors.operation.wake {op_id}`. Closing a browser is not proof that sign-in succeeded. |
| Reconnect refresh | `connectors.operation.status {op_id}` after binding the new runtime session. |

`connection.respond` with `settled:true` removes the card. RPC rejection 4004
means the operation ended (deadline or another client answered); remove it.
4002 means the sign-in link is still valid; retain it. Other failures retain an
actionable state and allow retry. Keep per-target in-flight guards so taps
cannot answer twice. Connection replacement removes old cards/actions; rebuild
from fresh snapshots and remembered operation IDs under the new runtime.

Open only HTTPS `connect_url` values with a host and no URL user/password,
maximum 4096 UTF-8 bytes. Environment fields default to required and secret;
keep secrets out of diagnostics and do not send unrequested values. Optional
`connectors.catalog {profile}` enriches app names/logos; it is not account
creation or proof a connection succeeded. Account-scoped Settings Apps flows
are a related but separate owner surface.

### Account-scoped app management

The current Settings Apps client deliberately waits for the person to choose
setup before making account calls, because a call can create the host's free
connector identity. A port should preserve that explicit setup boundary.

| Operation | Current RPC params / result fields used |
| --- | --- |
| Initial setup | `connectors.list {owner:{type:"account"}}`; successful answer enables the list. |
| Catalog | `connectors.catalog {}`; reads `connectors` rows including `slug`, name/logo metadata, `description`, `category`. |
| Accounts | `connectors.accounts {}`; reads `accounts` rows with `connection_id`, `connector`, `label`, `alias`, `status`, `active`, `disabled`. An account works when status is `active`, `active:true`, `disabled:false`. |
| Connect | `connectors.connect {owner:{type:"account"},connectors:[slug],alias?}`; same operation snapshot as a chat card. |
| Repair account | Also send `reconnect:true`, `connection_id` to `connectors.connect`. |
| Wake / status | `connectors.operation.wake` / `connectors.operation.status` with `{owner:{type:"account"},op_id}`. |
| Rename | `connectors.accounts.rename {connection_id,alias}`; then reload. Alias is 1–32 lowercase ASCII letters/digits/dashes, starts with a letter/digit. |
| Remove | `connectors.accounts.remove {connection_id}`; then reload. |

The settings client polls the operation every two seconds while waiting (up to
five minutes, or eight seconds after the person closes the sign-in page), then
reloads accounts. Closing a page or a local wait timer never proves a successful
account connection. RPC errors distinguish method absent (`-32601`), connectors
turned off (`4031`), setup required (`4032`), insufficient organization permission
(`4030`), and alias conflict (`4090`). These are outside the plugin native HTTP
response envelope.

Sources: [snapshot model](../../Bighelp/Connectors/ConnectorOperation.swift),
[card state and responses](../../Bighelp/Connectors/ConnectorCardStore.swift),
[account app management](../../Bighelp/Connectors/ConnectorAppsModel.swift),
[workspace event binding](../../Bighelp/DirectHermes/DirectHermesWorkspaceStore.swift),
[connector tests](../../BighelpTests/ConnectorCardTests.swift).

## 13. Port verification references

A new client should exercise real JSON contracts without needing Apple's UI.
Useful existing tests and vectors are:

| Contract | Repository evidence |
| --- | --- |
| Both groups host paths, attempt shapes, discard and cursor skips | [HermesGroupsHostPathTests](../../BighelpTests/HermesGroupsHostPathTests.swift), [recorded vectors](../../BighelpTests/Fixtures/HermesGroups/) |
| Group request/receipt validation, log replay and cancellation ownership | [client tests](../../BighelpTests/BighelpLinkHermesBotModeClientTests.swift), [contract tests](../../BighelpTests/HermesBotModeContractTests.swift) |
| Group approval identity and optional command | [approval tests](../../BighelpTests/BighelpLinkHermesBotModeApprovalTests.swift) |
| Durable sends, retries and room cache | [persistence tests](../../BighelpTests/HermesBotModePersistenceTests.swift), [room store tests](../../BighelpTests/BotModeRoomStoreTests.swift) |
| RoomLink setup, target identity, credentials | [peer tests](../../BighelpTests/HermesBotModePeerTests.swift), [two-host probe](../../Scripts/RoomLinkProbe.py) |
| Optional observations, shared sequence, reset and source loss | [activity tests](../../BighelpTests/HermesBotModeActivityTests.swift) |
| Current device HTTP routes, batch validation, stale owner/result rejection, capability filtering and paused close | [NativeDeviceToolSessionTests](../../BighelpTests/NativeDeviceToolSessionTests.swift) |
| Device permission revisions, idempotent mutation journal, privacy and lifecycle | [coordinator tests](../../BighelpTests/DeviceToolCoordinatorTests.swift), [permissions tests](../../BighelpTests/DeviceToolPermissionsTests.swift), [journal tests](../../BighelpTests/DeviceToolFileJournalTests.swift), [handoff tests](../../BighelpTests/DeviceToolHandoffTests.swift) |
| Display RPC/stream authentication, lease epochs and RFB byte vectors | [state tests](../../BighelpTests/BotScreenStateTests.swift), [RFB tests](../../BighelpTests/BotScreenRFBTests.swift), [viewer tests](../../BighelpTests/BotScreenViewerModelTests.swift) |
| Full connector snapshots, answers, deadlines, stale runtime rejection | [ConnectorCardTests](../../BighelpTests/ConnectorCardTests.swift) |

Recorded host replies, synthetic contract tests, simulator behavior, and physical
OS permission behavior prove different things. For an Android port, keep those
evidence categories separate, rerun current host flows against isolated Hermes
instances, and verify permissions/lifecycle on an actual Android device. Keep
unavailable extensions disabled until their negotiated contract and platform
implementation both exist.
