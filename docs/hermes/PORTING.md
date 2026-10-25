# Implementing an Android or React Native client

This guide consumes the [native transport contract](../NATIVE_TRANSPORT.md).
It proposes an implementation structure; it does not introduce new host methods.
The same wire messages apply to Kotlin, JavaScript/TypeScript, Swift and other
clients. Start with one host, one principal and a normal session before adding
multi-host UI or optional integrations.

## Separate wire logic from platform services

| Component | Responsibility | Portable implementation considerations |
|---|---|---|
| Endpoint and credentials | Canonical endpoint, proxy headers, discovery, sign-in, renewal and secure persistence | Kotlin can use an HTTP/WebSocket stack such as OkHttp; React Native needs a stack that exposes required headers, redirects and upgrade failures. These are implementation options, not host requirements. |
| Ordered transport | WebSocket readiness, newline frames, bounded decoding, outbound queue, RPC correlator, heartbeat | One ordered reader and writer per connection; do not run frame callbacks concurrently. Maintain distinct inbound and outbound request namespaces. |
| Capability registry | Core supported methods, exclusive submit, groups and optional plugin context | Keep the advertisements separate. Invalidate generation-bound capabilities when their owner retires. |
| Session coordinator | Create/resume, runtime/durable ID mapping, local submission journal, server request routing | Persist intent before dispatch and preserve uncertainty; never implement transport-wide automatic retry for mutations. |
| History and live reducer | Paged canonical history plus disposable live overlay | Keep stable row identities, raw native rows and replay coordinates; preserve ordering without guessing deduplication from text. |
| Extension clients | Typed stock REST/RPC and separately guarded plugin requests | Bound every response and validate returned ownership coordinates, not only HTTP status. |
| Platform adapter | Secure storage, browser callback, audio, files, permissions, app lifecycle and notification delivery | Expose only implemented platform capabilities. Platform permissions never imply a user has enabled agent access. |

A `WorkspaceOperation` is an internal app dispatch name. Some map to RPC,
others to REST, and some are local projections. Send the actual method/path
specified in the chapters, not a serialized Swift enum, cloud envelope or local
conversation ID.

## Minimum compatible chat profile

Implement these in order; acceptance criteria are in [CONFORMANCE.md](CONFORMANCE.md).

1. Parse and persist a canonical endpoint including deployment prefix; require
   validated TLS except the explicit private-network HTTP policy. Provide proxy
   credentials independently from Hermes credentials. Never follow credentialed
   redirects or permit a global cookie store to pick the identity.
2. Discover health/auth and support the host's chosen sign-in flow. Begin with
   dashboard session/access token if necessary, clearly showing unsupported
   flows rather than changing modes silently. Implement refresh-token persistence
   and single-flight rotation before claiming rotating sign-in support.
3. Authenticate `/api/ws`, register prompt handlers, wait for `gateway.ready`,
   and advertise `client.capabilities`. Validate newline-delimited frames and
   server requests independently from method-specific payloads. Read authenticated
   `/api/health` and request `gateway.capabilities {}`. Require its Boolean
   `per_session_exclusive_submit` before ordinary submit, queue or slash-command
   admission: `true` enables those operations, `false` keeps them unavailable
   while independently supported reads, prompt responses and session controls
   remain usable. Missing/non-Boolean is invalid; the server-request handshake
   does not replace this capability check.
4. List profiles and stored sessions; create a session with `source:"bighelp"`
   and a durable creation intent/key; reopen using the exact stored ID and
   profile. Validate the returned runtime and stored IDs separately.
5. Journal and submit one text turn; show its `streaming` receipt as admission,
   consume ordered events, handle clarify/approval, and verify terminal state.
   Steer an active turn by default; expose queue or interrupt only when supported.
6. Read and page canonical history; reconcile it with streaming rows. Reconnect,
   resume and replay with stale-owner checks. Keep an uncertain submission
   reviewable without resending it. Test network loss during each step.
7. Support cancellation and secure-input request retirement by exact socket
   generation, request ID and method. Until a prompt method is implemented,
   answer it with the specified unsupported-method error rather than a fake
   approval, terminal screenshot or empty secret.
8. Add optional extensions only after reading the connected host's context.
   Feature absence is normal. Keep unavailable screens and actions truthful.

## Owner and persistence model

Use an explicit owner token for asynchronous work:

```text
SignIn = canonicalEndpoint + verifiedPrincipal + authenticationGeneration
Owner = SignIn + workspaceConnectionGeneration
SocketOwner = Owner + socketEpoch

before network await: require capturedOwner == currentOwner
perform bounded request
before publishing result or saving rotated credentials:
    require capturedOwner == currentOwner
    require the credential record still matches the one this request read
```

