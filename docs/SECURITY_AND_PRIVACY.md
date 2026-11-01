# Security and privacy

Production transport contract: **native Hermes only for chat**. Cloudflare is
limited to optional notifications and Live Activities. The current composition,
voice boundary, enrollment isolation and verification requirements are defined
in [Native transport](NATIVE_TRANSPORT.md). Retained Link/paired-Direct protocol
sections below describe legacy compatibility code, not a selectable chat path.

This document describes the technical behavior of the current implementation.
It is not legal advice and does not replace a jurisdiction-specific privacy
policy, App Store disclosure review, or independent security audit.


## Optional iPhone tools

The next release candidate adds independent, default-off Health, Calendar,
Reminders and Location controls in Permissions. Health data is read only for the user's health
and fitness questions. Before Health's first grant, a one-time note says that shared Health data goes to
the person's Hermes computer and its AI provider, is not used for advertising, and can be turned off
at any time. When an agent asks for a tool that's off, a card in the chat can turn on the same
switch; it never turns one on by itself, and Not now refuses the call. Location shares where the phone is only when an agent
asks, with While Using the App access; it's approximate unless the person allows
precise location for that call. Calendar and Reminders permit direct reads and changes
after explicit enablement and iOS authorization. Grants belong to the phone, its
authorization epoch and the selected host. Turning a grant off blocks new and
in-flight access; it does not revoke the underlying iOS permission.

## What a live voice call tells the voice model

On a Full Duplex call to a computer whose plugin lists `native-voice-context-v1`, the app's offer also
sends the agent's name as the app shows it, the name you saved in bighelp (never the placeholder "You"),
and the phone's time zone. While Location is on in Device access and iOS allows it, it also sends a
coarse place: city, region and country. It comes from the phone's last known position when that is
less than an hour old, else from a new city-level fix (kilometer accuracy). The call waits for it
about one second at most; a slower search fills the place in for the next call. It never sends
coordinates or a street. The plugin puts these into that call's instructions for the voice provider
(GPT-Live or Gemini Live), so the agent can call you by name and answer weather and local questions,
and keeps none of them. With Location off, no place is sent.

Agents can also change how bighelp looks (light or dark mode and the chat color)
with `iphone_appearance`. It reads and changes only those two settings, shares no
phone data and needs no iOS permission, so it's on until the person turns off
"Let agents change how bighelp looks" in Device access (one switch for every
host). It works only while that chat is open and bighelp is in front.

Requested results travel through encrypted directed Link frames to the selected
Hermes host and may be sent to its AI provider and retained in normal tool/chat
history. The native mutation journal and plugin retry cache retain only bounded
identity and reconciliation metadata, never private read payloads. Health data
is not used for advertising or analytics. Availability is foreground-only.
Account erasure removes saved grants and the local mutation journal. See the
[iPhone device-tools contract](IPHONE_DEVICE_TOOLS.md) for exact boundaries,
Health empty-result semantics and the physical-device acceptance requirements.

## Usage and diagnostics

bighelp counts how it is used and how it performs so the maintainers can fix what is slow or
broken. It is on by default and has an off switch: Settings › Permissions › Device access ›
**Share usage and diagnostics**. What follows is what the code sends (`Bighelp/Telemetry/`).
Nothing here is for advertising or sold, it holds no name, email or account, and bighelp does not
track people across other companies' apps or sites. The numbers are tied to a random install ID, so
the App Store privacy label declares them as linked to the device's ID (not to a person's identity),
for app functionality and analytics, and never for tracking.

### What is sent

Each batch (at most 50 events) goes to `https://telemetry.bighelp.app/v1/batch`, over HTTPS,
gzip-compressed when that is smaller, with a 5-second timeout. It holds:

- **An install ID**: a random UUID the app makes and keeps in this device's Keychain (never in iCloud
  Keychain or a backup restored elsewhere). It is not derived from anything on the phone, the Apple
  ID, a host or a notification token. It never survives deleting the app: a launch that finds no marker
  in the app's own preferences (a fresh install or a reinstall) deletes any ID the Keychain still holds.
  A new **session ID** is made at each launch.
