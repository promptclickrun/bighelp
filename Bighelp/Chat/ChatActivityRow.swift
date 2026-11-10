import SwiftUI
import UIKit

/// One tool call or helper agent inside an unfolded work trail, as a step
/// line hanging from the trail's rail. A tool call unfolds in place as one
/// block (`ChatToolBlockView`: what it asked for, then what came back); code
/// it ran unfolds as a notebook cell (`ChatToolCodeCellView`). Each one is
/// its own recycled timeline row.
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
                                .fixedSize()
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
        BighelpActivityStepRow(step: ChatActivityPresentation.step(for: event))
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
        // Code a tool ran shows as a cell in place of its input and result.
        let codeCell = event.contentReference == nil ? ChatToolCodeCell.make(for: event) : nil
        let block = ChatToolBlock(event: event, showsCodeCell: codeCell != nil)
        if let reference = event.contentReference {
            Text("Preview — complete content is stored on Hermes.")
                .font(.bighelp(.caption))
                .foregroundStyle(.secondary)
            BighelpSessionContentDisclosure(sessionID: reference.sessionID, rowID: reference.rowID)
        }
        if let codeCell {
            ChatToolCodeCellView(cell: codeCell, event: event, identifier: "chat.activity.\(event.eventID).code-cell",
                                 onDisclosureChange: onDisclosureChange)
        }
        if !block.isEmpty {
            ChatToolBlockView(block: block, event: event, identifier: "chat.activity.\(event.eventID)",
                              showsActions: codeCell == nil)
        } else if codeCell == nil {
            Text("Hermes did not provide additional details for this call.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme
}

/// Back-to-back thinking as one row, named by the model's newest heading
/// ("Reading the PDF"); without one, "Thinking" while it runs, then "Thought
/// for 6s". The agent's thinking text unfolds under it; it's open while the
/// agent thinks, and after that too with Settings › Chat › Keep reasoning open,
/// unless the reader chose otherwise.
struct ChatThinkingRow: View {
    let events: [ChatActivityEvent]
    let onDisclosureChange: () -> Void

    @Environment(\.chatActivityDisclosureStore) private var disclosures
    @AppStorage(ChatReasoningPlacement.staysOpenKey) private var staysOpen = ChatReasoningPlacement.staysOpenByDefault
    @State private var localExpanded: Bool?

    private var isExpanded: Bool {
        guard let disclosures else { return localExpanded ?? (staysOpen || events.contains { $0.lifecycle == .running }) }
        return disclosures.reasoningChoice(events) ?? (staysOpen || disclosures.isExpanded(reasoning: events))
    }

    var body: some View {
        BighelpActivityRow(
            phase: ChatActivityPresentation.thinkingPhase(for: events),
            title: ChatActivityPresentation.thinkingTitle(for: events),
            note: ChatActivityPresentation.thinkingNote(for: events),
            isExpanded: Binding(get: { isExpanded }, set: { expanded in
                if let disclosures { disclosures.setExpanded(expanded, reasoning: events) }
                else { localExpanded = expanded }
            }),
            onDisclosureChange: onDisclosureChange,
            accessibilityIdentifier: "chat.activity.\(events.first?.eventID ?? "reasoning")",
            loaderID: ChatLoaderID.thinking(events)
        )
    }
}
