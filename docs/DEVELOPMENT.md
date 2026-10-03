# Development guide

Production transport contract: **native Hermes only for chat**. Cloud services
are used only for optional notifications and Live Activities, which BuzzKit delivers. The current composition,
voice boundary, enrollment isolation and verification requirements are defined
in [Native transport](NATIVE_TRANSPORT.md). Retained Link/paired-Direct protocol
sections below describe legacy compatibility code, not a selectable chat path.

## Requirements

- macOS
- A current Xcode with Swift 6 support
- XcodeGen 2.43 or newer
- An iOS 17+ simulator or physical device

ThinkingOrbsKit is vendored under `Packages/ThinkingOrbsKit` because the
upstream monorepo does not expose its nested Swift package at a remotely
resolvable SwiftPM root. Keep its MIT license and `PROVENANCE.md` with the
package, and verify the pinned upstream files before updating it.

## Generate the Xcode project

The project is configured by `project.yml`:

```sh
xcodegen generate
```

Do not edit the generated project file by hand. Regenerate it after adding,
removing, or moving source and resource files. The generated
`Bighelp.xcodeproj` is intentionally committed so Xcode can open the repository
without a generation step; it must match `project.yml`.

## Build

```sh
xcodebuild build \
  -project Bighelp.xcodeproj \
  -scheme Bighelp \
  -destination 'platform=iOS Simulator,name=<available simulator>'
```

When another build process is active, use a separate `-derivedDataPath` to avoid
locking or corrupting shared incremental state.

## iPhone tools and input regressions

Run the native permission, Apple service, mutation journal/coordinator and directed
socket suites listed in [the device-tools contract](IPHONE_DEVICE_TOOLS.md).
`DeviceToolPermissionsUITests` must show three independent controls off without
requesting real OS access. `ComposerInteractionUITests` must focus from visible
padding and align microphone/Send on iPhone and iPad. Native grants must stay
separate from system permission status, and delayed callbacks cannot restore
revoked access. Health reads must retain raw-query coverage and truncation.

Plugin tests require an isolated `HERMES_HOME` before imports. Use ordinary
(non-symlinked) temporary directories for both the home and `TMPDIR`. The bundled
plugin has both package and legacy fixture imports: include the plugin root and
its `tests` directory on `PYTHONPATH`, followed by the matching Hermes checkout,
and run `python -m unittest discover -s tests -t . -v`. Preserve intentional
bundled steering and completion/attention behavior when applying standalone
plugin updates; apply the feature diff rather than replacing those modules.

The Hermes `ToolExecutionContext` extension is a required host dependency. A
plugin doctor/import check cannot establish running gateway activation. Verify
the loaded plugin revision and a fresh connected Link state after one restart.
Record physical Health/EventKit acceptance separately from injected-boundary
and simulator checks.

## Mac app (Mac Catalyst)

The shipping Mac app is the iPad app through Mac Catalyst:

```sh
xcodebuild build \
  -project Bighelp.xcodeproj \
  -scheme BighelpCatalyst \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/bighelp-mac-dd
open /tmp/bighelp-mac-dd/Build/Products/Debug-maccatalyst/bighelp.app --args -use-demo-fixtures -disable-demo-delays
```

`-start-chat-mid-session` opens a demo chat whose agent is still working, for trying Command-Return.
`Scripts/release-mac.sh` archives it, exports it with Developer ID, wraps it in a signed and notarized DMG and
posts it to GitHub Releases (`--no-publish` stops after the DMG).

## Native macOS foundation (prototype)

Build and test the native Mac target with one reusable DerivedData root:

```sh
xcodebuild build \
  -project Bighelp.xcodeproj \
  -scheme BighelpMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/loopdy-macos-issue-26-derived

xcodebuild test \
  -project Bighelp.xcodeproj \
  -scheme BighelpMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/loopdy-macos-issue-26-derived
```

The initial responsive proof sizes are **760 × 620 points** (compact) and
**1440 × 896 points** (wide). At compact width, the split view may collapse the
inspector before any conversation or composer action clips. The app has a
720 × 560 point minimum window size.

## Test

```sh
xcodebuild test \
  -project Bighelp.xcodeproj \
  -scheme Bighelp \
  -destination 'platform=iOS Simulator,name=<available simulator>'
```

The unit targets use Swift Testing. The iOS UI target uses XCUITest. Tests cover
feature models, persistence/migrations, protocol validation, cryptography,
push, Live Activities, voice,
navigation, and accessibility-facing presentation.

