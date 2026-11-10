import SwiftUI
import UIKit

/// A chat's Files (••• › Files, #944): the chat's working folder on the computer. A path field
/// on top shows any other folder (Return goes there), with the folder above and the working
/// folder one tap away. Under it, the folder as a tree: a tap opens a folder in place, reading
/// it then, and opens a file to read. Search finds names in every folder opened so far.
struct ChatFolderBrowserView: View {
    private let context: ChatFolderContext
    @State private var model: ChatFolderBrowserModel
    @State private var opened: HostFolderEntry?
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    init(context: ChatFolderContext) {
        self.context = context
        _model = State(initialValue: ChatFolderBrowserModel(access: context.folders))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                pathRow
                BighelpSearchField(text: $model.search, prompt: "Search these folders",
                                   accessibilityIdentifier: "chat.files.search")
                    .bighelpListSearchRow()
                rows
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("chat.files.done")
                }
            }
            .navigationDestination(item: $opened) { entry in
                ChatFolderFileView(entry: entry, context: context)
            }
            .task { await model.start() }
        }
        .accessibilityIdentifier("chat.files")
    }

    private var pathRow: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                TextField("Folder path", text: $model.pathText,
                          prompt: Text("Folder path").bighelpFieldHint(theme))
                    .font(.bighelp(.footnote, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.submitPath() } }
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12,
                                                                     style: .continuous))
                    .bighelpMacFieldArea()
                    .accessibilityLabel("Folder path")
                    .accessibilityIdentifier("chat.files.path")
                pathButton("arrow.up", label: "Folder above", id: "chat.files.up", isOn: model.canGoUp) {
                    await model.goUp()
                }
                pathButton("house", label: "Working folder", id: "chat.files.working-folder",
                           isOn: !model.isAtWorkingFolder) {
                    await model.openWorkingFolder()
                }
            }
            if let message = model.rootMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.files.message")
            }
        }
        .listRowInsets(EdgeInsets(top: BighelpTokens.space8, leading: BighelpTokens.space16,
                                  bottom: BighelpTokens.space4, trailing: BighelpTokens.space16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func pathButton(_ systemImage: String, label: String, id: String, isOn: Bool,
                            action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: systemImage)
                .font(.bighelp(.body, weight: .medium))
                .foregroundStyle(isOn ? theme.primaryText : theme.tertiaryText)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12,
                                                                 style: .continuous))
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .disabled(!isOn)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var rows: some View {
        let rows = model.rows
        if model.root == nil, model.isLoading {
            status { ProgressView() }
        } else if rows.isEmpty, model.root != nil {
            status {
                Text(!model.search.isEmpty ? "No names match in the folders you opened."
                     : model.hiddenCount > 0 ? "This folder has only hidden items." : "This folder is empty.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("chat.files.empty")
            }
        } else {
            ForEach(rows) { row in
                ChatFolderRow(row: row, isExpanded: model.expanded.contains(row.entry.path),
                              isLoading: model.loading.contains(row.entry.path),
                              isEmpty: model.isEmptyFolder(row.entry),
                              message: model.folderMessages[row.entry.path]) {
                    if row.entry.isDirectory {
                        Task { await model.toggle(row.entry) }
                    } else {
                        opened = row.entry
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: BighelpTokens.space16, bottom: 0,
                                          trailing: BighelpTokens.space16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        if model.hiddenCount > 0, model.search.isEmpty, model.root != nil { hiddenRow }
    }

    /// Names that start with a dot are a developer's business: one line brings them, or puts them away.
    private var hiddenRow: some View {
        Button {
            model.showsHidden.toggle()
        } label: {
            Text(model.showsHidden ? "Hide hidden items"
                 : model.hiddenCount == 1 ? "Show 1 hidden item" : "Show \(model.hiddenCount) hidden items")
                .font(.bighelp(.footnote, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("chat.files.hidden")
        .listRowInsets(EdgeInsets(top: 0, leading: BighelpTokens.space16 + 44, bottom: BighelpTokens.space16,
                                  trailing: BighelpTokens.space16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func status(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 120)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// One folder or file in the tree, set in by how deep it is. A search result says where it is.
private struct ChatFolderRow: View {
    let row: ChatFolderBrowserModel.Row
    let isExpanded: Bool
    let isLoading: Bool
    let isEmpty: Bool
    let message: String?
    let action: () -> Void
    @BighelpThemeReader private var theme

    private var entry: HostFolderEntry { row.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.caption2, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(entry.isDirectory ? 1 : 0)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Image(systemName: symbol)
                        .font(.bighelp(.body))
                        .foregroundStyle(entry.isDirectory ? theme.action : theme.secondaryText)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let place = row.place {
                            Text(place)
                                .font(.bighelp(.caption, design: .monospaced))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    if isLoading { ProgressView().controlSize(.small) }
                }
                .padding(.leading, CGFloat(row.depth) * BighelpTokens.space16)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .bighelpPlainButtonStyle()
            .accessibilityLabel(entry.isDirectory ? "\(entry.name), folder" : entry.name)
            .accessibilityValue(entry.isDirectory ? ChatActivityDisclosureAccessibility.value(isExpanded: isExpanded) : "")
            .accessibilityIdentifier("chat.files.row.\(entry.name)")
            if isExpanded, let note = message ?? (isEmpty ? "Empty" : nil) {
                Text(note)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, CGFloat(row.depth + 1) * BighelpTokens.space16 + 44)
                    .padding(.bottom, BighelpTokens.space8)
            }
        }
    }

    private var symbol: String {
        if entry.isDirectory { return isExpanded ? "folder.fill" : "folder" }
        switch entry.preview {
        case .markdown: return "doc.richtext"
        case .picture: return "photo"
        case .text: return "doc.text"
        }
    }
}

/// A file from the tree, pushed over it: Markdown rendered (and editable, as everywhere), other
/// text as it is, a picture drawn. Anything else says it can't show here.
struct ChatFolderFileView: View {
    let entry: HostFolderEntry
    let context: ChatFolderContext
    @State private var markdown: MarkdownFileModel?

    var body: some View {
        Group {
            switch entry.preview {
            case .markdown:
                if let markdown { MarkdownFileContent(model: markdown) }
            case .picture:
                HostPictureView(entry: entry, folders: context.folders)
            case .text:
                HostTextFileView(entry: entry, files: context.files)
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if entry.preview == .markdown, markdown == nil {
                markdown = MarkdownFileModel(path: entry.path, access: context.files)
            }
        }
    }
}

/// A text file as it is, in monospace, a few hundred lines to a block so a long file scrolls well.
private struct HostTextFileView: View {
    let entry: HostFolderEntry
    let files: any HostTextFileAccess
    @State private var file: HostTextFile?
    @State private var blocks: [String] = []
    @State private var message: String?
    @BighelpThemeReader private var theme

    static let linesPerBlock = 200

    var body: some View {
        Group {
            if let file, !file.isBinary {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HostFilePathLine(path: file.path)
                        if file.isTruncated {
                            Label("Only the start of this long file shows here.", systemImage: "scissors")
                                .font(.bighelp(.footnote))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.bottom, BighelpTokens.space12)
                        }
                        ForEach(blocks.indices, id: \.self) { index in
                            Text(blocks[index])
                                .font(.bighelp(.caption, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(BighelpTokens.space16)
                }
                .accessibilityIdentifier("chat.files.text")
            } else if let message {
                ContentUnavailableView("Can't show \(entry.name)", systemImage: "doc.questionmark",
                                       description: Text(message))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar {
            if let file, !file.isBinary {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = file.text
                        BighelpHaptics.success()
                    }
                    .accessibilityIdentifier("chat.files.copy")
                }
            }
        }
        .task {
            guard file == nil else { return }
            do {
                let read = try await files.read(entry.path)
                blocks = Self.blocks(of: read.text)
                file = read
                message = read.isBinary ? "This file isn't text or a picture, so it can't show here." : nil
            } catch is CancellationError {
            } catch {
                message = "This file couldn't open. It may have moved, or Hermes can't read it."
            }
        }
    }

    static func blocks(of text: String) -> [String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return stride(from: 0, to: lines.count, by: linesPerBlock).map { start in
            lines[start..<min(start + linesPerBlock, lines.count)].joined(separator: "\n")
        }
    }
}

/// A picture from the computer, fitted to the page.
private struct HostPictureView: View {
    let entry: HostFolderEntry
    let folders: any HostFolderAccess
    @State private var image: UIImage?
    @State private var message: String?
    @BighelpThemeReader private var theme

    var body: some View {
        Group {
            if let image {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HostFilePathLine(path: entry.path)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
                            .accessibilityLabel(entry.name)
                            .accessibilityIdentifier("chat.files.picture")
                    }
                    .padding(BighelpTokens.space16)
                }
            } else if let message {
                ContentUnavailableView("Can't show \(entry.name)", systemImage: "photo",
                                       description: Text(message))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .task {
            guard image == nil else { return }
            do {
                let data = try await folders.picture(entry.path)
                if let decoded = UIImage(data: data) {
                    image = decoded
                } else {
                    message = "This picture is in a format that can't show here."
                }
            } catch is CancellationError {
            } catch {
                message = "This picture couldn't open. It may be too big, or Hermes can't read it."
            }
        }
    }
}

/// Where the open file is, in monospace, cut from the front so its name always shows.
private struct HostFilePathLine: View {
    let path: String
    @BighelpThemeReader private var theme

    var body: some View {
        Text(path)
            .font(.bighelp(.caption, design: .monospaced))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.bottom, BighelpTokens.space12)
            .accessibilityIdentifier("chat.files.file-path")
    }
}
