import Foundation

/// A workspace file boundary accepted only after the authenticated bighelp plugin
/// proves the serving profile's working folder and locked file policy. The plugin
/// finds that folder the way Hermes does: `terminal.cwd`, or Hermes' own default
/// when it isn't set (its `workspace.origin` says which).
/// The owner includes both authentication and connection generations.
struct DirectHermesWorkspaceFileScope: Equatable, Sendable {
    enum ManagedPolicy: Equatable, Sendable {
        case unrestricted
        case locked(root: String)
    }

    let root: String
    let owner: WorkspaceOwner
    private let policy: ManagedPolicy

    private init(root: String, owner: WorkspaceOwner, policy: ManagedPolicy) {
        self.root = root
        self.owner = owner
        self.policy = policy
    }


    /// Builds a production scope only from the authenticated bighelp plugin's
    /// workspace projection, never from Hermes' stock default-cwd response: the
    /// plugin refuses defaults that aren't the agent's own folder (the disk root,
    /// Hermes' own folders) and keeps Hermes' folders out of every listing.
    static func pluginReported(
        workspaceListing: [String: BighelpJSONValue],
        owner: WorkspaceOwner
    ) throws -> Self {
        guard let workspace = workspaceListing["workspace"]?.object,
              workspace["source"]?.string == "terminal.cwd",
              let rawRoot = workspace["root"]?.string,
              let root = try? path(rawRoot),
              let listedPath = workspaceListing["path"]?.string,
              let validatedListedPath = try? path(listedPath),
              samePath(validatedListedPath, root) else {
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        let policy = try managedPolicy(workspaceListing)
        guard case .locked(let policyRoot) = policy,
              samePath(policyRoot, root) else {
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        let scope = Self(root: root, owner: owner, policy: policy)
        try scope.validatePolicy(workspaceListing)
        _ = try scope.managedDirectory(workspaceListing, expectedPath: root)
        return scope
    }

#if DEBUG
    /// Test-only construction is deliberately explicit. Production has no path
    /// initializer and no hard-coded workspace fallback.
    static func fixture(
        root: String,
        owner: WorkspaceOwner,
        lockedManagedRoot: String? = nil
    ) throws -> Self {
        let root = try path(root)
        let policy: ManagedPolicy
        if let lockedManagedRoot {
            let locked = try path(lockedManagedRoot)
            guard contains(root: locked, path: root) else {
                throw DirectHermesManagedFilesError.scopeUnavailable
            }
            policy = .locked(root: locked)
        } else {
            policy = .unrestricted
        }
        return .init(root: root, owner: owner, policy: policy)
    }
#endif

    func contains(_ candidate: String) -> Bool {
        guard let candidate = try? Self.path(candidate) else { return false }
        return Self.contains(root: root, path: candidate)
    }

    func require(_ candidate: String) throws -> String {
        let candidate = try Self.path(candidate)
        guard Self.contains(root: root, path: candidate) else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        return candidate
    }

    func child(_ name: String, of directory: String) throws -> String {
        let directory = try require(directory)
        let name = try Self.pathComponent(name)
        let separator = Self.separator(for: directory)
        if Self.isFilesystemRoot(directory) { return directory + name }
        return directory + String(separator) + name
    }

    func parent(of candidate: String) throws -> String {
        let candidate = try require(candidate)
        guard !Self.samePath(candidate, root) else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        let separator = Self.separator(for: candidate)
        guard let index = candidate.lastIndex(of: separator) else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        var parent = String(candidate[..<index])
        if separator == "/", parent.isEmpty { parent = "/" }
        if separator == "\\", parent.utf8.count == 2 { parent += "\\" }
        return try require(parent)
    }

    func validatePolicy(_ payload: [String: BighelpJSONValue]) throws {
        guard let returned = try? Self.managedPolicy(payload), returned == policy else {
            throw DirectHermesManagedFilesError.scopeChanged
        }
    }

    func managedDirectory(
        _ payload: [String: BighelpJSONValue],
        expectedPath: String
    ) throws -> HermesManagedFileDirectory {
        try validatePolicy(payload)
        let expectedPath = try require(expectedPath)
        guard let rawPath = payload["path"]?.string else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        let returnedPath = try require(rawPath)
        guard Self.samePath(returnedPath, expectedPath),
              let rows = payload["entries"]?.array,
              rows.count <= WorkspaceManagementDecoder.maximumFileRows else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        let parent = try validatedParent(payload["parent"], path: returnedPath)
        let files = try rows.map { value -> HermesManagedFile in
            guard let object = value.object else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            return try managedFile(object)
        }
        guard Set(files.map(\.id)).count == files.count,
              files.allSatisfy({ !Self.samePath($0.path, returnedPath) }) else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return .init(path: returnedPath, parent: parent, files: files)
    }

    func artifactDirectory(
        _ payload: [String: BighelpJSONValue],
        expectedPath: String
    ) throws -> WorkspaceFileListing {
        let envelope = try artifactDirectoryEnvelope(payload, expectedPath: expectedPath)
        let entries = try envelope.rows.map { value -> WorkspaceFileListing.Entry in
            guard let object = value.object else { throw WorkspaceManagementError.invalidResponse }
            return try artifactEntry(object)
        }
        guard Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !Self.samePath($0.path, envelope.path) }) else {
            throw WorkspaceManagementError.invalidResponse
        }
        return .init(path: envelope.path, root: root, parent: envelope.parent, entries: entries)
    }

