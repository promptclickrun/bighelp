import SwiftUI

/// Pick an agent, pick a chat or start a new one, say a line, send.
///
/// It follows the app's own voice for a first screen: a plain list, the agent's name,
/// and no decoration that is not carrying information.
struct ShareView: View {
    @ObservedObject var model: ShareModel
    /// Ends the share sheet. Also the way out of every dead end here.
    var complete: () -> Void
    /// Hands the chat that was just written to back to the app.
    var openChat: (String) -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.sentChatID == nil ? "Cancel" : "Done") { complete() }
                    }
                    if model.step == .compose, model.sentChatID == nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                Task { await model.send() }
                            } label: {
                                if model.busy { ProgressView() } else { Text("Send").bold() }
                            }
                            .disabled(!model.canSend)
                        }
                    }
                }
        }
        .task { await model.start() }
    }

    private var title: String {
        switch model.step {
        case .agents: return "Share to bighelp"
        case .chats: return model.agent?.name ?? "Chats"
        case .compose: return model.chat?.title ?? "New chat"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure, model.agents.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(failure)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        } else {
            switch model.step {
            case .agents: agentsList
            case .chats: chatsList
            case .compose: compose
            }
        }
    }

    private var agentsList: some View {
        List {
            if model.loading && model.agents.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking your computer…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.agents) { agent in
                Button {
                    Task { await model.open(agent) }
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 34, height: 34)
                            .overlay(Text(String(agent.name.prefix(1))).font(.headline))
                        Text(agent.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if !model.subtitle.isEmpty {
                Section {
                    Text(model.subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chatsList: some View {
        List {
            Section {
                Button {
                    model.compose(into: nil)
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
            }
            if !model.chats.isEmpty {
                Section("Recent") {
                    ForEach(model.chats) { chat in
                        Button {
                            model.compose(into: chat)
                        } label: {
                            Text(chat.title).foregroundStyle(.primary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = model.sentChatID {
                sent(id)
            } else {
                if !model.input.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.input.attachments) { attachment in
                                Label(attachment.fileName,
                                      systemImage: attachment.kind == .image ? "photo" : "doc")
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if let link = model.input.link {
                    Text(link)
                        .font(.footnote)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                TextEditor(text: $model.text)
                    .frame(minHeight: 120)
                    .padding(.horizontal, 12)
                    .overlay(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text("Say something about it (optional)")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                if let failure = model.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                Spacer()
            }
        }
        .padding(.top, 8)
    }

    private func sent(_ id: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Sent to \(model.agent?.name ?? "your agent")")
                .font(.headline)
            Text("It will be waiting in the chat when you open bighelp.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open in bighelp") { openChat(id) }
                .buttonStyle(.bordered)
            Button("Done") { complete() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}
