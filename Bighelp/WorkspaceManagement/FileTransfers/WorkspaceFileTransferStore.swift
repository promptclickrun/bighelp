import Foundation
import Observation
import UniformTypeIdentifiers

struct WorkspaceManagedFileExport: Equatable, Sendable, Identifiable {
    let contents: HermesManagedFileContents
    let privateURL: URL

    var id: String { contents.sha256 + "\u{1f}" + contents.file.path }
    var fileName: String { contents.file.name }
    var mimeType: String { contents.file.mimeType ?? "application/octet-stream" }
}

@MainActor
@Observable
final class WorkspaceFileTransferStore {
    let hostName: String

    private(set) var directory: HermesManagedFileDirectory
    private(set) var selectedFile: HermesManagedFile?
    private(set) var deleteCandidate: HermesManagedFile?
    private(set) var export: WorkspaceManagedFileExport?
    private(set) var isLoading = false
    private(set) var isTransferring = false
    private(set) var successMessage: String?
    private(set) var errorMessage: String?
    private(set) var isRetired = false

    @ObservationIgnored private let client: DirectHermesManagedFilesClient
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(
        hostName: String,
        client: DirectHermesManagedFilesClient,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.client = client
        self.isCurrent = isCurrent
        directory = .init(path: client.scopePath ?? "", parent: nil, files: [])
    }

    var ownsScope: Bool { !isRetired && isCurrent() && client.ownsScope }
    var workspaceRoot: String? { client.scopePath }
    /// Once the host has said why there's no folder, stop saying it's still looking.
    var workspaceRootLabel: String { workspaceRoot ?? (errorMessage == nil ? "Finding it…" : "Unavailable") }
    var canRefresh: Bool { ownsScope && !isLoading && !isTransferring }
    var canAct: Bool { canRefresh && workspaceRoot != nil }
    var supportsLargeTransfers: Bool { client.supportsBinaryTransfers }
    var supportsMediaPlayback: Bool { client.supportsBinaryTransfers }

    func canPlay(_ file: HermesManagedFile) -> Bool {
        canAct
            && client.supportsBinaryTransfers
            && selectedFile == file
            && directory.files.contains(file)
            && DirectHermesManagedMediaPlayback.supports(file)
    }

    func mediaPlayback(for file: HermesManagedFile) -> DirectHermesManagedMediaPlayback? {
        guard canPlay(file) else { return nil }
        return DirectHermesManagedMediaPlayback(file: file, reader: client)
    }

    func refresh() async {
        await load(path: directory.path.isEmpty ? nil : directory.path)
    }

    func open(_ file: HermesManagedFile) async {
        guard file.isDirectory, canAct, directory.files.contains(file) else { return }
        await load(path: file.path)
    }

    func goUp() async {
        guard canAct, let parent = directory.parent else { return }
        await load(path: parent)
    }

    func select(_ file: HermesManagedFile) {
        guard canAct, !file.isDirectory, directory.files.contains(file) else { return }
        let previous = selectedFile
        selectedFile = selectedFile == file ? nil : file
        if previous != selectedFile { clearExport() }
        errorMessage = nil
        successMessage = nil
    }

