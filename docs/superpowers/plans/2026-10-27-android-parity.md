# Android End-to-End Parity Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. Continue all tasks; the user explicitly requires a functioning close-parity app, not a preview checkpoint. Steps use checkbox syntax for tracking.

**Goal:** Deliver a functioning Android app with real Hermes conversations and the current app's everyday workflows.

**Architecture:** Retain Kotlin/JVM protocol and domain clients in `android/hermes`; Android adapters and Compose live/demo presentation live in `android/app`. One authenticated authority owns each client, cache, journal and pending prompt. Platform integration follows verified domain behavior.

**Tech Stack:** Existing pinned Kotlin, coroutines, kotlinx JSON, OkHttp, Compose, Android Keystore and protected atomic files.

**Spec:** `docs/superpowers/specs/2026-10-27-android-parity-design.md`.

## Global Constraints

- Minimum API 26, compile/target 36. Existing pinned dependencies unless necessary.
- Real host data only on the live path; labeled synthetic demo remains separate. No fake progress or default AI spending.
- Consent precedes every host access; secure credentials never enter ordinary preferences, logs, public artifacts or backups.
- Validated canonical endpoints retain deployment prefixes; TLS stays enabled; private HTTP needs explicit opt-in. No ambient cookies, credentialed redirects or automatic mutation replay.
- Actual capabilities gate behavior, never release versions. Register handlers before server-request advertisement on every ready socket.
- Journal before mutation dispatch; original uncertain bytes stay reviewable and never automatically resend. Separate principal/owner/socket/profile/runtime/stored/epoch coordinates.
- Every async callback and persistence replacement checks its original owner. Protect reader-controlled chat scroll, drafts, input and history.
- Only isolated disposable Hermes clones/homes with synthetic data/models for live verification. No maintainer hosts, shared gateway restarts, production services, merges or releases.
- User-selected workers: Claude Sonnet 5.5 / Xhigh implementation and review; GPT-6.1 Terra / max device/browser.

## Review Focus

- A late reply/refresh/prompt from a retired host never publishes or rewrites a replacement sign-in.
- Socket upgrade without readiness and an absent/false exclusive-submit guarantee never admit a turn.
- Lost submit/create/refresh receipts follow their distinct reconciliation contracts, including process death.
- Streaming, paging, keyboard, background/reconnect and active-turn sends preserve reader/input ownership and never duplicate an answer.
- Missing plugin features, newer/older optional fields and per-agent context differences disable only the relevant operation without fabricating data.

### Task 1: Real authentication, bounded HTTP and ordered gateway

**Files:** New `android/hermes/src/{main,test}/kotlin/app/bighelp/hermes/` authentication/HTTP/gateway classes; `android/hermes/build.gradle.kts` dependencies. Existing endpoint/wire/policy files only where required; preserve all existing tests.

**Interfaces:** Provide public JVM types for auth status/providers, saved credentials, sign-in input, a compare-and-replace credential store, bounded authenticated HTTP, and an ordered gateway interface. Publish exact signatures in the report for later tasks. Store authority is canonical endpoint plus exact principal. Android browser composition uses a supplied browser-launch callback and a real device-local loopback listener; no invented app-scheme callback. RPC consumers need connect/close, request/result/failure, ordered event and server-request streams, exact-owned server replies, generation and current capability/readiness state.

- [ ] Write failing tests for bootstrap extraction, dashboard versus bearer headers, password/native browser PKCE query/cookie/state/code validation, token identity/expiry, single-flight rotating refresh with durable CAS and 401-only retirement, mode/principal changes, response bounds, no redirects/cookies/retries and cancellation.
- [ ] Write failing scripted WebSocket tests: no outbound before ready, 20-second ready deadline, fresh bearer ticket per connection, heartbeat, strict atomic ordered frames, RPC correlation, separate inbound/outbound ID namespaces, 64-entry prompt table, duplicates, wrong-method cancellation, late replies, unknown request `-32601`, close during mutation, false/malformed exclusive-submit and reconnect re-advertisement.
- [ ] Observe RED, implement actual contract in `docs/hermes/CONNECTION.md`, then run all Hermes JVM tests and document GREEN. No speculative retries; expose typed uncertain outcome after possible dispatch.
- [ ] Publish the exact API and focused evidence; independent scoped review before dependent code.

### Task 2: Durable conversations, catalog, prompts and recovery

**Files:** New JVM chat/catalog/history/journal models and tests in `android/hermes`; consume Task 1's published API.

**Interfaces:** A screen-facing live workspace/chat repository exposes state flows for agents, sessions, transcript, real activity, prompts, connectivity, retained intents and drafts. Actions cover load/search/page/create/open, send/steer/queue/stop, answer/cancel prompts, rename/archive/restore/delete/fork, model/reasoning/slash controls and reconnect. A platform-neutral durable store supports atomic scoped cache/draft/journal transactions; persistence failure prevents dispatch. Publish exact API for Android composition.

- [ ] Write failing cases for `source:bighelp`, persistent create key, distinct runtime/stored IDs, canonical Bot Chat merge, archived catalog and physical history pagination.
- [ ] Write failing reducer/admission cases for streaming before receipt, `streaming` admission versus `session.info running:false` terminal, tools and interims, active-turn steer, queued receipt, exact prompt ownership, unknown secure methods and cancellation.
- [ ] Write failing process-death/reconnect cases: journal before write, lost ACK never resend, create retry same key, canonical history/replay fallback, compaction successor, stale runtime/epoch, draft edits newer than sent intent, failed disk writes and explicit uncertainty review.
- [ ] Implement from `docs/hermes/CHAT.md` and current Swift domain code; run full JVM suite GREEN. Review focused diff; publish usable repository APIs, not just policy types.

