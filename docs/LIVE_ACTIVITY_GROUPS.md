# Shared chat Live Activity

bighelp uses one ActivityKit card for the phone's active chats. The Lock Screen shows up to five independently linked rows, with attention first and a count for additional work. The expanded Dynamic Island shows three rows. Large accessibility text reduces the visible rows. Each row uses real host phases; an old observation says Paused. Titles and agent names are resolved from the phone's App Group metadata, not sent in the group payload.

The layout is inspired by [T3 Code's AgentActivity](https://github.com/pingdotgg/t3code/blob/d53873b6a4799e87afd63c8d288ef0089f5a3748/apps/mobile/src/widgets/AgentActivity.tsx): compact rows, attention first, a quiet compact island, and explicit overflow. bighelp uses its own SwiftUI views and colors.

## Why cards were intermittent

Text-only turns did not emit a reasoning/tool activity, so they never reached the managed activity bridge. The bridge also awaited a host work snapshot before calling ActivityKit; leaving the app during that read could miss the foreground start window. After a failed start, an existing canonical entry only retried token registration. A new chat cancelled the previous chat's card before its replacement had started.

Confirmed live turn starts now reach the notification bridge without adding a transcript row. The bridge starts locally before the snapshot request, and binding an already-running, connected chat admits that live state too. Failed starts retain a pending event for a later live opportunity. An authenticated snapshot can promote the exact captured row to canonical host ownership. Canonical status then comes from that host, not local message-segment endings.

ActivityKit still controls whether a request may start. This change does not introduce remote push-to-start or promise that work first discovered while the app is suspended will create a card. A denied request is logged and remains retryable; stale content is shown honestly.

## Ownership and updates

`BighelpActivityGroupDriver` gives each turn a virtual native ID under one physical ActivityKit ID. The existing coordinator, ledger and registrar retain their exact account, host, profile, stored session and canonical turn ownership. A replacement receives a monotonic row revision. A late end or cancellation for an old virtual ID cannot remove its replacement. Ending the last row detaches the physical card before awaiting ActivityKit, so a new turn cannot reuse an activity already ending.

The app registers the physical token with BuzzKit under the physical group ID. Version 3 mobile registration sends `groupId`, opaque `rowId`, and `rowRevision`, while each host still owns its existing per-turn activity alias. Version 2 individual registrations remain supported. The notification Durable Object persists each authorized row, aggregates current rows at delivery time, and sends one payload to the physical group ID. An individual completion is an update while other chats remain active; only an empty active group sends an ActivityKit end.

Registration must establish credential/grant authority before another row can finish. The service rejects cross-device group joins and superseded row generations, rechecks current authority at egress, bounds retained rows and payload size, and serializes timestamped sends. Public session text, tool arguments, credentials and host addresses are never included in group status.

The payload carries five visible rows, the total active count, and opaque membership suffixes for up to 64 active rows. Hidden rows are recovered only when that membership confirms them; local dismissal tombstones survive restoration. Physical token registration is serialized across all row owners and drains token rotations before releasing the queue. If a remote completion ends the physical card before a new row registers, still-running work gets a new physical card during an eligible live opportunity. All-finished cards dismiss after 30 seconds, or on the next app opening. Upgrade cleanup dismisses old per-chat native cards only after a shared start succeeds.

## Chat widgets

Active Chats and Recent Chats retain working sessions before the twelve-session snapshot limit. The row link includes the correct gateway as well as the stored chat ID. Widget session freshness is independent of unrelated snapshot changes: a cached read does not become fresh merely because the app reopened or a board changed. The native runtime marks sessions live only after an authoritative read on the current connection. A live publisher can refresh the timestamp once a minute; background suspension stops that heartbeat. The timeline includes the stale boundary, subject to WidgetKit's scheduling, and preserves the chats while showing Updates paused.

The layouts reduce row counts at larger text sizes and bound text at the first accessibility size within the fixed widget area. Small widgets show one chat with one unambiguous destination; larger widgets link each row separately. VoiceOver retains the full chat title, agent and status.

## Delivery and validation boundary

Deploy the notification service's version 3 support before distributing an app build with shared activities. The plugin retains its existing canonical work and per-alias subscription protocol. An older service rejects version 3; the on-device card can remain visible but cannot receive its aggregate background updates. Merging this code does not deploy the Worker or publish an iOS build.

Regression tests cover native start/retry and restoration, independent completion, ending/new-turn races, payload bounds, the slow snapshot bridge, authoritative widget freshness, and scoped widget links. `HostActivityRenderTests` and `BighelpWidgetRenderTests` render production SwiftUI with made-up data. Simulator tests and fixture renders are distinct from a physical-device APNs end-to-end check.
