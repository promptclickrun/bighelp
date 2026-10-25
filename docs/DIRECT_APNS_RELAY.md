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
{"version":1,"token":"<lowercase hex, even length, 64 to 200 characters>","environment":"sandbox","appVersion":"2.7.0(160)","mutedTopics":["scheduled-tasks-deliveries"]}
```

`environment` is `sandbox` or `production`. Xcode builds are sandbox. TestFlight and App Store builds are production.
The Worker stores either, but only sends directly to the environments in `APNS_ENVIRONMENTS` (see below).
`appVersion` matches `^[0-9]{1,4}(\.[0-9]{1,4}){0,3}\([0-9]{1,7}\)$`.

Answer, HTTP 200:

```json
{"version":1,"target":{"kind":"alert","environment":"sandbox","updatedAt":1767225600}}
```

`mutedTopics` is required. It lists the topics this person turned off in Settings › Notifications › Notify Me About: a
unique subset of `chat-replies-completions`, `scheduled-tasks-deliveries`, `questions-approvals` and
`subagent-completions`, possibly empty. The app sends it with every `PUT`, and again whenever those settings change.
BuzzKit applies the same settings to its own sends, so the Worker has to apply them to direct ones (see "Muted topics").

A body with other keys, an unknown or repeated topic, or a value that doesn't match, is
`400 notification_push_target_invalid`. Writes are limited per installation in ten-minute windows, so a block never lasts longer than ten minutes: 4 for alert and
push-to-start tokens together (about 20 an hour), 40 for Live Activity tokens (about 240 an hour) and 2 for any one
activity (about 12 an hour). The app writes at launch, when its token or muted topics change, and at every Live Activity
start and token rotation, and a busy Live Activity user never uses up the alert allowance. Over a limit, a `PUT` answers
`429 notification_push_target_rate_limited`. A `DELETE` is never limited.

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
- A token APNs reports as dead is marked `invalid_at` and not used again. A new `PUT` clears the mark.
- Revoking an installation (`DELETE /v1/notifications/installations/current`) deletes its tokens and send records. Even
  before that finishes, a revoked installation's rows are never read, and the egress check refuses the send. If clearing the
  rows fails, the revocation still completes and the failure is logged as `push_cleanup_failed`. The rows expire.
- `push_sends` has one row per direct send. It is the idempotency record (below), kept for 24 hours and purged an hour
  after that. `push_target_writes` counts the writes in each ten-minute window.
- Housekeeping deletes up to 100 expired rows of each table. It runs after a `PUT` or `DELETE` on either route, at the
  start of every queue batch and after about one direct send in sixteen. It never delays an answer.

## Choosing the route

| Setting | Meaning |
|---|---|
| `DIRECT_APNS` | `off` (the default when unset), `shadow` or `on` |
| `DIRECT_APNS_CANARY` | Comma-separated installation IDs |
| `APNS_ENVIRONMENTS` | `production` (the default), `sandbox` or both, comma-separated |

A send goes direct when all of these are true:

- The APNs secrets and `PUSH_TOKEN_KEY` are set.
- The grant belongs to a notification installation. The retired account scope never goes direct.
- The installation has a live target of the right kind: `alert` for alerts, wakes and the test notification, or
  `liveactivity` for that activity.
- `DIRECT_APNS` is `on`, or it is `shadow` and the installation is in `DIRECT_APNS_CANARY`.
- The target's environment is listed in `APNS_ENVIRONMENTS`. A key made for production only answers a sandbox token with
  `403 BadEnvironmentKeyInToken`, so the default is `production`: sandbox targets (Xcode builds) go through BuzzKit
  without calling APNs, and record `push.fallback_buzzkit` with `environment_disabled`. In `shadow`, such a target reports
  `wouldUseDirect: false`.

A target saved without a muted-topics list is not used for direct delivery: the Worker can't honour what it doesn't know.

Everything else goes through BuzzKit. In `shadow`, a BuzzKit send for an installation that has a target also records
`push.shadow`. With `DIRECT_APNS=off` the send path doesn't read the push tables at all.

The BuzzKit link wake for retired account pairing (`sendBuzzKitLinkWake`) always stays on BuzzKit.

### When a direct send fails

| APNs answer | What happens |
|---|---|
| 410, or 400 `BadDeviceToken` or `DeviceTokenNotForTopic` | The target is marked invalid and this message goes through BuzzKit |
| 403 `BadEnvironmentKeyInToken` (any `BadEnvironmentKey…`) | The key doesn't serve this environment. The message goes through BuzzKit at once, with no new provider token. The target isn't blamed, nothing counts toward a breaker, and the Worker skips APNs for that environment for ten minutes (`environment_unsupported`) |
| 403 `ExpiredProviderToken`, `InvalidProviderToken` or `MissingProviderToken` | A new provider token is made once and the push is sent again. If that fails too, the message goes through BuzzKit |
| 429, 5xx or no answer in 5 seconds | The message goes on the retry queue and the host gets `accepted` with `providerStatus: "queued"`. With no queue, it goes through BuzzKit |
| Any other 4xx | The message goes through BuzzKit |

Anything unexpected before the request (a database error, a key that can't sign) also falls back to BuzzKit. So does a
direct path that runs past eight seconds in all (database, provider token and both APNs tries), so it can't outlast the
host's own 12 second timeout. The test notification never queues, because the person is waiting: a transient failure
goes straight to BuzzKit. A rich (unsealed) alert never queues either, because its text is plain: it goes to BuzzKit at once.

### Muted topics

BuzzKit applies each person's topic settings to every message by its `topic`, and it still holds the real settings. The
Worker's `mutedTopics` is a copy that can be out of date, so it is never used to hide an alert while BuzzKit can decide:

- While BuzzKit is configured, a direct-eligible alert whose topic is in `mutedTopics` goes through BuzzKit and records
  `push.fallback_buzzkit` with `topic_muted`. If the person did mute it, BuzzKit sends nothing. If the list is stale,
  they still get the alert they want.
- Only when BuzzKit isn't configured does the Worker suppress the alert itself. The host gets `202` with
  `status: "accepted"`, `providerStatus: "suppressed"` and `counts: {"total":0,"sent":0}`, and nothing is recorded.
- The sign-in wake, the test notification and Live Activity updates ignore muted topics, as they do on BuzzKit.

### Circuit breaker

Each environment has its own breaker, so failures on sandbox targets can never pause production. Three failures in a row
of the same setup kind in one environment pause direct sends to it in that Worker instance for a minute. The kinds are a
provider token APNs still refuses after it was replaced, and the refusals `BadTopic`, `TopicDisallowed`, `MissingTopic`,
`Forbidden`, `BadCertificate`, `BadCertificateEnvironment` and a key that can't sign. A success resets the count. A dead
token or a transient failure doesn't count. While the breaker is open every send goes through BuzzKit and records
`push.fallback_buzzkit` with `apns_breaker_open`. Without it, a bad key would add round trips to every send and could make
APNs refuse the new tokens with `TooManyProviderTokenUpdates`.

### The host's answer for a direct send

HTTP 202 with `{"version":1,"status":"accepted","deliveryId":"<apns-id>","providerStatus":"sent","counts":{"total":1,"sent":1}}`.
When the message is queued, `providerStatus` is `queued` and `counts` is `null`.

A BuzzKit send answers as before. `providerStatus` is the status in BuzzKit's create answer, or `accepted` if it has none.
The Worker no longer reads the message back, which saved a round trip on every send. The test notification and the
retired Link wake still read back, because they use `counts`.

### Live Activities and the shared card

Bighelp keeps one physical Live Activity for all of a phone's active chats ([Shared chat Live Activity](LIVE_ACTIVITY_GROUPS.md)).
Which ID the Worker sends to depends on how the phone registered:

- **Shared card (version 3 registration, with `groupId`).** The Worker sends one aggregate update to the physical card, from the
  user's Durable Object. The push token to register with `live-activity-target` is the physical card's, with
  **`activityId` set to the `groupId`** the phone registers with the grant route. Per-chat aliases (`activityId` in
  `/live-activities/<alias>`) get no token. The aggregate is rebuilt for every send, so a direct push that fails is never
  queued: it goes through BuzzKit at once (`group_not_queued`) with the same content. Its send key is
  `installation|liveactivity|groupId|timestamp`, and the group's own authority check is still the last step before the request.
- **Individual registration (version 2).** The Worker sends that activity's update to the token registered under its own
  `activityId`, as described above, and a failed push may use the retry queue.

### Idempotency

A direct send claims a `push_sends` row first. The key is `installation|kind|key`, where the key is the event ID for
alerts, `bighelp-renew-<grantId>-<window>` for wakes (a window is six hours), the request ID for the test notification and
`activityId|updateId` for Live Activity updates.

- A repeat of a message that was sent, or is waiting in the retry queue, answers `status: "duplicate"` and sends nothing.
- A repeat that arrives while the first request is still sending (under 20 seconds) answers `503 push_in_flight`. Nothing has been sent
  that an "accepted" could stand for, and a host retries a 503. The Worker never answers this case with 400, 401, 403,
  404, 410 or 422, because a host drops its grant on some of those.
- A record left in `sending` by a Worker that was cut off can be taken over after 20 seconds. The direct path ends by 8.
- A message that fell back to BuzzKit is marked `buzzkit`. A repeat goes to BuzzKit too, which deduplicates by the same
  key, so the phone can't get it by both routes. If the BuzzKit call failed, the repeat tries BuzzKit again.
- If the send was stopped before anything left (egress authority withdrawn, an unexpected error), the record is deleted.
- A Live Activity update is also deduplicated by its Durable Object, as before.

### Egress authorization

The Worker asks the owning Durable Object for the final decision (`authorizeNotificationEgress`) as the last awaited step
before the request to APNs, on every path. The provider token and the stored push token are both ready before that
call. The retry queue asks again before every attempt.

## What the Worker sends to APNs

`POST https://api.push.apple.com/3/device/<token>`, or `api.sandbox.push.apple.com` when the target says `sandbox`.
The provider token is an ES256 JWT, kept in memory per Worker instance and made again after 40 minutes, or when its issue
time is 50 minutes old. Its `iat` is rounded down to a 30-minute boundary, so every instance signs the same issue time and
APNs sees one token, not a refresh storm. APNs rejects a new token under 20 minutes old and one over 60 minutes old, and a
token is never used past 50 minutes of `iat`. The request times out after 5 seconds (less when the 8 second direct deadline is closer, and no request starts after a slow
egress check has used the time up), and at most 4 KiB of the answer is read.

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

