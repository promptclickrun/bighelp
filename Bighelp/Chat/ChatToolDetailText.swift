import SwiftUI
import UIKit

enum ChatToolDetailFormatter {
    nonisolated static func format(_ value: String) -> String {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
            let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: formatted, encoding: .utf8)
        else { return value }
        return text
    }
}

/// Bound inline text measurement independently of the retained tool result.
/// Complete content remains available to copying and the dedicated reader.
struct ChatToolDetailPreview: Sendable {
    let text: String
    let isTruncated: Bool

    nonisolated init(_ value: String) {
        // Do not parse/pretty-print an arbitrarily large result in a cell body.
        let source = value.utf8.count <= 4_096 ? ChatToolDetailFormatter.format(value) : value
        var scalars = String.UnicodeScalarView()
        var lines = 1
        var consumed = 0
        for scalar in source.unicodeScalars {
            guard consumed < 2_048, scalar != "\n" || lines < 16 else { break }
            scalars.append(scalar)
            consumed += 1
            if scalar == "\n" { lines += 1 }
        }
        text = String(scalars)
        isTruncated = text.utf8.count < source.utf8.count
    }

    nonisolated static func pages(_ value: String, isCancelled: () -> Bool = { false }) -> [String] {
        guard !isCancelled() else { return [] }
        var result: [String] = []
        var page = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars {
            if count == 4_096 {
                guard !isCancelled() else { return [] }
                result.append(String(page))
                page = String.UnicodeScalarView()
                count = 0
            }
            page.append(scalar)
            count += 1
        }
        if !page.isEmpty { result.append(String(page)) }
        return result
    }
}

struct ChatToolDetailText: View {
    let label: String
    let value: String
    let identifier: String
    var isCanonicalPreview = false
    @State private var showsCompleteValue = false

    var body: some View {
        let preview = ChatToolDetailPreview(value)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text(preview.text)
                .font(.bighelp(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
            if preview.isTruncated && !isCanonicalPreview {
                Button("View full \(label.lowercased())") { showsCompleteValue = true }
                    .font(.bighelp(.caption))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifier + ".view-full")
            }
        }
        .bighelpSheet(isPresented: $showsCompleteValue) {
            if !isCanonicalPreview {
                ChatToolDetailReader(label: label, value: value)
            }
        }
        .onChange(of: isCanonicalPreview) { _, isPreview in
            if isPreview { showsCompleteValue = false }
        }
    }
}

/// One section of an unfolded tool call (its input or result), readable:
/// key facts as label and value, text with real line breaks, long text cut
/// short with "View full". JSON that can't be made readable, plain text and
/// Hermes' canonical previews show as before. The raw value stays one tap
/// away and is what the section's Copy button copies.
struct ChatToolReadableSection: View {
    let label: String
    let value: String
    let identifier: String
    var isCanonicalPreview = false
    @State private var showsRawValue = false
    @BighelpThemeReader private var theme

    var body: some View {
        if !isCanonicalPreview, let detail = ChatToolReadableDetail.parse(value) {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                ForEach(Array(detail.items.enumerated()), id: \.offset) { index, item in
                    switch item {
                    case .fact(let factLabel, let factValue):
                        fact(factLabel, factValue)
                    case .block(let blockLabel, let text):
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            if let blockLabel {
                                Text(blockLabel)
                                    .font(.bighelp(.caption, weight: .semibold))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                            ChatToolDetailText(label: blockLabel ?? label, value: text,
                                               identifier: "\(identifier).item-\(index)")
                        }
                    }
                }
                Button("View raw \(label.lowercased())") { showsRawValue = true }
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.tertiaryText)
                    .bighelpPlainButtonStyle()
                    .accessibilityIdentifier(identifier + ".view-raw")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bighelpSheet(isPresented: $showsRawValue) {
                ChatToolDetailReader(label: label, value: value)
                    .bighelpSheetSize(.large)
            }
        } else {
            ChatToolDetailText(label: label, value: value, identifier: identifier,
                               isCanonicalPreview: isCanonicalPreview)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
            Text(label)
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize()
            Text(value)
                .font(.bighelp(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChatToolDetailReader: View {
    let label: String
    let value: String
    @State private var pages: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        Text(pages[index])
                            .font(.bighelp(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .overlay { if pages.isEmpty { ProgressView() } }
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.bighelpToolbarText() }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy all", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = value
                        BighelpHaptics.success()
                    }
                }
            }
        }
        .task(id: value) {
            let source = value
            let task = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return [String]() }
                let formatted = ChatToolDetailFormatter.format(source)
                return ChatToolDetailPreview.pages(formatted, isCancelled: { Task.isCancelled })
            }
            let prepared = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            pages = prepared
        }
    }
}
