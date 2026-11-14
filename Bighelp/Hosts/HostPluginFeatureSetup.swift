import SwiftUI

enum HostPluginFeature: String, Hashable, Sendable {
    case liveVoice, deviceAccess

    var capability: String { self == .liveVoice ? "native-voice-v1" : "native-device-tools-v1" }
    var title: String { self == .liveVoice ? "Bighelp plugin" : "Device access" }
    /// Device access shows the plugin only while there's something to do or wait for; Voice
    /// settings always show its status line, since every voice mode needs the plugin.
    var showsOnlyWhenNeeded: Bool { self == .deviceAccess }

    /// Whether the plugin's rows show. Device access hides them with no computer chosen (its
    /// opening line says to connect one), until the first check ends, and once the plugin is
    /// ready. A check alone changes nothing on screen: most end with the plugin ready, and a line
    /// that came and went moved the page each time it opened, so rows that were up stay up
    /// through a later check and rows that were hidden stay hidden.
    func showsRows(hasComputer: Bool, checked: Bool, checking: Bool, working: Bool, ready: Bool,
                   restartPending: Bool, showedRows: Bool) -> Bool {
        guard showsOnlyWhenNeeded else { return true }
        guard hasComputer else { return false }
        if working || restartPending { return true }
        guard checked else { return false }
        if checking { return showedRows }
        return !ready
    }
    var installIdentifier: String {
        self == .liveVoice ? CodexLiveVoiceSettingsPresentation.installAccessibilityIdentifier
            : "settings.install-loopdy-plugin-for-device-access"
    }
}

/// This section installs through the selected host's ordinary plugin manager.
/// Capability discovery and installation never enroll a notification recipient.
@MainActor
struct HostPluginFeatureSection: View {
    let feature: HostPluginFeature
    /// The page's opening line, as a row of its own in place of the section's title. The row is
    /// always on the page, so the check below has somewhere to live while the plugin's rows are hidden.
    var lead: Text? = nil
    @Environment(\.bighelpHostRegistry) private var registry
    @Environment(\.scenePhase) private var scenePhase
    @State private var setup: HostNotificationSetupModel?
    @State private var status = "Checking the selected computer…"
    @State private var action: String?
    @State private var checking = false
    @State private var ready = false
    /// Whether a check has finished for the computer in use, and whether it left something to
    /// do or wait for (`HostPluginFeature.showsRows`).
    @State private var checked = false
    @State private var showedRows = false
    /// Set after this section installed or turned on the plugin, until a restart finishes it.
    @State private var restarts: HostPluginUpdateModel?
    @State private var restartPrompt: HostPluginUpdateModel?
    @State private var requestID = UUID()

    private var identity: String {
        // The connection generation isn't observed; isConnected is, so a drop and
        // reconnect re-runs the check instead of keeping the old answer.
        "\(registry?.selectedHostID?.uuidString ?? "none"):\(registry?.generation.uuidString ?? "none"):\(registry?.selectedWorkspace?.connectionGeneration.uuidString ?? "none"):\(registry?.selectedWorkspace?.isConnected == true)"
    }

    private var showsRows: Bool {
        feature.showsRows(hasComputer: registry?.selectedHost != nil, checked: checked, checking: checking,
                          working: setup?.isWorking == true, ready: ready, restartPending: restarts != nil,
                          showedRows: showedRows)
    }

    private var offersInstall: Bool {
        action != nil && setup != nil && !checking && setup?.isWorking != true && restarts?.isWorking != true
    }

