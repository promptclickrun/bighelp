# Shortcuts and live chat reliability

September 11, 2026 follow-up to the accepted native chat interaction baseline.

The subsequent build 14 idle watchdog investigation is recorded separately in
[idle startup reliability](IDLE_STARTUP_RELIABILITY.md). It revealed queued-final
and subagent persistence plus presentation/reload work not covered by the active
stream benchmarks below. An idle watchdog is not evidence of a Shortcuts or SDK
version problem.

## Reproduced failures

- A burst of context and tool events for two unmounted chats, each retaining 1,000 messages, performed 80 synchronous full-catalog writes. The simulator main actor spent 2.364 seconds processing that burst.
- Catch-up presentation bypassed the ChatModel checkpoint timer and flushed once per tool event.
- Coalescing alone left a 306 ms main-actor pause when automatically encoding a catalog with 20,000 retained messages.
- Parallel Shortcuts agent and model queries independently called `AgentDirectoryStore.load`, whose load-generation checks cancelled one of the queries.
- Shortcuts reached host-backed operations without waiting for account/host readiness. The normal scene task was the only launch preparation owner.
- A chat that had used references kept synchronously saving unchanged reference state at each tool checkpoint.
- A waited Shortcut selected the first new assistant item, which could be an interim paragraph. An empty final response incorrectly returned a success placeholder. Cancellation became a delivery error.
- The send intent declared background-only execution even when waiting for a potentially long Hermes turn. Foreground continuation was never requested. This is a lifetime risk; the user's actual Shortcuts timeout has not yet been captured on a device.

## Required behavior

`BighelpShortcutService` shares connection preparation and agent enumeration across concurrent entity queries. `BighelpShortcutService.liveWorkspace()` shares a preparation flight, verifies the selected native workspace by loading agents, and reconnects once when needed. A partially failed workspace refresh does not block chat when its authenticated transport and required agent catalog work. An unavailable account or unverified transport fails before creating or submitting a session. Authority changes reject waiting actions. No scene being active is not, by itself, cancellation of a background intent. Intent names, entity IDs and parameters remain compatible with existing shortcuts.

The send intent runs in the background (`supportedModes` is `[.background]`, `openAppWhenRun` is false) whether or not **Wait for response** is on. It never asks for a foreground handoff: the intent runs in the app process, so `BighelpShortcutService.send` holds the host connection (`holdsHostConnection`) and asks iOS for background execution while the reply streams. With waiting on, the service activates the new chat through the normal conversation router and waits for the original send for `responseWait` (25 seconds). If the turn is still running at the deadline it leaves the turn running and returns a queued result, so the Shortcut reports that bighelp will notify the person; a waited result is never replaced by a queued one before that deadline. With waiting off it submits and returns queued right away.

Return the last new terminal assistant text after the awaited send completes, excluding streaming items and non-message tool content. Empty or missing final text is an explicit response-unavailable error, never a fabricated success message. Propagate caller cancellation without submitting again. Continue to use authenticated native session/agent/request ownership for response delivery; do not weaken socket correlation to make a Shortcut finish.

Background execution is **not a guarantee of unlimited App Intent execution**. Apple documents a typical 30-second intent execution budget and separate Siri limits, which is why `responseWait` stays under it. The send intent does not use `LongRunningIntent`. Do not add fake progress or use a background-mode entitlement to evade the system. See [Apple's execution guidance](https://developer.apple.com/forums/thread/832257).

The catalog throttles ordinary live writes across all sessions. The two-second catalog timer is not reset by every incoming event. Prepared chat models retain their own two-second snapshot checkpoint, so an ordinary dirty model can take up to both intervals to reach disk. Explicit terminal, navigation, suspension, wake and account teardown boundaries flush current model snapshots followed by the shared catalog. A continuous stream cannot postpone saving indefinitely.

Automatic encoding uses an immutable Sendable snapshot on a utility task. Account generation and checkpoint identity are checked again before protected atomic replacement. Mutations during encoding stay dirty and schedule another checkpoint. A newer synchronous save, failed strict save, reset or host switch retires older encoders. Do not remove those checks or resolve a new host scope from a stale snapshot.

Reference sends still require their synchronous immutable-intent checkpoint before upload. Ordinary tool checkpoints skip only reference bytes and state already saved successfully. Changed drafts, metadata and failed writes must still be saved or retried. Streaming results themselves continue through ordinary catalog persistence.

## Evidence and limits

Focused Debug simulator measurements on an iPhone 17 Pro / iOS 26.5:

| Work | Before | After |
| --- | --- | --- |
| Two-chat burst, 2,000 retained messages total | 80 writes; 2,364 ms on main actor | 0 writes during burst; 3.36 ms; one explicit lifecycle write |
| Automatic checkpoint, 20,000 retained messages | 306 ms maximum main-actor scheduling gap | 80 ms maximum gap; one complete checkpoint |

The tests read back retained messages, tool results and final context. Separate gated-encoder cases cover newer strict drafts, host changes and new stream updates arriving during encoding. The UI fixture adds a second active prepared conversation with 1,000 messages to the expanded 100-tool stream and checks an unsent draft while typing and scrolling.

The optimized simulator benchmark (`Release`, with `DEBUG` fixture compilation and testability enabled only for the simulator test) completed the expanded two-chat stream in 9 seconds. It recorded 100 background chat updates, an 80 ms maximum main-queue scheduling gap, a 43 ms answer-update p95 and a 223 ms maximum display-callback gap. The equivalent expanded single-chat run also passed the unchanged timing limits. These measurements do not imply a sustained physical-device frame rate.

Keep the no-polling timing benchmark separate from the interaction test. XCTest's full accessibility snapshots of this expanded transcript caused multi-second main-thread pauses during automated typing/swiping, confirmed by the sampled accessibility traversal stacks. The interaction test checks focus, exact draft preservation, access to history, Return to Latest and completion; its timing attachment remains diagnostic. This distinction does not establish VoiceOver performance or explain every possible live-device stall. Do not weaken the no-polling budgets to accommodate accessibility snapshot overhead.

These are synthetic simulator measurements, not a physical-device frame-rate claim. Atomic file replacement and explicit durability boundaries still perform synchronous file work. Search indexing, allocation growth, host execution latency and indefinite background execution are not claimed as fixed. Validate the user's existing shortcut and sustained real-network conversations on TestFlight before declaring device acceptance.

For waited Shortcuts, unit tests validate background send-only behavior, navigation, interim-versus-final selection, missing final text, cancellation and the queued result at the wait deadline. They do not invoke the operating system's Shortcuts runner. On a physical iPhone, run the existing saved action with a fast answer and verify that the next action receives the final text. For a reply that exceeds the wait deadline, verify that the next action receives the queued acknowledgement and that the eventual answer appears in bighelp. Also check cold launch, cancellation and send-only behavior. Notification delivery requires enrollment and permission; a queued acknowledgement does not prove delivery. Record iOS version and elapsed time separately from unit-test results.
