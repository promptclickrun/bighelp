# Direct Hermes sessions

> Current transport contract: [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md). Session creation, fork support and recovery have evolved since this narrative. Where transport details differ, use the versioned native contract and its source links.

`DirectHermesSessionCatalogClient` is a feature adapter over the shared,
owner-bound `WorkspaceOperationPerforming`. It owns no connection, credential,
agent loop, session database, ChatModel or canvas. The physical Direct adapter
maps its finite operations to native REST and TUI RPC.

## Identity and opening

App-visible IDs encode the exact authority cache scope, UTF-8 profile and
immutable native anchor using canonical base64url. They are not native request
coordinates. Native durable IDs and live runtime IDs remain separate in
`WorkspaceSessionCoordinate`. Compression can update the durable tip without
changing the app ID. Owner/profile comparisons retain exact UTF-8 identity.

`resolveCanonicalChat` uses the profile's `canonical_session.id`, never its
newest-session preview. It resumes that exact registry anchor with deferred,
omitted history. A known live runtime is activated without loading lossy RPC
message projections. Missing or rejected known canonical identity never creates
a replacement. An empty successful exact-title registry lookup returns
`notCreated`; this is not automatic creation permission.

Native lazy activation can omit the profile echo. The client accepts that only
for a previously verified exact live/durable pair, or after independently
checking the returned durable ID through profile-scoped REST metadata.

## Explicit creation and uncertainty

Production creation requires a throwing, durable `onCreationStateChange` sink.
Root composition owns its protected, authority-scoped storage. The client writes
state before dispatch and retains each native receipt before another mutation.
State can be restored for the same authority after connection replacement.

Ordinary New Chat creates a native lazy draft and returns the actual runtime and
durable identifiers. A selected folder comes only from the explicitly injected
host-folder provider; an active Project alone never supplies CWD. A returned CWD
that disagrees with that request is unconfirmed, not a successful selection.

First canonical birth is a separate, explicitly authorized action. It checks the
exact `Bot Chat` registry, creates only when no prior positive identity exists,
persists the title through `session.title`, requires `pending:false`, and reads
the registry back. A title-conflict winner is adopted from that registry.
No introductory prompt or other model call is submitted.

Native creation is neither atomic nor idempotent. An unknown create/title
outcome remains guarded; the client does not blindly retry it. A vanished
unpersisted draft may remain unresolvable without a separate human decision.
Creation receipts and the eventual canonical winner are retained as different
facts, rather than relabeling a losing draft.

## Catalog and history

The catalog pages each served profile's native REST sessions. Preview text is
metadata, not a fabricated transcript message. Native REST's recent-activity
heuristic is not promoted to running-agent evidence.

