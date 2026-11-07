# Long-session performance and foreground recovery

**Historical repair report.** The measurements below describe the earlier
scroll-observation implementation. The shipping canvas now uses
`NativeChatTimeline`; `ChatView` no longer drives scrolling from
`ChatModel.timelineScrollKey`. Keep the recovery/lifecycle findings, but do not
restore the old scroll pipeline from this report. Current requirements and
end-to-end chat checks are in the
[Chat interaction contract](CHAT_INTERACTION_CONTRACT.md) and
[Chat performance validation](CHAT_PERFORMANCE_VALIDATION.md).

Related: issue #93; prior recovery work #91. This is a bounded app-only repair, not a release or a claim that every real-device outage has been reproduced.

## Reported behavior and scope

The user clarified that switching to another app preserves the current bighelp screen when returning, but the connection is dead. Navigation restoration and crash recovery are therefore excluded. The app already invokes the full authenticated refresh on launch and foreground; adding a second logout-like pipeline would duplicate it and risk account data.

## Confirmed findings and changes

| Finding | Evidence | Change | Complexity |
| --- | --- | --- | --- |
| Scroll observation grows with settled history | The production scroll-key construction/equality path took a median 11.778 ms for 200 reads with 100 settled messages, versus 118.598 ms with 1,000. The scale regression failed. | Delete full-message/activity arrays from the observation key; use the rendered transcript revision, send state and clarification IDs. | 3/10 |
| Foreground joins stale pre-suspension refresh | A controlled suspended refresh blocked a new foreground refresh. The regression observed one connection instead of two and allowed old work to publish. | Invalidate, cancel and detach suspended refresh ownership synchronously; retain normal same-active coalescing. Late old completions cannot replace new state. | 5/10 |
| Explicit retry is ignored during failed replacement backoff | The real socket client remained retrying with two transports after an explicit retry; expected a third verified connection. | Coalesce only while a replacement handshake is actually connecting, not while a failed attempt waits in backoff. | 2/10 |

```text
Leave active scene → invalidate stale refresh ownership
Return → existing authenticated refresh → fresh socket → reload stores
Failed replacement → explicit retry → new handshake, without logout

Transcript mutation → revision changes → constant-size scroll comparison
```

The revision advances for array changes and in-place activity-group changes. Background catch-up still defers presentation while preserving received events. User draft edits alone do not invalidate scrolling. No message/history deletion, account reset, credential replacement, new timer, dependency, transport route or server change was introduced.

## Measurements

Xcode 26.6, Debug, arm64 iPad simulator on iOS 26.5. Synthetic settled assistant paragraphs plus a real controlled streaming-tail update. One warmup and five samples per size; each sample builds/compares the scroll observation key 200 times against the prior tail. The baseline recipe used the same constructor as ChatView; the candidate calls the exact production ChatModel key method. Milliseconds per 200 reads:

| Settled messages | Baseline samples | Candidate samples | Median before → after |
| --- | --- | --- | --- |
| 100 | 11.675292, 11.951959, 11.777625, 11.780958, 11.620500 | 0.035292, 0.035458, 0.035500, 0.035875, 0.035750 | 11.777625 → 0.035500 |
| 1,000 | 118.928583, 119.062834, 118.597583, 116.268541, 115.660708 | 0.035291, 0.035458, 0.035334, 0.035333, 0.035375 | 118.597583 → 0.035334 |

This is removal of a specific history-scaled UI cost, not an end-to-end app speedup, frame-rate measurement, memory profile or live-network latency claim. Timing values are simulator-specific. The regression threshold was set before implementation: the 1,000-message median must be no more than four times the 100-message median; baseline was about ten times.

## Verification

- Parent-reviewed production and test diff; native app compiled.
- Final focused native run: 45 executed tests in three suites, all passed.
- Real coordinator plus real socket client, synthetic transports: a held old store load does not block a new verified connection; original credentials remain unchanged; late cancelled work does not publish.
- Failed replacement backoff, duplicate retry coalescing and exact replacement-generation ownership covered.
- Same-ID streaming updates, in-place tool updates, deferred presentation, clarification changes and unrelated draft edits covered.
- The actual ChatView in a UIHostingController follows growing same-row content and idle incoming messages.
- Earlier focused runs also passed live-tail projection, activity insertion/group append and background catch-up preservation checks.

Use the repository's explicit `xcodebuild test` command and select `BighelpAppReadinessTests`, the named recovery tests in `BighelpLinkLiveSocketTests`, and the scroll/visible-canvas tests in `ChatModelTests`. Performance reproduction: `-only-testing:'BighelpTests/ChatModelTests/timelineScrollObservationCostDoesNotGrowWithSettledHistory()'`. Use one explicit project, simulator and reusable DerivedData root. A shared runner switched to an unrelated checkout during one attempted retry reproduction; that zero-selection result was excluded and the correct checkout was exercised directly. Neither `BighelpAppReadinessTests` nor `BighelpLinkLiveSocketTests` is in the repository today. The Link transport is retired.

## Remaining opportunities, not claimed fixes

- The September 11 follow-up coalesces live catalog writes across sessions and moves automatic checkpoint encoding off the main actor. Explicit durability boundaries still synchronously commit the catalog, and automatic atomic file replacement still runs on the owner actor. See [the measured scope and remaining limits](SHORTCUTS_AND_LIVE_CHAT_RELIABILITY.md); this is not a claim of zero disk latency or physical-device frame pacing.
- `SessionsModel.searchTokens(for:)` rebuilds normalized transcript search text on each nonempty-query filter evaluation. An incremental index may help large catalogs, but no search-speed improvement is claimed here.
- Open chat models retain full live history, and active route-unowned models are intentionally retained to finish work. Do not delete live data or cap visible history merely to lower memory. A device allocation profile is needed to distinguish expected growth from leaked resources.
- Store reloads remain sequential. Blind parallelization can contend for the ordered encrypted transport and does not establish lower end-to-end latency.

The exact 20–30 minute physical-device suspension incident and all real-network failure modes remain unverified. These repairs address reproduced local failure mechanisms. This historical task did not authorize a merge, TestFlight upload, installed-plugin change, cloud rollout or service restart; later chat release evidence is recorded separately in the current validation report.
