# iOS 27 native presentation contract

This is the current redesign requirement, not a claim that every surface has passed qualification.

## Design authority

- User-selected [iOS 27 Builder kit](https://www.figma.com/design/63PDCIYiMGW6BvUabZhlke), file key `63PDCIYiMGW6BvUabZhlke`.
- Three supplied concepts: light conversation directory/direct chat; dark work trail/approval/composer; light group conversation/agent details.
- The older [ChatUI design record](ui-v3-design.md) remains historical provenance, not the current visual authority.

The retained Figma design-context responses establish native toolbar, sheet toolbar, search, list/form, menu, alert, progress and semantic color/type families. Fresh metadata and variable-definition calls are currently rate-limited. Exact variable IDs, modes and unobserved components are not claimed. Raster mockup measurements are pixels, not verified iOS point specifications.

## Simplicity standard

A new user should understand how to connect and chat in roughly 30 seconds, with the low effort of Muse AI or similar chat apps. This is a comprehension target, not an unmeasured authentication-time guarantee. Keep one obvious primary action, group related settings in clear menus, and keep those settings editable. A setting does not need a separate screen. The source inventory preserves capabilities; it is not a page quota. Use progressive disclosure for advanced choices and recovery mechanics without hiding safety consequences.

The primary first-run path is Welcome → Connect → Choose your mode. Appearance customization is optional, not a required stop before setup, and remains accessible through Settings. After Connect, the bighelp plugin step is optional; notifications are offered only once the plugin is in. Every optional step has a small Skip at the top right; Connect and Choose your mode don't. The mode cards (Bots, Sessions, Code) each open a preview of their mode, and the screen says the choice can be changed later.

## Visual system

```text
Saved theme document, unchanged
├── Explicit document preview and portable export
└── Live presentation
    ├── Shared adaptive neutral surfaces, labels and status colors
    ├── Shared native typography, icon treatment and geometry
    └── Theme accent → outgoing messages and appropriate actions/links
```

The same neutral system applies to every bubble color. Light/dark presentation adapts through semantic platform colors. Resolve outgoing text contrast against the actual displayed accent, including dynamic system colors, not only retained hex fields. Non-system accents minimally adjust brightness when needed for readable action/link ink on native canvas, card and incoming-bubble surfaces, including elevated surfaces; the default keeps native system blue. Partner and custom themes were removed; don't bring back a second theme system that can overwrite the bubble color.

Use native navigation, toolbars, search, lists, forms, sections, menus, alerts, pickers, text inputs and system sheets. Custom content remains appropriate for message bubbles, agent artwork, inline artifacts and expressive media. Do not recreate native glass with decorative overlays around every control.

## Conversation hierarchy

- Conversations are the primary root. Search, existing filters, pins, groups and compose remain reachable.
- Direct identity is centered in the conversation toolbar and opens genuine details. Group headers use actual participant identities; incoming group messages identify their real speaker.
- Incoming prose uses neutral bubbles. Outgoing bubbles carry the selected accent. Rich content retains a wider bounded lane and its existing renderer.
- Work trails expose actual ordered events, delegated identity, lifecycle and detail disclosure. No timer-generated success or synthetic progress.
- Approval previews show actual pending authority and bounded action/content. Keep existing details and approval callbacks; a mockup is not authorization to invent or broaden an approval operation.
- Preserve the retained native composer editor, draft, marked text, selection, attachments, rich/source editing, voice, model/reasoning, steer/follow-up/stop and workspace access.

## Preservation boundaries

Retain every current-main capability and its production construction path: first-run progress, root/modal input ownership, optional notification setup, clone/template creation, readiness/retry protection, structured multi-question Clarify, native selection/reactions, exact-owner editing, live activity labels, native goal controls, configured-workspace artifacts, theme import and staged provider/model selection.

Models, transport contracts, canonical timeline identity, data retention, security/permission boundaries and uncertain-operation handling are not redesign targets. Platform-owned dialogs are qualified through their real invocation and dismissal, not rewritten.

## Qualification

The source inventory distinguishes declarations, shared components, routes, controls, dormant/legacy code and OS-owned mechanisms. Its counts are not shipping-screen or screenshot totals. Each record needs a concrete implementation disposition, and each shipping route needs corresponding rendered/control evidence.

Run focused state/transport regressions, then inspect and interact with the actual candidate on iPhone and iPad, light/dark, portrait/landscape, large Dynamic Type, increased contrast and Reduce Motion. Preserve VoiceOver semantics and 44-point actionable targets. Keyboard checks require actual visible software keys, usable editor geometry, draft retention and clearance, not merely a Keyboard accessibility node.

Review the aggregate diff, reconcile current main and verify source/PR identity before handoff. Source publication does not authorize merge, TestFlight, installation, runtime restart or cloud deployment. GitHub Actions remain disabled; native local evidence is not CI evidence.
