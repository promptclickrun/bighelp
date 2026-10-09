import SwiftUI

/// Keep navigation ownership on the shell even while a pushed chat covers it.
struct CanonicalChatLifetime: ViewModifier {
    let coordinator: CanonicalChatCoordinator
    let appState: AppState
    let owner: WorkspaceOwner?
    let agentID: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.path) { _, _ in coordinator.cancelIfSuperseded() }
            .onChange(of: appState.selectedTab) { _, _ in coordinator.cancelIfSuperseded() }
            .onChange(of: owner) { _, _ in coordinator.cancelIfSuperseded() }
            .onChange(of: agentID) { _, _ in coordinator.cancelIfSuperseded() }
            .onDisappear { coordinator.cancel() }
    }
}
