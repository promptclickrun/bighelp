# Direct APNs relay

The Link Worker (`services/link`, `link.loopdy.app`) can send a push straight to Apple's push service (APNs). Until now
every push went through BuzzKit, which added about ten seconds of queueing on its side. A direct send is one request
from the Worker to APNs, usually 150 to 400 ms.

This page is the contract for the Worker side: the routes the app calls, what the Worker sends, the settings that turn it
on and the order to roll it out. BuzzKit stays as the fallback and as the route for older app builds.

## What stays the same

- Older app builds never register a push token with the Worker, so they keep going through BuzzKit exactly as before.
- An installation gets one copy of each push, never both.
- Grants keep `provider: "buzzkit"` and their shape.
- The host's answer keeps its shape: HTTP 202 with `{version, status, deliveryId, providerStatus, counts}`. `status` is
  `accepted` or `duplicate`, and `deliveryId` is a string.
- With `DIRECT_APNS` unset or `off`, the Worker behaves as before. The differences are the `bighelp_meta` key (below),
  no read-back request to BuzzKit after a send, and telemetry and logs.

## Routes

Both routes use the same signed requests as the other installation routes (`loopdy-notification-device-v1`). Only
notification installations may call them. An account credential gets `403 notification_scope_invalid`. Responses are
`no-store`.

Before this Worker is deployed these routes answer 404. While the migration or `PUSH_TOKEN_KEY` is missing they answer
`503 notification_push_target_unavailable`. The app treats both as "try again later".

### `PUT /v1/notifications/push-target`

```json
{"version":1,"token":"<lowercase hex, even length, 64 to 200 characters>","environment":"sandbox","appVersion":"2.7.0(160)"}
```

`environment` is `sandbox` or `production`. Xcode builds are sandbox. TestFlight and App Store builds are production.
`appVersion` matches `^[0-9]{1,4}(\.[0-9]{1,4}){0,3}\([0-9]{1,7}\)$`.

Answer, HTTP 200:

```json
{"version":1,"target":{"kind":"alert","environment":"sandbox","updatedAt":1767225600}}
```

A body with other keys, or a value that doesn't match, is `400 notification_push_target_invalid`.

### `DELETE /v1/notifications/push-target`

Body `{"version":1}`. Answer `{"version":1,"target":null}`. Deleting twice is fine.

### `PUT /v1/notifications/live-activity-target`

One of:

```json
{"version":1,"kind":"liveactivity","activityId":"<[A-Za-z0-9][A-Za-z0-9._:-]{0,127}>","token":"<hex>","environment":"sandbox"}
{"version":1,"kind":"pts","token":"<hex>","environment":"sandbox"}
```

`pts` is a push-to-start token. It belongs to the app, not to one activity. The Worker stores it, but nothing sends to it
yet. Answer: `{"version":1,"target":{"kind":"liveactivity","activityId":"...","environment":"sandbox","updatedAt":1767225600}}`.
A `pts` answer has no `activityId`.

### `DELETE /v1/notifications/live-activity-target`

Body `{"version":1,"kind":"liveactivity","activityId":"..."}` or `{"version":1,"kind":"pts"}`. Answer
`{"version":1,"target":null}`.

### Storage

Migration `0010_push_targets.sql` adds two tables to `loopdy-link-accounts`.

- `push_targets` has one row per installation, kind (`alert`, `liveactivity`, `pts`) and activity ID. The token is sealed
  with AES-256-GCM. The key is `PUSH_TOKEN_KEY`, and the associated data is `installation|kind|activity`, so a ciphertext
  copied to another row doesn't open.
- Alert and `pts` rows last 60 days, and every `PUT` refreshes them. A Live Activity row lasts 12 hours. An installation
  keeps at most eight Live Activity rows.
- Expired rows are deleted in batches of 50, on `PUT`, `DELETE` and each queue batch.
- A token APNs reports as dead is marked `invalid_at` and not used again. A new `PUT` clears the mark.
- Revoking an installation (`DELETE /v1/notifications/installations/current`) deletes its tokens and send records. Even
  before that finishes, a revoked installation's rows are never read, and the egress check refuses the send.
