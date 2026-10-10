# iPhone tools for Hermes

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

Permissions contains independent Calendar, Reminders and Location controls. Apple Health
access was removed in 2.3.0 (105): App Review (guideline 2.5.1) refuses HealthKit in an app
whose main features don't need health data. The phone never lists or runs `health.read`, so
the plugin's `iphone_health` tool answers `authorization_required`; a saved Health grant is
dropped when read.
Every control starts off. Enabling one requests its native iOS permission from
that explicit foreground action. Calendar and Reminders authorize direct reads,
creation, updates and deletion after enablement, with no per-operation approval.
Location is read-only. OS permission by itself never enables agent access.

Grants are scoped to the current phone, phone authorization epoch and selected
host. Turning a control off invalidates active work immediately. Switching host,
signing out, backgrounding or losing protected-data access invalidates in-flight
operations. Account erasure deletes persisted grants and mutation outcomes.
Re-enabling a grant cannot revive a read started under an older grant revision.

The phone must be open, unlocked and connected. No background execution or wake-up
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
foreground/protected-data state, selected host, account and expiry. Results
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

- The Location switch asks iOS for While Using the App, never Always. Nothing
  runs in the background; a call while bighelp isn't open fails like the other
  tools (`device_unavailable` on the phone, `phone_unavailable` on the host).
- `NSLocationDefaultAccuracyReduced` keeps approximate location the default.
  When a call finds approximate access, iOS asks once for precise location
  (`requestTemporaryFullAccuracyAuthorization`, purpose key `AgentRequest` in
  `NSLocationTemporaryUsageDescriptionDictionary`). The question is asked only
  after the call is re-authorized (switch, chat, foreground), and the grant is
  re-checked after it. If the person keeps approximate, `precise` is false, a
  `note` says it's a rough area, and `place` has no street, neighborhood or
  postal code.
- It's a read: never journaled, never kept by the plugin for a retry.
- Older plugins reject `location` in the channel's `enabled` list, so the phone
  sends it only when `/native/context` lists `native-device-location-v1`, and
  Device access says to update the plugin.
- Demo mode (`-use-demo-fixtures`) answers from `DemoDeviceLocationProvider`, a
  made-up place, and never asks iOS.

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
