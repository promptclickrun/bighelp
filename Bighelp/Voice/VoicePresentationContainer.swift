import SwiftUI
import UIKit

/// Presentation choice is owned by Settings before this surface is created.
/// Neither mode can silently fall back to the other after media starts.
struct VoicePresentationContainer: View {
    let presentation: VoicePresentation
    let agentID: String?
    /// The agent's photo, when it has one; otherwise the persona avatar shows.
    var agentImageURL: URL? = nil
    let permissionCenter: PermissionCenter
    let onEnded: () -> Void
    /// Opens the chat, where voice isn't over it (the agent in the room). Nil over a chat.
    var onOpenChat: (() -> Void)? = nil
    /// Switches Settings to turn-based voice and reopens voice.
    var onUseTurnBased: (() -> Void)? = nil
    /// Opens live voice again, once what stopped it may be gone.
    var onTryAgain: (() -> Void)? = nil
    /// The chat's live work, so the avatar acts out what the agent is doing.
    var chatActivity: () -> AgentActivityKind = { .idle }
    /// The step the agent is on, in plain words ("Checking your calendars…").
    var chatStep: () -> String? = { nil }

    var body: some View {
        Group {
            if presentation.conversationMode == .turnBased {
                VoiceView(model: presentation.model, agentID: agentID,
                          agentImageURL: agentImageURL,
                          permissionCenter: permissionCenter,
                          onEnded: onEnded, onOpenChat: onOpenChat,
                          chatActivity: chatActivity, chatStep: chatStep)
            } else if let live = presentation.liveModel {
                NavigationStack {
                    LiveVoiceView(model: live, agentID: agentID,
                                  agentImageURL: agentImageURL, onEnded: onEnded,
                                  onUseTurnBased: onUseTurnBased, chatActivity: chatActivity,
                                  chatStep: chatStep)
                }
            } else {
                NavigationStack {
                    LiveVoiceUnavailableView(reason: presentation.liveUnavailable ?? .connecting,
                                             agentID: agentID, agentImageURL: agentImageURL,
                                             onClose: onEnded, onUseTurnBased: onUseTurnBased,
                                             onTryAgain: onTryAgain)
                }
            }
        }
        .onDisappear {
            presentation.liveModel?.end()
            presentation.model.stopMonitoring()
        }
    }
}

/// Shown when Settings chose live voice but it can't start here: says why and what fixes it.
/// The choice stays with Settings; Use TTS voice mode changes it.
private struct LiveVoiceUnavailableView: View {
    let reason: LiveVoiceUnavailable
    let agentID: String?
    let agentImageURL: URL?
    let onClose: () -> Void
    let onUseTurnBased: (() -> Void)?
    let onTryAgain: (() -> Void)?

    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: BighelpTokens.space16) {
            Spacer()
            AvatarView(stableID: agentID ?? "agent", displayName: "Bot",
                       imageURL: agentImageURL, size: 140, state: .idle)
                .accessibilityHidden(true)
            Text(reason.title)
                .font(.bighelp(.title2).weight(.bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            Text(reason.message)
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BighelpTokens.space32)
                .accessibilityIdentifier("voice.live-unavailable.message")
            if onUseTurnBased != nil {
                Text("With Take turns, this \(BighelpPlatform.isMac ? "Mac" : "phone") listens and the voice set up on your computer answers.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, BighelpTokens.space32)
            }
            Spacer()
            if let onUseTurnBased {
                Button(action: onUseTurnBased) {
                    Text("Take turns instead")
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.actionForeground)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(theme.action, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, BighelpTokens.space24)
                .accessibilityIdentifier("voice.live-unavailable.use-turn-based")
            }
            if let onTryAgain, reason.canTryAgain {
                Button(action: onTryAgain) {
                    Text("Try Again")
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.action)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay(Capsule().strokeBorder(theme.action, lineWidth: 1.5))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, BighelpTokens.space24)
                .accessibilityIdentifier("voice.live-unavailable.try-again")
            }
            // Close is secondary when turn-based voice is the way forward.
            Button(action: onClose) {
                Text("Close")
                    .font(.bighelp(.headline))
                    .foregroundStyle(onUseTurnBased == nil ? theme.actionForeground : theme.action)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(onUseTurnBased == nil ? theme.action : .clear, in: .capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.horizontal, BighelpTokens.space24)
            .padding(.bottom, BighelpTokens.space24)
            .accessibilityIdentifier("voice.live-unavailable.close")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { VoiceStageBackground(agentColor: AgentPersona(stableID: agentID ?? "agent").color) }
        .navigationTitle("Live voice")
        .navigationBarTitleDisplayMode(.inline)
        // Contain, so the buttons keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.live-unavailable")
    }
}

/// Attach to a truncated row using its canonical row ID (not a display index).
/// Merely rendering this button performs no host or attachment request.
struct BighelpSessionContentDisclosure: View {
    let sessionID: String
    let rowID: String
    @Environment(\.bighelpSessionContentReader) private var reader
    @State private var isPresented = false

    var body: some View {
        if let reader {
            Button {
                isPresented = true
            } label: {
                Label("Read complete content", systemImage: "doc.text.magnifyingglass")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("chat.complete-content.\(rowID)")
            .bighelpSheet(isPresented: $isPresented) {
                BighelpSessionContentSheet(sessionID: sessionID, rowID: rowID, reader: reader)
                    .bighelpSheetSize(.standard)
            }
        }
    }
}

private struct BighelpSessionContentSheet: View {
    let sessionID: String
    let rowID: String
    let reader: BighelpSessionContentReader
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var pages: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if content != nil {
                        ForEach(pages.indices, id: \.self) { index in
                            Text(pages[index])
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let errorMessage {
                        ContentUnavailableView("Content unavailable", systemImage: "doc.badge.ellipsis",
                                               description: Text(errorMessage))
                    } else {
                        ProgressView("Loading complete content")
                    }
                }
                .padding()
            }
            .navigationTitle("Complete content")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let content {
                        Button("Copy all", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = content
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .task(id: CanonicalContentReference(sessionID: sessionID, rowID: rowID)) {
                content = nil
                pages = []
                errorMessage = nil
                do {
                    let value = try await reader.load(sessionID, rowID)
                    try Task.checkCancellation()
                    let preparation = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let text: String
                        // A referenced assistant tool-call row can also contain
                        // omitted arguments. In that case retain the whole row,
                        // not just its prose content, in both reader and copy.
                        if let source = value.object,
                           source["tool_calls"]?.array?.isEmpty != false,
                           let original = source["content"]?.string {
                            text = original
                        } else {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                            text = String(decoding: try encoder.encode(value), as: UTF8.self)
                        }
                        let pages = ChatToolDetailPreview.pages(text, isCancelled: { Task.isCancelled })
                        try Task.checkCancellation()
                        return (text, pages)
                    }
                    let prepared = try await withTaskCancellationHandler {
                        try await preparation.value
                    } onCancel: { preparation.cancel() }
                    try Task.checkCancellation()
                    content = prepared.0
                    pages = prepared.1
                } catch is CancellationError {
                } catch {
                    errorMessage = "This saved content could not be verified. Reopen the conversation and try again."
                }
            }
        }
    }
}
