#if os(iOS)
import SwiftUI

/// Settings › CarPlay: the computer and the agent bighelp talks to in the car. Picking another
/// agent in the car changes the agent here too.
struct CarPlaySettingsSection: View {
    @State private var gateways: [BighelpShortcutGateway] = []
    @State private var hostID: UUID?
    @State private var agents: [BighelpShortcutAgent] = []
    @State private var agentID: String?
    @State private var isLoadingAgents = false
    @State private var agentsFailed = false
    @State private var isLoaded = false
    private let preference = CarPlayAgentPreference()

    var body: some View {
        Section {
            if gateways.count > 1 {
                Picker("Computer", selection: $hostID) {
                    Text("The one bighelp is using").tag(UUID?.none)
                    ForEach(gateways) { gateway in
                        Text(gateway.name).tag(UUID?.some(gateway.id))
                    }
                }
                .accessibilityIdentifier("settings.carplay.computer")
            }
            Picker("Agent", selection: $agentID) {
                Text("Default agent").tag(String?.none)
                ForEach(agents) { agent in
                    Text(agent.name).tag(String?.some(agent.id))
                }
                // A saved agent the list doesn't have (yet), so the picker never goes blank.
                if let agentID, !agents.contains(where: { $0.id == agentID }) {
                    Text(isLoadingAgents ? "Loading…" : "Saved agent").tag(String?.some(agentID))
                }
            }
            .accessibilityIdentifier("settings.carplay.agent")
        } header: {
            Text("CarPlay")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When you open bighelp in CarPlay, it starts a voice chat with this agent.")
                if agentsFailed {
                    Text("bighelp couldn't read this computer's agents. Check that it's on.")
                }
            }
        }
        .task {
            gateways = BighelpCarPlayServices.gateways?() ?? []
            hostID = preference.hostID.flatMap { id in gateways.contains { $0.id == id } ? id : nil }
            agentID = preference.agentID
            isLoaded = true
            await loadAgents()
        }
        .onChange(of: hostID) { old, new in
            guard isLoaded, old != new else { return }
            preference.hostID = new
            // Agents belong to one computer: another computer starts on its default.
            agentID = nil
            Task { await loadAgents() }
        }
        .onChange(of: agentID) { _, new in
            guard isLoaded else { return }
            preference.agentID = new
        }
    }

    private func loadAgents() async {
        isLoadingAgents = true
        defer { isLoadingAgents = false }
        do {
            agents = try await BighelpCarPlayServices.agents?(hostID) ?? []
            agentsFailed = false
        } catch {
            agentsFailed = true
        }
    }
}
#endif