- **Context**: app version and build, the OS name and version, the kind of device (iPhone, iPad, Mac,
  Vision) and where the build came from (debug, TestFlight, App Store). No device name, no
  language, no region, no advertising or vendor identifier.
- **Events**, each a fixed name with a few numbers or fixed words:

  | Event | What it carries |
  |---|---|
  | `app.opened`, `app.backgrounded`, `session.ended` | whether it was a cold start; time in the foreground; session length |
  | `feature.used` | which of 14 fixed features was used: chat sent, card drawn, card answered, voice turn, live voice, workflow run, mode switched, agent opened, file opened, Shortcut run (counted after the AI-data agreement), widget opened (any `loopdy://` link the system opens: mostly widgets, also Live Activity and alert links), CarPlay voice, Watch chat, notification opened |
  | `perf.first_token_ms`, `perf.reconnect` | milliseconds from Send to the first streamed word; how long a reconnect took and whether it worked |
  | `perf.launch` | MetricKit's launch histograms: the middle bucket and how many launches |
  | `hang`, `crash` | MetricKit's reports: exception type, code and signal as numbers, and up to 64 stack frames as a binary UUID, an offset and the binary's name |
  | `notification.received` | whether a push was an alert or a wake, whether it came the new way or the old way, and how many milliseconds it took from the relay (and from the host event) to the phone |
  | `telemetry.toggled` | sent once, when someone turns sharing back on |

Crash and hang reports come from Apple's MetricKit only, with no third-party SDK. MetricKit's
free-text fields (termination reason, exception reason, memory-region description) are never read.
Stack frames are addresses, so a crash reads as numbers until a symbol file turns them into names, off
the phone.

### What is never sent

Message text, prompts, replies, tool arguments or results, file names or paths, card contents, push
tokens, agent or person names, emails, IP addresses, host addresses, chat or session IDs, event IDs,
or anything from the Keychain except this install ID. Names, keys and values are Swift enums and
numbers, so free text has no way into the code that builds a batch, and the service drops any
name, key or value off its own allowlist. Tests feed realistic chat text, file paths and names
through every entry point and check none of it reaches a batch.

### Push delivery times

The notification service extension makes no network calls for this. For each push it writes a
receipt (alert or wake, which path it took, and the delivery time) to a small list of at most 200 in
the app group it already shares with the app. The app reads and clears that list when it opens and
comes forward, and sends the times as `notification.received` events. With sharing off, the
extension writes nothing and the app throws away what is there.

### Where it goes and how long it stays

