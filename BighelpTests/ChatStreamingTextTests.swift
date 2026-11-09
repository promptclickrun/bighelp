import Testing
import UIKit
@testable import Bighelp

/// A streamed answer comes as the whole answer again for each piece. These keep the work for a
/// piece to what changed: the last block, and the text laid out since.
@MainActor
struct ChatStreamingTextTests {
    @Test func aGrowingAnswerKeepsItsFinishedBlocks() throws {
        let cache = ChatNativeMarkdownRenderCache()
        let finished = "## Plan\n\nFirst **check** the bill.\n\n- one\n- two\n\n"
        var text = finished + "The last paragraph"
        var previous = cache.render(document: MarkdownDocument(text), style: style())
        let boundary = (previous.string as NSString).range(of: "The last paragraph").location
        for piece in [" keeps", " growing", " with `code`."] {
            text += piece
            let revision = cache.revision
            let updated = cache.render(document: MarkdownDocument(text), style: style())
            #expect(cache.revision == revision &+ 1)
            // Everything before the paragraph being written stays, up to its line break.
            #expect(cache.unchangedPrefix == boundary - 1)
            #expect(updated.attributedSubstring(from: NSRange(location: 0, length: cache.unchangedPrefix))
                .isEqual(to: previous.attributedSubstring(from: NSRange(location: 0, length: cache.unchangedPrefix))))
            // And it is the text a fresh build of the whole answer gives.
            #expect(updated.isEqual(to: ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument(text),
                                                                                  style: style())))
            previous = updated
        }
    }

    @Test func aNewBlockDrawsTheOneBeforeItAgain() throws {
        // The space under a block depends on what follows it.
        let cache = ChatNativeMarkdownRenderCache()
        _ = cache.render(document: MarkdownDocument("One.\n\nTwo."), style: style())
        let updated = cache.render(document: MarkdownDocument("One.\n\nTwo.\n\n## Three"), style: style())
        #expect(cache.unchangedPrefix == ("One." as NSString).length)
        #expect(updated.isEqual(to: ChatNativeMarkdownAttributedBuilder.build(
            document: MarkdownDocument("One.\n\nTwo.\n\n## Three"), style: style())))
    }

    @Test func aChangeEarlierInTheAnswerOrInItsLookStartsOver() throws {
        let cache = ChatNativeMarkdownRenderCache()
        _ = cache.render(document: MarkdownDocument("One.\n\nTwo.\n\nThree."), style: style())
        let edited = cache.render(document: MarkdownDocument("Won.\n\nTwo."), style: style())
        #expect(cache.unchangedPrefix == 0)
        #expect(edited.isEqual(to: ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument("Won.\n\nTwo."),
                                                                             style: style())))
        let large = cache.render(document: MarkdownDocument("Won.\n\nTwo.\n\nMore."),
                                 style: style(.accessibilityLarge))
        #expect(cache.unchangedPrefix == 0)
        #expect(large.isEqual(to: ChatNativeMarkdownAttributedBuilder.build(
            document: MarkdownDocument("Won.\n\nTwo.\n\nMore."), style: style(.accessibilityLarge))))
    }

    @Test func theTextViewTakesOnlyTheChangedEnd() throws {
        let cache = ChatNativeMarkdownRenderCache()
        let first = cache.render(document: MarkdownDocument("Done **here**.\n\nStill writing"), style: style())
        let storage = EditRecordingTextStorage(attributedString: first)
        let updated = cache.render(document: MarkdownDocument("Done **here**.\n\nStill writing this."), style: style())
        ChatNativeTextStorageUpdater.apply(updated, previous: first, unchangedPrefix: cache.unchangedPrefix, to: storage)
        #expect(storage.isEqual(to: updated))
        let edit = try #require(storage.edits.last)
        #expect(storage.edits.count == 1)
        #expect(edit.location == ("Done here.\nStill writing" as NSString).length)
    }

    @Test func aStalePrefixNeverSkipsAChange() {
        // A view that missed a render gets a prefix that describes another change: text that
        // differs before it must still be replaced.
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17)]
        let previous = NSAttributedString(string: "Alpha beta", attributes: attributes)
        let updated = NSAttributedString(string: "Alpine beta gamma", attributes: attributes)
        let storage = NSTextStorage(attributedString: previous)
        ChatNativeTextStorageUpdater.apply(updated, previous: previous, unchangedPrefix: 8, to: storage)
        #expect(storage.string == "Alpine beta gamma")
    }

    @Test(arguments: [
        "Short.",
        "A longer paragraph that wraps over several lines at a phone's width, with **bold** words and `code` in it.",
        "## Heading\n\nA paragraph.\n\n- first item\n- second item that is long enough to wrap onto another line\n\n```\nlet x = 1\n```",
    ])
    func aSideLayoutMeasuresWhatTheTextViewDoes(markdown: String) {
        let text = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument(markdown), style: style())
        let view = messageTextView()
        view.textStorage.setAttributedString(text)
        let side = ChatNativeMarkdownSideLayouts(textStorage: view.textStorage)
        for width: CGFloat in [120, 280, 393, 700] {
            let expected = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            #expect(side.size(width: width).height == ceil(expected.height), "width \(width)")
        }
    }

    @Test func aSideLayoutFollowsTheTextAsItGrowsAndLetsGo() {
        let view = messageTextView()
        let cache = ChatNativeMarkdownRenderCache()
        let first = cache.render(document: MarkdownDocument("One line."), style: style())
        view.textStorage.setAttributedString(first)
        let side = ChatNativeMarkdownSideLayouts(textStorage: view.textStorage)
        let short = side.size(width: 200).height
        let longer = String(repeating: "More words that wrap. ", count: 12)
        let updated = cache.render(document: MarkdownDocument("One line.\n\n" + longer), style: style())
        ChatNativeTextStorageUpdater.apply(updated, previous: first, unchangedPrefix: cache.unchangedPrefix,
                                           to: view.textStorage)
        #expect(side.size(width: 200).height > short)
        #expect(side.size(width: 200).height
                == ceil(view.sizeThatFits(CGSize(width: 200, height: .greatestFiniteMagnitude)).height))
        // Never more than a few widths, and none once the text is still.
        for width in stride(from: CGFloat(100), through: 600, by: 100) { _ = side.size(width: width) }
        #expect(view.textStorage.layoutManagers.count == 1 + ChatNativeMarkdownSideLayouts.limit)
        side.release()
        #expect(view.textStorage.layoutManagers.count == 1)
    }

    @Test func copyTextIsMadeOnlyWhenRead() {
        let document = MarkdownDocument("Use **bighelp** and [open settings](https://example.com).")
        let interaction = ChatBubbleInteraction(document: document, canFork: false)
        #expect(interaction.copyText == document.visiblePlainText)
        #expect(ChatBubbleInteraction(document: document, canFork: false, canonicalSource: "Source").copyText == "Source")
    }

    @Test func aMessageWithNoCardIsParsedOnce() {
        #expect(!ChatCardMessageProjection.mayHoldCard("Plain **text**\n```swift\nlet x = 1\n```\nDone", isStreaming: true))
        #expect(ChatCardMessageProjection.mayHoldCard("Here:\n```loopdy-card\n{}", isStreaming: false))
        // While an answer arrives, a last line that may become a card fence is a card on its way.
        #expect(ChatCardMessageProjection.mayHoldCard("Here:\n```loop", isStreaming: true))
        #expect(ChatCardMessageProjection.mayHoldCard("Here:\n```", isStreaming: true))
        #expect(!ChatCardMessageProjection.mayHoldCard("Here:\n```loop", isStreaming: false))
        // The parsed document gives the same parts as parsing the text again.
        let source = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\nOutro with `code`."
        let parts = ChatCardMessageProjection(document: MarkdownDocument(source))
        let parsedAgain = ChatCardMessageProjection(source: source, role: .assistant)
        #expect(parts.segments == parsedAgain.segments)
        #expect(parts.cardIDs == parsedAgain.cardIDs)
    }

    /// The message text view's own setup: TextKit 1, no insets, no line padding.
    private func messageTextView() -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        return view
    }

    private func style(_ category: UIContentSizeCategory = .large) -> ChatNativeMarkdownStyle {
        .init(primaryText: .label, secondaryText: .secondaryLabel, accent: .systemBlue,
              codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
              traitCollection: UITraitCollection(preferredContentSizeCategory: category))
    }
}