A full list asks for its pages and its chats' `projects.for_cwd` lookups ahead of
reading them, at most four at a time (`DirectHermesCatalogPrefetch`): every first
page at once, and the rest once a first page gives its `total`. The list still reads
each answer in the host's order, so its rows, its errors and where it stops are what
one request after another gave. An answer it never reads, such as a page past
`has_more` or the folder of a chat it skips, is dropped with its error. Taps from
notifications, widgets and Shortcuts wait for this list after the app returns (#535).

History requests use explicit profile, order, offset and bounded row limits.
`latest` responses are already chronological. Physical row IDs and timestamps
must not be used to reorder compaction projections. Complete hydration consumes
all pages within explicit app capacity bounds; incremental history overlaps a
known boundary row to detect shifted windows. Observed rewrites, mismatched
resolved IDs and inconsistent paging require reconciliation, not mixed history.
REST offers no snapshot-isolation guarantee, so undetectable concurrent edits
cannot be claimed impossible.

The typed projection retains raw native rows, physical content, display
overrides and multimodal parts. Unsupported non-text parts are reported, not
turned into guessed attachment IDs or paths. Tool calls/results join only on
exact unambiguous native call IDs. Their original content remains in activity
detail, never assistant final text. Unknown outcomes use the app-only
`recorded` lifecycle, which is neither running nor success and cannot drive
Live Activities. Legacy Link wire rejects that lifecycle.

In-memory history windows are bounded and disposable. Evicted or stale paging
coordinates require a fresh read. This is not a competing transcript authority.

Root must keep native recorded history in its versioned repository namespace,
separate from older writers that cannot decode that lifecycle. Shared repository
checkpoints prepare encoding and existing-file validation off the main actor,
then verify a one-use handle and exact file identity before atomic adoption.
Raw encoded bytes still require strict schema validation; account retirement or
file replacement invalidates prepared checkpoints.

## Flags, branching and verification

Catalog-row identity, compression lineage root and resolved transcript identity
are distinct. The native catalog's `_lineage_root_id` anchors ordinary app IDs;
its current row ID and `_lineage_ids` remain separate typed metadata. A history
read that follows a non-compression continuation does not retarget metadata
actions to that continuation.

Live title changes use the verified runtime; inactive title changes refresh and
target the native catalog row. Canonical Bot Chat is not renamed as an agent
display-name operation. Archive/hidden/pin/read setters use the known native
compression anchor (the canonical registry row for Bot Chat pinning). They are
not arbitrary ancestor or branch operations. Stored metadata readback verifies
returned flags where REST exposes them; `unread` uses the mutation
acknowledgement because detail does not expose an equivalent Boolean.

### Bot Chats are Hermes' own

Hermes delivers what other agents send (`message_agent`, peer DMs) into the session titled exactly "Bot Chat"
(`gateway/session_bot.py`). It takes over only its own native local chat (a `local-…` ID) or an older chat from
one of its own local surfaces (`cli`, `tui`, `gui`, `desktop`, `oneshot`, `tool`, `acp`). Any other "Bot Chat" is
moved aside: renamed `Bot Chat (<source> <id>)`, made visible, and replaced by a new one Hermes makes, without the
old context. A Bot Chat the app made over its socket (source `bighelp`) was such a chat, so the first message
another agent sent an agent replaced its Bot Chat.

- **Hermes makes it.** `createFirstCanonicalChat` (an agent's first Bot Chat, and the one after New Bot Chat) asks
  the plugin (`bot-chat/create`, `native-bot-chat-v1`), which has the agent's own Hermes gateway make it the way
  Hermes' delivery does. The creation's intent ID is the retry key, so a lost reply never makes two. A plugin
  without the route gets the socket's `session.create`, as before.
- **New Bot Chat** stays: the open Bot Chat is renamed `Bot Chat · <date>` first, which frees the title, and the
  plugin makes the next one.
- **Source label.** Hermes stores its own chats as `local`; the app's resume stamps `bighelp`, which gives the
  agent bighelp's brief. Identity checks treat those two labels as one (`DirectHermesIdentity.sameSessionSource`),
  and the app resumes a `local` chat whose ID starts with `local-`. Every other label still has to match exactly.
- **Chats moved aside before this** keep their history. The catalog shows a non-canonical `bighelp` or `local`
  chat titled exactly `Bot Chat (<label> <id>)` as an ordinary chat named like a retired Bot Chat; the host title
  isn't rewritten.
- **A failed open** shows the saved copy without a connection of its own. The chat opens again by itself while it
  is on screen (`ShellFeatureStore.failedOpenRetryDelays`) and when the person comes back to it, so Send works
  again without restarting the app.
- **Catch-up before Send** waits at most `ChatModel.catchUpTimeout` (30 seconds); the message stays in the box.

Edits of a saved chat go through `DirectHermesSessionEditor`. Current Hermes answers the dashboard's `PATCH` and
`DELETE /api/sessions/{id}` with 404 `not_found` for chats the app made over the socket, so hide and unhide
(`session.set_hidden`), archive and restore (`session.archive`) and delete (`session.delete`, refused by Hermes while
the chat is open) use the socket, and a title is set on an open chat (`session.title`; a saved chat is opened first).
Pin and unread have no socket method and use the dashboard route; Hermes' own words (`not_found`,
`client_upgrade_required`…) reach the alert. A socket that answers "method not found" falls back to the dashboard
route, which sends a fresh lowercase-UUID `request_id` and `expected_revision` (`expected_generation` for a delete)
when the row's detail has an integer `runtime_revision`, tries once more on `revision_conflict` or `stale_generation`,
and sends the plain body when the detail has no revision.

Generic conversation deletion is disabled. The explicit internal
`deleteNativeRow` operation refreshes the catalog target and returns a row-only
receipt that warns other history may remain. Hermes deletes that row and
delegate children but orphans branch/compression descendants; neither root nor
tip deletion proves conversation-wide erasure. Root must obtain explicit
row-semantic confirmation before exposing that narrower action.

This client does not conform to `SessionForkClient`: that receipt cannot carry
native branch coordinates, and raw REST row counts do not establish the native
branch method's visible-prefix count. Root must not substitute the local
success-shaped fork client for Direct. No seeded `session.create` workaround is
used.

The exact-checkpoint limitation was checked against the official branch
implementation: its count indexes a separate filtered, reconciled display
history, not REST rows or displayed wire messages. It accepts no checkpoint
digest, boundary row ID or shared history revision. An idle read is not a
snapshot lock. Writes may precede a failed agent build, and the returned message
IDs may still belong to the source; a child needs authoritative history refetch.
Whole-current-text-history branching is a different operation and does not
implement bighelp's selected-message checkpoint contract. The separate API-server
fork route also has different source/auth semantics and ends the original
session; it is not a substitute.

The smallest upstream branch extension would accept a stable native checkpoint
coordinate with an expected history revision, reject stale boundaries before
mutation, and expose a recoverable operation receipt with exact child
profile/durable/runtime coordinates. Conversation-wide deletion separately
needs an explicit server-owned lineage scope and authoritative deletion receipt.
These are missing capabilities, not API names implemented by this client.

Contract reference: official Hermes
`1c671beab29164d8931c5d01c5739502267089d8`, especially
`hermes_cli/web_routers/sessions.py`, `tui_gateway/methods_session.py`,
`tui_gateway/methods_profiles.py`, and the public programmatic integration guide.
Tests are synthetic owner-bound transport contracts; they do not create a
production session or invoke a provider/model.
