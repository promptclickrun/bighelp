# Workspace management

Workspace management is a set of native tool pages for one computer.
`WorkspaceDestination` is a finite navigation contract. The shell opens a page
with `RootShellView.openWorkspaceDestination(_:)` from where it belongs, and the
shell routes Sessions, Scheduled Tasks, Skills, Voice, agent profiles and device
settings to their existing owners. Tasks means session goals and task controls,
not a second scheduler. Artifacts means files in their originating sessions, not
an invented universal host catalog.

There is no Hermes tools list. Each page opens from the screen it tunes: AI providers
and default models in Settings › Models; Skills, Plugins, Messaging, MCP and
Toolsets in Settings › Apps & skills;
logs, webhooks, tool backends, diagnostics, backups and the other host pages on a
computer's page (Advanced groups, with Advanced options on); Clean up chats in
Settings › Chat; Toolsets and Manage bots in a bot's Advanced Options. Scratchpad,
GitHub and Wiki remain retired from app navigation, and the contract also leaves
out Usage (the first group of Settings, and the sidebar's More) and the destinations for this app's own settings, which
live in Settings. Native Wiki
contracts and clients remain for older hosts that still list `native-wiki-v1`
(current plugin releases no longer have the Wiki routes), without adding a
visible Wiki menu entry.

`NativeWorkspaceManagementClient` consumes the shared `WorkspaceOperationPerforming`
boundary. It does not open a second socket, proxy arbitrary URLs, invoke shell
commands, or create provider/MCP connections. Hermes remains authoritative.
The selected owner includes authentication and connection generations; the
client checks it before and after every await. The shell must synchronously
retire `WorkspaceManagementStore` when the host, principal or profile changes.
Retirement removes loaded content, file previews and pending mutation reviews.

## Implemented management surfaces

| Destination | Native management behavior |
|---|---|
| Projects | Bounded list/search, folder details, reviewed rename and reversible archive/restore; registration changes never delete files |
| Models | Configured provider/model inventory and current profile default; existing agent runtime controls own default changes |
| Files | Read-only native confined-root or canonical plugin host-grant navigation; real revision-bound plugin directory pages and digest-verified bounded UTF-8 previews |
| Usage | Host-reported 30-day totals/model rows; null aggregates stay unknown, and the period refers to session start dates |
| Logs | Bounded serving-profile diagnostics; only severity is displayed, with message bodies withheld |
| Memory | Actual provider readiness and built-in storage sizes; the native endpoint does not return editable memory documents |
| Toolsets | Profile inventory, enabled/configured state and tool names; enabled is not runtime-health proof |
| Plugins | Profile plugin inventory, canonical identity, version and source; no implicit trusted-code installation |
| MCP | Profile server configuration and transport; not a claim that every configured connection is live |
| Messaging | Profile platform configuration and host-reported gateway state; no parallel platform adapter |
| Webhooks | Serving-profile inventory and reviewed per-subscription enable/disable; no global platform restart |
| Configuration | Allowlisted profile-default reasoning controls, with receipt and fresh readback |
| Keys | Presence-only catalog and reviewed write-only replacement for non-channel-managed secret fields |
| System | Bounded host system/version information, without process-control actions |
| Documentation | Explicit external links to official Hermes documentation, not a substitute for missing functionality |

Inventory snapshots retain their full accepted bounded rows. Search and Show more
are local presentation over that snapshot, not invented server pagination.
Plugin Files uses the existing server's real offset/limit/revision contract;
directory search in this view filters only the pages loaded so far.
An oversized or malformed response fails visibly rather than silently truncating.
Failed refreshes label the previous read as stale and disable changes.

## Scope and privacy

The released memory, webhook and log endpoints use the serving process profile;
an undeclared profile query parameter does not change that. These pages remain
unavailable until composition supplies verified serving-profile identity equal
to the selected profile. System and managed Files explicitly disclose host-wide
scope. Native operations are not inferred from a successful connection or a
version string; mutable controls require exact owner/profile capability evidence.

The native file response must contain matching, nonempty `root` and `locked_root`,
with `can_change_path` false. Every navigation and preview verifies the same
root and requested path. A stock native root must be explicitly configured
before the first listing: the client never enumerates a default host home to
discover afterward that it was unconfined. No arbitrary path field or broader
filesystem API is exposed. Unsupported binary/large documents remain in their original attachment
workflow. Preview data is memory-only, not persisted or automatically exported.

The optional `WorkspaceGrantedFilesClient` is a separate adapter for the canonical
bighelp plugin's existing authenticated Files API. Composition selects it explicitly,
never as an error fallback that broadens authority. The authenticated native context
must prove that the selected profile is the serving profile. Its root catalog
contains opaque IDs and labels, not absolute source paths. Host-local grants are
additional authority; there is no remote grant/revoke action.

The adapter re-probes the grant catalog before navigation, paging and file reads.
Directory pages retain the same revision, offset and total; file chunks retain
the same full-file revision and size, and the completed bytes must match that
SHA-256 before preview. Stale pages, changed chunks, revoked roots, binary data,
unsupported traversal and owner changes fail visibly. The host rechecks grant
generation and filesystem identity during I/O, but the existing wire format
contains no grant-generation token or per-principal ACL. This app does not claim
either; authenticated clients share the serving profile's explicitly granted
catalog. Previously delivered content cannot be remotely recalled.

Credential models ignore raw/redacted values, commands, headers and environment
values. Replacement text is held only for explicit review/submission and is
cleared from its editor immediately after review begins or navigation retires
the editor. A successful save confirms host storage and presence, never provider
authentication. Log bodies are not displayed or exported because regex token
redaction cannot reliably remove private prompts and paths.

No new content repository, telemetry, permission, raw-microphone upload, plugin
installation or host restart is introduced. Advanced install/setup, memory reset,
raw config editing, secret reveal, Git write operations and process administration
are deliberately not automatic mobile actions.

## Validation and integration

### Direct Projects and Scheduled Tasks

`DirectHermesProjectClient` reuses the existing picker/store contract. Current
session association comes from an exact profile/durable-session detail read and
Hermes' project-for-directory method, never local registry matching or a
guessed conversion from a visible conversation ID. Moving an existing session
does not change the profile's global project preference. Selecting the global
project only changes Hermes' registry: new-session creation must explicitly use
`selectedFolderPath(agentID:)` as its native working directory. Directory
suggestions remain unavailable without a verified narrow policy-aware route;
the adapter never scans the host or uses a generic filesystem bypass.

`DirectHermesScheduledTasksClient` uses the existing schedule builder and native
profile-scoped cron routes. The native all-profile route suppresses individual
profile failures, so the adapter reads the authoritative profile catalog and
each profile separately. A failure remains a failed catalog, not a successful
partial list. Raw native IDs and profile coordinates are preserved. A
`ScheduledTaskIdentity` pair keys rows, cached updates, deletions and pending
mutations, so different profiles can keep the same native job ID without
collapsing or renaming it. ID-only legacy lookup must resolve exactly one task
or report ambiguity. Root navigation must pass the known task profile into
the detail view; the existing list callback already supplies the full task.

Mutations verify native identity, saved fields and state; deletion also checks
the exact profile's next catalog. Completed and failed states remain distinct
from active/paused. Running a paused job requires explicit review because native
Hermes resumes it. Script/skill execution cannot be duplicated or edited as a
plain prompt through a lossy mobile form. Native delivery catalogs are process
scoped: implicit non-local home destinations require verified serving-profile
identity, while explicit platform/channel coordinates remain catalog validated.
Partial or lost mutation outcomes are never automatically retried.

### Read-only native Project Changes

`DirectHermesProjectGitClient` uses the canonical plugin's separately negotiated
native Project Git read capability. It does not adapt the weaker stock dashboard
Git routes or reuse unrelated Files grant IDs. Requests carry only the selected
profile, full native stored-session ID and registered Project ID; the plugin
revalidates that association and applies its existing pinned-root Git and
sensitive-file policies. The iOS client checks the captured owner and resolved
session coordinates before and after every request.

The adapter reuses the existing strict Project Git response decoders and Changes
renderer. Every mutation capability is false; prepare and execute fail without
contacting the host. Incomplete status is unavailable rather than pretending
that its next offset names a supported status-page endpoint. Unmerged/combined
conflict diffs are explicitly unsupported. Binary and oversized diff outcomes
remain typed; full Markdown/text preview bytes are preserved within their bound.

Status tokens remain the existing service's content-derived optimistic
observations. The host checks them before and after each read; they are not an
immutable filesystem snapshot or atomic Project/session lease. No client-created
hash substitutes for a host token. Diff pages forward the same host token, and
the existing `status_changed` recovery refetches current status and restarts the
diff rather than appending another revision. Only confirmed
`project_not_repository` means N/A; Git, authorization, scope and transport
failures remain errors.

This client requires the compatible canonical plugin routes and Direct native
context broker. Source-level client tests do not establish deployment, root
composition or a live user's Project authorization.

### Native Wiki identity

Wiki ownership keeps the retired Link transport's device authority
(`WikiOwner.Authority.link`) apart from authenticated native Hermes principal
authority, which is the only kind the app makes today. Native identity contains the endpoint,
provider, principal and profile, with no invented Link device, account or
authorization epoch. Its local storage namespace is domain-separated; opaque
principal equality is byte-exact. The legacy Link JSON encoding remains unchanged
so protected filenames and recovery journals from older versions remain readable.

The shared Wiki codecs retain byte/revision/upload validation and accept a
finite native request seam without manufacturing Link frames. Native transport
composition must additionally bind the current `WorkspaceOwner` and plugin
context; a stable persistent principal is not proof of a current connection.
The selected Codex UI retires Wiki navigation and the legacy chat
reference-provider interface. Native Wiki contracts and clients remain
available for backend integration without restoring those app surfaces.

Native login does not require Wiki pairing or device enrollment.
The compatible canonical plugin still owns grants, revision checks, shared
principal/profile uploads, and protected source policy. Generated, mirrored and
exported sources remain read-only even if the host supports file creation.

`DirectHermesWikiClient` maps only the fixed native Wiki operations through the
owner-bound performer. The native context, conditional context header and
request identifier belong to that authenticated transport. Reads, searches,
images and upload/status calls reuse the existing validated domain codecs.
Native saved-folder discovery uses non-mutating resolve, never connect: another
device's cached preference cannot silently recreate a revoked grant. Reconnection
requires an explicit Connect action and a fresh host root identity/generation.

Disconnect on Hermes is separate from disconnecting locally. Its reviewed action
removes access for the same Hermes principal/profile across devices, not login,
files or recovery uploads. The app accepts only an exact root-matching receipt,
retires late reads of that root, and retains pending recovery. Logout and cache
cleanup never invoke host disconnection. Local cleanup failures after confirmed
revocation are reported as partial local cleanup, not a failed host operation.

`WorkspaceManagementTests` covers native DTO bounds, additive metadata,
process-profile gates, path/root and byte validation, secret/log projections,
owner replacement, reviewed mutations, authoritative response matching,
retirement and local paging. `WorkspaceManagementLayoutTests` mounts the real
SwiftUI hub and management views at phone/tablet dimensions with accessibility
text sizes. These mounted tests do not replace end-to-end shell routing,
VoiceOver interaction or physical-device acceptance.

`WorkspaceGrantedFilesTests` and `WorkspaceGrantedFilesClientTests` cover exact
grant capability flags, root selection without automatic reads, real page
coordinates, grant re-probes, relative-path confinement, chunk revision changes,
content digests, binary/oversize failures and serving-profile/owner invalidation.

Run both suites and `WorkspaceFoundationTests` on an isolated simulator, using
one DerivedData directory. The final integrated shell must also exercise every
`usesExistingDestination` callback and preserve the chat interaction regressions.
Synthetic fixtures never contact or mutate a production Hermes host.

Wiki/reference cleanup tests that exercise the real simulator Keychain require
a locally signed simulator app. Use ad-hoc simulator signing
(`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`), not an unsigned app; this does
not require production provisioning or authorize distribution.

For the official source mutation contract (not a fake Hermes package), run:

```sh
"$HERMES_PYTHON" Scripts/validate_workspace_native_contracts.py \
  --hermes-root "$HERMES_SOURCE"
```

`HERMES_SOURCE` must identify the reviewed official checkout and `HERMES_PYTHON`
a compatible Hermes environment. The script creates a temporary isolated home,
exercises the real project and reasoning handlers, and removes only that home.
It never launches a gateway, executes an agent, restarts services or accesses
production credentials. HTTP authentication, root-shell navigation and live
connected-host acceptance remain separate checks.
