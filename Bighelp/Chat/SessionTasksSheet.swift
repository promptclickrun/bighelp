import SwiftUI

struct SessionTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: ChatTaskDrawerState

    var body: some View {
        NavigationStack {
            ScrollView {
                taskContent
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var taskContent: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space20) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Chat progress")
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: BighelpTokens.space8)
                    Text("\(state.completedCount) of \(state.totalCount)")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                ProgressView(
                    value: Double(state.completedCount),
                    total: Double(max(1, state.totalCount))
                )
                .tint(theme.action)
                .accessibilityLabel("Chat task progress")
                .accessibilityValue("\(state.completedCount) of \(state.totalCount) completed")
            }
            .padding(BighelpTokens.space16)
            .bighelpSurface(.card)
            .accessibilityIdentifier("tasks.summary")

            LazyVStack(alignment: .leading, spacing: BighelpTokens.space12) {
                ForEach(state.items) { task in
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        taskIcon(task.status)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(task.content)
                                .font(.bighelp(.body))
                                .foregroundStyle(task.status == .cancelled
                                    ? theme.tertiaryText
                                    : theme.primaryText)
                                .strikethrough(task.status == .cancelled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(taskStatus(task.status))
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(BighelpTokens.space16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bighelpSurface(.card)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task.row.\(task.id)")
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(BighelpTokens.space20)
        .frame(maxWidth: .infinity)
    }

    private func taskStatus(_ status: ChatTaskStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }

    @ViewBuilder
    private func taskIcon(_ status: ChatTaskStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(theme.tertiaryText)
        case .inProgress:
            BighelpThinkingOrb(scenario: .working, scale: .inline)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(theme.tertiaryText)
        }
    }

    @BighelpThemeReader private var theme

}
