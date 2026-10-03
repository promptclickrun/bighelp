# Hermes Bot Mode

## Product boundary

bighelp supports Hermes and is building its own bighelp Native harness. Neither
path replaces the other. The Goose-based iOS/Companion runtime remains under
development; the local Bot Mode fixture runner is not that production engine.

For Hermes hosts, Hermes owns room membership, routing, task execution,
idempotency, fencing and the durable event log. The iOS app presents that state through one typed `groups.*` client. It can use
native authenticated Direct workspace operations or explicitly selected,
authenticated encrypted Link. Direct does not require a bighelp account.
The plugin forwards these fixed operations through Hermes' existing
`tui_gateway.server.handle_request` dispatcher. No second daemon, private
database adapter or synthesized member-turn prompt is needed.

## Readiness and ownership

The client is bound to the selected transport's verified authority, selected host
and authentication/connection generations. Only that host's rooms are listed;
switching hosts retires old catalog results, observers and actions before the
replacement context is exposed.
Check ownership and cancellation around every await. A stale completion must
never update a newly selected instance. Negotiate `groups.capabilities` after
Link verification. Execution requires protocol 2, a running driver, an authority
identifier, the necessary methods and typed-events/idempotent-send/monotonic-log/
coordinator-fencing features. Advertising methods alone does not prove that the
driver runs. Peer room-link enablement is not required for local hosted rooms.

An older plugin or unavailable driver leaves saved rooms readable. Do not enable
action controls that cannot execute, and do not silently fall back to local
sequential direct chats. Existing local harness interfaces remain available for
fixtures and future separately qualified runtimes.

Native room discovery uses every bounded `groups.list` page. Room names,
member IDs, profile IDs, targets and revisions remain distinct server facts.
Unavailable profiles stay in the roster and its count. Hidden member session
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

Link advertises `groups-results-v1` for a separately bounded groups-result
envelope. Only an opted-in request receives the corresponding result marker.
Legacy envelopes and limits remain unchanged. Native log authority is validated
at its exact schema path; this never permits gateway or secret-bearing keys in
arbitrary workspace payloads. Event bytes are never truncated to fit transport.

## Durable interaction contract

- Create one stable room with selected profile members. Hermes has no supported
  operation to edit that roster after creation; the app must reflect that limit.
  Persist the create intent before dispatch. Recover a lost receipt by room ID:
  reissuing an old create name can conflict after another client renames the room.
- Persist the client event ID, exact text and thread ID before sending. An
  uncertain retry reuses that identity. Do not generate a second event merely
  because the phone lost a response.
- Preserve the server's user-event identity. Replay contiguous `groups.log`
  pages from the last persisted cursor, including all pages. A room snapshot's
  latest sequence and a send receipt do not establish that earlier log entries
  have been consumed.
- Validate room, cursor, sequence and authority before publishing a page.
  Deduplicate by server event identity while preserving server order.
- Reopening or reconnecting replays durable history and reconciles running state.
  Screen dismissal and task cancellation do not stop Hermes work. Only the
  explicit Stop action sends `groups.stop`.
- Show exact hosted-room approval requests from `driver_status.pending_actions`.
  Resolve only that task, execution generation and request through
  `groups.approve`, using Allow Once or Deny. Ordinary device approvals are a
  separate contract. Do not silently approve or offer unsupported persistent grants.
  Command text is optional in Hermes: show it verbatim when present and keep a
  valid request actionable when Hermes supplies only the request identity.
- Retry eligible deferred/indeterminate tasks with their server task IDs through `groups.retry`.
  `driver_status.pending_actions` may advertise a retry before any failure event
  is available. Present that task action without inventing a member or failure.
  Keep each retry receipt and match terminal events by task ID, execution
  generation, thread ID and turn ID. All retried tasks must settle before the
  turn completes; unrelated room activity or the latest human message is not
  sufficient. A polling timeout is not an authoritative task failure. Preserve
  uncertain work until the host resolves it.
  Retain the batch, received task receipts and uncertain dispatches across
  relaunch. Hermes has no retry-idempotency token or public task-receipt lookup;
  a missing receipt is not permission to replay the batch.
- Show agent messages and supported activity from typed events. Do not invent
  tool calls or claim token streaming when the hosted-room log only provides
  completed member messages.

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

Run `HermesBotModeContractTests`, `BighelpLinkHermesBotModeClientTests`,
`BighelpLinkHermesBotModeApprovalTests`, `BotModeRoomStoreTests` and
`ChatBotModeIntegrationTests` along with the chat interaction regression gate.
The Link client tests cover request shapes, cancelled/stale results, idempotency,
cursor validation and driver status. Store checks cover persistence, replay,
capability gating and room execution. Preserve the separate local fixture tests.

Run the plugin contract and workspace-control suites with the official Hermes
source on `PYTHONPATH`. Publish the matching plugin separately from the iOS
archive, then activate it using Hermes' supported installer/updater. An app
upload does not activate a plugin on a user's host. Record source, simulator,
live host and TestFlight evidence separately; none substitutes for the others.
Include `test_hosted_room_contract` and the portable
`bighelp-plugin/tests/fixtures/groups-result-v1.json` vector for negotiated
envelope and encryption coverage.

Room discovery on the Hermes host must exclude invalid profile directories and
deleted-profile tombstones. In the September 10 host version, enumerating every
directory included `profiles/.deleted` and made `groups.create` reject all local
rooms. The host fix uses Hermes' profile validator and tombstone helper; retain
the hosted-room integration regression when updating Hermes. This is a host
prerequisite, not something the iOS client should bypass or repair through a
private filesystem API.
