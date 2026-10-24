#if os(iOS)
import CarPlay
import UIKit

/// Opening bighelp in CarPlay starts a voice chat with the agent picked in Settings › CarPlay
/// (else the one last picked in the car, else the default), ready to listen. The home is a list:
/// the agent's face, what it's doing and its steps on top, the other agents under it. The voice
/// screen shows over it while you talk: an overlay on iOS 27, presented on iOS 26.4.
@MainActor
final class BighelpCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayVoiceController?
    /// While the car shows bighelp, it's in use: the host connection stays open as it does for
    /// the iPhone's own screen, even with the iPhone locked in a pocket.
    private var releaseHost: (@MainActor () -> Void)?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        releaseHost?()
        releaseHost = BighelpShortcutService.holdHostConnection()
        let controller = CarPlayVoiceController(interface: interfaceController)
        self.controller = controller
        controller.begin()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.finish()
        controller = nil
        releaseHost?()
        releaseHost = nil
    }
}

/// CarPlay calls every handler (buttons, list rows, alerts) on its own queue, not the main
/// thread. A main-actor closure handed to it traps there (Swift 6 checks isolation), so each
/// handler is a plain `@Sendable` closure that hops to the main actor.
enum CarPlayCallbacks {
    static func button(_ action: @escaping @MainActor @Sendable () -> Void) -> @Sendable (CPButton) -> Void {
        { _ in Task { @MainActor in action() } }
    }

    static func barButton(_ action: @escaping @MainActor @Sendable () -> Void) -> @Sendable (CPBarButton) -> Void {
        { _ in Task { @MainActor in action() } }
    }

    static func alert(_ action: @escaping @MainActor @Sendable () -> Void) -> @Sendable (CPAlertAction) -> Void {
        { _ in Task { @MainActor in action() } }
    }

    static func listItem(_ action: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable (any CPSelectableListItem, @escaping () -> Void) -> Void {
        { _, completion in
            completion()
            Task { @MainActor in action() }
        }
    }

    /// A presentation's result, back on the main actor.
    static func done(_ action: @escaping @MainActor @Sendable (Bool) -> Void) -> @Sendable (Bool, (any Error)?) -> Void {
        { success, _ in Task { @MainActor in action(success) } }
    }
}

@MainActor
final class CarPlayVoiceController {
    private let interface: CPInterfaceController
    private let session: CarPlayVoiceSession
    private var home: CPListTemplate?
    private var voice: CPVoiceControlTemplate?
    /// The agent the voice screen's faces are for.
    private var voiceAgentID: String?
    private var isVoiceShown = false
    private var mirroring: Task<Void, Never>?
    private var shownPhase: CarPlayVoiceSession.Phase?
    private var shownHeader: CarPlayHeaderContent?
    private var shownAgents: [CarPlayAgentRow] = []
    private var faces: [String: UIImage] = [:]

    init(interface: CPInterfaceController, session: CarPlayVoiceSession = CarPlayVoiceSession()) {
        self.interface = interface
        self.session = session
    }

    func begin() {
        guard #available(iOS 26.4, *) else {
            // Voice apps arrived in CarPlay with iOS 26.4.
            let info = CPInformationTemplate(
                title: "bighelp", layout: .leading,
                items: [CPInformationItem(title: nil, detail: "Update your iPhone to talk to your agent in CarPlay.")],
                actions: [])
            interface.setRootTemplate(info, animated: false, completion: nil)
            return
        }
        let home = CPListTemplate(title: "bighelp", listHeader: header(for: content()), sections: [],
                                  assistantCellConfiguration: nil)
        self.home = home
        interface.setRootTemplate(home, animated: false, completion: nil)
        // Connecting starts with the car, not with the first look at the screen.
        talk()
        mirroring = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func finish() {
        mirroring?.cancel()
        mirroring = nil
        session.stop()
    }

    // MARK: Talking

    private func talk(agentID: String? = nil) {
        shownPhase = nil
        Task { await session.start(agentID: agentID) }
    }

    private func end() {
        session.stop()
        hideVoice()
    }

    /// Keeps the home and the voice screen in step with the conversation.
    private func refresh() {
        guard #available(iOS 26.4, *), let home else { return }
        let content = content()
        if content != shownHeader {
            shownHeader = content
            home.listHeader = header(for: content)
        }
        let rows = CarPlayAgentChoice.rows(for: session.agents, currentID: session.agent?.id,
                                           limit: min(CarPlayAgentChoice.maximumListed, Int(CPListTemplate.maximumItemCount)))
        if rows != shownAgents {
            shownAgents = rows
            home.updateSections(rows.isEmpty ? [] : [CPListSection(items: rows.map(item(for:)), header: "Agents",
                                                                    sectionIndexTitle: nil)])
        }
        let phase = session.phase
        guard phase != shownPhase else { return }
        shownPhase = phase
        switch phase {
        case .connecting, .listening, .working, .speaking:
            showVoice()
            voice?.activateVoiceControlState(withIdentifier: CarPlayVoiceStates.identifier(for: phase))
            updateMute()
        case .paused:
            hideVoice()
        case .problem(let message):
            hideVoice()
            showProblem(message)
        }
    }

