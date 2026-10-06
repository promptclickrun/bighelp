import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct WorkspaceFileTransferView: View {
    @Bindable var store: WorkspaceFileTransferStore

    @State private var isImporting = false
    @State private var isCreatingDirectory = false
    @State private var newDirectoryName = ""
    @State private var exportDocument: WorkspaceManagedFileDocument?
    @State private var exportName = "download"
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var mediaPlayback: DirectHermesManagedMediaPlayback?

    var body: some View {
        Group {
            if store.ownsScope {
                fileList
            } else {
                ContentUnavailableView(
                    "Workspace changed",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Return to Workspace and open Files for the current host.")
                )
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await store.importAndUpload(url) }
            case .failure:
                exportError = "The selected file could not be opened by the system file picker."
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportDocument?.contentType ?? .data,
            defaultFilename: exportName
        ) { result in
            exportDocument = nil
            if case .failure = result {
                exportError = "The downloaded file was verified, but the device did not export a copy."
            }
        }
        .bighelpSheet(item: $mediaPlayback) { playback in
            WorkspaceManagedMediaView(playback: playback)
                .bighelpSheetSize(.large)
        }
        .alert("New Folder", isPresented: $isCreatingDirectory) {
            TextField("Folder name", text: $newDirectoryName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                let name = newDirectoryName
                newDirectoryName = ""
                Task { await store.createDirectory(named: name) }
            }
            Button("Cancel", role: .cancel) { newDirectoryName = "" }
        } message: {
            Text("Create one folder inside \(store.directory.path).")
        }
        .confirmationDialog(
            "Delete selected file?",
            isPresented: Binding(
                get: { store.deleteCandidate != nil },
                set: { if !$0 { store.cancelDelete() } }
            ),
            titleVisibility: .visible
        ) {
            if let candidate = store.deleteCandidate {
                Button("Delete \(candidate.name)", role: .destructive) {
                    Task { await store.confirmDelete() }
                }
            }
            Button("Cancel", role: .cancel) { store.cancelDelete() }
        } message: {
            if let candidate = store.deleteCandidate {
                Text("Permanently delete only this selected file from Hermes?\n\(candidate.path)")
            }
        }
        .alert("File Transfer", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .accessibilityIdentifier("workspace.file-transfers")
    }

    private var fileList: some View {
        List {
            locationSection
            statusSections
            directorySection
            selectedFileSection
            constraintsSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .toolbar { toolbar }
    }

    private var locationSection: some View {
        Section("Location") {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Workspace folder") {
                Text(store.workspaceRootLabel)
                    .font(.bighelp(.caption).monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if !store.directory.path.isEmpty, store.directory.path != store.workspaceRoot {
                LabeledContent("Folder") {
                    Text(store.directory.path)
                        .font(.bighelp(.caption).monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if store.directory.parent != nil {
                Button("Parent Folder", systemImage: "arrow.up.to.line") {
                    Task { await store.goUp() }
                }
                .disabled(!store.canAct)
                .frame(minHeight: BighelpTokens.hitTarget)
            }
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if store.isLoading {
            Section { ProgressView("Refreshing managed files…") }
        }
        if store.isTransferring {
            Section { ProgressView("Verifying file operation…") }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { store.clearMessages() }
            }
            .accessibilityIdentifier("workspace.file-transfers.error")
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    private var directorySection: some View {
        Section {
            if store.directory.files.isEmpty, !store.isLoading {
                ContentUnavailableView(
                    store.workspaceRoot == nil ? "Workspace folder unavailable" : "No managed files",
                    systemImage: "folder",
                    description: Text(store.workspaceRoot == nil
                        ? "bighelp shows files only from the folder this agent works in, and this computer hasn't confirmed it."
                        : "Upload a file or create a folder inside this host’s configured workspace.")
                )
            }
            ForEach(store.directory.files) { file in
                Button {
                    if file.isDirectory {
                        Task { await store.open(file) }
                    } else {
                        store.select(file)
                    }
                } label: {
                    WorkspaceManagedFileRow(
                        file: file,
                        selected: store.selectedFile == file
                    )
                }
                .buttonStyle(.plain)
                .disabled(!store.canAct)
                .accessibilityHint(file.isDirectory ? "Opens this folder" : "Selects this file for playback, download, sharing, export, or deletion")
            }
        } header: {
            Text("Contents")
        } footer: {
            Text("Files are limited to this host’s configured workspace.")
        }
    }

    @ViewBuilder
    private var selectedFileSection: some View {
        if let file = store.selectedFile {
            Section {
                LabeledContent("Selected", value: file.name)
                LabeledContent("Size", value: file.byteCount.map(Self.bytes) ?? "Unknown")
                LabeledContent("Modified", value: file.modifiedAt.formatted(date: .abbreviated, time: .shortened))

                if DirectHermesManagedMediaPlayback.supports(file) {
                    Button(
                        file.mimeType?.lowercased().hasPrefix("video/") == true ? "Preview Video" : "Play Audio",
                        systemImage: "play.circle"
                    ) {
                        mediaPlayback = store.mediaPlayback(for: file)
                    }
                    .disabled(!store.canPlay(file))
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("workspace.file-transfers.play-media")
                }

                Button("Download & Verify", systemImage: "arrow.down.doc") {
                    Task { await store.downloadSelected() }
                }
                .disabled(!store.canAct)
                .frame(minHeight: BighelpTokens.hitTarget)

                if let export = store.export, export.contents.file == file {
                    ShareLink(
                        item: export.privateURL,
                        preview: SharePreview(export.fileName)
                    ) {
                        Label("Share Verified Copy", systemImage: "square.and.arrow.up")
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .accessibilityHint("Opens the private native share sheet for the verified downloaded bytes")

                    Button("Export Verified Copy", systemImage: "folder.badge.plus") {
                        exportDocument = WorkspaceManagedFileDocument(
                            data: export.contents.bytes,
                            mimeType: export.mimeType
                        )
                        exportName = export.fileName
                        isExporting = true
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }

                Button("Delete Selected File", systemImage: "trash", role: .destructive) {
                    store.prepareDelete(file)
                }
                .disabled(!store.canAct)
                .frame(minHeight: BighelpTokens.hitTarget)
            } header: {
                Text("Selected file")
            } footer: {
                Text("Actions apply only to the selected file.")
            }
        }
    }

    private var constraintsSection: some View {
        Section {
            if store.supportsLargeTransfers {
                LabeledContent(
                    "Upload & download",
                    value: "Up to \(Self.bytes(DirectHermesManagedFilesClient.maximumNativeTransferBytes))"
                )
            } else {
                LabeledContent(
                    "Upload",
                    value: "Up to \(Self.bytes(DirectHermesManagedFilesClient.maximumJSONUploadBytes))"
                )
                LabeledContent(
                    "Download",
                    value: "Up to \(Self.bytes(DirectHermesManagedFilesClient.maximumJSONDownloadBytes))"
                )
            }
            LabeledContent(
                "Audio & video playback",
                value: store.supportsMediaPlayback ? "Available" : "Unavailable"
            )
        } header: {
            Text("Advanced · Host limits")
        } footer: {
            Text("Availability reflects the currently selected host connection.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("New Folder", systemImage: "folder.badge.plus") {
                isCreatingDirectory = true
            }
            .disabled(!store.canAct)

            Button("Upload", systemImage: "arrow.up.doc") {
                isImporting = true
            }
            .disabled(!store.canAct)

            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refresh() }
            }
            .disabled(!store.canRefresh)
        }
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

private struct WorkspaceManagedFileRow: View {
    let file: HermesManagedFile
    let selected: Bool

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(file.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: BighelpTokens.space8) {
                    if let count = file.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))
                    }
                    if let mime = file.mimeType { Text(mime) }
                }
                .font(.bighelp(.caption))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: BighelpTokens.space8)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var symbol: String {
        if file.isDirectory { return "folder.fill" }
        guard let type = file.mimeType else { return "doc" }
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.contains("zip") || type.contains("archive") || type.contains("compressed") {
            return "archivebox"
        }
        return "doc"
    }

    private var accessibilityLabel: String {
        let kind = file.isDirectory ? "Folder" : "File"
        let size = file.byteCount.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? "size unavailable"
        return "\(file.name), \(kind), \(size)"
    }
}

private struct WorkspaceManagedFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data
    let contentType: UTType

    init(data: Data, mimeType: String) {
        self.data = data
        contentType = UTType(mimeType: mimeType) ?? .data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
