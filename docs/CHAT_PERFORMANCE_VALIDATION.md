# Chat performance validation

Baseline: `origin/main` at `ed0b069` (pulled September 10, 2026).
Working branch: `fix/chat-streaming-performance`.

Status: shipped to internal TestFlight as **2.0.1 (8)** on September 10, 2026.
The user subsequently accepted this chat experience as the baseline to preserve.
Future work follows the [Chat interaction contract](CHAT_INTERACTION_CONTRACT.md)
and [reproduction commands](DEVELOPMENT.md#chat-regression-checks). This report
retains the original measurements, failed probes, and evidence limits.

## September 11 consecutive large results: local follow-up

This follow-up is implemented and tested locally; it is not a new TestFlight
release or evidence of direct transport completion. The earlier fixture
interleaved tools with assistant prose. A new scenario sends 100 consecutive
expanded tools with roughly 64 KiB results while another retained chat updates.
Before the preview change it exceeded the 45-second completion deadline.
A process sample showed main-thread table snapshot work forcing SwiftUI text
measurement. Measured physical footprint was 228.4 MiB, with a 381.7 MiB peak;
process RSS was not used as the footprint measurement.

Tool previews now bound inline layout and retain full content through a separate
lazy reader and exact original-source copying. Final local Debug validation on
the iPhone 17 Pro / iOS 26.5 simulator passed 16 unit tests and two UI tests.
The complete-reader UI test reaches a unique final-page marker, copies the value,
pastes it into the app composer, and compares the exact original JSON. An
unchanged two-active-chat typing/scrolling scenario also passed earlier in this
follow-up. Reader preparation has a separate cancellation regression.

| Fixture | Stream elapsed | Main-queue maximum | Answer queue p95 | Display callback p95 | Maximum display gap |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 consecutive expanded tools + second active chat | 9 s | 63 ms | 35 ms | 66 ms | 117 ms |

This removes the reproduced fixture hang; 66 ms display p95 does not establish
60 FPS. Real-device performance, host backlog behavior, direct Tailscale routing,
and long Shortcut execution remain separate acceptance checks.

## Diagnosis

The original canvas moved the most recent assistant message between an eager
container and a lazy history container as each following message arrived. A real
UIKit regression demonstrated that this replaced the earlier `UITextView` and
cleared its selection. Expanded tool streaming also exceeded the 45-second
completion deadline. A CPU sample captured sustained SwiftUI lazy-layout and
AttributeGraph work.

Changing scroll anchors alone did not resolve the lockup when dragging through a
large answer that was still growing. The canvas therefore uses a native table
for recycling, row sizing, drag/deceleration, and scroll position. SwiftUI still
renders the existing message cards, actions, and composer.

A later native-canvas CPU sample identified synchronous session serialization
from every terminal tool event as another repeated main-thread cost.
Tool events now share the existing bounded checkpoint; completion, stop,
navigation and lifecycle flushes retain their explicit durability boundaries.

Growing answers also replaced their entire attributed text buffer. The native
text view now compares canonical rendered revisions and replaces only the
changed suffix, including earlier formatting changes when necessary. TextKit's
internally added fallback-font attributes do not invalidate unchanged content.

## Behavior under test

- Stable message identity and native text selection after appending a new message.
- Native typing, emoji caret offsets, first-responder and undo-manager continuity
  while a live answer changes beside 400 historical messages.
- A bounded set of visible cells with 1,000 historical rows.
- Reader position and row identity when earlier history is inserted.
- Replacing a prepared model with matching session/row IDs retires old callbacks.
- Recycled cells start with their new row's own local state.
- Unsent clarification text and multi-select choices belong to the request's
  model, survive recycling, and are cleared at request/account boundaries.
- Appending formatted text retains the stable TextKit prefix, native selection,
  and exact characters/attributes across edits and emoji boundaries.
- Every tool result survives a coalesced persistence checkpoint.
- Hands-off streaming remains at the actual tail; dragging/expanding details
  releases automatic following until the reader returns.
- Sending a new message from older history explicitly resumes following.
- Existing completed-turn, disclosure, transcript-reconciliation and geometry
  regressions remain part of validation.

## Evidence and limits

The native UIKit regression suite verifies actual view identity, selection,
first-responder state, caret offsets, cell reuse and visible row geometry. UI
tests exercise disclosure/collapse/reopen, scrolling an expanded tool offscreen
and back, returning to the latest answer, and 20 gated batches of growing text.
The gates let XCTest prove that content changed between observations instead
of inadvertently sampling only a completed stream.

The final Debug run passed **267 tests in six unit suites** and **10 UI tests**
on an iPhone 17 Pro simulator running iOS 26.5. The unit run took 21.722 seconds;
the UI scenarios took 257.359 seconds. The iPad portrait canvas was additionally
inspected with the work trail and an individual tool expanded. Text, tool copy
controls, the composer and Return to Latest remained visible and accessible.

Final Debug measurements (milliseconds unless stated otherwise):

| Fixture | Stream elapsed | Main-queue maximum | Growing-answer main-queue p95 | Display callback p95 |
| --- | ---: | ---: | ---: | ---: |
| 100 tools, fully expanded | 11.635 s | 93.76 | 44.50 | 206.64 |
| 100 tools, collapsed | 9.735 s | 85.76 | 43.95 | 101.66 |
| 5 tools, collapsed | 3.701 s | 69.97 | 34.76 | 50.28 |

The final optimized run also passed **all 12 native regression tests and all
three stress scenarios**. Its measurements were:

| Fixture | Stream elapsed | Main-queue maximum | Growing-answer main-queue p95 | Display callback p95 |
| --- | ---: | ---: | ---: | ---: |
| 100 tools, fully expanded | 11.168 s | 98.64 | 43.53 | 200.63 |
| 100 tools, collapsed | 9.700 s | 64.12 | 40.79 | 66.81 |
| 5 tools, collapsed | 3.685 s | 50.83 | 31.86 | 49.93 |

The original expanded-stream reproduction exceeded its 45-second completion
deadline. These measurements demonstrate completion and bounded main-queue
work under the fixture; they do not establish 60 FPS. An exploratory 50 ms
display-callback-p95 assertion was not met. The final responsiveness checks use
the independent main-queue probe (maximum below 250 ms; growing-answer p95 below
50 ms) while retaining the original 500 ms display-stall and 30-second completion
guards. The slower display-callback measurements remain in every result.

The simulator stress fixture uses 100 alternating formatted assistant messages
and tool calls, with work trails and individual tool details expanded, followed
by 40 updates to one growing answer. A CADisplayLink requests a 60 Hz cadence and
records callback gaps. Completion is observed through a Darwin notification,
avoiding repeated accessibility-tree snapshots during measurement.
A separate main-queue timer records scheduling gaps, including the answer-only
phase. Display callbacks are not interchangeable with main-queue latency:
under this simulator's expanded burst, the measured display callback gaps are
substantially larger than the independent main-queue gaps.

Performance checks also use compiler optimization with DEBUG fixture code and
testability explicitly enabled. This is an optimized simulator test build, not
an App Store archive. Simulator callback timing is not a physical-device FPS
measurement. These simulator results do not establish physical-device frame
rate or live-host acceptance. The separate release and product acceptance below
do not change that measurement boundary.

The work started from freshly fetched `origin/main`. Existing simulator data,
DerivedData and verified old local build output were cleared first, recovering
approximately 30 GiB before the new validation builds. Source, the existing
untracked `.asc/` directory, release archives and dSYMs were preserved.
After validation, the iPhone and iPad simulators used for this task were shut
down and 1.4 GiB of intermediate result bundles were removed. Logs and the
original regression/final result bundles remain. The final disk reading was
57 GiB available; fresh build output and the final app products remain local.

## Release and product acceptance

The production 2.0.1 (8) arm64 archive used Release optimization without DEBUG
fixtures or testability. Export verification checked matching app/watch/extension
versions, distribution signatures, production push entitlements, disabled
debugging, and matching executable/dSYM identity. Apple processing reached
`VALID` and `IN_BETA_TESTING`; all four internal group build relationships and
the saved test notes were read back. The signed artifacts and source manifest
are retained outside the repository.

The user's subsequent feedback explicitly established this as how chat should
feel and requested durable documentation to prevent regressions. This is product
acceptance of the experience, not an instrumented physical-device FPS result.
Future comparisons must retain the fully expanded fixture, growing-answer phase,
reader-control and native-input cases, and the slower display-callback results
alongside the independent main-queue measurements.
