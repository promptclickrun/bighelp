import SwiftUI

struct AgentSelectionView: View {
    let title: String
    let detail: String
    let agents: [AgentProfile]
    var avatarURL: @MainActor (AgentProfile) -> URL? = { _ in nil }
    let select: (AgentProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(agents) { agent in
                    Button { select(agent) } label: {
                        HStack(spacing: BighelpTokens.space12) {
                            AvatarView(
                                stableID: agent.id,
                                displayName: agent.name,
                                imageURL: avatarURL(agent),
                                size: 44
                            )
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                    .font(.bighelp(.callout).weight(.semibold))
                                    .foregroundStyle(theme.primaryText)
                                if !agent.role.isEmpty {
                                    Text(agent.role)
                                        .font(.bighelp(.footnote))
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, BighelpTokens.space4)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.surface)
                    .accessibilityLabel("Choose \(agent.name)")
                    .accessibilityIdentifier("scheduled-tasks.choose-agent.\(agent.id)")
                }
            } header: {
                Text(detail)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, BighelpTokens.space8)
            }
            if agents.isEmpty {
                ContentUnavailableView(
                    "No bots yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Add a bot first, then give it a task.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        #if targetEnvironment(macCatalyst)
        // A Mac sheet can't be swiped away, so the picker needs its own way out.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .bighelpToolbarText()
            }
        }
        #endif
    }

    @BighelpThemeReader private var theme
}
