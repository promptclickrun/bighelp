import SwiftUI

@MainActor
struct HostToolBackendsView: View {
    @Bindable var store: HostToolBackendsStore

    var body: some View {
        List {
            scopeSection
            messageSections

            switch store.support {
            case .unknown:
                Section { ProgressView("Checking host tool backends…") }
            case .unavailable(let reason):
                Section {
                    ContentUnavailableView("Tool Backends unavailable", systemImage: "wrench.and.screwdriver", description: Text(reason))
                }
            case .available:
                terminalSection
                computerUseSection
                grantSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tool Backends")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await store.load() }
        .task { if store.terminal == nil { await store.load() } }
        .confirmationDialog(
            store.review?.title ?? "Review host change",
            isPresented: Binding(
                get: { store.review != nil },
                set: { if !$0 { store.review = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let review = store.review {
                Button(review.buttonTitle) { Task { await store.confirm(review) } }
                Button("Cancel", role: .cancel) { store.review = nil }
            }
        } message: {
            Text(store.review?.message ?? "")
        }
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
        } header: { Text("Workspace") } footer: {
            Text("These controls configure execution on the selected Hermes host. They do not change \(BighelpPlatform.isMac ? "macOS" : "iOS") permissions or run a terminal on this device.")
        }
    }

    @ViewBuilder
    private var messageSections: some View {
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    @ViewBuilder
    private var terminalSection: some View {
        if let terminal = store.terminal {
            Section {
                ForEach(terminal.backends) { backend in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(backend.label).font(.bighelp(.headline))
                                if !backend.summary.isEmpty {
                                    Text(backend.summary).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            terminalStatus(backend)
                        }
                        if !backend.detail.isEmpty {
                            Text(backend.detail)
                                .font(.bighelp(.caption))
                                .foregroundStyle(backend.status == .ready ? Color.secondary : Color.orange)
                        }
                        if !backend.isActive {
                            Button("Review Selection") { store.prepareBackend(backend) }
                                .buttonStyle(.bordered)
                                .disabled(!store.canAct)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                    .accessibilityElement(children: .contain)
                }
            } header: {
                Text("Terminal execution")
            } footer: {
                Text("Hermes permits selecting a backend that still needs setup so its guidance remains visible. Selection affects future host terminal environments; existing sessions are not migrated.")
            }
        }
    }

    @ViewBuilder
    private var computerUseSection: some View {
        if let status = store.computerUse {
            Section {
                LabeledContent("Host platform", value: platformLabel(status.hostPlatform))
                LabeledContent("Platform support", value: status.isPlatformSupported ? "Supported" : "Unavailable")
                LabeledContent("CuaDriver", value: status.isInstalled ? (status.version ?? "Installed") : "Not installed")
                LabeledContent("Readiness", value: readinessLabel(status.isReady))

                if status.hostPlatform == "darwin" {
                    permissionRow("Accessibility", value: status.hasAccessibilityPermission,
                                  detail: "Allows CuaDriver on the host Mac to post input and read accessibility data.")
                    permissionRow("Screen Recording", value: status.hasScreenRecordingPermission,
                                  detail: "Allows CuaDriver on the host Mac to capture app windows.")
                    permissionRow("Screen capture check", value: status.canCaptureScreen,
                                  detail: "Runtime confirmation that host screen capture is usable.")
                    Text("macOS grants attach to CuaDriver’s host identity, not to bighelp\(BighelpPlatform.isMac ? "" : " and not to this phone").")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                }

                ForEach(status.checks) { check in
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        LabeledContent(check.label, value: check.status.capitalized)
                        if !check.message.isEmpty {
                            Text(check.message).font(.bighelp(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }

                if let attribution = status.source?.attribution, !attribution.isEmpty {
                    LabeledContent("Permission source", value: attribution)
                }
                if let note = status.source?.note, !note.isEmpty {
                    Text(note).font(.bighelp(.caption)).foregroundStyle(.secondary)
                }
                if let error = status.errorSummary, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.bighelp(.footnote)).foregroundStyle(.orange)
                }

                Button("Refresh Host Status", systemImage: "arrow.clockwise") {
                    Task { await store.refreshComputerUse() }
                }
                .disabled(!store.ownsScope)

                if status.requiresMacHostInteraction && status.isInstalled {
                    Button("Review Host Permission Request", systemImage: "macwindow.badge.plus") {
                        store.prepareComputerUsePermissionRequest()
                    }
                    .disabled(!store.canAct)
                }
            } header: {
                Text("Advanced · Computer Use")
            } footer: {
                if status.hostPlatform == "darwin" {
                    Text("Requesting permissions only launches the supported CuaDriver flow. You must interact with macOS on the host. bighelp never reports that \(BighelpPlatform.isMac ? "it" : "iOS") granted Mac Accessibility or Screen Recording.")
                } else {
                    Text("Windows and Linux do not use the macOS TCC grant flow. Hermes reports CuaDriver health instead; bighelp does not manufacture a permission toggle.")
                }
            }
        }
    }

    @ViewBuilder
    private var grantSection: some View {
        if let receipt = store.grantReceipt {
            Section {
                HStack {
                    Text("CuaDriver permission flow")
                    Spacer()
                    grantStatusLabel(store.grantStatus)
                }
                Text("Continue on the host Mac. Approve the macOS dialogs attributed to CuaDriver, then return here and refresh.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Refresh Process") { Task { await store.refreshGrantStatus() } }
                        .buttonStyle(.bordered)
                    Button("Refresh Permissions") { Task { await store.refreshComputerUse() } }
                        .buttonStyle(.bordered)
                    Button("Dismiss") { store.dismissGrantReceipt() }
                        .buttonStyle(.bordered)
                }
                Text("Host process \(receipt.processID.formatted())\(receipt.wasAlreadyRunning ? " was already running." : " was started by Hermes.")")
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Host interaction required")
            } footer: {
                Text("A finished process is not proof of permission. Readiness is confirmed only by a later host Computer Use status response.")
            }
        }
    }

    @ViewBuilder
    private func terminalStatus(_ backend: HermesTerminalBackend) -> some View {
        if backend.isActive {
            Label("Selected", systemImage: "checkmark.circle.fill")
                .font(.bighelp(.caption)).foregroundStyle(.secondary)
        } else {
            switch backend.status {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle").font(.bighelp(.caption)).foregroundStyle(.green)
            case .needsSetup:
                Label("Needs setup", systemImage: "wrench.and.screwdriver").font(.bighelp(.caption)).foregroundStyle(.orange)
            case .unavailable:
                Label("Unavailable", systemImage: "nosign").font(.bighelp(.caption)).foregroundStyle(.red)
            }
        }
    }

    private func permissionRow(_ label: String, value: Bool?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            LabeledContent(label, value: readinessLabel(value))
            Text(detail).font(.bighelp(.caption)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func grantStatusLabel(_ status: HermesComputerUseGrantStatus?) -> some View {
        switch status?.phase {
        case .waitingForHostInteraction, nil:
            Label("Waiting on Mac", systemImage: "macwindow").font(.bighelp(.caption)).foregroundStyle(.orange)
        case .finished(let exitCode):
            Label(exitCode == 0 ? "Process finished" : "Process failed", systemImage: exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                .font(.bighelp(.caption)).foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
        case .outcomeUnknown:
            Label("Unknown", systemImage: "questionmark.circle").font(.bighelp(.caption)).foregroundStyle(.orange)
        }
    }

    private func readinessLabel(_ value: Bool?) -> String {
        switch value {
        case true: "Ready"
        case false: "Not ready"
        case nil: "Unknown"
        }
    }

    private func platformLabel(_ value: String) -> String {
        switch value {
        case "darwin": "macOS"
        case "win32": "Windows"
        case "linux": "Linux"
        default: value
        }
    }
}
