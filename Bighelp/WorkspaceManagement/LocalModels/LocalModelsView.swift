import SwiftUI

@MainActor
struct LocalModelsView: View {
    @Bindable var store: LocalModelsStore

    @State private var searchQuery = ""
    @State private var hostModelPath = ""

    var body: some View {
        List {
            scopeSection
            messageSections

            switch store.support {
            case .unknown:
                Section { ProgressView("Checking host Local Models support…") }
            case .unavailable(let reason):
                Section {
                    ContentUnavailableView("Local Models unavailable", systemImage: "cpu", description: Text(reason))
                } footer: {
                    Text("Models run on the selected Hermes host, never on this device.")
                }
            case .available:
                runtimeSection
                stagedModelsSection
                catalogSection
                hardwareSection
                jobsSection
                browserSection
                sideloadSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Local Models")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await store.refresh() }
        .task { if store.status == nil { await store.load() } }
        .confirmationDialog(
            store.review?.title ?? "Review host change",
            isPresented: Binding(
                get: { store.review != nil },
                set: { if !$0 { store.review = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let review = store.review {
                Button(review.buttonTitle, role: review.isDestructive ? .destructive : nil) {
                    Task { await store.confirm(review) }
                }
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
        } header: {
            Text("Applies to")
        } footer: {
            Text("Runtime, network, disk, and memory changes occur on this host.")
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
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    @ViewBuilder
    private var runtimeSection: some View {
        if let status = store.status {
            Section {
                LabeledContent("Runtime", value: status.isRuntimeInstalled ? "Installed" : "Not installed")
                LabeledContent("Build", value: status.runtimeTag)
                if let backend = status.runtimeBackend {
                    LabeledContent("Backend", value: backend)
                }
                LabeledContent("Server", value: status.isServerRunning ? "Running" : "Stopped")
                LabeledContent("Automatic start", value: status.isEnabled ? "Enabled" : "Disabled")
                if status.isRuntimeUpdateAvailable {
                    Label("A newer configured runtime build is available to install.", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
                if let active = status.activeModelID {
                    LabeledContent("New-chat default", value: active)
                }
                if status.isRuntimeInstalled {
                    Button(status.isServerRunning ? "Review Stop Server" : "Review Start Server",
                           systemImage: status.isServerRunning ? "stop.circle" : "play.circle") {
                        store.prepareServer(status.isServerRunning ? .stop : .start)
                    }
                    .disabled(!store.canAct)
                }
                Button(status.isRuntimeInstalled ? "Review Runtime Update" : "Review Runtime Install",
                       systemImage: "shippingbox.and.arrow.backward") {
                    store.prepareInstallRuntime()
                }
                .disabled(!store.canAct)
            } header: {
                Text("Runtime")
            } footer: {
                Text("Starting an installed server does not load a model immediately. Models become resident on first inference; Stop unloads all models and disables automatic start.")
            }
        }
    }

    @ViewBuilder
    private var hardwareSection: some View {
        if let hardware = store.hardware {
            Section("Advanced · Host capacity") {
                if let name = hardware.gpuName { LabeledContent("GPU", value: name) }
                LabeledContent("Memory architecture", value: hardware.usesUnifiedMemory ? "Unified" : "Discrete")
                LabeledContent("Total VRAM", value: LocalModelsStore.byteLabel(hardware.totalVRAMBytes))
                LabeledContent("Usable VRAM", value: LocalModelsStore.byteLabel(hardware.usableVRAMBytes))
                LabeledContent("Available RAM", value: LocalModelsStore.byteLabel(hardware.availableRAMBytes))
                if let utilization = hardware.gpuUtilizationPercent {
                    LabeledContent("GPU utilization", value: "\(utilization)%")
                }
                if let used = hardware.usedVRAMBytes {
                    LabeledContent("VRAM in use", value: LocalModelsStore.byteLabel(used))
                }
            }
        }
    }

    @ViewBuilder
    private var jobsSection: some View {
        if !store.jobs.isEmpty {
            Section("Advanced · Recent jobs") {
                ForEach(store.jobs) { job in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            Text(job.target).font(.bighelp(.headline))
                            Spacer()
                            jobState(job)
                        }
                        Text(job.phase.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.bighelp(.caption))
                            .foregroundStyle(.secondary)
                        if !job.detail.isEmpty {
                            Text(job.detail).font(.bighelp(.footnote)).foregroundStyle(.secondary)
                        }
                        if let total = job.totalBytes, total > 0 {
                            ProgressView(value: Double(min(job.completedBytes, total)), total: Double(total))
                            Text("\(LocalModelsStore.byteLabel(job.completedBytes)) of \(LocalModelsStore.byteLabel(total))")
                                .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        } else if job.state == .running {
                            ProgressView()
                        }
                        Button("Refresh Job") { Task { await store.refreshJob(job) } }
                            .buttonStyle(.bordered)
                            .disabled(!store.ownsScope)
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            }
        }
    }

    @ViewBuilder
    private var stagedModelsSection: some View {
        if let status = store.status {
            Section {
                if status.stagedModels.isEmpty {
                    Text("No managed models are downloaded on this host.").foregroundStyle(.secondary)
                }
                ForEach(status.stagedModels) { model in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(model.id).font(.bighelp(.headline))
                                Text(model.sizeLabel).font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if status.activeModelID == model.id {
                                Label("Default", systemImage: "checkmark.circle.fill").font(.bighelp(.caption))
                            }
                        }
                        if let resident = status.loadedModels[model.id] {
                            LabeledContent("Memory", value: resident.capitalized)
                            if let placement = status.placements[model.id] {
                                Text(placementText(placement)).font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        } else if let loading = status.loadingModels[model.id] {
                            ProgressView(value: loading.percent, total: 100)
                            Text("Loading: \(loading.stage) • \(loading.percent.formatted(.number.precision(.fractionLength(0))))%")
                                .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Memory", value: "Not resident")
                        }
                        HStack {
                            Button("Review Use") { store.prepareActivate(model) }
                                .bighelpProminentButtonStyle()
                                .disabled(!store.canAct || status.activeModelID == model.id)
                            if status.loadedModels[model.id] != nil || status.loadingModels[model.id] != nil {
                                Button("Review Eject") { store.prepareEject(model) }
                                    .buttonStyle(.bordered)
                                    .disabled(!store.canAct)
                            }
                            Button("Review Delete", role: .destructive) { store.prepareDelete(model) }
                                .buttonStyle(.bordered)
                                .disabled(!store.canAct)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            } header: {
                Text("Managed models")
            } footer: {
                Text("Use changes the new-chat default and starts the host server if needed. It does not claim that the model is already loaded into memory.")
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        if !store.catalog.isEmpty {
            Section {
                if let recommended = store.catalog.first(where: \.isRecommended) {
                    Button("Review Quickstart with \(recommended.displayName)") {
                        store.prepareQuickstart(recommended)
                    }
                    .disabled(!store.canAct || !recommended.fitsHost || recommended.needsNewerRuntime)
                }
                ForEach(store.catalog) { model in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.displayName).font(.bighelp(.headline))
                            Spacer()
                            if model.isRecommended { Label("Recommended", systemImage: "star.fill").font(.bighelp(.caption)) }
                        }
                        if !model.summary.isEmpty { Text(model.summary).font(.bighelp(.footnote)) }
                        Text("\(model.sizeLabel) • \(model.nativeContextLabel) native context")
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        Label(model.fitSummary, systemImage: model.fitsHost ? "checkmark.circle" : "xmark.circle")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(model.fitsHost ? Color.secondary : Color.orange)
                        if let detail = model.fitDetail {
                            Text(detail).font(.bighelp(.caption)).foregroundStyle(.secondary)
                        }
                        if model.needsNewerRuntime {
                            Text("Requires \(model.minimumRuntime ?? "a newer llama.cpp runtime") before download or use.")
                                .font(.bighelp(.caption)).foregroundStyle(.orange)
                        }
                        if model.isDownloaded {
                            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Button("Review \(model.sizeLabel) Download") { store.prepareDownload(model) }
                                .buttonStyle(.bordered)
                                .disabled(!store.canAct || !model.fitsHost || model.needsNewerRuntime)
                        }
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            } header: {
                Text("Model catalog")
            } footer: {
                Text("Hermes computes fit and download size for this host. Downloads require review before network or disk use.")
            }
        }
    }

    private var browserSection: some View {
        Section {
            TextField("Search Hugging Face GGUF repositories", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await store.search(searchQuery) } }
                .accessibilityIdentifier("local-models.search")
            Button("Search") { Task { await store.search(searchQuery) } }
                .disabled(!store.canAct || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            ForEach(store.searchResults) { result in
                Button {
                    Task { await store.loadRepository(result.repository) }
                } label: {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(result.repository)
                        Text("\(result.downloads.formatted()) downloads • \(result.likes.formatted()) likes\(result.isGated ? " • gated" : "")")
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }

            if let repository = store.selectedRepository {
                ForEach(store.repositoryFiles) { group in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Text(group.label).font(.bighelp(.headline))
                        Text("\(LocalModelsStore.byteLabel(group.totalBytes)) • \(fitLabel(group.fit))")
                            .font(.bighelp(.caption))
                            .foregroundStyle(group.fit == .tooBig ? Color.orange : Color.secondary)
                        Button("Review Download") {
                            store.prepareBrowsedDownload(repository: repository, group: group)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!store.canAct || group.fit == .tooBig)
                    }
                    .padding(.vertical, BighelpTokens.space4)
                }
            }

            if store.isSearching { ProgressView("Reading host model catalog…") }
        } header: {
            Text("Advanced · Browse models")
        } footer: {
            Text("Search runs on Hermes. bighelp sends only selected GGUF paths and never runs repository code.")
        }
    }

    private var sideloadSection: some View {
        Section {
            TextField("Absolute .gguf path on the host", text: $hostModelPath, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("local-models.sideload-path")
            Button("Review Host File Registration") { store.prepareSideload(hostPath: hostModelPath) }
                .disabled(!store.canAct || !hostModelPath.lowercased().hasSuffix(".gguf"))
        } header: {
            Text("Advanced · Register host file")
        } footer: {
            Text("The path must already exist on the host. Hermes validates the .gguf file before linking or copying it.")
        }
    }

    @ViewBuilder
    private func jobState(_ job: HermesLocalRuntimeJob) -> some View {
        switch job.state {
        case .running:
            Label("Running", systemImage: "clock").font(.bighelp(.caption)).foregroundStyle(.secondary)
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill").font(.bighelp(.caption)).foregroundStyle(.green)
        case .error:
            Label("Failed", systemImage: "xmark.circle.fill").font(.bighelp(.caption)).foregroundStyle(.red)
        }
    }

    private func placementText(_ placement: HermesLocalModelPlacement) -> String {
        var parts: [String] = []
        if let granted = placement.grantedWindowLabel ?? placement.windowLabel { parts.append("\(granted) context") }
        if placement.isSpilled == true { parts.append("uses system-memory spill") }
        return parts.isEmpty ? "Resident on the host" : parts.joined(separator: " • ")
    }

    private func fitLabel(_ fit: HermesLocalModelFileGroup.Fit) -> String {
        switch fit {
        case .fitsGPU: "Fits GPU"
        case .needsRAM: "Uses system RAM"
        case .tooBig: "Too large for this host"
        case .unknown: "Fit unknown"
        }
    }
}