    /// Artifacts uses strict envelope/policy validation while isolating individual
    /// hostile, unsupported, or escaping rows. The Files client intentionally
    /// continues to use the all-or-nothing managed-directory decoder.
    func artifactEnumerationDirectory(
        _ payload: [String: BighelpJSONValue],
        expectedPath: String
    ) throws -> WorkspaceArtifactDirectoryInspection {
        let envelope = try artifactDirectoryEnvelope(payload, expectedPath: expectedPath)
        var entries: [WorkspaceFileListing.Entry] = []
        var diagnostics: [WorkspaceArtifactScanDiagnostic] = []
        var identifiers = Set<String>()

        for value in envelope.rows {
            guard let object = value.object else {
                diagnostics.append(.unsupportedEntry(directory: envelope.path, entryName: nil))
                continue
            }
            let safeName = object["name"]?.string.flatMap { try? Self.pathComponent($0) }
            if let rawPath = object["path"]?.string,
               let candidate = try? Self.path(rawPath),
               !Self.contains(root: root, path: candidate) {
                diagnostics.append(.outsideWorkspace(directory: envelope.path, entryName: safeName))
                continue
            }
            do {
                let entry = try artifactEntry(object)
                guard !Self.samePath(entry.path, envelope.path),
                      identifiers.insert(entry.id).inserted else {
                    diagnostics.append(.unsupportedEntry(directory: envelope.path, entryName: safeName))
                    continue
                }
                entries.append(entry)
            } catch {
                diagnostics.append(.unsupportedEntry(directory: envelope.path, entryName: safeName))
            }
        }

        return .init(
            listing: .init(path: envelope.path, root: root, parent: envelope.parent, entries: entries),
            diagnostics: diagnostics
        )
    }

    private func artifactDirectoryEnvelope(
        _ payload: [String: BighelpJSONValue],
        expectedPath: String
    ) throws -> (path: String, parent: String?, rows: [BighelpJSONValue]) {
        try validatePolicy(payload)
        let expectedPath = try require(expectedPath)
        guard let rawPath = payload["path"]?.string else {
            throw WorkspaceManagementError.fileRootNotConfined
        }
        let returnedPath = try require(rawPath)
        guard Self.samePath(returnedPath, expectedPath),
              let rows = payload["entries"]?.array,
              rows.count <= WorkspaceManagementDecoder.maximumFileRows else {
            throw WorkspaceManagementError.invalidResponse
        }
        let parent = try validatedParent(payload["parent"], path: returnedPath)
        return (returnedPath, parent, rows)
    }

    private func validatedParent(_ value: BighelpJSONValue?, path current: String) throws -> String? {
        if Self.samePath(current, root) {
            guard value == nil || value == .null || value?.string != nil else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            if let raw = value?.string {
                let reported = try Self.path(raw)
                let lexicalParent = Self.lexicalParent(of: current)
                guard lexicalParent.map({ Self.samePath($0, reported) }) ?? false else {
                    throw DirectHermesManagedFilesError.invalidResponse
                }
            }
            return nil
        }
        guard let raw = value?.string else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        let returned = try require(raw)
        let expected = try parent(of: current)
        guard Self.samePath(returned, expected) else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return returned
    }

    func managedFile(_ object: [String: BighelpJSONValue]) throws -> HermesManagedFile {
        guard let rawPath = object["path"]?.string,
              let rawName = object["name"]?.string,
              let isDirectory = object["is_directory"]?.boolean,
              let modified = object["mtime"]?.number,
              modified.isFinite,
              (-62_135_596_800.0...253_402_300_799.0).contains(modified) else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        let path = try require(rawPath)
        let name = try Self.pathComponent(rawName)
        let byteCount: Int?
        let mimeType: String?
        if isDirectory {
            guard object["size"] == nil || object["size"] == .null,
                  object["mime_type"] == nil || object["mime_type"] == .null else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            byteCount = nil
            mimeType = nil
        } else {
            guard let size = object["size"]?.integer, size >= 0,
                  let rawMIME = object["mime_type"]?.string else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            byteCount = size
            mimeType = try Self.mimeType(rawMIME)
        }
        return .init(
            path: path,
            name: name,
            isDirectory: isDirectory,
            byteCount: byteCount,
            modifiedAt: Date(timeIntervalSince1970: modified),
            mimeType: mimeType
        )
    }