    // MARK: Home

    private func content() -> CarPlayHeaderContent {
        CarPlayHeaderContent(agentID: session.agent?.id, name: session.agent?.name ?? "bighelp",
                             status: CarPlayHeaderContent.status(phase: session.phase, step: session.step),
                             earlierSteps: session.earlierSteps, isTalking: CarPlayHeaderContent.isTalking(session.phase))
    }

    @available(iOS 26.4, *)
    private func header(for content: CarPlayHeaderContent) -> CPListTemplateDetailsHeader {
        let face = content.agentID.flatMap { id in session.agent.map { faceImage(for: $0, id: id) } }
            ?? CarPlayVoiceStates.symbol("waveform", size: 80)
        let button: CPButton = content.isTalking
            ? CPButton(image: CarPlayVoiceStates.symbol("xmark"), handler: CarPlayCallbacks.button { [weak self] in self?.end() })
            : CPButton(image: CarPlayVoiceStates.symbol("waveform"), handler: CarPlayCallbacks.button { [weak self] in self?.talk() })
        button.title = content.isTalking ? "End" : "Talk"
        let body = content.earlierSteps.isEmpty ? [] : [NSAttributedString(string: content.earlierSteps.joined(separator: "\n"))]
        return CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: face), title: content.name,
                                           subtitle: content.status, bodyVariants: body, actionButtons: [button])
    }

    private func item(for row: CarPlayAgentRow) -> CPListItem {
        let agent = session.agents.first { $0.id == row.id }
        let face = agent.map { faceImage(for: $0, id: $0.id, size: 44) }
        let mark = row.isCurrent ? CarPlayVoiceStates.symbol("checkmark", size: 24) : nil
        let item = CPListItem(text: row.title, detailText: row.detail, image: face, accessoryImage: mark, accessoryType: .none)
        let id = row.id
        // Another agent: a new conversation with it, saved as the one the car talks to.
        item.handler = CarPlayCallbacks.listItem { [weak self] in self?.talk(agentID: id) }
        return item
    }

    private func faceImage(for agent: CarPlayAgent, id: String, size: CGFloat = 96) -> UIImage {
        let key = "\(id)|\(Int(size))"
        if let face = faces[key] { return face }
        let face = CarPlayFaces.face(for: agent, imageURL: session.agentImageURLs[id], size: size)
        faces[key] = face
        return face
    }

    // MARK: Voice screen

    /// Over the home while you talk. It's never the root and nothing is pushed over it.
    private func showVoice() {
        guard #available(iOS 26.4, *), !isVoiceShown else { return }
        let template = voiceTemplate()
        isVoiceShown = true
        let done = CarPlayCallbacks.done { [weak self] success in if !success { self?.isVoiceShown = false } }
        if #available(iOS 27.0, *) {
            interface.showOverlayTemplate(template, animated: true, completion: done)
        } else {
            interface.presentTemplate(template, animated: true, completion: done)
        }
    }

    private func hideVoice() {
        guard isVoiceShown else { return }
        isVoiceShown = false
        if #available(iOS 27.0, *) {
            interface.hideOverlayTemplate(animated: true, completion: nil)
        } else {
            interface.dismissTemplate(animated: true, completion: nil)
        }
    }

    /// The voice screen for the agent in use, with its face; made again when the agent changes.
    @available(iOS 26.4, *)
    private func voiceTemplate() -> CPVoiceControlTemplate {
        if let voice, voiceAgentID == session.agent?.id { return voice }
        let face = session.agent.map { faceImage(for: $0, id: $0.id, size: CarPlayFaces.voiceSize) }
        let template = CPVoiceControlTemplate(voiceControlStates: CarPlayVoiceStates.all(
            face: face, name: session.agent?.name,
            end: { [weak self] in self?.end() },
            // Stops listening and shows the agents under it, to pick another.
            agents: { [weak self] in self?.end() }))
        voice = template
        voiceAgentID = session.agent?.id
        return template
    }

    private func showProblem(_ message: String) {
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: "Try Again", style: .default, handler: CarPlayCallbacks.alert { [weak self] in
                self?.interface.dismissTemplate(animated: true, completion: nil)
                self?.talk()
            }),
            CPAlertAction(title: "OK", style: .cancel, handler: CarPlayCallbacks.alert { [weak self] in
                self?.interface.dismissTemplate(animated: true, completion: nil)
            }),
        ])
        interface.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Mute sits in the voice screen's top bar while the conversation runs.
    private func updateMute() {
        guard #available(iOS 26.4, *), let voice else { return }
        let mute = CPBarButton(title: session.isMuted ? "Unmute" : "Mute", handler: CarPlayCallbacks.barButton { [weak self] in
            self?.session.toggleMute()
            self?.updateMute()
        })
        voice.trailingNavigationBarButtons = [mute]
    }
}

