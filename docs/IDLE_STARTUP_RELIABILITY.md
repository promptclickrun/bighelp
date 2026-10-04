# Idle startup and historical delivery

September 11, 2026 follow-up to build 14. Opening Home must remain responsive
even when no session is active and the phone has accumulated historical delivery.

## Device evidence

The physical iPhone's build 14 log, `Loopdy-2026-09-11-032445.ips`, records a
foreground process-exit watchdog (`0x8BADF00D`), with the main thread inside
SwiftUI/Observation tracking. The matching launch's disk resource report
records 1,078.51 MB of writes over 7,188 seconds. Symbolication against build
14's exact dSYM identifies full-catalog persistence from queued final answers
and removed subagents on the main thread. The sampled launch had no active
sessions in its saved catalog: 62 records, 185 messages, and 2,938 tool/activity
events, in a 6.9 MB file.

A nearby memory report lists bighelp at approximately 690 MiB. bighelp was **not**
the jetsam victim. This does not establish a leak or a memory-limit termination.
The watchdog stack alone does not identify an infinite loop or an OS defect.
Treat these as app investigation evidence, not an iOS-version explanation.

## Required implementation boundaries

- Historical final answers, child discovery, title updates and child termination
  share the catalog checkpoint. Mounted chat snapshots publish before the one
  catch-up completion save. Background/suspension still flushes dirty state.
- Home, the sidebar and Sessions use `SessionCatalogStore.presentedRecords`.
  During catch-up this is a stable snapshot; canonical `records` continue to
  receive every authenticated event immediately. Routing, merges, permission
  checks and persistence must never read the presentation snapshot.
- End catch-up by publishing the latest catalog and roster presentation once.
  Account reset clears the presentation snapshot as well as canonical state.
  Previously completed children must not flash as newly active work during replay.
- Queued assistant finals defer automatic Home reloads until catch-up ends.
  They must not start a dashboard request per historical answer. An account
  boundary discards a pending refresh from the previous owner.
- Keep live turn completion and strict reference-send durability boundaries.
  Preserve encrypted sequence validation, event identities, ordered receipt
  commit and acknowledgements. No transport data is dropped to improve timing.

## Reproduction and evidence limits

`SessionCatalogStoreTests` covers mounted/unmounted queued finals, subagent
discovery/termination, exact persisted readback, and SwiftUI observation during
catch-up. `ShellFeatureStoreTests` covers automatic dashboard reload coalescing.

The measurements below came from a UI fixture (since retired with the old launch UI tests) that
launched Home with 62 synthetic completed chats and 3,000 retained tool events,
then delivers 120 historical answers and 120 start/end subagent rosters through
the production feature store. It starts no chat. The probe samples the app's
main queue and display callbacks, then checks menu/settings navigation. XCTest
waits on a completion signal during measurement instead of repeatedly traversing
the accessibility tree.

| Same Debug simulator workload | Previous implementation | Corrected implementation |
| --- | ---: | ---: |
| Catalog writes | 360 | 1 |
| Total measured seconds, including 3 idle seconds | 16 | 3 |
| Maximum display callback gap | 460 ms | 53 ms |
| Main queue p95 | 120 ms | 17 ms |
| Maximum main queue gap | 159 ms | 53 ms |
| Memory footprint at end | 70 MiB | 70 MiB |

These iPhone 17 Pro / iOS 26.5 simulator results reproduce excess work and
verify its reduction. They do not reproduce the physical phone's 690 MiB
footprint or prove that its exact watchdog can no longer recur. Physical
TestFlight acceptance must include reopening after accumulated delivery,
several minutes idle, navigation, and two simultaneous long chats.

Device diagnostics contain personal session data; they are not fixtures and
must not be committed. This investigation is independent of the remaining
long-running Shortcuts system-execution acceptance described in
[Shortcuts and live chat reliability](SHORTCUTS_AND_LIVE_CHAT_RELIABILITY.md).
