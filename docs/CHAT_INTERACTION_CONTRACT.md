# Chat interaction contract

bighelp's chat should feel like a native conversation: users can read, type,
inspect tools, and follow a response without managing the interface themselves.
The user accepted the experience shipped in **2.0.1 (8)** on September 10, 2026
as the baseline to preserve. Visual redesigns and new features inherit this
contract. Smoothness must not come at the expense of content or input accuracy.

This is the current behavior contract for the shipping iPhone/iPad chat. Read it
before changing the canvas, message rendering, activity disclosures, composer,
hosted cards, presentation dependencies, or chat persistence. Historical design
plans do not authorize reverting to their earlier scroll implementations.

## Required user experience

| Situation | Required behavior |
| --- | --- |
| A response grows while the reader is following it | Follow the actual laid-out tail continuously. Do not replay scroll animations, jump over the same tool repeatedly, or move earlier messages between containers. |
| The reader drags through history or opens work details | Reader interaction takes ownership immediately. Streaming continues without pulling the reader away; drag and deceleration remain native. |
| The reader reaches the bottom, taps Return to Latest, or sends a message | Resume following. Sending from older history must expose the new live answer, including reference and mid-session send paths. Respect Reduce Motion for explicit navigation. |
| Previous history is inserted or a tool is expanded | Preserve the reading context and semantic row identity. Never make a disclosure toggle an implicit jump to the bottom. |
| A short first response arrives | Start naturally below the header; do not force a short conversation to the bottom of an otherwise empty canvas. |
| A long answer gains text or formatting | Keep exact text, Markdown-derived formatting, Unicode boundaries, and valid selection. Earlier formatting corrections and shorter replacements must still apply. |
| The user types while messages and tools arrive | Preserve the native editor, first responder, caret, selection, undo state, and draft. Streaming must not reopen a dismissed keyboard or dismiss an active editor. Explicit user dismissal remains available. |
| The user taps the visible input surface | The entire visible input, including its padding, focuses the native editor. Padding hit surfaces sit behind the editor so native caret placement and text selection keep their gestures. |
| The composer is empty or contains one line | The microphone and Send controls share the input's vertical center. Preserve bottom alignment when the native editor grows to multiple lines. |
| A tool or clarification card scrolls offscreen and returns | Preserve explicit disclosure choices and request-scoped unsent clarification text/choices. Reusing a cell for another row must not transfer local state to it. |
| A session or model owner is replaced | Retire old callbacks and state ownership even when row IDs match. Actions and live presentation must reflect the current owner. |
| A conversation becomes large | Keep visible view construction bounded and input usable with expanded tools. Retain the complete authoritative content; hiding or dropping results is not a performance fix. |

V3 is the only shipping interface in `SettingsStore`; legacy enum values remain
decodable for preference migration. Themes, typography, rich cards, accessibility
settings, and future presentation variants must preserve these same behaviors.

## Implementation boundaries

The current implementation has one scroll owner and separate lifetimes for
canonical data, reader state, and disposable views:

| Responsibility | Owner and invariant |
| --- | --- |
| Ordered transcript and accepted events | `ChatModel` and the existing transcript projection. Preserve request/session/agent validation, ordering, reconciliation, and terminal results. |
| Native scrolling and layout | `NativeChatTimeline`, `ChatTimelineTableView`, and `ChatTimelineController`. One self-sizing, recycling table contains the canvas; the composer stays outside it. |
| Row identity and update scope | Semantic `ChatCanvasRow.id` plus conversation and model-owner identity. Reconfigure changed content while retaining unchanged visible history. Do not use array positions, fresh UUIDs, or streaming text as identity. |
| Expanded activity | `ChatCanvasTranscriptProjection` projects work-trail headers and individual tool events as sibling native rows. Completed-turn folds retain their disclosure header and project expanded contents separately. A hundred expanded tools must not become one giant hosted cell. |
| Text storage | `ChatNativeTextStorageUpdater` compares canonical old/new attributed text, preserves the unchanged prefix, and edits the changed suffix. TextKit's added fallback attributes are not a new canonical revision. |
| Reader choices and drafts | The prepared chat's disclosure store owns explicit tool/fold choices. `DashboardModel` owns clarification drafts by item, session, and request; removal/account reset prunes them. These are local presentation state, not a new transcript authority. |
| Hosted SwiftUI content | `HostedRow.body` preserves Observation, and `.id(row.id)` scopes recycled local state. Propagate public presentation values and app dependencies without replacing the hosting configuration's private layout/accessibility environment. |
| Persistence | Existing bounded checkpoints coalesce draft/tool writes. Live final-turn, stop, navigation, and lifecycle paths retain explicit flushes. Historical final answers and subagent lifecycle updates share the catch-up checkpoint; a terminal tool must not synchronously rewrite the entire retained session. |
| Idle startup | Home, sidebar and Sessions hold stable presentation during catch-up and publish the accumulated state once. Routing and actions continue to resolve canonical records. See [idle startup reliability](IDLE_STARTUP_RELIABILITY.md). |

