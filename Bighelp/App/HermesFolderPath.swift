import Foundation

/// Folder paths on the Hermes computer as a person types them: full paths
/// ("/srv/app") or home-relative ones ("~/projects/app").
enum HermesFolderPath {
    /// The folder to list and the name typed so far. Empty text browses home;
    /// a trailing slash lists that folder's own subfolders.
    static func query(for typed: String) -> (parentPath: String, prefix: String)? {
        let path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if path.isEmpty || path == "~" || path == "~/" { return ("~", "") }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        if path == "/" { return ("/", "") }
        if path.hasSuffix("/") { return (String(path.dropLast()), "") }
        let value = path as NSString
        let parent = value.deletingLastPathComponent
        return (parent.isEmpty ? "/" : parent, value.lastPathComponent)
    }

    static func isAccepted(_ typed: String) -> Bool {
        let path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }

    /// The full path to save, or nil while home is unknown for a "~" path.
    static func expanded(_ typed: String, home: String?) -> String? {
        var path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/") { return path }
        guard path == "~" || path.hasPrefix("~/"), let home else { return nil }
        return path == "~" ? home : home + path.dropFirst()
    }

    /// "~/projects" for a folder inside home; other paths unchanged.
    static func abbreviated(_ path: String, home: String?) -> String {
        guard let home, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Home, worked out from a listing of a "~" folder that came back with its full path.
    static func home(listed typedParent: String, fullPath: String) -> String? {
        guard fullPath.hasPrefix("/") else { return nil }
        if typedParent == "~" { return fullPath }
        guard typedParent.hasPrefix("~/") else { return nil }
        let rest = String(typedParent.dropFirst())
        guard fullPath.hasSuffix(rest), fullPath.count > rest.count else { return nil }
        return String(fullPath.dropLast(rest.count))
    }

    /// The folder above, or nil at the top.
    static func parent(of path: String) -> String? {
        guard path != "/", path.hasPrefix("/") else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

/// Reads Hermes's `/api/fs/list` into the subfolders matching what's typed:
/// names starting with it first, then names containing it. Hidden folders
/// appear once a "." is typed.
enum HermesFolderListing {
    static func page(_ response: BighelpJSONValue, requestedPath: String, prefix: String,
                     offset: Int, limit: Int) throws -> HermesWorkspaceFolderPage {
        guard let object = response.object, let rows = object["entries"]?.array, rows.count <= 50_000 else {
            throw WorkspaceClientError.invalidResponse
        }
        if let code = object["error"]?.string, !code.isEmpty { throw WorkspaceClientError.rejected(code: code) }
        var parent: String?
        var starts: [HermesWorkspaceFolderSuggestion] = []
        var contains: [HermesWorkspaceFolderSuggestion] = []
        let match = prefix.lowercased()
        for row in rows {
            guard let entry = row.object, let name = entry["name"]?.string, let path = entry["path"]?.string,
                  !name.isEmpty, !path.isEmpty, path.utf8.count <= 4_096 else {
                throw WorkspaceClientError.invalidResponse
            }
            if parent == nil {
                let above = (path as NSString).deletingLastPathComponent
                parent = above.isEmpty ? "/" : above
            }
            guard entry["isDirectory"]?.boolean == true, !name.hasPrefix(".") || match.hasPrefix(".") else { continue }
            let lowered = name.lowercased()
            if match.isEmpty || lowered.hasPrefix(match) {
                starts.append(.init(name: name, path: path))
            } else if lowered.contains(match) {
                contains.append(.init(name: name, path: path))
            }
        }
        let byName: (HermesWorkspaceFolderSuggestion, HermesWorkspaceFolderSuggestion) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let folders = starts.sorted(by: byName) + contains.sorted(by: byName)
        let page = Array(folders.dropFirst(offset).prefix(limit))
        let next = offset + page.count < folders.count ? offset + page.count : nil
        return .init(parentPath: parent ?? requestedPath, folders: page, nextOffset: next)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case WorkspaceClientError.rejected(code: "ENOENT", _): "There's no folder at that path yet."
        case WorkspaceClientError.rejected(code: "ENOTDIR", _): "That path is a file, not a folder."
        case WorkspaceClientError.rejected(code: "EACCES", _): "Hermes isn't allowed to open that folder."
        case WorkspaceClientError.unavailable: "This connection can't browse folders. Type the full path."
        default: "Remote folders could not be listed."
        }
    }
}
