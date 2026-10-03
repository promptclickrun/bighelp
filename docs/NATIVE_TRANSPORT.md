# Native chat transport

Production chat connects directly to the selected Hermes host. Cloud services are
used only for explicitly enabled notifications and Live Activities, which BuzzKit delivers.

## Connection and storage

- `BighelpAppComposition` selects `NativeWorkspaceRuntime` and the existing
  authenticated Hermes REST and `/api/ws` clients.
- Startup always selects the independent host registry. A saved Link preference,
  cloud login, expired cloud credential, or unavailable cloud service cannot
  select the chat route. Host authentication and local submission journals are
  isolated from cloud account erasure.
- The iOS target no longer contains the disabled Link chat socket, its outbox
  state machine, the paired Direct experience, or the old HTTPS gateway client.
  Shared wire value types and narrowly scoped legacy-data erasers remain where
  native clients, notification delivery or migrations still use them. The plugin
  does not load a Link chat client or start its paired Direct listener; its
  explicitly injected protocol fixtures do not enable a production fallback.
- Existing legacy account-scoped host files and credentials are preserved.
  They are not adopted by matching an address. Reauthenticate an existing native
  host explicitly when moving it into the independent registry.
- Connect to the operator's existing Hermes dashboard address and port. No
  additional listener, public URL, cloud login or cloud pairing is required.
  The app discovers and offers the host's own sign-in methods: no sign-in,
  dashboard session token, access token, username/password and dashboard login.
  An ungated dashboard bootstraps its existing session token from the exact
  endpoint's inert HTML, just as the dashboard does; this does not create a
  provider identity or change server authentication. Provider accounts retain
  strict provider/user identity. All credentials remain in the iOS Keychain,
  on this device only, readable after its first unlock.
- Rotating sign-ins (the Nous Portal's renewal token lasts a day) are renewed
  while bighelp is closed: the plugin asks the notification service for a quiet
  push (`bighelp_wake`, `renew-sign-in`) every eight hours, and the app renews
  each computer that isn't connected (`renewSignInWhileAway`). A live connection
  renews its own, and reconnecting waits for a renewal on its way. iOS may delay
  or drop quiet pushes, and never delivers them to a force-quit app.
- Hermes owns sessions, turns, tools, approvals, model state and recovery. An
  uncertain native submission remains in its existing local journal; reconnect
  does not resend it or switch to a cloud queue.
- A reply to a message (long-press › Reply) has no field in `prompt.submit`, so
  it travels in the message text the way Hermes hands replies from other
  platforms to the model: a first line `[Replying to your previous message: "…"]`
  (or `my previous message`, or a name in group chats), a blank line, then the
  text (`ChatReplyQuote`). The quote is one line of at most 500 characters with
  `@` handles disarmed. Because it is the message's own text, Hermes' saved
  history keeps it, and the app reads it back to draw the reply above the bubble.
  The draft saves its reply the same way.

## Optional delivery

The notification account action opens only account management, with no paired
chat-device catalog. Explicit notification enrollment records a separate
`BighelpHostNotificationBinding` (cloud device and authorization epoch). It does
not change the native host, principal, credentials, selected workspace or
registry generation.

Notification ledgers, grants, trust pins and Live Activity ownership use that
notification scope. Each operation still verifies the current cloud credential
and exact native host binding. Changing the notification account retires its old
delivery enrollment and retains pending revocation metadata. Native chat is
unaffected. Cloud requests without an explicit enrollment remain unavailable.

## Native Live Voice

The optional plugin capability `native-voice-v1` exposes bounded POST operations
under `/api/plugins/loopdy/native/voice/`: `status`, `offer`, `poll`, `result`,
and `close`. They require the real Hermes interactive session, native context
ETag and request-ID correlation. All calls bind the native principal, profile,
stored session and backend runtime; there is no Link account or device catalog.

The host reuses the existing Codex subscription or explicitly selected API-key
provider media implementation. Credentials remain on the host. There is no
automatic provider/billing fallback. The phone owns WebRTC audio, and host events
arrive over the authenticated bounded native feed.

Provider work requests go through the current `ChatModel` and ordinary Hermes
`prompt.submit`. They do not create another voice job database, agent loop or
cloud queue. Repeated IDs are ignored; identical pending requests with different
provider IDs share one native submission. Distinct requests are bounded and
serialized. Work and pending approvals remain visible in the same chat.

Only a verified native terminal answer may be returned to the media provider.
A queued receipt, failed turn, overlapping admission or uncertain submission
does not become a claimed answer. Long answers are explicitly labeled excerpts;
the complete result remains in Hermes history. Native timeline updates are not
appended a second time to return an answer to voice.

An offer ID is consumed before provider allocation and cannot be replayed in the
same backend runtime. A backend restart changes the native context and rejects
old-context requests. A result append is also claimed before sending, so a lost
receipt cannot cause a repeated provider append. Media expires after 60 seconds
without authenticated polling. Ending media does not cancel accepted Hermes
work, and an old call's result cannot appear in a replacement call.

## Verification boundaries

`NativeWorkspaceProductionUITests` exercises the production app against a
disposable real Hermes host with a rejecting cloud endpoint: native sign-in,
workspace navigation, new chat, ordinary tool execution, streaming, exact stored
history and cold relaunch. `Scripts/NativeWorkspaceAcceptanceProbe.py` requires
an explicit full source SHA and records every attempted cloud connection.

Native voice tests additionally cover real native lifecycle reduction, duplicate
provider requests, owner changes, media close, provider append uncertainty and
authentication revocation. Simulated provider/media tests do not establish live
microphone performance or a completed physical-device voice conversation.

Build, plugin activation and TestFlight processing are separate claims and must
be verified against the exact deployed source and build number.

Missing or invalid optional cloud configuration cannot stop application startup.
Native chat notification subscription and Live Activity hooks run separately after
explicit enrollment; their errors cannot block opening or sending chat.

## Workspace presentation and synchronization

Tasks uses Hermes' native cron client for its full lifecycle. Agent row taps
create a new native chat for that profile. Groups use official groups RPCs and
keep the selected authority's cached catalog through transient reconnects.
Agent enumeration omits session scans, compares catalog metadata, and reuses
unchanged SOUL/avatar details for up to 60 seconds because the current Hermes
catalog does not provide revisions for those files. Changed metadata fetches
fresh details immediately; mutation validation always rereads current state.
Auth/host changes retain their strict scope boundaries. Streaming native rows
advance the same presentation counter as locally submitted messages.
