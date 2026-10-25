# Hermes chat, sessions, prompts and history

This is the platform-neutral contract implemented by bighelp's Direct Hermes client. It is intended for an Android, Expo, Kotlin or other native client that uses the same authenticated Hermes dashboard WebSocket and REST API. Hermes executes the agent; the client owns presentation, local drafts, request correlation and recovery gates.

Examples use invented opaque identifiers. Fields shown in examples are representative; the tables distinguish fields the client requires from optional metadata. This repository contains the consuming client and contract tests, not the Hermes server. A behavior described as **client policy** is an app invariant, not an additional server guarantee. Capability replies and actual method results take precedence over a Hermes version string.

Primary implementations: [conversation lifetime](../../Bighelp/DirectHermes/DirectHermesConversationClient.swift), [submission](../../Bighelp/DirectHermes/DirectHermesConversationClient+Submission.swift), [events](../../Bighelp/DirectHermes/DirectHermesConversationClient+Events.swift), [recovery](../../Bighelp/DirectHermes/DirectHermesConversationClient+Recovery.swift), [live projection](../../Bighelp/DirectHermes/DirectHermesProjection.swift), [session catalog](../../Bighelp/Hermes/DirectHermesSessionCatalogClient.swift), [history projection](../../Bighelp/Hermes/DirectHermesHistoryProjection.swift), [release contract](../../Bighelp/DirectHermes/DirectHermesReleaseContract.swift).

## 1. Identities and authority

Keep these coordinates separate in every model and operation:

| Coordinate | Meaning and use |
|---|---|
| Host/sign-in identity | Exact selected dashboard endpoint and authenticated principal. Scopes credentials, drafts, cached history and permissions. An address alone does not prove the same sign-in. |
| Connection owner/generation | Local lease for one connection. Reconnecting creates a new owner even for the same sign-in. Check it before dispatch and after every suspension/await, including errors. A stale result cannot update a new connection. |
| `profile` | Hermes profile/agent ID. It is not the display name. A direct chat has exactly one profile. |
| Runtime session ID | Returned as `session_id` by create/resume/activate. Targets live RPCs such as `prompt.submit`, `session.steer`, `session.interrupt`, `session.activate` and `session.events.since`. Can change on reattachment. |
| Stored session ID | Returned as `stored_session_id`, `session_key` or `resumed` where documented below. Targets REST history, stored metadata and `session.resume`. Compaction can produce a successor stored ID. |
| Canonical registry ID | A profile's `canonical_session.id` for Bot Chat. It is a durable anchor, not whichever chat was most recently active. |
| App-visible conversation ID | Stable local route identity, scoped by authority, profile and immutable history/lineage anchor. Never send it in place of a native runtime or stored ID. |
| History row ID | Physical positive integer `id` in REST history; `row_id` in live binding/reaction receipts. Not a runtime ID, turn ID, message text hash or chronological sort key. |
| Event sequence and epoch | `seq` is a per-session event cursor within a `replay_epoch`/`epoch`. Another runtime's sequence, or a saved-session reaction sequence, cannot advance this runtime's cursor. |
| Local submission ID | A UUID in the device's uncertainty journal. It is **not** a Hermes submit nonce and is not sent to `prompt.submit`. |
| Server-request wire ID | Original JSON-RPC string `id`. Opaque, exact UTF-8 bytes, including whitespace and Unicode normalization form; echo unchanged in the response. Different from approval `params.request_id`. |

The Swift app-visible identity combines a format prefix, authority cache scope and canonical base64url-encoded exact profile and immutable anchor. A port can use another unambiguous local encoding, but must preserve the same scoping and stability. Do not change visible identity when a stored tip changes. Retain former stored IDs for notification routing, and migrate the draft journal's durable coordinate after verified adoption.

Source: [identity and coordinate models](../../Bighelp/Hermes/DirectHermesSessionModels.swift), [workspace owner](../../Bighelp/Workspace/WorkspaceOwner.swift), [coordinate adoption](../../Bighelp/DirectHermes/DirectHermesConversationClient.swift), [owned RPC lease](../../Bighelp/DirectHermes/DirectHermesOwnedRPC.swift). Exact opaque-ID and owner fences are tested in [protocol parity](../../BighelpTests/DirectHermesProtocolParityTests.swift), [reconnect parity](../../BighelpTests/DirectHermesReconnectParityTests.swift) and [conversation tests](../../BighelpTests/DirectHermesConversationTests.swift).

## 2. Before admitting chat work

Use the selected host's authenticated `/api/ws` JSON-RPC connection; register server-request handlers before sending work. Every new physical socket must announce:

```json
{"jsonrpc":"2.0","id":"client-capabilities-1","method":"client.capabilities","params":{"server_requests":true}}
```

This tells Hermes that this socket can answer approval, clarify, secret and sudo requests. Without it, some Hermes hosts answer those requests themselves with empty values. The current client announces once per socket after handlers exist, reannounces after reconnect, and tolerates an explicit RPC rejection from an older host. A transport failure allows a later announcement attempt. This announcement does not claim support for every server-request method.

`per_session_exclusive_submit` must be a Boolean in the gateway capability manifest. Missing or string `"true"` is invalid. `false` disables chat submit, queue and slash-command capabilities in this client; reads, approvals and non-submission session controls remain available. This is a **client safety gate** based on a host-advertised guarantee that submitters for one runtime are serialized. Do not infer it from version metadata.

Readiness for a new local admission is: connected, authoritative sequence coverage, no hydration, no recovery required, no durable reattachment required, and no pending local admission. An active turn is a separate condition: a ready connection can offer Steer/Queue while it runs. The current client allows a new message to wait behind an already verified, temporary history catch-up; it does not send during that catch-up.

Sources: [capability manifest](../../Bighelp/DirectHermes/DirectHermesCapabilityManifest.swift), [network advertisement](../../Bighelp/DirectHermes/DirectHermesNetworking.swift), [readiness gates](../../Bighelp/DirectHermes/DirectHermesConversationClient.swift), [parity tests](../../BighelpTests/DirectHermesReconnectParityTests.swift).

## 3. Create, resume and activate

### Create a new chat

```json
{"jsonrpc":"2.0","id":"create-1","method":"session.create","params":{
  "profile":"research",
  "source":"bighelp",
  "idempotency_key":"11111111-1111-4111-8111-111111111111",
  "cwd":"/home/example/projects/demo",
  "cwd_explicit":true,
  "model":"example-model",
  "provider":"example-provider",
  "reasoning_effort":"high",
  "fast":false
}}
```

Representative accepted result:

```json
{"jsonrpc":"2.0","id":"create-1","result":{
  "session_id":"runtime-a",
  "stored_session_id":"saved-a",
  "session_key":"saved-a",
  "message_count":0,
  "messages":[],
  "running":false,
  "info":{"profile_name":"research","stored_session_id":"saved-a","model":"example-model","provider":"example-provider","cwd":"/home/example/projects/demo","lazy":true}
}}
```

The actual catalog create path sends `profile`, `source` and `idempotency_key`, plus the choices applicable to that creation:

| Parameter | Client use |
|---|---|
| `profile` | Required. The profile to create for. |
| `source` | Always `"bighelp"`. Hermes uses it to select surface instructions. Omitting it can select terminal instructions; `"desktop"` promises a different client's tools. A port of bighelp should preserve this source. |
| `idempotency_key` | Lowercase UUID of one persisted logical create intent. Reuse the same key when resolving that intent. Repository guidance records a five-minute host retention window; older Hermes can ignore the key. This is not indefinite exactly-once creation. |
| `title` | Optional ordinary title; first Bot Chat uses `"Bot Chat"`. |
| `hidden`, `follow_profile_config` | Both `true` for a first canonical Bot Chat. Ordinary creation omits them. |
| `cwd`, `cwd_explicit` | Explicit host folder and `true` after deliberate selection. Validate the returned CWD. Do not derive a folder merely from an active project. |
| `model`, `provider` | Optional session override. `provider` accompanies a selected model. The create result must report the chosen model. |
| `reasoning_effort`, `fast` | Optional session overrides. `fast` is Boolean here. |
| `close_on_disconnect`, `omit_messages` | Allowed by the workspace route; ordinary catalog creation currently omits them. Their presence in the allowlist is not evidence they are always sent. |

Create acceptance requires empty `messages`, `message_count:0`, actual runtime and stored IDs, an `info` object naming the requested profile, consistent durable aliases if supplied, confirmation of a selected model and confirmation of an explicitly requested CWD. The runtime can be lazy and the session can remain an unpersisted draft until its first turn.

