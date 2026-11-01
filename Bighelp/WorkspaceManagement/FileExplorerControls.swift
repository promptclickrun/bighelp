import SwiftUI

extension HermesManagedFile: FileExplorerEntry {
    var explorerModifiedAt: Date? { modifiedAt }
}

extension WorkspaceFileListing.Entry: FileExplorerEntry {
    var explorerModifiedAt: Date? { modifiedAt }
}

struct FileExplorerControls: View {
    @Binding var options: FileExplorerOptions
    var showsSearch = true
    var searchPrompt = String(localized: "Search this folder")

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if showsSearch {
                BighelpSearchField(text: $options.query, prompt: searchPrompt,
                                   accessibilityLabel: searchPrompt, accessibilityIdentifier: "files.search")
            }
            HStack {
                Menu {
                    Picker("Sort by", selection: $options.sort) {
                        Text("Name (A–Z)").tag(FileExplorerOptions.Sort.name)
                        Text("Recently modified").tag(FileExplorerOptions.Sort.modified)
                        Text("Created").tag(FileExplorerOptions.Sort.created)
                    }
                    Picker("Order", selection: $options.ascending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("files.sort")
                Menu {
                    Picker("Filter", selection: $options.filter) {
                        Text("All files").tag(FileExplorerOptions.Filter.all)
                        Text("Folders").tag(FileExplorerOptions.Filter.folders)
                        Text("Documents").tag(FileExplorerOptions.Filter.documents)
                        Text("Images").tag(FileExplorerOptions.Filter.images)
                        Text("Video").tag(FileExplorerOptions.Filter.video)
                        Text("Audio").tag(FileExplorerOptions.Filter.audio)
                        Text("Other files").tag(FileExplorerOptions.Filter.other)
                    }
                } label: {
                    Label("Filter", systemImage: options.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("files.filter")
                Spacer()
                if options.isFiltering {
                    Button("Clear") { options.query = ""; options.filter = .all }
                        .accessibilityIdentifier("files.clear")
                }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: BighelpTokens.hitTarget)
            if options.sort != .name {
                Text("Files without this date appear last.")
                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
            }
        }
        .onChange(of: options.sort) { _, sort in options.ascending = sort == .name }
    }
}
