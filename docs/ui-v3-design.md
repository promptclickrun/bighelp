# UI V3: ChatUI adapted for bighelp

Status: historical design and implementation record. Current shipping V3 and
preference-migration behavior are documented in [Product](../PRODUCT.md) and
[Design](../DESIGN.md). The [Chat interaction contract](CHAT_INTERACTION_CONTRACT.md)
supersedes this record's earlier interface-selection and scroll-ownership
assumptions. Ownership assignments and branch references below describe the
original work, not instructions for a new change.

The current visual authority is the [iOS 27 native presentation contract](IOS27_DESIGN_CONTRACT.md), based on the user's iOS 27 Builder kit and three agentic conversation mockups. The ChatUI link below is retained only as historical provenance.

## Direction contract

**Thesis:** A calm native conversation surface with bighelp's working tools integrated, rather than a stack of showcase cards.

**Visual language:** System typography, semantic theme colors, theme-accent user bubbles, neutral readable assistant content, rounded media, SF Symbols, monochrome infinity New Chat actions and pronounced native glass on functional chrome. Match the reference's hierarchy, not its fixed small text sizes.

**Interaction:** Existing model/reasoning and workspace controls, expandable rich composer, attachments/slash/voice, grouped activity and Project Changes retain their behaviors.

**First viewport:** A concise session header and current model, conversation content, compact Project Changes when applicable, and an obvious usable composer. Empty chat still provides a real entry point. V3 uses a full-width header on both iPhone and iPad rather than a capped tablet strip. Regular-width headers have larger menu and New Chat controls, while the title/model remain centered and the visible icon bottoms align; compact-width controls and other New Chat placements retain their existing sizes.

**Scope:** V3 is the default when no interface preference is saved; explicit V1/V2 selections and legacy choices remain respected. Same underlying models, timeline and transport. Light/dark, portrait/landscape and accessibility proof. No release or restart.

## Ownership and boundaries

- Parent: settings/version persistence, environment plumbing, theme picker, tests, fixture, integration, native builds, source review and GitHub.
- Chat owner: ChatView, ChatAttachmentMenu, SessionStatusRailView.
- Message owner: MessageViews presentation only.
- Shell owner: side panel and shared shell/voice/list styling.
- Parent branch depends on unmerged PR69 at 58d9b06; no silent merge of that work.

## Visual reference

https://www.figma.com/community/file/1211259538649728876/chatui-swiftui-for-chat

ChatUI Figma reference by its community authors, listed under CC BY 4.0. Used as design inspiration; no Figma assets or ChatUI package are vendored. Implementation uses existing bighelp code and native SwiftUI controls.

## Acceptance

1. V3 is the default for an unset or unrecognized interface version without a legacy preference. Explicit persisted selections and legacy V1/V2 migration take precedence; all three versions remain available in Settings.
2. All current controls remain connected to their production actions and stores.
3. Distinct V3 chat/composer/messages, side panel and themes are visible in the actual simulator.
4. Existing rich cards, Markdown/code, activity grouping, attachment projection and scroll ownership are preserved.
5. Focused automated and visual proof at the integrated revision; no TestFlight or service action.