Every alert, wake and test push carries `bighelp_meta` at the top level of the payload. A direct push has
`{"v":1,"path":"direct","sentAt":<ms>,"occurredAt":<ms>}`: `sentAt` is when the Worker sent it and `occurredAt` is when the
host made the event, when it says.

The BuzzKit copy goes into `data`, which BuzzKit puts at the top level, and is only `{"v":1,"path":"buzzkit","occurredAt":<ms>}`.
It has no `sentAt`, because a host retry must send a body identical to the first one under the same idempotency key. When
the key would push a message past BuzzKit's payload budget, it is left out and the send goes ahead. The notification
extension reads it to record the delay. The app ignores unknown top-level keys: `PushPayload`, `BighelpSealedNotification`,
`BighelpProactiveNotificationOpen` and the wake checks each read named keys only.

## Retry queue

`loopdy-link-apns-retry`, with the dead-letter queue `loopdy-link-apns-retry-dlq` (`max_retries` 5). Only sealed alerts, wakes
and Live Activity updates wait here. A message holds the grant ID, kind, event type, send key and the message in
BuzzKit's shape. It holds no push token and no ciphertext of one.

A push is worth little once it is late, so a message gets one more direct try and then goes through BuzzKit:

- The inline send is the first try. If it fails in a way worth retrying, the message waits 5 seconds.
- If the second try fails too, or the next wait would end after the push expires, the message goes through BuzzKit at
  once. An alert lives 900 seconds, a question 300 and an approval 60.
