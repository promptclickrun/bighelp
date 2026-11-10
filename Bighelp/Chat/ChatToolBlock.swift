import SwiftUI
import UIKit

/// An unfolded tool call as one block (#943): what the agent asked for on top, what came back under a
/// line. Short values share one line ("notes.md · Limit 200") and text keeps its line breaks, so
/// nothing reads as JSON. Hermes' own input and result stay one tap away (Show raw).
struct ChatToolBlock: Equatable, Sendable {
    /// Text with line breaks: a file's new contents, what a tool printed.
    struct Passage: Equatable, Sendable {
        /// Named only when its half holds more than one ("Old string", "New string").
        let label: String?
        let text: String
    }

    /// One half of the block.
    struct Part: Equatable, Sendable {
        /// The short values, on one line.
        var line: String?
        var passages: [Passage] = []

        var isEmpty: Bool { line == nil && passages.isEmpty }

        fileprivate var readable: [String] {
            ([line].compactMap { $0 }) + passages.map { passage in
                passage.label.map { "\($0)\n\(passage.text)" } ?? passage.text
            }
        }
    }

    let ask: Part
    let answer: Part

    var isEmpty: Bool { ask.isEmpty && answer.isEmpty }

    /// The block as it reads, whole, for Copy.
    var copyText: String {
        [ask.readable, answer.readable].filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// `showsCodeCell`: the call's code and output are a notebook cell (`ChatToolCodeCell`), so the
    /// block keeps only what the cell doesn't show.
    init(event: ChatActivityEvent, showsCodeCell: Bool = false) {
        ask = showsCodeCell ? Part() : Self.part(event.arguments, isAsk: true)
        var answer = showsCodeCell ? Part() : Self.part(event.result, isAsk: false)
        var lines = [answer.line].compactMap { $0 }
        // Hermes' own words about the call, where they add to its result.
        let summary = Self.trimmed(event.summary)
        let detail = Self.trimmed(event.detail).flatMap { $0 == summary || $0 == Self.trimmed(event.result) ? nil : $0 }
        for (label, note) in [("Summary", summary), ("Details", detail)] {
            guard let note, note != Self.trimmed(event.result) else { continue }
            if note.count <= ChatToolReadableDetail.inlineLength, !note.contains(where: \.isNewline) {
                lines.insert(note, at: label == "Summary" ? 0 : lines.count)
            } else {
                answer.passages.append(Passage(label: label, text: note))
            }
        }
        answer.line = lines.isEmpty ? nil : lines.joined(separator: " · ")
        self.answer = Self.unnamingALonePassage(answer)
    }

    /// A value that says what it is by itself: its name would only be noise.
    private static let plainLabels: Set<String> = [
        "Path", "File path", "Filename", "File", "URL", "URLs", "Query", "Pattern", "Name", "Title",
    ]

    private static func part(_ raw: String?, isAsk: Bool) -> Part {
        guard let raw = trimmed(raw) else { return Part() }
        // Text that isn't JSON is already readable.
        guard let detail = ChatToolReadableDetail.parse(raw) else {
            return Part(passages: [Passage(label: nil, text: raw)])
        }
        var facts: [String] = []
        var part = Part()
        for item in detail.items {
            switch item {
            case .fact(let label, let value):
                // What the call was about leads its line without a name: "notes.md · Limit 200".
                facts.append(isAsk && facts.isEmpty && plainLabels.contains(label) ? value : "\(label) \(value)")
            case .block(let label, let text):
                part.passages.append(Passage(label: label, text: text))
            }
        }
        part.line = facts.isEmpty ? nil : facts.joined(separator: " · ")
        return unnamingALonePassage(part)
    }

    private static func unnamingALonePassage(_ part: Part) -> Part {
        guard part.passages.count == 1, let passage = part.passages.first else { return part }
        return Part(line: part.line, passages: [Passage(label: nil, text: passage.text)])
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Draws a `ChatToolBlock`: the request, a hairline, the answer on a lighter ground, then Copy and
/// Show raw. Long text is cut short with "View full" (`ChatToolDetailText`).
struct ChatToolBlockView: View {
    let block: ChatToolBlock
    let event: ChatActivityEvent
    /// The step's own identifier ("chat.activity.<event>"); the block's parts add to it.
    let identifier: String
    /// The call has a notebook cell above, which carries the raw data itself.
    var showsActions = true

    @State private var rawSection: RawSection?
    @BighelpThemeReader private var theme

    /// Hermes keeps the complete content; what's here is its preview, shown as it came.
    private var isCanonicalPreview: Bool { event.contentReference != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !block.ask.isEmpty {
                    part(block.ask, named: "ask", lineColor: theme.primaryText)
                        .padding(BighelpTokens.space12)
                }
                if !block.ask.isEmpty, !block.answer.isEmpty {
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: BighelpTokens.hairline)
                }
                if !block.answer.isEmpty {
                    part(block.answer, named: "answer", lineColor: theme.tertiaryText)
                        .padding(BighelpTokens.space12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.canvas.opacity(0.55))
                }
            }
            .background(theme.primaryText.opacity(0.05))
            .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
            }
            if showsActions, !isCanonicalPreview { actions }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier + ".block")
        .bighelpSheet(item: $rawSection) { section in
            ChatToolDetailReader(label: section.label, value: section.value)
                .bighelpSheetSize(.large)
        }
    }

    private func part(_ part: ChatToolBlock.Part, named name: String, lineColor: Color) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if let line = part.line {
                Text(line)
                    .font(.bighelp(.caption, design: .monospaced))
                    .foregroundStyle(lineColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).\(name).line")
            }
            ForEach(Array(part.passages.enumerated()), id: \.offset) { index, passage in
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    if let label = passage.label {
                        Text(label)
                            .font(.bighelp(.caption, weight: .semibold))
                            .foregroundStyle(theme.tertiaryText)
                    }
                    ChatToolDetailText(label: passage.label ?? (name == "ask" ? "Input" : "Result"),
                                       value: passage.text, identifier: "\(identifier).\(name).text-\(index)",
                                       isCanonicalPreview: isCanonicalPreview)
                        .foregroundStyle(theme.primaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: BighelpTokens.space16) {
            Button("Copy") {
                UIPasteboard.general.string = block.copyText
                BighelpHaptics.success()
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier(identifier + ".copy")
            if event.arguments != nil || event.result != nil {
                Menu {
                    if let arguments = event.arguments {
                        Button("Input") { rawSection = RawSection(label: "Input", value: arguments) }
                    }
                    if let result = event.result {
                        Button("Result") { rawSection = RawSection(label: "Result", value: result) }
                    }
                } label: {
                    Text("Show raw")
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier(identifier + ".view-raw")
            }
            Spacer(minLength: 0)
        }
        .font(.bighelp(.caption, weight: .semibold))
        .foregroundStyle(theme.secondaryText)
        .frame(minHeight: BighelpTokens.hitTarget)
        .padding(.leading, BighelpTokens.space4)
    }

    private struct RawSection: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }
}