**Client policy:** durably persist a creation record *before* dispatch and each received coordinate before another mutation. The record contains schema version, authority scope, intent UUID, profile, purpose, phase, connection generation, optional CWD and received runtime/stored/canonical IDs. The ordinary and first-canonical flows are distinct. Do not create another chat because a known canonical chat is missing or a resume fails.

There is one narrow compatibility retry: when create explicitly rejects `cwd_explicit` with the mapped `invalid_params` result, retry the same create intent/key without that field. The code's rationale is that older hosts reject unknown fields and already honor the old CWD precedence. A timeout or malformed receipt does not authorize this retry.

First Bot Chat creation also persists its title through `session.title`, requires the title receipt to be non-pending, and reads the exact `Bot Chat` registry back. A title-conflict winner is adopted from that registry. No introductory prompt is required. Recovering an unfinished create uses its retained identity/key or resumes its received stored ID; it must not block an independent New Chat forever.

Sources: [creation state](../../Bighelp/Hermes/DirectHermesSessionModels.swift), [`dispatchCreate` and canonical creation](../../Bighelp/Hermes/DirectHermesSessionCatalogClient.swift), [allowed create fields](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift), [architecture guidance](../../AGENTS.md), [catalog tests](../../BighelpTests/DirectHermesSessionCatalogClientTests.swift).

### Resume a durable chat

Resume consumes a **stored** ID, not the previous runtime ID:

```json
{"jsonrpc":"2.0","id":"resume-1","method":"session.resume","params":{
  "session_id":"saved-a","profile":"research","source":"bighelp",
  "close_on_disconnect":false,"defer_history":true,"omit_messages":true
}}
```

```json
{"jsonrpc":"2.0","id":"resume-1","result":{
  "session_id":"runtime-b","stored_session_id":"saved-b","session_key":"saved-b","resumed":"saved-b",
  "running":false,"messages":[],"messages_omitted":true,
  "info":{"profile_name":"research","stored_session_id":"saved-b","model":"example-model"}
}}
```

The returned stored ID is authoritative and may be a compaction successor of the requested ID. At least one of `session_key`, `stored_session_id`, `resumed` must exist as a nonempty bounded string; every supplied alias must agree exactly. A supplied `info.profile_name` must agree with the requested profile. `info` is required; a supplied `running` must be Boolean. The shared release decoder bounds runtime/stored IDs to 512 UTF-8 bytes and validates them as coordinates.

Two current call sites differ intentionally in request shape: retained-stream recovery uses all fields shown above, including `close_on_disconnect:false`; catalog `resume(profileID:storedID:)` sends `profile`, stored `session_id`, `source`, `defer_history:true`, `omit_messages:true` and currently omits `close_on_disconnect`. Do not treat the latter omission as a guaranteed host lifetime policy.

### Activate an already verified live runtime

```json
{"jsonrpc":"2.0","id":"activate-1","method":"session.activate","params":{"session_id":"runtime-b","profile":"research","omit_messages":true}}
```

Activation attaches/touches an existing runtime. It does not create an agent or admit a prompt. The snapshot includes `session_id`, a durable alias (catalog-backed recovery requires `session_key`), Boolean `running`, optional `info`, `todo_state`, `inflight`, `queued`, `pending_approval`, `pending_clarify`, `pending_connection`, `turn_started_at`, and messages when not omitted. Current runtime-control proof is stricter: it requires `messages_omitted:true`, `messages:[]`, exact runtime/stored/profile echoes, `info.stored_session_id`, model, and built-runtime provider/reasoning values. Lazy runtimes may omit provider/reasoning.

**Client policy:** reuse an activation only for a previously proved exact runtime/profile/durable pair belonging to the current owner and replay epoch. REST discovery or an old runtime number is not write authority. On a stale-runtime refusal, invalidate the exact runtime binding and reattach using the durable coordinate before admitting more work. Discovery alone must not create/resume chats to determine whether agents are working.

Sources: [shared resume parameters and decoder](../../Bighelp/DirectHermes/DirectHermesReleaseContract.swift), [catalog binding validation](../../Bighelp/Hermes/DirectHermesSessionCatalogClient.swift), [activation snapshot validation](../../Bighelp/DirectHermes/DirectHermesConversationClient+Projection.swift), [retained reattachment](../../Bighelp/DirectHermes/NativeWorkspaceSessionBridge+Recovery.swift), [runtime-control proof](../../Bighelp/DirectHermes/DirectHermesSessionControlClient.swift), [reconnect tests](../../BighelpTests/DirectHermesReconnectParityTests.swift).

## 4. Submit, steer, queue, interrupt and side tasks

These operations target `session_id: <runtime ID>` and ordinarily include `profile`. A receipt proves admission only to the extent described; it does not prove the agent consumed a steer, finished a tool or persisted a final reply.

| Method | Additional parameters | Accepted response and client behavior |
|---|---|---|
| `prompt.submit` | `text`; current plain-send policy adds `queued:true`; optional native `images` on attachment paths | `status:"streaming"` or `"ok"` admits a live turn; retain the send's pending state until the native terminal lifecycle. `status:"queued"`, `"steered"`, `"redirected"` are also accepted by the ordinary send decoder and transfer queue ownership to Hermes; ordinary chat then returns on admission. The narrower explicit queue path accepts `queued` or `streaming`. Optional `user_row_id` binds the newest unsaved human row. |
| `session.steer` | `text` | Actual steer success is `status:"queued"`; `status:"rejected"` is a definite refusal. A `streaming` result is invalid for this method. Requires an observed active turn in this client. Does not silently become a new or queued prompt when idle. |
| `session.queue` | `text` | Allowed workspace operation, but the current conversation client's Queue UI uses `prompt.submit` with `queued:true`. This file does not assert a `session.queue` receipt contract not exercised by that path. |
| `session.interrupt` | None | Requires `status:"interrupted"`. Marks “stop requested”; the later `session.info.running:false` remains the turn-end authority. |
| `session.redirect` | `text` | Explicit advanced operation; returns exactly `{status,text}` with correction status `redirected`, `queued` or `rejected`. Separate from Interrupt and send. |
| `prompt.background` | `text` | Exactly `{task_id:<nonempty string>}`. Runs beside the main turn. Completion is `background.complete` for that task ID. |
| `prompt.btw` | `text` | Exactly `{task_id:<nonempty string>}`. Completion is `btw.complete`. |

Example ordinary admission:

```json
{"jsonrpc":"2.0","id":"submit-1","method":"prompt.submit","params":{"session_id":"runtime-b","profile":"research","text":"Summarize the project","queued":true}}
```

```json
{"jsonrpc":"2.0","id":"submit-1","result":{"status":"streaming","user_row_id":101}}
```

`queued:true` on an apparently idle send prevents another surface winning the race from causing the host's default interrupt/redirect behavior. A `streaming` ACK is **not** “ready for another ordinary submit”: the turn stays pending through tool work, final assistant segments and goal/loop evaluation. A mid-turn Send uses the selected Steer or Queue path; Steer is the product default.

Interrupt and send is a client sequence, not `session.redirect`:

```text
persist exact text and method=session.interrupt
send session.interrupt once
require status=interrupted and the same connection owner
check local cancellation
replace journal method with prompt.submit
send prompt.submit(text, queued=true) once
accept queued or streaming; retire the local uncertainty record
```

Stop clears the old host queue; enqueue only after its confirmed receipt. If either receipt is lost, do not proceed past that uncertain stage or retry either mutation automatically. Sending attachments while a turn runs supports Queue only in this adapter. The upload/file/PDF preparation paths are separate from turn admission; do not turn an uncertain upload into a resend.

For live voice, the normal turn sends `surface:"voice-live"` and, for a non-command prompt, `voice_turn:true`. A queued voice receipt has no eventual turn identity, so its waiter stays until a native `message.start` binds it. It returns only the exact verified final segments of that turn; overlap, failure or uncertainty cannot become a claimed answer. Requests made while the chat is busy can use `prompt.background`; these side tasks cannot access the phone's device-tool channel. Current side-task text input limit is 1 MiB; receipt task IDs are nonempty and at most 4,096 bytes.

Optional `native-people-v1` speaker attribution is a bounded pre-send plugin note (`people/speaking`) using the **stored** session ID and a saved person identity/name. It is not a `prompt.submit` field. The note wait is capped at 1.2 seconds and does not rewrite the user's text or send an on-screen placeholder name.