- If BuzzKit can't take it, the message waits (15, 45, 120, 300 and 600 seconds) as long as the push is still fresh. A
  message that would be stale by its next try is dropped. A wake lives six hours, so it can use every try and then land
  in the dead-letter queue.

Each attempt checks the grant and installation again, opens the stored token again, checks the person's muted topics
again and asks for egress authority again. Any unexpected error after the grant is loaded (a database or decryption error,
for example) sends the message through BuzzKit at once, with `consumer_error`, instead of waiting to fail the same way. A message whose authority is gone, whose push has expired or that has already
been sent is dropped.

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
| `push.fallback_buzzkit` | `reason`: `apns_unconfigured`, `no_target`, `target_unreadable`, `target_incomplete`, `token_invalid`, `provider_token`, `no_queue`, `not_queued`, `plaintext_not_queued`, `queue_unavailable`, `retries_exhausted`, `apns_breaker_open`, `environment_disabled`, `environment_unsupported`, `group_not_queued`, `apns_deadline`, `topic_muted`, `consumer_error`, `payload_too_large`, `target_lookup_failed`, `claim_failed`, `already_with_buzzkit` or `apns_<apns reason>` |
| `push.shadow` | `eventType`, `wouldUseDirect` |

### Workers Logs

Workers Logs is on, sampled at 20 percent, with invocation logs off (`"logs": {"invocation_logs": false}`). What it keeps:

- The lines the Worker prints itself: `[loopdy-link] push_<event>: <code>`, `[loopdy-link] request_failed: <error class>` and
  the older socket and delivery lines. They hold fixed codes. An unexpected error logs only its class name, not the
  exception, which can carry paths or secrets.
- The metadata Cloudflare adds to any log line: time, the Worker's name, the outcome and the data centre.

What it does not keep: request URLs (which carry grant and device IDs), headers, request or response bodies, push tokens,
installation IDs and message text. Don't add a log line that does.

## Settings

| Kind | Name |
|---|---|
| Secrets | `APNS_KEY_P8` (the `.p8` file's text), `APNS_KEY_ID`, `APNS_TEAM_ID`, `PUSH_TOKEN_KEY` (base64 of 32 random bytes) |
| Vars | `APNS_TOPIC` (`app.loopdy.mobile`), `DIRECT_APNS` (`on` in `wrangler.jsonc` since the 2.6.20 rollout; `off` when unset), `DIRECT_APNS_CANARY` (empty) |
| Queue | Producer `APNS_RETRY`, consumer for `loopdy-link-apns-retry` |
| Service | Optional `TELEMETRY` to `bighelp-telemetry`, entrypoint `TelemetryIngest` |

Secrets are set with `wrangler secret put` and never go in the repository. Whoever holds the `.p8` key can push to every
installation, so keep it off hosts and rotate it if it ever reaches one. Make `PUSH_TOKEN_KEY` with
`openssl rand -base64 32`. Replacing it makes every stored token unreadable. Those installations use BuzzKit until their app sends its token again.

## Rollout

Each step is safe to stop at. The Worker changes nothing for anyone until step 6. The planned APNs key is valid for
production only, so leave `APNS_ENVIRONMENTS` at `production`: debug builds keep using BuzzKit.

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
