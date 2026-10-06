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
    let onWorkspaceTap: () -> Void
    /// Switches Settings to turn-based voice and reopens voice.
    var onUseTurnBased: (() -> Void)? = nil
    /// The chat's live work, so the avatar acts out what the agent is doing.
    var chatActivity: () -> AgentActivityKind = { .idle }

    var body: some View {
        Group {
            if presentation.conversationMode == .turnBased {
                VoiceView(model: presentation.model, agentID: agentID,
                          agentImageURL: agentImageURL,
                          permissionCenter: permissionCenter,
                          onEnded: onEnded, onWorkspaceTap: onWorkspaceTap,
                          chatActivity: chatActivity)
            } else if let live = presentation.liveModel {
                NavigationStack {
                    LiveVoiceView(model: live, agentID: agentID,
                                  agentImageURL: agentImageURL, onEnded: onEnded,
                                  onUseTurnBased: onUseTurnBased, chatActivity: chatActivity)
                }
            } else {
                NavigationStack {
                    LiveVoiceUnavailableView(agentID: agentID, agentImageURL: agentImageURL,
                                             onClose: onEnded, onUseTurnBased: onUseTurnBased)
                }
            }
        }
        .onDisappear {
            presentation.liveModel?.end()
            presentation.model.stopMonitoring()
        }
    }
}

/// Shown when Settings chose live voice but the host can't provide it. The
/// choice stays with Settings; this screen explains how to change it.
private struct LiveVoiceUnavailableView: View {
    let agentID: String?
    let agentImageURL: URL?
    let onClose: () -> Void
    let onUseTurnBased: (() -> Void)?

    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: BighelpTokens.space16) {
            Spacer()
            AvatarView(stableID: agentID ?? "agent", displayName: "Agent",
                       imageURL: agentImageURL, size: 140, state: .idle)
                .accessibilityHidden(true)
            Text("Live voice isn't available")
                .font(.bighelp(.title2).weight(.bold))
                .foregroundStyle(theme.primaryText)
            Text("Your Hermes computer doesn't support live voice yet. TTS voice mode listens on this \(BighelpPlatform.isMac ? "Mac" : "phone") and answers in the voice set up on your computer.")
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BighelpTokens.space32)
            Spacer()
            if let onUseTurnBased {
                Button(action: onUseTurnBased) {
                    Text("Use TTS voice mode")
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.actionForeground)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(theme.action, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, BighelpTokens.space24)
                .accessibilityIdentifier("voice.live-unavailable.use-turn-based")
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
