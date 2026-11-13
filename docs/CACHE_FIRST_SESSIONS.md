# Cached session opening and native scan attachments

## Session lifecycle

Existing chat navigation mounts the retained ChatModel or the host/account-scoped
local transcript before awaiting network work. Mounting an existing model does
not reconcile an older catalog over live text. The canonical recent-history
refresh still owns remote identities and live-state recovery. The composer and
Send work at once: a message sent before the native client is ready waits at the
bottom of the chat with "Sending…" (`stagedSends`) and goes out once the chat can
take it. Commands (`/…`) and PDF pages still wait in the box for the connection.

```text
open saved chat
  restore the one scoped cached conversation
  mount its retained model and navigation
  fetch recent history (shared by simultaneous readers)
  reuse the verified runtime coordinate, or resolve it once
  recover events / activate / recover boundary events
  refresh the optional subagent roster independently
```

There is no metadata-preparation pass ahead of initial history. A known native
runtime no longer needs profile enumeration and a second activation solely to
resolve its identity. Required replay/snapshot ordering remains intact.

Cancelling one history reader leaves other readers attached. Retiring the final
reader cancels the underlying request; suspension/account retirement clears
admission and rejects late publication. Refresh persistence uses the existing
coalesced, off-main encoding checkpoint. Navigation, suspension and send durability
barriers retain explicit flush behavior. Foreground recovery prioritizes retained
chats before unrelated optional workspace catalogs; it still reads canonical
history rather than treating an event ring as unlimited durable history.

Native text updates reuse a validated last-segment index. Whole-history replacement
or reordering invalidates that index by identity, not by an assumed array offset.

## Submission receipts

A validated steer/queue receipt proves admission to Hermes, not model consumption.
After that receipt, Hermes owns its queue and bighelp retires its local uncertainty
record. Unknown outcomes and legacy records remain local and are never automatically
resent. A recovered connection can accept a separately authored new message without
requiring receipt-management chores. The attention surface contains only actual
host approvals and clarification requests, not old steered text.

## Reopen identity and group readiness

Hosted groups use their own verified group client. Their unused direct-chat
placeholder does not gate Send. Direct chats stage a message until their own
transport is ready.
Programmatic direct sends preserve the draft while that transport is unavailable.

Authoritative history may refine a stored result's tool-call linkage at a page
boundary. Reconcile that representation by its exact event ID, turn and kind
before constructing the ledger; do not keep both identity variants as separate
work-trail headers. Keep distinct turns and distinct source records intact.
Repeated recorded history remains recorded, never newly running. These cases are
covered by synthetic regressions and an optional private replay of the affected
phone cache and canonical host rows. Private replay data is not bundled or committed.

The chat canvas has no hydration overlay. The history-state flag coordinates
refresh and readiness without covering existing messages or blocking interaction.

## Canonical tool coverage

The real-host release check returned repeated tool-call IDs with different request
arguments and different result bodies. Those are conflicting recorded variants,
not byte-identical duplicates that the client may discard. Native history keeps
all of those source records. Its verified call-ID coverage separately retires the
redundant live overlay, so reopening does not append another "More completed work"
folder for the same covered call. Coverage remains host/profile/stored-session
scoped and defaults to empty for clients without this native provenance.

## Document scanning

`Scan document` in the attachment menu uses Apple's
`VNDocumentCameraViewController`. Camera access is requested only on explicit use;
unsupported devices show an unavailable action. The system scanner handles capture,
page correction and ordering. Saving creates one local PDF containing all selected
pages, with bounded raster dimensions and a maximum of 20 pages. Existing per-file,
batch-size and attachment-count checks still apply. Oversize scans are rejected,
never silently shortened.

Cancellation creates no attachment. Successful results stage on the original,
non-retired chat/agent after the camera is dismissed. The normal Send action is
required for any upload. PDF creation does not add OCR or make a network request.

## Verification

Focused regressions cover acknowledged versus unknown steers, recovery during a
held optional roster, concurrent/cancelled history readers, cached draft/model
identity, long-history text updates, and PDF page ordering/cancellation/limits.
The cached-open UI fixture deliberately holds metadata for 15 seconds and history
for 60 seconds while exercising the composer and first-tap return/reopen.

The isolated stock-Hermes fixture exercises actual native authentication, streaming,
tool use, persisted history, relaunch and a second send with a local synthetic model.
This is real client/host protocol evidence, not a production-provider benchmark.
Optimized simulator stress checks retain the existing frame/main-queue thresholds.
Physical camera acquisition and physical-device latency remain separate observations;
Simulator cannot exercise document-scanner camera hardware.