Use the smallest relevant test target while iterating. The hosted release gate
runs the native suite and focused UI regressions once; the complete phone/iPad
matrix is available by explicit manual request.

### Chat regression checks

Read the [Chat interaction contract](CHAT_INTERACTION_CONTRACT.md) before
changing chat rendering, scrolling, input, hosted cards, or persistence. The
accepted [2.0.1 (8) baseline](CHAT_PERFORMANCE_VALIDATION.md) includes expanded
tools and long growing answers; collapsed or completed-only fixtures are not
sufficient substitutes.

From the repository root, choose an installed simulator UUID and reuse one
DerivedData directory. Run the integrated Debug regression set:

```sh
CHAT_SIMULATOR_ID='<available simulator UUID>'
CHAT_DERIVED_DATA="$PWD/DerivedData"
xcodebuild test \
  -project Bighelp.xcodeproj -scheme Bighelp -configuration Debug \
  -destination "platform=iOS Simulator,id=$CHAT_SIMULATOR_ID" \
  -derivedDataPath "$CHAT_DERIVED_DATA" -parallel-testing-enabled NO \
  -only-testing:BighelpTests/ChatTimelineRenderPartitionTests \
  -only-testing:BighelpTests/ChatModelTests \
  -only-testing:BighelpTests/ChatCanvasGeometryTests \
  -only-testing:BighelpTests/ChatCompletedTurnTests \
  -only-testing:BighelpTests/ChatActivityDisclosureTests \
  -only-testing:BighelpTests/DashboardModelTests \
  -only-testing:BighelpUITests/ChatStreamingAnchorUITests \
  -only-testing:BighelpUITests/ToolDisclosureUITests
```

The baseline executed 267 Swift Testing cases and ten XCTest UI cases. Counts
can grow; confirm the intended suites and cases ran, passed, and were not
skipped. Swift Testing reports its own `Test run with ... tests ... passed`
line; an XCTest wrapper reporting zero tests is not the Swift Testing result.
An unselected/zero-test run does not validate the change.

For Shortcuts or shared session persistence changes, also run
`BighelpShortcutServiceTests`, `BighelpAppIntentContractTests`, `BighelpAppReadinessTests`, `SessionCatalogStoreTests`,
`DemoRepositoryTests`, `ReferenceDeliveryAcceptanceTests` and `ShellFeatureStoreTests`.
Include `testTypingAndScrollingWithTwoActiveLongChats` in the UI pass. It exercises
the real feature store and repository while a second prepared chat retains 1,000
messages and receives context, tool and text updates. See
[Shortcuts and live chat reliability](SHORTCUTS_AND_LIVE_CHAT_RELIABILITY.md).
For wait-enabled intent changes, separately verify the existing saved Shortcut
on a physical iPhone with both a quick answer and an answer taking over 30
seconds. Confirm the next action receives the final text. Simulator service
tests and generated App Intents metadata do not prove the OS execution lifetime.
Individual Swift Testing selectors require the function signature, including
`()` or parameter labels; inspect the executed count even if discovery succeeded.

For performance changes, also run this **simulator-only** optimized recipe in
bash or zsh, using the same simulator and DerivedData variables:

```sh
chat_stress_args=(
  -project Bighelp.xcodeproj -scheme Bighelp -configuration Release
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES
  -destination "platform=iOS Simulator,id=$CHAT_SIMULATOR_ID"
  -derivedDataPath "$CHAT_DERIVED_DATA" -parallel-testing-enabled NO
  -only-testing:BighelpTests/ChatTimelineRenderPartitionTests
  -only-testing:BighelpUITests/ChatStreamingAnchorUITests/testExpandedLongToolStreamKeepsMainThreadResponsive
  -only-testing:BighelpUITests/ChatStreamingAnchorUITests/testLongToolStreamKeepsMainThreadResponsive
  -only-testing:BighelpUITests/ChatStreamingAnchorUITests/testShortToolStreamKeepsMainThreadResponsive
)
xcodebuild build-for-testing "${chat_stress_args[@]}" && \
xcodebuild test-without-building "${chat_stress_args[@]}"
```

This enables DEBUG fixtures and testability **only** to measure optimized
simulator code. Never copy those overrides into an archive/export command.
The production Release archive must have no DEBUG define or testability
override. If the candidate changes after `build-for-testing`, rebuild before
using `test-without-building`.