- `push_sends` has one row per direct send. It is the idempotency record (below) and is deleted after 24 hours.

## Choosing the route

| Setting | Meaning |
|---|---|
| `DIRECT_APNS` | `off` (the default when unset), `shadow` or `on` |
| `DIRECT_APNS_CANARY` | Comma-separated installation IDs |

A send goes direct when all of these are true:

- The APNs secrets and `PUSH_TOKEN_KEY` are set.
- The grant belongs to a notification installation. The retired account scope never goes direct.
- The installation has a live target of the right kind: `alert` for alerts, wakes and the test notification, or
  `liveactivity` for that activity.
- `DIRECT_APNS` is `on`, or it is `shadow` and the installation is in `DIRECT_APNS_CANARY`.

Everything else goes through BuzzKit. In `shadow`, a BuzzKit send for an installation that has a target also records
`push.shadow`. With `DIRECT_APNS=off` the send path doesn't read the push tables at all.

The BuzzKit link wake for retired account pairing (`sendBuzzKitLinkWake`) always stays on BuzzKit.

### When a direct send fails

| APNs answer | What happens |
|---|---|
| 410, or 400 `BadDeviceToken` or `DeviceTokenNotForTopic` | The target is marked invalid and this message goes through BuzzKit |
| 403 `ExpiredProviderToken`, `InvalidProviderToken` or `MissingProviderToken` | A new provider token is made once and the push is sent again. If that fails too, the message goes through BuzzKit |
| 429, 5xx or no answer in 5 seconds | The message goes on the retry queue and the host gets `accepted` with `providerStatus: "queued"`. With no queue, it goes through BuzzKit |
| Any other 4xx | The message goes through BuzzKit |