Tail following occurs after UIKit layout and yields during tracking, dragging,
and deceleration. The deferred publication of the bottom-state Boolean is for
controls; it must not become another delayed offset writer. Do not reintroduce
competing `ScrollViewReader`/`scrollTo` tasks, geometry feedback loops, or separate
eager live-tail and lazy-history containers.

Keep native self-sizing and measured heights associated with semantic rows and
width. Invalidate relevant measurements when content or presentation changes.
Speculative row prefetching is disabled for this canvas because growing, rich
rows multiplied hosting/layout work. Re-enabling it or replacing the container
requires comparative evidence for expanded tools, growing text, and user drag.

Stable identity must not freeze a row's observable pending state, theme, controls,
or callbacks. When adding an environment dependency, review both hosted-value
propagation and the coordinator's style/owner invalidation. Preserve the row's
own accessibility graph; wholesale copying of `EnvironmentValues` broke it.

Native recycling bounds instantiated views; it does not make all transcript
projection, decoding, or persistence constant-time. Measure the affected path.
Keep background catch-up's authenticated event handling and deferred presentation
boundaries described in [Background chat continuity](BACKGROUND_CHAT_CONTINUITY.md).

## Regression coverage

The historical suite name `ChatTimelineRenderPartitionTests` now protects the
native canvas. It does **not** require restoring the old rendering partition.
Its [actual UIKit tests](../BighelpTests/ChatTimelineRenderPartitionTests.swift)
cover these boundaries:

| Boundary | Regression tests |
| --- | --- |
| View identity and selection | `appendingTextPreservesThePreviousNativeMessageAndItsSelection` |
| Bounded cells and reading position | `nativeRowsRecycleAndPrependingHistoryKeepsTheVisibleMessageInPlace`, `oneExpandedWorkTrailRecyclesIndividualToolRows` |
| Correct reuse, observation, and owner replacement | `recycledRowsStartWithTheirOwnLocalState`, `livePresentationChangesUpdateAnOtherwiseUnchangedRow`, `replacingTheModelWithMatchingRowIDsRetiresItsVisibleActions` |
| Exact incremental text | `incrementalNativeTextPreservesExactCharactersAndFormatting`, `streamingTextEditsOnlyTheChangedSuffix` |
| Native input continuity | `typingDuringLongHistoryStreamingKeepsTheNativeComposerAndCaret` |
| Clarification lifetime | `clarificationDraftSurvivesScrollingOffscreenAndBack`, `clarificationDraftsAreScopedToTheRequestAndAccount` |
| Batched writes without lost results | `completedToolBurstsShareOnePersistenceCheckpointWithoutLosingResults` |
| Shared persistence across running chats | `twoUnmountedChatsCheckpointTogetherWithoutBlockingEveryLiveEvent`, `aLargeAutomaticCheckpointLeavesTheMainActorResponsive` |
| Idle startup and queued finals | `reopeningWithQueuedFinalAnswersUsesOneCatalogCheckpoint`, `historicalCatchUpPublishesHomeAndSidebarOnceWithoutReplayingOldWork`, `testOpeningHomeWithCompletedHistoryAndQueuedDeliveryRemainsResponsive` |
| Catch-up and reference checkpoints stay bounded | `catchUpToolBurstsStayCoalescedUntilTheirDurableCheckpoint`, `streamingDoesNotRepeatAnUnchangedReferenceDurabilityWrite` |
| Old encoders cannot overwrite newer drafts or another host | `inFlightCheckpointsPreserveNewerDurableAndAccountState` |
| Typing and review during two active chats | `testTypingAndScrollingWithTwoActiveLongChats` |

Run [ChatStreamingAnchorUITests](../BighelpUITests/ChatStreamingAnchorUITests.swift)
for the three short/long/expanded stress scenarios, growing-tail following,
reading during a stream, consecutive tool turns, sending from history, and first
short-response placement. Run
[ToolDisclosureUITests](../BighelpUITests/ToolDisclosureUITests.swift) for expanded
tool reuse, enclosing-trail recreation, and completed-fold context.

Run [ComposerInteractionUITests](../BighelpUITests/ComposerInteractionUITests.swift)
for visible-padding focus and action/input geometry. Validate actual keyboard
appearance and rendered element frames; a focus Boolean alone cannot establish
that the visible input accepts the user's tap.

Retain the adjacent `ChatModelTests`, `ChatCanvasGeometryTests`,
`ChatCompletedTurnTests`, `ChatActivityDisclosureTests`, and `DashboardModelTests`
coverage. Renderer checks do not replace lifecycle, durability, reconciliation,
or request-boundary tests. The older `timelineScrollKey` microbenchmark alone
does not exercise the shipping table or establish smooth scrolling.

