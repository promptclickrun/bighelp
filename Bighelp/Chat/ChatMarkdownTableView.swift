import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A Markdown pipe table in a chat: a header row and rows of cells that wrap
/// at a readable width. A table wider than the bubble scrolls sideways.
/// Double-tap a cell to select its words; the button at the top right copies
/// the whole table.
struct ChatMarkdownTableView: View {
    let table: MarkdownTable
    var textColor: Color?

    @BighelpThemeReader private var theme: BighelpTheme
    @Environment(\.openURL) private var openURL
    @State private var copiedAt: Date?

    /// Cells wrap here instead of growing into one long line.
    static let maximumColumnWidth: CGFloat = 220

    var body: some View {
        // The copy button sits just above the table's top right, so it never
        // covers a column name when a wide table scrolls under it.
        VStack(alignment: .trailing, spacing: BighelpTokens.space4) {
            copyButton
            grid
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.markdown-table")
    }

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ChatTableLayout(columns: table.header.count, maximumColumnWidth: Self.maximumColumnWidth) {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, isHeader: true, isLastRow: table.rows.isEmpty)
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, isHeader: false,
                             isLastRow: row == table.rows.count - 1)
                            .accessibilityLabel(cellLabel(row: table.rows[row], column: column))
                    }
                }
            }
            .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
            }
            // The stroke sits half outside the table; keep it from being clipped.
            .padding(BighelpTokens.hairline)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var copyButton: some View {
        Button {
            ChatTableCopy.copy(table)
            BighelpHaptics.success()
            UIAccessibility.post(notification: .announcement, argument: "Table copied")
            let now = Date.now
            withAnimation(.snappy) { copiedAt = now }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if copiedAt == now { withAnimation(.snappy) { copiedAt = nil } }
            }
        } label: {
            Image(systemName: copiedAt == nil ? "doc.on.doc" : "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(copiedAt == nil ? theme.secondaryText : theme.action)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(theme.primaryText.opacity(0.06), in: .circle)
                // A comfortable target around the small icon, without adding height.
                .frame(width: 44, height: 26)
                .contentShape(.rect.inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copiedAt == nil ? "Copy table" : "Table copied")
        .accessibilityIdentifier("chat.markdown-table.copy")
    }

    private func cell(_ markdown: String, column: Int, isHeader: Bool, isLastRow: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return ChatTableCellText(
            markdown: markdown, isHeader: isHeader, alignment: nativeAlignment(alignment),
            textColor: textColor ?? theme.primaryText, theme: theme, openURL: openURL
        )
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space8)
            // The layout sizes every cell to its column and row; fill it so the
            // header shading and row lines have no gaps.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(alignment))
            .background(isHeader ? theme.primaryText.opacity(0.06) : .clear)
            .overlay(alignment: .bottom) {
                if !isLastRow {
                    Rectangle().fill(theme.border).frame(height: BighelpTokens.hairline)
                }
            }
            .accessibilityAddTraits(isHeader ? .isHeader : [])
    }

    /// "Total: $270" reads better than the bare value.
    private func cellLabel(row: [String], column: Int) -> String {
        let value = MarkdownDocument(row[column]).visiblePlainText
        let name = table.header.indices.contains(column)
            ? MarkdownDocument(table.header[column]).visiblePlainText : ""
        return name.isEmpty ? value : "\(name): \(value)"
    }

    private func nativeAlignment(_ alignment: MarkdownTable.Alignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    private func frameAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// One cell as native text, like the rest of the message: double-tap selects
/// a word, drag the handles for more, and Copy is in the menu.
struct ChatTableCellText: UIViewRepresentable {
    let markdown: String
    let isHeader: Bool
    let alignment: NSTextAlignment
    let textColor: Color
    let theme: BighelpTheme
    let openURL: OpenURLAction

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeUIView(context: Context) -> UITextView {
        let view = ChatMentionTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.isOpaque = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.adjustsFontForContentSizeCategory = true
        view.setContentHuggingPriority(.required, for: .vertical)
        view.accessibilityIdentifier = "chat.markdown-table.cell"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        view.tintColor = UIColor(theme.action)
        view.linkTextAttributes = [.foregroundColor: UIColor(theme.action),
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        let text = ChatNativeMarkdownAttributedBuilder.tableCell(markdown, isHeader: isHeader, alignment: alignment, style: .init(
            primaryText: UIColor(textColor), secondaryText: UIColor(theme.secondaryText),
            accent: UIColor(theme.action), codeBackground: UIColor(theme.primaryText.opacity(0.07)),
            proseLineSpacing: 0, traitCollection: view.traitCollection, theme: theme))
        view.accessibilityLabel = ChatMentionRendering.plainText(text, usingNames: true)
        if view.attributedText?.isEqual(to: text) != true {
            view.attributedText = text
            view.invalidateIntrinsicContentSize()
        }
    }

    /// Unwrapped width when asked for its ideal size, so columns fit their text.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .greatestFiniteMagnitude
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: ceil(min(size.width, width)), height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction

        init(openURL: OpenURLAction) { self.openURL = openURL }

        /// Links open in the browser chosen in Settings, like the rest of the chat.
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [openURL] _ in openURL(url) }
        }
    }
}

