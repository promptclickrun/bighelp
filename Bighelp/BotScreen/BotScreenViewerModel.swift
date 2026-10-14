import CoreGraphics
import Foundation
import Observation

/// The open screen: one RFB session at a time, who's in control, and what to do when
/// the socket closes. Input goes out only while this viewer holds control (Hermes drops
/// anyone else's anyway). Closing hands control back.
@MainActor
@Observable
final class BotScreenViewerModel {
    enum Phase: Equatable {
        case connecting
        case live
        /// Stopped trying; the sentence says why, in plain words.
        case ended(String)
    }

    let agentID: String
    let agentName: String
    private(set) var phase = Phase.connecting
    private(set) var control = BotScreenControl()
    /// The screen's size in pixels: the picture's, or Hermes' setting before one arrives.
    private(set) var screenSize: BotScreenSize
    private(set) var desktopName: String?
    private(set) var hasPicture = false
    private(set) var isChangingControl = false
    /// A short note that fades on its own: "Someone else took control."
    private(set) var notice: String?
    /// Bumped by Try again; the view restarts `run()` when it changes.
    private(set) var attempt = 0
    /// While in control: touches click and drag on the screen (true), or move and zoom the view.
    var touchesDriveScreen = true
    var showsKeyboard = false

    /// The canvas draws pictures as they come, without redrawing the SwiftUI around it.
    @ObservationIgnored var frameSink: ((RFBFrame) -> Void)? {
        didSet { if let lastFrame { frameSink?(lastFrame) } }
    }
    @ObservationIgnored private(set) var lastFrame: RFBFrame?
    @ObservationIgnored private let service: any BotScreenService
    @ObservationIgnored private var session: RFBSession?
    @ObservationIgnored private var transport: (any RFBTransport)?
    @ObservationIgnored private var profileKey: String?
    @ObservationIgnored private var reconnects = BotScreenReconnects()
    @ObservationIgnored private var buttons: RFBButtons = []
    @ObservationIgnored private var pointer = CGPoint.zero
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(agentID: String, agentName: String, size: BotScreenSize, service: any BotScreenService) {
        self.agentID = agentID
        self.agentName = agentName
        screenSize = size
        self.service = service
    }

    var isInControl: Bool { control.holder == .me }

    // MARK: Connection