/// Records where each replacement starts.
private final class EditRecordingTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    private(set) var edits: [NSRange] = []

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        if backing.length > 0 { edits.append(range) }
        beginEditing()
        backing.replaceCharacters(in: range, with: attrString)
        edited([.editedCharacters, .editedAttributes], range: range, changeInLength: attrString.length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }
}

/// What the chat's rows do with a growing answer, in a real window.
@MainActor
struct ChatStreamingBubbleTests {
    @Test(.timeLimit(.minutes(1)))
    func aGrowingAnswersBubbleGrowsWithIt() async throws {
        func view(_ text: String) -> some View {
            MessageBubble(role: .assistant, speakerName: "Agent", text: text, delivery: "Streaming",
                          isPendingSubmission: false, onFork: nil)
                .environment(\.bighelpUIV3Enabled, true)
                .frame(width: 350)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        var text = "The first line of an answer."
        let host = UIHostingController(rootView: view(text))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func textHosts(_ view: UIView) -> [ChatMessageTextHost] {
            (view as? ChatMessageTextHost).map { [$0] } ?? view.subviews.flatMap(textHosts)
        }
        try await Task.sleep(for: .milliseconds(250))
        let textHost = try #require(textHosts(host.view).first)
        var last = textHost.bounds.height
        #expect(last > 0)
        // Paragraph after paragraph, the way an answer arrives: the bubble must take each one.
        for paragraph in 1...6 {
            text += "\n\nParagraph \(paragraph) has enough **words** in it to wrap over more than one line at this width."
            host.rootView = view(text)
            try await Task.sleep(for: .milliseconds(150))
            #expect(textHost.bounds.height > last, "paragraph \(paragraph)")
            last = textHost.bounds.height
        }
        // The bubble is as tall as its text, and the text view under it has room to grow.
        let needed = ChatNativeMarkdownSideLayouts(textStorage: textHost.textView.textStorage)
            .size(width: textHost.bounds.width).height
        #expect(abs(textHost.bounds.height - needed) <= 1)
        #expect(textHost.textView.frame.height >= textHost.bounds.height)
        #expect(textHost.textView.frame.height.truncatingRemainder(dividingBy: ChatMessageTextHost.growthStep) == 0)
        // Once the text is still, the text view is the bubble's own size again.
        try await Task.sleep(for: .milliseconds(1_800))
        #expect(textHost.textView.frame.height == textHost.bounds.height)
    }
}
