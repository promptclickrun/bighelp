import CryptoKit
import Foundation
import Observation
import SwiftUI

/// A direct, read-only index of one host-reported configured workspace.
/// Directory responses are followed only while their resolved paths and
/// managed-files policy remain inside that owner-bound scope.
@MainActor
@Observable
final class WorkspaceArtifactsStore {
    typealias ScopeValidator = @MainActor () async throws -> DirectHermesWorkspaceFileScope
    let hostName: String
    private(set) var files: [WorkspaceFileListing.Entry] = []
    private(set) var scanDiagnostics: [WorkspaceArtifactScanDiagnostic] = []
    private(set) var isLoading = false
    /// True when the host listed what the agent made (plugin 2.15+) rather
    /// than the app scanning folders itself.
    private(set) var isAgentIndex = false
    private(set) var isOpening = false
    private(set) var errorMessage: String?
    private(set) var openErrorMessage: String?
    private(set) var openedAttachment: ChatAttachment?

    @ObservationIgnored private let owner: WorkspaceOwner
    @ObservationIgnored private let scope: DirectHermesWorkspaceFileScope?
    @ObservationIgnored private let scopeValidator: ScopeValidator?
    @ObservationIgnored private let suppliedScopeOwnerMismatch: Bool
    @ObservationIgnored private let performer: any WorkspaceOperationPerforming
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var openGeneration = UUID()
    @ObservationIgnored private var isRetired = false

    init(
        hostName: String,
        owner: WorkspaceOwner,
        scope: DirectHermesWorkspaceFileScope? = nil,
        performer: any WorkspaceOperationPerforming,
        scopeValidator: WorkspaceArtifactsStore.ScopeValidator? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.owner = owner
        suppliedScopeOwnerMismatch = scope != nil && scope?.owner != owner
        self.scope = scope?.owner == owner ? scope : nil
        self.performer = performer
        self.scopeValidator = scopeValidator
        self.isCurrent = isCurrent
    }

    var ownsOwner: Bool {
        !isRetired && isCurrent() && performer.owner == owner
    }
    var ownsScope: Bool { ownsOwner && scope?.owner == owner && scopeValidator != nil }
    var workspaceRoot: String? { scope?.root }
    var scopeUnavailableReason: String {
        suppliedScopeOwnerMismatch
            ? "Artifacts are unavailable because the supplied workspace boundary belongs to a different host or connection generation. Reopen Artifacts for the current workspace."
            : "This host has not confirmed its configured workspace. Update its bighelp plugin and check the workspace folder in Hermes settings."
    }

    func retire() {
        isRetired = true
        refreshGeneration = UUID()
        openGeneration = UUID()
        isLoading = false
        isOpening = false
        openedAttachment = nil
    }

