# Background chat continuity

bighelp's `UIBackgroundModes` are `audio` (CarPlay voice with the iPhone locked), `fetch` (Background App Refresh
for widgets) and `remote-notification` (quiet pushes). Background execution is discretionary: silent pushes may be
delayed, combined, or omitted; force-quit prevents background relaunch until the app is opened again. There is no
keepalive for chat and no guarantee the phone stays current while suspended.

## Going away and coming back

- **Background grace.** Going to the background keeps the host connection for 25 seconds
  (`BighelpBackgroundGrace.duration`, inside iOS's background allowance of about 30 seconds), with background time
  from iOS. Coming back in time cancels the close, so the chat finds a live connection. If iOS asks for its time
  back early, the connection closes then. While a Shortcut, CarPlay or another outside caller holds the connection
  (`BighelpShortcutService.holdsHostConnection`), the grace's close leaves it open. On the Mac, which doesn't
  suspend apps, no background task is taken.
- **Saving.** Going to the background writes every chat's pending changes at once
  (`flushChatPersistence`) and publishes the widgets' data.
- **Coming back.** The app reconnects (`reconnect()`). The reconnect's recovery reattaches the open chats it held
  (`NativeWorkspaceSessionRecovery`, the chat on screen first) and reads each one's newest history page again,
  keeping the earlier pages it already has (`refreshHeldHistory`). After a turn ends, the host's saved history is
  the truth. A chat on screen that had no connection of its own opens again (`openDetachedChat`). See
  [idle startup reliability](IDLE_STARTUP_RELIABILITY.md) for launch.

## Preserve content, defer presentation

Foreground presentation also follows the
[Chat interaction contract](CHAT_INTERACTION_CONTRACT.md). Catch-up must preserve
reader ownership, native input, disclosure choices, and request-scoped drafts.
Coalescing presentation or persistence must not discard canonical events or
reintroduce delayed scrolling that overrides a drag. Keep the existing lifecycle
flushes when changing tool-event checkpoint frequency.

The app does not discard activity, generated cards, drafts, or terminal messages in expectation of a later history fetch. Existing request continuations, approval handling, sender/session checks and receipt order remain intact.

`ShellFeatureStore.setChatPresentationDeferred` can hold presentation while a batch of events arrives: route-owned chat models defer their derived transcript (`setTranscriptPresentationDeferred`), and the session catalog keeps a stable copy of its rows (`SessionCatalogStore.setPresentationDeferred`). Canonical items and activity are still applied, and persistence stays coalesced. Closing it rebuilds each transcript once, flushes the catalog in one write and runs one deferred Home refresh. Setting it twice to the same value does nothing. Today only the idle replay fixture (`CanvasStreamingFixtureClient`) opens it; the live background and foreground paths above do not.

## Quiet pushes

A quiet push reaches `BighelpLinkWakeCenter` (a legacy name from the retired Link transport). The app handles two
kinds:

- **Sign-in renewal** (`bighelp_wake`, type `renew-sign-in`). The plugin asks the notification service to send it
  about every 8 hours (`_SIGN_IN_WAKE_SECONDS` in the plugin's `managed_notifications.py`). The app renews each
  computer's rotating sign-in that isn't connected (`renewSignInWhileAway`).
- **Notification wake** (`loopdy_link`, version 2, type `wake`). The app reconciles notification delivery: pending
  revocations, Live Activity recovery for each computer, then a flush of pending card operations
  (`BighelpManagedNotificationIntegration.recoverWake`). It does not open chats or read their history.

bighelp's own handler reports "new data" only when a sign-in was renewed, and never "failed" for a wake it
handled, so iOS does not throttle later wakes. BuzzKit's answer for the same push is merged in. The app sets no time budget of its own for a wake; iOS's limit applies.

## Host side

The plugin does not throttle or coalesce chat streaming for the phone. Hermes sends each answer a few words at a
time over the chat's socket, and the app paces its own redraws (see AGENTS.md › Streaming under a drag).

## Verification boundary

Unit tests (`ChatModelTests`, `ShellFeatureStoreTests`, `SessionCatalogStoreTests`) cover a 75-event deferred
presentation batch with local persistence, idempotent presentation boundaries, and retained native chat scrolling. Physical push scheduling is not a simulator guarantee and is not a
release gate for this work.
