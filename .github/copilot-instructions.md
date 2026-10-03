# bighelp repository instructions

## Product and repository

bighelp is a Swift 6 SwiftUI client for personal AI agents running through Hermes. This repository contains:

- the iOS and iPadOS app under `Bighelp/`;
- a notification service extension under `BighelpNotificationService/`;
- a Live Activity extension under `BighelpLiveActivity/`;
- shared extension models under `BighelpActivityShared/` and `Bighelp/NotificationShared/`;
- Swift Testing and XCUITest targets under `BighelpTests/` and `BighelpUITests/`;
- (the Hermes plugin lives in its own repository, promptclickrun/bighelp-plugin).

Production uses independently authenticated native Hermes REST and `/api/ws`.
Cloud services are allowed only for optional notifications and Live Activities. Never
restore Link chat routing, queues, workers, account-catalog startup gates, or the
old paired Direct listener. See `docs/NATIVE_TRANSPORT.md`.

Read these before making material changes:

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/DEVELOPMENT.md`
- `CONTRIBUTING.md`
- `bighelp-plugin/README.md`, `bighelp-plugin/PROTOCOL.md`, and `bighelp-plugin/SECURITY.md` for plugin or protocol work

## Hermes is authoritative

Hermes is authoritative for agent execution, sessions, transcripts, tools, approvals, policy, profiles, projects, scheduled tasks, models, reasoning configuration, and lifecycle state. bighelp is a native client and platform integration, not a second Hermes runtime.

The app may keep bounded local presentation and offline state, but it must reconcile remote behavior with Hermes. Optimistic UI is never proof that Hermes accepted or committed an operation. Request, session, agent, profile, revision, sequence, acknowledgement, and authorization coordinates must match before state is committed.

Use the current official Hermes documentation and source when a Hermes capability or contract is material:

https://hermes-agent.nousresearch.com/docs

Relevant native surfaces include documented:

- Python plugin registration APIs;
- platform adapters and `BasePlatformAdapter` behavior;
- plugin hooks, tools, skills, slash commands, and CLI subcommands;
- approval transports and platform actions;
- authenticated plugin API namespaces;
- native media extraction, authorization, and delivery APIs;
- profile, project, session, config, model, cron, and policy APIs;
- TUI gateway JSON-RPC methods and event streams;
- the API server only where its documented feature set fits the requirement.

Choose the narrowest public Hermes surface that preserves Hermes ownership. Verify the current contract rather than inferring support from an old implementation or copied code.

## Forbidden Hermes integration shapes

Do not solve a missing capability by building or depending on:

- a shim protocol that imitates a Hermes API;
- a sidecar service or daemon that becomes required for normal bighelp operation;
- a patch, fork-only behavior, or edit to an installed Hermes checkout such as `~/.hermes/hermes-agent`;
- monkeypatching, `sys.modules` replacement, runtime method replacement, or mutation of private Hermes globals in production code;
- a copied agent loop, session manager, approval engine, scheduler, policy engine, project registry, profile store, transcript store, or model catalog;
- a shadow database that competes with Hermes for authoritative runtime state;
- a parallel MCP client, provider client, or gateway control plane when Hermes already owns that connection and exposes a supported route;
- shelling out to emulate an in-process Hermes API when a documented plugin or TUI-gateway method exists;
- a compatibility fallback that changes authority, weakens authentication, broadens approval scope, or produces behavior newer Hermes versions would reject.

Tests may patch or stub imports to isolate behavior. Production code may not use those test techniques as architecture.

If current Hermes native support cannot express a required outcome, stop that implementation path. Record the exact user outcome, missing public capability, current surfaces examined, security and compatibility requirements, and the smallest upstream Hermes extension that would close the gap. Change the bighelp design or contribute upstream. Do not conceal the gap behind local infrastructure.

## Current architecture

- `BighelpAppComposition` is the composition root for production and fixture dependencies.
- `ShellFeatureStore` owns route-scoped feature-model creation and lifetime.
- Mutable feature models are generally `@MainActor` and `@Observable`.
- Features use narrow client protocols so production and deterministic fixture implementations share the same UI and model logic.
- Keep transport wire models separate from app domain and UI models.
- Validate, normalize, and bound every untrusted value before converting it to application state.
- Production composition selects `NativeWorkspaceRuntime` through `WorkspaceConnectionStore`; `Bighelp/DirectHermes` owns native transport. Retained Link chat implementations are disabled compatibility code, not a fallback.
- Hermes is the remote session authority. Local session records are a cache plus local draft/presentation state.
- Versioned JSON repositories use crash-safe replacement and sequential migrations. Preserve newer-than-supported files rather than overwriting them.
- Shared app-extension code belongs only in the explicit shared source folders.

For a new app feature, normally:

1. Define bounded `Codable` and `Sendable` domain models.
2. Define a narrow `@MainActor` client protocol.
3. Implement deterministic fixtures.
4. Implement the native Hermes or local client.
5. Create an `@Observable` model or store.
6. Build a SwiftUI view that receives dependencies.
7. Compose it through `BighelpAppComposition` or `ShellFeatureStore`.
8. Add focused unit tests and appropriate UI coverage.

Follow established repository architecture, not a generic MVVM template from another project.

## Apple-platform requirements

- Swift language mode: 6.0.
- Minimum deployment target: iOS 17.
- Use SwiftUI and Observation patterns already present in the repository.
- Preserve strict concurrency and actor isolation. Do not silence concurrency failures with unsafe annotations.
- Every affected flow must be complete on iPhone and iPad in portrait and landscape.
- Validate Dynamic Type, VoiceOver names/values/hints, logical focus order, 44-by-44-point minimum touch targets, keyboard behavior where applicable, Dark Mode, and Reduce Motion.
- Use existing design-system components, semantic colors, system typography, and SF Symbols before adding new visual primitives.
- Loading, empty, error, offline, retry, cancellation, and success states must tell the truth about the authoritative operation.

## Chat experience baseline

The user accepted chat in 2.0.1 (8) as the experience to preserve. Before
changing rendering, scrolling, composer/editor behavior, hosted cards, themes,
or chat persistence, read the
[Chat interaction contract](../docs/CHAT_INTERACTION_CONTRACT.md) and its
[regression commands](../docs/DEVELOPMENT.md#chat-regression-checks).

- Preserve one native recycling canvas, semantic row and model-owner identity,
  reader-controlled following, and separately recyclable expanded tool details.
- Preserve native input/selection/undo, observable row updates, hosted
  accessibility, and model-owned disclosure choices and clarification drafts.
- Keep incremental attributed-text updates and bounded persistence checkpoints
  with explicit final/stop/navigation/lifecycle flushes.
- Do not restore eager-latest/lazy-history partitions, competing delayed scroll
  writers, per-tool full-session writes, or row-local ownership of request-scoped
  clarification drafts.
- Verify the actual native/UI scenarios. The old scroll-key microbenchmark and
  default CI smoke selection do not establish chat interaction acceptance.
  Keep optimized simulator instrumentation out of production archives.

Historical design plans and retained test names do not override this contract.

## Project generation, build, and tests

`project.yml` is the Xcode project authority. `Bighelp.xcodeproj` is generated and intentionally committed. Do not edit `project.pbxproj` manually. After adding, removing, renaming, or moving source or resource files, run:

```sh
xcodegen generate
```

Select an installed simulator shown by `xcrun simctl list devices available` or `xcodebuild -showdestinations`. Build with:

```sh
xcodebuild build \
  -project Bighelp.xcodeproj \
  -scheme Bighelp \
  -destination 'platform=iOS Simulator,name=<available simulator>'
