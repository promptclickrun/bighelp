import SwiftUI

struct BotModeObservedToolView: View {
    let row: BotModeObservedTool
    let memberName: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Button(action: onToggle) {
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(memberName) · \(row.observation.tool.name)")
                            .font(.bighelp(.subheadline).weight(.semibold))
                        Text(row.observation.kind == .started ? "Started · live observation" : "Finished · outcome not reported")
                            .font(.bighelp(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                detail(row.observation.arguments, title: "Arguments")
                detail(row.observation.result, title: "Result")
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .accessibilityIdentifier("bot-mode.observed-tool")
    }

    @ViewBuilder
    private func detail(_ detail: HermesBotModeActivityDetail, title: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(title).font(.bighelp(.caption).weight(.semibold))
            if let text = detail.text, detail.state == .available {
                ChatToolDetailText(label: title, value: text, identifier: "\(row.id).\(title)")
            } else {
                Text(omissionMessage(detail.state))
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func omissionMessage(_ state: HermesBotModeActivityDetail.State) -> String {
        switch state {
        case .available, .unavailable: "Not provided by the computer."
        case .omittedSize: "Omitted by the computer because of its size."
        case .omittedSensitive: "Omitted by the computer's sensitive-content check."
        }
    }
}