An automatic socket replacement can retain the logical authenticated client and
its registered prompt handlers, while retiring all old socket requests and
queued responses. A rebuilt workspace connection replaces its workspace owner
as well. Keep both fences explicit; the host replay epoch is a third, separate
coordinate.

Retire runtime handles, queued replies, secure prompt values, feed cursors and
in-flight writes on owner change. Same-sign-in caches may remain visible during
reconnection; other-host data must never masquerade as the active host's data.
Profile ID, runtime ID, stored ID, room ID, tool call ID, turn ID and task ID
remain separate fields even when their strings happen to match.

Keep credentials in OS-backed secure storage. Android Keystore-backed encrypted
storage can serve that purpose; Expo SecureStore is an option when its lifecycle
and size limits fit. Do not store refresh/access tokens or proxy secrets in
AsyncStorage, ordinary preferences, analytics or URLs you log. Store durable
history and non-secret intent journals in a versioned local repository scoped
to the sign-in. Do not import old Link pending intents by matching an address.

A mutation journal should retain its original payload, local intent identity,
state (prepared/dispatched/acknowledged/uncertain), authoritative receipt and
ownership coordinates. A socket request ID correlates one call; it is not an
idempotency guarantee. `session.create` and `groups.send` have specific
idempotency behavior; ordinary `prompt.submit` does not inherit it.

## Android and Expo boundaries

| Concern | Port requirement |
|---|---|
| HTTPS and local hosts | Configure network permissions and intentional private HTTP exceptions in the native app. Do not disable certificate validation to make a LAN host connect. Browser mixed-content/CORS restrictions are separate from Hermes authentication. |
| WebSocket headers | Verify the chosen library can supply the documented Authorization/proxy headers and ticket behavior. A browser WebSocket API cannot freely set headers; an Expo native build and a web build are distinct environments. |
| Browser sign-in | The current flow uses PKCE, state, callback validation and a host-accepted loopback redirect. An Android callback implementation must satisfy that contract. An arbitrary app-scheme redirect is not established as accepted by the host. |
| Foreground/background | Mobile suspension can leave a socket object reporting open after it stops working. Probe liveness on return, rotate/resume as needed and re-advertise handlers. Android background execution policies require their own lifecycle design. |
| Notification delivery | APNs, BuzzKit enrollment, iOS quiet wakes and Live Activities are optional Apple integrations. FCM or an Android delivery adapter needs a separately supported backend contract; changing a push token string does not establish compatibility. |
| Live voice | The plugin's offer/poll/result/close protocol is portable; audio focus, microphone permission, WebRTC and media playback require platform adapters. Confirm provider/backend identity and uncertain append behavior. |
| Device tools | Port the authenticated bounded bridge separately from the OS implementation. Advertise only tools actually implemented and enabled. Unsupported iOS-only operations must fail explicitly; do not claim Health, Focus, Shortcuts or AlarmKit parity. |
| Display | Implement the documented authenticated display bridge/RFB profile. Do not reuse Hermes bearer tokens on arbitrary remote desktop endpoints. |
| JSON numbers | Parse integer counters without silent precision loss. JavaScript numbers cannot exactly represent every 64-bit integer; reject out-of-range values or use a lossless parser/storage representation. Serialize numeric wire fields as numbers when required, not string substitutes. |
| Unicode and sizes | Enforce UTF-8 byte limits where specified, not UTF-16 code units or grapheme count. Do not normalize opaque IDs; `é` and `e` plus combining acute can name distinct requests. |

## Recovery sketch

```text
on disconnect:
    retire the socket generation and outstanding prompt owners
    mark dispatched mutations lacking a receipt as uncertain
    persist known receipts; preserve the same-sign-in history/journal
    do not repeat a mutation just because its future rejected

on reconnect under the same sign-in:
    authenticate and rotate credentials safely
    rotate the socket epoch and wait for ready
    replace workspace owner only if rebuilding the authenticated connection
    register/advertise server-request handling
    refresh capabilities and optional plugin context
    require per_session_exclusive_submit == true before reopening submit/queue/commands
    resume retained sessions by profile and durable ID
    adopt the returned durable successor and new runtime ID
    read bounded history and use the session recovery/replay sequence
    reconcile open prompts and known turns without resubmitting intent
```

This is an outline, not a replacement for [CHAT.md](CHAT.md)'s activation/replay
ordering or [CONNECTION.md](CONNECTION.md)'s automatic recovery eligibility.
Room recovery uses the durable room log and its own idempotency contracts.

## What constitutes a working port

First pass the portable framing vectors and all applicable stateful cases in
CONFORMANCE. Then run equivalent disposable-host probes with an explicit Hermes
and plugin source revision, including both groups paths if groups are offered.
Finally verify real Android lifecycle, browser callback, secure storage,
file/audio handling and any supported push adapter on devices. A successful
Swift test, example JSON parse or simulator screenshot does not establish those
platform-specific claims.
