import SwiftUI

/// An agent's app, full screen (DESIGN.md › Agents' apps): Done, the app's title and how fresh its
/// data is, a ••• menu with Reload, and the page. When the page sends an answer, a panel shows the
/// exact message, and nothing goes until the person taps Send.
@MainActor
struct HTMLAppScreen: View {
    /// Sends the answer as the person's next message; throws when the chat can't send now.
    let send: @MainActor (String) throws -> Void

    @State private var model: HTMLAppScreenModel
    @State private var answerHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    init(app: HTMLAppCard, agentID: String, send: @escaping @MainActor (String) throws -> Void) {
        self.send = send
        _model = State(initialValue: HTMLAppScreenModel(app: app, agentID: agentID))
    }

    /// Data is read only while the page shows and bighelp is in front.
    private struct DataWatch: Hashable {
        let isOpen: Bool
        let isActive: Bool
        let loadID: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .overlay {
            if let pending = model.pendingAnswer { answerPanel(pending) }
        }
        .task { await model.open() }
        .task(id: dataWatch) {
            guard dataWatch.isOpen, dataWatch.isActive else { return }
            await model.watchData()
        }
        .onDisappear { model.cancelAnswer() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("html-app.screen")
    }

    private var dataWatch: DataWatch {
        let isOpen = if case .open = model.phase { true } else { false }
        return DataWatch(isOpen: isOpen, isActive: scenePhase == .active, loadID: model.loadID)
    }

    private func close() {
        model.cancelAnswer()
        dismiss()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: BighelpTokens.space8) {
            Button("Done", action: close)
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(minWidth: 60, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .accessibilityIdentifier("html-app.done")
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(model.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if let status {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.dataProblem == nil ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(status)
                    }
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Menu {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.reload() } }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .background(theme.surface, in: .circle)
                    .contentShape(.circle)
            }
            .accessibilityLabel("App options")
            .accessibilityIdentifier("html-app.options")
        }
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, 6)
    }

    /// "Live, updated 2:14 PM" for an app with data; nothing for one without.
    private var status: String? {
        guard model.isLive else { return nil }
        if let problem = model.dataProblem {
            return switch problem {
            case .missing: "Live, waiting for data"
            case .invalid, .tooLarge: "Live, the data can't be read"
            }
        }
        guard let updated = model.dataUpdatedAt else { return "Live" }
        return "Live, updated \(updated.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Page

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .opening:
            Text("Opening the app…")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        case .open(let html):
            HTMLAppWebView(appID: model.app.appID, html: html, sendsAnswers: model.sendsAnswers,
                           dataJSON: model.dataJSON, colorScheme: colorScheme,
                           onAnswer: { await model.requestAnswer($0) }, onClose: close)
                .id(model.loadID)
        case .failed(let error):
            VStack(spacing: BighelpTokens.space12) {
                Text(error.message)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                if error == .noConnection || error == .failed {
                    Button("Try again") { Task { await model.reload() } }
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .accessibilityIdentifier("html-app.retry")
                }
            }
            .padding(BighelpTokens.space24)
        }
    }

    // MARK: Answer

    private func answerPanel(_ pending: HTMLAppScreenModel.PendingAnswer) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { model.cancelAnswer() }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send this answer?")
                        .font(.bighelp(.title3, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                    Text("It goes in the chat as your next message.")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
                // As tall as the message, up to 240 points; a longer one scrolls.
                ScrollView {
                    answerText(pending.message)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { answerHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(answerHeight, 44), 240))
                .background(theme.surface, in: .rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.border, lineWidth: 0.5)
                }
                if let failure = model.sendFailure {
                    Text(failure)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    panelButton("Cancel", filled: false) { model.cancelAnswer() }
                        .accessibilityIdentifier("html-app.answer.cancel")
                    panelButton("Send", filled: true) { model.confirmAnswer(send) }
                        .accessibilityIdentifier("html-app.answer.send")
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .background(theme.canvas, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24,
                                                                 style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("html-app.answer")
        }
        .transition(.opacity)
    }

    private func answerText(_ message: String) -> some View {
        Text(message)
            .font(.bighelp(.body))
            .foregroundStyle(theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }

    private func panelButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(filled ? theme.actionForeground : theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: max(50, BighelpTokens.hitTarget))
                .background(filled ? theme.action : theme.surface, in: .rect(cornerRadius: 14, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
