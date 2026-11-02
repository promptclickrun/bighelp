# Contributing

Production transport contract: **native Hermes only for chat**. Cloud services
are used only for optional notifications and Live Activities, which BuzzKit delivers. The current composition,
voice boundary, enrollment isolation and verification requirements are defined
in [Native transport](docs/NATIVE_TRANSPORT.md). Retained Link/paired-Direct protocol
sections below describe legacy compatibility code, not a selectable chat path.

## Before opening a pull request

1. Read [Architecture](docs/ARCHITECTURE.md).
2. For security-sensitive work, follow [SECURITY.md](SECURITY.md) instead of
   opening a public issue.
3. Keep changes focused and include tests for changed behavior.
4. For chat, composer, card, theme, or chat-persistence work, read the
   [Chat interaction contract](docs/CHAT_INTERACTION_CONTRACT.md) and use its
   [regression recipe](docs/DEVELOPMENT.md#chat-regression-checks).

## Development workflow

```sh
xcodegen generate
xcodebuild test \
  -project Bighelp.xcodeproj \
  -scheme Bighelp \
  -destination 'platform=iOS Simulator,name=<available simulator>'
```

Use fixture mode for UI and integration work that does not require access to an
authorized service:

```text
-use-demo-fixtures
-disable-demo-delays
```

## Pull request expectations

- The maintainer reviews and merges every pull request. Checks on pull requests
  from forks start after a maintainer approves them.
- Explain the user-visible behavior and trust-boundary impact.
- Add or update Swift Testing coverage.
- For changes affecting chat, record native/UI regression results and any
  untested interaction or device cases. Performance changes also need the
  optimized stress comparison, including expanded tools and growing text.
  Preserve the accepted behavior and evidence; do not weaken thresholds or
  remove content to obtain a passing result.
- Update public documentation when architecture, storage, permissions,
  encryption, retention, or privacy disclosures change.
- Preserve Swift 6 concurrency correctness.
- Keep external input strictly bounded and validated.
- Do not add third-party dependencies without prior discussion.
- Do not include DerivedData, archives, exported apps, logs, or other generated
  build artifacts. The generated `Bighelp.xcodeproj` is the intentional
  exception. Regenerate it from `project.yml`; do not edit it by hand.

## Sensitive information

Never commit or paste into issues:

- API tokens, cookies, credentials, or private keys
- APNs credentials or device tokens
- Cloud account, database, queue, or namespace identifiers
- Production logs containing user content
- Private endpoints or administrative routes
- Real pairing codes or passkey responses

Use placeholders in examples. If a contribution needs production investigation,
coordinate privately with a maintainer.

## Legal

This project is licensed under the [Apache License, Version 2.0](LICENSE). By
submitting a contribution you agree it is licensed under the same terms.
Do not include third-party copyrighted material or code whose license is
incompatible with Apache-2.0.