The UI tests launch the synthetic tool stream with five or 100 tools; the
expanded scenario opens both work trails and individual tool details. They
measure growing text after the tool burst. Gated-stream tests separately prove
tail following and reader control while content changes. Inspect saved fixture
metrics and XCTest attachments as well as pass/fail; display-callback p95 and
main-queue p95 measure different things. Preserve logs and a `.xcresult` outside
source using a unique `-resultBundlePath` for each retained run.

Record affected iPhone/iPad orientation, keyboard, Dynamic Type, VoiceOver, and
Reduce Motion checks. Report untested cases explicitly. Run broader affected
tests for changes to shared models, settings, editors, or lifecycle boundaries.
The default hosted smoke profile does not select `ChatStreamingAnchorUITests`
or `ToolDisclosureUITests`; run them explicitly for relevant chat changes.

## Hermes plugin

The Hermes plugin lives in its own repository,
[promptclickrun/bighelp-plugin](https://github.com/promptclickrun/bighelp-plugin).
Install it with:

```sh
hermes plugins install promptclickrun/bighelp-plugin --enable
```

The app installs and offers the plugin's latest
[GitHub Release](https://github.com/promptclickrun/bighelp-plugin/releases); nothing is pinned in the app.

## Internal release automation

Before shipping persistence or catch-up changes, run `SessionCatalogStoreTests`,
`ShellFeatureStoreTests`, and
`BighelpLaunchTests/testOpeningHomeWithCompletedHistoryAndQueuedDeliveryRemainsResponsive`.
The idle Home fixture measures queued final answers and subagent rosters with no
active turn. Passing active-stream tests alone does not cover this path. Retain
the metric attachment and exact before/after source identity; see
[idle startup reliability](IDLE_STARTUP_RELIABILITY.md).

Install the pinned Ruby dependencies:

```sh
/opt/homebrew/opt/ruby/bin/bundle install
```

The repository pins Ruby in `.ruby-version` and provides `bin/fastlane`, which
prefers Homebrew Ruby on macOS and falls back to the active Bundler elsewhere.

The release lanes use the App Store Connect API key already registered with
`asc auth login`. On another machine or CI, set `ASC_KEY_ID`,
`ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY_PATH` instead. A readable `.p8` file is
required by Fastlane even when `asc` stores the key in the system Keychain.
Private keys and generated release artifacts must not be committed.

Ship the next available TestFlight build to every internal group:

```sh
bin/fastlane ios deploy_testflight notes:"What to test"
```

The lane asks App Store Connect for the next build number, updates
`project.yml`, regenerates `Bighelp.xcodeproj`, archives and uploads the app,
waits for processing, and adds the build to every internal TestFlight group.
Use `build_number:97` to override automatic numbering.
The lane prevents concurrent releases on one machine. CI systems running on
multiple release hosts must also configure a shared concurrency group.

Verify credentials, the next build number, and internal group discovery without
building or uploading:

```sh
bin/fastlane ios release_check
bin/fastlane ios release_check build_number:97
```

Install the exact current Git commit of the bighelp plugin and restart Hermes:

```sh
bin/fastlane ios hermes_plugin
```

Run both operations in order:

```sh
bin/fastlane ios release notes:"What to test"
```

## Fixture mode

The app can run without production services:

```text
-use-demo-fixtures
-disable-demo-delays
```

Additional launch arguments used by UI tests can select an initial screen. Keep
fixture content synthetic and never copy production data into tests.

## Runtime configuration

The notification service's address (`https://link.loopdy.app`) is fixed in
`BighelpNotificationBrokerClient`.

Configure Apple capabilities for:

- Push notifications
- Shared Keychain access between the app and notification service extension
- Live Activities

Use local build settings or secret-management systems for environment-specific
values. Never commit:

- Cloud service API tokens
- APNs keys or certificates
- Signing certificates or provisioning profiles
- Private host credentials
- Account content keys
- Device private keys
- Production database or namespace identifiers

The checked-in project contains the publisher's signing identifiers. External
contributors should substitute their own development team, bundle identifiers,
associated-domain entitlement, and Keychain access group. Fixture-mode simulator
development does not require access to bighelp's production cloud or Apple
credentials.

## Adding a feature

Use this pattern:

1. Define Codable/Sendable domain models.
2. Define a narrow `@MainActor` client protocol.
3. Implement a deterministic fixture client.
4. Implement the native Hermes or local client.
5. Create an `@Observable` feature model/store.
6. Add a SwiftUI view that receives the model.
7. Compose it in `BighelpAppComposition` or `ShellFeatureStore`.
8. Add focused unit tests and, where appropriate, UI tests.

Keep transport models separate from UI models. Validate every untrusted
boundary before converting it to app state.

## Persistence changes

Local JSON repositories are schema-versioned. When changing a persisted model:

1. Prefer additive Codable fields with safe defaults when possible.
2. Add a sequential repository migration for structural changes.
3. Test old, current, corrupt, and newer-than-supported files.
4. Never silently overwrite a file created by a newer app version.
5. Preserve crash-safe temporary-write and replacement behavior.

## Protocol changes

Multiple independently deployed components implement bighelp Link.
Protocol changes require compatibility tests for:

- Strict payload validation and bounds
- Old and new endpoints during rollout
- Unknown message handling
- Replay and sequence behavior
- Cancellation and reconnect behavior
- Revoked-device behavior
- Encryption and authentication failure

Do not document or log live protocol coordinates in public issues.

## Security and privacy checklist

Before merging a feature:

- Does it add durable local or cloud data?
- Can the routing plane decrypt any new payload?
- Does it add a required-reason API or collected-data category?
- Does it place sensitive text on the Lock Screen?
- Does it add a permission usage description?
- Are secrets in Keychain or secret bindings rather than UserDefaults/source?
- Are all external strings, identifiers, counts, and byte sizes bounded?
- Are callbacks and continuations identity-checked and settled exactly once?
- Is cancellation safe?
- Does sign-out, unpair, or revocation remove access?
- Are logs redacted?
- Are production and fixture paths both tested?

Update `docs/ARCHITECTURE.md` whenever any checklist answer changes.

## Code organization

Feature folders own their views, domain models, observable state, and adapters.
Cross-target code belongs only in the explicit shared folders. Avoid moving
secrets or production configuration into fixtures.

The `Hermes` folder contains a direct HTTPS client retained for compatibility
and testing. Production selects `NativeWorkspaceRuntime` and `DirectHermesWorkspaceClient`.
The older `HermesClient` is not the selected transport.

## Documentation safety

Public documentation may describe algorithms, boundaries, data classes, and
security properties. It must not publish:

- Production resource or account identifiers
- Secret values or key material
- Private routes or administrative commands
- Exact anti-abuse thresholds
- Exact key-rotation schedules
- Complete database schemas
- Production incident details that reveal an unpatched weakness

Security reports belong in private channels described by `SECURITY.md`.


## Hosted iOS validation and TestFlight

The `iOS build and tests` GitHub Actions workflow builds the XcodeGen project on
`macos-26`. By default, one simulator job with a 35-minute limit runs the native
suite and the focused UI regressions selected by
[`Scripts/ci_release_validation.py`](../Scripts/ci_release_validation.py), covering
References, keyboard dismissal, workspace navigation, expanded draft sending,
slash insertion, and rich editing/formatting. These are separate from the
[chat regression checks](#chat-regression-checks).
The short Wiki host and release-readiness checks run alongside it. Full phone/iPad
coverage requires manually enabling `full_suite`; it is not a release prerequisite.
Failed runs preserve the Xcode log, `.xcresult`, and generated project. Successful
default runs preserve the summary and a small exact-source validation receipt.
No Apple signing credentials are needed for simulator validation.

`Internal TestFlight` is a manually started workflow. After this workflow reaches
the default branch, open Actions → Internal TestFlight → Run workflow and choose
`main` and enter release notes. This release workflow does not run simulator
tests or require a CI receipt. Review the available validation evidence before
starting it; a release does not make a failed CI run passing. It archives/signs
the merged app and its extensions, uploads the IPA, waits for processing,
and verifies the exact version/build and internal group membership. It records
`release.json` beside the signed IPA. A failed upload/distribution must be
reconciled in App Store Connect before retrying; the next run chooses a new build
number rather than reusing an uncertain one. Concurrent hosted releases are
serialized.

Configure these repository Actions secrets (never commit or paste the values
into issues, chat, or logs):

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect team API key ID |
| `ASC_ISSUER_ID` | API issuer ID |
| `ASC_PRIVATE_KEY` | Full `.p8` private key, including PEM header/footer and real newlines |
| `IOS_DISTRIBUTION_P12_BASE64` | Single-line base64 of an Apple Distribution certificate **with its private key**, exported as `.p12` |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Password protecting that `.p12` |

The API key must access your App Store Connect app (see `APP_STORE_APP_ID` in
`fastlane/Fastfile`) and permit Xcode provisioning for your team
(`BIGHELP_DEVELOPMENT_TEAM`). Configure at least one
internal TestFlight group. A downloaded `.cer` alone cannot sign; the matching
private key is required. If the only copy is on an unavailable Mac, recover an
existing signing backup or use the optional [one-time CI signing setup](CI_SIGNING.md)
from a phone to prepare an encrypted identity. The release workflow does not revoke
or create certificates; the separate setup workflow creates one only after its
explicit manual confirmation. It installs the supplied identity in a temporary keychain
and deletes temporary signing files when finished. It uses the committed
Fastlane bundle and needs no preconfigured `asc` login on the runner.

Wiki folder registration also requires deploying the updated bighelp Hermes
plugin that advertises `wiki.connect`. The iOS workflow does not update or restart
an unrelated host. Deploy the committed plugin on the authorized host with the
existing plugin release procedure, then verify `hermes plugins doctor loopdy
--ci`, gateway health, and Wiki folder Save from the paired device. Existing
Wiki connections remain available on compatible older hosts; a missing new
operation produces an explicit host-update message.

Implementation references: [Fastlane TestFlight action](https://docs.fastlane.tools/actions/upload_to_testflight/),
[Fastlane Xcode signing](https://docs.fastlane.tools/codesigning/xcode-project/).

## Hermes Bot Mode and instance regression checks

Use [Hermes Bot Mode](HERMES_BOT_MODE.md) as the current runtime contract. Keep
its Link client, room-store and ChatModel integration suites green. Include
pending-send recovery, canonical event IDs, cursor/authority checks, explicit
Stop, failed-task retry and task-specific approvals. A direct-chat fixture is not
proof of native Hermes room execution or of the bighelp Native harness.

The UI gate includes default/AX XXXL suggested prompts, root content clearance
in portrait/landscape/accessibility sizes, Wiki navigation, Hosts/Connected
Devices and long-press instance switching. Keep primary-host preference separate
from immediate selection. Preserve the chat performance gate alongside this work.


## Draft, account recovery and drawer regression checks

For composer ownership or account recovery changes, run these actual suites:
`ReferenceDeliveryAcceptanceTests`, `ReferenceNativeEditorAcceptanceTests`,
`ReferenceHubTests`, `ChatModelTests`, `ShellFeatureStoreTests`,
and `BighelpAppStartupTests`. Confirm the selectors
execute tests. Preserve failure evidence before fixing the implementation.

The mounted reference tests must retain ordinary text through provider loss,
reject retired account/host callbacks, send to a newly selected agent, and persist
an actual canonical reference through the store callback after reassignment.
Host selection must disable the old composer before any `await`. Account tests
must distinguish protected-data recovery and partial-store failure from missing
credentials or a lost/replaced verified connection.

Link catalog changes and Worker rollbacks must also run the signed HTTP catalog
regressions in `services/link/test/http.test.ts`, the full Link suite, type check
and deployment dry run. The regression fixture must include a forward-migrated
Native row alongside an existing phone and Hermes host. Verify that v1 returns
its supported kinds and that all persisted rows, grants and schema are unchanged.
Do not fix this by revoking devices, changing keys or coercing Native to Hermes.
After deployment, verify the live signed account profile and device list; source
tests alone do not establish successful iPhone sign-in.

Run `BighelpLaunchTests/testQuickWorkspaceCompactNavigationKeepsMenusAndPreviewRowsVisible`
and `BighelpLaunchTests/testQuickWorkspaceCapsPinnedPreviewAndOpensAllAgentsRoute`
for drawer changes. Inspect their screenshots as well as geometry and hit-target
assertions. Keep navigation before the bounded pinned-agent preview and sessions;
verify the full Agents route remains reachable with more pins than the preview.

For scheduler compatibility, run the bighelp plugin contract, workspace-control
and portability suites with the installed Hermes source on `PYTHONPATH`, followed
by the official plugin doctor. The installed-module cron test must cover all seven
workers. A read-only live list can verify integration without creating or running
user tasks. Deploy the exact tested plugin revision and read back installed and
active state separately from TestFlight processing.