    func refresh() async {
        guard ownsScope, scope != nil, !Task.isCancelled else { return }
        let request = UUID()
        refreshGeneration = request
        openGeneration = UUID()
        isOpening = false
        isLoading = true
        errorMessage = nil
        openErrorMessage = nil
        defer {
            if refreshGeneration == request { isLoading = false }
        }

        do {
            let next = try await loadTree(request: request)
            guard canPublishRefresh(request) else { return }
            files = next.files
            scanDiagnostics = next.diagnostics
        } catch is CancellationError {
            // Navigation and superseded refreshes do not become host failures.
        } catch {
            guard canPublishRefresh(request) else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func open(_ entry: WorkspaceFileListing.Entry) async {
        guard ownsScope, let scope, !Task.isCancelled, !entry.isDirectory else { return }
        guard scope.contains(entry.path) else {
            openErrorMessage = WorkspaceManagementError.fileRootNotConfined.localizedDescription
            return
        }
        guard let size = entry.size, (1...ChatAttachment.maximumAgentBytes).contains(size) else {
            openErrorMessage = "This file cannot be opened in bighelp because its size is empty, unknown, or above the native preview limit."
            return
        }

        let request = UUID()
        let listingGeneration = refreshGeneration
        openGeneration = request
        isOpening = true
        openErrorMessage = nil
        defer {
            if openGeneration == request { isOpening = false }
        }

        do {
            let parent = try scope.parent(of: entry.path)
            try await validateScope()
            guard canPublishOpen(request, listingGeneration: listingGeneration) else { return }
            let verificationPayload = try await performer.perform(
                .filesList,
                payload: ["path": .string(parent)],
                owner: owner
            )
            guard canPublishOpen(request, listingGeneration: listingGeneration) else { return }
            let verification = try scope.artifactEnumerationDirectory(
                verificationPayload,
                expectedPath: parent
            )
            guard verification.listing.entries.contains(entry) else {
                throw WorkspaceManagementError.fileRootNotConfined
            }
            let payload = try await performer.perform(
                .filesRead,
                payload: ["path": .string(entry.path)],
                owner: owner
            )
            guard canPublishOpen(request, listingGeneration: listingGeneration) else { return }
            openedAttachment = try Self.attachment(payload, entry: entry, scope: scope)
        } catch is CancellationError {
        } catch {
            guard canPublishOpen(request, listingGeneration: listingGeneration) else { return }
            openErrorMessage = Self.message(for: error, opening: true)
        }
    }

    func closeAttachment() {
        openedAttachment = nil
    }

    private func loadTree(request: UUID) async throws -> WorkspaceArtifactIndex {
        guard let scope else { throw DirectHermesManagedFilesError.scopeUnavailable }
        try await validateScope()
        do {
            let index = try await WorkspaceArtifactTreeEnumerator.loadRecent(
                scope: scope, owner: owner, performer: performer)
            guard canPublishRefresh(request) else { throw CancellationError() }
            isAgentIndex = true
            return index
        } catch is CancellationError {
            throw CancellationError()
        } catch where WorkspaceArtifactTreeEnumerator.mustAbort(for: error) {
            throw error
        } catch {
            // An older plugin can't list recent files: scan a few folders instead.
        }
        guard canPublishRefresh(request) else { throw CancellationError() }
        isAgentIndex = false
        return try await WorkspaceArtifactTreeEnumerator.load(
            scope: scope,
            owner: owner,
            performer: performer,
            canContinue: { self.canPublishRefresh(request) },
            onProgress: { partial in
                guard self.canPublishRefresh(request) else { return }
                self.files = partial
            }
        )
    }

    private func validateScope() async throws {
        guard ownsScope, let scope, let scopeValidator else {
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        let current = try await scopeValidator()
        guard ownsScope, current.owner == owner,
              DirectHermesWorkspaceFileScope.samePath(current.root, scope.root), current == scope else {
            throw DirectHermesManagedFilesError.scopeChanged
        }
    }

    private func canPublishRefresh(_ request: UUID) -> Bool {
        ownsScope && refreshGeneration == request && !Task.isCancelled
    }

    private func canPublishOpen(_ request: UUID, listingGeneration: UUID) -> Bool {
        ownsScope && openGeneration == request && refreshGeneration == listingGeneration && !Task.isCancelled
    }


    private static func attachment(
        _ payload: [String: BighelpJSONValue],
        entry: WorkspaceFileListing.Entry,
        scope: DirectHermesWorkspaceFileScope
    ) throws -> ChatAttachment {
        try scope.validatePolicy(payload)
        guard let rawPath = payload["path"]?.string else {
            throw WorkspaceManagementError.invalidResponse
        }
        let responsePath = try scope.require(rawPath)
        guard DirectHermesWorkspaceFileScope.samePath(responsePath, entry.path),
              let size = payload["size"]?.integer,
              size == entry.size,
              (1...ChatAttachment.maximumAgentBytes).contains(size),
              let dataURL = payload["data_url"]?.string,
              dataURL.utf8.count <= ((ChatAttachment.maximumAgentBytes + 2) / 3) * 4 + 512,
              let separator = dataURL.range(of: ";base64,"),
              dataURL.hasPrefix("data:") else {
            throw WorkspaceManagementError.invalidResponse
        }

        let mimeStart = dataURL.index(dataURL.startIndex, offsetBy: 5)
        let mimeType = String(dataURL[mimeStart..<separator.lowerBound]).lowercased()
        guard payload["mime_type"]?.string?.lowercased() == mimeType,
              entry.mimeType == nil || entry.mimeType == mimeType,
              let data = Data(base64Encoded: String(dataURL[separator.upperBound...])),
              data.count == size else {
            throw WorkspaceManagementError.invalidResponse
        }

        let digest = SHA256.hash(data: Data((entry.path + "\0" + entry.name).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try .agentArtifact(
            id: "artifact_" + digest,
            fileName: entry.name,
            mimeType: mimeType,
            data: data
        )
    }

    private static func message(for error: any Error, opening: Bool = false) -> String {
        if let error = error as? WorkspaceManagementError { return error.localizedDescription }
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        if let error = error as? DirectHermesManagedFilesError { return error.localizedDescription }
        return opening
            ? "This file could not be opened from Hermes. Check the connection and try again."
            : "The configured workspace file index could not be refreshed. Check the connection and try again."
    }
}

@MainActor
struct WorkspaceArtifactsView: View {
    @State private var store: WorkspaceArtifactsStore
    @State private var search = ""
    /// Inside the agent home's Apps tab: no navigation title, toolbar or
    /// system search bar, which would land in the root navigation bar.
    var isEmbedded = false

    init(
        hostName: String,
        owner: WorkspaceOwner,
        scope: DirectHermesWorkspaceFileScope? = nil,
        performer: any WorkspaceOperationPerforming,
        scopeValidator: WorkspaceArtifactsStore.ScopeValidator? = nil,
        isCurrent: @escaping @MainActor () -> Bool,
        isEmbedded: Bool = false
    ) {
        self.isEmbedded = isEmbedded
        _store = State(initialValue: WorkspaceArtifactsStore(
            hostName: hostName,
            owner: owner,
            scope: scope,
            performer: performer,
            scopeValidator: scopeValidator,
            isCurrent: isCurrent
        ))
    }

    private var visibleFiles: [WorkspaceFileListing.Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.files }
        return store.files.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
                || ($0.mimeType?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if !store.ownsOwner {
                WorkspaceUnavailableView(
                    destination: .artifacts,
                    hostName: store.hostName,
                    reason: "This workspace is no longer selected. Return to Workspace to open the current host."
                )
            } else if store.ownsScope {
                content
            } else {
                WorkspaceUnavailableView(
                    destination: .artifacts,
                    hostName: store.hostName,
                    reason: store.scopeUnavailableReason
                )
            }
        }
        .modifier(ArtifactsNavigationChrome(isEmbedded: isEmbedded))
        .task { await store.refresh() }
        .bighelpSheet(isPresented: Binding(
            get: { store.openedAttachment != nil },
            set: { if !$0 { store.closeAttachment() } }
        )) {
            if let attachment = store.openedAttachment {
                WorkspaceArtifactOpenView(attachment: attachment)
                    .bighelpSheetSize(.large)
            }
        }
        .accessibilityIdentifier("workspace.artifacts")
    }

    private var content: some View {
        List {
            if isEmbedded {
                Section {
                    TextField("Search files, paths, or types", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("workspace.artifacts.search")
                }
            }
            // The Apps tab keeps to the files; the Workspace screen names the host and folder.
            if !isEmbedded {
                Section("Workspace") {
                    LabeledContent("Host", value: store.hostName)
                    if let root = store.workspaceRoot {
                        LabeledContent("Workspace folder") {
                            Text(root)
                                .font(.bighelp(.caption).monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if store.isLoading {
                Section {
                    ProgressView(store.files.isEmpty ? "Finding recent files" : "Refreshing")
                }
            }

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    if !store.files.isEmpty {
                        Text("Showing the last successful file index.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(.secondary)
                    }
                    Button("Retry") { Task { await store.refresh() } }
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityIdentifier("workspace.artifacts.error")
            }

            if !store.scanDiagnostics.isEmpty {
                Section {
                    Label("This is a partial index. Some folders or entries could not be scanned safely.",
                          systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(store.scanDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(diagnostic.message)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Scan notes")
                } footer: {
                    Text("Only verified files inside the configured workspace are shown. Skipped branches are not searched or opened.")
                }
                .accessibilityIdentifier("workspace.artifacts.partial-index")
            }

            if store.isOpening {
                Section { ProgressView("Opening file") }
            }

            if let error = store.openErrorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if visibleFiles.isEmpty, !store.isLoading, store.errorMessage == nil {
                    ContentUnavailableView(
                        search.isEmpty
                            ? (store.scanDiagnostics.isEmpty ? "No files in this workspace" : "No verified files found")
                            : "No matching files",
                        systemImage: search.isEmpty ? "doc" : "magnifyingglass"
                    )
                }
                ForEach(visibleFiles) { entry in
                    Button {
                        Task { await store.open(entry) }
                    } label: {
                        WorkspaceArtifactRow(entry: entry, root: store.workspaceRoot ?? "",
                                             showsLastChange: store.isAgentIndex)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoading || store.isOpening)
                    .accessibilityHint("Downloads this file from Hermes and opens the native preview")
                }
            } header: {
                Text(store.isAgentIndex ? "Made or changed lately" : "Files")
            } footer: {
                Text(store.isAgentIndex
                     ? "Files your agent wrote, edited or sent you, plus new files near the top of the workspace. Newest first."
                     : "Newest-created files first. Files without a creation date appear afterward, sorted by name.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(isEmbedded ? .hidden : .automatic)
        .modifier(ArtifactsSearchAndRefresh(isEmbedded: isEmbedded, search: $search) {
            await store.refresh()
        })
    }
}

private struct ArtifactsNavigationChrome: ViewModifier {
    let isEmbedded: Bool

    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content
                .navigationTitle("Artifacts")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ArtifactsSearchAndRefresh: ViewModifier {
    let isEmbedded: Bool
    @Binding var search: String
    let refresh: @MainActor () async -> Void

    func body(content: Content) -> some View {
        if isEmbedded {
            content.refreshable { await refresh() }
        } else {
            content
                .searchable(text: $search, prompt: "Search files, paths, or types")
                .refreshable { await refresh() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await refresh() }
                        }
                    }
                }
        }
    }
}

private struct WorkspaceArtifactRow: View {
    let entry: WorkspaceFileListing.Entry
    let root: String
    var showsLastChange = false

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(entry.name)
                    .font(.bighelp(.body))
                Text(relativePath)
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: BighelpTokens.space8) {
                    if let size = entry.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    Text(modifiedLabel)
                }
                .font(.bighelp(.caption2))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: BighelpTokens.space8)
            Image(systemName: "chevron.right")
                .font(.bighelp(.caption))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(relativePath), \(modifiedLabel)")
    }

    private var relativePath: String {
        guard DirectHermesWorkspaceFileScope.contains(root: root, path: entry.path),
              !DirectHermesWorkspaceFileScope.samePath(entry.path, root) else { return entry.path }
        let separator: Character = root.hasPrefix("/") ? "/" : "\\"
        return String(entry.path.dropFirst(root.count + (root.last == separator ? 0 : 1)))
    }

    private var modifiedLabel: String {
        if showsLastChange, let date = [entry.createdAt, entry.modifiedAt].compactMap({ $0 }).max() {
            return "Changed \(date.formatted(.relative(presentation: .named)))"
        }
        guard let date = entry.createdAt else { return "Creation date unavailable" }
        return "Created \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var symbol: String {
        guard let mimeType = entry.mimeType else { return "doc" }
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.contains("zip") || mimeType.contains("archive") || mimeType.contains("compressed") {
            return "archivebox"
        }
        return "doc"
    }
}

private struct WorkspaceArtifactOpenView: View {
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    ChatAttachmentGallery(attachments: [attachment], alignsTrailing: false)
                    Text("\(BighelpPlatform.isMac ? "Click" : "Tap") the file above to open bighelp's native preview and save options.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
            }
        }
    }
}