    func importAndUpload(_ url: URL) async {
        guard canAct else { return }
        let token = beginTransfer()
        defer { finishTransfer(token) }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try Self.readImportedFile(url)
            }.value
            guard accepts(token) else { return }
            let uploaded = try await client.upload(
                localFile: imported.url,
                byteCount: imported.byteCount,
                fileName: imported.name,
                mimeType: imported.mimeType,
                to: directory.path,
                overwrite: false
            )
            guard accepts(token) else { return }
            directory = try await client.list(path: directory.path)
            guard accepts(token), directory.files.contains(uploaded) else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
            selectedFile = uploaded
            successMessage = "Uploaded \(uploaded.name) and verified its exact bytes from Hermes."
        } catch {
            publish(error, token: token)
        }
    }

    func createDirectory(named name: String) async {
        guard canAct else { return }
        let token = beginTransfer()
        defer { finishTransfer(token) }
        do {
            let created = try await client.createDirectory(named: name, in: directory.path)
            guard accepts(token) else { return }
            directory = try await client.list(path: directory.path)
            guard accepts(token), directory.files.contains(created) else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
            successMessage = "Created \(created.name) and verified it in the folder listing."
        } catch {
            publish(error, token: token)
        }
    }

    func prepareDelete(_ file: HermesManagedFile) {
        guard canAct, !file.isDirectory, directory.files.contains(file) else { return }
        selectedFile = file
        deleteCandidate = file
        errorMessage = nil
        successMessage = nil
    }

    func cancelDelete() {
        deleteCandidate = nil
    }

    func confirmDelete() async {
        guard canAct,
              let candidate = deleteCandidate,
              !candidate.isDirectory,
              selectedFile == candidate,
              directory.files.contains(candidate) else { return }
        let token = beginTransfer()
        defer { finishTransfer(token) }
        do {
            try await client.delete(candidate)
            guard accepts(token) else { return }
            let refreshed = try await client.list(path: directory.path)
            guard accepts(token),
                  !refreshed.files.contains(where: { $0.path.utf8.elementsEqual(candidate.path.utf8) }) else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
            directory = refreshed
            selectedFile = nil
            deleteCandidate = nil
            clearExport()
            successMessage = "Deleted \(candidate.name) and verified that it is no longer listed."
        } catch {
            publish(error, token: token)
        }
    }

    func downloadSelected() async {
        guard canAct,
              let selectedFile,
              !selectedFile.isDirectory,
              directory.files.contains(selectedFile) else { return }
        let token = beginTransfer()
        clearExport()
        defer { finishTransfer(token) }
        do {
            let contents = try await client.download(selectedFile)
            guard accepts(token), contents.file == self.selectedFile else { return }
            let privateURL = try Self.makePrivateShareFile(contents)
            guard accepts(token) else {
                try? FileManager.default.removeItem(at: privateURL.deletingLastPathComponent())
                return
            }
            export = .init(contents: contents, privateURL: privateURL)
            successMessage = "Downloaded \(contents.file.name); Hermes’ size and exact response bytes were verified."
        } catch {
            publish(error, token: token)
        }
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    func clearExport() {
        if let export {
            try? FileManager.default.removeItem(at: export.privateURL.deletingLastPathComponent())
        }
        export = nil
    }

    func retire() {
        isRetired = true
        generation = UUID()
        isLoading = false
        isTransferring = false
        selectedFile = nil
        deleteCandidate = nil
        clearExport()
        errorMessage = nil
        successMessage = nil
    }

    private func load(path: String?) async {
        guard ownsScope, !isTransferring else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let value = try await client.list(path: path)
            guard accepts(token) else { return }
            directory = value
            if let selectedFile,
               !value.files.contains(where: { $0 == selectedFile }) {
                self.selectedFile = nil
                clearExport()
            }
        } catch {
            publish(error, token: token)
        }
    }

    private func beginTransfer() -> UUID {
        let token = UUID()
        generation = token
        isLoading = false
        isTransferring = true
        errorMessage = nil
        successMessage = nil
        return token
    }

    private func finishTransfer(_ token: UUID) {
        if generation == token { isTransferring = false }
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private func publish(_ error: any Error, token: UUID) {
        guard accepts(token) else { return }
        if error is CancellationError { return }
        if let value = error as? DirectHermesManagedFilesError {
            errorMessage = value.localizedDescription
        } else if let value = error as? WorkspaceClientError {
            errorMessage = value.localizedDescription
        } else if let value = error as? DirectHermesError {
            errorMessage = value.localizedDescription
        } else {
            errorMessage = "The managed-file operation could not be completed. Refresh before trying again."
        }
    }

    private struct ImportedFile: Sendable {
        let url: URL
        let name: String
        let mimeType: String
        let byteCount: Int
    }

    private nonisolated static func readImportedFile(_ url: URL) throws -> ImportedFile {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentTypeKey,
            .nameKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= DirectHermesManagedFilesClient.maximumNativeTransferBytes else {
            throw DirectHermesManagedFilesError.fileTooLarge(
                limit: DirectHermesManagedFilesClient.maximumNativeTransferBytes
            )
        }
        let name = values.name ?? url.lastPathComponent
        guard !name.isEmpty,
              name.utf8.count <= 255,
              name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !name.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else {
            throw DirectHermesManagedFilesError.invalidName
        }
        let type = values.contentType?.preferredMIMEType ?? "application/octet-stream"

        try Task.checkCancellation()
        return .init(url: url, name: name, mimeType: type, byteCount: size)
    }

    private nonisolated static func makePrivateShareFile(_ contents: HermesManagedFileContents) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "LoopdyManagedFileShares", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUnlessOpen,
                .posixPermissions: 0o700,
            ]
        )
        var protectedFolder = folder
        var folderValues = URLResourceValues()
        folderValues.isExcludedFromBackup = true
        try protectedFolder.setResourceValues(folderValues)

        let file = folder.appending(path: contents.file.name, directoryHint: .notDirectory)
        do {
            try contents.bytes.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let readback = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard readback == contents.bytes else { throw DirectHermesManagedFilesError.invalidResponse }
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
