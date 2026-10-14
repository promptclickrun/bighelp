import SwiftUI

/// What the agent is doing on its screen right now: its turns that use the browser or
/// computer tools, in its chats open in the app. Work the app can't see (a chat it hasn't
/// opened, a scheduled task) isn't counted; nothing is ever made up.
@MainActor
struct BotScreenActivity {
    /// Turns using the screen now.
    let count: Int
    let usesBrowserOnly: Bool
    /// The newest step in plain words while it runs: "Opening stays.example…".
    let phrase: String?
    /// The chat whose turn used the screen last, for Stop task.
    let chat: ChatModel?

    init(chats: [ChatModel]) {
        var tasks: [(chat: ChatModel, last: ChatActivityEvent)] = []
        var browserOnly = true
        for chat in chats where chat.isSending {
            let events = chat.activityLedger.allEvents
            guard let turn = events.last?.turnID else { continue }
            let screen = events.filter { $0.turnID == turn && $0.kind == .tool && Self.usesScreen($0.toolName) }
            guard let last = screen.last else { continue }
            browserOnly = browserOnly && screen.allSatisfy { $0.toolName?.hasPrefix("browser_") == true }
            tasks.append((chat, last))
        }
        let newest = tasks.max { $0.last.occurredAt < $1.last.occurredAt }
        count = tasks.count
        usesBrowserOnly = browserOnly
        phrase = newest.flatMap { $0.last.lifecycle == .running ? $0.last.toolPhrase.live : nil }
        chat = newest.flatMap { $0.chat.canStop ? $0.chat : nil }
    }

    /// Hermes' tools that act on the agent's screen.
    static func usesScreen(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        return toolName.hasPrefix("browser_") || toolName.hasPrefix("computer_")
    }