    private func artifactEntry(_ object: [String: BighelpJSONValue]) throws -> WorkspaceFileListing.Entry {
        guard let rawPath = object["path"]?.string,
              let rawName = object["name"]?.string,
              let isDirectory = object["is_directory"]?.boolean else {
            throw WorkspaceManagementError.invalidResponse
        }
        let entryPath = try require(rawPath)
        let name = try Self.pathComponent(rawName)
        let size: Int?
        let mimeType: String?
        if isDirectory {
            guard object["size"] == nil || object["size"] == .null,
                  object["mime_type"] == nil || object["mime_type"] == .null else {
                throw WorkspaceManagementError.invalidResponse
            }
            size = nil
            mimeType = nil
        } else {
            guard let returnedSize = object["size"]?.integer, returnedSize >= 0,
                  let returnedMIME = object["mime_type"]?.string else {
                throw WorkspaceManagementError.invalidResponse
            }
            size = returnedSize
            mimeType = try Self.mimeType(returnedMIME)
        }
        let modifiedAt: Date?
        if object["mtime"] == nil || object["mtime"] == .null {
            modifiedAt = nil
        } else {
            guard let seconds = object["mtime"]?.number, seconds.isFinite,
                  (-62_135_596_800.0...253_402_300_799.0).contains(seconds) else {
                throw WorkspaceManagementError.invalidResponse
            }
            modifiedAt = Date(timeIntervalSince1970: seconds)
        }
        let createdAt: Date?
        if object["created"] == nil || object["created"] == .null {
            createdAt = nil
        } else {
            guard let seconds = object["created"]?.number, seconds.isFinite,
                  (-62_135_596_800.0...253_402_300_799.0).contains(seconds) else {
                throw WorkspaceManagementError.invalidResponse
            }
            createdAt = Date(timeIntervalSince1970: seconds)
        }
        return .init(
            path: entryPath,
            name: name,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt,
            mimeType: mimeType,
            createdAt: createdAt
        )
    }

    private static func managedPolicy(_ payload: [String: BighelpJSONValue]) throws -> ManagedPolicy {
        if payload["can_change_path"] == .boolean(true),
           payload["root"] == .null, payload["locked_root"] == .null {
            return .unrestricted
        }
        guard payload["can_change_path"] == .boolean(false),
              let rawRoot = payload["root"]?.string,
              let rawLocked = payload["locked_root"]?.string else {
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        guard let root = try? path(rawRoot),
              let locked = try? path(rawLocked),
              samePath(root, locked) else {
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        return .locked(root: root)
    }

    static func path(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        if value.hasPrefix("/") {
            guard !value.contains("\\"), !value.contains("//"),
                  value == "/" || !value.hasSuffix("/"),
                  !value.split(separator: "/", omittingEmptySubsequences: false).contains("."),
                  !value.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
                throw DirectHermesManagedFilesError.invalidPath
            }
            return value
        }
        let bytes = Array(value.utf8)
        guard bytes.count >= 3,
              ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])),
              bytes[1] == 58, bytes[2] == 92,
              !value.contains("/"), !value.contains("\\\\"),
              value.utf8.count == 3 || !value.hasSuffix("\\") else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        if bytes.count == 3 { return value }
        let parts = value.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
        guard !parts.contains("."), !parts.contains(".."), !parts.contains(where: \.isEmpty) else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        return value
    }

    static func contains(root: String, path: String) -> Bool {
        guard let root = try? Self.path(root), let path = try? Self.path(path),
              separator(for: root) == separator(for: path) else { return false }
        if separator(for: root) == "\\" {
            let foldedRoot = Data(root.lowercased().utf8)
            let foldedPath = Data(path.lowercased().utf8)
            return foldedPath == foldedRoot
                || foldedPath.starts(with: foldedRoot + Data((isFilesystemRoot(root) ? "" : "\\").utf8))
        }
        return Data(path.utf8) == Data(root.utf8) || Data(path.utf8).starts(with: Data((root == "/" ? "/" : root + "/").utf8))
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        guard separator(for: lhs) == separator(for: rhs) else { return false }
        return separator(for: lhs) == "\\"
            ? Data(lhs.lowercased().utf8) == Data(rhs.lowercased().utf8)
            : Data(lhs.utf8) == Data(rhs.utf8)
    }

    static func pathComponent(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 255,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else {
            throw DirectHermesManagedFilesError.invalidName
        }
        return value
    }

    static func mimeType(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 120,
              normalized.contains("/"),
              normalized.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0))
              }) else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return normalized
    }

    private static func separator(for path: String) -> Character {
        path.hasPrefix("/") ? "/" : "\\"
    }

    private static func isFilesystemRoot(_ path: String) -> Bool {
        path == "/" || (separator(for: path) == "\\" && path.utf8.count == 3)
    }

    private static func lexicalParent(of path: String) -> String? {
        guard !isFilesystemRoot(path) else { return nil }
        let separator = separator(for: path)
        guard let index = path.lastIndex(of: separator) else { return nil }
        var parent = String(path[..<index])
        if separator == "/", parent.isEmpty { parent = "/" }
        if separator == "\\", parent.utf8.count == 2 { parent += "\\" }
        return parent
    }
}
