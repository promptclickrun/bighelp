import SwiftUI
import UIKit

/// One tool call or helper agent inside an unfolded work trail, as a step
/// line hanging from the trail's rail. A tool call unfolds its full details
/// (arguments, result) in place. Each one is its own recycled timeline row.
struct ChatActivityRow: View {
    let event: ChatActivityEvent
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var disclosures
    @State private var localExpanded: Bool?
    @BighelpLoaderScaled(relativeTo: .footnote) private var stepGlyphSide = BighelpActivityMetrics.stepGlyphSide
    private var isExpanded: Bool {
        disclosures?.isExpanded(event) ?? localExpanded ?? false
    }

    var body: some View {
        if event.kind == .reasoning {
            ChatThinkingRow(events: [event], onDisclosureChange: onDisclosureChange)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if event.kind == .tool {
                    Button {
                        onDisclosureChange()
                        let expanded = !isExpanded
                        if let disclosures { disclosures.setExpanded(expanded, for: event) }
                        else { localExpanded = expanded }
                    } label: {
                        HStack(spacing: BighelpTokens.space8) {
                            stepLine
                            Image(systemName: "chevron.right")
                                .font(.bighelp(.caption2, weight: .bold))
                                .foregroundStyle(theme.tertiaryText)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(event.collapsedAccessibilityLabel(status: outcome))
                    .accessibilityValue(ChatActivityDisclosureAccessibility.value(isExpanded: isExpanded))
                    .accessibilityHint(isExpanded ? "Collapses full tool details." : "Expands full tool details.")
                    .accessibilityIdentifier("chat.activity.\(event.eventID)")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        stepLine
                        if let summary = event.collapsedPresentationSummary, !summary.isEmpty {
                            Text(summary)
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, stepGlyphSide + BighelpTokens.space8)
                                .padding(.bottom, BighelpTokens.space4)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(event.collapsedAccessibilityLabel(status: outcome))
                    .accessibilityIdentifier("chat.activity.\(event.eventID)")
                }

                if event.kind == .tool, isExpanded {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        toolDetails
                    }
                    .padding(.leading, stepGlyphSide + BighelpTokens.space8)
                    .padding(.bottom, BighelpTokens.space8)
                }
            }
            .bighelpActivityRail()
        }
    }

    private var stepLine: some View {
        BighelpActivityStepRow(step: ChatActivityPresentation.step(for: event),
                               showsSpinner: event.lifecycle == .running)
    }

    /// Touch needs a full target; the Mac's pointer keeps the stack compact.
    private var minimumHeight: CGFloat {
        BighelpPlatform.isMac ? BighelpTokens.scaled(32) : BighelpTokens.hitTarget
    }

    /// An ending worth hearing; a running or finished step says it in its words.
    private var outcome: String? {
        switch event.lifecycle {
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .running, .succeeded, .recorded: nil
        }
    }

    @ViewBuilder
    private var toolDetails: some View {
        let sections = detailSections
        if let reference = event.contentReference {
            Text("Preview — complete content is stored on Hermes.")
                .font(.bighelp(.caption))
                .foregroundStyle(.secondary)
            BighelpSessionContentDisclosure(sessionID: reference.sessionID, rowID: reference.rowID)
        }
        if sections.isEmpty {
            Text("Hermes did not provide additional details for this call.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                ForEach(sections, id: \.label) { section in
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        HStack {
                            Text(section.label)
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                            Spacer(minLength: BighelpTokens.space8)
                            if event.contentReference == nil {
                                Button {
                                    UIPasteboard.general.string = section.value
                                    BighelpHaptics.success()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .bighelpFont(.metadata)
                                        .foregroundStyle(theme.tertiaryText)
                                        .frame(
                                            minWidth: BighelpTokens.hitTarget,
                                            minHeight: BighelpTokens.hitTarget
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Copy \(section.label.lowercased())")
                            }
                        }
                        ChatToolReadableSection(label: section.label, value: section.value,
                                                identifier: "chat.activity.\(event.eventID).\(section.label.lowercased())",
                                                isCanonicalPreview: event.contentReference != nil)
                            .foregroundStyle(theme.secondaryText)
                            .padding(BighelpTokens.space12)
                            .background(
                                theme.raisedSurface,
                                in: .rect(cornerRadius: BighelpTokens.radius12)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                                    .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier(
                                "chat.activity.\(event.eventID).\(section.label.lowercased())"
                            )
                    }
                }
            }
        }
    }

    private var detailSections: [(label: String, value: String)] {
        var sections: [(String, String)] = []
        if let summary = nonempty(event.summary) {
            sections.append(("Summary", summary))
        }
        if let arguments = nonempty(event.arguments) {
            sections.append(("Input", arguments))
        }
        if let result = nonempty(event.result) {
            sections.append(("Result", result))
        }
        if let detail = nonempty(event.detail), detail != event.summary, detail != event.result {
            sections.append(("Details", detail))
        }
        return sections
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    @BighelpThemeReader private var theme: BighelpTheme
}

/// Back-to-back thinking as one row: "Thinking" while it runs, then "Thought
/// for 6s". The agent's thinking text unfolds under it; it's open while the
/// agent thinks unless the reader chose otherwise.
struct ChatThinkingRow: View {
    let events: [ChatActivityEvent]
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var disclosures
    @State private var localExpanded: Bool?

    private var isExpanded: Bool {
        disclosures?.isExpanded(reasoning: events) ?? localExpanded ?? events.contains { $0.lifecycle == .running }
    }

    var body: some View {
        BighelpActivityRow(
            phase: ChatActivityPresentation.thinkingPhase(for: events),
            note: ChatActivityPresentation.thinkingNote(for: events),
            isExpanded: Binding(get: { isExpanded }, set: { expanded in
                if let disclosures { disclosures.setExpanded(expanded, reasoning: events) }
                else { localExpanded = expanded }
            }),
            onDisclosureChange: onDisclosureChange,
            accessibilityIdentifier: "chat.activity.\(events.first?.eventID ?? "reasoning")"
        )
    }
}