See [Development: chat regression checks](DEVELOPMENT.md#chat-regression-checks)
for the exact selectors and optimized simulator recipe. The default hosted smoke
selection does not include the two chat UI suites; a generic green CI badge is
not evidence that these scenarios ran.

## Acceptance and evidence

For a change affecting this contract:

1. Reproduce the affected interaction with synthetic content, including expanded
   tools and a response that is still growing. Check actual native identity,
   text/selection, or geometry where relevant; a state-only assertion is not a
   substitute for a visible scroll/input regression.
2. Run the focused regression set, then the broader affected coverage. Use gated
   stream progress to prove that content changed between observations. Do not
   mistake an already completed stream for a passing follow/reader test.
3. For performance changes, also run the optimized simulator stress recipe and
   retain elapsed time, display-callback gaps, and independent main-queue gaps.
   Avoid continuous accessibility-tree polling during timed measurement; verify
   completion and rendered content afterward.
4. Exercise affected layouts on iPhone/iPad in portrait/landscape, with the
   keyboard open and dismissed, Dynamic Type, VoiceOver, and Reduce Motion.
   Report which cases were observed and which remain untested.
5. Compare the same fixture, configuration, and environment. Keep raw results
   and prior failures. Do not silently raise thresholds, remove expanded-tool
   coverage, truncate content, or suppress valid events to make a run pass.

The current stress guards require completion within the 45-second observation
deadline, recorded elapsed time below 30 seconds, a maximum display-callback gap
below 500 ms, maximum independent main-queue gap below 250 ms, and growing-answer
main-queue p95 below 50 ms, with more than ten display and answer-queue samples.
These are regression guards, not a definition of ideal interaction or a 60 FPS
claim. Display-callback p95 is retained as a diagnostic, not a passing 50 ms gate.
The accepted baseline and the exploratory display-p95 failure are preserved in
[Chat performance validation](CHAT_PERFORMANCE_VALIDATION.md).

Swift Testing completion and XCTest UI completion must both show that the
intended cases actually ran. A zero-test selector, compile, screenshot, upload,
or successful TestFlight processing cannot replace interaction evidence.
The user's acceptance of build 2.0.1 (8) establishes the product baseline;
physical-device frame-rate claims still require device measurements.

## Glass, startup and suggested prompts

Native Liquid Glass controls need the scrolling content behind them. Keep the
chat table full height, overlay the measured header and composer, and let the
table own their content/indicator insets. Do not reintroduce opaque fills behind
glass or duplicate the insets in a second SwiftUI scroll container. Preserve
Reduce Transparency and older-platform fallbacks. UIKit owns active gestures;
an inset change must not force a content offset during dragging/deceleration.

Suggested prompts are compact, readable text-and-icon controls with at least a
44-point hit target. Use explicit text layout inside hosted cells, bounded by
the available width. Verify default and accessibility Dynamic Type; a label in
the accessibility tree does not prove the title is visibly rendered. Selecting
a prompt retains the established quick-action behavior.

Home may appear from cached admission before the host is ready. Dashboard loads
must wait for the verified connection and reject results from a replaced
connection. Navigation cancellation must not become a visible load failure.

Long-pressing the bighelp logo in every workspace sidebar presents the same
loaded host selection state.


## Composer and recovery ownership

A temporarily unavailable optional reference provider must not retire a prepared
chat, discard plain text, or prevent ordinary Send. `ReferenceChatComposition`
may bind the hub to no owner while account recovery runs; it must preserve the
composer. Reference preparation and canonical delivery still require the exact
current account, host, session, agent, recipients and authorization epoch.

Real account/host replacement permanently retires old composers. Host selection
must apply this fence synchronously, in the same main-actor turn that changes
the socket target, before queuing asynchronous reconnection. Retired callbacks
must remain rejected even if an old provider returns or session IDs match.

Selecting another agent in an empty direct chat preserves unsent text. It clears
reference review IDs and old remote-session coordinates, rebinds the owner, and
persists against the current model identity and session coordinates. Persistence
callbacks must not retain the original agent assignment as permanent authority.
Never bypass a failed durable reference checkpoint: nothing may be uploaded or
sent until that exact intent has been saved successfully.

`ReferenceDeliveryAcceptanceTests` mounts the real composition and protects
provider loss/recovery, account retirement, ordinary and reference Send after
agent selection, and the synchronous host-switch fence. Keep these tests beside
the canonical byte-preservation, uncertain-delivery and failed-checkpoint cases.


## Sidebar and optional project context

Home, Scratchpad, Wiki, Scheduled Tasks, Skills & Tools and Settings form one
continuous navigation group: do not add a divider after Wiki. Pinned agent previews
follow the navigation, with sessions below; preserve the existing bounded previews
so navigation and some content remain visible together.

A selected non-repository folder remains valid chat context. Its Changes rail reads
N/A rather than presenting an error or Retry. Only the typed host non-repository
result authorizes that presentation; missing Git, unsafe configuration, timeouts
and failing repositories must stay distinguishable and recoverable.

All-category GitHub reference discovery may return incomplete results when an
independent request fails. Keep successful repositories/issues/PRs, disclose partial
results and continue searching other kinds. Retire all rows when the credential,
account, host or owning chat changes, including during an in-flight search.
