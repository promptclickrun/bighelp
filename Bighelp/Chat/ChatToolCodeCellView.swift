import SwiftUI
import UIKit

/// An unfolded code tool call as one notebook cell (`ChatToolCodeCell`, #926):
/// the code with line numbers and colors, folded after 10 lines, then its
/// output under a line in the same card. Copy takes the clean code or output;
/// View raw keeps Hermes' own input and result one tap away.
struct ChatToolCodeCellView: View {
    let cell: ChatToolCodeCell
    let event: ChatActivityEvent
    let identifier: String
    let onDisclosureChange: () -> Void

    @State private var showsAllLines = false
    @State private var showsReader = false
    @State private var rawSection: RawSection?
    @BighelpThemeReader private var theme

    static let foldedLineCount = 10
    /// Longer code opens in the reader instead of growing the chat row.
    static let inlineLineLimit = 200

    private var isFoldable: Bool { cell.lines.count > Self.foldedLineCount }
    private var isFolded: Bool { isFoldable && !showsAllLines }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            VStack(alignment: .leading, spacing: 0) {
                codeHeader
                ChatCodeLinesView(lines: isFolded ? Array(cell.lines.prefix(Self.foldedLineCount)) : cell.lines,
                                  lastNumber: cell.lines.count)
                    .padding(.horizontal, BighelpTokens.space12)
                    .padding(.bottom, isFoldable ? 0 : BighelpTokens.space12)
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            if isFolded {
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: BighelpTokens.space32)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(cell.language.rawValue) code, "
                        + (cell.lines.count == 1 ? "1 line" : "\(cell.lines.count) lines"))
                    .accessibilityValue(isFolded ? cell.lines.prefix(Self.foldedLineCount).map(\.text)
                        .joined(separator: "\n") : cell.code)
                    .accessibilityIdentifier(identifier + ".code")
                if isFoldable { showAllButton }
                Rectangle()
                    .fill(theme.border)
                    .frame(height: BighelpTokens.hairline)
                outputSection
                    .background(theme.canvas.opacity(0.55))
            }
            .background(theme.primaryText.opacity(0.05))
            .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
            }
            .bighelpSheet(isPresented: $showsReader) {
                ChatToolCodeReader(cell: cell)
                    .bighelpSheetSize(.large)
            }
            rawMenu
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .bighelpSheet(item: $rawSection) { section in
            ChatToolDetailReader(label: section.label, value: section.value)
                .bighelpSheetSize(.large)
        }
    }

    private var codeHeader: some View {
        HStack(spacing: 0) {
            Text(cell.language.rawValue)
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: BighelpTokens.space8)
            iconButton("doc.on.doc", label: "Copy code", id: ".copy-code") { copy(cell.code) }
            iconButton("arrow.up.left.and.arrow.down.right", label: "Open full screen", id: ".open") {
                showsReader = true
            }
        }
        .padding(.leading, BighelpTokens.space12)
    }

    private var showAllButton: some View {
        Button {
            onDisclosureChange()
            if cell.lines.count > Self.inlineLineLimit { showsReader = true } else { showsAllLines.toggle() }
        } label: {
            Text(showsAllLines ? "Show less" : "Show all \(cell.lines.count) lines")
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, BighelpTokens.space4)
                .background(theme.raisedSurface, in: .capsule)
                .overlay { Capsule().stroke(theme.border, lineWidth: BighelpTokens.hairline) }
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier(identifier + ".show-all")
    }

    private var outputSection: some View {
        // The header's 44-point Copy button already spaces it from the output.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BighelpTokens.space8) {
                outcome
                Spacer(minLength: BighelpTokens.space8)
                if let output = cell.output {
                    iconButton("doc.on.doc", label: "Copy output", id: ".copy-output") { copy(output) }
                }
            }
            .padding(.leading, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.scaled(36))
            if let output = cell.output {
                ChatToolDetailText(label: "Output", value: output, identifier: identifier + ".output")
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space12)
            }
            if let error = cell.error {
                ChatToolDetailText(label: "Error", value: error, identifier: identifier + ".error")
                    .foregroundStyle(theme.danger)
                    .padding(.horizontal, BighelpTokens.space12)
                    .padding(.top, cell.output == nil ? 0 : BighelpTokens.space8)
            }
            if cell.output == nil, cell.error == nil, cell.ending != .running {
                Text("No output")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.horizontal, BighelpTokens.space12)
            }
        }
        .padding(.bottom, BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How the run ended, in the words and color the step line uses.
    @ViewBuilder
    private var outcome: some View {
        let (words, color): (String, Color?) = switch cell.ending {
        case .running: ("Running…", nil)
        case .succeeded: ("Output", theme.success)
        case .failed: (cell.exitCode.map { $0 == 0 ? "Failed" : "Exit code \($0)" } ?? "Failed", theme.danger)
        case .stopped: ("Stopped", theme.tertiaryText)
        }
        HStack(spacing: BighelpTokens.space4 + 2) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(words)
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(cell.ending == .running ? theme.tertiaryText : theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier + ".outcome")
    }

    private var rawMenu: some View {
        Menu {
            if let arguments = event.arguments {
                Button("Input") { rawSection = RawSection(label: "Input", value: arguments) }
            }
            if let result = event.result {
                Button("Result") { rawSection = RawSection(label: "Result", value: result) }
            }
        } label: {
            Text("View raw")
                .font(.bighelp(.caption))
                .foregroundStyle(theme.tertiaryText)
                .frame(minHeight: BighelpTokens.scaled(32))
                .contentShape(.rect)
        }
        .accessibilityIdentifier(identifier + ".view-raw")
    }

    private func iconButton(_ systemImage: String, label: String, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier + id)
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        BighelpHaptics.success()
    }

    private struct RawSection: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }
}

