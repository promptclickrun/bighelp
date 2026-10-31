import SwiftUI

/// Files an agent sent that are still on their way to this phone: a picture's
/// glow or a file's tile, the same size as what replaces it, in place of the
/// message's raw file line. When the app stopped trying (`failure`), or
/// nothing finished the load in `AgentFileLoad.stallAfter`, it says why, with
/// Try again: a loading tile never stays on screen for good.
struct PendingAgentFilesView: View {
    let fileNames: [String]
    var failure: AgentFileFailure?
    /// The reply is still arriving: its files are asked for once it ends.
    var isStreaming = false
    var onRetry: (() -> Void)?

    @State private var stalled = false
    @State private var attempt = 0

    var body: some View {
        if let shown = failure ?? (stalled ? .stalled : nil) {
            failedCard(shown)
        } else {
            // Counted only while bighelp is in front and the reply has ended: coming back, the
            // connection loads it first, and a reply still arriving hasn't asked yet.
            loading
                .task(id: "\(attempt) \(scenePhase == .active) \(isStreaming)") {
                    guard scenePhase == .active, !isStreaming else { return }
                    try? await Task.sleep(for: AgentFileLoad.stallAfter)
                    guard !Task.isCancelled else { return }
                    AgentFileLoad.log.notice("A message's files stayed loading on screen past the deadline")
                    stalled = true
                }
        }
    }

    private var loading: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
                .scrollIndicators(.hidden)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fileNames.count == 1 ? "Loading \(fileNames[0])" : "Loading \(fileNames.count) files")
        .accessibilityIdentifier("chat.message-attachments.loading")
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            ForEach(Array(fileNames.enumerated()), id: \.offset) { index, name in
                if Self.isPicture(name) {
                    BighelpImageGeneratingView(caption: "Loading your image", variant: .develop, size: .compact,
                                               aspectRatio: 4.0 / 3.0, phaseOffset: Double(index) * 0.4)
                        .frame(width: uiV3Enabled ? 208 : 176, height: uiV3Enabled ? 156 : 132)
                        .clipShape(.rect(cornerRadius: uiV3Enabled ? BighelpTokens.radius20 : BighelpTokens.radius12))
                } else {
                    fileTile(name)
                }
            }
        }
    }

    private func fileTile(_ name: String) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: Self.isVideo(name) ? "film.fill" : "doc.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(width: 36, height: 36)
                .background(theme.action.opacity(0.10), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .bighelpMessageFont(.label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Loading…")
                    .bighelpMessageFont(.metadata)
                    .bighelpShimmer(isActive: true)
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius12))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
    }

    /// Why the files didn't come, in plain words, and Try again on its own line.
    private func failedCard(_ failure: AgentFileFailure) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .top, spacing: BighelpTokens.space8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 36, height: 36)
                    .background(theme.secondaryText.opacity(0.10), in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .bighelpMessageFont(.label)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(failure.reason)
                        .bighelpMessageFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let onRetry {
                Button {
                    stalled = false
                    attempt += 1
                    onRetry()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("chat.message-attachments.retry")
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius12))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.message-attachments.failed")
    }

    private var title: String {
        guard fileNames.count > 1 else {
            return String(localized: "Couldn't load \(fileNames.first ?? String(localized: "this file"))")
        }
        return fileNames.allSatisfy(Self.isPicture)
            ? String(localized: "Couldn't load \(fileNames.count) pictures")
            : String(localized: "Couldn't load \(fileNames.count) files")
    }

    static func isPicture(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    static func isVideo(_ name: String) -> Bool {
        ["mp4", "m4v", "mov", "webm"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    @BighelpThemeReader private var theme: BighelpTheme
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.scenePhase) private var scenePhase
}

/// Try again on a message whose files stopped loading (`ChatModel.retryAgentFiles`).
struct ChatAgentFileRetry {
    let retry: @MainActor (_ itemID: String) -> Void
}

extension EnvironmentValues {
    @Entry var chatAgentFileRetry: ChatAgentFileRetry?
}
