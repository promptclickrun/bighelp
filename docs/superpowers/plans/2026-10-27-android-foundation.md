# Android Foundation Implementation Plan

> **For agentic workers:** Use focused implementation tasks with independent review. Steps use checkbox syntax for tracking.

**Goal:** Establish a buildable native Android app and a tested portable Hermes foundation.

**Architecture:** A Kotlin/JVM `hermes` module owns the bounded protocol and connection policy. A Compose `app` module owns consent, secure platform persistence and UI. Demo fixtures exercise screens without a host.

**Tech Stack:** Kotlin, Gradle, Jetpack Compose, OkHttp, kotlinx.serialization, coroutines, JUnit.

**Spec:** `docs/superpowers/specs/2026-10-27-android-foundation-design.md`

## Global Constraints

- Minimum Android API is 26; compile and target API are 36.
- Use `app.bighelp.android` as the development application ID, with `.debug` on debug builds.
- No host request is sent before consent.
- No credentialed redirects or ambient cookies.
- A dispatched mutation without a receipt is uncertain, not failed, and is never automatically repeated.
- Personal information and real host data never enter this public repository.

## Review Focus

- A malformed trailing frame publishes no earlier message from the same WebSocket message.
- UTF-8 byte boundaries and deeply nested JSON fail before unbounded parsing.
- A deployment prefix remains part of endpoint identity and every route.
- Switching owner or closing a connection retires late responses.
- Demo responses remain labeled examples; unsupported live behavior is unavailable.

### Task 1: Reproducible build and portable protocol

**Files:** `android/settings.gradle.kts`, `android/build.gradle.kts`, `android/gradle/`, `android/hermes/`.

**Interfaces:** `HermesEndpoint.parse(input, allowPrivateHttp)` produces a canonical endpoint with prefix preserving route construction. `HermesWire.decode(bytes)` returns an ordered list of typed frames or a typed rejection, atomically.

- [ ] Add the Gradle wrapper, pinned build dependencies and JVM test harness.
- [ ] Write failing vector and endpoint tests; capture the failure.
- [ ] Implement the decoder and endpoint rules from `CONNECTION.md` and Swift source.
- [ ] Run all vectors and generated limit tests; independently review trust boundaries.

### Task 2: App shell and explicitly scoped live connection

**Files:** `android/app/`, `android/README.md`.

**Interfaces:** App state owns consent and connection generation; screens observe state and invoke explicit actions. Demo and live repositories implement the same UI model without invented host success.

- [ ] Add Compose app, manifest and local consent preferences with backup exclusions; introduce Keystore storage with authenticated sign-in in the next milestone.
- [ ] Add consent, connection setup, demo sessions/chat, agents and one Settings surface.
- [ ] Add consent-gated public host discovery through `HostDiscovery.check(endpoint, consentGranted): DiscoveryResult`; do not label discovery as a connection or collect credentials.
- [ ] Test consent, failed setup, draft preservation and demo control behavior.

### Task 3: Verify, review and record evidence

**Files:** `android/README.md`, Android CI workflow, issue/PR.

- [ ] Run JVM tests, Android unit checks, lint and debug assemble.
- [ ] Inspect demo screens and use controls in light and dark on a dedicated emulator, when available.
- [ ] Review the full diff, fix concrete findings and repeat affected verification.
- [ ] Document remaining acceptance gaps, commit changes and open a draft PR linked to its issue.

### Parallel account preparation

- [ ] Use Terra/max for browser work to prepare personal Play Console registration.
- [ ] Leave identity, verification and any required direct checkout with the maintainer; report the exact remaining steps.