```

Test with:

```sh
xcodebuild test \
  -project Bighelp.xcodeproj \
  -scheme Bighelp \
  -destination 'platform=iOS Simulator,name=<available simulator>'
```

Use the smallest relevant test target or `-only-testing:` selector while iterating, then run the complete affected scheme before final approval. When another native build is active, use one bounded, reusable `-derivedDataPath`; do not create an unbounded series of DerivedData directories.

Use fixture mode for UI work that does not require production services:

```text
-use-demo-fixtures
-disable-demo-delays
```

Keep fixtures synthetic. Never copy production content, identifiers, credentials, or logs into tests.

For the Hermes plugin, use the Python environment bundled with a real Hermes checkout:

```sh
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes/hermes-agent}"
PYTHONPATH="$HERMES_ROOT:bighelp-plugin" \
  "$HERMES_ROOT/venv/bin/python" \
  -m unittest discover -s bighelp-plugin/tests -v

hermes plugins doctor bighelp-plugin --ci
```

If Hermes is not installed in the environment, report that the native plugin validation could not run. Do not create a fake Hermes package or weaken tests to make the command green.

Validate these customizations with:

```sh
python3 .github/scripts/validate-copilot-customizations.py
```

## Protocol and compatibility rules

bighelp Link components are independently deployed. A protocol change requires explicit old/new compatibility and failure tests. Cover strict decoding and bounds, unknown messages, rollout ordering, request/result coordinate matching, replay, sequence and acknowledgement behavior, cancellation, reconnect, duplicate delivery, revoked devices, authorization epoch changes, and cryptographic failure.

Preserve these meanings:

- `accepted` means Hermes accepted a request; it is not an assistant final.
- The relay and mobile cache are not transcript or policy authorities.
- Approval choices are exactly those Hermes offered. Never invent or broaden a scope.
- Project archive removes registration only and never deletes project files.
- Folder suggestions expose bounded directory coordinates, not file contents.
- Live Activity state is sanitized and excludes prompts, tool arguments, attachments, credentials, and complete model output.
- Ordinary notification text is rendered only after required authentication and decryption succeeds.

Do not publish live protocol coordinates, private routes, administrative commands, exact anti-abuse thresholds, key-rotation schedules, complete production schemas, or unpatched incident details.

## Security and privacy

Treat the app, extensions, bighelp Link service, notification relay, Hermes host, configured providers, APNs, and local device storage as distinct trust boundaries.

- Keep private keys, account content keys, tokens, and credentials in Keychain, Hermes secret/config facilities, or external secret storage as documented. Never commit them.
- Bound identifiers, labels, counts, byte sizes, collection sizes, filenames, paths, timestamps, and response bodies.
- Fail closed on malformed, expired, replayed, mismatched, unauthorized, or unknown inputs.
- Identity-check callbacks and continuations and settle each operation exactly once.
- Preserve cancellation semantics and prevent late callbacks from committing into newer work.
- Redact logs and user-facing errors. Do not expose local paths, secrets, raw provider bodies, or private Hermes state.
- Sign-out, device revocation, unpair, account deletion, and profile changes must remove or invalidate access at the correct authority boundary.
- Update `docs/ARCHITECTURE.md` when architecture, storage, permissions, encryption, retention, or disclosure changes.

Do not add third-party dependencies without explicit discussion. Preserve provenance and license files for vendored `Packages/ThinkingOrbsKit` changes.

## Git, review, and release discipline

Inspect the full working tree before editing. Existing changes belong to their current owner. Do not discard, overwrite, stage, commit, reformat, or "clean up" unrelated work. Keep changes focused and review the aggregate diff, not only the last commit.

Before declaring work complete:

1. Reconcile every requested deliverable.
2. Run focused tests and the broadest applicable build/test/plugin checks.
3. Inspect skipped tests and explain any affected untested lane.
4. Review security, privacy, accessibility, protocol, migration, and compatibility impact.
5. Run `git diff --check` and inspect the exact final diff.
6. Separate observed proof from assumptions and residual risks.

Do not deploy the plugin, restart Hermes, upload to App Store Connect, distribute TestFlight builds, push commits, publish releases, or notify users unless the assigned task explicitly authorizes that external action. After any authorized external write, read back the exact target before reporting success. Archive creation, upload acceptance, a zero exit code, or process completion alone is not release proof.
