# bighelp for Android

Native Kotlin and Jetpack Compose build-out, tracked in [#644](https://github.com/promptclickrun/bighelp/issues/644).

The integration authority is [the Hermes transport contract](../docs/NATIVE_TRANSPORT.md). The first milestone is described in [the design](../docs/superpowers/specs/2026-10-27-android-foundation-design.md) and [implementation plan](../docs/superpowers/plans/2026-10-27-android-foundation.md).

## Build

Install JDK 17 and an Android SDK with platform 36 and build tools 35.0.0. Set `ANDROID_HOME` or create a local, ignored `local.properties` with `sdk.dir=/absolute/path/to/sdk`. Open this directory in Android Studio, or run from the repository root:

```sh
cd android
./gradlew :hermes:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`, with application ID `app.bighelp.android.debug`. Release signing, Play upload and the permanent release ID are not configured.

The wrapper pins Gradle 8.13 and its distribution checksum. AGP 8.13.2 supports API 36 with JDK 17 and Gradle 8.13 ([Android compatibility table](https://developer.android.com/build/releases/agp-8-13-0-release-notes)). Kotlin and Compose dependencies are pinned; this foundation uses the stable Compose BOM 2025.10.01. Android's [Compose BOM guide](https://developer.android.com/develop/ui/compose/bom) explains dependency alignment.

## Structure

- `hermes/`: pure JVM endpoint and wire policy; tests read `../docs/hermes/vectors/wire.json` directly.
- `app/`: Android lifecycle, platform storage, Compose screens and explicit demo fixtures. In `app/src/main/kotlin/app/bighelp/android/`:
  - State, no Android types: `AppState.kt` (routes, setup, demo data), `BighelpAppModel.kt` (every action and rule), `DemoContent.kt` (invented sample chats and the fixed example reply).
  - Network: `HostDiscovery.kt` (`HostDiscovery.check(endpoint, consentGranted)`) and `HostStatus.kt` (strict `/api/status` decoding). This is the only code that opens a connection.
  - Platform: `MainActivity.kt` (Activity, `ViewModel`, privacy-policy link), `PreviewPreferences.kt` (consent and appearance in app-private preferences).
  - Screens and theme: `BighelpApp.kt` (routing and Back), `WelcomeScreens.kt`, `SetupScreen.kt`, `SessionsScreen.kt`, `ChatScreen.kt`, `AgentsScreen.kt`, `SettingsScreen.kt`, `PlacesMenu.kt` (the one menu), `Components.kt`, `BighelpTheme.kt`, `NoodleMark.kt`.
- `../.github/workflows/android.yml`: JVM tests, Android unit checks, lint and APK build on Android/contract changes.

## Evidence and release gates

The foundation is not an Android feature-parity or release-readiness claim. Record executed verification in the PR. Shared framing fixtures and scripted tests do not establish real-host compatibility, physical-device lifecycle, browser callbacks, credential rotation, or notification delivery.

### What the first app milestone does

- **Try the demo** opens sample chats, agents and Settings. Everything is invented and stays on the phone; every demo screen says so, and every reply is the same fixed, labeled example. It needs no agreement because nothing is sent. Controls that work: New chat, Send, search, agent choice, Light/Dark/Same as phone, drafts kept while you look elsewhere, Latest button and Android Back.
- **Connect your computer** asks for the one-time AI data agreement first (stored as `bighelp.privacy.ai-data-agreed` in app-private preferences, excluded from backup and device transfer), then checks one typed address with `GET /api/status`. A host that answers is reported as *found*, never *connected*. It collects no token or password, stores no address or sign-in, opens no gateway and sends no chat.
- Discovery sends no cookies, tokens or custom headers, follows no redirect, reads at most 16,384 decoded bytes, and keeps no response text. Each status request sends `Connection: close` to avoid reusing a closed HTTP/1.x connection; automatic retries remain disabled. HTTPS uses the platform's certificate checks, and `network_security_config.xml` trusts only the phone's built-in (system) certificate authorities. A certificate signed by a private authority that you installed on the phone is not trusted, so a host that uses one looks like "No Hermes computer answered". Use a certificate from a public authority, or plain HTTP on a private network. This preview offers no way to trust a private authority.

### Plain HTTP on a private network

`HermesEndpoint.parse` allows `http://` only with the explicit private-network switch **and** a host that is private by its syntax (see [the connection contract](../docs/hermes/CONNECTION.md)). Android's network security config cannot list those ranges, so `res/xml/network_security_config.xml` permits cleartext at the platform level, and the typed client is the gate: `HostDiscovery` requests only a validated `HermesEndpoint`, and nothing else in the app opens a connection (no WebView, no other HTTP client). Anyone adding network code must go through `HermesEndpoint`, or tighten that file first.

### Tests in this milestone

`app/src/test` holds JVM tests only: `AppModelTest` (consent gating, address refusal, one check at a time, stale and cancelled results, demo send, drafts, search, Back), `HostStatusTest` (strict status shape and bounds) and `HostDiscoveryTest` (real requests to a local scripted server: the GET and its headers, no credentials, no redirect, only HTTP 200, malformed bodies, the 16,384-byte limit with and without a declared length, a cancelled check cancelling the real call, and repeated checks of closing and keep-alive HTTP/1.x hosts). Emulator verification is recorded separately; there are no automated UI tests yet. Demo drafts and chats survive navigation and rotation, but reset after process death or leaving the demo. UI localization is not implemented yet.

### Verified preview snapshot: 2026-10-27

At source commit `591c44d`, all 57 core and 41 app JVM tests pass, debug assemble succeeds, and lint reports 0 errors and 9 dependency-version notices. [Android CI passed on that commit](https://github.com/promptclickrun/bighelp/actions/runs/40552550144). The core suite includes all 55 shared wire vectors; changing the shared vector file invalidates Gradle's test result.

Manual checks on an Android 16 / API 36 emulator exercised demo controls, drafts, keyboard/Back, history/Latest, rotation, light/dark appearance, consent and setup. After the HTTP/1.x connection fix, the initial status check and eight consecutive Check again taps each showed Found with exactly one matching local-fixture receipt and response. A separate two-second delayed check passed. The installed APK's on-device SHA-256 matched the built file.

These are demo and synthetic HTTP/1.0 fixture results. No real Hermes host, HTTPS/HTTP/2 discovery, physical device, lower API level or TalkBack behavior was verified. The rotation checks did not reproduce the suspected jump; they do not rule out a timing race.

Before a working live-chat milestone, implement and test authenticated ordered WebSocket readiness, prompt handlers, the exclusive-submit gate, distinct runtime/stored IDs, a durable uncertainty journal, streaming/history reconciliation and reconnect/replay. Do not expose live Send before those acceptance cases pass. Follow [PORTING.md](../docs/hermes/PORTING.md) in order.

Before Play release, settle the permanent application ID and signing ownership, complete personal developer registration and verification, verify on a physical Android device, add the Android delivery adapter if push is offered, and complete Google's current test/release requirements. No production service is deployed by the Android foundation.
