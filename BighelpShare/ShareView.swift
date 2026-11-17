import SwiftUI

/// What was shared, a note, and Send. It says who gets it: the default bot, in a new chat. Send saves
/// the share for bighelp and closes the sheet; bighelp does the sending (#1069).
struct ShareView: View {
    @ObservedObject var model: ShareModel
    var cancel: () -> Void
    var done: () -> Void

    var body: some View {
        NavigationStack {
            form
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Saving takes a moment and can't be undone halfway.
                        Button("Cancel", action: cancel)
                            .disabled(model.phase == .saving || model.phase == .saved)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .saving || model.phase == .saved {
                            ProgressView()
                        } else {
                            Button("Send") {
                                Task { if await model.send() { done() } }
                            }
                            .bold()
                            .disabled(!model.canSave)
                            .accessibilityIdentifier("share.send")
                        }
                    }
                }
        }
    }

    private var title: String {
        model.botName.map { String(localized: "Send to \($0)") } ?? String(localized: "Send to Bighelp")
    }

    private var whatHappens: String {
        if let name = model.botName {
            return String(localized: "Bighelp sends this to \(name) in a new chat.")
        }
        return String(localized: "Bighelp sends this to your default bot in a new chat.")
    }

    private var form: some View {
        Form {
            Section {
                ForEach(model.rows) { row in
                    ShareRowView(row: row)
                }
            } footer: {
                if case .failed(let message) = model.phase {
                    Text(message).foregroundStyle(.red)
                } else if !model.problems.isEmpty {
                    Text("Nothing is sent while an item can't be. Cancel, then share again without it.")
                }
            }
            Section {
                TextField("Add a note (optional)", text: $model.note, axis: .vertical)
                    .lineLimit(1...6)
                    .disabled(model.phase == .saving || model.phase == .saved)
            } footer: {
                if model.noteIsTooLong {
                    Text("Your note is too long.").foregroundStyle(.red)
                } else {
                    Text(whatHappens)
                }
            }
        }
    }
}

private struct ShareRowView: View {
    let row: ShareModel.Row

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(row.problem == nil ? Color.secondary : Color.red)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                if let problem = row.problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                } else if !row.detail.isEmpty {
                    Text(row.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if row.isReading { ProgressView() }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if row.problem != nil { return "exclamationmark.triangle" }
        switch row.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .picture: return "photo"
        case .file: return "doc"
        }
    }
}
