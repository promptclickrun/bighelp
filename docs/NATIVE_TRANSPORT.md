# Hermes native transport contract

This is the entry point for implementing a bighelp-compatible Hermes client in
any language or UI framework, including Kotlin and Expo/React Native. The wire
contract is JSON over authenticated HTTP and WebSockets; Swift types, Apple
frameworks and the app's local `WorkspaceOperation` names are not wire formats.

## Scope and status

This contract describes the **native transport profile used by bighelp**, audited
against app revision `09fc79c01aed91734e8006b5355209a31c52feca` (2026-10-25).
It covers the stock Hermes dashboard/session APIs the app uses and its optional
plugin integrations. It is not a specification of every unrelated upstream
Hermes endpoint. No Hermes server changes or client behavior changes accompany
these documents.

Some companion behavior was also checked against [bighelp-plugin revision
`7e1f74f`](https://github.com/promptclickrun/bighelp-plugin/tree/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf).
The app and plugin evolve independently: an app route registration is not proof
that a particular server offers that route. In particular, Wiki client routes
remain in this app revision but were removed in that companion revision. Gate
features by the actual connected host's advertisements.

The requirements below define interoperability with the current app profile.
Within the chapters, **wire behavior** describes messages the app sends or
accepts, **client policy** describes its local safety/size/retry choices, and
**limitations** identify behavior not established by the audited sources.
Terms such as “must” describe this profile, not a claim that all historical
Hermes releases implement a new standard. Source and test links make those
boundaries inspectable. Example hosts, names, IDs and data are synthetic.

## Read the contract

| Document | Contents |
|---|---|
| [Connection, authentication and framing](hermes/CONNECTION.md) | Endpoint normalization and prefixes, TLS/proxies, all sign-in modes, PKCE/rotation, WebSocket upgrade, JSON-RPC and newline framing, bounds, readiness, ping and reconnect |
| [Sessions, chat, prompts and recovery](hermes/CHAT.md) | Runtime/durable identities, create/resume, submit/steer/queue/background, commands, event payloads, prompt replies, history, journal and replay |
| [Stock API reference](hermes/REFERENCE.md) | HTTP and RPC inventory for sessions, profiles, models, providers, cron, projects/git, files, configuration, skills, tools, MCP, gateways and administration |
| [Optional plugin extensions](hermes/EXTENSIONS.md) | Native context, feature gates, ETags/request correlation, route matrix, attachments, managed media/files, voice, boards, Workflows and other plugin APIs |
| [Groups and device integration](hermes/GROUPS_AND_DEVICE_TOOLS.md) | Both groups protocol paths, RoomLink, durable room log/actions, optional room activity, device tools, display and native app connections |
| [Optional delivery](hermes/DELIVERY.md) | Notification enrollment and sealed alerts, foreground feed, quiet hours and Apple delivery boundaries |
| [Porting guide](hermes/PORTING.md) | Suggested implementation layers, Android/Expo constraints, persistence and reconnect algorithm, phased acceptance criteria |
| [Conformance and evidence](hermes/CONFORMANCE.md) | Portable framing vectors, stateful test matrix, source/test traceability, known gaps and validation boundaries |

Read Connection and Chat before implementing API wrappers. For an initial
Android client, implement the minimum chat profile in the porting guide; then
add feature-gated extensions. All API paths in this documentation are relative
to the selected endpoint's deployment prefix unless explicitly absolute URLs.

## Authority and vocabulary

| Term | Meaning |
|---|---|
| Endpoint | Canonical dashboard scheme, host, port and deployment prefix; never just the hostname |
| Principal | Verified dashboard/provider identity at that endpoint; separate from a display name or a model-provider account |
| Sign-in scope | Endpoint plus authentication identity/generation; bounds all credentials, saved state and actions |
| Workspace connection generation | Workspace owner generation; replaced when the workspace rebuilds its authenticated connection |
| Logical transport owner | Lifetime of an authenticated client; registered prompt handlers may survive its automatic socket recovery |
| Socket epoch | One concrete WebSocket lifetime; rotates on socket replacement and fences in-flight requests/replies |
| Replay epoch | Host-advertised event-stream lifetime; determines whether a saved session-event cursor is reusable |
| Profile | Hermes agent configuration selected by `profile`; IDs are opaque and are not display names |
| Runtime session ID | Live `session_id` used for session RPC and events; replaced when resuming |
| Stored session ID | Durable history coordinate, returned as `session_key`/`stored_session_id`/`resumed`; can change after compaction |
| Request ID | JSON-RPC correlation ID, server prompt ID, native HTTP UUID, or a domain idempotency key; these are separate namespaces |
| Sequence/cursor | Coordinate within a specific event stream or page contract; room-log, session-event and disposable-feed cursors are not interchangeable |
| Receipt | Confirmation for a specific operation; a submit receipt is not a terminal agent answer |
| Outcome unknown | A mutation may have reached the host but no authoritative receipt was received; it is not a rejection |

Opaque identifiers must be compared without Unicode normalization, trimming or
case folding. Numeric timestamps and counters keep each endpoint's documented
units. Do not turn missing values into fabricated state, and distinguish absent
fields from JSON `null` where a decoder does.

## Architectural invariants

1. Chat connects directly to the user's existing Hermes dashboard address and
   port using stock REST and `/api/ws`. Hermes owns sessions, turns, tools,
   model state, approvals and durable history. There is no cloud queue, second
   agent execution loop, extra listener or Link fallback.
2. Native chat needs no bighelp account. Host authentication and submission
   journals are independent of optional notification enrollment/account erasure.
   Old Link preference files or credentials cannot select a production chat route.
3. Register server-request handlers and advertise
   `client.capabilities {"server_requests":true}` on every socket. A WebSocket
   upgrade alone is not ready. Do not answer prompts with invented blanks.
4. Every `session.create` and `session.resume` uses `source:"bighelp"` and the
   appropriate profile. The source affects Hermes' model instructions; `desktop`
   describes a different client's tools. Never invent device capabilities for a port.
5. A `prompt.submit` receipt of `streaming` leaves the turn active. A later Send
   uses the intended steer/queue path; it does not start an overlapping submit.
6. After a dispatched mutation loses its receipt, retain the intent and reconcile.
   Reconnect never blindly resends it, swaps to a cloud transport, takes over
   another process's session, or asserts the work failed. Domain-specific safe
   retries require their own demonstrated idempotency contract.
7. Reject stale asynchronous results after a host, principal or generation
   change. Preserve same-sign-in presentation state across a transient disconnect;
   that does not authorize old requests to act on a new socket.
8. Plugin routes are optional and capability-gated. `/api/plugins/loopdy/native/…`
   uses the native context ETag and a lowercase UUID request ID, with response
   correlation. `loopdy` route/header identifiers are intentionally stable.
9. Durable history is authoritative after a turn and on reopening. Streaming
   rows and disposable activity observations must not be appended as duplicate
   history. Preserve unknown read-only data only within each endpoint's bounds.
10. Optional notifications and Live Activities have separate enrollment, grants,
    trust keys and lifecycle. Their errors cannot block opening or sending chat.
    Apple delivery facilities are not Android transport requirements.

## Compatibility and evidence

Negotiate actual capabilities, not version strings. The host health response,
`gateway.ready`, core method advertisements, `groups.capabilities`, and plugin
`native/context` serve different purposes; none replaces the others. A missing
optional capability disables that integration rather than selecting a retired
transport. Retain readable saved state through transient connectivity failures.

The chapters identify exact tests and probes used as documentary evidence.
The repository's 59 existing JSON fixtures do not collectively define the
protocol. The additional [wire vectors](hermes/vectors/wire.json) isolate the
framing boundary, and the [conformance checklist](hermes/CONFORMANCE.md) covers
the stateful behavior that cannot be established by a single JSON sample.

Older design narratives under `docs/` retain historical implementation context.
Where they describe Link fallback, account-required native chat, missing native
features or non-idempotent create behavior, use this contract and its source
revision instead. Product interaction requirements remain in
[CHAT_INTERACTION_CONTRACT.md](CHAT_INTERACTION_CONTRACT.md); broad app architecture
and delivery background remain in [ARCHITECTURE.md](ARCHITECTURE.md).