Sources: [submission state machine](../../Bighelp/DirectHermes/DirectHermesConversationClient+Submission.swift), [side-task methods](../../Bighelp/DirectHermes/DirectHermesSessionActions.swift), [background waiter](../../Bighelp/DirectHermes/DirectHermesConversationClient+Events.swift), [queued caller](../../Bighelp/DirectHermes/DirectHermesConversationClient+Queued.swift), [speaker note](../../Bighelp/DirectHermes/DirectHermesChatSpeakerNote.swift), [attachment admission](../../Bighelp/DirectHermes/DirectHermesConversationClient+Attachments.swift). Tests include `plainSendDuringOwnRunningTurnSteers`, `acknowledgedSteersDoNotBecomeRetainedSubmissionAlerts`, `interruptAndSendPersistsThenStopsThenQueuesExactlyOnce` and `unknownInterruptOrSendNeverRetriesOrDropsItsOriginalIntent` in [conversation tests](../../BighelpTests/DirectHermesConversationTests.swift).

## 5. Submission uncertainty and the local journal

The client has no durable prompt-submit idempotency key or host query that proves which local UUID was accepted. A JSON-RPC request ID is correlation for one request, not a replay token. Identical text in history is not acceptance proof.

Before a mutation, save the original composer text, exact outgoing method/text, local UUID and creation time under the exact host/profile/stored-session scope. Preserve newer composer edits independently. The current protected atomic draft store saves attachment bytes separately only for a **definitely refused** intent; ordinary uncertain upload entries retain their existing text/reference cost. A write failure before dispatch must prevent dispatch.

| Outcome | Current client policy |
|---|---|
| Validated ordinary streaming/ok receipt, then unambiguous successful terminal lifecycle | Retire the journal entry. Timeline already received deltas; do not append the function's return value as another reply. |
| Validated queued/steer receipt | Retire the admission-uncertainty entry. Hermes now owns accepted bytes. This does not claim steer consumption. |
| Confirmed admitted turn interrupted by local suspension | Retain known admission/turn/epoch evidence; exact same-epoch successful terminal replay can settle it later. |
| `prompt.submit` explicit refusal `4001`, `4007`, `4090` | Save a definitely unsent entry with `rejectionCode`, original composer text and attachments. `4001`/`4007` revoke the runtime until durable reattachment. `4090` can mean another process owns the session or the open-session cap; transport preserves `error.data.reason == "MAX_CONCURRENT_SESSIONS"` as the latter. |
| Proven pre-admission input/ownership refusal | The narrow code allowlist is `4001,4002,4004,4009,4010,4030,4130`, plus `4007,4090` for `prompt.submit`; method-specific handling above takes precedence. Retire only when non-admission is actually established. |
| Unknown timeout/disconnect/cancellation, malformed receipt, arbitrary command failure | Retain exact journal entry, set recovery required, do not retry, do not switch transport, do not convert it into a chat message. |
| Recovery observes an idle snapshot | Restore transport readiness when coverage is valid; idle does not prove whether a lost submit was admitted. Keep the original uncertainty record. |
| Explicit local review | Can remove a retained record after saving that decision. Reviewing is not sending. A future intentional send is a new admission. |

The ordinary lost-ACK path may attempt one exact-owner snapshot/replay recovery so independent new input can become usable again. It leaves the original uncertain entry untouched. An uncertain steer similarly stays local after recovery without blocking every independent future message. A failure to save refusal/retirement leaves the prior durable entry in place and must not trigger replay.

There are two independent waits: the JSON-RPC admission receipt and the turn's terminal lifecycle. Events can precede the admission receipt. Track candidate native turn IDs seen during the local pending slot, terminal observations for each and whether multiple starts overlapped. Do not settle a submission from an unrelated turn's final. The current client keeps at most two candidate starts to detect ambiguity. A failed `message.complete` before any `message.start` is a special known failed turn and can settle its own send.

For “send without waiting for response” callers, `QueuedConversationClient.submit` launches the same ordinary path and waits only for definite admission (currently up to 45 seconds). It does not use a second transport or detached outbox.

Sources: [draft record and atomic storage](../../Bighelp/DirectHermes/DirectHermesDraftStore.swift), [journal admission/settlement](../../Bighelp/DirectHermes/DirectHermesConversationClient+Submission.swift), [suspension](../../Bighelp/DirectHermes/DirectHermesConversationClient.swift), [lost-ACK, refusal and queue tests](../../BighelpTests/DirectHermesConversationTests.swift), [reason decoding parity](../../BighelpTests/DirectHermesProtocolParityTests.swift).

## 6. Slash commands

Load commands from `commands.catalog`, using runtime `session_id` and `profile` for an attached chat, or `profile` plus optional host `cwd` for a draft. Do not hard-code a complete menu: skills, plugins and user commands are host-installed.

The response consumed here has `pairs:[["/name","description"],...]` (at most 2,048), with optional `canon`, `commands`, `skills` and `categories`. `canon` maps aliases to canonical invocation keys. `skills` identifies skill invocations. Category names `Plugin Commands` and `User Commands` identify those sources; otherwise the entry is core. `commands` metadata can contain `argument_mode`. Preserve invocation spelling/identity; the client skips individual invalid names, flattens control characters in descriptions and trims displayed descriptions to 240 characters. Supported command-name characters are Unicode alphanumerics, `-`, `_`, `.`, with 1–96 UTF-8 bytes after `/`.

| Command source | Dispatch |
|---|---|
| Selected core command, or typed command without a non-core selection | `slash.exec {session_id,profile,command:<whole original slash text>}` |
| Selected skill, plugin or user command | `command.dispatch {session_id,profile,name:<name without slash>,arg:<arguments>}` |
| `slash.exec` explicitly rejects with `4018` | Replace journal method and dispatch once through `command.dispatch`; this code proves the first route refused before execution. Typed parsing removes leading `/`, lowercases the first whitespace-delimited name and passes the remaining argument text. No transport-failure fallback. |

A dispatcher may return `{type:"skill"|"send",message:<expanded text>}`. That is an instruction to the client, not proof that a turn started. Submit those exact bytes once through `prompt.submit` with `queued:true`, then use normal admission/terminal rules. `/plan` and skills can depend on this expansion. If a command returns `output` and is not `streaming`/`queued`, show that output once as a command result and settle immediately. A command whose expansion/submit outcome is unknown must not be rerun.

The first message in Code mode must use the same command router; sending a leading slash directly as `prompt.submit.text` bypasses command expansion. The menu selection is validated against the current text before dispatch, so editing the command cannot execute a stale selected entry.

Sources: [catalog decoder](../../Bighelp/Chat/SlashCommands.swift), [command dispatcher and fallback](../../Bighelp/DirectHermes/DirectHermesConversationClient+Submission.swift), [command tests](../../BighelpTests/DirectHermesConversationTests.swift), [Code mode guidance](../../AGENTS.md).

## 7. Live event envelopes and payloads

Hermes events are JSON-RPC notifications with method `event`:

```json
{"jsonrpc":"2.0","method":"event","params":{
  "type":"message.delta","session_id":"runtime-b","seq":24,"payload":{"text":"Hello"}
}}
```

Live events can include additional outer parameters; retain them where needed. The reducer uses `type`, `session_id`, `payload`, `seq`. Replay entries from `session.events.since.events` are normally **params dictionaries**, not full envelopes; the client accepts either shape and sorts replay by `seq`.

The following is the **consumer payload contract**, not a claim that Hermes supplies every optional field. `?` means optional. Most core message/tool payloads are decoded tolerantly. Typed auxiliary decoders listed as “exact” reject additional payload keys; malformed optional events are ignored rather than becoming invented content.