The service is a Cloudflare Worker (`telemetry.bighelp.app`). It checks every batch against an
allowlist, rate-limits by install ID and by a keyed hash of the network address (the address itself is
never stored, logged or forwarded), and forwards what passes to Microsoft Azure (Application Insights
and Log Analytics), where it is kept for 90 days. Reports from a Hermes host (not from the app) also get the
host's country and, in the US, its state, as Cloudflare's edge assigns them to the connection; no city
or address is kept. See [TELEMETRY.md](TELEMETRY.md#host-location).

### The off switch

- Turning it off stops sending at once, throws away anything queued (in memory and on disk), deletes
  the install ID, and stops the extension from noting pushes. A launch with it off deletes the queue
  file and any ID again. Quick off and on changes run one after another, and each computer is asked
  again whether the choice still stands just before it is told.
- It also tells each connected computer that lists `native-host-telemetry-v1` to stop its own usage
  reports (`PUT /api/plugins/loopdy/native/telemetry {"enabled": false}`). A computer that connects
  later while sharing is off is told then. Computers without the feature are skipped.
- Turning it back on makes a new install ID (so the two periods can't be joined), sends one
  `telemetry.toggled` event, and sends `{"enabled": true}` to each connected computer that lists the
  feature. The app sends `true` at no other time. A computer that wasn't connected at that moment keeps
  its own switch off until the next time someone turns sharing on while it's connected.
- Sharing never runs in tests, in UI tests, in demo mode (`-use-demo-fixtures`) or in a build from
  Xcode (unless `-bighelp-telemetry` is passed).

## 1. Security goals

bighelp aims to:

- Keep message content unreadable to the Cloudflare routing layer.
- Authenticate every authorized endpoint independently.
- Make endpoint revocation enforceable without rotating every other device.
- Prevent replay, cross-session substitution, malformed payloads, and stale
  callbacks from becoming trusted application state.
- Keep private keys and content keys out of source code and ordinary
  preferences.
- Deliver notification text only after cryptographic authentication and
  decryption on the recipient device.
- Minimize durable cloud data and separate account routing from APNs delivery.

## 2. Cryptographic design

### Link account content key

For a bighelp Link account, the app creates a random account content key on the
device. Link message and workspace payloads are authenticated and encrypted with
AES-GCM before they enter the bighelp Link routing plane. An independently
authenticated native Hermes workspace does not acquire a Link account key or
require Link pairing.

During account registration, the app uses a passkey PRF result to wrap the
account content key. The cloud stores the resulting encrypted envelope, not the
plaintext account key. On sign-in, the passkey PRF result unwraps the key on the
device.

### Device authentication

Each independently authenticated Link device creates its own P-256 signing key. The private key remains in the
device Keychain; the public key is registered with the account service.
Authenticated requests include freshness and replay-protection material and are
verified against the device's current authorization epoch.

Device-friendly names are encrypted with the account content key before cloud
storage.

### Paired Watch companion

The companion Watch is not an independent Link endpoint. It uses the
OS-managed paired WatchConnectivity channel and receives no account content
key, signing key, passkey grant or reusable host credential. The paired Watch
is trusted with the bounded session, approval and attention content displayed
on its screen. The phone revalidates authority, offer identity, expiry and exact
approval scope before submitting an action to the authorized host.

Phone action receipts and Watch recovery records are bounded, atomic,
backup-excluded Application Support files protected until first user
authentication. They can retain a bounded final voice reply for recovery for
up to 24 hours. Watch recovery does not persist prompts or whole snapshots.
Account/host changes invalidate offers and clear state when the Watch receives
the new context; already displayed data cannot be erased remotely while it is
offline. Stale data cannot authorize new actions.

Watch system dictation follows Apple's language, permission and processing
settings; it is not covered by the phone's on-device recognition guarantee.
The app sends the reviewed text draft through the phone, not a raw microphone
recording. Reply speech is explicitly requested and stops on backgrounding.

### Host pairing

Pairing uses a short-lived human-readable challenge. Approval transfers the
account content key to the new Hermes host through an ephemeral Curve25519 key
agreement, HKDF-derived wrapping key, and authenticated encryption. The pairing
code is not a reusable credential and does not contain a private key.

The host locally commits to the pairing flow, device coordinate, signing public
key, and agreement public key. QR pairing carries the complete SHA-256
commitment. Manual pairing requires a separately displayed 16-character
fingerprint derived from that commitment. The app derives the commitment again
from the server-inspected keys and refuses to release the account key if it does
not match. The plugin ignores any pairing URL supplied by the service and
constructs the verified URL from its own keys.

### Link frames

WebSocket frames contain routing and sequencing metadata plus AES-GCM
ciphertext. The account/link Worker and Durable Object route this envelope
without decrypting the content.

The endpoints enforce monotonic sequence handling, acknowledgements, duplicate
recognition, request/session matching, and bounded decoding.

### Encrypted alerts

Each mobile device owns a notification recipient key. Alert encryption uses an
ephemeral key agreement, HKDF, and AES-GCM. The relay signs the complete
envelope. The device validates a bounded, validity-windowed sender-key set
provided during authenticated push registration.

Notification content is rendered only after signature, freshness, recipient,
and authenticated-decryption checks succeed.

The account service provisions the sender-key set. No independent out-of-band
transparency or continuity mechanism anchors it. This protects against
modification in APNs transit and relay storage, while the account service
remains in the notification trust boundary.

## 3. Trust model

### Trusted with plaintext

- The user's unlocked iOS device
- Its paired Watch, for bounded companion content and explicit replies
- Each explicitly authorized Hermes host
- AI or tool providers configured by that Hermes host, for data required to
  perform the user's request

### Not trusted with plaintext message content

- bighelp's Cloudflare routing Worker
- The per-account Durable Object
- The notification relay database
- The asynchronous APNs delivery queue
- Apple Push Notification service for encrypted alert bodies

### bighelp Card data sources

Build 3 accepts static `loopdy.card` documents only. Delivered Cards must have an
empty `data_sources` array, and the production client does not perform Card data
fetches. Live third-party data sources remain reserved for a later security-reviewed
release. The dormant parser and network-policy code are not production-reachable in
this build.

### Local customization

bighelp does not expose a Marketplace, public catalog, publishing workflow, or
remote installation service. Theme and card-template customization stays local.
Portable theme import and export move only files the user explicitly selects and
do not upload, publish, or install executable content.

### Public provider artwork

Provider logos use a dedicated public Cloudflare static-asset endpoint, separate
from authenticated Link traffic. Requests contain no account credentials,
conversation content, model selections, provider configuration or tracking IDs.
The app retrieves the complete approved artwork catalog regardless of the selected
provider. Cloudflare still receives ordinary connection metadata such as IP
address, timing and standard HTTP headers.

The client permits only the fixed HTTPS logo origin and validates relative,
content-addressed image paths. Redirects, oversized metadata/images, digest
mismatches and invalid PNG dimensions are rejected. HTTPS authenticates the
hosting origin; the manifest's SHA-256 values detect content mismatch, not a
compromised publishing account. Publishers control artwork only, never app code,
provider identities or model routing.

A bounded, replaceable cache of public images and catalog metadata lives in the
app's Caches directory, independent of account data and excluded from backups by
the operating system. Failed refreshes keep the last-good catalog; no cache uses
bundled artwork. Successful catalog withdrawal removes the remote override on
the next refresh, but cannot remotely erase copies on offline devices. Daily
refreshes and failure backoff limit traffic without background polling.

### Plugin catalog pictures

The Plugins storefront shows banner pictures and screenshots that a plugin's catalog
row links to. Lists (shelves, the official pick, See all and search results) load a
banner only for official and verified plugins. A community plugin's pictures are on a
server its author controls, so they load only on that plugin's own page, after the
person opens it. Pictures load like link previews: public HTTPS hosts only, no
cookies or credentials, size-bounded, shrunk to card size and kept in Caches for a
week.

### On-device voices

An agent can speak with Phonon on the iPhone or iPad instead of its computer's
speech provider (Settings › Voice). The model downloads only when someone picks
it, from a fixed GitHub Releases address, and is checked against a SHA-256 pinned
in the app and against each file's SHA-256 in the model's own list before it's
used. The request carries no account, conversation or agent data; GitHub still
receives ordinary connection metadata. The model lives in Application Support,
excluded from backups, until it's removed in Settings. Replies spoken with it
never leave the device for speech, and which agents use it stays on the device.

### Important limitation

End-to-end encryption protects content while it passes through bighelp's cloud
services. It cannot protect content on a compromised authorized device or
Hermes host. A configured provider may receive plaintext needed for the request.
Screen capture and visible Lock Screen content can also expose information.

It also does not hide traffic metadata such as IP address, timing, connection
duration, ciphertext size, or device-routing relationships from infrastructure
providers.

The routing service can still delay, suppress, or replay-invalid pairing
traffic, but it cannot substitute a different host key without failing the QR
commitment or separately displayed manual verification code.

## 4. Data inventory

| Data | On iOS device | bighelp Cloudflare | Hermes / providers |
|---|---|---|---|
| Messages and replies | Local session cache | Transient ciphertext only | Plaintext as needed to run the agent |
| Attachments | Local session cache; memory during upload | Transient ciphertext only | Plaintext as needed to process the request |
| Voice audio | Memory during on-device recognition | Not sent by bighelp | TTS voice: not sent as raw microphone audio. Full Duplex: streamed from the phone straight to the live voice provider the person picked (GPT-Live or Gemini Live) |
| Voice transcript | Local session cache | Transient ciphertext only | Plaintext as the user request |
| Synthesized speech audio | Memory during playback | Transient ciphertext only | Generated by the configured voice service |
| Agent instructions/settings | Local presentation cache | Transient ciphertext for workspace operations | Stored according to Hermes configuration |
| Device private/signing keys | Keychain | Never | Only keys generated by that endpoint |
| Account content key | Keychain | Encrypted envelope only | Present on authorized endpoints |
| Passkey biometric data | Apple authentication system | Never | Never |
| Passkey public credential | System-managed locally | Durable public metadata | Not required |
| Device name | Local | Authenticated ciphertext | Readable by authorized account endpoints |
| Device/public-key metadata | Local | Durable operational metadata | Used to authorize endpoints |
| APNs token | System/app memory and Keychain-related state | Encrypted at rest in relay storage | Not required |
| Alert title/body | Device after decryption | Encrypted payload | Created by the authorized source |
| Live Activity state | ActivityKit | Bounded state, encrypted at rest but readable during relay delivery and by Apple | Created from agent activity |
| Static Card document and embedded values | Local transcript cache | Transient ciphertext only | Generated and validated on the authorized Hermes host |
| Live Card source URL, response, and request metadata | Not accepted in build 3 | Not accepted in build 3 | Not accepted in build 3 |
| Preferences | UserDefaults | Not uploaded as preferences | Not required |
| Avatars | App sandbox | Filename metadata only through workspace flows | Image upload is not part of the current directory path |

## 5. Local storage

### Keychain

Private credentials use non-synchronizing, device-only Keychain items. They are
available after the first device unlock so background networking and
notification processing can operate.

Native Hermes credentials use their stricter existing
when-unlocked/device-only protection. Independent native hosts do not acquire a
bighelp account identity: their metadata, credential items and drafts are scoped
separately from optional cloud credentials. Cloud sign-out and account deletion
do not erase independent host authentication or legacy account-keyed Direct
sources awaiting verified migration. Those sources are not automatically exposed
to another account or adopted by matching an address. Explicit host removal
controls local Direct credential deletion; it is not remote token revocation.
Opaque provider/principal comparisons are byte-exact, not display-name equality.

The native workspace also owns separate protected content manifests, transcript
revisions, creation-intent journals and host-scoped preferences. Cloud erasure
does not erase these independent sources or reset their navigation. Native
session creation persists its bounded intent before every non-idempotent
mutation; a lost response remains uncertain across reconnect and cannot trigger
an automatic replacement session. Recorded historical tool evidence uses a
separate versioned cache and cannot imply a live or successful tool outcome.
Native connection leases reject stale results without closing the shared host
socket or switching to Link.

Ordinary native files stay local until Send. The complete batch is checked
before upload, then files are staged serially through the exact live session.
The app sends only the acknowledged `ref_text` references with the user's
caption. Confirmed references and uncertain attempts remain in the protected
submission journal; cancellation after the last upload does not authorize a
prompt, retry, or remote file deletion. Removing a local attachment does not
claim to remove an uploaded host file. Photos go through Hermes' own
`image.attach_bytes` (at most 8 MB each, 10 per message), which stages each one
on the exact live session before the prompt; the host keeps the picture in the
agent's images folder and the chat's history names it. Unsupported conversation
clients cannot advertise attachment support or silently send only the caption.

Photo actions ([Image drafts](IMAGE_DRAFTS.md)) never write on an upload. A
contact or event read from a picture is a draft until the person saves it in the
review; the host records only the draft's state and a hash of the approved
fields, never a second copy of them. Text inside a picture is data, never
instructions or consent. In a chat that holds a picture the person sent, or a
library photo the agent read there, the host and the phone both refuse the
agent's own `contacts.create` and `calendar.create` (`review_required`), so
standing Device access can't turn a picture into a new contact or event without
the person's review. Other phone tools keep their own switches and rules.

Signing out attempts a signed request to revoke this device and its push/Live
Activity authorization, then deletes bighelp Link runtime credentials,
notification recipient keys, sender-key pins, account-scoped defaults, local
content files, and all account-scoped in-memory state. Local erasure still runs
if the remote revocation is unavailable, and the app surfaces that revocation
could not be confirmed. Uninstall behavior alone should not be treated as
remote revocation.

The app stores the account and signing keys as software keys in device-only
Keychain items rather than as Secure Enclave private-key objects. A sufficiently
privileged compromise after the first unlock may expose them.

### App sandbox

Scratchpad text is an in-memory draft owned by the active account/host. Closing
the editor retains it for that running app session; switching owner or signing
out clears it. It is not a cross-launch saved document unless the user exports
it through the native Files picker. Sending to an agent only stages a Markdown
attachment in the explicitly selected session; normal Send is still required.

Image-paste providers are read only after an explicit Paste or Paste Image
action. Paste-menu availability uses an image-type query, not clipboard content.
Image data follows the existing bounded user-attachment preparation path; leaving
the composer or switching its model invalidates pending imports before staging.

The app stores readable session caches, drafts, attachments, Bot Mode history,
agent metadata, settings, and avatars in its private container. The JSON
repositories are versioned and crash-safe but do not add a separate
application-level encryption layer. JSON and attachment directories explicitly
use complete-until-first-user-authentication protection so background Link and
notification reconciliation can continue after the first unlock. Avatar files
and directories use complete protection and remain unavailable while locked.
Protected files and directories, including Link's pending encrypted transport
state and corruption recovery backups, are explicitly excluded from device
backups.

The pending encrypted Link frame and its sequence/acknowledgement state are
stored in protected Application Support JSON rather than backup-eligible
UserDefaults. Existing per-device UserDefaults snapshots migrate to this file
before their legacy keys are removed.

Anyone who can unlock or compromise the device may be able to read this local
content.

## 6. Cloud retention

The current Cloudflare deployment stores durable identity and delivery metadata
but no readable chat-session database.

- Passkey public records, account coordinates, and active device public keys
  remain while the account/device remains authorized.
- The service stores only hashes of access tokens.
- Authentication challenges and access sessions become invalid after expiry or
  consumption; immediate physical deletion of every expired row is not claimed.
- Encrypted frames waiting for an offline endpoint are removed after recipient
  acknowledgement or endpoint revocation. No independent time-based frame
  expiration was verified.
  The recipient overflow repair preserves these accepted obligations while
  permitting future copies to saturated recipients to be skipped before
  acceptance. It reserves recipient-local capacity rather than allowing one
  offline device to exhaust every device's budget. Fresh session recovery can
  restore only content actually stored by the host, not every skipped transient
  event. See [Legacy Link retention](LINK_RETENTION.md) for the policy, migration,
  ordering, and separately authorized rollout requirements.
- Push registrations persist while authorized or leased.
- Alert payloads are encrypted at rest and delivery records are pruned by the
  relay lifecycle.
- Revocation tombstones and idempotency metadata are retained only for
  consistency and replay protection.
- Aggregate counters do not contain prompts or replies.

Account deletion is available in the app and requires a fresh passkey assertion.
The Link service revokes every device push registration and Live Activity,
deletes the passkey account and device directory rows, closes active sockets,
and purges the per-account Durable Object. The service performs a second object
purge after deleting the account directory to close races with an already
authenticated request. The app removes its local account-scoped state only
after the service confirms deletion.

Logical deletion is not a guarantee that every infrastructure backup or
provider recovery copy is immediately physically unrecoverable. Cloudflare,
Apple, Hermes-host, model/tool provider, and backup retention remain subject to
their deployed policies and legal obligations.

The exact operational durations are intentionally not published here. They
should remain short, reviewed, and enforced automatically.

## 7. Apple services and permissions

| Permission/service | Why it is used | Privacy behavior |
|---|---|---|
| Camera | Pairing QR codes and optional Reflective Vision | Frames are not recorded or stored by the feature |
| Microphone | Voice conversation input | TTS voice: raw audio remains on device. Full Duplex: raw audio goes from the phone straight to the chosen live voice provider while the call is open, never through bighelp's services |
| Speech recognition | Convert speech to text | On-device recognition is required |
| Photos | Select profile and agent avatars | Images are processed and stored locally |
| Location (while using the app) | The agent's `iphone_location` tool, after you turn on Location for a host | Asked for when you turn the switch on; approximate unless you allow precise location for a call; sent to that host and its AI provider, never kept by bighelp |
| Face ID / device authentication | Passkey user verification | Biometric data is handled by the OS |
| Notifications | Agent alerts | Alert text is encrypted for the recipient device |
| Live Activities | Agent progress on Lock Screen/Dynamic Island | Shows bounded status plus session and agent labels |
| Local network | Connecting to an explicitly configured native Hermes host | Native-first workspace access still requires host authentication; HTTPS uses Apple trust, and policy-supported local HTTP requires explicit consent. Link is a separate optional connection |

Apple and network providers necessarily process delivery metadata such as IP
addresses, device tokens, app topics, timing, and service diagnostics according
to their own policies.

### bighelp Card requests

Build 3 makes no third-party Card data requests. Cards contain embedded values,
and both the Hermes plugin and iOS app reject nonempty `data_sources`. Opening a
Card therefore does not disclose the device IP, timing, URL, or query to a Card
source host. See [bighelp Cards](BIGHELP_CARDS.md) for the static release contract.

## 8. Privacy manifest

The app declares:

- Tracking: **false**
- Tracking domains: none
- Collected data: a linked device identifier used for app functionality
- Required-reason API use: preferences and elapsed-time measurement

bighelp does not declare user content as collected by its cloud because the
current deployed frame-routing path receives authenticated ciphertext, has no
frame-decryption operation, and does not retain a readable session store. This
classification depends on the documented key-establishment design. Review it
with qualified privacy counsel before release.

This conclusion must be revisited if any of the following changes:

- Cloud code gains a content-decryption key
- Pairing or sender-key provisioning changes the documented trust assumptions
- Message, transcript, attachment, or prompt content is logged
- Readable content is added to D1, Durable Object, KV, R2, Analytics, or queues
- Retention expands beyond real-time delivery needs
- A third-party telemetry or customer-support SDK is added
- Live Activity state begins carrying unrestricted user content

## 9. Live Activity and Lock Screen privacy

The app supplies Live Activities with a sanitized projection. It maps tool names
to generic categories, limits text, and excludes prompts, arguments, attachments,
and complete model output.

The session title, agent name, and progress state can still be visible on the
Lock Screen. Users who require shoulder-surfing protection should disable Live
Activities or notification previews in iOS settings.

## 10. Logging and telemetry

Native Workspace management retains its bounded read models and text previews
only in memory under the selected host/profile owner. Credential catalogs show
presence without raw or redacted values; explicit replacement uses a write-only
editor and is never persisted by that feature. Log bodies are withheld from the
mobile UI. Native managed file responses must prove an unchanged, explicitly
configured confined root; default host-home enumeration is not used as a probe.
The optional canonical plugin Files adapter instead requires verified serving-profile
identity and host-local grants, rechecks its catalog across navigation, and validates
revision-bound pages and full-file hashes. Those grants are shared by authenticated
clients of the serving profile, not per-device ACLs. No generic filesystem, config, secret-reveal, process
control or raw-microphone-upload surface is added.
See [Workspace management](WORKSPACE_MANAGEMENT.md) for the exact feature scope.

Native Wiki recovery records distinguish authenticated Hermes endpoint/provider/
principal/profile ownership from legacy Link device ownership. The bounded
native principal coordinates are held in protected local Wiki state; no token,
password, device enrollment, or account content key is introduced. Its storage
namespace cannot overlap a legacy Link account namespace. Legacy Link encoding
and local recovery filenames remain unchanged. Current transport authorization
is checked separately from the stable persisted principal identity.

Read-only native Project Changes uses the canonical plugin's registered
Project/session checks and existing safe Git engine. It does not infer
authorization from Files grant labels or expose caller-selected host paths.
Diffs and preview content are bounded, remain in feature memory, and are not
sent to new analytics or cloud endpoints. The content token is an optimistic
before/after check, not an immutable filesystem lease; this adapter cannot stage,
commit, fetch, pull, push or execute commands.

The iOS app includes no analytics, advertising, crash-reporting, or behavioral
tracking SDK. Production code must not log:

- Credentials or private keys
- Passkey assertions
- APNs tokens
- Account or device authorization material
- Plaintext prompts, responses, attachments, or decrypted notifications
- Full server error bodies

Cloudflare platform logs and Apple service logs may contain provider-level
network and delivery metadata. Operators should keep application logging
redacted and minimize retention.

## 11. Security limitations

- This project makes no claim of an independent third-party security audit.
- The custom protocol depends on correct implementation at both iOS and Hermes
  endpoints.
- A compromised authorized endpoint can read account content.
- A compromised device after unlock can read local caches.
- Manual pairing relies on the user comparing the host's separate 16-character
  verification code; QR pairing carries the full key commitment.
- The account service provisions notification sender trust. No separate
  transparency or continuity system verifies it.
- E2E content encryption does not provide anonymity or hide traffic patterns.
- Availability depends on Cloudflare, APNs, the Hermes host, configured
  providers, and Apple services used by enabled features.
- Live Activity state is privacy-reduced, not equivalent to the encrypted alert
  channel.
- Independently authenticated native Hermes is selected by production composition
  for its own workspace. Its native API, authentication and Apple-networking
  acceptance are separate from Link validation; neither proves the other.

## 12. Export and legal review

The app implements cryptographic operations using Apple's CryptoKit and
Security frameworks and declares that it does not use non-exempt encryption.
That setting may be appropriate for system-provided, standard cryptography, but
export classification depends on distribution, functionality, and current law.
Confirm it through Apple's current export-compliance process and, when needed,
with qualified counsel. This documentation is not an export determination.

Report suspected vulnerabilities privately using the process in
[`SECURITY.md`](../SECURITY.md).

## Explicit Wiki folder setup

Saving Add Wiki authorizes a safe existing host folder for the current authenticated device/profile through the separately negotiated `wiki.connect` operation. New grants are read-only; a typed suggestion alone grants nothing. Filesystem traversal, symlink ancestors, sensitive and system roots, the configured Hermes control home, and Wiki state are excluded. The operation cannot adopt, overwrite or bypass overlapping grants held by another device/profile/pairing authority. Existing grants retain their generation and policy; new grants receive a fresh generation. Host-local grant/revoke administration remains separate.

Authorized Wiki metadata can disclose the chosen absolute source folder over the existing account-wide encrypted Link. When a page or section is explicitly referenced, its full source path accompanies the selected snapshot as bounded JSON metadata and follows normal chat/model-provider disclosure. Visible tags use the title. Other holders of the account key may decrypt this traffic. Path metadata is absent on older hosts and is not inferred from a display name.

## Group presentation preferences

The Agents screen keeps pinned and archived group preferences locally on this
device, scoped to the authenticated workspace. Archiving here hides the group
from the active Agents list; Archived groups can restore it. This does not stop
Hermes work or delete its transcript. Account-data erasure clears these
preferences. Delete is a separate confirmed action through Hermes' native
`groups.disband` operation, which stops the room and permanently retires its ID.
