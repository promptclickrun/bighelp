import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct HostImportView: View {
    @Bindable var store: HostOperationsStore

    @State private var hostArchivePath = ""
    @State private var isSelectingArchive = false
    @State private var isReadingArchive = false
    @State private var selectionError: String?
    @State private var readTask: Task<Void, Never>?

    var body: some View {
        List {
            scopeSection
            messageSections
            impactSection
            hostPathSection
            uploadSection
            actionStatusSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Import Backup")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            readTask?.cancel()
            readTask = nil
            isReadingArchive = false
            store.cancelImportReview()
        }
        .fileImporter(
            isPresented: $isSelectingArchive,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            importSelectedArchive(result)
        }
        .bighelpSheet(item: Binding(
            get: { store.importReview },
            set: { if $0 == nil { store.cancelImportReview() } }
        )) { review in
            HostImportReviewView(store: store, review: review) {
                if case .hostPath = review.source { hostArchivePath = "" }
            }
            .bighelpSheetSize(.standard)
        }
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Original connection", value: store.hostName)
            LabeledContent("Selected profile", value: store.profileID)
            LabeledContent("Import target", value: store.operationTargetProfileID ?? "Not verified")
        } header: { Text("Destination") } footer: {
            Text("Import restores the profile used by the connected Hermes server, which may differ from the profile selected in bighelp. bighelp verifies that target before confirmation. Switching hosts invalidates the review.")
        }
    }

    @ViewBuilder
    private var messageSections: some View {
        if let selectionError {
            Section {
                Label(selectionError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Dismiss") { self.selectionError = nil }
            }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if store.importOutcomeNeedsReview {
            Section {
                Label("Import outcome remains uncertain", systemImage: "questionmark.diamond.fill")
                    .foregroundStyle(.orange)
                Text("Another import is disabled for this retained presentation. Refresh the original action receipt; do not select or resend the archive as a retry.")
            }
        }
        if store.operationTargetProfileID == nil {
            Section {
                Label("Serving profile not verified", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("bighelp could not verify which profile this Hermes server uses. Hooks and backup import remain unavailable until read-only discovery confirms the target; your selected profile is not used as a guess.")
            }
        }
    }

    private var impactSection: some View {
        Section {
            Label("Replaces host configuration, skills, sessions, databases, scheduled tasks, and other backup members.", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Label("May restore declared memory-provider files under the host user’s home folder.", systemImage: "folder.badge.gearshape")
            Label("May install or start a stopped messaging gateway after restore.", systemImage: "antenna.radiowaves.left.and.right")
            Text("bighelp never restarts hermes serve, never sends a separate gateway lifecycle request, and never retries an unconfirmed import.")
            DisclosureGroup("Technical limits") {
                Text("Hermes skips machine-specific runtime files and uses live-safe database restoration where possible. Partial per-file failure is reported through the background action status.")
                Text("The dashboard import endpoint has no dry run or archive-manifest review API.")
            }
        } header: {
            Text("Before you import")
        } footer: {
            Text("Review the source and destination here. Create a current backup first when you need a rollback point.")
        }
    }

    private var hostPathSection: some View {
        Section {
            TextField("Path to ZIP on the Hermes host", text: $hostArchivePath, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.bighelp(.body).monospaced())
                .privacySensitive()
            Button("Review Host Archive", systemImage: "doc.text.magnifyingglass") {
                store.reviewHostImport(path: hostArchivePath)
            }
            .disabled(!store.canPrepareImport || hostArchivePath.isEmpty)
            .frame(minHeight: BighelpTokens.hitTarget)
        } header: {
            Text("From the host")
        } footer: {
            Text("POST /api/ops/import accepts an existing host filesystem path. bighelp preserves the reviewed path exactly and does not offer arbitrary file operations.")
        }
    }

    private var uploadSection: some View {
        Section {
            Button(isReadingArchive ? "Reading Private ZIP…" : "Choose Private ZIP…", systemImage: "lock.doc") {
                selectionError = nil
                isSelectingArchive = true
            }
            .disabled(!store.canPrepareImport || isReadingArchive)
            .frame(minHeight: BighelpTokens.hitTarget)
        } header: {
            Text("From this device")
        } footer: {
            Text("The selected regular file must be a ZIP no larger than \(ByteCountFormatter.string(fromByteCount: Int64(DirectHermesHostOperationsClient.maximumImportUploadBytes), countStyle: .file)). Bytes stay in memory only through review and use the fixed authenticated multipart POST /api/ops/import-upload seam. No alternate route or implicit lifecycle request is allowed.")
        }
    }

    @ViewBuilder
    private var actionStatusSection: some View {
        if let receipt = store.importActionReceipt {
            Section {
                LabeledContent("Action", value: receipt.action.rawValue)
                LabeledContent("Status", value: importStatus(receipt))
                Text(receipt.admission == .actionSlotOnly
                     ? "This is the host’s named import action slot, not proof of which invocation occupied it."
                     : "The host acknowledged this import with a process/action receipt.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                Button("Refresh Import Status") { Task { await store.pollAction(receipt) } }
                    .disabled(!store.ownsScope)
            } header: {
                Text("Retained import receipt")
            } footer: {
                Text("Status polling is read-only. It never relaunches the import.")
            }
        }
    }

    private func importSelectedArchive(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            isReadingArchive = true
            readTask?.cancel()
            readTask = Task { await readSelectedArchive(url) }
        } catch {
            selectionError = "bighelp could not open that private ZIP selection. No file content was retained in the error."
        }
    }

    private func readSelectedArchive(_ url: URL) async {
        defer {
            isReadingArchive = false
            readTask = nil
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 else {
                throw HostOperationsError.invalidRequest
            }
            guard size <= DirectHermesHostOperationsClient.maximumImportUploadBytes else {
                throw HostOperationsError.importTooLarge
            }
            let bytes = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try Data(contentsOf: url)
            }.value
            try Task.checkCancellation()
            guard bytes.count == size else { throw HostOperationsError.invalidRequest }
            store.reviewUploadedImport(filename: url.lastPathComponent, bytes: bytes)
        } catch is CancellationError {
        } catch let error as HostOperationsError {
            selectionError = error.localizedDescription
        } catch {
            selectionError = "bighelp could not read that private ZIP. No file content was retained in the error."
        }
    }

    private func importStatus(_ receipt: HermesHostActionReceipt) -> String {
        switch store.actionStatuses[receipt.id]?.phase {
        case .running, nil: "Pending"
        case .succeeded: "Completed"
        case .failed(let code): "Failed (exit \(code))"
        case .outcomeUnknown: "Outcome unknown"
        }
    }
}

@MainActor
private struct HostImportReviewView: View {
    @Bindable var store: HostOperationsStore
    let review: HermesHostImportReview
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    LabeledContent("Original connection", value: review.hostName)
                    LabeledContent("Selected profile", value: review.selectedProfileID)
                    LabeledContent("Reviewed unscoped target", value: review.targetProfileID)
                    switch review.source {
                    case .hostPath(let path):
                        LabeledContent("Host archive") {
                            Text(path).font(.bighelp(.caption).monospaced()).multilineTextAlignment(.trailing)
                        }
                    case .uploadedFile(let name, let byteCount):
                        LabeledContent("Private file", value: name)
                        LabeledContent("Upload bytes", value: ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
                        LabeledContent("Fixed target", value: "POST /api/ops/import-upload")
                    }
                }
                .privacySensitive()

                Section("Final impact") {
                    Text("Target: the serving backend’s reviewed Hermes home (`\(review.targetProfileID)`) on the original connection. The endpoint receives `force=true` only after this confirmation because its spawned CLI has no interactive stdin.")
                    Text("Configuration, skills, sessions, databases, cron state, and other backup members may be overwritten. Some external memory-provider state can be restored under the host user’s home directory.")
                    Text("bighelp will retain the returned import action receipt and poll status without replay. If acknowledgement is lost, uploaded bytes are discarded and another import is disabled for this presentation.")
                    Text("bighelp sends no restart or start call. Hermes’ stock importer itself may ensure a stopped messaging gateway is installed/running after restore.")
                }
            }
            .navigationTitle("Review Backup Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.cancelImportReview()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isMutating)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import Reviewed Backup", role: .destructive) {
                        Task {
                            await store.launchReviewedImport()
                            if store.importReview == nil {
                                onFinished()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!store.canPrepareImport)
                }
            }
            .interactiveDismissDisabled(store.isMutating)
        }
    }
}