| Event | Payload read by the client | Reduction |
|---|---|---|
| `gateway.ready` | `replay_epoch?`, capability fields handled by connection setup | Announces a usable physical socket. Synchronously close retained chat admission until per-runtime catch-up finishes; an epoch alone is not session coverage. |
| `message.start` | No required payload fields | Start a native turn identified locally by epoch and sequence. Reset text/reasoning segment state and current-turn todo baseline. Do not invent a human row for a turn another surface started. |
| `message.delta` | `text?:string` | Append to cumulative current-segment text; upsert one stable assistant row, mark running. Nonempty text seals active reasoning. |
| `message.interim` | `text?:string` | Seal a complete assistant segment; use supplied interim text as that segment, clear cumulative text, advance segment. Still inside the same turn. |
| `message.complete` | `text?`, `reasoning?`, `status?`, `error?`, `failure_reason?`, `error_surface?`, `billing?`, `response_reused?`, `response_previewed?`, `usage?`, `persisted_turn?` | Finalize/replace the current assistant segment; final text replaces accumulated deltas. Does **not** normally end the turn. With reused/previewed final and no open segment, settle the already sealed matching final instead of duplicating it. |
| `reasoning.delta` | `text?:string`; optional common activity metadata | Append model reasoning to the current reasoning phase. After a sealed phase, a new delta creates a new phase. |
| `reasoning.available` | Ignored by this reducer | Hermes' assistant-body progress preview is not authoritative model reasoning. Do not create a reasoning row from it. |
| `thinking.delta` | `text:string`, `rendered?:string\|null`, `verbose?:boolean\|null`; no other keys | Spinner/status text only. Do not append reasoning or assistant transcript rows. Current visible spinner text uses at most 256 characters. |
| `tool.generating` | Exactly `{name:string}` | Status preannouncement only: no `tool_id` exists to join it to a later call. |
| `tool.start`, `tool.progress`, `tool.complete` | `tool_id:string` required/nonempty; `name?`, `context?`, `summary?`, `args?`, `result?`, `status?`, `duration_s?` or `duration_seconds?` | Upsert activity by turn and tool ID; preserve original arguments/result as string or JSON. Start seals reasoning. Complete maps explicit failed/error and cancelled/interrupted statuses; otherwise a real tool-complete event is success. |
| `subagent.*` | `subagent_id?`, `child_session_id?`, `parent_id?`, `goal?`, `text?`, `summary?`, `tool_preview?`, `status?`, `model?`, `tool_count?`, `started_at?` | Require a real subagent ID or child session coordinate. Thinking/text append; complete settles child activity. Refreshing optional roster must not overwrite a newer event. |
| `session.info` | `running?:boolean`, `stored_session_id?`, `model?`, `reasoning_effort?`, `service_tier?`, `title?`, `usage?` | `running:false` after running is the normal turn terminal. Adopt verified stored-tip updates and metadata. Settle orphan running ordinary tools as **recorded**, not guessed successes; subagents retain their own lifecycle. |
| `session.title` | `title:string` | Rename presentation. |
| `session.usage` | `usage?:object` | Update valid context/usage values; absence does not erase the last valid snapshot. |
| `error` | Host diagnostic payload | Mark the current turn failed in client state. The following lifecycle, rather than an arbitrary diagnostic alone, owns normal turn settlement. |
| `background.complete`, `btw.complete` | `task_id:string`, `text:string`, `question?:string\|null`; no other keys | Match exact task identity and task kind; settle side-task activity and show its reply independently of the main turn. Does not end the main turn. |
| `review.summary` | Exactly `{text:string}` | Retain a background-review activity. |
| `notice` | Exactly `{message:string}` | Retain a neutral recorded notice. |
| `status.update` | Exactly `{kind:string,text:string}` | Status only. `compressing`, `compacting`, `compacted` drive confirmed compaction presentation. Do not infer progress percentages. |
| `tool.output_risk` | Exactly `{tool_id:string,name:string,risk:string,findings:[string],redacted:boolean}` | Safety-warning activity; at most 1,024 findings. Preserve host redaction fact. |
| `message.reaction` | Exactly `{row_id:nonnegative integer,role:string,reactions:[{emoji,author,at?,seen?}]}` | Replace reactions for that exact physical row. Author is `user` or `agent`; emoji nonempty; `at` numeric/null, `seen` Boolean/null; at most 1,024 reactions. |
| `reaction` | Exactly `{kind:string}` | Agent affection reaction; separate from row tapbacks. |
| `session.control.update` | Exactly `{control:<control snapshot>}` | Replace valid goal/loop/heartbeat control snapshot. |
| `todo.updated` | Canonical native todo state (below) | Update current native todo snapshot with epoch/turn/sequence authority. |
| `session.reclaimed` | Exactly `{session_id:string,stored_session_id:string,reason:string}` | May be global (`params.session_id` absent). Revoke only when **both payload IDs** match this client, and an outer session ID, if present, also matches runtime. |
| `request.cancel` | Exactly interpreted cancellation fields `{id:string,method:string,reason:string}` | Retire the matching pending server request by exact wire ID **and** method, including a queued response that has not begun writing. See prompts below. |
| Legacy `approval.request`, `clarify.request`, `clarify.expire`, `secret.request`, `sudo.request`, `mcp.setup.request` and secure `*.expire` | See prompt sections | Compatibility requests, not assistant transcript messages. Negotiate approval/clarify origin before making cards actionable. |

Failure final example (advisory error fields are tolerant):

```json
{"type":"message.complete","session_id":"runtime-b","seq":30,"payload":{
  "status":"error","text":"The provider is busy.","failure_reason":"overloaded",
  "error_surface":{"layer":"provider","code":"overloaded","retryable":true,"provider_label":"Example Provider"}
}}
```

`status:"error"` creates a known turn failure. If the runtime was not running, this failed final can be its own failed-before-start terminal; it must not attach to the previous turn. `error_surface` can contain layer/code/retryable/provider label/reset epoch seconds; `billing` can contain provider label and HTTPS billing URL. Unknown or malformed advisory fields count as absent. The user, rather than the transport, decides whether to retry a reported failed turn.

Valid usage requires nonnegative `context_used` and positive `context_max`, bounded to 10^12. Optional counters are `compressions`, `prompt`, `output`, `cached`, `total`; `model` is optional.

Canonical todo state, used by `todo.updated` and activation's `todo_state`, has this shape:

```json
{"revision":2,"todos":[{"id":"task-a","content":"Inspect the project","status":"in_progress"}]}
```

`revision` is a nonnegative integer; status is `pending`, `in_progress`, `completed` or `cancelled`. A full snapshot has at most 256 unique tasks. IDs have no leading/trailing whitespace; content is nonempty, at most 4,000 characters and permits tab/newline but no other controls. `todos:[]` with revision at least 1 is an authoritative clear; an unused empty revision 0 read is unknown. Native epoch/generation/turn sequence outrank unsequenced cached state; a new turn can restart revision numbers. Todo extraction also recognizes direct `todo`/`todo_list`, or a single nested call through `tool_call`; an unsupported newer result must not resurrect an older todo list. See [todo snapshot parser](../../Bighelp/Chat/SessionStatusModels.swift) and [todo authority reduction](../../Bighelp/DirectHermes/DirectHermesProjection.swift).

Sources: [wire/event codec](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift), [typed payloads and reducer](../../Bighelp/DirectHermes/DirectHermesProjection.swift), [client event routing](../../Bighelp/DirectHermes/DirectHermesConversationClient+Events.swift), [usage/reaction projection](../../Bighelp/DirectHermes/DirectHermesConversationClient+Projection.swift), [failure parser](../../Bighelp/Chat/ChatTurnFailure.swift). [Conversation tests](../../BighelpTests/DirectHermesConversationTests.swift) cover segment finals, reused answers, reasoning phases, spinner text, tools, todo revisions and stored-session reactions.

### Reducer ordering and terminal rules

Use a single serialized reducer per retained chat. The current implementation's important order is:

1. Handle exact-owner `session.reclaimed` first, before admitting any same-run mutation. Revoke connection generation, cancel in-flight helpers and release hydration/background waiters; retain uncertainty and visible content.
2. Otherwise require connected state and exact runtime `session_id`. The sole special route is `message.reaction` addressed to the exact stored session: apply it without touching the runtime cursor.
3. While hydrating, hold runtime events in arrival order (current cap 16,384). Do not expose them to the live reducer before recovered coverage is proved.
4. For a sequenced event, ignore `seq <= lastSequence`; otherwise advance cursor before projecting. The ordinary live reducer does not itself reject every sequence jump; recovery and held-event gates establish contiguous coverage. A port should not weaken those gates.
5. Update typed projection, liveness, prompt compatibility, turn identity and metadata; publish assistant row upserts, then activities/todos/controls/subagents. Message and activity ordering share a monotonic local `sourceOrder` assigned on first insertion and retained by upserts.
6. Settle the pending send only after both definite admission and its owned terminal lifecycle are observed. A `message.complete` is normally a segment final. Hermes' `session.info.running:false` is the finally-bookend after goal/loop evaluation.
7. Use live `message.complete.persisted_turn.user_row_id` and `final_assistant_row_id` to bind optimistic rows to durable IDs. Do not guess the match from repeated text.
8. Schedule media/reaction/optional roster reads after critical text/lifecycle reduction. Replayed activity must not trigger fresh live notifications, live elapsed timers or duplicate rows.

Live turn IDs in the Swift reducer are derived from `epoch:message.start.seq`; assistant segment IDs incorporate stored coordinate, turn, segment and first event key. These are display identities, not host admission IDs. Preserve arrival order across messages, reasoning and tools; do not sort by wall clock or text. Final timestamps/durations can enrich an existing row without changing its order. Monotonic time measured from an actually observed live start can supply elapsed duration; replay must not fabricate a duration for missed time.

## 8. Approval and clarification server requests

Modern requests arrive as actual JSON-RPC requests and require a response with the original string ID:

```json
{"jsonrpc":"2.0","id":"server-approval-a","method":"approval","params":{
  "session_id":"runtime-b","request_id":"approval-domain-a",
  "command":"git status","description":"Inspect the working tree",
  "tool_name":"terminal","choices":["once","session","always","deny"]
}}
```

```json
{"jsonrpc":"2.0","id":"server-approval-a","result":{"choice":"once","all":false}}
```

The response has no `method`/`params` and is **not** a new `approval.respond` request. Keep wire ID and domain `request_id` distinct. Bind a request to transport generation, exact host/principal, runtime, profile and visible conversation before exposing it as actionable. Rebinding or retiring a connection invalidates old cards and handlers. Do not persist old socket responses for automatic replay.

Approval requires nonempty runtime and domain request IDs (each at most 4,096 UTF-8 bytes), and 1–16 choices. The understood choices are `once`, `session`, `always`, `deny`; keep only those offered, deduplicate them, skip unknown choices, and reject a request with no understood choices. `command` and `description` are optional strings up to 65,536 bytes; `tool_name` and `gateway_session_id` are optional strings up to 4,096 bytes. Optional `allow_permanent`, `allow_session`, `smart_denied` must be Boolean if supplied. Unknown future fields do not invalidate this decoder. Authorize only the selected offered scope. Current UI responses always use `all:false`. Cancel is `{choice:"deny",all:false}`.

Single clarification:

```json
{"jsonrpc":"2.0","id":"server-question-a","method":"clarify","params":{
  "session_id":"runtime-b","question":"Which environment?","choices":["Test","Production"],"multi_select":false
}}
```

```json
{"jsonrpc":"2.0","id":"server-question-a","result":{"answer":"Test"}}
```

Batch clarification:

```json
{"jsonrpc":"2.0","id":"server-question-b","method":"clarify","params":{
  "session_id":"runtime-b",
  "questions":[
    {"qid":"environment","question":"Which environment?","choices":["Test","Production"]},
    {"qid":"checks","question":"Which checks?","choices":["Unit","UI"],"multi_select":true}
  ],
  "answers":{"environment":"Test"}
}}
```

```json
{"jsonrpc":"2.0","id":"server-question-b","result":{"answers":{"environment":"Test","checks":"[\"Unit\",\"UI\"]"}}}
```

| Clarify rule | Client behavior |
|---|---|
| Shape | Exactly one non-null `question` or `questions` must exist. Ignore unknown fields; optional null `choices`/`multi_select` mean absent. Single request cannot contain non-null `answers`. |
| Question text | Nonempty, no NUL, at most 65,536 UTF-8 bytes. |
| Batch | 1–10 questions, each with unique nonempty `qid` up to 4,096 bytes. Current decoder also rejects Swift-equivalent duplicate QIDs, so a portable producer should use simple distinct IDs. |
| Choices | Optional/null or array with at most 12 nonempty distinct exact-byte strings, each at most 10,000 bytes and no NUL. |
| Multi-select | Boolean; requires nonempty choices when true. The answer remains a **string containing JSON array text**, not a JSON array at result level. |
| Existing `answers` | Batch only, object of at most five locked QID/string answers; all keys must name batch questions. Return locked values unchanged in the single modern batch response. |
| Answer | Nonempty, no NUL, at most 10,000 bytes. Plain free text is accepted, including typed “Other”. For JSON-array multi-select text: nonempty unique strings, selected choices plus at most one custom string, no more than choice count + 1. |
| Cancel | Modern clarification returns `{}`. Do not send blank text as a new chat turn. |

Local answer drafts can survive closing/reopening a question sheet only while the exact request remains pending. Once expired/cancelled/rebound, the same text must not answer a different request.

Sources: [prompt store, validation and results](../../Bighelp/DirectHermes/DirectHermesPrompt.swift), [scope choices](../../Bighelp/Approvals/ApprovalModels.swift), [prompt-store tests](../../BighelpTests/DirectHermesPromptStoreTests.swift).