/// The whole table on the clipboard: a Markdown table for Messages and Notes,
/// tab-separated text for Numbers and Sheets, and an HTML table for Mail.
enum ChatTableCopy {
    static func copy(_ table: MarkdownTable) {
        UIPasteboard.general.setItems([[
            UTType.plainText.identifier: markdown(table),
            UTType.tabSeparatedText.identifier: tabSeparated(table),
            UTType.html.identifier: html(table),
        ]])
    }

    static func markdown(_ table: MarkdownTable) -> String {
        func row(_ cells: [String]) -> String {
            "| " + cells.map { plain($0).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        let rule = "|" + table.header.indices.map { column in
            switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
            case .leading: " --- "
            case .center: " :---: "
            case .trailing: " ---: "
            }
        }.joined(separator: "|") + "|"
        return ([row(table.header), rule] + table.rows.map(row)).joined(separator: "\n")
    }

    static func tabSeparated(_ table: MarkdownTable) -> String {
        ([table.header] + table.rows).map { cells in
            cells.map { plain($0).replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func html(_ table: MarkdownTable) -> String {
        func escaped(_ text: String) -> String {
            plain(text).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let head = "<tr>" + table.header.map { "<th>\(escaped($0))</th>" }.joined() + "</tr>"
        let body = table.rows.map { "<tr>" + $0.map { "<td>\(escaped($0))</td>" }.joined() + "</tr>" }.joined()
        return "<table><thead>\(head)</thead><tbody>\(body)</tbody></table>"
    }

    /// A cell's words without Markdown marks.
    private static func plain(_ markdown: String) -> String {
        MarkdownDocument(markdown).visiblePlainText.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Cells in row order. Each column is as wide as its widest cell (capped, so
/// long text wraps), and each row as tall as its tallest cell at those widths.
/// (Grid measures a wrapping cell's height before its width is capped, so
/// wrapped rows came out too short.)
struct ChatTableLayout: Layout {
    let columns: Int
    let maximumColumnWidth: CGFloat

    struct Measurement {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Measurement {
        guard columns > 0 else { return Measurement(widths: [], heights: []) }
        var widths = Array(repeating: CGFloat.zero, count: columns)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            widths[index % columns] = max(widths[index % columns], min(ideal, maximumColumnWidth))
        }
        widths = widths.map { $0.rounded(.up) }
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            var height = CGFloat.zero
            for column in 0..<columns where start + column < subviews.count {
                let size = subviews[start + column].sizeThatFits(ProposedViewSize(width: widths[column], height: nil))
                height = max(height, size.height)
            }
            heights.append(height.rounded(.up))
        }
        return Measurement(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurement) -> CGSize {
        CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measurement) {
        guard columns > 0 else { return }
        var y = bounds.minY
        for (row, height) in cache.heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: cache.widths[column], height: height))
                x += cache.widths[column]
            }
            y += height
        }
    }
}

/// A Markdown thematic break (`---`).
struct ChatMarkdownRuleView: View {
    @BighelpThemeReader private var theme: BighelpTheme

    var body: some View {
        Rectangle()
            .fill(theme.border)
            .frame(maxWidth: .infinity)
            .frame(height: BighelpTokens.hairline)
            .padding(.vertical, BighelpTokens.space4)
            .accessibilityHidden(true)
    }
}