/// Lines of code beside their numbers; a wrapped line stays beside its number.
struct ChatCodeLinesView: View {
    let lines: [ChatCodeLine]
    /// The cell's last line number, so every number column is as wide.
    let lastNumber: Int
    var isLazy = false
    @BighelpThemeReader private var theme

    var body: some View {
        Group {
            if isLazy {
                LazyVStack(alignment: .leading, spacing: 2) { rows }
            } else {
                VStack(alignment: .leading, spacing: 2) { rows }
            }
        }
        .font(.bighelp(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private var rows: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                ZStack(alignment: .trailing) {
                    Text(String(lastNumber)).hidden()
                    Text(String(offset + 1))
                }
                .foregroundStyle(theme.tertiaryText)
                .accessibilityHidden(true)
                Text(attributed(line))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func attributed(_ line: ChatCodeLine) -> AttributedString {
        // An empty Text has no baseline, which doubles a blank line's height.
        guard !line.runs.isEmpty else { return AttributedString(" ") }
        var result = AttributedString()
        for run in line.runs {
            var part = AttributedString(run.text)
            part.foregroundColor = color(run.token)
            if run.token == .comment { part.inlinePresentationIntent = .emphasized }
            result.append(part)
        }
        return result
    }

    /// One set of syntax colors for light themes and one for dark, each
    /// readable on the cell's tint over that theme's canvas.
    private func color(_ token: ChatCodeToken?) -> Color {
        let dark = theme.isDarkPalette
        return switch token {
        case .keyword: Color(hex: dark ? "FF8FA8" : "B4235A")
        case .string: Color(hex: dark ? "9FD8A9" : "2F7A4A")
        case .number: Color(hex: dark ? "C9B6FF" : "6B45D1")
        case .call: Color(hex: dark ? "8DC2FF" : "2563A8")
        case .comment: theme.tertiaryText
        case nil: theme.primaryText
        }
    }
}

/// The whole cell full screen: every line of the code, then its output.
struct ChatToolCodeReader: View {
    let cell: ChatToolCodeCell
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    ChatCodeLinesView(lines: cell.lines, lastNumber: cell.lines.count, isLazy: true)
                    if cell.output != nil || cell.error != nil {
                        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                            Text("Output")
                                .font(.bighelp(.caption, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                            if let output = cell.output {
                                ChatToolDetailText(label: "Output", value: output, identifier: "chat.code-reader.output")
                                    .foregroundStyle(theme.primaryText)
                            }
                            if let error = cell.error {
                                ChatToolDetailText(label: "Error", value: error, identifier: "chat.code-reader.error")
                                    .foregroundStyle(theme.danger)
                            }
                        }
                        .padding(.top, BighelpTokens.space12)
                        .overlay(alignment: .top) {
                            Rectangle().fill(theme.border).frame(height: BighelpTokens.hairline)
                        }
                    }
                }
                .padding()
            }
            .background(theme.canvas)
            .navigationTitle(cell.language.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.bighelpToolbarText() }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Copy code") { copy(cell.code) }
                        if let output = cell.output {
                            Button("Copy output") { copy(output) }
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("chat.code-reader.copy")
                }
            }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        BighelpHaptics.success()
    }
}