/// What the home's header says: plain values, so the wording is testable without the car.
struct CarPlayHeaderContent: Equatable {
    var agentID: String?
    var name: String
    var status: String
    var earlierSteps: [String]
    var isTalking: Bool

    static func status(phase: CarPlayVoiceSession.Phase, step: String?) -> String {
        switch phase {
        case .connecting: "Connecting…"
        case .listening: "Listening"
        case .working: step ?? "Working…"
        case .speaking: step ?? "Speaking"
        case .paused: "Tap Talk to start"
        case .problem: "Couldn't connect"
        }
    }

    static func isTalking(_ phase: CarPlayVoiceSession.Phase) -> Bool {
        switch phase {
        case .connecting, .listening, .working, .speaking: true
        case .paused, .problem: false
        }
    }
}

/// The voice screen's states: a short line and the agent's face in a moving ring for each.
@MainActor
enum CarPlayVoiceStates {
    static let connecting = "connecting"
    static let listening = "listening"
    static let working = "working"
    static let speaking = "speaking"

    static func identifier(for phase: CarPlayVoiceSession.Phase) -> String {
        switch phase {
        case .connecting: connecting
        case .listening: listening
        case .working: working
        case .speaking: speaking
        case .paused, .problem: listening
        }
    }

    /// Each state offers End and Agents (back to the list of agents under it).
    static func all(
        face: UIImage?,
        name: String?,
        end: @escaping @MainActor @Sendable () -> Void,
        agents: @escaping @MainActor @Sendable () -> Void
    ) -> [CPVoiceControlState] {
        let who = name ?? "your agent"
        func picture(_ ring: CarPlayFaces.Ring, symbol fallback: String, values: [Double]) -> UIImage {
            face.map { CarPlayFaces.voice($0, ring: ring) } ?? animated([fallback], values: values)
        }
        let states = [
            CPVoiceControlState(identifier: connecting, titleVariants: ["Connecting to \(who)…", "Connecting…"],
                                image: picture(.connecting, symbol: "waveform", values: [0.1, 0.3, 0.1]), repeats: true),
            CPVoiceControlState(identifier: listening, titleVariants: ["Listening. Go ahead.", "Listening"],
                                image: picture(.listening, symbol: "waveform", values: [0.2, 0.5, 0.8, 1, 0.6, 0.3]), repeats: true),
            CPVoiceControlState(identifier: working, titleVariants: ["\(who) is working…", "Working…"],
                                image: picture(.working, symbol: "ellipsis", values: [0.33, 0.66, 1]), repeats: true),
            CPVoiceControlState(identifier: speaking, titleVariants: ["\(who) is speaking", "Speaking"],
                                image: picture(.speaking, symbol: "speaker.wave.3.fill", values: [0.33, 0.66, 1]), repeats: true),
        ]
        if #available(iOS 26.4, *) {
            for state in states {
                let stop = CPButton(image: symbol("xmark"), handler: CarPlayCallbacks.button(end))
                stop.title = "End"
                let list = CPButton(image: symbol("person.2"), handler: CarPlayCallbacks.button(agents))
                list.title = "Agents"
                state.actionButtons = [stop, list]
            }
        }
        return states
    }

    /// Lavender on the car's screen, like bighelp's actions.
    static let tint = UIColor(red: 0xC9 / 255, green: 0xB6 / 255, blue: 0xFF / 255, alpha: 1)

    static func symbol(_ name: String, size: CGFloat = 40, value: Double? = nil) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let image = value.flatMap { UIImage(systemName: name, variableValue: $0, configuration: configuration) }
            ?? UIImage(systemName: name, withConfiguration: configuration)
            ?? UIImage()
        return image.withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    private static func animated(_ names: [String], values: [Double]) -> UIImage {
        let frames = names.flatMap { name in values.map { symbol(name, size: 120, value: $0) } }
        return UIImage.animatedImage(with: frames, duration: 0.25 * Double(frames.count)) ?? frames[0]
    }
}
#endif
