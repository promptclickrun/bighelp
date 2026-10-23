#if os(iOS)
import CarPlay
import UIKit

/// Opening bighelp in CarPlay starts a new voice chat with the agent you last
/// picked in the car (else your default agent), ready to listen. CarPlay shows
/// only what the conversation is doing; Agents opens the one list, to pick who
/// to talk to.
@MainActor
final class BighelpCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayVoiceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        let controller = CarPlayVoiceController(interface: interfaceController)
        self.controller = controller
        controller.begin()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.finish()
        controller = nil
    }
}

@MainActor
final class CarPlayVoiceController {
    private let interface: CPInterfaceController
    private let session: CarPlayVoiceSession
    private var template: CPVoiceControlTemplate?
    private var mirroring: Task<Void, Never>?
    private var shownPhase: CarPlayVoiceSession.Phase?
    private var agentLoad: Task<Void, Never>?

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
        let template = CPVoiceControlTemplate(voiceControlStates: CarPlayVoiceStates.all(
            end: { [weak self] in self?.session.stop() },
            talk: { [weak self] in self?.restart() },
            agents: { [weak self] in self?.showAgents() }))
        self.template = template
        interface.setRootTemplate(template, animated: false, completion: nil)
        updateButtons()
        Task { await session.start() }
        mirroring = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.show(self.session.phase)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func finish() {
        mirroring?.cancel()
        mirroring = nil
        agentLoad?.cancel()
        agentLoad = nil
        session.stop()
    }

    private func show(_ phase: CarPlayVoiceSession.Phase) {
        guard phase != shownPhase, let template else { return }
        shownPhase = phase
        switch phase {
        case .connecting: template.activateVoiceControlState(withIdentifier: CarPlayVoiceStates.connecting)
        case .listening: template.activateVoiceControlState(withIdentifier: CarPlayVoiceStates.listening)
        case .working: template.activateVoiceControlState(withIdentifier: CarPlayVoiceStates.working)
        case .speaking: template.activateVoiceControlState(withIdentifier: CarPlayVoiceStates.speaking)
        case .paused: template.activateVoiceControlState(withIdentifier: CarPlayVoiceStates.paused)
        case .problem(let message):
            template.activateVoiceControlState(withIdentifier: CarPlayVoiceStates.paused)
            showProblem(message)
        }
        updateButtons()
    }

