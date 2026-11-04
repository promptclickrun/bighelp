import SwiftUI

/// Helpers or a background command reporting back, where Hermes' report would be: what
/// finished, a line for each task, and See results. It draws only its row's value, so the
/// timeline builds it once and keeps it like any other row; nothing on it moves or updates
/// on its own, and the report is laid out only in the sheet.
struct ChatBackgroundResultCard: View {
    let result: ChatBackgroundResult

    @State private var isPresented = false
    @BighelpThemeReader private var theme
    @BighelpLoaderScaled(relativeTo: .body) private var glyphSide: CGFloat = 18

    /// More tasks than this read "and 2 more"; the sheet lists them all.
    static let shownTasks = 3

    var body: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack(spacing: BighelpTokens.space8) {
                    BighelpActivityGlyphView(glyph: result.kind == .helpers ? .glyph(.bots) : .symbol("terminal"),
                                             side: glyphSide)
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: glyphSide, height: glyphSide)
                        .accessibilityHidden(true)
                    Text(result.headline)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityIdentifier("chat.background-result.headline")
                    Spacer(minLength: BighelpTokens.space8)
                    if let time = ChatBackgroundResult.duration(result.seconds) {
                        Text(time)
                            .bighelpFont(.metadata)
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    ForEach(Array(result.tasks.prefix(Self.shownTasks).enumerated()), id: \.offset) { _, task in
                        ChatBackgroundTaskLine(task: task, isCommand: result.kind == .command)
                    }
                    if result.tasks.count > Self.shownTasks {
                        Text("and \(result.tasks.count - Self.shownTasks) more")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                    if result.isEarlyWarning {
                        Text("The others are still working.")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Button { isPresented = true } label: {
                    HStack(spacing: BighelpTokens.space4) {
                        Text("See results")
                        Image(systemName: "chevron.right")
                            .font(.bighelp(.caption).weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.background-result.open")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bighelpSheet(isPresented: $isPresented) {
            ChatBackgroundResultSheet(result: result)
                .bighelpSheetSize(.large)
        }
    }
}

/// One task on the card or in the sheet: how it ended, what it was, how long it took.
private struct ChatBackgroundTaskLine: View {
    let task: ChatBackgroundResult.Task
    let isCommand: Bool
    var wraps = false

    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: wraps ? .firstTextBaseline : .center, spacing: BighelpTokens.space8) {
            Image(systemName: symbol)
                .font(.bighelp(.caption).weight(.bold))
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Group {
                if isCommand {
                    Text(task.goal).font(.bighelp(.caption, design: .monospaced))
                } else {
                    Text(task.goal).bighelpFont(wraps ? .body : .metadata)
                }
            }
            .foregroundStyle(wraps ? theme.primaryText : theme.secondaryText)
            .lineLimit(wraps ? nil : 1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let time = ChatBackgroundResult.duration(task.seconds) {
                Text(time)
                    .bighelpFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.goal), \(spokenOutcome)")
    }

    private var symbol: String {
        switch task.outcome {
        case .finished: "checkmark"
        case .failed: "xmark"
        case .stoppedEarly: "exclamationmark"
        case .stopped: "stop.fill"
        }
    }

    private var color: Color {
        switch task.outcome {
        case .finished: theme.success
        case .failed: theme.danger
        case .stoppedEarly: theme.warning
        case .stopped: theme.secondaryText
        }
    }

    private var spokenOutcome: String {
        switch task.outcome {
        case .finished: "finished"
        case .failed: "failed"
        case .stoppedEarly: "stopped early, so the work may be partial"
        case .stopped: "stopped"
        }
    }
}

/// The whole result: every task, then what each one reported.
struct ChatBackgroundResultSheet: View {
    let result: ChatBackgroundResult

    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        ForEach(Array(result.tasks.enumerated()), id: \.offset) { _, task in
                            ChatBackgroundTaskLine(task: task, isCommand: result.kind == .command, wraps: true)
                        }
                    }
                    ForEach(Array(result.reportSections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            if !section.heading.isEmpty {
                                Text(section.heading.uppercased())
                                    .bighelpFont(.metadata, weight: .bold)
                                    .tracking(0.6)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Text(section.body)
                                .font(.bighelp(.footnote))
                                .foregroundStyle(theme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(BighelpTokens.space16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(result.headline)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chat.background-result.done")
                }
            }
        }
        .accessibilityIdentifier("chat.background-result.sheet")
    }
}
