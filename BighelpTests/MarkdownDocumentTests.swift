import Foundation
import Testing
@testable import Bighelp

struct MarkdownDocumentTests {
    @Test func chatBubbleWidthUsesAnIMessageLikeResponsiveMaximum() {
        #expect(abs(ChatBubbleLayoutMetrics.maximumWidth(containerWidth: 390) - 319.8) < 0.001)
        // A landscape iPad's lane gets wide bubbles; only huge widths are capped.
        #expect(abs(ChatBubbleLayoutMetrics.maximumWidth(containerWidth: 1_024) - 839.68) < 0.001)
        #expect(ChatBubbleLayoutMetrics.maximumWidth(containerWidth: 2_000) == ChatBubbleLayoutMetrics.maximumAbsoluteWidth)
        #expect(ChatBubbleLayoutMetrics.maximumWidth(containerWidth: 0) == 0)
    }

    @Test func parsesNativeRichTextBlocksWithoutDroppingSourceContent() {
        let source = """
        # Release summary

        This is **ready** with a [runbook](https://example.com/runbook).

        A consecutive paragraph confirms comfortable body rhythm.

        ## Checklist

        - First check
        - Second check

        ### Ordered steps

        1. Pair the device
        2. Start the session

        > Keep the paired host online.

        ```swift
        let state = "ready"
        ```
        """

        let document = MarkdownDocument(source)

        #expect(document.blocks == [
            .heading(level: 1, markdown: "Release summary"),
            .paragraph(markdown: "This is **ready** with a [runbook](https://example.com/runbook)."),
            .paragraph(markdown: "A consecutive paragraph confirms comfortable body rhythm."),
            .heading(level: 2, markdown: "Checklist"),
            .unorderedList(items: ["First check", "Second check"]),
            .heading(level: 3, markdown: "Ordered steps"),
            .orderedList(start: 1, items: ["Pair the device", "Start the session"]),
            .quote(markdown: "Keep the paired host online."),
            .code(language: "swift", text: "let state = \"ready\"")
        ])
    }

    @Test func visiblePlainTextStripsMarkdownDecorationButRetainsAnswerMeaning() {
        let document = MarkdownDocument("Use **bighelp Link** and read [the guide](https://example.com).\n\n- One\n- Two")

        #expect(document.visiblePlainText == "Use bighelp Link and read the guide.\n\nOne\nTwo")
    }

    @Test func malformedMarkdownFallsBackToReadableVisibleText() {
        let source = "An unfinished **answer and `code"

        let document = MarkdownDocument(source)

        #expect(document.blocks == [.paragraph(markdown: source)])
        #expect(document.visiblePlainText == source)
    }

    @Test func emptyMarkdownProducesNoDecorativeBlocks() {
        let document = MarkdownDocument(" \n\n ")

        #expect(document.blocks.isEmpty)
        #expect(document.visiblePlainText.isEmpty)
    }

    @Test func bubbleInteractionReusesTheAlreadyParsedDocument() {
        let document = MarkdownDocument("Use **bighelp** and [settings](https://loopdy.app).")
        let interaction = ChatBubbleInteraction(document: document, canFork: true)
        #expect(interaction.copyText == document.visiblePlainText)
        #expect(interaction.menuActions == [.copy, .selectText, .forkFromHere])
    }

    @Test func bubbleInteractionsCopyVisibleRichTextAndExposeForkOnlyWhenAllowed() {
        let interaction = ChatBubbleInteraction(
            markdown: "Use **bighelp Link** and [open settings](https://loopdy.app).",
            canFork: true
        )

        #expect(interaction.copyText == "Use bighelp Link and open settings.")
        #expect(interaction.menuActions == [.copy, .selectText, .forkFromHere])
        #expect(
            ChatBubbleInteraction(markdown: "Draft", canFork: false).menuActions
                == [.copy, .selectText]
        )
    }

    @Test func bareWebURLsBecomeInteractiveWithoutRequiringMarkdownLinkSyntax() throws {
        let attributed = ChatInlineMarkdown.attributedText(
            "Read https://loopdy.app/docs?source=chat#links for details."
        )
        let links = attributed.runs.compactMap(\.link)

        #expect(links == [try #require(URL(
            string: "https://loopdy.app/docs?source=chat#links"
        ))])
    }

    @Test func markdownLinksKeepTheirDestinationWhenBareURLDetectionRuns() throws {
        let attributed = ChatInlineMarkdown.attributedText(
            "Open [the bighelp guide](https://loopdy.app/guide)."
        )
        let links = attributed.runs.compactMap(\.link)

        #expect(links == [try #require(URL(string: "https://loopdy.app/guide"))])
    }

    @Test func markdownBlocksAlwaysGrowVerticallyInsteadOfEllipsizingWrappedText() {
        #expect(ChatMarkdownLayoutPolicy.growsVerticallyWithoutTruncation)
    }

    @Test func primaryMarkdownHeadingsUseDistinctSemanticStylesAboveBodyText() {
        #expect(ChatMarkdownTypography.headingRole(for: 1) == .display)
        #expect(ChatMarkdownTypography.headingRole(for: 2) == .screenTitle)
        #expect(ChatMarkdownTypography.headingRole(for: 3) == .sectionTitle)
    }

    @Test func markdownUsesReadableParagraphAndSectionRhythm() {
        #expect(ChatMarkdownLayoutPolicy.blockSpacing == 16)
        #expect(ChatMarkdownLayoutPolicy.spacing(
            after: .heading(level: 1, markdown: "Overview"),
            before: .paragraph(markdown: "Opening paragraph.")
        ) == 8)
        #expect(ChatMarkdownLayoutPolicy.spacing(
            after: .paragraph(markdown: "Opening paragraph."),
            before: .paragraph(markdown: "Consecutive paragraph.")
        ) == 16)
        #expect(ChatMarkdownLayoutPolicy.spacing(
            after: .paragraph(markdown: "Consecutive paragraph."),
            before: .heading(level: 2, markdown: "Details")
        ) == 20)
        #expect(ChatMarkdownLayoutPolicy.spacing(
            after: .unorderedList(items: ["One item"]),
            before: .quote(markdown: "A supporting note.")
        ) == 16)
        #expect(ChatMarkdownLayoutPolicy.listRowSpacing == 8)
        #expect(ChatMarkdownLayoutPolicy.unorderedMarkerWidth == 16)
        #expect(ChatMarkdownLayoutPolicy.orderedMarkerWidth == 28)
    }

    @Test func toolDetailsPrettyPrintStructuredJSONAndPreservePlainText() {
        #expect(ChatToolDetailFormatter.format("{\"query\":\"Work\",\"limit\":5}") == """
        {
          "limit" : 5,
          "query" : "Work"
        }
        """)
        #expect(ChatToolDetailFormatter.format("Command completed successfully") == "Command completed successfully")
    }

    /// Code that prints one number or word gives output that is a JSON
    /// fragment. Writing a fragment back raised an Objective-C exception that
    /// `try?` can't catch, so unfolding the tool call ended the app.
    @Test func toolDetailsKeepJSONFragmentsAsTheyAre() {
        for fragment in ["84.5\n", "42", "true", "null", #""done""#] {
            #expect(ChatToolDetailFormatter.format(fragment) == fragment)
            #expect(!ChatToolDetailPreview(fragment).text.isEmpty)
        }
    }

    @Test func largeToolPreviewBoundsLayoutAndPreservesCompleteUnicodeContent() {
        let original = String(repeating: "👩🏽‍💻 file.swift: verified result\n", count: 5_000)
        let preview = ChatToolDetailPreview(original)
        #expect(preview.isTruncated)
        #expect(preview.text.unicodeScalars.count <= 2_048)
        #expect(preview.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 16)
        let pages = ChatToolDetailPreview.pages(original)
        #expect(pages.joined() == original)
        #expect(pages.allSatisfy { $0.unicodeScalars.count <= 4_096 })
    }

    @Test func smallToolPreviewKeepsReadableJSON() {
        let original = "{\"count\":2}"
        let preview = ChatToolDetailPreview(original)
        #expect(!preview.isTruncated)
        #expect(preview.text == ChatToolDetailFormatter.format(original))
    }

    @Test func cancelledToolReaderPreparationDiscardsPartialPages() {
        var checks = 0
        let pages = ChatToolDetailPreview.pages(String(repeating: "large result ", count: 10_000), isCancelled: {
            checks += 1
            return checks == 2
        })
        #expect(pages.isEmpty)
        #expect(checks == 2)
    }
}

struct ProjectChangesMarkdownPreviewTests {
    @Test func regularPanelSnapsBetweenSplitAndFullContainerWidths() {
        #expect(ProjectChangesPanelWidthPolicy.snap(width: 560, containerWidth: 1024) == 520)
        #expect(ProjectChangesPanelWidthPolicy.snap(width: 760, containerWidth: 1024) == 1024)
    }

    @Test func regularPanelClampsDragToMinimumAndContainerWidth() {
        #expect(ProjectChangesPanelWidthPolicy.clamp(width: 200, containerWidth: 1024) == 520)
        #expect(ProjectChangesPanelWidthPolicy.clamp(width: 1400, containerWidth: 1024) == 1024)
    }

    @Test func regularPanelUsesActualDragTranslationWhenSnapping() {
        #expect(
            ProjectChangesPanelWidthPolicy.snappedWidth(
                startWidth: 520,
                translation: -600,
                containerWidth: 1024
            ) == 1024
        )
        #expect(
            ProjectChangesPanelWidthPolicy.snappedWidth(
                startWidth: 1024,
                translation: 600,
                containerWidth: 1024
            ) == 520
        )
    }

    @Test func displayStateStartsInDiffAllowsPreviewAndResetsForANewFile() {
        var state = ProjectChangesDiffDisplayState()

        #expect(state.mode == .diff)
        state.select(.preview)
        #expect(state.mode == .preview)

        state.prepareForFileSelection()

        #expect(state.mode == .diff)
    }

    @Test func fullyLoadedUntrackedMarkdownReconstructsTheSelectedFileContent() {
        let file = ProjectGitFileChange(
            path: "README.md",
            originalPath: nil,
            indexStatus: "?",
            worktreeStatus: "?",
            kind: .untracked,
            insertions: 3,
            deletions: 0,
            isBinary: false
        )
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .worktree,
            availability: .available,
            offset: 0,
            lines: [
                .init(offset: 0, kind: .addition, oldLine: nil, newLine: 1, content: "# Hello"),
                .init(offset: 1, kind: .addition, oldLine: nil, newLine: 2, content: ""),
                .init(offset: 2, kind: .addition, oldLine: nil, newLine: 3, content: "- One"),
            ],
            nextOffset: nil
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .content("# Hello\n\n- One")
        )
    }

    @Test func pagedMarkdownDiffRequiresEveryPageBeforePreviewing() {
        let file = ProjectGitFileChange(
            path: "Notes.markdown",
            originalPath: nil,
            indexStatus: "?",
            worktreeStatus: "?",
            kind: .untracked,
            insertions: 2,
            deletions: 0,
            isBinary: false
        )
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .worktree,
            availability: .available,
            offset: 0,
            lines: [
                .init(offset: 0, kind: .addition, oldLine: nil, newLine: 1, content: "# Partial"),
            ],
            nextOffset: 1
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .unavailable("Load every diff page before previewing this Markdown file.")
        )
    }

    @Test func trackedMarkdownHunksNeverMasqueradeAsACompleteFile() {
        let file = ProjectGitFileChange(
            path: "README.md",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary,
            insertions: 1,
            deletions: 1,
            isBinary: false
        )
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .worktree,
            availability: .available,
            offset: 0,
            lines: [
                .init(offset: 0, kind: .header, oldLine: nil, newLine: nil, content: "@@ -20,4 +20,4 @@"),
                .init(offset: 1, kind: .context, oldLine: 20, newLine: 20, content: "Before"),
                .init(offset: 2, kind: .deletion, oldLine: 21, newLine: nil, content: "Old"),
                .init(offset: 3, kind: .addition, oldLine: nil, newLine: 21, content: "New"),
            ],
            nextOffset: nil
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .unavailable(
                    "Tracked diffs contain changed hunks, not the complete file."
                )
        )
    }

    @Test func trackedMarkdownUsesCompletePreviewContentFromHost() {
        let file = ProjectGitFileChange(
            path: "README.md",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary,
            insertions: 1,
            deletions: 1,
            isBinary: false
        )
        let content = "# Full document\n\nUpdated **content**."
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .worktree,
            availability: .available,
            offset: 0,
            lines: [],
            nextOffset: nil,
            previewContent: content
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .content(content)
        )
    }

    @Test func trackedPlainTextUsesCompletePreviewContentFromHost() {
        let file = ProjectGitFileChange(
            path: "notes.TXT",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary,
            insertions: 1,
            deletions: 1,
            isBinary: false
        )
        let content = "Complete plain-text document\nwith another line."
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .worktree,
            availability: .available,
            offset: 0,
            lines: [],
            nextOffset: nil,
            previewContent: content
        )

        #expect(ProjectChangesMarkdownPreviewBuilder.isPreviewableText(path: file.path))
        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .content(content)
        )
    }

    @Test func fullyLoadedAddedMarkdownReconstructsTheSelectedStagedSide() {
        let file = ProjectGitFileChange(
            path: "GUIDE.MD",
            originalPath: nil,
            indexStatus: "A",
            worktreeStatus: ".",
            kind: .ordinary,
            insertions: 2,
            deletions: 0,
            isBinary: false
        )
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .staged,
            availability: .available,
            offset: 0,
            lines: [
                .init(offset: 0, kind: .header, oldLine: nil, newLine: nil, content: "@@ -0,0 +1,2 @@"),
                .init(offset: 1, kind: .addition, oldLine: nil, newLine: 1, content: "# Guide"),
                .init(offset: 2, kind: .addition, oldLine: nil, newLine: 2, content: "Read **this**."),
            ],
            nextOffset: nil
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .content("# Guide\nRead **this**.")
        )
    }

    @Test func binaryMarkdownDiffNamesWhyPreviewIsUnavailable() {
        let file = ProjectGitFileChange(
            path: "image-notes.md",
            originalPath: nil,
            indexStatus: "?",
            worktreeStatus: "?",
            kind: .untracked,
            insertions: 0,
            deletions: 0,
            isBinary: true
        )
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .worktree,
            availability: .binary,
            offset: 0,
            lines: [],
            nextOffset: nil
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .unavailable("Binary Markdown files cannot be previewed.")
        )
    }

    @Test func oversizedMarkdownDiffNamesWhyPreviewIsUnavailable() {
        let file = ProjectGitFileChange(
            path: "large.md",
            originalPath: nil,
            indexStatus: "A",
            worktreeStatus: ".",
            kind: .ordinary,
            insertions: 10_001,
            deletions: 0,
            isBinary: false
        )
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .staged,
            availability: .oversized,
            offset: 0,
            lines: [],
            nextOffset: nil
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .unavailable("This Markdown diff is too large to preview safely.")
        )
    }

    @Test func nonMarkdownPathsNeverExposeAReconstructedPreview() {
        let file = ProjectGitFileChange(
            path: "Source.swift",
            originalPath: nil,
            indexStatus: "?",
            worktreeStatus: "?",
            kind: .untracked,
            insertions: 1,
            deletions: 0,
            isBinary: false
        )
        let diff = ProjectGitDiffPage(
            path: file.path,
            side: .worktree,
            availability: .available,
            offset: 0,
            lines: [
                .init(offset: 0, kind: .addition, oldLine: nil, newLine: 1, content: "let value = true"),
            ],
            nextOffset: nil
        )

        #expect(
            ProjectChangesMarkdownPreviewBuilder.preview(for: diff, file: file)
                == .unavailable("Preview is available only for Markdown and plain-text files.")
        )
    }
}