    private func showProblem(_ message: String) {
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: "Try Again", style: .default) { [weak self] _ in
                self?.interface.dismissTemplate(animated: true, completion: nil)
                self?.restart()
            },
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                self?.interface.dismissTemplate(animated: true, completion: nil)
            },
        ])
        interface.presentTemplate(alert, animated: true, completion: nil)
    }

    private func restart(agentID: String? = nil) {
        shownPhase = nil
        Task { await session.start(agentID: agentID) }
    }

    // MARK: Agents

    /// Ends listening (the audio session goes with it) and opens the agent
    /// list one level above the voice screen. Never deeper than two templates.
    private func showAgents() {
        guard interface.templates.count < 2 else { return }
        session.stop()
        let list = CPListTemplate(title: "Agents", sections: [Self.section([Self.message("Loading agents…")])])
        interface.pushTemplate(list, animated: true, completion: nil)
        loadAgents(into: list)
    }

    private func loadAgents(into list: CPListTemplate) {
        agentLoad?.cancel()
        agentLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            let limit = min(CarPlayAgentChoice.maximumListed, Int(CPListTemplate.maximumItemCount))
            do {
                let rows = try await session.agentRows(limit: limit)
                guard !Task.isCancelled else { return }
                if rows.isEmpty {
                    list.updateSections([Self.section([Self.message("No agents yet", detail: "Add one in bighelp on your iPhone.")])])
                    return
                }
                list.updateSections([Self.section(rows.map { row in
                    let item = Self.item(for: row)
                    item.handler = { [weak self] _, completion in
                        self?.choose(agentID: row.id)
                        completion()
                    }
                    return item
                })])
            } catch {
                guard !Task.isCancelled else { return }
                let retry = Self.message("Couldn't load your agents", detail: "Tap to try again.", enabled: true)
                retry.handler = { [weak self] _, completion in
                    list.updateSections([Self.section([Self.message("Loading agents…")])])
                    self?.loadAgents(into: list)
                    completion()
                }
                list.updateSections([Self.section([retry])])
            }
        }
    }

    /// A pick goes back to the voice screen and starts talking to that agent.
    private func choose(agentID: String) {
        interface.popTemplate(animated: true, completion: nil)
        restart(agentID: agentID)
    }

    private static func section(_ items: [CPListItem]) -> CPListSection {
        CPListSection(items: items)
    }

    private static func message(_ text: String, detail: String? = nil, enabled: Bool = false) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail)
        item.isEnabled = enabled
        return item
    }

    private static func item(for row: CarPlayAgentRow) -> CPListItem {
        let mark = row.isCurrent ? CarPlayVoiceStates.symbol("checkmark", size: 24) : nil
        return CPListItem(text: row.title, detailText: row.detail, image: nil, accessoryImage: mark, accessoryType: .none)
    }

    /// Mute sits in the top bar while the conversation runs.
    private func updateButtons() {
        guard #available(iOS 26.4, *), let template else { return }
        let running = switch session.phase {
        case .paused, .problem: false
        default: true
        }
        guard running else {
            template.trailingNavigationBarButtons = []
            return
        }
        let mute = CPBarButton(title: session.isMuted ? "Unmute" : "Mute") { [weak self] _ in
            self?.session.toggleMute()
            self?.updateButtons()
        }
        template.trailingNavigationBarButtons = [mute]
    }
}

/// The voice screen's states: a short line and a moving picture for each.
@MainActor
enum CarPlayVoiceStates {
    static let connecting = "connecting"
    static let listening = "listening"
    static let working = "working"
    static let speaking = "speaking"
    static let paused = "paused"

    /// Running states offer End; the paused one offers Talk. Each also offers
    /// Agents, the second of the two buttons a state can hold.
    static func all(
        end: @escaping @MainActor () -> Void,
        talk: @escaping @MainActor () -> Void,
        agents: @escaping @MainActor () -> Void
    ) -> [CPVoiceControlState] {
        let states = [
            CPVoiceControlState(identifier: connecting, titleVariants: ["Connecting to your agent…", "Connecting…"],
                                image: animated(["waveform"], values: [0.1, 0.3, 0.1]), repeats: true),
            CPVoiceControlState(identifier: listening, titleVariants: ["Listening. Go ahead.", "Listening"],
                                image: animated(["waveform"], values: [0.2, 0.5, 0.8, 1, 0.6, 0.3]), repeats: true),
            CPVoiceControlState(identifier: working, titleVariants: ["Thinking…"],
                                image: animated(["ellipsis"], values: [0.33, 0.66, 1]), repeats: true),
            CPVoiceControlState(identifier: speaking, titleVariants: ["Speaking"],
                                image: animated(["speaker.wave.3.fill"], values: [0.33, 0.66, 1]), repeats: true),
            CPVoiceControlState(identifier: paused, titleVariants: ["Paused. Tap Talk to start again.", "Paused"],
                                image: symbol("pause.circle", size: 120), repeats: false),
        ]
        if #available(iOS 26.4, *) {
            for state in states {
                let first: CPButton
                if state.identifier == paused {
                    first = CPButton(image: symbol("waveform")) { _ in talk() }
                    first.title = "Talk"
                } else {
                    first = CPButton(image: symbol("xmark")) { _ in end() }
                    first.title = "End"
                }
                let second = CPButton(image: symbol("person.2")) { _ in agents() }
                second.title = "Agents"
                state.actionButtons = [first, second]
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
