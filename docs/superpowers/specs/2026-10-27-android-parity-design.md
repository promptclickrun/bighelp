# Functioning Android app with everyday bighelp parity

## Outcome and authority

The requested outcome is a functioning end-to-end Android application close to the current Apple app, not another discovery-only preview. Continue the existing Kotlin/Jetpack Compose implementation in `android/`. Current Apple behavior, `DESIGN.md`, `docs/CHAT_INTERACTION_CONTRACT.md`, `docs/NATIVE_TRANSPORT.md` and its chapters are the reference. The earlier foundation is the starting point and remains a clearly labeled optional demo.

The user has directed implementation and supplied the platform/model choices. Preserve those choices and the existing Ink direction; do not introduce another design selection gate or stop at an intermediate milestone. A checkpoint or PR is progress, not acceptance of a partial application.

## Architecture

`android/hermes` remains JVM-testable and owns authentication, ordered transport, domain clients, durable intent/recovery rules and feature decoding. `android/app` supplies Android Keystore encryption, protected atomic local storage, browser/audio/files/permissions/lifecycle adapters, observable app state and Compose presentation. Network results and persistence are bound to endpoint, exact principal and owner generation. Demo and live repositories implement the same screen-facing interfaces, while demo provenance remains explicit.

Build on the already selected native Kotlin approach rather than changing frameworks or embedding the dashboard. Screens follow existing bighelp navigation and plain language. One menu, one Settings, searchable lists, readable chat and stable input take precedence over copying Apple-only visual effects.

## Required workflows

1. Add, save, select, reconnect and remove computers. Discover the advertised authentication mode. Support automatic dashboard bootstrap, explicit session/access tokens, password PKCE and browser PKCE without collecting browser cookies. Save credentials with Android Keystore encryption and verify rotating sign-in identity with single-flight compare-and-replace. Consent precedes all host access.
2. Load agents and durable sessions from the host, including canonical Bot Chats and archived sessions. Start and resume the exact agent/chat with `source: "bighelp"`, preserving runtime and stored identifiers independently. Search, rename, archive, restore, delete and select models/reasoning through real supported operations.
3. Send and stream real turns, display tools and terminal states, steer by default during active work, queue or stop when available, and show questions, approvals and secure requests. Register handlers before advertising them on every socket. Unknown requests fail explicitly. Acknowledgement means admission, not completion.
4. Preserve drafts, cached history and uncertainty across process death. Page canonical history, replay/catch up after interruption, keep reading position and composer stable, and never automatically resend an uncertain mutation. A refused send remains editable; a lost receipt remains reviewable.
5. Offer agents/Bots, configured workspace files and attachments, Feed/Ideas/Goals, Projects, Kanban, Workflows/Dev Factory, scheduled tasks, Usage and connected Apps using their real documented stock/plugin APIs. Implement everyday read/write/detail interactions and truthful supported/unsupported states; do not substitute raw JSON viewers for the product. Optional plugin capabilities are discovered from context and protected with its ETag/request-ID envelope.
6. Offer Code workflows for project/branch/worktree selection, launching chats in the exact folder, inspecting Changes and the supported Ship actions. Preserve ownership and confirmation semantics of the Apple client.
7. Add Android file picking/sharing, rendered incoming media, turn-based voice and supported live voice, hosted groups, permissions and applicable device tools with explicit grants. Android lifecycle recovery must work across background/foreground. Advertise only actually implemented platform capabilities.
8. Settings cover saved computers, appearance/layout/mode, identity, device access and advanced host tools under Nerd Mode. No cloud bighelp account or retired Link pairing.

Platform-specific Apple surfaces (Watch, CarPlay, visionOS, Live Activities, Shortcuts, Health/Focus/AlarmKit) require honest Android equivalents or explicit platform boundaries. They do not justify omitting ordinary Android app workflows. Android push needs a real supported delivery adapter; never claim APNs registration works with an FCM token. Store verification remains a distribution gate and does not pause application implementation.

## Invariants

- Minimum API 26, target/compile 36; keep existing pinned toolchain unless a necessary change is justified.
- No host access before consent, credentials in URLs/logs/preferences, ambient cookies, credentialed redirects, disabled TLS checks or automatic mutation replay.
- Preserve deployment prefixes and independent proxy credentials. Public HTTP remains prohibited; private HTTP is explicit and typed.
- Wait for `gateway.ready`, authenticated health and actual exclusive-submit capability. No version allowlist.
- Strict bounded atomic frame decoding; ordered reader/writer, distinct inbound/outbound IDs, stale-owner fences, bounded prompt table and secure cancellation.
- Journal before dispatch; persistence failure prevents send. Same text is not proof of acceptance. Create retries retain the creation key; ordinary submits have no invented idempotency guarantee.
- Native extensions require advertised feature, current context and exact response correlation. Missing fields are tolerated as documented; unknown fields never break unrelated screens.
- Real data only outside labeled demo. No invented progress, fake tools or canned replies on the live path. No AI spending from default jobs.
- Public repository artifacts contain synthetic data only. Use isolated disposable Hermes clones/homes and synthetic models for verification. Never contact maintainer hosts or restart shared gateways.

## Verification and completion

Each independently testable task gets meaningful failing-before/fixed-after tests and a focused independent review. Build and lint the integrated app. Exercise real controls in light/dark on Android with exact installed APK identity, including connection, live send/stream, active-turn controls, prompts, files, navigation, restart/background and recovery. Run isolated stock Hermes/plugin processes with recorded source revisions and synthetic model responses, distinguishing those from scripted socket tests and demo data. Retain screenshots and receipts outside the public repository.

Maintain an explicit parity/acceptance matrix through implementation. A row is complete only when its implementation and appropriate evidence exist; capability absence and platform boundaries are separate dispositions. Do not label the outcome complete merely because the initial chat works, tests pass or the preview builds. Publish logical commits and a real linked PR; the maintainer merges and controls release. Identity documents/payment remain directly in Google.