### Task 3: Everyday feature clients and capability discovery

**Files:** JVM typed stock/plugin feature clients and tests under `android/hermes`; consume Task 1 HTTP/gateway and Task 2 identities.

**Interfaces:** Typed models/actions for agents and instructions/avatar/model, workspace files and attachment transfer, Feed/Ideas/Goals and feedback, Projects/stock Git/Code, Kanban, scheduled tasks, Workflows/Dev Factory, Usage, Apps/connections, groups and supported voice control. Native extension context is per owner with feature gate, ETag and exact request-ID echo; optional absence is distinct from error.

- [ ] Turn the inventory in `/tmp/bighelp-android-parity-inventory.md` into a durable parity matrix with actual call/decoder/acceptance references. Do not silently defer ordinary app features.
- [ ] Write failing request/response and ownership tests for every family used by the UI; cover native context normalization/correlation/conflict, missing feature, bounded payloads and unknown mutation readback.
- [ ] Implement documented everyday list/detail/write flows from `REFERENCE.md`, `EXTENSIONS.md`, `GROUPS_AND_DEVICE_TOOLS.md` and current Swift typed clients. Scope all file/agent/session/project/room IDs correctly. Readback validates mutations where contracted; no generic replay.
- [ ] Verify upload/download offsets/size/digest, edited-file conflict and stock Git project-worktree restrictions, groups durable event/idempotency/pending-action variants and voice allocation/result uncertainty.
- [ ] Full JVM GREEN, scoped review, published API and matrix dispositions. Missing host feature never becomes a fake success.

### Task 4: Android secure persistence and complete live UI

**Files:** `android/app/src/main/`, app tests, manifest/build dependencies as needed. Preserve demo behavior and shared design components.

**Interfaces:** Android Keystore AES-GCM credential store implements Task 1 CAS and verifies readback; app-private atomic history/journal/draft store implements Task 2. A lifecycle ViewModel composes live repositories and shared menu/settings/navigation. Browser launch uses system browser with owned loopback callback. All UI actions call real typed clients.

- [ ] Write failing state/storage tests for consent, add/select/remove/restore computers, cancelled sign-in owner, process-death drafts/journal, private HTTP, credential rotation and feature availability.
- [ ] Implement sign-in and saved hosts, real agent/Bot/session list, chat streaming/tools/prompts/secure input, slash/model/reasoning controls, active-turn controls, history paging/search and uncertainty review.
- [ ] Implement everyday feature screens from Task 3 with real list/detail/edit controls: agents/instructions, files/transfers/text editing, content/feedback, projects/Code/changes, Kanban, tasks/workflows, Usage and Apps. Keep unsupported rows truthful, host admin behind Nerd Mode, one menu and Settings.
- [ ] Add appearance/layout/mode and user identity preferences; readable Markdown, selectable output, stable reader position and keyboard behavior. Demo uses the same presentational components with labeled fixtures.
- [ ] Full app/core JVM checks, lint, debug/release assembly, focused source review and Terra actual-control verification before accepting the slice.

### Task 5: Android media, groups, lifecycle and granted tools

**Files:** Focused platform adapters/screens/tests under `android/app`, domain refinements only when required by observed integration.

- [ ] Add file picker/share/open and incoming attachment/image presentation, bounded caches and permission handling.
- [ ] Add microphone permission/audio focus/recording/playback and real supported voice flows. Keep a lost voice result append uncertain, not replayed. Implement hosted group membership/chat/pending actions via actual advertised path; never fan out normal chats to fake a group.
- [ ] Add applicable Android device tools behind explicit persistent off-by-default grants and OS permissions; advertise only implemented operations. Keep Apple-only tools unavailable. Add supported Android notification delivery only with a proven server adapter; no APNs/FCM substitution.
- [ ] Verify lifecycle foreground recovery, stopped process restoration, sign-in preservation, host switching, cancelled prompts and media transfers. Test and review each affected boundary.

### Task 6: Integrated parity acceptance and delivery

**Files:** Android README, parity matrix, test fixtures/probes, existing PR/issue and final evidence records.

- [ ] Use isolated real Hermes/plugin hosts from `/tmp/bighelp-android-disposable-host.md`, recorded source revisions and synthetic model. Never shared Hermes launchers or actual maintainer hosts.
- [ ] Terra/max installs exact APK and exercises open/password/browser/token sign-in, saved restore, create/resume/send/stream/steer/stop/prompts, history/restart/reconnect and host switch, files and all implemented everyday feature controls in light/dark. Record fixture versus actual-host boundaries and exact receipts.
- [ ] Run integrated checks, fix reproduced failures, one whole-branch review with scoped fix follow-up, repeat affected verification and reconcile every parity-matrix row. Unfinished ordinary workflows keep this task open.
- [ ] Update real PR title/body around the final application, source/evidence/limitations and model/harness footer. Commit and push logical changes, keep PR linked and maintainer merge/release authority. Stop owned temporary servers/emulator runtime; retain exact artifacts and installed toolchain.
