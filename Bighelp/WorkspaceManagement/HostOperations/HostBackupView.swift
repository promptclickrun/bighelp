import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct HostBackupView: View {
    @Bindable var store: HostOperationsStore

    @State private var confirmsBackup = false
    @State private var confirmsPrune = false
    @State private var exportDocument: HostBackupDocument?
    @State private var exportFilename = "hermes-backup.zip"
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Host", value: store.hostName)
                LabeledContent("Profile", value: store.profileID)
            } header: { Text("Workspace") } footer: {
                Text("Backups are created inside Hermes’ dashboard backup directory. bighelp can download only the archive path returned by its own confirmed backup receipt.")
            }

            if let message = store.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Dismiss") { store.clearMessages() }
                }
            }
            if let exportError {
                Section {
                    Label(exportError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Dismiss") { self.exportError = nil }
                }
            }

            backupSection
            checkpointSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backups & Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await store.refreshBackups() }
        .confirmationDialog(
            "Create a host backup?",
            isPresented: $confirmsBackup,
            titleVisibility: .visible
        ) {
            Button("Create Backup") { Task { await store.createBackup() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will create one timestamped ZIP in its managed dashboard backup directory. The immediate response admits a background action; bighelp waits for completion before enabling download.")
        }
        .confirmationDialog(
            "Prune rollback checkpoints?",
            isPresented: $confirmsPrune,
            titleVisibility: .visible
        ) {
            Button("Prune Checkpoints", role: .destructive) { Task { await store.pruneCheckpoints() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will apply its checkpoint-pruning policy to the host. Review the displayed session and storage totals first. This does not create a backup automatically.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .zip,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            store.clearDownloadedBackup()
            if case .failure = result {
                exportError = "The device did not save the backup. Hermes’ host archive was not deleted."
            }
        }
    }

    private var backupSection: some View {
        Section {
            Button("Create Backup", systemImage: "externaldrive.badge.plus") {
                confirmsBackup = true
            }
            .disabled(!store.canAct)
            .frame(minHeight: BighelpTokens.hitTarget)

            if let receipt = store.lastBackupReceipt {
                LabeledContent("Latest action", value: backupStatus(receipt))
                if store.canDownloadLastBackup {
                    Button("Download Latest Backup", systemImage: "arrow.down.doc") {
                        Task {
                            await store.downloadLastBackup()
                            guard let download = store.downloadedBackup else { return }
                            exportDocument = HostBackupDocument(data: download.bytes)
                            exportFilename = download.filename
                            isExporting = true
                        }
                    }
                    .disabled(!store.canAct)
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                Button("Refresh Backup Status") { Task { await store.pollAction(receipt) } }
                    .disabled(!store.ownsScope)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("The native download is bounded to 4 MB by the existing authenticated transport. Larger archives remain safely on the host and are reported as unavailable for native download rather than truncated.")
        }
    }

    @ViewBuilder
    private var checkpointSection: some View {
        if let checkpoints = store.checkpoints {
            Section {
                LabeledContent("Sessions", value: checkpoints.sessions.count.formatted())
                LabeledContent("Files", value: checkpoints.sessions.reduce(0) { $0 + $1.fileCount }.formatted())
                LabeledContent("Storage", value: bytes(checkpoints.totalBytes))

                if checkpoints.sessions.isEmpty {
                    ContentUnavailableView(
                        "No rollback checkpoints",
                        systemImage: "arrow.uturn.backward.circle",
                        description: Text("Hermes reported no checkpoint files to review."))
                } else {
                    DisclosureGroup("Per-session review") {
                        ForEach(checkpoints.sessions) { session in
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(session.id).font(.bighelp(.subheadline).monospaced()).textSelection(.enabled)
                                Text("\(session.fileCount.formatted()) files • \(bytes(session.bytes))")
                                    .font(.bighelp(.caption))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, BighelpTokens.space4)
                        }
                    }

                    Button("Prune Checkpoints", systemImage: "trash", role: .destructive) {
                        confirmsPrune = true
                    }
                    .disabled(!store.canAct)
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            } header: {
                Text("Advanced · Rollback checkpoints")
            } footer: {
                Text("This inventory is read-only. Pruning uses Hermes’ supported background action and refreshes the inventory only after a terminal result.")
            }
        } else if store.isLoading {
            Section { ProgressView("Loading checkpoint inventory…") }
        } else {
            Section {
                ContentUnavailableView(
                    "Checkpoint inventory unavailable",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Pull to refresh this host’s public checkpoint summary."))
            }
        }
    }

    private func backupStatus(_ receipt: HermesHostActionReceipt) -> String {
        switch store.actionStatuses[receipt.id]?.phase {
        case .running, nil: "Pending"
        case .succeeded: "Completed"
        case .failed(let code): "Failed (exit \(code))"
        case .outcomeUnknown: "Outcome unknown"
        }
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

private struct HostBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              HostBackupDocument.hasZIPSignature(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    private static func hasZIPSignature(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let signature = Array(data.prefix(4))
        return signature == [0x50, 0x4b, 0x03, 0x04]
            || signature == [0x50, 0x4b, 0x05, 0x06]
            || signature == [0x50, 0x4b, 0x07, 0x08]
    }
}