    var body: some View {
        if let lead {
            // A row, not a header: a section whose rows are all hidden may not keep its modifiers
            // alive, and the check must run to find out whether the rows are needed at all.
            Section {
                checksPlugin(lead.bighelpFont(.metadata).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear))
            }
            if showsRows { pluginSection }
        } else {
            checksPlugin(pluginSection)
        }
    }

    /// Runs the check for the computer in use, again when it changes, and stops it when the page goes.
    private func checksPlugin(_ view: some View) -> some View {
        view
            .task(id: identity) { await check() }
            .onDisappear { requestID = UUID(); setup?.cancel() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                requestID = UUID()
                setup?.cancel()
                // The check this replaces returns without finishing, so it can't clear its own flag.
                checking = false
            }
    }

    private var pluginSection: some View {
        Section {
            if showsRows {
                Label(status, systemImage: ready ? "checkmark.circle" : "puzzlepiece.extension")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.plugin-status.\(feature.rawValue)")
                if let restarts, restarts.isWorking {
                    ProgressView(restarts.message ?? "Restarting Hermes…")
                } else if checking || setup?.isWorking == true {
                    ProgressView(setup?.isWorking == true ? "Setting up the plugin…" : "Checking plugin…")
                } else if let action, let setup {
                    Button(action) { Task { await install(setup) } }
                        .accessibilityIdentifier(feature.installIdentifier)
                } else if let restarts {
                    Button("Restart Hermes to Finish") { restartPrompt = restarts }
                        .accessibilityIdentifier("settings.plugin-restart.\(feature.rawValue)")
                } else if !ready, registry?.selectedHost != nil {
                    Button("Check again") { Task { await check() } }
                        .accessibilityIdentifier("settings.plugin-check.\(feature.rawValue)")
                }
            }
        } header: {
            Text(lead == nil ? feature.title : "Bighelp plugin")
        } footer: {
            if feature == .deviceAccess, showsRows, offersInstall {
                Text(BighelpPlatform.isMac
                     ? "Installation leaves macOS permissions off."
                     : "Installation leaves iOS permissions off.")
            }
        }
        .pluginRestartPrompt($restartPrompt) { restarted in
            if restarted { restarts = nil }
            await check()
        }
    }

    /// Installs or turns on the plugin, then asks to restart the dashboard and the gateway: it
    /// takes effect only after both.
    private func install(_ setup: HostNotificationSetupModel) async {
        await setup.enable()
        guard !Task.isCancelled else { return }
        guard setup.state == .installed, setup.pluginChanged, let registry else {
            status = setup.message
            return
        }
        status = "Plugin installed. It takes effect after the Hermes dashboard and the messaging gateway restart."
        // Its install button is done; the restart button takes its place.
        action = nil
        let model = await HostPluginUpdateModel.afterPluginChange(hostID: setup.hostID, registry: registry)
        guard !Task.isCancelled else { return }
        restarts = model
        restartPrompt = model
    }

    private func check() async {
        let request = UUID()
        requestID = request
        checking = true; ready = false; action = nil
        defer {
            if requestID == request {
                checking = false
                checked = true
                showedRows = !ready || restarts != nil
            }
        }
        guard let registry, let host = registry.selectedHost,
              let workspace = registry.selectedWorkspace, workspace.isConnected,
              let direct = workspace.nativeClient,
              let authority = workspace.savedConnection?.workspaceAuthority else {
            status = "Connect to a Hermes computer to check the plugin."
            return
        }
        let generation = registry.generation
        let connection = workspace.connectionGeneration
        func owns() -> Bool {
            requestID == request && registry.generation == generation
                && registry.selectedHostID == host.id && workspace.connectionGeneration == connection
                && workspace.isConnected && !Task.isCancelled
        }
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: generation,
                                   connectionGeneration: connection)
        let client = DirectHermesNativePluginClient(http: direct, owner: owner,
                                                    currentOwner: { owns() ? owner : nil })
        setup?.cancel()
        setup = HostNotificationSetupModel(host: host, registry: registry, enrollNotifications: false)
        // Tracks whether the plugin's native API (hermes serve dashboard
        // process) answered at all. A 200 without the capability means the
        // middleware did not advertise it; a thrown route means the plugin is
        // not loaded there. Both are distinct from "not installed".
        var nativeResponded = false
        var nativeFailure: (any Error)?
        do {
            let context: DirectHermesNativeContext
            do { context = try await client.loadContext(force: true) }
            catch where Self.isMomentary(error) {
                // A host waking up or a network hand-off; one more try before
                // reporting anything.
                try await Task.sleep(for: .seconds(1))
                guard owns() else { return }
                context = try await client.loadContext(force: true)
            }
            guard owns() else { return }
            nativeResponded = true
            if context.features.contains(feature.capability) {
                guard registry.recordPluginFeatureReadiness(
                    feature: feature,
                    hostID: host.id,
                    registryGeneration: generation,
                    connectionGeneration: connection,
                    contextETag: context.etag,
                    capabilities: context.features,
                    isCurrent: owns
                ) else { return }
                ready = true
                status = "Bighelp plugin connected."
                return
            }
        } catch {
            guard owns() else { return }
            nativeFailure = error
            // A missing route can mean absent, disabled, or not yet loaded.
            // Read the official manager before offering any installation.
        }
        do {
            let matches = try HostInstalledPlugin.decodeList(
                await workspace.managePlugins(["action": .string("list")])
            ).filter { $0.name == "loopdy" }
            guard owns() else { return }
            if matches.isEmpty {
                status = "The Bighelp plugin is not installed on this computer."
                action = "Install Bighelp Plugin"
            } else if matches.count == 1, let installed = matches.first {
                let latest = try? await GitHubPluginReleaseSource.shared.latest(refresh: false)
                guard owns() else { return }
                if let latest, let current = installed.version,
                   HostPluginPin.compare(current, latest.version) == .orderedAscending {
                    status = "This computer has Bighelp plugin \(current). Version \(latest.version) is available."
                    action = "Update Bighelp Plugin"
                } else if installed.configuredEnabled {
                    status = nativeResponded
                        ? "The plugin is installed and answers, but it doesn't offer this feature on this computer. The Hermes dashboard's log on your computer says why. Restart the dashboard on your computer, then check again."
                        : Self.unreachableMessage(nativeFailure)
                } else {
                    status = "The Bighelp plugin is installed but disabled."
                    action = "Enable Bighelp Plugin"
                }
            } else {
                status = "Hermes reported more than one Bighelp plugin. Review the installed plugins on your computer."
            }
        } catch {
            guard owns() else { return }
            status = "Plugin status could not be verified. Check your computer connection and try again."
        }
    }

    /// Only a missing route means the Hermes dashboard hasn't loaded the plugin. A
    /// turned-away sign-in or a host that didn't answer needs a different step,
    /// and a restart wouldn't help.
    static func unreachableMessage(_ failure: (any Error)?) -> String {
        switch failure {
        case WorkspaceClientError.unavailable(.pluginRequired)?:
            "The plugin is installed, but the Hermes dashboard on your computer hasn't loaded it yet. Restart the dashboard and the messaging gateway on your computer, then check again."
        case WorkspaceClientError.authenticationRequired?:
            "The plugin is installed, but this computer turned down Bighelp's sign-in. Sign in to the computer again, then check again."
        default:
            "The plugin is installed, but this computer didn't answer Bighelp just now. Check again in a moment."
        }
    }

    private static func isMomentary(_ error: any Error) -> Bool {
        switch error {
        case WorkspaceClientError.transportUnavailable, DirectHermesError.timedOut, DirectHermesError.connectionFailed,
             DirectHermesError.serverUnavailable:
            true
        default:
            false
        }
    }
}

