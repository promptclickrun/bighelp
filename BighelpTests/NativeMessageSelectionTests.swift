import Foundation
import Testing
import UIKit
import SwiftUI
@testable import Bighelp

@MainActor
struct NativeMessageSelectionTests {
    @Test(arguments: [TimelineRole.human, .assistant])
    func everyMessageRoleUsesTheInlineNativeSelectionSurface(role: TimelineRole) {
        #expect(ChatMessageInteractionPolicy.usesInlineNativeSelection(role: role, uiV3Enabled: true))
    }

    @Test(arguments: [TimelineRole.human, .assistant])
    func everyMessageRoleCanOfferReactions(role: TimelineRole) {
        let presentation = NativeMessageReactionPresentation(
            rowID: 42,
            reactions: [],
            availability: .available,
            isUpdating: false,
            errorMessage: nil
        )

        let canReact = ChatMessageInteractionPolicy.canReact(
            role: role,
            presentation: presentation,
            hasMutationHandler: true
        )
        #expect(canReact)
        #expect(
            ChatBubbleInteraction(
                markdown: "React to this message",
                canFork: true,
                canReact: canReact
            ).menuActions == [.react, .copy, .selectText, .forkFromHere]
        )
    }

    @Test func allMentionIsAnIdentityPillAtItsOriginalPosition() {
        let rendered = ChatNativeMarkdownAttributedBuilder.build(
            document: MarkdownDocument("Ask @all about this."), style: style())
        #expect(rendered.string == "Ask \u{fffc} about this.")
        #expect(rendered.attribute(.attachment, at: 4, effectiveRange: nil) is NSTextAttachment)
    }

    @Test func agentMentionsStayInlineAndCopyKeepsTypedHandles() throws {
        var mentionStyle = style()
        mentionStyle.mentionIdentities = [.init(handle: "sage", name: "Sage Green")]
        let source = "Before @SAGE, ask @all; then @sage! After."
        let rendered = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument(source), style: mentionStyle)
        #expect(rendered.string == "Before \u{fffc}, ask \u{fffc}; then \u{fffc}! After.")
        #expect(ChatMentionRendering.plainText(rendered) == source)
        #expect(ChatMentionRendering.plainText(rendered, usingNames: true)
            == "Before Sage Green, ask All; then Sage Green! After.")
        let attachment = try #require(rendered.attribute(.attachment, at: 7, effectiveRange: nil) as? ChatMentionAttachment)
        #expect(attachment.displayName == "Sage Green")
        #expect(attachment.image != nil)
        let view = ChatMentionTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.textStorage.setAttributedString(rendered)
        view.selectedRange = NSRange(location: 7, length: 6)
        // Only read what this test writes; reading another process's clipboard prompts for permission.
        defer { UIPasteboard.general.items = [] }
        view.copy(nil)
        #expect(UIPasteboard.general.string == "@SAGE, ask")
    }

    @Test func onlyRecognizedProseMentionsBecomePills() {
        var mentionStyle = style()
        mentionStyle.mentionIdentities = [.init(handle: "sage", name: "Sage Green")]
        let source = "person@sage.test https://example.test/@sage `@sage` [@sage](https://example.test) @missing @sage/path\n\n```\n@all @sage\n```"
        let rendered = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument(source), style: mentionStyle)
        var count = 0
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value is ChatMentionAttachment { count += 1 }
        }
        #expect(count == 0)
        #expect(ChatMentionRendering.plainText(rendered).contains("@missing @sage/path"))
        let noMention = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument("Just an update."), style: mentionStyle)
        #expect(noMention.string == "Just an update.")
    }

    @Test func unicodeMentionsAndAmbiguousNamesDoNotChangeSurroundingText() {
        var mentionStyle = style()
        mentionStyle.mentionIdentities = [.init(handle: "café", name: "Café Agent")]
        let source = "👋🏽 Ask @cafe\u{301}. Done."
        let rendered = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument(source), style: mentionStyle)
        #expect(rendered.string == "👋🏽 Ask \u{fffc}. Done.")
        #expect(Array(ChatMentionRendering.plainText(rendered).utf8) == Array(source.utf8))
        mentionStyle.mentionIdentities.append(.init(handle: "CAFÉ", name: "Another Agent"))
        let ambiguous = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument(source), style: mentionStyle)
        #expect(ambiguous.string == source)
    }

    @Test func mentionRenderingRefreshesForNamesAndGrowsWithDynamicType() throws {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("Ask @sage.")
        var mentionStyle = style()
        mentionStyle.mentionIdentities = [.init(handle: "sage", name: "Sage Green")]
        let first = cache.render(document: document, style: mentionStyle)
        #expect(cache.render(document: document, style: mentionStyle) === first)
        let normal = try #require(first.attribute(.attachment, at: 4, effectiveRange: nil) as? ChatMentionAttachment)
        mentionStyle.mentionIdentities = [.init(handle: "sage", name: "Sage Blue")]
        let renamed = cache.render(document: document, style: mentionStyle)
        #expect(ChatMentionRendering.plainText(renamed, usingNames: true) == "Ask Sage Blue.")
        var largeStyle = style(.accessibilityExtraExtraExtraLarge)
        largeStyle.mentionIdentities = mentionStyle.mentionIdentities
        let large = cache.render(document: document, style: largeStyle)
        let larger = try #require(large.attribute(.attachment, at: 4, effectiveRange: nil) as? ChatMentionAttachment)
        #expect(larger.bounds.height > normal.bounds.height)
        #expect(larger.bounds.width <= 220 + larger.font.pointSize)
    }

    @Test func streamingKeepsTheExistingPillAndOnlyEditsTheSuffix() throws {
        let cache = ChatNativeMarkdownRenderCache()
        var mentionStyle = style()
        mentionStyle.mentionIdentities = [.init(handle: "sage", name: "Sage Green")]
        let first = cache.render(document: MarkdownDocument("Ask @sage. Stable text."), style: mentionStyle)
        let attachment = try #require(first.attribute(.attachment, at: 4, effectiveRange: nil) as? ChatMentionAttachment)
        let updated = cache.render(document: MarkdownDocument("Ask @sage. Stable text. More text."), style: mentionStyle)
        #expect(updated.attribute(.attachment, at: 4, effectiveRange: nil) as? ChatMentionAttachment === attachment)
        let storage = NSTextStorage(attributedString: first)
        ChatNativeTextStorageUpdater.apply(updated, previous: first, to: storage)
        #expect(ChatMentionRendering.plainText(storage) == "Ask @sage. Stable text. More text.")
        #expect(storage.attribute(.attachment, at: 4, effectiveRange: nil) as? ChatMentionAttachment === attachment)
    }

    @Test func nativeProseUsesSystemFontByDefault() throws {
        let rendered = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument("Hello"), style: style())
        let actual = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(actual.fontName == BighelpTheme.light.uiFont(.body).fontName)
    }

    private func style(_ category: UIContentSizeCategory = .large) -> ChatNativeMarkdownStyle {
        .init(primaryText: .label, secondaryText: .secondaryLabel, accent: .systemBlue,
              codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
              traitCollection: UITraitCollection(preferredContentSizeCategory: category))
    }

    @Test func unchangedMarkdownReusesAttributedRenderingAndInvalidatesForTextAndStyle() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**One** and [link](https://example.com)")
        let first = cache.render(document: document, style: style())
        for _ in 0..<100 {
            #expect(cache.render(document: document, style: style()) === first)
        }
        let changed = cache.render(document: MarkdownDocument("**Two**"), style: style())
        #expect(changed !== first)
        #expect(changed.string == "Two")
        let large = cache.render(document: MarkdownDocument("**Two**"), style: style(.accessibilityExtraExtraExtraLarge))
        #expect(large !== changed)
        let largeFont = large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let normalFont = changed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect((largeFont?.pointSize ?? 0) > (normalFont?.pointSize ?? 0))
    }

    @Test func recreatedSwiftUIColorsReuseUnchangedNativeRendering() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**Same** message across tool updates")
        func recreatedStyle() -> ChatNativeMarkdownStyle {
            .init(primaryText: UIColor(Color(red: 0.8, green: 0.7, blue: 0.6)),
                  secondaryText: UIColor(Color.secondary), accent: UIColor(Color.blue),
                  codeBackground: UIColor(Color.black.opacity(0.1)), proseLineSpacing: 5,
                  traitCollection: UITraitCollection(traitsFrom: [
                    .init(userInterfaceStyle: .dark), .init(preferredContentSizeCategory: .large)]))
        }
        let first = cache.render(document: document, style: recreatedStyle())
        #expect(cache.render(document: document, style: recreatedStyle()) === first,
                "Equivalent SwiftUI color bridges must not rebuild unchanged message text")
    }

    @Test func unchangedSourceReusesParsingWithoutLosingByteDistinctEdits() {
        let cache = ChatMessageContentCache()
        let original = cache.project("**Caf\u{00e9}**")
        #expect(cache.project("**Caf\u{00e9}**") === original)
        let edited = cache.project("**Cafe\u{0301}**")
        #expect(edited !== original)
        #expect(Array(edited.references.source.utf8) == Array("**Cafe\u{0301}**".utf8))
        #expect(edited.document.visiblePlainText == "Cafe\u{0301}")
        let malformed = "Text\n```loopdy-references-v1\ninvalid"
        let failed = cache.project(malformed)
        #expect(failed.references.failure != nil)
        #expect(failed.references.prose == malformed)
        #expect(failed.references.references.isEmpty)
        #expect(cache.project(malformed) === failed)
        #expect(cache.project("**Caf\u{00e9}**") !== original,
                "Keep only the current source revision, not every past message value")
    }

    @Test func layoutTraitsDoNotInvalidateIdenticalRenderedText() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**Stable** text while surrounding views change")
        func layoutStyle(_ scale: CGFloat) -> ChatNativeMarkdownStyle {
            .init(primaryText: .label, secondaryText: .secondaryLabel, accent: .systemBlue,
                  codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
                  traitCollection: UITraitCollection(traitsFrom: [
                    .init(preferredContentSizeCategory: .large),
                    .init(userInterfaceStyle: .light), .init(displayScale: scale)]))
        }
        let first = cache.render(document: document, style: layoutStyle(2))
        #expect(cache.render(document: document, style: layoutStyle(3)) === first,
                "Layout-only traits cannot invalidate identical fonts and colors")
        let dark = ChatNativeMarkdownStyle(primaryText: .label, secondaryText: .secondaryLabel,
            accent: .systemBlue, codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
            traitCollection: UITraitCollection(traitsFrom: [
                .init(preferredContentSizeCategory: .large), .init(userInterfaceStyle: .dark)]))
        #expect(cache.render(document: document, style: dark) !== first,
                "A real resolved color change must invalidate the rendered revision")
    }

    @Test func nativeMeasurementReusesSizesAndInvalidatesWithRenderedRevision() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("**A** message")
        _ = cache.render(document: document, style: style())
        var calls = 0
        func measure(_ width: CGFloat) -> CGSize {
            calls += 1
            return CGSize(width: width, height: CGFloat(calls))
        }
        let first = cache.measure(width: 300, using: measure)
        for _ in 0..<100 {
            #expect(cache.measure(width: 300, using: measure) == first)
        }
        #expect(calls == 1)
        _ = cache.measure(width: 200, using: measure)
        #expect(calls == 2)
        #expect(cache.measure(width: 300, using: measure) == first)
        _ = cache.render(document: document, style: style())
        #expect(cache.measure(width: 300, using: measure) == first)
        _ = cache.render(document: MarkdownDocument("Changed text"), style: style())
        #expect(cache.measure(width: 300, using: measure) != first)
        #expect(calls == 3)
        _ = cache.render(document: MarkdownDocument("Changed text"), style: style(.accessibilityExtraExtraExtraLarge))
        _ = cache.measure(width: 300, using: measure)
        #expect(calls == 4)
        for width in 301...310 { _ = cache.measure(width: CGFloat(width), using: measure) }
        let before = calls
        _ = cache.measure(width: 300, using: measure)
        #expect(calls == before + 1, "Old widths must be evicted from the bounded per-view cache")
    }

    @Test func formattedTextKeepsInlineTraitsAndExactLinks() throws {
        let result = ChatNativeMarkdownAttributedBuilder.build(
            document: MarkdownDocument("**Bold** and *italic* with `code` and [Apple](https://apple.com)."), style: style())
        #expect(result.string == "Bold and italic with code and Apple.")
        let text = result.string as NSString
        let bold = try #require(result.attribute(.font, at: text.range(of: "Bold").location, effectiveRange: nil) as? UIFont)
        let italic = try #require(result.attribute(.font, at: text.range(of: "italic").location, effectiveRange: nil) as? UIFont)
        let code = try #require(result.attribute(.font, at: text.range(of: "code").location, effectiveRange: nil) as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect((result.attribute(.link, at: text.range(of: "Apple").location, effectiveRange: nil) as? URL)?.absoluteString == "https://apple.com")
    }

    @Test func blockTextAndDynamicTypeRemainReadable() throws {
        let document = MarkdownDocument("# Heading\n\nA paragraph.\n\n- First\n- Second\n\n> Quoted\n\n```swift\nlet x = 1\n```")
        let normal = ChatNativeMarkdownAttributedBuilder.build(document: document, style: style())
        let large = ChatNativeMarkdownAttributedBuilder.build(document: document, style: style(.accessibilityExtraExtraExtraLarge))
        #expect(normal.string == large.string)
        for text in ["Heading", "A paragraph.", "First", "Second", "Quoted", "let x = 1"] {
            #expect(normal.string.contains(text))
        }
        #expect(!normal.string.contains("```"))
        let normalFont = try #require(normal.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let largeFont = try #require(large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(largeFont.pointSize > normalFont.pointSize)
    }
}
