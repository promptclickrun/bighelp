import SwiftUI
import UIKit

@MainActor
struct ChatNativeMarkdownStyle {
    let primaryText: UIColor
    let secondaryText: UIColor
    let accent: UIColor
    let codeBackground: UIColor
    let proseLineSpacing: CGFloat
    let traitCollection: UITraitCollection
    var theme: BighelpTheme = .light
    /// Interim agent messages render slightly smaller than the answer.
    var textScale: CGFloat = 1
    var mentionIdentities: [ChatMentionIdentity] = []
}

/// One rendered revision per native text view. The cache never crosses a
/// message/view lifetime and invalidates for text, theme and accessibility traits.
@MainActor
final class ChatNativeMarkdownRenderCache {
    private struct StyleKey: Equatable {
        let lineSpacing: CGFloat
        let textScale: CGFloat
        let fontSizes: [CGFloat]
        let typeface: BighelpThemeTypeface
        let typography: BighelpThemeTypography
        let colors: [CGColor]
        let mentionIdentities: [ChatMentionIdentity]

        init(_ style: ChatNativeMarkdownStyle) {
            mentionIdentities = style.mentionIdentities
            lineSpacing = style.proseLineSpacing
            textScale = style.textScale
            typeface = style.theme.typeface
            typography = style.theme.typography
            // These are the text styles used by the attributed builder below.
            // SwiftUI also changes unrelated custom UIKit traits on updates.
            fontSizes = [UIFont.TextStyle.title2, .title3, .headline, .body,
                         .subheadline, .caption1, .callout].map {
                UIFontDescriptor.preferredFontDescriptor(
                    withTextStyle: $0, compatibleWith: style.traitCollection).pointSize
            }
            colors = [style.primaryText, style.secondaryText, style.accent,
                      style.codeBackground].map {
                $0.resolvedColor(with: style.traitCollection).cgColor
            }
        }
    }

    private var document: MarkdownDocument?
    private var styleKey: StyleKey?
    private var rendered: NSAttributedString?
    private var measurements: [(width: CGFloat, size: CGSize)] = []

    func measure(width: CGFloat, using measurement: (CGFloat) -> CGSize) -> CGSize {
        guard rendered != nil, width.isFinite, width > 0 else { return measurement(width) }
        if let cached = measurements.first(where: { $0.width == width }) {
            return cached.size
        }
        let size = measurement(width)
        guard size.width.isFinite, size.height.isFinite else { return size }
        // SwiftUI asks again during placement and may alternate width proposals.
        // Keep only a few sizes for this view's current text/style revision.
        if measurements.count == 4 { measurements.removeFirst() }
        measurements.append((width, size))
        return size
    }

    func render(document: MarkdownDocument, style: ChatNativeMarkdownStyle) -> NSAttributedString {
        let key = StyleKey(style)
        if self.document == document, styleKey == key,
           let rendered {
            return rendered
        }
        let updated = NSMutableAttributedString(attributedString:
            ChatNativeMarkdownAttributedBuilder.build(document: document, style: style))
        if styleKey == key, let previous = rendered {
            ChatMentionRendering.reuseAttachments(in: updated, from: previous)
        }
        let rendered = NSAttributedString(attributedString: updated)
        self.document = document
        self.styleKey = key
        self.rendered = rendered
        measurements.removeAll(keepingCapacity: true)
        return rendered
    }
}

