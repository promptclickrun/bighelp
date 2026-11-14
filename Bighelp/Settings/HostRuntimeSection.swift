import SwiftUI

@MainActor
struct HostRuntimeSection: View {
    let store: HostRuntimeStore?
    let agents: AgentDirectoryStore?
    let theme: BighelpTheme

    private var currentStore: HostRuntimeStore? { store?.ownsScope == true ? store : nil }
    private var status: HostRuntimeStatus? { currentStore?.status }
    private var needsHermesRecovery: Bool {
        agents?.errorCode == "hermes_capability_missing" || status?.hasMissingAgentCapability == true
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text(title).bighelpFont(.label, weight: .semibold)
                Text(detail).bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if currentStore?.isChecking == true { ProgressView("Checking computer") }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.host-runtime-status")

            if let status {
                if currentStore?.availability != .supported {
                    Text("Last observation, not verified by the latest check.")
                        .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                }
                DisclosureGroup("Advanced details") {
                    LabeledContent("Hermes running", value: status.hermes.runningVersion ?? "Unknown")
                    LabeledContent("Hermes CLI on PATH", value: status.hermes.cliVersion ?? "Unknown")
                    LabeledContent("Hermes updates", value: status.hermes.updateState.title)
                    LabeledContent("Hermes restart", value: status.hermes.restartState.title)
                    LabeledContent("bighelp plugin running", value: status.plugin.runningVersion)
                    LabeledContent("Plugin active revision", value: status.plugin.activeRevision.map { String($0.prefix(12)) } ?? "Unknown")
                    LabeledContent("Plugin installed revision", value: status.plugin.installedRevision.map { String($0.prefix(12)) } ?? "Unknown")
                    LabeledContent("Plugin restart", value: status.plugin.restartState.title)
                    if let checkedAt = currentStore?.checkedAt {
                        Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                    }
                }

            }
            Button {
                guard let requestedStore = currentStore else { return }
                Task {
                    guard requestedStore.ownsScope, !Task.isCancelled else { return }
                    await agents?.loadReportingErrors()
                    guard requestedStore.ownsScope, !Task.isCancelled else { return }
                    await requestedStore.refresh()
                }
            } label: {
                Label("Check Computer Status", systemImage: "arrow.clockwise")
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .disabled(currentStore == nil || currentStore?.isChecking == true || agents?.isLoading == true)
            .accessibilityIdentifier("settings.check-host-runtime")
        } header: {
            Text("Computer")
        } footer: {
            Text("A connected Link does not prove every feature works. Checking never updates or restarts the computer; plugin updates do not update Hermes.")
        }
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .listRowBackground(theme.surface)
    }

    private var title: String {
        if needsHermesRecovery { return "Hermes compatibility needs attention" }
        if status?.plugin.restartState == .required || status?.hermes.restartState == .required { return "Computer restart required" }
        if agents?.errorMessage != nil { return "Bot discovery unavailable" }
        if status?.hermes.updateState == .available { return "Hermes update available" }
        switch currentStore?.availability {
        case .supported:
            if status?.compatibility.state == .compatible,
               status?.compatibility.checkedOperations.contains("agents.list") == true { return "Bot discovery available" }
            return "Computer compatibility unknown"
        case .unsupported: return "Computer diagnostics not supported"
        case .unavailable: return "Computer status unavailable"
        case .unknown, nil: return "Computer status unknown"
        }
    }

    private var detail: String {
        if needsHermesRecovery { return AgentDirectoryStore.hermesCompatibilityRecovery }
        if status?.hermes.restartState == .required {
            return "Restart the Hermes gateway on the computer when active work can be interrupted, then reconnect and check again."
        }
        if status?.plugin.restartState == .required {
            return "The installed bighelp plugin differs from the active plugin. Restart the gateway on the computer when active work can be interrupted, then reconnect and check again. For plugin updates, use Settings → Connectivity → Updates."
        }
        if agents?.errorMessage != nil {
            return "Bots could not be loaded. Check again or inspect the gateway. Existing chats and cached bots remain available; this does not prove Hermes is outdated."
        }
        if status?.hermes.updateState == .available {
            return "Update Hermes on the computer, then restart when active work can be interrupted. Reconnect and check again. Updating the bighelp plugin does not update Hermes."
        }
        switch currentStore?.availability {
        case .supported:
            if status?.compatibility.state == .compatible,
               status?.compatibility.checkedOperations.contains("agents.list") == true {
                return "The computer listed bots. This does not check every feature or prove Hermes is current."
            }
            return "Bot compatibility is not established. Unknown version or update details do not prove the computer is outdated."
        case .unsupported:
            return "This computer does not advertise diagnostics. That does not establish whether Hermes is current. Check the gateway on the computer; bighelp plugin updates are separate in Settings → Connectivity → Updates."
        case .unavailable:
            return "The computer did not provide a verified status. Check the connection and try again. No update or restart was requested."
        case .unknown, nil:
            return "Computer diagnostics have not been verified. Connect to the paired computer and check again. Missing diagnostics do not mean Hermes is outdated."
        }
    }
}