/// Explicit host-detail installation. It reuses the stock plugin coordinator
/// and never registers a device or creates a notification grant.
@MainActor
struct HostPluginInstallationSection: View {
    let model: HostNotificationSetupModel
    @State private var showsReview = false
    /// Set after this section installed or turned on the plugin, until a restart finishes it.
    @State private var restarts: HostPluginUpdateModel?
    @State private var restartPrompt: HostPluginUpdateModel?
    /// What the restart that finished the install said, once its button is gone.
    @State private var finishedRestartMessage: String?
    @Environment(\.bighelpHostRegistry) private var registry

    var body: some View {
        Section {
            Text(model.message)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hosts.plugin-install.status")
            if let failure = model.failure, !model.isWorking {
                BighelpNotificationFailureCodeRow(failure: failure, identifier: "hosts.plugin-install.failure")
            }

            if model.isWorking {
                ProgressView(model.state == .installing ? "Installing the plugin…" : "Checking the plugin…")
                    .accessibilityIdentifier("hosts.plugin-install.progress")
            } else if model.state == .installed || model.state == .enabled {
                Label("Installed and enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("hosts.plugin-install.complete")
            } else if showsReview {
                Text("This installs the newest Bighelp plugin release from GitHub, or turns on the one that's already there. An older plugin is replaced, which overwrites any local changes to it; a newer one is kept.")
                    .fixedSize(horizontal: false, vertical: true)
                if let release = model.release {
                    LabeledContent("Version", value: release.version)
                        .accessibilityIdentifier("hosts.plugin-install.version")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Commit").bighelpFont(.metadata).foregroundStyle(.secondary)
                        Text(release.pin.revision).bighelpFont(.code).textSelection(.enabled)
                    }
                }
                Text("Hermes' own security scanner checks the plugin before it's installed, and Bighelp confirms the exact version landed.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Installing doesn't turn on notifications. The plugin takes effect after the Hermes dashboard and the messaging gateway restart, and Bighelp asks to restart them once it's in.")
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = model.actionTitle {
                    Button(actionTitle) { Task { await install() } }
                        .accessibilityIdentifier("hosts.install-loopdy-plugin.confirm")
                }
                Button("Not Now", role: .cancel) { showsReview = false }
                    .accessibilityIdentifier("hosts.install-loopdy-plugin.not-now")
            } else {
                Button(pluginReviewTitle) {
                    showsReview = true
                    Task { await model.loadRelease() }
                }
                    .accessibilityIdentifier("hosts.install-loopdy-plugin")
            }
            if let restarts {
                if restarts.isWorking {
                    ProgressView(restarts.message ?? "Restarting Hermes…")
                        .accessibilityIdentifier("hosts.plugin-install.restarting")
                } else {
                    Button("Restart Hermes to Finish") { restartPrompt = restarts }
                        .accessibilityIdentifier("hosts.plugin-install.restart")
                }
            }
            if let message = restarts?.message ?? finishedRestartMessage, restarts?.isWorking != true {
                Text(message).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hosts.plugin-install.restart-status")
            }
        } header: {
            Text("Bighelp Plugin")
        } footer: {
            Text("Plugin installation is separate from notification enrollment. Basic chat and Artifacts remain available without it.")
        }
        .pluginRestartPrompt($restartPrompt) { restarted in
            guard restarted, let restarts else { return }
            finishedRestartMessage = restarts.message
            self.restarts = nil
        }
    }

    private var pluginReviewTitle: String {
        switch model.state {
        case .notConfigured: "Install Bighelp Plugin"
        case .outcomeUnknown: "Review and Check Installed State"
        default: "Review Plugin Setup"
        }
    }

    /// Installs or turns on the plugin, then asks to restart the dashboard and the gateway: it
    /// takes effect only after both.
    private func install() async {
        await model.enable()
        guard model.state == .installed || model.state == .enabled, model.pluginChanged, let registry else { return }
        let restarts = await HostPluginUpdateModel.afterPluginChange(hostID: model.hostID, registry: registry)
        self.restarts = restarts
        restartPrompt = restarts
    }
}