    /// Connects and stays connected until the view goes away or Hermes says the screen is
    /// gone. Run from the viewer's `.task(id: attempt)`; cancelling it closes the socket.
    func run() async {
        guard !isClosed else { return }
        phase = .connecting
        let events = Task { [weak self, service] in
            for await event in service.events() { self?.receive(event) }
        }
        defer { events.cancel() }
        while !Task.isCancelled, !isClosed {
            let end: BotScreenStreamEnd
            do {
                end = try await attach()
            } catch {
                guard !Task.isCancelled, !isClosed else { return }
                if let sentence = Self.endingSentence(for: error) {
                    phase = .ended(sentence)
                    return
                }
                end = .dropped
            }
            guard !Task.isCancelled, !isClosed else { return }
            if end == .controlTaken { post(notice: "Someone else took control.") }
            guard let delay = reconnects.delay(after: end) else {
                phase = .ended(Self.sentence(for: end))
                return
            }
            if phase == .live { phase = .connecting }
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func retry() {
        guard !isClosed else { return }
        reconnects = BotScreenReconnects()
        phase = .connecting
        attempt += 1
    }

    /// One attach: a fresh ticket, the socket, then pictures until it closes.
    private func attach() async throws -> BotScreenStreamEnd {
        let observation = try await service.observe(agentID: agentID, viewerID: control.viewerID)
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        control.adopt(viewerID: observation.viewerID)
        control.apply(observation.status.lease)
        profileKey = observation.status.profileKey
        if !hasPicture { screenSize = observation.status.size }
        // Still this person's from before the app went away: keep it, under the new ID.
        if control.holder == .meBeforeReconnect { await takeControl() }
        let transport = try await service.openStream(observation)
        guard !Task.isCancelled, !isClosed else {
            transport.close(handBack: true)
            throw CancellationError()
        }
        let session = RFBSession(transport: transport)
        self.session = session
        self.transport = transport
        defer {
            if self.session === session {
                self.session = nil
                self.transport = nil
            }
        }
        do {
            try await session.run(
                onServerInit: { [weak self] info in await self?.serverReady(info) },
                onFrame: { [weak self] frame in await self?.show(frame) })
            return BotScreenStreamEnd(closeCode: transport.closeCode)
        } catch RFBError.unsupportedSecurity {
            throw RFBError.unsupportedSecurity
        } catch {
            if Task.isCancelled || isClosed { throw CancellationError() }
            return BotScreenStreamEnd(closeCode: transport.closeCode)
        }
    }

    private func serverReady(_ info: RFBSession.ServerInfo) {
        guard !isClosed else { return }
        desktopName = info.name.isEmpty ? nil : info.name
        screenSize = BotScreenSize(width: info.width, height: info.height)
    }

    private func show(_ frame: RFBFrame) {
        guard !isClosed else { return }
        lastFrame = frame
        frameSink?(frame)
        if screenSize.width != frame.width || screenSize.height != frame.height {
            screenSize = BotScreenSize(width: frame.width, height: frame.height)
        }
        if !hasPicture { hasPicture = true }
        if phase != .live {
            phase = .live
            reconnects.connected()
        }
    }

    private func receive(_ event: BotScreenEvent) {
        guard !isClosed, let profileKey, event.profileKey == profileKey else { return }
        switch event {
        case .lease(_, let lease):
            apply(lease)
        case .status(let status):
            apply(status.lease)
            // Turned off elsewhere: the socket goes too, and the next attach says so.
            if !status.running { transport?.close(handBack: false) }
        }
    }

    private func apply(_ lease: BotScreenLease) {
        let before = control.holder
        guard control.apply(lease) else { return }
        let after = control.holder
        if before == .me, after != .me {
            releaseHeldInput()
            showsKeyboard = false
            if after == .someoneElse { post(notice: "Someone else took control.") }
        }
    }

    // MARK: Control

    func takeControl() async {
        guard let viewerID = control.viewerID, !isChangingControl, !isClosed else { return }
        isChangingControl = true
        defer { isChangingControl = false }
        do {
            let lease = try await service.takeControl(agentID: agentID, viewerID: viewerID)
            // Closed while asking: the screen must not stay in a gone viewer's hands.
            if isClosed {
                if lease.isHeld(byViewerID: viewerID) {
                    _ = try? await service.handBack(agentID: agentID, viewerID: viewerID)
                }
                return
            }
            apply(lease)
        } catch {
            guard !isClosed else { return }
            post(notice: "Couldn't take control. Try again.")
        }
    }

    func handBack() async {
        guard let viewerID = control.viewerID, !isChangingControl, !isClosed else { return }
        isChangingControl = true
        defer { isChangingControl = false }
        releaseHeldInput()
        do {
            let lease = try await service.handBack(agentID: agentID, viewerID: viewerID)
            guard !isClosed else { return }
            apply(lease)
            showsKeyboard = false
        } catch {
            guard !isClosed else { return }
            post(notice: "Couldn't hand control back. Try again.")
        }
    }

    /// The viewer is closing: control goes back to the agent, and the socket closes with
    /// 1000, which Hermes also takes as a hand-back. Nothing here changes after this.
    func close() {
        guard !isClosed else { return }
        releaseHeldInput()
        isClosed = true
        noticeTask?.cancel()
        frameSink = nil
        if control.holder == .me, let viewerID = control.viewerID {
            let service = service
            let agentID = agentID
            Task { _ = try? await service.handBack(agentID: agentID, viewerID: viewerID) }
        }
        transport?.close(handBack: true)
    }

    // MARK: Input (screen pixels)

    func movePointer(to point: CGPoint) {
        sendPointer(point, buttons: buttons)
    }

    func press(_ button: RFBButtons, at point: CGPoint) {
        buttons.insert(button)
        sendPointer(point, buttons: buttons)
    }

    func release(_ button: RFBButtons, at point: CGPoint) {
        buttons.remove(button)
        sendPointer(point, buttons: buttons)
    }

    func click(_ button: RFBButtons, at point: CGPoint) {
        sendPointer(point, buttons: buttons)
        press(button, at: point)
        release(button, at: point)
    }

    /// Wheel steps: each is the wheel button pressed and released.
    func scroll(_ wheel: RFBButtons, steps: Int, at point: CGPoint) {
        for _ in 0..<max(0, min(steps, 20)) {
            sendPointer(point, buttons: buttons.union(wheel))
            sendPointer(point, buttons: buttons)
        }
    }

    func type(_ text: String) {
        for keysym in RFBKeysym.forText(text) {
            key(keysym, down: true)
            key(keysym, down: false)
        }
    }

    func key(_ keysym: UInt32, down: Bool) {
        guard isInControl, let session else { return }
        session.send(RFBClientMessage.key(keysym, down: down))
    }

    private func sendPointer(_ point: CGPoint, buttons: RFBButtons) {
        guard isInControl, let session else { return }
        pointer = CGPoint(x: min(max(0, point.x), CGFloat(screenSize.width - 1)),
                          y: min(max(0, point.y), CGFloat(screenSize.height - 1)))
        session.send(RFBClientMessage.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: buttons))
    }

    /// A drag cut short by losing control must not leave the button held down.
    private func releaseHeldInput() {
        guard !buttons.isEmpty, let session else { buttons = []; return }
        buttons = []
        session.send(RFBClientMessage.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: []))
    }

    private func post(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.notice == text else { return }
            self.notice = nil
        }
    }

    // MARK: Words

    static func sentence(for end: BotScreenStreamEnd) -> String {
        switch end {
        case .screenGone: "The screen was turned off."
        case .notAllowed: "Your computer didn't let bighelp open the screen."
        case .controlTaken, .ticketRefused: "Someone else keeps taking control of the screen."
        case .dropped: "Lost the connection to the screen."
        }
    }

    /// Failures that trying again won't fix. Nil means "try again soon".
    static func endingSentence(for error: any Error) -> String? {
        switch error {
        case RFBError.unsupportedSecurity:
            "This screen asks for a password bighelp can't send."
        case WorkspaceClientError.unavailable(.unsupportedOperation):
            "This computer's Hermes doesn't have screens yet."
        case WorkspaceClientError.rejected:
            // display.observe refuses a screen that isn't running.
            "The screen is off."
        case WorkspaceClientError.authenticationRequired:
            "Sign in to your computer again to see the screen."
        default:
            nil
        }
    }
}
