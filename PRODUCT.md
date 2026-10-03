# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Product Purpose

bighelp is a native client for conversations with agents, including model selection, reasoning and tool activity, rich generated cards, files, code/project changes and voice interaction.

## Runtime Direction

bighelp supports Hermes and is also building **bighelp Native**, its own native
harness for iOS and Companion. These are complementary product paths.
The planned Goose-based Native runtime is not a
working production engine in this release. Shared presentation, persistence and
harness interfaces are foundations, not evidence that Native execution works.

On a Hermes instance, Bot Mode uses Hermes' official hosted rooms. Do not replace
that with sequential direct chats or synthesized multi-agent prompts. Native
harness work must preserve the Hermes path and the accepted chat experience.
See [Hermes Bot Mode](docs/HERMES_BOT_MODE.md).

Agents can use iPhone Health, Calendar and Reminders. The
[device-tools contract](docs/IPHONE_DEVICE_TOOLS.md) uses
Hermes' official tool registration and the existing encrypted Link path. Each is
independently off by default under Permissions. The feature requires the updated
Hermes execution context, plugin and directed Link relay. Enabling Calendar or
Reminders authorizes direct changes on the user's request without another
per-operation confirmation; Health access remains read-only.
This work does not depend on the unfinished Native harness.

## Operating Context

Users return to existing sessions, continue live work, switch agents and workspaces, inspect project changes, and personalize appearance. Conversation continuity and readable long-form output remain essential when the presentation changes.

## Experience Vision

Chat should feel immediate, stable, and natural even when a long conversation
contains expanded tool calls. Users should be able to read older output, inspect
work, and type while an answer streams without losing their place, input, or
control of the keyboard. Speed includes accurate content and predictable state.

The user accepted the chat experience in **2.0.1 (8)** on September 10, 2026 as
the baseline for future work. New features, themes, and visual redesigns must
preserve the [Chat interaction contract](docs/CHAT_INTERACTION_CONTRACT.md).
This is an ongoing product requirement, not a completed performance initiative.

Opening Home with no active chat must also feel immediate. Catching up on old
answers must not replay completed work as new activity, repeatedly rebuild the
menu, or stall navigation. Preserve the [idle startup contract](docs/IDLE_STARTUP_RELIABILITY.md).

## Capabilities and Constraints

- V3 is the only shipping interface. Legacy V1/V2 preference values remain
  decodable for migration; they do not define alternate production chat engines.
- Preserve established model/reasoning controls, side menu, theme picker, Project Changes, rich drafts, slash commands, attachment flows and voice modes.
- Preserve transcript identity, ordering, hydration, grouping, reader-controlled
  scrolling, native input continuity, and request-scoped drafts in every redesign.
- Large-history efficiency must preserve messages and tool results. Reducing
  visible detail or dropping valid events is not an acceptable speed improvement.
- UI work does not authorize Hermes core/plugin changes, service restarts, merges or releases.

## Brand Commitments

The current redesign authority is the user-selected [iOS 27 Builder kit](https://www.figma.com/design/63PDCIYiMGW6BvUabZhlke) and three agentic conversation mockups. The [native presentation contract](docs/IOS27_DESIGN_CONTRACT.md) requires shared adaptive neutral surfaces and native typography/controls across themes, with theme color limited to outgoing bubbles and appropriate action/link accents. Saved theme documents and existing behavior remain intact. Native Apple interaction takes precedence over copying showcase wrappers; no UI package is added.

## Accessibility & Inclusion

Readable long-form content, Dynamic Type, contrast, Reduce Motion and full touch targets. Icon ink alignment is distinct from button-frame alignment.

## Evidence on Hand

Current reference evidence comprises the three supplied light/dark direct, group, work/approval and agent-detail concepts plus retained iOS 27 Builder design-context responses. Fresh Figma metadata/variable reads are rate-limited; unobserved variable IDs and modes are not asserted. The nine earlier ChatUI reference panels and their attribution remain in the [historical design record](docs/ui-v3-design.md).

Current behavior and measured limits are recorded in
[Chat performance validation](docs/CHAT_PERFORMANCE_VALIDATION.md).
Product acceptance, simulator timing, and measured device frame rate are
distinct forms of evidence; do not substitute one for another.


Voice settings include agent-scoped Hermes TTS provider, voice ID and a write-only
API key replacement for OpenAI and ElevenLabs. Device-local voice mode and speed
remain separate. Show confirmed saves and truthful current provider/key presence;
never imply that storing a key verifies the provider account or audio quality.
Non-repository chat folders show N/A under Changes. Connected GitHub accounts expose
repository, issue and PR anchors, retaining available results during partial discovery.