Anything unexpected before the request (a database error, a key that can't sign) also falls back to BuzzKit. The test
notification never queues, because the person is waiting: a transient failure goes straight to BuzzKit.

### The host's answer for a direct send

HTTP 202 with `{"version":1,"status":"accepted","deliveryId":"<apns-id>","providerStatus":"sent","counts":{"total":1,"sent":1}}`.
When the message is queued, `providerStatus` is `queued` and `counts` is `null`.

A BuzzKit send answers as before. `providerStatus` is the status in BuzzKit's create answer, or `accepted` if it has none.
The Worker no longer reads the message back, which saved a round trip on every send. The test notification and the
retired Link wake still read back, because they use `counts`.

### Idempotency

A direct send claims a `push_sends` row first. The key is `installation|kind|key`, where the key is the event ID for
alerts, `bighelp-renew-<grantId>-<window>` for wakes (a window is six hours), the request ID for the test notification and
`activityId|updateId` for Live Activity updates.

- A repeat answers `status: "duplicate"` and sends nothing.
- A send that fails or falls back to BuzzKit deletes its row, so the host's retry isn't blocked.
- A row left in `sending` by a Worker that was cut off can be taken over after 60 seconds.
- A Live Activity update is also deduplicated by its Durable Object, as before.

### Egress authorization

The Worker asks the owning Durable Object for the final decision (`authorizeNotificationEgress`) as the last awaited step
before the request to APNs, on every path. The provider token and the stored push token are both ready before that
call. The retry queue asks again before every attempt.

## What the Worker sends to APNs

`POST https://api.push.apple.com/3/device/<token>`, or `api.sandbox.push.apple.com` when the target says `sandbox`.
The provider token is an ES256 JWT, kept in memory per Worker instance and made again after 40 minutes. APNs rejects a
new token under 20 minutes old and one over 60 minutes old. The request times out after 5 seconds, and at most 4 KiB of
the answer is read.

| Header | Value |
|---|---|
| `apns-topic` | `APNS_TOPIC` (`app.loopdy.mobile`), or `<topic>.push-type.liveactivity` for a Live Activity |
| `apns-push-type` | `alert`, `background` (wake) or `liveactivity` |
| `apns-priority` | `10` for alerts, the test and Live Activities. `5` for wakes |
| `apns-expiration` | Now plus the TTL. 60 s for approvals, 300 s for questions, 900 s for other alerts, 21,600 s for wakes, 300 s for the test. A Live Activity update expires at its stale date, between 1 minute and 1 hour on |
| `apns-id` | A version 8 UUID from the SHA-256 of the send key, so a retry carries the same ID |
| `apns-collapse-id` | A digest of the event ID for alerts (43 characters), `bighelp-renew-sign-in` for wakes. None for Live Activities and the test |

The event ID is 101 bytes, and APNs allows 64 bytes for a collapse ID. That is why alerts use its digest.

### Payloads

A direct payload is built from the same message the BuzzKit route sends, so the app runs the same code for both. A direct
push has no `bk.messageId`, so the BuzzKit SDK sends no receipts for it.

Sealed alert (`alert`):

```json
{
  "aps": {
    "alert": {"title": "bighelp", "body": "New reply"},
    "sound": "default",
    "category": "LOOPDY_AGENT_UPDATE",
    "mutable-content": 1,
    "thread-id": "<sessionReference>",
    "interruption-level": "active"
  },
  "loopdy": {"version": 2, "eventId": "...", "eventType": "...", "grantId": "...", "agent": {"id": "..."},
             "sessionReference": "...", "sealed": {"...": "..."}, "avatar": {"url": "..."}},
  "bk": {
    "deepLink": "loopdy:///dashboard?eventId=...",
    "action": {"name": "open_loopdy_managed_event", "data": {"eventId": "..."}},
    "category": "LOOPDY_AGENT_UPDATE",
    "actions": [{"id": "open", "title": "Open", "foreground": true}]
  },
  "bighelp_meta": {"v": 1, "path": "direct", "sentAt": 1767225600000, "occurredAt": 1767225599000}
}
```

- `sound` is there only when the event asks for it. `interruption-level` is `time-sensitive` for questions and approvals.
- An unsealed (rich) alert has the agent's name as the title, the text as the body and `bk.image` with the avatar URL.
- The sign-in wake (`background`) is `{"aps":{"content-available":1},"bighelp_wake":{"version":1,"type":"renew-sign-in","grantId":"..."},"bighelp_meta":{...}}`.
- The test notification has BuzzKit's title and body, `loopdy_test`, `sound: default` and `mutable-content`.
- A Live Activity update is `{"aps":{"timestamp":<s>,"event":"update"|"end","content-state":{...},"stale-date":<s>,"dismissal-date":<s>}}`.
  `dismissal-date` is sent only at the end, 30 seconds on. All dates are Unix seconds. The content state is the same
  object BuzzKit gets, and it decodes in `LoopdySessionActivityAttributes.ContentState`. It carries no `bighelp_meta`.

### `bighelp_meta`

Every alert, wake and test push carries `bighelp_meta` at the top level of the payload: `v` is 1, `path` is `direct` or
`buzzkit`, `sentAt` is when the Worker sent it (Unix milliseconds) and `occurredAt` is when the host made the event, when
it says. BuzzKit sends it too. It goes into `data`, which BuzzKit puts at the top level. The notification extension reads
it to record the delay. The app ignores unknown top-level keys: `PushPayload`, `BighelpSealedNotification`,
`BighelpProactiveNotificationOpen` and the wake checks each read named keys only.

## Retry queue

`loopdy-link-apns-retry`, with the dead-letter queue `loopdy-link-apns-retry-dlq`. A message is delivered up to six times
(`max_retries` 5), waiting 5, 15, 45, 120, 300 and 600 seconds. A message holds the grant ID, kind, event type, send key
and the message in BuzzKit's shape. It holds no push token and no ciphertext of one.

Each attempt checks the grant and installation again, opens the stored token again and asks for egress authority again.
A message whose authority is gone, whose push has expired or that has already been sent is dropped. The last attempt
goes through BuzzKit. If that fails too, the message goes to the dead-letter queue and the send record is deleted.

## Telemetry

If the `TELEMETRY` service binding exists, the Worker calls `TelemetryIngest.relay(events)` in `ctx.waitUntil` and
ignores every failure. Without the binding it sends nothing. The events hold fixed codes and counts only. They never hold
a token, an ID, message text or a path.

| Event | Properties |
|---|---|
| `push.sent` | `eventType`, `path` (`direct` or `buzzkit`), `priority`, `result`, `status`, `environment` (direct only), `hostToWorkerMs`, `providerMs`, `attempt` |
| `push.token_invalid` | `kind`, `reason` |
| `push.retry` | `attempt`, `reason` |
| `push.dlq` | `reason` |
| `push.fallback_buzzkit` | `reason`: `apns_unconfigured`, `no_target`, `token_invalid`, `provider_token`, `no_queue`, `queue_unavailable`, `retries_exhausted`, `payload_too_large`, `target_lookup_failed`, `claim_failed` or `apns_<apns reason>` |
| `push.shadow` | `eventType`, `wouldUseDirect` |

The Worker's own log lines (Workers Logs, sampled at 20 percent) are `[loopdy-link] push_<event>: <code>`. An unexpected
error logs only its class name. It no longer logs the exception itself, because Workers Logs now keeps what a Worker
prints.

## Settings

| Kind | Name |
|---|---|
| Secrets | `APNS_KEY_P8` (the `.p8` file's text), `APNS_KEY_ID`, `APNS_TEAM_ID`, `PUSH_TOKEN_KEY` (base64 of 32 random bytes) |
| Vars | `APNS_TOPIC` (`app.loopdy.mobile`), `DIRECT_APNS` (`off`), `DIRECT_APNS_CANARY` (empty) |
| Queue | Producer `APNS_RETRY`, consumer for `loopdy-link-apns-retry` |
| Service | Optional `TELEMETRY` to `bighelp-telemetry`, entrypoint `TelemetryIngest` |

Secrets are set with `wrangler secret put` and never go in the repository. Whoever holds the `.p8` key can push to every
installation, so keep it off hosts and rotate it if it ever reaches one. Make `PUSH_TOKEN_KEY` with
`openssl rand -base64 32`. Replacing it makes every stored token unreadable. Those installations use BuzzKit until their app sends its token again.

## Rollout

Each step is safe to stop at. The Worker changes nothing for anyone until step 6.

1. Create the queues: `wrangler queues create loopdy-link-apns-retry-dlq` and `wrangler queues create loopdy-link-apns-retry`.
2. Apply migration 0010 to the remote `loopdy-link-accounts` database.
3. Set the four secrets.
4. Deploy the telemetry Worker, or remove the `services` block from `wrangler.jsonc`. A binding to a Worker that doesn't
   exist stops the deploy.
5. Deploy `loopdy-link` with `DIRECT_APNS=off`. Pushes go through BuzzKit as before, with telemetry on.
6. Set `DIRECT_APNS=shadow` and put the maintainer's own installation ID in `DIRECT_APNS_CANARY`. Check `push.sent` for
   `path: direct`, then `push.shadow` for how many installations have a target.
7. Set `DIRECT_APNS=on` once the app build that registers targets is out and the canary looks right.

Deploying before step 2 is safe: a missing table counts as "no target", the routes answer 503 and revocation still works.

### Rollback

Set `DIRECT_APNS=off` and deploy, or change the variable in the dashboard. Every push goes through BuzzKit again at the
next request. Queued messages still send, or fall back to BuzzKit on their last attempt. Targets stay stored, so turning
it back on needs nothing from the apps.

## What an older app build sees

Nothing changes. It never calls the two routes, so it has no target and every push goes through BuzzKit. The pushes
carry one extra top-level key, `bighelp_meta`, which that build ignores. The Worker's other routes, responses and error
codes are unchanged.

## Tests

`services/link/test/apns.test.ts` covers the APNs client against a fake APNs, the routes, the send path in every mode, the
retry queue and what is logged and reported. Run `pnpm test` and `pnpm run typecheck` in `services/link`. The tests make a
throwaway key. No real key belongs in the repository.