    var title: String {
        let noun = usesBrowserOnly ? "browser task" : "screen task"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

/// The Screen tab's state: Hermes' answer about this agent's screen, a still picture
/// while it's on, and Start / Turn off.
@MainActor
@Observable
final class BotScreenTabModel {
    let agentID: String
    let service: any BotScreenService
    private(set) var status: BotScreenStatus?
    private(set) var picture: RFBFrame?
    private(set) var isWorking = false
    private(set) var message: String?
    /// Hermes' own words for the last failure, for Nerd Mode.
    private(set) var hermesWords: String?

    init(agentID: String, service: any BotScreenService) {
        self.agentID = agentID
        self.service = service
    }

    /// The tab shows once the host has answered. An older Hermes (no screens) never does.
    var showsTab: Bool { status != nil }

    func load() async {
        do {
            let next = try await service.status(agentID: agentID)
            status = next
            if !next.running { picture = nil }
        } catch {
            // Unknown method: older Hermes, no tab. Anything else: try again next time.
        }
    }

    func refreshPicture() async {
        guard status?.running == true else { return }
        do {
            switch try await service.thumbnail(agentID: agentID) {
            case .image(let frame): picture = frame
            case .hidden: picture = nil
            // Turned off elsewhere, or not drawn yet: ask what's going on.
            case .none: await load()
            }
        } catch {}
    }

    func start() async {
        await act("start the screen") { try await $0.service.start(agentID: $0.agentID) }
    }

    func turnOff() async {
        await act("turn off the screen") { try await $0.service.stop(agentID: $0.agentID) }
    }

    /// Start and stop from anywhere (the CLI, Hermes Desktop, the idle timer) and control
    /// changes show here as they happen.
    func listen() async {
        for await event in service.events() {
            guard let key = status?.profileKey, event.profileKey == key, var next = status else { continue }
            switch event {
            case .lease(_, let lease):
                guard lease.epoch >= next.lease.epoch else { continue }
                next.lease = lease
                if lease.holder == .human { picture = nil }
            case .status(let pushed):
                next = pushed
                if !pushed.running { picture = nil }
            }
            status = next
        }
    }

    private func act(_ action: String, _ body: (BotScreenTabModel) async throws -> BotScreenStatus) async {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        hermesWords = nil
        defer { isWorking = false }
        do {
            let next = try await body(self)
            status = next
            if !next.running { picture = nil }
        } catch {
            message = BotScreenMessage.sentence(for: error, doing: action)
            hermesWords = HermesRefusalMessage.sentence(in: error)
        }
    }
}

/// The agent's screen in its profile: a live still, what it's doing there, and the way in.
struct AgentScreenTab: View {
    let model: BotScreenTabModel
    let agentName: String
    /// The agent's chats open in the app, for what it's doing now and Stop task.
    let chats: [ChatModel]
    @State private var viewer: BotScreenViewerModel?
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            let activity = BotScreenActivity(chats: chats)
            if activity.count > 0 { activityRow(activity) }
            if let status = model.status { content(status) }
            if let message = model.message {
                Text(message)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.danger)
                if nerdModeEnabled, let words = model.hermesWords {
                    Text(words)
                        .font(.bighelp(.footnote).monospaced())
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
        .task(id: pollKey) {
            // Only while this tab shows, the app is in front, the screen is on and the
            // picture isn't hidden. A still every few seconds; nothing animates.
            guard pollKey.polls else { return }
            while !Task.isCancelled {
                await model.refreshPicture()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .task { await model.listen() }
        .bighelpFullScreenCover(item: $viewer, onDismiss: { Task { await model.load(); await model.refreshPicture() } }) { viewer in
            BotScreenViewer(model: viewer, chats: chats)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.screen")
    }

    private struct PollKey: Hashable {
        let polls: Bool
    }

    private var pollKey: PollKey {
        PollKey(polls: scenePhase == .active && viewer == nil && model.status?.running == true
                && model.status?.lease.holder == .agent)
    }

    @ViewBuilder
    private func content(_ status: BotScreenStatus) -> some View {
        if !status.supported {
            sentence("Screens work when Hermes runs on Linux, or runs its tools in a Docker sandbox.",
                     symbol: "display")
                .accessibilityIdentifier("agent.screen.unsupported")
        } else if !status.installed {
            notInstalled(status)
        } else if !status.running {
            stopped(status)
        } else {
            preview(status)
        }
    }

    private func activityRow(_ activity: BotScreenActivity) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: activity.usesBrowserOnly ? "globe" : "cursorarrow.rays")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.incomingMessageBackground))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                if let phrase = activity.phrase {
                    Text(phrase)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.screen.activity")
    }

    private func preview(_ status: BotScreenStatus) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Button { open(status) } label: {
                ZStack {
                    Color.black
                    if status.lease.holder == .human {
                        VStack(spacing: BighelpTokens.space8) {
                            Image(systemName: "person.fill.viewfinder")
                                .font(.bighelp(.title2))
                            Text("Someone is using this screen")
                                .font(.bighelp(.subheadline).weight(.semibold))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(BighelpTokens.space16)
                    } else if let picture = model.picture {
                        Image(decorative: picture.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .aspectRatio(status.size.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .bighelpPlainButtonStyle()
            .accessibilityLabel(status.lease.holder == .human
                                ? "\(agentName)'s screen. Someone is using it." : "\(agentName)'s screen")
            .accessibilityHint("Opens the screen.")
            .accessibilityIdentifier("agent.screen.preview")
            .overlay(alignment: .bottomTrailing) {
                Button { open(status) } label: {
                    Label("Open screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .background(Capsule().fill(Color.black.opacity(0.62)))
                        .contentShape(Capsule())
                }
                .bighelpPlainButtonStyle()
                .padding(BighelpTokens.space12)
                .accessibilityIdentifier("agent.screen.open")
            }
            if status.lease.holder == .agent {
                Button {
                    Task { await model.turnOff() }
                } label: {
                    Text("Turn off screen")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .bighelpPlainButtonStyle()
                .disabled(model.isWorking)
                .accessibilityIdentifier("agent.screen.turn-off")
            }
            if nerdModeEnabled { nerdDetails(status) }
        }
    }

    private func stopped(_ status: BotScreenStatus) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let blocker = status.blocker {
                sentence(status.isInSandbox
                         ? "The agent's sandbox needs a desktop image before its screen can start."
                         : "Your computer is low on memory, so the screen can't start right now.",
                         symbol: "exclamationmark.triangle")
                    .accessibilityIdentifier("agent.screen.blocked")
                if nerdModeEnabled { nerdText(blocker) }
            } else {
                sentence("The screen is off. Start it to watch \(agentName) use the browser, or to take over.",
                         symbol: "display")
                Button {
                    Task { await model.start() }
                } label: {
                    Label(model.isWorking ? "Starting…" : "Start screen", systemImage: "play.fill")
                        .font(.bighelp(.body).weight(.semibold))
                        .foregroundStyle(theme.actionForeground)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(theme.action))
                        .contentShape(Capsule())
                }
                .bighelpPlainButtonStyle()
                .disabled(model.isWorking)
                .accessibilityIdentifier("agent.screen.start")
            }
            if nerdModeEnabled { nerdDetails(status) }
        }
    }

    private func notInstalled(_ status: BotScreenStatus) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            sentence(status.isInSandbox
                     ? "The agent's sandbox needs a desktop image before it can have a screen."
                     : "Your computer needs the screen apps installed first. Whoever runs it can do that once.",
                     symbol: "shippingbox")
                .accessibilityIdentifier("agent.screen.not-installed")
            if nerdModeEnabled {
                if let command = status.installCommand {
                    HStack(alignment: .top, spacing: BighelpTokens.space8) {
                        nerdText(command)
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = command
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                                .contentShape(.rect)
                        }
                        .bighelpPlainButtonStyle()
                        .bighelpIconLabel("Copy the install command")
                        .accessibilityIdentifier("agent.screen.copy-install")
                    }
                } else if !status.missing.isEmpty {
                    nerdText("Missing: " + status.missing.joined(separator: ", "))
                }
            }
        }
    }

    private func nerdDetails(_ status: BotScreenStatus) -> some View {
        nerdText("\(status.size.width)×\(status.size.height) · \(status.placement)")
    }

    private func nerdText(_ text: String) -> some View {
        Text(text)
            .font(.bighelp(.footnote).monospaced())
            .foregroundStyle(theme.secondaryText)
            .textSelection(.enabled)
    }

    private func sentence(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.incomingMessageBackground))
            Text(text)
                .font(.bighelp(.body))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func open(_ status: BotScreenStatus) {
        viewer = BotScreenViewerModel(agentID: model.agentID, agentName: agentName, size: status.size,
                                      service: model.service)
    }
}

extension BotScreenViewerModel: Identifiable {}
