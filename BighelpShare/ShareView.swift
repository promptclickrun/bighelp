import SwiftUI

/// What was shared, a note, and Save. It says plainly what happens next: nothing is sent from
/// here, and bighelp has to be opened to choose who gets it and send it, because iOS doesn't let a
/// share sheet open its app.
struct ShareView: View {
    @ObservedObject var model: ShareModel
    var cancel: () -> Void
    var done: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .saved { saved } else { form }
            }
            .navigationTitle("Save for bighelp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.phase != .saved {
                    ToolbarItem(placement: .cancellationAction) {
                        // Saving takes a moment and can't be undone halfway.
                        Button("Cancel", action: cancel)
                            .disabled(model.phase == .saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .saving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await model.save() } }
                                .bold()
                                .disabled(!model.canSave)
                        }
                    }
                }
            }
        }
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
                    Text("Nothing is saved while an item can't be. Cancel, then share again without it.")
                }
            }
            Section {
                TextField("Add a note (optional)", text: $model.note, axis: .vertical)
                    .lineLimit(1...6)
                    .disabled(model.phase == .saving)
            } footer: {
                if model.noteIsTooLong {
                    Text("Your note is too long.").foregroundStyle(.red)
                } else {
                    Text("Nothing is sent yet. In bighelp you choose the agent and chat, look it over, and send it yourself.")
                }
            }
        }
    }

    private var saved: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Saved for bighelp")
                .font(.headline)
            Text("Open bighelp to choose the agent and chat, then send it. It stays on this device until you send it or delete it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
