import Foundation
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct ChatCitationTests {
    @Test func resolvesOnlyExplicitUnambiguousWebReferencesOutsideCode() {
        let source = """
        Answer.[1][2][3]

        [1]: https://example.com/one
        - [2] [The **second** guide](https://example.com/two)
        [3] https://example.com/three
        [3] https://example.com/conflict
        [4] https://example.com/a and https://example.com/b
        [5] [Local](file:///tmp/example)
        [6] `https://example.com/code`
        7. https://example.com/ordinary-list
        ```loopdy-card
        [8] https://example.com/card
        ```
        ~~~text
        [9] https://example.com/fenced
        ~~~
            [10] https://example.com/indented
        ```
        [11] https://example.com/unfinished
        """
        #expect(ChatCitationLinks.resolve(in: source) == [
            1: URL(string: "https://example.com/one")!,
            2: URL(string: "https://example.com/two")!,
        ])
    }

    @Test func linksOnlyProseAndPreservesCharactersAndExistingDestinations() {
        let links = [1: URL(string: "https://example.com/one")!]
        let markdown = "👋🏽 Answer.[1] `code[1]` arr[1] [existing [1]](https://example.com/existing) Unknown.[2]"
        let plain = ChatInlineMarkdown.attributedText(markdown)
        let linked = ChatCitationLinks.applying(to: plain, links: links)
        #expect(String(linked.characters) == String(plain.characters))
        #expect(linked.runs.compactMap(\.link) == [links[1]!, URL(string: "https://example.com/existing")!])
        #expect(ChatCitationLinks.applying(to: plain, links: [:]) == plain)
    }

    @Test func projectionLinksOnlyFinishedAssistantRevisionsAndKeepsOriginalContent() {
        let cache = ChatMessageContentCache()
        let source = "Answer.[15]\n\n[15] https://example.com/source"
        let streaming = cache.project(source, isStreaming: true)
        #expect(streaming.citationLinks.isEmpty)
        let final = cache.project(source)
        #expect(final.citationLinks[15] == URL(string: "https://example.com/source"))
        #expect(cache.project(source) === final)
        #expect(final.document == streaming.document)
        #expect(final.references.prose == source)
        #expect(final.linkPreviewURL == streaming.linkPreviewURL)
        #expect(final.document.visiblePlainText == streaming.document.visiblePlainText)
        #expect(cache.project(source, role: .human).citationLinks.isEmpty)
        #expect(cache.project(source.replacingOccurrences(of: "/source", with: "/changed")).citationLinks[15]
                == URL(string: "https://example.com/changed"))
        #expect(cache.project("Answer.[15]").citationLinks.isEmpty)
    }

    @Test func renderCacheInvalidatesForCitationDestinationsAndReusesUnchangedRender() {
        let cache = ChatNativeMarkdownRenderCache()
        let document = MarkdownDocument("Answer.[1]")
        var style = ChatNativeMarkdownStyle(primaryText: .label, secondaryText: .secondaryLabel,
            accent: .systemBlue, codeBackground: .systemGray, proseLineSpacing: 5,
            traitCollection: UITraitCollection())
        let original = cache.render(document: document, style: style)
        style.citationLinks = [1: URL(string: "https://example.com/source")!]
        let linked = cache.render(document: document, style: style)
        #expect(linked.string == original.string)
        #expect(!linked.isEqual(to: original))
        #expect(cache.render(document: document, style: style) === linked)
        let index = (linked.string as NSString).range(of: "[1]").location
        #expect(linked.attribute(.link, at: index, effectiveRange: nil) as? URL == style.citationLinks[1])
    }

    @Test func longAnswerCitationCompletionKeepsGeometryAndCachedMeasurements() {
        let source = String(repeating: "A longer garden guide with enough detail to wrap onto several lines.[1]\n\n", count: 100)
            + "[1] https://example.com/garden"
        let document = MarkdownDocument(source)
        var style = ChatNativeMarkdownStyle(primaryText: .label, secondaryText: .secondaryLabel,
            accent: .systemBlue, codeBackground: .systemGray, proseLineSpacing: 5,
            traitCollection: UITraitCollection())
        let cache = ChatNativeMarkdownRenderCache()
        let view = UITextView(usingTextLayoutManager: false)
        view.isScrollEnabled = false
        let old = cache.render(document: document, style: style)
        view.attributedText = old
        let size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
        let start = Date.timeIntervalSinceReferenceDate
        style.citationLinks = ChatCitationLinks.resolve(in: source)
        let final = cache.render(document: document, style: style)
        ChatNativeTextStorageUpdater.apply(final, previous: old, to: view.textStorage)
        let finalSize = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
        let milliseconds = (Date.timeIntervalSinceReferenceDate - start) * 1_000
        #expect(finalSize == size)
        #expect(final.string == old.string)
        var measurements = 0
        for _ in 0..<100 {
            #expect(cache.render(document: document, style: style) === final)
            _ = cache.measure(width: 350) { _ in measurements += 1; return finalSize }
        }
        #expect(measurements == 1)
        print("CITATION_COMPLETION characters=\(source.count) milliseconds=\(milliseconds)")
    }
}
