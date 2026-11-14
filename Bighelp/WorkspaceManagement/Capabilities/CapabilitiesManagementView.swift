import SwiftUI

/// One native entry point for all four management domains. The destination is a
/// closed enum, and every dependency is a feature-specific protocol.
@MainActor
struct CapabilitiesManagementView: View {
    let kind: CapabilitiesManagementKind
    let hostName: String
    let profileName: String

    @State private var skillsModel: SkillsHubManagementModel
    @State private var mcpModel: MCPManagementModel
    @State private var pluginModel: PluginLifecycleManagementModel
    @State private var toolsetModel: ToolsetManagementModel

    init(
        kind: CapabilitiesManagementKind,
        hostName: String,
        profileName: String,
        dependencies: CapabilitiesManagementDependencies
    ) {
        self.kind = kind
        self.hostName = hostName
        self.profileName = profileName
        _skillsModel = State(initialValue: SkillsHubManagementModel(client: dependencies.skills, keptCopies: .shared))
        _mcpModel = State(initialValue: MCPManagementModel(client: dependencies.mcp))
        _pluginModel = State(initialValue: PluginLifecycleManagementModel(client: dependencies.plugins, keptCopies: .shared))
        _toolsetModel = State(initialValue: ToolsetManagementModel(client: dependencies.toolsets))
    }

    init?(
        destination: WorkspaceDestination,
        hostName: String,
        profileName: String,
        dependencies: CapabilitiesManagementDependencies
    ) {
        guard let kind = CapabilitiesManagementKind(destination: destination) else { return nil }
        self.init(kind: kind, hostName: hostName, profileName: profileName, dependencies: dependencies)
    }

    var body: some View {
        Group {
            switch kind {
            case .skills:
                SkillsHubManagementView(model: skillsModel, hostName: hostName, profileName: profileName)
            case .mcp:
                MCPManagementView(model: mcpModel, hostName: hostName, profileName: profileName)
            case .plugins:
                PluginLifecycleManagementView(model: pluginModel, hostName: hostName)
            case .toolsets:
                ToolsetManagementView(model: toolsetModel, hostName: hostName, profileName: profileName)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("capabilities.management.\(kind.rawValue)")
    }
}

struct CapabilitiesScopeSection: View {
    let hostName: String
    let profileName: String?

    var body: some View {
        Section {
            LabeledContent("Host", value: hostName)
            if let profileName { LabeledContent("Profile", value: profileName) }
        } header: {
            Text("Applies to")
        } footer: {
            if profileName == nil {
                Text("Plugin changes affect every profile on this host.")
            }
        }
    }
}

struct CapabilitiesStatusSections: View {
    let support: CapabilitiesHostSupport
    let isBusy: Bool
    let errorMessage: String?
    let successMessage: String?
    let retry: () -> Void

    var body: some View {
        if isBusy {
            Section { ProgressView("Waiting for Hermes") }
        }
        if case .unavailable(let message) = support {
            Section {
                Label(message, systemImage: "questionmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text("Unavailable features remain off; Bighelp does not substitute a local implementation.")
            }
        }
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: retry)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .disabled(isBusy)
            }
            .accessibilityIdentifier("capabilities.error")
        }
        if let successMessage {
            Section { Label(successMessage, systemImage: "checkmark.circle") }
                .accessibilityIdentifier("capabilities.confirmed")
        }
    }
}
