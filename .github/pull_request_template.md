## Change

Describe the user-visible outcome and the affected ownership or data boundaries.

## Validation

List the checks actually run on a Mac, their results, and any relevant skipped or
unverified cases. Do not ask for a CI run: the Apple workflows are off by default
([AGENTS.md](../AGENTS.md)). For UI changes, identify the devices/orientations and
accessibility/keyboard states exercised.

## Chat behavior

If rendering, scrolling, input, hosted cards, themes, or chat persistence are
affected, complete the applicable
[Chat interaction contract](../docs/CHAT_INTERACTION_CONTRACT.md) checks and
link the [native/UI regression results](../docs/DEVELOPMENT.md#chat-regression-checks).
Otherwise state why this section is not applicable.

- Reading position, tail following, and expanded tool behavior:
- Native input, selection, and draft/disclosure continuity:
- Performance evidence and remaining measurement limits, when affected:

Keep logs, screenshots, archives, credentials, and private user data outside the
source diff. Do not equate a passing build or upload with interaction acceptance.
