import SwiftUI

@MainActor
struct CuratorView: View {
    @Bindable var store: MemoryGraphStore
    @State private var showingRunConfirmation = false

    var body: some View {
        List {
            MemoryOperationMessages(store: store)

            if let curator = store.curator {
                Section {
                    LabeledContent("Host", value: store.hostName)
                    LabeledContent("Curator", value: curator.isEnabled ? (curator.isPaused ? "Paused" : "Active") : "Disabled by Hermes")
                    if let lastRunAt = curator.lastRunAt {
                        LabeledContent("Last started", value: lastRunAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("Last started", value: "Not reported")
                    }
                } header: {
                    Text("Overview")
                } footer: {
                    Text("Curator maintains learned skills using this host’s configuration.")
                }

                Section("Automatic") {
                    Toggle("Pause automatic curation", isOn: Binding(
                        get: { store.curator?.isPaused ?? false },
                        set: { paused in Task { await store.setCuratorPaused(paused) } }
                    ))
                    .disabled(!curator.isEnabled || store.isMutating)
                }

                Section("Advanced · Schedule") {
                    if let interval = curator.intervalHours {
                        LabeledContent("Review interval", value: duration(hours: interval))
                    }
                    if let idle = curator.minimumIdleHours {
                        LabeledContent("Minimum idle time", value: duration(hours: idle))
                    }
                    if let stale = curator.staleAfterDays {
                        LabeledContent("Mark stale after", value: days(stale))
                    }
                    if let archive = curator.archiveAfterDays {
                        LabeledContent("Archive after", value: days(archive))
                    }
                }

                Section {
                    Button("Start Curator", systemImage: "wand.and.stars") {
                        showingRunConfirmation = true
                    }
                    .disabled(!curator.isEnabled || store.isMutating)
                } footer: {
                    Text("Starting confirms only that Hermes launched the background review, not that it completed or changed anything.")
                }

                Section {
                    Label("Mark inactive skills stale", systemImage: "clock.badge.exclamationmark")
                    Label("Archive eligible skills for later restoration", systemImage: "archivebox")
                    Label("Preserve pinned and scheduled skills", systemImage: "pin")
                } header: { Text("Before you run") } footer: {
                    Text("Curator archives skills instead of deleting them. Memory chunks remain separate in Knowledge.")
                }
            } else if store.isLoading {
                Section { ProgressView("Loading Curator status…") }
            } else {
                Section {
                    ContentUnavailableView(
                        "Curator status unavailable",
                        systemImage: "wand.and.stars.inverse",
                        description: Text("Refresh Memory to ask Hermes for its current Curator state."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .bighelpRefreshable { await store.refresh() }
        .confirmationDialog(
            "Run Curator on this Hermes host?",
            isPresented: $showingRunConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run Curator") { Task { await store.runCurator() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Curator may mark, archive, consolidate, or update eligible skills according to the host’s configuration. The action runs in the background and may outlive this screen.")
        }
    }

    private func duration(hours: Double) -> String {
        guard hours.rounded() == hours else { return "\(hours.formatted()) hours" }
        let value = Int(hours)
        return value == 1 ? "1 hour" : "\(value.formatted()) hours"
    }

    private func days(_ value: Double) -> String {
        guard value.rounded() == value else { return "\(value.formatted()) days" }
        let count = Int(value)
        return count == 1 ? "1 day" : "\(count.formatted()) days"
    }
}
