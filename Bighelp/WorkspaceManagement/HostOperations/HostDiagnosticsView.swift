import SwiftUI

@MainActor
struct HostDiagnosticsView: View {
    @Bindable var store: HostOperationsStore

    @State private var diagnosticAction: HermesDiagnosticAction?
    @State private var confirmsShare = false

    var body: some View {
        List {
            Section {
                LabeledContent("Host", value: store.hostName)
                LabeledContent("Profile", value: store.profileID)
            } header: { Text("Workspace") } footer: {
                Text("This screen retains only bounded public system fields. It does not display environment values, host paths, raw logs, or diagnostic file contents.")
            }

            if let message = store.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Dismiss") { store.clearMessages() }
                }
            }
            if let message = store.successMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("Dismiss") { store.clearMessages() }
                }
            }

            if let stats = store.systemStats {
                identitySection(stats)
                capacitySections(stats)
            } else if store.isLoading {
                Section { ProgressView("Loading diagnostics…") }
            }

            if let egress = store.egress {
                Section("Egress") {
                    Text(egress.text)
                        .font(.bighelp(.footnote).monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                ForEach(HermesDiagnosticAction.allCases) { action in
                    Button(action.title, systemImage: icon(action)) {
                        diagnosticAction = action
                    }
                    .disabled(!store.canAct)
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            } header: { Text("Checks") } footer: {
                Text("Hermes runs these as background host actions. bighelp reads only completion status here; raw action logs are not imported into the app’s public diagnostics projection.")
            }

            Section {
                Button("Share Force-Redacted Diagnostics with Nous", systemImage: "lock.shield") {
                    // Fresh every time: no persisted or implied consent.
                    confirmsShare = true
                }
                .disabled(!store.canAct)
                .frame(minHeight: BighelpTokens.hitTarget)

                if let share = store.diagnosticsShare {
                    if let url = share.viewURL {
                        Link("Open Diagnostics Receipt", destination: url)
                    }
                    if let uploadID = share.uploadID {
                        LabeledContent("Upload ID", value: uploadID)
                            .textSelection(.enabled)
                    }
                    if let expiry = share.expiresAt {
                        LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            } header: {
                Text("Optional support share")
            } footer: {
                Text("This is an external upload to Nous support storage. Hermes forces redaction, but the bundle can still contain system and diagnostic context. bighelp asks for confirmation on every upload and never attaches extra client files automatically.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await store.refreshDiagnostics() }
        .confirmationDialog(
            diagnosticAction.map { "Run \($0.title)?" } ?? "Run host check?",
            isPresented: Binding(
                get: { diagnosticAction != nil },
                set: { if !$0 { diagnosticAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = diagnosticAction {
                Button("Run \(action.title)") {
                    diagnosticAction = nil
                    Task { await store.runDiagnostic(action) }
                }
            }
            Button("Cancel", role: .cancel) { diagnosticAction = nil }
        } message: {
            Text(diagnosticMessage)
        }
        .confirmationDialog(
            "Share redacted diagnostics with Nous?",
            isPresented: $confirmsShare,
            titleVisibility: .visible
        ) {
            Button("Share with Nous") { Task { await store.shareDiagnosticsWithNous() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will collect recent host diagnostics, force-redact secrets and email addresses, and upload the bundle to Nous support storage. bighelp sends no custom attachment and stores no standing consent.")
        }
    }

    private func identitySection(_ stats: HermesSystemStats) -> some View {
        Section("System") {
            LabeledContent("Operating system", value: [stats.operatingSystem, stats.operatingSystemRelease]
                .compactMap { $0 }.joined(separator: " "))
            LabeledContent("Architecture", value: stats.architecture)
            LabeledContent("Host name", value: stats.hostname)
            LabeledContent("Hermes", value: stats.hermesVersion)
            LabeledContent("Python", value: [stats.pythonImplementation, stats.pythonVersion]
                .compactMap { $0 }.joined(separator: " "))
            if let uptime = stats.uptimeSeconds {
                LabeledContent("System uptime", value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
            }
        }
    }

    @ViewBuilder
    private func capacitySections(_ stats: HermesSystemStats) -> some View {
        if let cpuCount = stats.cpuCount {
            Section("Compute") {
                LabeledContent("Logical CPUs", value: cpuCount.formatted())
                if let percent = stats.cpuPercent {
                    LabeledContent("CPU use", value: percent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                }
                if !stats.loadAverage.isEmpty {
                    LabeledContent("Load average", value: stats.loadAverage.map {
                        $0.formatted(.number.precision(.fractionLength(0...2)))
                    }.joined(separator: " / "))
                }
                if let process = stats.process {
                    LabeledContent("Hermes memory", value: bytes(process.residentBytes))
                    LabeledContent("Hermes threads", value: process.threadCount.formatted())
                }
            }
        }

        if let memory = stats.memory {
            capacitySection("Memory", value: memory)
        }
        if let disk = stats.disk {
            capacitySection("Hermes storage volume", value: disk)
        }

        if !stats.hasExtendedMetrics {
            Section {
                Label("Extended host metrics are unavailable because Hermes reported no psutil support.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capacitySection(_ title: String, value: HermesSystemStats.Capacity) -> some View {
        Section(title) {
            LabeledContent("Used", value: bytes(value.used))
            LabeledContent("Available", value: bytes(value.available))
            LabeledContent("Total", value: bytes(value.total))
            LabeledContent("Utilization", value: value.percent.formatted(.number.precision(.fractionLength(0...1))) + "%")
        }
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func icon(_ action: HermesDiagnosticAction) -> String {
        switch action {
        case .doctor: "stethoscope"
        case .securityAudit: "checkmark.shield"
        case .promptSize: "text.measurement"
        case .dump: "doc.text.magnifyingglass"
        case .configMigrate: "gearshape.2"
        }
    }

    private var diagnosticMessage: String {
        guard let action = diagnosticAction else { return "" }
        return switch action {
        case .configMigrate:
            "Hermes will run its supported configuration migration on the host. This may rewrite configuration defaults. Completion will be polled; the action is never retried automatically."
        case .dump:
            "Hermes will create its diagnostic dump on the host. bighelp will not download or upload the dump automatically."
        default:
            "Hermes will run this host check in the background. bighelp will poll its fixed action status and will not expose raw host logs."
        }
    }
}