### Cancellation, duplicate requests and unsupported methods

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","payload":{"id":"server-question-a","method":"clarify","reason":"expired"}}}
```

All three cancellation fields are required strings, with no other payload keys. Wire request IDs have a 1,024-byte limit (the wire layer allows an empty string, while actionable prompt decoders can require nonempty). Method names are nonempty printable ASCII up to 256 bytes; cancellation reasons are bounded to 4,096 bytes. Match exact request ID bytes **and** method; a cancellation naming `clarify` must not retire an `approval` with the same ID. A completed handler can have a queued response while the writer is busy; cancellation is still effective until response writing begins. Once cancelled, no late UI action or staged response may write it. Current transport capacity is 64 open server requests; duplicates do not create another card/response and capacity overflow is ignored without growing state.

Malformed actionable prompt parameters return JSON-RPC error `-32602`. Retired handlers return `-32000`; transport retirement prevents stale results being written. Unknown well-formed server-request methods decode successfully and receive `-32601` from the unregistered-method path. The parity catalog includes `approval`, `clarify`, `mcp.setup`, `preview.act`, `preview.read`, `secret`, `sudo`, `terminal.read`, `tour`, `vault.code`, `vault.save_login`, `vault.unlock_prompt`, `window.read`; decoding a name is not implementation of its business operation.

Sources: [transport dispatch/write state](../../Bighelp/DirectHermes/DirectHermesNetworking.swift), [server-request codec/state](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift), [protocol-parity tests](../../BighelpTests/DirectHermesProtocolParityTests.swift).

### Legacy event compatibility

Choose approval/clarify mode from the **final** `session.events.since` recovery result:

| Observation | Mode |
|---|---|
| `open_requests` exists and is an array, including `[]` | Modern server requests. Restore through the ordinary server-request dispatcher. Do not duplicate `approval.request`/`clarify.request` compatibility events as cards. |
| `open_requests` absent | Legacy events. Restore `pending_approval`/`pending_clarify` from activation, then apply post-snapshot legacy events. |
| `open_requests` exists with any other type | Invalid recovery; keep admission closed. |

Legacy `approval.request`/`clarify.request` payloads contain nonempty `request_id`; runtime comes from the event envelope. They otherwise share approval/clarify content validation. `clarify.expire {request_id}` expires only that clarification. Current client caps legacy approval/clarify cards at 64. A malformed optional live event is ignored; malformed authoritative recovery state fails recovery.

Legacy answers are **new client RPC requests**, once each:

| Method | Params and accepted result |
|---|---|
| `approval.respond` | `{session_id:<runtime>,profile,request_id:<legacy ID>,choice,all:false}` → nonnegative integer `resolved`; `>0` confirms resolution, `0` means expired. |
| `clarify.respond` single | `{session_id:<runtime>,profile,request_id,answer}` → `status:"ok"` or `"expired"`. |
| `clarify.respond` batch | Send one request per **unanswered** QID, in question order, adding `question_id`. Each `ok` response must provide `remaining:[qid,...]` exactly matching the remaining unanswered suffix; lock each confirmed answer locally before the next. Do not resend prefilled answers. |
| Legacy clarify cancel | Same method with `answer:""` and no QID; accept `ok`/`expired`. |
| `approval.received` | Only after the exact legacy approval card was actually presented in the foreground: `{session_id,profile,request_id}` → `acknowledged:true`. One attempt per card/socket; this starts its host-side timeout/receipt behavior, not approval. |

`4009` on a legacy response is expired. A lost/malformed response sets recovery required and retains uncertainty; no automatic answer resend or conversion into a new chat message. Confirmed Stop clears legacy approval/clarify prompts; an unconfirmed Stop does not. Suspension removes legacy authority until recovery chooses the mode again.

Sources: [legacy prompt adapter](../../Bighelp/DirectHermes/DirectHermesConversationClient+Prompts.swift), [presentation acknowledgment](../../Bighelp/DirectHermes/DirectHermesWorkspaceStore.swift), [legacy tests](../../BighelpTests/DirectHermesLegacyPromptTests.swift).

## 9. Secure input, sudo, vault and MCP prompts

Secure requests are attended, non-transcript UI. The secret value belongs only to the mounted secure input control and one response operation. Never place it in a message row, draft journal, notification, log, analytics property or automatic retry queue. Clear mounted sensitive state before sending and when the prompt changes/disappears. A transport-unknown response is not permission to submit that value again.

```json
{"jsonrpc":"2.0","id":"secure-a","method":"secret","params":{
  "session_id":"runtime-b","env_var":"EXAMPLE_API_KEY","prompt":"Enter the key for this connection",
  "metadata":{"source":"agent","label":"Service API key"}
}}
```

```json
{"jsonrpc":"2.0","id":"secure-a","result":{"value":"example-value"}}
```

The current secure decoder requires a preexisting exact runtime binding, a nonempty wire ID/runtime ID of at most 4,096 bytes and no identifier control characters. It is stricter about unknown parameter keys than approval/clarify:

| Server-request method | Accepted params beyond `session_id` | Result value |
|---|---|---|
| `secret` | Required `env_var` nonempty ≤4,096 bytes, required `prompt` string ≤65,536 bytes; optional null/object `metadata`; no other keys. `metadata.source:"agent"` and trimmed `label` ≤120 bytes affect presentation only. | `{value:<nonempty secret string>}`; local input limit 65,536 bytes, no NUL. |
| `sudo` | Exactly `session_id`; no other keys | `{value:<password string>}`. It is not `{password:...}` for a modern server response. |
| `vault.code` | Optional `site` ≤255 bytes and `hint` ≤500 bytes, each bounded single-line text/null; no other keys | `{value:<code>}`. Current UI strips whitespace/hyphens and allows 1–64 ASCII letters/numbers. |
| `vault.save_login` | Exactly `session_id`, `origin`, `site`. `origin` is HTTP(S), has host, no URL credentials, ≤2,048 bytes and no whitespace/control characters; optional/null site label ≤255 bytes. | `{value:"{\"identifier\":\"...\",\"password\":\"...\"}"}`: the value is JSON object **text**, with trimmed nonempty identifier ≤512 bytes and password ≤4,096 bytes, no NUL. Show the origin as authority. |
| `vault.unlock_prompt` | Exactly `session_id`, `backend`, `display_name`. Backend nonempty ≤64 bytes; optional/null single-line name ≤120 bytes. | `{value:<master password string>}` with the ordinary secure-value limit. |
| `mcp.setup` | `server` required nonempty ≤160 bytes; optional `action` `install`/`enable`/`authorize` (absent/null defaults to `install`), optional null/string `reason` ≤65,536 bytes; no other keys | `{value:<JSON outcome text>}` after the separate MCP management operation, such as status/server/tools/detail. This is an attended setup flow, not a blanket approval or secret write. |

Cancel secret/sudo/vault prompts with `{value:""}`. Cancel MCP with a JSON-text outcome of status `declined`. Modern errors use `-32602` for invalid secure params and `-32000` for retired requests. Current secure store capacity is 64. Unbound or unsupported secure requests never become actionable.

Older hosts can emit `secret.request`, `sudo.request`, `mcp.setup.request` and exact matching `secret.expire`, `sudo.expire`, `mcp.setup.expire`. Payload contains `request_id`, runtime comes from the envelope. Legacy vault events are deliberately unsupported. Modern and legacy secure responses differ:

| Legacy response RPC | Params |
|---|---|
| `secret.respond` | `{request_id:<wire ID>,value:<string>}` |
| `sudo.respond` | `{request_id:<wire ID>,password:<string>}` |
| `mcp.setup.respond` | `{request_id:<wire ID>,result:<JSON outcome text>}` |

These legacy secure params currently contain no `session_id`/`profile`; binding is proved locally before dispatch. Dispatch once, lock the entry while in flight, and retire it on success, expiry or unknown transport outcome. Do not persist/replay secure bytes. Ordinary `request.cancel` also retires secure prompts by generation/ID/method.

MCP install/enable/authorization uses the existing MCP management client, requests only the exact server/required environment, optionally reloads that live runtime after success, and reports uncertainty without repeating setup. Cancelling an in-progress OAuth flow is one attempt. Do not infer from the prompt that a broader MCP/environment mutation has already been authorized.

Sources: [secure prompt store, validation and UI clearing](../../Bighelp/DirectHermes/DirectHermesSecurePrompt.swift), [handler registration](../../Bighelp/DirectHermes/DirectHermesWorkspaceStore.swift), [secure tests](../../BighelpTests/DirectHermesSecurePromptTests.swift), [prompt parity tests](../../BighelpTests/DirectHermesProtocolParityTests.swift).

## 10. Recovery and reconnect without replaying mutations

The transport's `gateway.ready` is not enough to reopen Send. It must synchronously gate each retained stream before another event in the same decoded batch arrives. Workspace recovery owns durable reattachment; the conversation client's `recover` operates only on an already owned runtime and never hides a resume, second writer or prompt retry.

`session.events.since` request:

```json
{"jsonrpc":"2.0","id":"events-1","method":"session.events.since","params":{"session_id":"runtime-b","last_seen":20}}
```

Representative result:

```json
{"jsonrpc":"2.0","id":"events-1","result":{
  "epoch":"host-epoch-a","latest_seq":22,"truncated":false,
  "events":[
    {"type":"message.start","session_id":"runtime-b","seq":21,"payload":{}},
    {"type":"message.delta","session_id":"runtime-b","seq":22,"payload":{"text":"Hello"}}
  ],
  "open_requests":[
    {"id":"server-question-a","method":"clarify","params":{"session_id":"runtime-b","question":"Continue?"}}
  ]
}}
```

`latest_seq` is a per-session cursor; the event list can be empty or incomplete when the replay ring is truncated. Every open-request row must contain exactly `id`, `method`, `params`; `params.session_id` must match this runtime, and capacity/ID/method limits must validate before restoring any entry. Unknown supported-shape methods still go through the ordinary unsupported-handler response path.

Hermes snapshots and replay use different locks. Do not pretend an activation snapshot and one cursor are atomic. Current recovery brackets the activation:

```text
capture connection owner; close admission; hide actionable prompt mode
checkpoint = retained last sequence
before = events.since(runtime, last_seen = same supplied epoch ? checkpoint : 0)
validate before.epoch and before.latest_seq
snapshot = session.activate(runtime, profile, omit_messages=true for REST-backed chat)
validate exact runtime and durable aliases, Boolean running
after = events.since(runtime, last_seen=before.latest_seq)
require after.epoch == before.epoch; validate after.latest_seq
select prompt mode from after.open_requests
validate/restore final open_requests and pending connection card before publishing snapshot
choose replay strategy below
replay all held live events only if they extend accepted cursor contiguously
open admission only for the same owner and successful coverage
```

Recovery strategies:

| Case | Reconciliation |
|---|---|
| Same epoch, retained checkpoint >0, both replay results explicitly `truncated:false` | Exact replay: retain rich live rows, apply pre-snapshot events then validated todo baseline then tail events through the ordinary reducer. If tail has no start/delta/running transition, activation is the newest liveness observation. Reconcile saved history after confirmed idle. |
| Fresh non-catalog client, checkpoint 0, no live state/unresolved intents, snapshot running, complete current-turn replay | Bootstrap only the history preceding the live turn, then replay the complete current-turn typed events. Use timestamp/ordered-role boundary rather than equal prompt text. Preserve accepted queue/correction source metadata without inventing submissions. |
| Epoch changed, ring truncated, no retained cursor or incomplete live replay | Keep existing rich visible rows. Adopt native snapshot as source detail (`inflight`, queue and boundary events), not cumulative delta text. Do not append an unknown overlap twice. Replay only relevant boundary lifecycle events, then seed accepted latest cursor. |
| Catalog-backed chat had a partial reply that ended while away, without exact replay | Fetch fresh canonical saved history after recovery and replace the partial display with that finished source. A cumulative inflight dump cannot prove its final text. |

Held-event coverage is explicit: every held event must have `seq`; discard sequences already consumed, sort the remainder and require `checkpoint+1, checkpoint+2, ...` with no gaps or duplicate new sequence. Buffer overflow or a gap keeps admission closed and retains the buffer for durable catch-up. A failed explicit reread on an unchanged live socket can preserve transport readiness only if all observed held events are still covered. A first-load/reconnect recovery failure suspends the stream.

After valid recovery, uncertainty records remain as described above. An idle snapshot cannot settle a lost ACK. Known already-admitted submission evidence can settle on exact matching terminal replay, but not by text matching. A side-task result missed without exact replay cannot be reconstructed by this waiter; release it with an error rather than inventing an answer. Optional roster and reaction hydration occur after the critical gate and cannot hold incoming text.

On `session.reclaimed`, revoke first; the server has retired that writer. On socket disconnect, suspend all retained chats, retire old prompt bindings, release hydration waiters and rotate generation. On reconnect, reannounce server requests, use the stored session to resume if needed, adopt the proved returned runtime/stored coordinates, reset runtime checkpoint if runtime changed, then recover. Do not run `session.create` as a reconnection fallback.

Hermes can reap disconnected app runtimes; repository guidance records a 20-second orphan-reap behavior and plugin `durable_sessions.py` support for retaining `bighelp` sessions. Those host/plugin lifetime details are not a replacement for durable reattachment. Returning to a chat reads host-saved history as truth after a turn ends.

Sources: [recovery algorithm](../../Bighelp/DirectHermes/DirectHermesConversationClient+Recovery.swift), [held events and reclaim](../../Bighelp/DirectHermes/DirectHermesConversationClient+Events.swift), [workspace recovery ownership](../../Bighelp/DirectHermes/NativeWorkspaceSessionBridge+Recovery.swift), [open request restoration](../../Bighelp/DirectHermes/DirectHermesNetworking.swift), [connection continuity guidance](../../AGENTS.md). Tests: [reconnect parity](../../BighelpTests/DirectHermesReconnectParityTests.swift), [conversation recovery](../../BighelpTests/DirectHermesConversationTests.swift), [workspace reconnect policy](../../BighelpTests/WorkspaceReconnectPolicyTests.swift), [reopen replay](../../BighelpTests/SessionReopenReplayTests.swift).

## 11. Canonical history and paging

Use REST history for catalog-backed chats. `session.activate`/`session.history` expose a lossy runtime display projection; it is not interchangeable with physical stored rows. Keep active rich live rows when a stale cached history seed arrives. A consumed event cursor belongs to those rows; replacing them with an older page loses deltas that exact replay will correctly not send again.

```http
GET /api/sessions/saved-b/messages?profile=research&limit=40&offset=0&order=latest&include_compacted=true
```

Representative response (rows are already in display chronology):

```json
{
  "session_id":"saved-b","profile":"research",
  "messages":[
    {"id":101,"session_id":"saved-b","role":"user","content":"Hello","timestamp":1792000000.0},
    {"id":102,"session_id":"saved-b","role":"assistant","content":"Hi","reasoning_content":"...","timestamp":1792000001.0,"turn_duration_ms":1200}
  ],
  "pagination":{"offset":0,"limit":40,"order":"latest","returned":2}
}
```

`data` is accepted as an alias for `messages`. Required pagination fields must exactly echo requested `offset`, `limit`, `order`, and `returned` must equal array length; rows cannot exceed the requested limit. Returned `session_id` can resolve a compaction successor and is adopted only through validated rebinding. A supplied `profile` must match. Each row must have exact returned `session_id`, positive integer `id` ≤2^53−1 and a valid role string. Duplicate physical row IDs invalidate a page/projection.

| Stored row fields | Interpretation |
|---|---|
| `content` | Preserve raw JSON. String renders verbatim; null is empty. Array supports `{type:"text"\|"input_text"\|"output_text",text:string}` parts joined with newline. Other parts remain raw and mark unsupported non-text content; do not fabricate attachments. |
| `display_content` | Optional display override; use for rendered text while retaining physical `content`. |
| `display_kind` | `hidden` / `internal_notification` do not render. `model_switch` renders as system metadata even if its physical role is `user`. Do not recognize model switches from marker-like text alone. |
| `reasoning_content`, `reasoning` | First present non-null of those keys, as string. Recorded reasoning activity, not a running or proven successful phase. |
| `tool_calls` | Absent/null/empty string or array ≤128 of `{id?,function:{name?,arguments?}}`. Preserve argument string verbatim, or encode actual JSON without inventing arguments. |
| `tool_call_id`, `tool_name` | Tool-result coordinates. Join only an exactly unique request ID to exactly one result ID in the retained window. Missing/duplicate IDs remain separate recorded evidence. |
| `timestamp` | Display metadata only; preserve server row order. If present/non-null, it must be finite numeric epoch seconds in 0–253,402,300,799. |
| `turn_duration_ms` | Optional integer 0–86,400,000; malformed values are ignored without hiding the row. |
| `platform_message_id` | Optional physical external-platform coordinate, retained separately from app IDs. |
| `display_metadata` | Saved reactions and optional `reply_expected` used by silent-reply presentation. Bad reactions do not block the transcript. |

History body/argument text is bounded at 1 MiB, but retains invisible Unicode formatting and terminal control text as inert display data. Do not apply protocol identifier validation to transcript bodies. Render unknown roles as retained evidence rather than fabricated human/assistant replies. The typed projection records unsupported-content row IDs.

History messages use stable app-scoped physical-row IDs. Every source row receives `sourceOrderBase + original index`; tool requests/results and reasoning remain in that order even through compaction. Tool activities join to the nearest preceding visible ordinary user row for turn grouping. Unambiguous tool results remain neutral **recorded** activity: history alone does not attest success/failure and must not drive a running Live Activity or voice final answer.

Silent reply marker handling follows the real prompt/display kind and host metadata: scheduled/webhook/internal or reaction-only turns can remain quiet; an ordinary person's message answered only with a marker can show the product's “no written reply” notice. Preserve raw rows regardless. See [silent reply rules](../../Bighelp/Chat/ChatSilentReply.swift) and [user display text](../../Bighelp/Hermes/HermesUserMessageDisplay.swift).

### Paging policies

These are **client policies** over offset paging; the REST API does not provide snapshot isolation.

| Read | Current algorithm |
|---|---|
| Full hydration | First request `order:oldest,offset:0,limit:200`; next `offset=accumulatedCount−1,limit:201`. The first returned row must exactly equal the previous last row (including raw JSON), then discard the overlap. Require one stored ID for the read, no duplicate new row IDs and positive progress. Stop on a short page. |
| First/latest page | Accept `turnLimit` 1–10; request `rowLimit=min(400,turnLimit×40)`, `order:latest,offset:0`. “Turn limit” is a fetch-size heuristic, not a host guarantee of exactly that many turns. A full page yields next offset equal to retained row count. |
| Older page | Require the current retained next offset; request `offset−1,limit:rowLimit+1,order:latest`. The last returned row must equal the retained oldest row byte-for-byte as canonical JSON. Drop it and prepend older rows. Require no duplicate IDs. |
| Latest refresh | If the newest page begins inside the retained window, the existing tail IDs align with the new prefix and the boundary row is unchanged, retain earlier held pages and replace the tail. Otherwise start a fresh window. |
| Reconnect cache adoption | Reuse windows only for the same exact sign-in and an empty replacement history cache. The cache supplies display, not runtime ownership. |

Current capacities: 50,000 history rows, 32 MiB raw encoded history per retained read, at most four cached windows and 64 MiB across windows. Eviction makes an old paging offset invalid. Check owner, hydration token and stored identity after every page and again before publishing. Detected shifted windows/rewrites require a fresh reconciliation; do not combine inconsistent pages. Boundary overlaps catch some concurrent changes, not every possible race.

Sources: [REST route](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift), [paging, projection, cache adoption](../../Bighelp/Hermes/DirectHermesSessionCatalogClient.swift), [row parser and tool pairing](../../Bighelp/Hermes/DirectHermesHistoryProjection.swift), [history bounds](../../Bighelp/Hermes/DirectHermesSessionModels.swift), [history tests](../../BighelpTests/DirectHermesHistoryProjectionTests.swift), [native history coverage](../../BighelpTests/NativeHistoryCoverageTests.swift).

### Catalog and Bot Chat notes

List saved chats through `GET /api/sessions` with explicit profile, bounded limit/offset and archive/source policy. Current catalog pages use limit 100, `archived=include`, `order=created` by default, then hide deliberately archived rows while keeping auto-archived ones. Default excluded sources are `tool`, `kanban`, `bot_room`. `total`/`has_more` drive continuation; older pinned-row expansion means row count alone is not reliable. Preview is metadata, never a fabricated transcript message. REST recent activity is not proof of an active turn.

Hidden canonical Bot Chats are absent from the normal list. Ask `profiles.list` for sessions (`include_sessions:true` / its host default) and merge `canonical_session`/canonical Bot Chat identities so a refresh cannot drop them. Keep catalog row ID, `_lineage_root_id`, `_lineage_ids`, canonical registry anchor and resolved transcript tip distinct. Compaction can update the tip while route/draft identity stays stable.

More catalog and metadata detail: [Direct Hermes sessions](../DIRECT_HERMES_SESSIONS.md). Older narrative statements there about creation/fork availability can lag implementation; the current source and contract tests are authoritative for request shapes.

## 12. Runtime controls relevant to chat

All mutations use a current proved runtime and exact owner. Do not omit `session_id` where a missing session would change profile defaults. Readback is evidence; a successful-looking mutation reply alone is not enough where the adapter requires proof.

| Operation | Wire shape and validation |
|---|---|
| Model list | `model.options {profile,session_id}`; current app caches profile catalog for 60 seconds but always obtains current live proof for selection. A draft picker can list without waiting for reattachment; applying a choice requires the exact live coordinate. |
| Session model | `config.set {profile,session_id,key:"model",value:"<model> --provider <provider> --session",confirm_expensive_model?:true}`. Require reply key/model/scope, Boolean `confirm_required`; defer/confirmation means not yet confirmed changed. Fresh activation proof must show model and provider, or a fresh catalog must prove the selected alias is current. Preserve prior reasoning after a model switch. |
| Reasoning | `config.set {profile,session_id,key:"reasoning",value:<level>,scope:"session"}`, then `config.get` same key to verify. Allowed values: `none,minimal,low,medium,high,xhigh,max,ultra` (empty live value means Auto). |
| Fast mode | `config.set {profile,session_id,key:"fast",value:"fast"\|"normal",scope:"session"}`, then get to verify. Available only for a supported provider/model and idle runtime. Creation's `fast` uses Boolean; runtime config uses string. Read aliases `on`/`priority` normalize to `fast`, and `off`/empty normalize to `normal`; preserve newer unknown modes as host-set rather than showing Off. |
| YOLO | `config.set {profile,session_id,key:"yolo",value:"on"\|"off",scope:"session"}`; reply value `"1"`/`"0"` confirms. Can target a new live draft before first persistence. |
| Compact | `session.compress {session_id,profile,focus_topic?}`. Advanced facade requires idle; chat compact tracks host progress and receipt `compressed`/`pending`, `removed`, before/after token/message counts. Timeout can leave host compaction running. Do not retry automatically. |
| Status / usage / context | `session.status`, `session.usage`, `session.context_breakdown` with runtime/profile. Read-only metadata. |
| Goal/loop/heartbeat read | `session.control.read` → exactly `{control:{goal:object\|null,loop:object\|null,heartbeat:object\|null,revision:string,updated_at:number}}`. |
| Goal/loop/heartbeat action | `session.control {session_id,profile,action,args?}` → exactly `{control,dispatch}`. Actions include `goal.pause/resume/clear/unwait`, `loop.pause/resume/stop`, subgoal add/remove/clear and heartbeat pause/resume/clear. A `dispatch.type:"send"` with `message` requires a separate one-time `prompt.submit(queued:true)`; control itself has not admitted that continuation. Report accepted/rejected/unknown separately; never repeat the control on a lost continuation receipt. |
| Undo / save / CWD | `session.undo`, `session.save`, `session.cwd.set {cwd}` are idle-gated in the advanced facade and followed by status/history readback where relevant. Replacing CWD must echo the exact requested path. |
| Subagent controls | `subagent.list {session_id}`, `subagent.tail`/`subagent.interrupt {session_id,subagent_id}`, `subagent.steer` adds `text`; gate actual advertised capabilities and exact parent runtime. |

Sources: [runtime control adapter](../../Bighelp/DirectHermes/DirectHermesSessionControlClient.swift), [session actions and typed result decoders](../../Bighelp/DirectHermes/DirectHermesSessionActions.swift), [goal rail conversion](../../Bighelp/DirectHermes/DirectHermesGoalControl.swift), [subagent client](../../Bighelp/DirectHermes/DirectHermesConversationClient+Subagents.swift), [runtime-control tests](../../BighelpTests/DirectHermesSessionControlClientTests.swift), [goal tests](../../BighelpTests/DirectHermesGoalControlTests.swift).

Workspace route allowlists and size fences are local policy, not schema discovery. [`DirectHermesWorkspaceClient`](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift) rejects unknown outbound operation fields. [`DirectHermesCoreRequestScope`](../../Bighelp/DirectHermes/DirectHermesCoreRequestScope.swift) checks owner/cancellation before/after requests, with 512 KiB encoded request and 2 MiB result bounds for adapters that use it. Direct conversation/action RPCs have their own paths and may accept fields (for example voice surface fields) not present in the finite workspace `promptSubmit` allowlist. A port should preserve the appropriate boundary instead of assuming all call sites share one field filter.

## 13. Group chats are a separate contract

Do not implement a group as a loop of ordinary `prompt.submit` calls. Hermes owns membership, task routing, durable room log, fencing, approvals and retry/discard semantics through `groups.*`. Negotiate `groups.capabilities`, then obey the features/methods and each `driver_status.pending_actions` entry actually returned.

There are two observed server paths with different capabilities: the older dashboard/`hermes serve` path and the gateway session path. In particular, seatable profiles, RoomLink, retry parameters, discard support and list cursors differ. A retry action with only `task_id` must not acquire guessed member/execution-generation fields; a session-path action that names them must return them exactly. Group approvals use `groups.approve` and host pending-action identity, not ordinary `approval` cards or persistent approval choices.

Detailed group wire/behavior references: [Hermes Bot Mode](../HERMES_BOT_MODE.md), [groups workspace routes](../../Bighelp/DirectHermes/DirectHermesWorkspaceClient.swift), [real-host fixture vectors](../../BighelpTests/Fixtures/HermesGroups), [RoomLink probe](../../Scripts/RoomLinkProbe.py). Group send retry can reuse a host-supported durable event ID; ordinary chat uncertainty has no equivalent submit nonce and must follow this document's no-replay rules.

## 14. Guarantees, limits and verification map

| Property | Evidence / limitation |
|---|---|
| Ordinary submit exactly once across an unknown ACK | **Not guaranteed.** Client avoids automatic replay; no durable submit operation ID is sent. Preserve uncertainty for review. |
| Create idempotency | Key is sent for the same persisted intent. Host retention/support is bounded; it is not indefinite deduplication. |
| Atomic snapshot and replay | **Not supplied by the consumed API.** Client brackets activation and preserves unknown overlaps as source detail. |
| Durable history paging snapshot | **Not supplied.** Overlap anchors detect observed window shifts; undetectable concurrent edits remain possible. |
| Complete multimodal history rendering | **Not implemented by text projection.** Preserve raw parts and unsupported-content indication; use explicit attachment/media routes for real bytes. |
| Prompt response receipt after socket loss | **Not proof of delivery.** Retire old authority and restore host-open requests, never replay stored responses/secrets. |
| Live tool outcome after only history/orphan idle | **Unknown.** Use recorded evidence, not success or running. |
| Side-task result after non-exact recovery | May be unavailable to a waiting caller; do not invent/re-run it. |
| Version-based feature selection | **Not used.** Capabilities and method-specific responses select supported behavior. |

Portable reducer/admission tests should reproduce the existing source-backed cases:

| Area | Existing evidence |
|---|---|
| Exact original IDs, duplicate/cancellable staged responses, cancellation method fence, malformed envelopes, documented method names | [DirectHermesProtocolParityTests](../../BighelpTests/DirectHermesProtocolParityTests.swift) |
| Durable resume mapping, conflicting aliases/profile rejection, exact-owner reclaim, waiter release, exclusive-submit Boolean | [DirectHermesReconnectParityTests](../../BighelpTests/DirectHermesReconnectParityTests.swift) |
| Streaming ACK remains pending, mid-turn steer, queue admission, segment-final vs turn-final, late ACK, lost receipt, interrupt-and-send ordering, unchanged journal, held-event gaps, finished-away reseed | [DirectHermesConversationTests](../../BighelpTests/DirectHermesConversationTests.swift) |
| Approval offered scopes, unknown choice tolerance, modern batch/locked answers, cancellation | [DirectHermesPromptStoreTests](../../BighelpTests/DirectHermesPromptStoreTests.swift) |
| Legacy snapshot/event mode, exact expiry, sequential batch answers, no unknown-answer replay | [DirectHermesLegacyPromptTests](../../BighelpTests/DirectHermesLegacyPromptTests.swift) |
| Secure cancel value, one-time agent secret/code/login/unlock, bound-runtime validation | [DirectHermesSecurePromptTests](../../BighelpTests/DirectHermesSecurePromptTests.swift) |
| Physical row IDs/server order, hidden/multimodal rows, exact tool pairing, neutral recorded outcome, duration/reactions, overlap paging/refresh | [DirectHermesHistoryProjectionTests](../../BighelpTests/DirectHermesHistoryProjectionTests.swift) |
| Model/provider/fast/reasoning readback and stale owner protection | [DirectHermesSessionControlClientTests](../../BighelpTests/DirectHermesSessionControlClientTests.swift) |

These unit/contract tests primarily use synthetic transports. They do not independently prove a particular deployed host/plugin's behavior. Real-host probes live under [Scripts](../../Scripts), including [protocol](../../Scripts/DirectHermesProtocolProbe.py), [streaming](../../Scripts/DirectHermesStreamingProbe.py) and [native workspace acceptance](../../Scripts/NativeWorkspaceAcceptanceProbe.py). Use disposable hosts and invented data as required by [AGENTS.md](../../AGENTS.md); do not run probes against a maintainer's real host without their permission.
