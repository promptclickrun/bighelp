import Foundation
import UniformTypeIdentifiers

protocol FileExplorerEntry {
    var path: String { get }
    var name: String { get }
    var isDirectory: Bool { get }
    var explorerModifiedAt: Date? { get }
    var createdAt: Date? { get }
    var mimeType: String? { get }
}

struct FileExplorerOptions {
    enum Sort: String, CaseIterable { case name, modified, created }
    enum Filter: String, CaseIterable { case all, folders, documents, images, video, audio, other }

    var query = ""
    var sort: Sort = .name
    var ascending = true
    var filter: Filter = .all

    var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all }

    func apply<File: FileExplorerEntry>(_ files: [File]) -> [File] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.filter { file in
            (filter == .all || Self.kind(file) == filter)
                && (search.isEmpty || file.name.localizedStandardContains(search)
                    || file.path.localizedStandardContains(search)
                    || (file.mimeType?.localizedStandardContains(search) ?? false))
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            if sort != .name {
                let left = sort == .created ? lhs.createdAt : lhs.explorerModifiedAt
                let right = sort == .created ? rhs.createdAt : rhs.explorerModifiedAt
                switch (left, right) {
                case let (left?, right?) where left != right: return ascending ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            return lhs.path < rhs.path
        }
    }

    private static func kind(_ file: some FileExplorerEntry) -> Filter {
        if file.isDirectory { return .folders }
        let type = file.mimeType.flatMap { UTType(mimeType: $0) }
        let extensionType = UTType(filenameExtension: (file.name as NSString).pathExtension)
        let types = [type, extensionType].compactMap { $0 }
        if types.contains(where: { $0.conforms(to: .image) }) { return .images }
        if types.contains(where: { $0.conforms(to: .movie) }) { return .video }
        if types.contains(where: { $0.conforms(to: .audio) }) { return .audio }
        if types.contains(where: { $0.conforms(to: .text) || $0.conforms(to: .pdf) || $0.conforms(to: .spreadsheet) || $0.conforms(to: .presentation) }) { return .documents }
        if ["doc", "docx", "odt", "rtf"].contains((file.name as NSString).pathExtension.lowercased()) { return .documents }
        return .other
    }
}
