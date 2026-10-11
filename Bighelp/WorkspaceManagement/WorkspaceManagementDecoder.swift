import Foundation

enum WorkspaceManagementDecoder {
    typealias Object = [String: BighelpJSONValue]
    static let maximumRows = 1_000
    static let maximumFileRows = 50_000
    static let maximumDocumentBytes = 262_144

    static func text(_ value: BighelpJSONValue?, maximum: Int = 512, empty: Bool = false) throws -> String {
        guard let text = value?.string, text.utf8.count <= maximum,
              empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.unicodeScalars.contains(where: { $0.value == 0 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) })
        else { throw WorkspaceManagementError.invalidResponse }
        return text
    }

    static func optionalText(_ value: BighelpJSONValue?, maximum: Int = 512) throws -> String? {
        guard let value, value != .null else { return nil }
        return try text(value, maximum: maximum, empty: true)
    }

    static func rows(_ value: BighelpJSONValue?, maximum: Int = maximumRows) throws -> [BighelpJSONValue] {
        guard let rows = value?.array, rows.count <= maximum else {
            throw WorkspaceManagementError.invalidResponse
        }
        return rows
    }

    static func object(_ value: BighelpJSONValue) throws -> Object {
        guard let object = value.object else { throw WorkspaceManagementError.invalidResponse }
        return object
    }

    static func unique<T: Identifiable>(_ rows: [T]) throws -> [T] where T.ID: Hashable {
        guard Set(rows.map(\.id)).count == rows.count else { throw WorkspaceManagementError.invalidResponse }
        return rows
    }

    static func projects(_ payload: Object) throws -> [WorkspaceProject] {
        try unique(rows(payload["projects"]).map { try project(object($0)) })
    }

    static func project(_ row: Object) throws -> WorkspaceProject {
        guard let archived = row["archived"]?.boolean else { throw WorkspaceManagementError.invalidResponse }
        let folders: [WorkspaceProject.Folder] = try rows(row["folders"], maximum: 100).map {
            let folder = try object($0)
            guard let isPrimary = folder["is_primary"]?.boolean else { throw WorkspaceManagementError.invalidResponse }
            return try .init(
                path: text(folder["path"], maximum: 4_096),
                label: optionalText(folder["label"]),
                isPrimary: isPrimary
            )
        }
        return try .init(
            id: text(row["id"], maximum: 128),
            name: text(row["name"], maximum: 200),
            summary: optionalText(row["description"], maximum: 8_192) ?? "",
            isArchived: archived,
            folders: unique(folders)
        )
    }

    /// Hermes' model catalog, read like the chat picker's
    /// (`DirectHermesAgentRuntimeDefaultsClient.decodeModelProviders`): a malformed
    /// provider, an unusable model or a repeat costs only itself, never the list.
    static func models(_ payload: Object) throws -> WorkspaceModelCatalog {
        guard let rows = payload["providers"]?.array else { throw WorkspaceManagementError.invalidResponse }
        var providerIDs = Set<String>()
        let providers: [WorkspaceModelCatalog.Provider] = rows.compactMap { value in
            guard let row = value.object, let id = try? text(row["slug"], maximum: 256),
                  providerIDs.insert(id).inserted else { return nil }
            var modelIDs = Set<String>()
            let models = (row["models"]?.array ?? []).compactMap { model -> String? in
                guard let model = try? text(model, maximum: 256), modelIDs.insert(model).inserted else { return nil }
                return model
            }
            return .init(
                id: id,
                name: (try? text(row["name"], maximum: 200)) ?? id,
                models: models,
                isAuthenticated: row["authenticated"]?.boolean
            )
        }
        return .init(
            providers: providers,
            currentProvider: (try? text(payload["provider"], maximum: 256, empty: true)) ?? "",
            currentModel: (try? text(payload["model"], maximum: 256, empty: true)) ?? ""
        )
    }

    static func path(_ value: BighelpJSONValue?) throws -> String {
        let path = try text(value, maximum: 4_096)
        guard path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !path.contains("//"), path == "/" || !path.hasSuffix("/")
        else { throw WorkspaceManagementError.invalidResponse }
        return path
    }

    static func contains(root: String, path: String) -> Bool {
        path == root || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }

    static func fileRoot(_ payload: Object, expectedRoot: String?) throws -> String {
        let root: String
        if payload["can_change_path"] == .boolean(true), payload["locked_root"] == .null, payload["root"] == .null {
            // Hermes explicitly permits browsing outside a locked directory.
            root = "/"
        } else {
            guard payload["can_change_path"] == .boolean(false),
                  let locked = try optionalText(payload["locked_root"], maximum: 4_096),
                  payload["root"]?.string == locked else { throw WorkspaceManagementError.fileRootNotConfined }
            root = locked
        }
        _ = try path(.string(root))
        guard expectedRoot == nil || root == expectedRoot else { throw WorkspaceManagementError.fileRootNotConfined }
        return root
    }

    static func files(
        _ payload: Object,
        expectedPath: String?,
        expectedRoot: String?,
        maximumEntries: Int = maximumRows
    ) throws -> WorkspaceFileListing {
        let root = try fileRoot(payload, expectedRoot: expectedRoot)
        let currentPath = try path(payload["path"])
        guard contains(root: root, path: currentPath),
              expectedPath == nil || currentPath == expectedPath else {
            throw WorkspaceManagementError.invalidResponse
        }
        let parent = try optionalText(payload["parent"], maximum: 4_096)
        if let parent {
            _ = try path(.string(parent))
            let prefix = parent == "/" ? "/" : parent + "/"
            guard contains(root: root, path: parent), currentPath.hasPrefix(prefix),
                  String(currentPath.dropFirst(prefix.count)).contains("/") == false else {
                throw WorkspaceManagementError.invalidResponse
            }
        }
        let entries: [WorkspaceFileListing.Entry] = try rows(payload["entries"], maximum: maximumEntries).map {
            let row = try object($0)
            let childPath = try path(row["path"])
            let name = try text(row["name"], maximum: 255)
            guard let isDirectory = row["is_directory"]?.boolean,
                  contains(root: root, path: childPath), childPath != currentPath,
                  !name.contains("/"), !name.contains("\\") else { throw WorkspaceManagementError.invalidResponse }
            let size = row["size"]?.integer
            guard isDirectory || (size != nil && size! >= 0) else { throw WorkspaceManagementError.invalidResponse }
            let modifiedAt = try fileModifiedAt(row["mtime"])
            let createdAt = try fileModifiedAt(row["created"])
            let mimeType = try fileMIMEType(row["mime_type"], isDirectory: isDirectory)
            return .init(
                path: childPath,
                name: name,
                isDirectory: isDirectory,
                size: size,
                modifiedAt: modifiedAt,
                mimeType: mimeType,
                createdAt: createdAt
            )
        }
        return try .init(path: currentPath, root: root, parent: parent, entries: unique(entries))
    }

    /// Decodes the stock managed-file response while confining this feature to
    /// the literal Hermes workspace. An unrestricted host response never turns
    /// into UI access above `/workspace`.
    static func workspaceArtifacts(_ payload: Object, expectedPath: String) throws -> WorkspaceFileListing {
        let workspaceRoot = "/workspace"
        guard contains(root: workspaceRoot, path: expectedPath) else {
            throw WorkspaceManagementError.fileRootNotConfined
        }
        let listing = try files(
            payload,
            expectedPath: expectedPath,
            expectedRoot: nil,
            maximumEntries: maximumFileRows
        )
        guard contains(root: workspaceRoot, path: listing.path),
              listing.entries.allSatisfy({ contains(root: workspaceRoot, path: $0.path) }) else {
            throw WorkspaceManagementError.fileRootNotConfined
        }
        if expectedPath == workspaceRoot {
            guard listing.parent == nil || listing.parent == "/" else {
                throw WorkspaceManagementError.invalidResponse
            }
        } else {
            guard let separator = expectedPath.lastIndex(of: "/") else {
                throw WorkspaceManagementError.invalidResponse
            }
            let expectedParent = String(expectedPath[..<separator])
            guard listing.parent == expectedParent else { throw WorkspaceManagementError.invalidResponse }
        }
        return .init(
            path: listing.path,
            root: workspaceRoot,
            parent: expectedPath == workspaceRoot ? nil : listing.parent,
            entries: listing.entries
        )
    }

    private static func fileModifiedAt(_ value: BighelpJSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        guard let seconds = value.number, seconds.isFinite,
              (-62_135_596_800.0...253_402_300_799.0).contains(seconds) else {
            throw WorkspaceManagementError.invalidResponse
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func fileMIMEType(_ value: BighelpJSONValue?, isDirectory: Bool) throws -> String? {
        guard let value, value != .null else { return nil }
        let mimeType = try text(value, maximum: 120)
        guard !isDirectory, mimeType.contains("/"), mimeType.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0))
        }) else { throw WorkspaceManagementError.invalidResponse }
        return mimeType.lowercased()
    }

    static func file(_ payload: Object, expectedPath: String, root: String) throws -> WorkspaceFilePreview {
        _ = try fileRoot(payload, expectedRoot: root)
        guard try path(payload["path"]) == expectedPath,
              contains(root: root, path: expectedPath),
              let size = payload["size"]?.integer, (0...maximumDocumentBytes).contains(size),
              let dataURL = payload["data_url"]?.string,
              dataURL.utf8.count <= maximumDocumentBytes * 2,
              let separator = dataURL.firstIndex(of: ","),
              dataURL[..<separator].hasPrefix("data:"),
              dataURL[..<separator].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: separator)...])),
              data.count == size,
              let content = String(data: data, encoding: .utf8),
              !content.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) })
        else { throw WorkspaceManagementError.filePreviewUnavailable }
        return try .init(path: expectedPath, name: text(payload["name"], maximum: 255), text: content)
    }

    static func logs(_ payload: Object) throws -> [String] {
        // Log bodies can contain prompts, paths or credentials even after token-pattern redaction.
        // Retain only allowlisted severity; do not display, export or persist raw messages.
        try rows(payload["lines"], maximum: 500).map { value in
            let line = try text(value, maximum: 32_768, empty: true)
            let level = ["CRITICAL", "ERROR", "WARNING", "WARN", "INFO", "DEBUG"].first {
                line.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
            } ?? "LOG"
            return "\(level) - Message withheld to protect private host data"
        }
    }
}
