import SwiftUI

/// The expand icon next to a long instructions box (an agent's SOUL, a
/// personality). It only asks to open the full-screen editor; the form
/// presents it with `focusedTextEditor(…)` from its root, because a cover
/// hung on a list header didn't take the keyboard.
struct FocusedTextEditorButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.bighelp(.footnote).weight(.semibold))
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Expand \(title)")
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// Long instructions are hard to fine-tune in a small box. This opens the
    /// same text full screen. It edits the text in place, so every change is
    /// still there back in the form; Save also saves the form once the
    /// full-screen editor has closed.
    func focusedTextEditor(
        isPresented: Binding<Bool>,
        title: String,
        text: Binding<String>,
        placeholder: String = "",
        identifier: String,
        onSave: (() -> Void)? = nil
    ) -> some View {
        modifier(FocusedTextEditorPresentation(
            isPresented: isPresented, title: title, text: text,
            placeholder: placeholder, identifier: identifier, onSave: onSave
        ))
    }
}

private struct FocusedTextEditorPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let onSave: (() -> Void)?

    @State private var savesAfterClosing = false

    func body(content: Content) -> some View {
        content
            // Save waits for the editor to close, so the form can close its own sheet.
            #if targetEnvironment(macCatalyst)
            // A cover would fill the whole Mac window; a large sheet is the Mac's editor.
            .bighelpSheet(isPresented: $isPresented, onDismiss: closed) { editor.bighelpSheetSize(.large) }
            #else
            .bighelpFullScreenCover(isPresented: $isPresented, onDismiss: closed) { editor }
            #endif
            .onChange(of: isPresented) { _, presented in
                if presented { savesAfterClosing = false }
            }
    }

    private var editor: some View {
        FocusedTextEditor(
            title: title,
            text: $text,
            placeholder: placeholder,
            identifier: identifier,
            onSave: onSave == nil ? nil : {
                savesAfterClosing = true
                isPresented = false
            }
        )
    }

    private func closed() {
        guard savesAfterClosing else { return }
        savesAfterClosing = false
        onSave?()
    }
}

struct FocusedTextEditor: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let onSave: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.bighelp(.body))
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(title)
                .accessibilityIdentifier("\(identifier).focused")
                .padding(.horizontal, BighelpTokens.space12)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.top, 8)
                            .padding(.leading, BighelpTokens.space12 + 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas.ignoresSafeArea())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityHint("Keeps your changes and goes back")
                            .accessibilityIdentifier("\(identifier).done")
                            .bighelpToolbarText()
                    }
                    if let onSave {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save", action: onSave)
                                .fontWeight(.semibold)
                                .accessibilityIdentifier("\(identifier).save")
                        }
                    }
                }
                .onAppear { isFocused = true }
        }
    }

    @BighelpThemeReader private var theme
}
