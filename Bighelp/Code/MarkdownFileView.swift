import SwiftUI

/// One Markdown file on the Hermes computer in the viewer: rendered, or as text while
/// editing. Save reads the file again first; if it changed on the computer since it
/// opened (an agent wrote it, say), the person chooses: replace it, or reload.
@MainActor
@Observable
final class MarkdownFileModel {
    let path: String
    private(set) var file: HostTextFile?
    var draft = ""
    private(set) var isEditing = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    /// Save found a newer file on the computer; the person picks what wins.
    var hasConflict = false

    @ObservationIgnored private let access: any HostTextFileAccess

    init(path: String, access: any HostTextFileAccess) {
        self.path = path
        self.access = access
    }

    var name: String { (path as NSString).lastPathComponent }
    var hasChanges: Bool { isEditing && draft != file?.text }
    var canEdit: Bool { file?.isEditable == true }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            file = try await access.read(path)
            errorMessage = file?.isBinary == true ? "This file isn't text." : nil
        } catch is CancellationError {
        } catch {
            errorMessage = "This file couldn't open. It may have moved, or Hermes can't read it."
        }
    }

    func beginEditing() {
        guard let file, file.isEditable else { return }
        draft = file.text
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        draft = ""
    }

    /// Saves `draft`. Without `replacing`, a file that changed on the computer is not overwritten.
    @discardableResult
    func save(replacing: Bool = false) async -> Bool {
        guard let opened = file, isEditing else { return false }
        guard draft.utf8.count <= HostTextFile.maximumSaveBytes else {
            errorMessage = "This file is too long to save from here."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if !replacing {
                let current = try await access.read(path)
                guard current.text == opened.text else {
                    hasConflict = true
                    return false
                }
            }
            try await access.write(path, text: draft)
            file = HostTextFile(path: opened.path, text: draft, isTruncated: false, isBinary: false)
            isEditing = false
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = "Your changes weren't saved. Check your connection, then try Save again."
            return false
        }
    }

    /// Drops the edit and shows the computer's current file.
    func reload() async {
        cancelEditing()
        await load()
    }
}

/// Where a chat's Markdown paths point: its session's folder on the computer.
struct HostFileLinkContext {
    let folder: String
    let files: any HostTextFileAccess
}

private struct OpensHostFilesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a chat whose Markdown paths open the viewer; message text links them.
    var opensHostFiles: Bool {
        get { self[OpensHostFilesKey.self] }
        set { self[OpensHostFilesKey.self] = newValue }
    }
}

extension View {
    /// Markdown file paths in this chat's messages open the viewer, resolved against `context`'s folder.
    func hostFileLinks(_ context: HostFileLinkContext?) -> some View {
        modifier(HostFileLinks(context: context))
    }
}

private struct HostFileLinks: ViewModifier {
    let context: HostFileLinkContext?
    @Environment(\.openURL) private var outerOpenURL
    @State private var opened: OpenedFile?

    struct OpenedFile: Identifiable {
        let path: String
        var id: String { path }
    }

    func body(content: Content) -> some View {
        if let context {
            content
                .environment(\.opensHostFiles, true)
                .environment(\.openURL, OpenURLAction { url in
                    guard let path = HostFileLink.path(from: url) else {
                        outerOpenURL(url)
                        return .handled
                    }
                    opened = OpenedFile(path: HostFileLink.resolve(path, in: context.folder))
                    return .handled
                })
                .bighelpSheet(item: $opened) { file in
                    MarkdownFileSheet(path: file.path, access: context.files)
                        .bighelpSheetSize(.large)
                }
        } else {
            content
        }
    }
}

/// The viewer as its own sheet, with Done.
struct MarkdownFileSheet: View {
    @State private var model: MarkdownFileModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDiscard = false

    init(path: String, access: any HostTextFileAccess) {
        _model = State(initialValue: MarkdownFileModel(path: path, access: access))
    }

    var body: some View {
        NavigationStack {
            MarkdownFileContent(model: model)
                .navigationTitle(model.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            if model.hasChanges { confirmsDiscard = true } else { dismiss() }
                        }
                        .accessibilityIdentifier("markdown-file.done")
                    }
                }
                .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                    Button("Discard changes", role: .destructive) { dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
        }
        .interactiveDismissDisabled(model.hasChanges)
    }
}

/// The viewer's body: the file rendered, or a text editor while editing. Its Edit and
/// Save buttons join whatever navigation bar it is in.
struct MarkdownFileContent: View {
    let model: MarkdownFileModel

    var body: some View {
        Group {
            if model.isEditing {
                editor
            } else if let file = model.file, !file.isBinary {
                rendered(file)
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Can't open \(model.name)", systemImage: "doc.questionmark",
                                       description: Text(model.errorMessage ?? "Try again in a moment."))
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actionButton }
        }
        .alert("This file changed on your computer", isPresented: Binding(
            get: { model.hasConflict }, set: { model.hasConflict = $0 })) {
            Button("Replace it with mine") { Task { await model.save(replacing: true) } }
            Button("Reload theirs", role: .cancel) { Task { await model.reload() } }
        } message: {
            Text("Someone else saved \(model.name) after you opened it.")
        }
        .task { if model.file == nil { await model.load() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-file")
    }

    private func rendered(_ file: HostTextFile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text(file.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityIdentifier("markdown-file.path")
                if file.isTruncated {
                    Label("Only the start of this long file shows here, so it can't be edited.",
                          systemImage: "scissors")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
                MarkdownMessageView(document: MarkdownDocument(file.text), primaryText: theme.primaryText,
                                    secondaryText: theme.secondaryText, accent: theme.action)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("markdown-file.rendered")
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(BighelpTokens.space16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .bighelpRefreshable { await model.load() }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .padding(BighelpTokens.space12)
            }
            TextEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, BighelpTokens.space12)
                .bighelpMacFieldArea()
                .accessibilityIdentifier("markdown-file.editor")
        }
    }

    @ViewBuilder private var actionButton: some View {
        if model.isEditing {
            HStack(spacing: BighelpTokens.space12) {
                Button("Cancel") { model.cancelEditing() }
                    .accessibilityIdentifier("markdown-file.cancel")
                Button {
                    Task { await model.save() }
                } label: {
                    if model.isSaving { ProgressView() } else { Text("Save").bold() }
                }
                .disabled(!model.hasChanges || model.isSaving)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("markdown-file.save")
            }
        } else if model.canEdit {
            Button("Edit") { model.beginEditing() }
                .accessibilityIdentifier("markdown-file.edit")
        }
    }

    @BighelpThemeReader private var theme
}
