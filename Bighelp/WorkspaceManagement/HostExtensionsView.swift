import SwiftUI

/// Optional features appear only after the selected host confirms their mounts.
@MainActor
struct HostExtensionsView: View {
    @Bindable var kanban: HermesKanbanStore
    @Bindable var achievements: HermesAchievementsStore

    var body: some View {
        List {
            Section {
                if kanban.mount == .available {
                    NavigationLink("Kanban") { HermesKanbanView(store: kanban) }
                } else {
                    LabeledContent("Kanban", value: kanban.isLoading ? "Checking…" : "Unavailable")
                    if let error = kanban.errorMessage { Text(error).foregroundStyle(.secondary) }
                }
                if achievements.mount == .available {
                    NavigationLink("Achievements") { HermesAchievementsView(store: achievements) }
                } else {
                    LabeledContent("Achievements", value: achievements.isLoading ? "Checking…" : "Unavailable")
                    if let error = achievements.errorMessage { Text(error).foregroundStyle(.secondary) }
                }
            } header: { Text("Available on this host") } footer: {
                Text("Features available on this Hermes host. Nothing is installed automatically.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Host Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if kanban.mount == .unknown { await kanban.load() }
            if achievements.mount == .unknown { await achievements.load() }
        }
        .bighelpRefreshable {
            await kanban.load()
            await achievements.load()
        }
    }
}