@MainActor
enum ChatNativeMarkdownAttributedBuilder {
    static func build(
        document: MarkdownDocument,
        style: ChatNativeMarkdownStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")

        for (index, block) in document.blocks.enumerated() {
            let spacingAfter = spacing(afterBlockAt: index, in: document)
            append(block, spacingAfter: spacingAfter, style: style, to: result)
            if index < document.blocks.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        return result
    }

    private static func spacing(afterBlockAt index: Int, in document: MarkdownDocument) -> CGFloat {
        guard index < document.blocks.count - 1 else { return 0 }
        return ChatMarkdownLayoutPolicy.spacing(
            after: document.blocks[index],
            before: document.blocks[index + 1]
        )
    }

    private static func append(
        _ block: MarkdownBlock,
        spacingAfter: CGFloat,
        style: ChatNativeMarkdownStyle,
        to result: NSMutableAttributedString
    ) {
        switch block {
        case .heading(let level, let markdown):
            result.append(inline(
                markdown,
                role: ChatMarkdownTypography.headingRole(for: level),
                textColor: style.primaryText,
                paragraphStyle: paragraphStyle(spacingAfter: spacingAfter, style: style),
                style: style
            ))
        case .paragraph(let markdown):
            result.append(inline(
                markdown,
                role: .body,
                textColor: style.primaryText,
                paragraphStyle: paragraphStyle(spacingAfter: spacingAfter, style: style),
                style: style
            ))
        case .unorderedList(let items):
            let tasks = items.map(MarkdownTaskItem.split)
            appendList(
                items: tasks.map(\.text),
                markers: tasks.map { $0.done.map(MarkdownTaskItem.marker(done:)) ?? "•" },
                markerWidth: ChatMarkdownLayoutPolicy.unorderedMarkerWidth,
                spacingAfter: spacingAfter,
                style: style,
                to: result
            )
        case .orderedList(let start, let items):
            appendList(
                items: items,
                markers: items.indices.map { "\(start + $0)." },
                markerWidth: ChatMarkdownLayoutPolicy.orderedMarkerWidth,
                spacingAfter: spacingAfter,
                style: style,
                to: result
            )
        case .quote(let markdown):
            let paragraph = paragraphStyle(
                spacingAfter: spacingAfter,
                headIndent: ChatMarkdownLayoutPolicy.unorderedMarkerWidth + BighelpTokens.space8,
                style: style
            )
            let marker = NSAttributedString(
                string: "▏\t",
                attributes: attributes(
                    font: font(role: .body, style: style),
                    textColor: style.accent,
                    paragraphStyle: paragraph
                )
            )
            result.append(marker)
            result.append(inline(
                markdown,
                role: .body,
                textColor: style.secondaryText,
                paragraphStyle: paragraph,
                forceItalic: true,
                style: style
            ))
        case .code(let language, let text):
            if let language {
                let languageParagraph = paragraphStyle(
                    spacingAfter: BighelpTokens.space4,
                    style: style
                )
                result.append(NSAttributedString(
                    string: language.uppercased(),
                    attributes: attributes(
                        font: font(role: .metadata, strong: true, style: style),
                        textColor: style.secondaryText,
                        paragraphStyle: languageParagraph
                    )
                ))
                result.append(NSAttributedString(string: "\n"))
            }
            let codeParagraph = paragraphStyle(spacingAfter: spacingAfter, style: style)
            result.append(NSAttributedString(
                string: text,
                attributes: attributes(
                    font: font(role: .code, style: style),
                    textColor: style.primaryText,
                    paragraphStyle: codeParagraph,
                    backgroundColor: style.codeBackground
                )
            ))
        case .table(let table):
            // Chat bubbles draw tables as their own grid (ChatMarkdownTableView);
            // anywhere else gets one line per row.
            let rows = [table.header] + table.rows
            for (offset, row) in rows.enumerated() {
                let isLast = offset == rows.count - 1
                result.append(inline(
                    row.joined(separator: "  ·  "),
                    role: .body,
                    textColor: offset == 0 ? style.secondaryText : style.primaryText,
                    paragraphStyle: paragraphStyle(
                        spacingAfter: isLast ? spacingAfter : ChatMarkdownLayoutPolicy.listRowSpacing,
                        style: style
                    ),
                    style: style
                ))
                if !isLast { result.append(NSAttributedString(string: "\n")) }
            }
        case .rule:
            result.append(NSAttributedString(
                string: "———",
                attributes: attributes(
                    font: font(role: .body, style: style),
                    textColor: style.secondaryText,
                    paragraphStyle: paragraphStyle(spacingAfter: spacingAfter, style: style)
                )
            ))
        }
    }

    private static func appendList(
        items: [String],
        markers: [String],
        markerWidth: CGFloat,
        spacingAfter: CGFloat,
        style: ChatNativeMarkdownStyle,
        to result: NSMutableAttributedString
    ) {
        let contentIndent = markerWidth + BighelpTokens.space8
        for index in items.indices {
            let isLast = index == items.index(before: items.endIndex)
            let paragraph = paragraphStyle(
                spacingAfter: isLast ? spacingAfter : ChatMarkdownLayoutPolicy.listRowSpacing,
                headIndent: contentIndent,
                style: style
            )
            result.append(NSAttributedString(
                string: "\(markers[index])\t",
                attributes: attributes(
                    font: font(role: .body, style: style),
                    textColor: style.primaryText,
                    paragraphStyle: paragraph
                )
            ))
            result.append(inline(
                items[index],
                role: .body,
                textColor: style.primaryText,
                paragraphStyle: paragraph,
                style: style
            ))
            if !isLast {
                result.append(NSAttributedString(string: "\n"))
            }
        }
    }

    private static func inline(
        _ markdown: String,
        role: BighelpFontRole,
        textColor: UIColor,
        paragraphStyle: NSParagraphStyle,
        forceItalic: Bool = false,
        style: ChatNativeMarkdownStyle
    ) -> NSAttributedString {
        let source = ChatInlineMarkdown.attributedText(markdown)
        let result = NSMutableAttributedString(string: "")

        for run in source.runs {
            let intent = run.inlinePresentationIntent
            let isStrong = intent?.contains(.stronglyEmphasized) == true
            let isItalic = forceItalic || intent?.contains(.emphasized) == true
            let isCode = intent?.contains(.code) == true
            let isStrikethrough = intent?.contains(.strikethrough) == true
            let runText = String(source[run.range].characters)
            var runAttributes = attributes(
                font: font(
                    role: role,
                    strong: isStrong,
                    italic: isItalic,
                    monospaced: isCode,
                    style: style
                ),
                textColor: run.link == nil ? textColor : style.accent,
                paragraphStyle: paragraphStyle,
                backgroundColor: isCode ? style.codeBackground : nil
            )
            if let link = run.link {
                runAttributes[.link] = link
                runAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if isStrikethrough {
                runAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: runText, attributes: runAttributes))
        }

        ChatMentionRendering.apply(to: result, identities: style.mentionIdentities, traits: style.traitCollection)
        return result
    }

    private static func paragraphStyle(
        spacingAfter: CGFloat,
        headIndent: CGFloat = 0,
        style: ChatNativeMarkdownStyle
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.proseLineSpacing
        paragraph.paragraphSpacing = spacingAfter
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = headIndent
        if headIndent > 0 {
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: headIndent)]
            paragraph.defaultTabInterval = headIndent
        }
        return paragraph
    }

    private static func attributes(
        font: UIFont,
        textColor: UIColor,
        paragraphStyle: NSParagraphStyle,
        backgroundColor: UIColor? = nil
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
        if let backgroundColor {
            result[.backgroundColor] = backgroundColor
        }
        return result
    }

    private static func font(
        role: BighelpFontRole,
        strong: Bool = false,
        italic: Bool = false,
        monospaced: Bool = false,
        style: ChatNativeMarkdownStyle
    ) -> UIFont {
        var resolved = style.theme.uiFont(monospaced ? .code : role, compatibleWith: style.traitCollection)
        if strong { resolved = resolved.bighelpApplyingTraits(.traitBold) }
        if italic { resolved = resolved.bighelpApplyingTraits(.traitItalic) }
        if style.textScale != 1 { resolved = resolved.withSize((resolved.pointSize * style.textScale).rounded()) }
        return resolved
    }
}

extension ChatNativeMarkdownAttributedBuilder {
    /// One Markdown table cell, styled like the message text around it.
    static func tableCell(
        _ markdown: String,
        isHeader: Bool,
        alignment: NSTextAlignment,
        style: ChatNativeMarkdownStyle
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let cell = NSMutableAttributedString(attributedString: inline(
            markdown, role: .body, textColor: style.primaryText, paragraphStyle: paragraph, style: style
        ))
        if isHeader {
            cell.enumerateAttribute(.font, in: NSRange(location: 0, length: cell.length)) { value, range, _ in
                guard let font = value as? UIFont else { return }
                cell.addAttribute(.font, value: font.bighelpApplyingTraits(.traitBold), range: range)
            }
        }
        return cell
    }
}
