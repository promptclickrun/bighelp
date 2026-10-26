# Optional notifications and activity delivery

This is the client contract for optional Hermes notification delivery, including the parts an Android client can reuse. Native chat connects directly to Hermes and needs no bighelp account, notification installation, cloud pairing, push token, or notification permission. A delivery failure must not prevent opening, recovering, or sending a chat.

The reference app revision is `09fc79c01aed91734e8006b5355209a31c52feca`. Host route details were cross-checked against the read-only companion plugin revision [`7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf`](https://github.com/promptclickrun/bighelp-plugin/tree/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf). Capability and response validation, rather than a Hermes or plugin version comparison, decides what is available.

The app's composition and cloud background are described in [ARCHITECTURE](../ARCHITECTURE.md#notifications), [NATIVE_TRANSPORT](../NATIVE_TRANSPORT.md#optional-delivery), and [SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md). Some encrypted-alert prose in those broader documents describes the earlier relay-signed format. The managed sealed-alert v2 format documented below is **host-signed**, with the recipient public key sent directly to the host. Its source and shared vector define this format.

## Authorities and platform boundaries

Keep these credentials and coordinates separate:

| Authority | What it permits | Where it goes |
| --- | --- | --- |
| Native Hermes sign-in and principal | Access to this exact configured Hermes host and its authorized profiles/sessions | The selected host origin only, using its ordinary native authentication |
| Notification installation signing key | Notification-only service operations for this install and authorization epoch | `https://link.loopdy.app` only |
| Host notification signing key | Claiming grants and signing sealed alerts for that host | Public key is read from the authenticated host; private key stays on the host |
| Sealed-alert recipient key | Decrypting alert content for this device | Private P-256 key stays on device; public point goes directly to the host |
| Push provider registration | Delivery to a particular device | Platform/provider adapter; no sending secret is supplied to the host |

`BighelpHostNotificationBinding` is `{deviceID, authorizationEpoch}`. Its local scope is the lowercase hexadecimal `SHA256(UTF8(deviceID + ":" + decimal(authorizationEpoch)))`. Enrollment ledger ownership includes that scope, the configured host's local connection UUID, and profile. The grant's `instanceId` is the lowercase form of that local connection UUID; it is not the installation ID or a server runtime ID.

Every asynchronous operation rechecks the current installation credentials, epoch, binding, configured host, native principal and endpoint. A chat subscription additionally proves that the opened chat belongs to that exact native workspace authority. A response from a replaced host, old principal, old profile, or retired binding cannot publish state. A grant cannot migrate to another configured host merely because an address or public key matches. Changing delivery enrollment does not alter native credentials, the selected workspace, or native submission journals.

See [host registry](../../Bighelp/Hosts/BighelpHostRegistry.swift), [credential/owner checks](../../Bighelp/Notifications/BighelpManagedNotificationService.swift), [ledger](../../Bighelp/Notifications/BighelpManagedNotificationLedger.swift), and [factory hooks](../../Bighelp/Notifications/BighelpManagedNotificationFactory.swift).

The host APIs, grant checks, sealed bytes and foreground listener can be implemented in Kotlin/Java. The current reference service/provider readiness contract is for **Apple push**, and ActivityKit is an Apple presentation API. This repository does not establish an Android/FCM token-registration or background-delivery contract. Do not send an FCM token to the APNs `push-target` route or treat an Android registration as satisfying `activeIOSPushEnvironments`. An Android background delivery path needs an explicitly supported provider/service adapter and its own readiness proof. The foreground listener still requires an active enrollment; it is not an enrollment bypass.

## Explicit enrollment and recovery

Enrollment starts from the person's Enable action. Opening a chat, opening Settings, restoring metadata, or starting the app is not permission to create a new grant, widen its event types, or request notification permission. Existing enrollments may recover in the foreground independently of chat.

The reference flow is:

1. Create or recover a notification-only installation. Save a pending bootstrap intent and signing key before sending it. Bind the install/epoch to the selected native host without changing native identity.
2. Identify with the delivery provider, request OS notification permission, register this device, and read back provider readiness for this attempt's exact registration. In the current app this is BuzzKit/APNs; installed plugin metadata and an old registration receipt are insufficient.
3. Read authenticated host `GET /notifications/capabilities`. Validate its key, require `managedEnrollmentSupported`, and require all eight event types below. A 404 here is a missing running backend route (`backendRestartRequired`), not proof of enrollment.
4. Reconcile pending removals and list this installation's service grants. Reject ambiguous matches and host-key changes. An explicit enable may replace an expired or obsolete partial grant, after revocation and readback.
5. Freeze a version 3 grant-creation body and its idempotency key to durable local storage **before** the service mutation. On an unknown outcome retain and reuse the exact bytes; do not invent another key. The reference request expires in 30 days.
6. Save the validated grant, then give only its ID and a separately persisted enrollment idempotency key to the host's `/enroll`. Require an `active` grant with the same authority, then GET the enrollment and require an identical readback before marking it enabled.
7. If `sealedAlerts.version == 2`, pin the grant's host signing key locally before registering the device's content public key. This allows an alert sent immediately after registration to open safely. Require the returned key ID to match the local key.
8. Synchronize supported preferences and Quiet Hours. Subscribe an already-open chat only after checking its native owner; later chat openings use the same hook. These delivery hooks run separately from chat opening/sending.

See [setup state machine](../../Bighelp/Hosts/HostNotificationSetup.swift), [enrollment implementation](../../Bighelp/Notifications/BighelpManagedNotificationService.swift), [notification identity](../../Bighelp/Notifications/BighelpNotificationIdentity.swift), [provider readiness](../../Bighelp/BuzzKit/BighelpBuzzKitRuntime.swift), and [managed service tests](../../BighelpTests/ManagedNotificationServiceTests.swift).

The complete immutable event set is:

```json
["approval.required","clarification.required","scheduled.completed","scheduled.failed","session.completed","session.failed","subagent.completed","subagent.failed"]
```

A grant covers one agent profile, including that profile's chats that this device has not opened. Per-session subscription rows remain explicit opt-ins; approval delivery uses them. They are not a general chat-access or profile-wide notification authorization mechanism.

For removal, stop local use and remove sender trust immediately, while durably retaining cloud revocation and host-cleanup intent. Revoke the service grant with its expected revision and confirm it in service readback; delete the host enrollment too. Offline removal can leave cleanup pending. Turning notifications off revokes the installation and its grants. Neither operation deletes native chats or signs out the host. See the [removal/reconciliation implementation](../../Bighelp/Notifications/BighelpManagedNotificationService.swift) and [ledger migration tests](../../BighelpTests/ManagedNotificationLedgerMigrationTests.swift).

## Host HTTP transport

For this section, `N = /api/plugins/loopdy/notifications` on the configured Hermes dashboard origin. The `/notifications` routes use Hermes' authenticated plugin router, not a bighelp account bearer. They do **not** use the native-context `If-Match` protocol; `/native/…` routes in the later sections do.

[DirectHostNotificationClient](../../Bighelp/Hosts/DirectHostNotificationClient.swift) restores a fresh authenticator from the exact host credential vault for each operation. It persists an allowed native credential rotation only if the original vault value and principal are still current. It does not replace newer chat credentials with a retained notification snapshot or automatically replay a write whose outcome is unknown. Use the same origin, TLS, redirect and proxy-header rules as native host transport.

The client admits `GET`, `POST`, `PUT`, `DELETE`, caps ordinary request and response JSON at 262,144 bytes, requires an object with integer `version: 1` on success, and checks HTTP status first. A plugin refusal can be `{"detail":{"code":"notification_enrollment_inactive"}}`; preserve the bounded machine code and status. Do not assume error bodies carry a success `version`.

Host request bodies reject unknown fields. Send JSON booleans and integers with their actual types. UUIDs are lowercase canonical UUIDs (versions 1–5 and RFC variant). Profiles match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. The companion route schema for `sessionId`, optional `turnId`, and activity IDs is `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`; the app's generic coordinate reader is broader (up to 180 bytes), which does not widen the host's accepted request schema. `sessionReference = base64url(SHA256(UTF8(profile + NUL + storedSessionId)))`, a 43-character string.

### Capabilities and enrollment

`GET N/capabilities` has no body. Current result:

```json
{
  "version": 1,
  "hostKeyId": "fV1kKKcy5hugjZOa4lMSYnzD1a1KIxxI4GLKeX4JIOQ",
  "hostPublicKey": "BK8QBhGFijYF2Ww_Rj0wluWpOz4t03RI-aQZuP4RdxYZr08nIdgQIyPQNZbD4Mh-1ZYsZu22YgFzMD6dxzOTHro",
  "managedEnrollmentSupported": true,
  "supportedEventTypes": ["approval.required","clarification.required","scheduled.completed","scheduled.failed","session.completed","session.failed","subagent.completed","subagent.failed"],
  "richLiveActivitySupported": true,
  "producerCapabilities": {"sessionCompletion":true,"sessionFailure":true,"richLiveActivity":true,"nativeApproval":true,"nativeClarification":true},
  "sealedAlerts": {"version":2},
  "preferences": {"peerChats":true,"workflows":true,"scheduledLinks":true,"channels":true}
}
```

The key above is a public test-vector key. Actual `producerCapabilities` booleans report producers loaded in the running process; they are not inferred from installation status. `supportedEventTypes`, `richLiveActivitySupported`, `sealedAlerts`, and `preferences` are optional in the app decoder. Missing support remains unavailable; absent `richLiveActivitySupported` falls back to `producerCapabilities.richLiveActivity`. Only sealed version 2 is recognized. Require a valid 65-byte uncompressed P-256 public point and `hostKeyId = base64url(SHA256(pointBytes))`.

| Method/path | Exact request fields | Successful result fields |
| --- | --- | --- |
| `POST N/enroll` | `version:1`, `idempotencyKey:UUID`, `grantId:UUID` | `version:1`, `grant:Grant` |
| `GET N/enrollments/{grantId}` | No body | `version:1`, `grant:Grant` |
| `DELETE N/enrollments/{grantId}` | No body | `version:1`, `state:"removed"`, `grantId` |
| `PUT N/enrollments/{grantId}/recipient-key` | `version:1`, `publicKey`: canonical base64url of a valid 65-byte uncompressed P-256 agreement public point (87 characters) | `version:1`, `recipientKeyId`: base64url SHA-256 of that public point |

Host enrollment claims the service grant using the host's own signing key. Host GET rechecks service authority and removes local enrollment if its remote grant is forbidden, missing, or different. Host DELETE removes local delivery state, including recipients and queued alerts; it does not by itself prove service revocation.

`Grant` is the public authority object in [managed models](../../Bighelp/Notifications/BighelpManagedNotificationModels.swift):

| Field | Type and checks |
| --- | --- |
| `grantId` | Lowercase UUID |
| `instanceId` | Optional UUID for legacy account grants; required for `notification-instance`; new enrollment must equal this configured host's local connection UUID in lowercase |
| `hostKeyId`, `hostPublicKey` | SHA-256 key ID and canonical base64url uncompressed P-256 point; must match authenticated capabilities and any existing pin |
| `authorizationEpoch` | Positive integer; must equal current installation epoch |
| `profile` | Profile identifier; must equal enrolled profile |
| `eventTypes` | Unique, nonempty subset of the eight recognized types; current enrollment requires the entire set |
| `createdAt`, `expiresAt` | Integer Unix seconds; `createdAt > 0`, `createdAt < expiresAt <= 9999999999`, lifetime at most 2,592,000 seconds; usable grant must be unexpired |
| `revision` | Integer in `1…9007199254740991`; optimistic revocation coordinate |
| `provider` | `"buzzkit"` in this schema |
| `subscriberScope` | `"notification-instance"` for new enrollment; `"account"` accepted only for legacy model compatibility |
| `state` | `"issued"`, `"active"`, or `"revoked"`; enabled enrollment requires `"active"` |

Grant equality of authority includes every field except `state`; event type order is immaterial. Host claim must preserve that authority and return `active`. The following GET must match the claimed object, including state. A grant envelope is exactly `{version, grant}`, and list envelope exactly `{version, grants}`; lists are limited to 256 unique grant IDs by the app.

### Sessions, preferences and event readback

| Method/path under `N/enrollments/{grantId}` | Request | Successful result |
| --- | --- | --- |
| `PUT /sessions` | `{"version":1,"profile":"juno","sessionId":"session_example","enabled":true}` | `version:1`, `grantId`, `profile`, `sessionId`, computed `sessionReference`, `enabled` |
| `GET /preferences` | No body | `version:1`, `peerChats:boolean`, `workflows:{needsYou,succeeded,failed,cancelled}` (booleans), `scheduledLinks:boolean`, `channels:{other:boolean,choices:{channel:boolean}}` |
| `PUT /preferences` | `version:1`, required `peerChats:boolean`; optional `workflows`, `scheduledLinks`, `channels` in the GET shapes | Same fields as GET; confirm every preference sent before recording success |
| `GET /channels` | No body | `version:1`, `profile`, `channels:[{"id":"telegram","name":"Telegram"}]` |
| `GET /events/{eventId}` | No body | `version:1`, `event:EventDetail` |

Subscription success must echo the exact grant/profile/stored session, computed reference and enabled value while the chat and grant remain current. Disabling a session removes that session's pending alerts and activity registrations. The reference app subscribes only after a chat has actually opened or recovered; opening a cached screen alone is insufficient.

Preference fields are advertised separately in capabilities. Peer chats start off. All four workflow kinds start on. Scheduled links start off and are enabled only by clients that understand their navigation. Channels start with `{"other":true,"choices":{}}`; up to 64 channel choices override `other`. `bighelp` always alerts and cannot appear as a channel choice. Channel IDs use lowercase ASCII letters/digits, `_` or `-`, start with a letter/digit and are 1–40 characters; the host also rejects source aliases that map to another channel (such as `cli`). App display names are nonempty and at most 40 characters. The app merges at most 64 channels across hosts.

An event ID is `<grantId>:<64 lowercase hex digits>`. Its digest is a stable host event identity; do not recompute it from displayed text. The event detail shape is:

```json
{
  "version": 1,
  "event": {
    "eventId": "0f8b5d2e-3c4a-4b6e-9d1f-2a3b4c5d6e7f:47422196208f67c40d2aa342978e9212de651bbd9d22b9d8f87bc7776a55e3ed",
    "eventType": "session.completed",
    "profile": "juno",
    "sessionId": "session_example",
    "turnId": "turn_example",
    "occurredAt": 1800000000,
    "agent": {"id":"juno","name":"Juno","avatarSha256":"785b0751fc2c53dc14a4ce3d800e69ef9ce1009eb327ccf458afe09c242c26c9"},
    "content": {"kind":"reply","text":"Your flight is booked."}
  }
}
```

Notification coordinates are routing hints until checked against the local active grant and native host. For authenticated readback, require matching event ID/type/profile, valid session/turn coordinates, `agent.id == profile`, nonempty agent name at most 80 UTF-8 bytes, a lowercase 64-hex avatar hash, and nonempty content at most 1,600 characters. `occurredAt` must be at least the grant's creation and at most `min(now + 120, grant.expiresAt)`.

Expected content kinds are `approval` for `approval.required`, `clarification` for `clarification.required`, `scheduled` for `scheduled.*`, `subagent` for `subagent.*`, `failure` for `session.failed`, otherwise `reply`. Resume only the verified host/profile/session using ordinary native session loading; this endpoint supplies no chat credentials or alternative chat transport.

Special references have navigation meaning: workflow alerts use `workflow.run.<runId>`; clients opting into scheduled links can receive `scheduled.chat.<sessionId>` or `scheduled.job.<jobId>`. Scheduled event identity still names the task run. Its routing reference must remain separate from that chat's own reply reference, because the task output is not in that chat. See [scheduled alert links](../../Bighelp/Notifications/BighelpScheduledAlertLinks.swift) and [notification navigation](../../Bighelp/Notifications/BighelpManagedNotificationNavigation.swift).

### Host provider metadata

`GET N/provider` is a safe host metadata route, not provider registration or a readiness proof for this device. The reference app's setup reads capabilities and service readiness instead. Current host result fields are `version:1`, `provider:"buzzkit"`, `subscriberScopes:["notification-instance","account"]`, `preferences:"buzzkit-topics"`, `richContentRequired:true`, `serverSendingAuthorityOnHost:false`, `eventTypes`, `maximumAvatarBytes:524288`, `maximumTextCharacters:1600`, and `topics`:

```json
{
  "chat-replies-completions": ["session.completed","session.failed"],
  "scheduled-tasks-deliveries": ["scheduled.completed","scheduled.failed"],
  "questions-approvals": ["approval.required","clarification.required"],
  "subagent-completions": ["subagent.completed","subagent.failed"]
}
```

No subscriber identity, provider sending key or Apple key comes from this route. Host schemas and result implementations are in the pinned plugin's [managed API](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/loopdy_plugin/managed_notifications_api.py) and [managed notifications](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/loopdy_plugin/managed_notifications.py).

## Quiet Hours on the host

This route is under `P = /api/plugins/loopdy/native`, rather than `N`. Load `GET P/context`, verify its native principal/owner, and require feature `native-notification-quiet-hours-v1`. Send `POST P/notifications/quiet-hours` with that context's `If-Match` ETag and a fresh lowercase UUID `X-Loopdy-Request-ID`:

```json
{"grantId":"0f8b5d2e-3c4a-4b6e-9d1f-2a3b4c5d6e7f","enabled":true,"startMinute":1320,"endMinute":420,"timeZone":"America/Denver"}
```

The request has exactly those five fields, no `version`. `startMinute` and `endMinute` are integers 0–1439. `timeZone` is a valid IANA zone, 1–64 bytes using letters, digits, `+`, `-`, `/`, `_`; the app falls back to `UTC` when its local identifier cannot be represented. Success:

```json
{"version":1,"grantId":"0f8b5d2e-3c4a-4b6e-9d1f-2a3b4c5d6e7f","quietHours":{"enabled":true,"startMinute":1320,"endMinute":420,"timeZone":"America/Denver"},"quietNow":false}
```

Require the echoed request ID and exact grant/window/time-zone readback. Native context and this request/response are capped at 16,384 bytes in the reference notification client. A 412 reloads context and retries once; a missing context route or missing feature is `featureUnavailable`. Unknown outcomes do not justify an unbounded replay loop.

The host checks the device's local clock in that zone just before sending, including daylight saving transitions. Start is inclusive, end exclusive; an overnight window uses `minute >= start || minute < end`. Equal times mean an empty window, not all day. All alert kinds are skipped during Quiet Hours, including foreground instant alerts, approvals and clarifications. Skipped alerts are never replayed after the window. Live Activity updates and silent sign-in wakes are unaffected.

The reference app saves a confirmed copy, sends only changes, and retries failed synchronization on later chat openings or settings changes. A host that lacks the feature does not block enrollment. See [Quiet Hours model](../../Bighelp/Notifications/BighelpQuietHours.swift), [sync implementation](../../Bighelp/Notifications/BighelpManagedNotificationService.swift), and [boundary/time-zone tests](../../BighelpTests/QuietHoursTests.swift).

## Foreground instant alerts

`BighelpLiveAlertListener` long-polls the authenticated host while the app is open. It receives the same sealed alert that a push would carry, then acknowledges alerts it showed or intentionally kept quiet. The host does not learn which chat is visible.

Require `native-live-alerts-v1` in the current `P/context`. All routes below are POST JSON with `If-Match` and a fresh `X-Loopdy-Request-ID`, and successful responses echo the request ID. They have no top-level `version`. Each grant entry is exactly `{grantId, recipientKeyId}`; use 1–8 entries for active, unexpired, enabled grants whose recipient key is registered and whose host sender pin is present. The host verifies the grant/key pairing. Use one listener UUID for a run; a newer listener takes over the grants from the older one.

| Path under `P` | Request fields | Result fields |
| --- | --- | --- |
| `/alerts/listen` | `listenerId:UUID`, `grants:[{grantId,recipientKeyId}]`, `waitSeconds:0…25`, optional `knownAvatars:[plaintext SHA-256 hex]` (at most 32; app sends it) | `alerts:[LiveAlert]`, `grantIds:[UUID]`, `ackWindowMilliseconds:1000` |
| `/alerts/ack` | `grants`, `eventIds:[eventId]` (1–32) | `settled:[eventId]` |
| `/alerts/stop` | `listenerId`, `grants` | `stopped:true` |

Example listen body:

```json
{"listenerId":"ce001bc8-9665-4dc9-bc09-1c4ff6ff9453","grants":[{"grantId":"0f8b5d2e-3c4a-4b6e-9d1f-2a3b4c5d6e7f","recipientKeyId":"6ayoB-tYsoMf-GBljov-hUad6MoQyusYpy1C9WR3kpY"}],"waitSeconds":25,"knownAvatars":[]}
```

`LiveAlert` fields are `grantId`, `agentId` (profile identifier), `eventId`, `eventType`, `sessionReference`, `turnId`, `occurredAt`, `sealed` (the v2 envelope below), and `avatar:{sha256,data?}`. Here `avatar.sha256` hashes the **encrypted** image blob, whereas `knownAvatars` contains plaintext image hashes. Optional `data` is `data:application/octet-stream;base64,` followed by ordinary base64 of that encrypted blob. The host sends it only for unknown pictures that fit (393,216 data-string characters maximum). Push delivery can supply an HTTPS avatar URL instead.

The app requires a known event type, exact grant-prefixed event ID, valid agent ID and 43-character reference, and matching `sealed.eventId`/`sealed.grantId`. It processes only alerts for the grants in this listen and at most eight per answer. Decrypt and verify before showing or deliberately suppressing an alert. A decryption or display failure receives no ack, allowing push fallback. Already-shown events, disabled kinds, and a visible chat can be deliberately suppressed and acknowledged. Deduplicate by stable event ID across listener and push paths; a late push must not show a second banner. See [listener/presenter](../../Bighelp/Notifications/BighelpLiveAlerts.swift), [grouping/presentation](../../Bighelp/NotificationShared/BighelpSealedAlertPresentation.swift), [visible-chat tracking](../../Bighelp/Notifications/BighelpVisibleChats.swift), and [listener tests](../../BighelpTests/BighelpLiveAlertTests.swift).

The host offers an alert for one second from availability, not one second from client receipt. An ack settles only alerts not already claimed by the push sender. A lost/late ack may therefore still produce a push; the client cannot promise delivery cancellation from its local ack attempt. The reference app ignores ack failures and immediately listens again. A listen returns up to eight alerts, bounded to about 1,000,000 bytes; the app transport accepts up to 1,048,576 bytes and gives the call 40 seconds. Ack/stop accept 16,384-byte responses and use 5-second timeouts.

Listen again after success, including an empty result. The host lease covers the requested wait plus 10 seconds and is shortened to a 10-second grace between responses. Send `/stop` when leaving the foreground so future alerts push immediately; expiry/disconnect also permits fallback. The app uses 25-second waits, reducing to 8 after a long request is cut off after at least 10 seconds. It backs off `1,2,4,8,16,30` seconds plus up to 20% jitter on successive failures; one context conflict retries immediately. Missing support or `live_alerts_not_enrolled` waits 300 seconds, `live_alerts_busy` waits 60 seconds. Host error codes are 404 `live_alerts_not_enrolled`, 429 `live_alerts_busy` (32 live grants host-wide), and 503 `live_alerts_unavailable`.

## Sealed-alert v2: portable cryptography

Source: [Swift opener](../../Bighelp/NotificationShared/BighelpSealedAlerts.swift), [canonical base64url](../../Bighelp/NotificationShared/BighelpRelayTrust.swift), and pinned plugin [sealer](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/loopdy_plugin/sealed_alerts.py). Do not substitute the earlier relay envelope, service request signatures, SPKI public-key representation, or a platform push wrapper for this format.

All binary envelope fields use canonical unpadded base64url (`A–Z a–z 0–9 _ -`, no whitespace or `=`); decode and re-encode must reproduce the input. Hashes called hex are lowercase. Keys are P-256 / `secp256r1`. Public points are SEC1/X9.63 uncompressed `0x04 || X[32] || Y[32]` (65 bytes), validated as curve points. `keyId(point) = base64url(SHA256(point))` (43 characters).

### Envelope schema

The sealed object has **exactly** these 12 keys; reject added or missing keys:

| Field | Type / decoded size |
| --- | --- |
| `v` | Integer `2` |
| `grantId`, `eventId`, `recipientKeyId`, `senderKeyId` | Nonempty single-line strings, at most 256 UTF-8 bytes each; delivery layer further validates coordinates |
| `issued` | Positive integer Unix seconds |
| `ephemeralPublicKey` | Canonical base64url, 65-byte valid P-256 point |
| `salt` | Canonical base64url, 32 bytes |
| `nonce` | Canonical base64url, 12 bytes |
| `ciphertext` | Canonical base64url, 1–4,096 bytes accepted by the app parser |
| `tag` | Canonical base64url, 16 bytes |
| `signature` | Canonical base64url, 64-byte IEEE P1363 ECDSA `r[32] \|\| s[32]`, big-endian |

The sender targets a serialized envelope of at most 2,300 bytes so it fits in a push with routing metadata; it shortens the body when needed. The parser's larger ciphertext cap is not permission for a producer to exceed that push budget.

Opening uses these exact byte operations (`UTF8`, no trailing newline in either joined string):

```text
AAD = UTF8(join("\n", [
  "loopdy-sealed-alert-v2", grantId, eventId,
  recipientKeyId, senderKeyId, decimal(issued)
]))

signatureInput = UTF8(join("\n", [
  "loopdy-sealed-alert-signature-v2", hex(SHA256(AAD)),
  base64url(ephemeralPublicKey), base64url(salt), base64url(nonce),
  base64url(ciphertext), base64url(tag)
]))

sharedSecret = ECDH_P256(recipientPrivateKey, ephemeralPublicKey)
info = UTF8("loopdy-sealed-alert-key-v2") || 0x00 || SHA256(AAD)
aesKey = HKDF_SHA256(IKM=sharedSecret, salt=salt, info=info, length=32)
packed = AES_256_GCM_DECRYPT(aesKey, nonce, ciphertext || tag, AAD)
plaintextBytes = RAW_DEFLATE_INFLATE(packed)
```

Verify ECDSA P-256/SHA-256 over `signatureInput` using the **pinned host public key** before ECDH/decryption. ECDH yields the fixed-width 32-byte shared secret. HKDF uses the raw SHA-256 digest in `info`, not its hex or base64 encoding. Java providers that expect DER ECDSA signatures must convert `r||s` correctly or use a P1363-aware verifier; do not treat the 64 bytes as DER. Likewise, the compressed data is **raw DEFLATE** (Python `wbits=-15`, Java `Inflater(true)`), without a zlib/gzip header, despite Apple's decompression API naming it `.zlib`.

The plaintext is UTF-8 JSON. The sender uses sorted keys, compact separators, literal Unicode and no nonfinite numbers. The content schema is:

```json
{"v":2,"eventId":"0f8b5d2e-3c4a-4b6e-9d1f-2a3b4c5d6e7f:47422196208f67c40d2aa342978e9212de651bbd9d22b9d8f87bc7776a55e3ed","eventType":"session.completed","title":"Juno","body":"Your flight is booked.","avatar":{"mimeType":"image/png","sha256":"785b0751fc2c53dc14a4ce3d800e69ef9ce1009eb327ccf458afe09c242c26c9","cipherSha256":"d5821545b4a99d79d92a9cca79b7190e1ad28cb848c3f6f345667cc32ddcacd8","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","nonce":"ZGVmZ2hpamtsbW5v"}}
```

This example illustrates the schema; use the unchanged fixture below for cryptographic verification. `avatar` is optional in the content decoder. Require `v == 2`, matching envelope `eventId`, and nonempty title/body. The app limits packed bytes to 16,384 and decompressed JSON to 65,536 bytes; enforce bounds while inflating in a portable implementation. The decoded content `eventType` must match the outer event type.

The notification wrapper's `loopdy` object carries `version:2`, `grantId`, `eventId`, `eventType`, `sealed`, and optional routing/image fields (`agent:{id}`, `sessionReference`, `avatar:{url}`). The foreground listener constructs the same `loopdy` coordinates locally. Wrapper `eventId` and `grantId` must match the sealed object. Never trust a sender key supplied by a push: resolve the local sender pin by grant ID, require the sender key ID to match it, require that pin unexpired at the current time, and require `issued <= pin.expiresAt`. Require the recipient key ID to match this device's public key. The current sealed opener does not impose an additional maximum alert age; deduplication and event-routing validation are separate checks. On any parse, trust, signature, recipient, decompression or AEAD failure, show at most a generic fallback; never display unverified text.

### Encrypted avatar

`avatar.key` decodes to an independent 32-byte AES key and `avatar.nonce` to 12 bytes. They are carried **inside** the sealed content. The image blob is `ciphertext || tag[16]`:

```text
avatarAAD = UTF8("loopdy-sealed-avatar-v2\n" + grantId + "\n" + avatar.sha256)
require hex(SHA256(blob)) == avatar.cipherSha256
image = AES_256_GCM_DECRYPT(avatar.key, avatar.nonce, blob, avatarAAD)
require hex(SHA256(image)) == avatar.sha256
```

The host reuses a per-grant/per-image key and nonce only for that identical image, producing an identical blob. A client accepts only authenticated image bytes; never use outer hash/URL as image authenticity. The reference renderer accepts PNG, JPEG or WebP, tries a hash-checked plaintext cache before inline bytes/download, and retains the newest 32 images. Its HTTPS download has a 12-second timeout and a 2,000,000-byte cap; instant-alert inline parsing has its own 1,048,576-byte cap. Avatar failure can leave the verified text visible without an attachment.

### Shared conformance vector

Use [sealed-alert-v2-vector.json](../../BighelpTests/Fixtures/sealed-alert-v2-vector.json) verbatim with [BighelpSealedAlertTests](../../BighelpTests/BighelpSealedAlertTests.swift). It includes test-only recipient private/public keys, sender public key, envelope, expected plaintext, encrypted avatar and expected image. The companion [fixture](https://github.com/promptclickrun/bighelp-plugin/blob/7e1f74ff26c1c36dd6bb7d2da3c19d6a44c3fdaf/fixtures/contracts/sealed-alert-v2-vector.json) is byte-identical. It tests opening, rather than deterministic ECDSA signature production.

Useful independent checkpoints derived from that unchanged fixture:

| Value | Expected |
| --- | --- |
| Fixture file SHA-256 | `c8663ef57c2a80718b3008a06f3c40352b24b57d2eaef1a2478e89b1de467b5e` |
| `SHA256(AAD)` | `9e3626a17a994941e1587983129bf005da01b5aacf09c22c2623d405689f1bdc` |
| `SHA256(signatureInput)` | `532009c5cfd3da6212ec189170414076493f03fafbeb24127e86bab34a0bbd08` |
| ECDH shared secret, hex (test key only) | `7f8178ff8220c57f4cb88f9e412b9f4b459f1c318aca049c9692a27d44e928df` |
| Derived AES key, hex (test key only) | `8d90d38e2250a231449795cbcd7a21f44f1c6a648a8ba259480771251223abf2` |
| Decrypted compressed/decompressed byte counts | `425` / `554` |
| Decompressed JSON SHA-256 | `bc0bd89364b218f2ff68209515033a7d02d2347abb3a73f8c403099c81ecb242` |
| Expected avatar size | `1024` bytes |

Also reject the vector after a changed ciphertext, tag, salt, nonce, ephemeral key, issued value, sender key, recipient key, outer event ID or event type; reject an added envelope field. These cases are exercised by the Swift tests. The vector's fixed `issued` time is test data; supply an appropriate test clock for the grant-pin wrapper rather than weakening production expiry checks.

## Notification service seam

These service calls are optional delivery operations, never Hermes host authentication. The reference [broker](../../Bighelp/Notifications/BighelpNotificationIdentity.swift) accepts only the exact HTTPS `link.loopdy.app` origin, with no cookies, credential store, cache, or redirects; 20-second request / 30-second resource timeouts and a 262,144-byte response cap. Do not forward its proof headers or any retained legacy mobile proof to a host. The legacy type name `BighelpManagedNotificationAccountAPI` does not mean that a new installation needs an account bearer.

For installation bootstrap, generate a device-only P-256 signing key, installation UUID, request UUID, timestamp and 24 random nonce bytes. Public key here is **DER SubjectPublicKeyInfo**, encoded canonical base64url, unlike the X9.63 alert public points. Sign ECDSA-SHA-256/P1363 over:

```text
join("\n", ["loopdy-notification-bootstrap-v1", "POST", "/v1/notifications/bootstrap",
  installationId, requestId, decimal(timestamp), nonce, publicKeySPKI])
```

`POST /v1/notifications/bootstrap` body has exactly `version:1`, `installationId`, `requestId`, `publicKeySPKI`, `timestamp`, `nonce` and `proof`. `nonce` and `proof` are base64url strings (proof is 64 raw signature bytes). The client requires response `version:2` and `credential:{scope:"notification-only", installationId:<same>, authorizationEpoch:1}`. Retain the same signing key as the active install credential; no account bearer is returned. A bootstrap retry must use the durable intent rules in the identity coordinator.

Subsequent install requests sign the exact body bytes (empty for GET/no body):

```text
bodyDigest = base64url(SHA256(bodyBytes))
transcript = UTF8(join("\n", ["loopdy-notification-device-v1", upper(method), path,
  installationId, decimal(timestamp), nonce, decimal(authorizationEpoch), bodyDigest]))
signature = base64url(ECDSA_P256_SHA256_P1363(signingPrivateKey, transcript))
```

Headers are `x-loopdy-notification-installation`, `x-loopdy-timestamp`, `x-loopdy-nonce`, `x-loopdy-authorization-epoch`, and `x-loopdy-signature` with those values. There is no trailing newline. Body canonicalization is performed before freezing/sending, not reconstructed after an uncertain outcome. Service errors use `error.code` or `error` and may omit `version`; check HTTP status before decoding success. Do not flatten `notification_credentials_revoked` into an unrelated parse error.

Let `G = /v1/notifications/host-grants`:

| Service method/path | Request | Client-consumed result |
| --- | --- | --- |
| `GET G` | No body | Exactly `{"version":1,"grants":[Grant]}` |
| `POST G` | `version:3`, `idempotencyKey:UUID`, `instanceId:UUID`, `hostPublicKey`, `hostKeyId`, `profile`, all eight `eventTypes`, `expiresAt` | Exactly `{"version":1,"grant":Grant}`; verify requested authority |
| `DELETE G/{grantId}` | `{"version":2,"expectedRevision":1}` (actual saved revision) | `version:1`, `grant:Grant` with matching ID and `state:"revoked"`; confirm with list readback |
| `GET G/buzzkit/identity` | No body | `version:1` or `2`, `identity:{externalId,identityHash}`; `externalId` is `notify_` or legacy `acct_` plus 43 base64url characters, hash is 64 lowercase hex |
| `POST G/buzzkit/status` | `version:2`, `tokenHash` = lowercase hex SHA-256 of the UTF-8 lowercase hex APNs token, `environment:"sandbox"` or `"production"` | `version:2`, `readiness` as defined below; this is Apple-specific |
| `DELETE /v1/notifications/installations/current` | Empty body | `version:2`, `installation` containing matching `installationId` and `state:"revoked"` |

Current Apple provider `readiness` contains `configured`, `pushCredentials:[{environment?,status,validatedAt?,lastError?}]`, `subscriber:{identified,verified,activeIOSPushEnvironments,currentDevice?}`, and `topicSlugs`. `currentDevice` contains `matched`, `environment`, `enabled`, `active`, optional `subscriptionId`. A ready result requires configured/identified/verified; an active credential with a null or matching environment; the exact current device matched, enabled and active in the required environment; and all four topic slugs from the host provider table. This schema supplies no Android readiness fields. See [BuzzKit runtime](../../Bighelp/BuzzKit/BighelpBuzzKitRuntime.swift) and [identity tests](../../BighelpTests/BighelpNotificationIdentityInstallationScopeTests.swift).

The direct Apple optimization (`PUT /v1/notifications/push-target`, `live-activity-target`, APNs environments/tokens, push-to-start and quiet sign-in wake delivery) is described in [ARCHITECTURE: direct push registration](../ARCHITECTURE.md#direct-push-registration). These are Apple adapters, not portable notification endpoint names for arbitrary tokens. Failure or absence of that optimization leaves the existing supported push path in place. Background renew-sign-in wakes are best effort and must never be a requirement for native reconnect.

## Work snapshots and Apple Live Activities

Activity delivery is independently optional, enabled only for a current grant with rich-activity support. A native event can inform local presentation, but a current host snapshot is not proof that a local projected message segment has the snapshot's canonical turn ID. Never bind a delayed activity registration to whatever turn happens to be current later.

| Method/path under `N/enrollments/{grantId}` | Exact request fields | Successful result fields |
| --- | --- | --- |
| `POST /work` | `version:1`, `profile`, `sessionId` | Exactly `version:1`, `grantId`, `work:null` or `Work` |
| `PUT /live-activities/{activityId}` | `version:1`, `profile`, `sessionId`, computed `sessionReference`, positive integer `leaseExpires <= 9999999999`, optional `turnId` | `version:1`, `activityId`, `grantId`, `sessionReference`, `state:"subscribed"` |
| `DELETE /live-activities/{activityId}` | No body | `version:1`, `activityId`, `grantId`, `state:"removed"` |

`Work` has exactly `profile`, `sessionId`, `turnId`, `phase`, `activeSubagentCount`, `terminal`, `outcome`, `observedAt`. `phase` is `thinking`, `waiting`, `using_tool`, `delegating`, `responding`, `completed`, or `failed`; `outcome` is `null`, `completed`, `failed`, or `cancelled`. Require exact requested profile/session, valid turn coordinate, count 0–99 and positive `observedAt <= min(9999999999, now + 120)`. `terminal` is true exactly when outcome exists and active subagent count is zero. Nonzero helpers require `delegating`; completed/failed phases require their corresponding terminal outcome (cancelled maps to completed). A null snapshot means this host process has no applicable hook observation; it must not manufacture progress. See [work decoder](../../Bighelp/Notifications/BighelpManagedWorkSnapshot.swift).

Activity registration requires the matching service registration to exist and be active with the same grant, activity ID, reference and lease. An explicit `turnId` must name a retained host observation; mismatched/conflicting ownership is rejected. The app preserves pending registrations/removals across failures and checks revisions before clearing them.

The Apple app groups active chats into one physical ActivityKit card, with independent rows, attention first, up to five rows plus total count. Cloud version 3 registration carries a physical `groupId`, opaque `rowId` and `rowRevision`; host per-turn aliases remain distinct. Completing one chat cannot end another chat's row. Only bounded phases, fixed labels and counts go to the service; locally retained titles are not included in that push state. Activity state is reduced, **not sealed alert content**: the service reads it to deliver it and Apple processes it. Android may map the verified Work model to its own local presentation, but these ActivityKit/APNs registration semantics do not establish Android background updates.

For the complete grouping, cloud registration/revision and lifecycle contract, see [LIVE_ACTIVITY_GROUPS](../LIVE_ACTIVITY_GROUPS.md), [activity registrar](../../Bighelp/Notifications/BighelpManagedLiveActivityRegistrar.swift), [native activity runtime](../../Bighelp/Notifications/BighelpManagedNativeActivityRuntime.swift), [work reducer](../../Bighelp/LiveActivity/BighelpLiveActivityWorkReducer.swift), and [coordinator tests](../../BighelpTests/BighelpLiveActivityCoordinatorTests.swift). Live Activities are an optional consumer of authenticated Hermes state, never a chat transport or source of transcript authority.
