import CoreGraphics
import Foundation
import os
import UIKit

/// Demo mode's agent screen: made-up status and control changes, and a small RFB
/// server in the app that speaks the same protocol as Hermes' Xvnc, so the real
/// client draws it and real taps and typing change it. Nothing here is a real
/// person's data or a real site.
@MainActor
final class DemoBotScreenService: BotScreenService {
    static let shared = DemoBotScreenService()
    static let profileKey = "/demo/hermes/profiles/default"

    let desktop = DemoBotDesktop()
    private var running = true
    private var lease = BotScreenLease.agent
    private var viewers = 0
    private var listeners: [UUID: AsyncStream<BotScreenEvent>.Continuation] = [:]

    private var current: BotScreenStatus {
        BotScreenStatus(running: running, size: DemoBotDesktop.size, lease: lease, profileKey: Self.profileKey)
    }

    func status(agentID: String) async throws -> BotScreenStatus { current }

    func start(agentID: String) async throws -> BotScreenStatus {
        running = true
        broadcast(.status(current))
        return current
    }

    func stop(agentID: String) async throws -> BotScreenStatus {
        guard lease.holder == .agent else {
            throw WorkspaceClientError.rejected(code: nil, message: HermesRefusalMessage("a human holds this screen"))
        }
        running = false
        broadcast(.status(current))
        return current
    }

    func thumbnail(agentID: String) async throws -> BotScreenThumbnail {
        guard running else { return .none }
        guard lease.holder == .agent else { return .hidden }
        return await desktop.thumbnail().map(BotScreenThumbnail.image) ?? .none
    }

    func observe(agentID: String, viewerID: String?) async throws -> BotScreenObservation {
        guard running else {
            throw WorkspaceClientError.rejected(code: nil, message: HermesRefusalMessage("not running"))
        }
        let id = viewerID ?? { viewers += 1; return "demo-viewer-\(viewers)" }()
        return BotScreenObservation(ticket: "demo-ticket", viewerID: id, status: current)
    }

    func takeControl(agentID: String, viewerID: String) async throws -> BotScreenLease {
        lease = BotScreenLease(holder: .human, viewerHash: BotScreenLease.hash(viewerID: viewerID), epoch: lease.epoch + 1)
        broadcast(.lease(profileKey: Self.profileKey, lease))
        return lease
    }

    func handBack(agentID: String, viewerID: String) async throws -> BotScreenLease {
        if lease.isHeld(byViewerID: viewerID) {
            lease = BotScreenLease(holder: .agent, viewerHash: nil, epoch: lease.epoch + 1)
            broadcast(.lease(profileKey: Self.profileKey, lease))
        }
        return lease
    }

    func openStream(_ observation: BotScreenObservation) async throws -> any RFBTransport {
        guard running else { throw WorkspaceClientError.rejected(code: nil) }
        let viewerID = observation.viewerID
        // Like Hermes: a viewer that closes on purpose hands control back.
        return DemoRFBTransport(desktop: desktop) { [self] handBack in
            guard handBack else { return }
            Task { @MainActor in _ = try? await self.handBack(agentID: "", viewerID: viewerID) }
        }
    }

    func events() -> AsyncStream<BotScreenEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: BotScreenEvent.self)
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.listeners[id] = nil }
        }
        return stream
    }

    private func broadcast(_ event: BotScreenEvent) {
        for listener in listeners.values { listener.yield(event) }
    }
}

/// The demo's desktop: a made-up browser page and a terminal that shows what's typed.
actor DemoBotDesktop {
    static let size = BotScreenSize(width: 1_280, height: 800)
    static let terminal = RFBRect(x: 840, y: 440, width: 400, height: 300)

    private let context: CGContext
    private var typed = "echo hello"
    private var clicks: [CGPoint] = []

    init() {
        context = CGContext(data: nil, width: Self.size.width, height: Self.size.height, bitsPerComponent: 8,
                            bytesPerRow: Self.size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // UIKit drawing, top-left origin.
        context.translateBy(x: 0, y: CGFloat(Self.size.height))
        context.scaleBy(x: 1, y: -1)
        Self.drawDesktop(in: context)
        Self.drawTerminal(typed, in: context)
    }

    func thumbnail() -> RFBFrame? { context.makeImage().map(RFBFrame.init) }

    /// A key from the viewer. Returns the part of the screen that changed.
    func key(_ keysym: UInt32) -> RFBRect? {
        switch keysym {
        case RFBKeysym.backSpace: guard !typed.isEmpty else { return nil }; typed.removeLast()
        case RFBKeysym.returnKey: typed = ""
        case 0x20...0x7E: typed.append(Character(Unicode.Scalar(UInt8(keysym))))
        default: return nil
        }
        typed = String(typed.suffix(60))
        Self.drawTerminal(typed, in: context)
        return Self.terminal
    }

    /// A click from the viewer leaves a small mark where it landed.
    func click(x: Int, y: Int) -> RFBRect {
        let mark = RFBRect(x: max(0, x - 9), y: max(0, y - 9), width: 18, height: 18)
        UIGraphicsPushContext(context)
        UIColor(red: 1, green: 138 / 255, blue: 122 / 255, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)).fill()
        UIGraphicsPopContext()
        return RFBRect(x: mark.x, y: mark.y, width: min(mark.width, Self.size.width - mark.x),
                       height: min(mark.height, Self.size.height - mark.y))
    }

    /// The pixels of one rectangle, rows top to bottom, in `RFBPixelFormat.bgrx`.
    func pixels(_ rect: RFBRect) -> [UInt8] {
        guard let data = context.data else { return [] }
        let rowBytes = context.bytesPerRow
        var out = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        out.withUnsafeMutableBytes { buffer in
            for row in 0..<rect.height {
                buffer.baseAddress!.advanced(by: row * rect.width * 4)
                    .copyMemory(from: data.advanced(by: (rect.y + row) * rowBytes + rect.x * 4), byteCount: rect.width * 4)
            }
        }
        return out
    }

    private static func drawDesktop(in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let full = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let colors = [UIColor(red: 0.13, green: 0.32, blue: 0.36, alpha: 1).cgColor,
                      UIColor(red: 0.20, green: 0.17, blue: 0.40, alpha: 1).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: full.height), options: [])
        }
        UIColor(white: 0.1, alpha: 0.9).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: full.width, height: 30))
        text("Applications", at: CGPoint(x: 14, y: 6), size: 14, color: .white)
        text("10:42", at: CGPoint(x: full.width - 60, y: 6), size: 14, color: .white)

        // A browser window on a made-up booking page.
        let browser = CGRect(x: 60, y: 70, width: 740, height: 560)
        window(browser, title: "Kyoto stays — Browser")
        UIColor(white: 0.94, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: browser.minX + 16, y: browser.minY + 44, width: browser.width - 32, height: 30),
                     cornerRadius: 15).fill()
        text("stays.example/kyoto/gion", at: CGPoint(x: browser.minX + 32, y: browser.minY + 50), size: 14,
             color: UIColor(white: 0.3, alpha: 1))
        text("Quiet rooms near Gion", at: CGPoint(x: browser.minX + 24, y: browser.minY + 96), size: 26,
             color: UIColor(white: 0.1, alpha: 1), bold: true)
        let rooms = [("Garden room", "2 guests · from 18,000"), ("Tatami suite", "4 guests · from 31,000"),
                     ("Courtyard twin", "2 guests · from 22,500")]
        for (index, room) in rooms.enumerated() {
            let card = CGRect(x: browser.minX + 24, y: browser.minY + 150 + CGFloat(index) * 122,
                              width: browser.width - 48, height: 106)
            UIColor(white: 0.96, alpha: 1).setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 12).fill()
            UIColor(red: 0.55, green: 0.67, blue: 0.60, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: card.minX + 12, y: card.minY + 12, width: 120, height: 82),
                         cornerRadius: 8).fill()
            text(room.0, at: CGPoint(x: card.minX + 150, y: card.minY + 20), size: 19,
                 color: UIColor(white: 0.12, alpha: 1), bold: true)
            text(room.1, at: CGPoint(x: card.minX + 150, y: card.minY + 50), size: 15, color: UIColor(white: 0.4, alpha: 1))
            UIColor(red: 0.48, green: 0.32, blue: 0.88, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: card.maxX - 112, y: card.minY + 34, width: 96, height: 38),
                         cornerRadius: 19).fill()
            text("Hold", at: CGPoint(x: card.maxX - 82, y: card.minY + 43), size: 15, color: .white, bold: true)
        }
        window(CGRect(x: CGFloat(terminal.x), y: CGFloat(terminal.y), width: CGFloat(terminal.width),
                      height: CGFloat(terminal.height)), title: "Terminal")
    }

    private static func drawTerminal(_ typed: String, in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let body = CGRect(x: terminal.x + 1, y: terminal.y + 31, width: terminal.width - 2, height: terminal.height - 32)
        UIColor(white: 0.08, alpha: 1).setFill()
        UIRectFill(body)
        text("agent@screen:~$ " + typed + "▏", at: CGPoint(x: body.minX + 12, y: body.minY + 12), size: 14,
             color: UIColor(red: 0.62, green: 0.93, blue: 0.68, alpha: 1), monospaced: true, width: body.width - 24)
    }

    private static func window(_ frame: CGRect, title: String) {
        UIColor.white.setFill()
        UIBezierPath(rect: frame).fill()
        UIColor(white: 0.86, alpha: 1).setFill()
        UIRectFill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 30))
        text(title, at: CGPoint(x: frame.minX + 12, y: frame.minY + 6), size: 14, color: UIColor(white: 0.2, alpha: 1))
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, color: UIColor,
                             bold: Bool = false, monospaced: Bool = false, width: CGFloat = 700) {
        let font = monospaced ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        (string as NSString).draw(in: CGRect(x: point.x, y: point.y, width: width, height: size * 6),
                                  withAttributes: [.font: font, .foregroundColor: color])
    }
}

/// The demo screen's socket: client bytes go to a little RFB 3.8 server, and its
/// replies come back as messages, just like Hermes' bridge.
final class DemoRFBTransport: RFBTransport {
    private let server: DemoRFBServer
    private let closed = OSAllocatedUnfairLock(initialState: false)
    private let onClose: @Sendable (Bool) -> Void

    init(desktop: DemoBotDesktop, onClose: @escaping @Sendable (Bool) -> Void) {
        server = DemoRFBServer(desktop: desktop)
        self.onClose = onClose
    }

    func send(_ data: Data) async throws { try await server.receiveFromClient(data) }

    func receive() async throws -> Data { try await server.nextMessage() }

    func close(handBack: Bool) {
        let first = closed.withLock { wasClosed in
            defer { wasClosed = true }
            return !wasClosed
        }
        guard first else { return }
        onClose(handBack)
        Task { [server] in await server.shutdown() }
    }

    var closeCode: Int? { closed.withLock { $0 } ? 1000 : nil }
}

private actor DemoRFBServer {
    private enum Stage { case version, security, clientInit, ready }

    private let desktop: DemoBotDesktop
    private var stage = Stage.version
    private var input: [UInt8] = []
    private var outbox: [Data] = [Data("RFB 003.008\n".utf8)]
    private var waiter: CheckedContinuation<Data, any Error>?
    private var isShutDown = false
    private var waitingForChange = false
    private var dirty: [RFBRect] = []
    private var buttons: UInt8 = 0

    init(desktop: DemoBotDesktop) { self.desktop = desktop }

    func nextMessage() async throws -> Data {
        if !outbox.isEmpty { return outbox.removeFirst() }
        guard !isShutDown else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func shutdown() {
        isShutDown = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    func receiveFromClient(_ data: Data) async throws {
        guard !isShutDown else { throw CancellationError() }
        input += data
        while let length = nextLength(), input.count >= length {
            let message = Array(input.prefix(length))
            input.removeFirst(length)
            await handle(message)
        }
    }

    private func nextLength() -> Int? {
        switch stage {
        case .version: return 12
        case .security, .clientInit: return 1
        case .ready:
            guard let type = input.first else { return nil }
            switch type {
            case 0: return 20
            case 2: return input.count >= 4 ? 4 + 4 * (Int(input[2]) << 8 | Int(input[3])) : nil
            case 3: return 10
            case 4: return 8
            case 5: return 6
            case 6: return input.count >= 8 ? 8 + Int(UInt32(input[4]) << 24 | UInt32(input[5]) << 16
                                                       | UInt32(input[6]) << 8 | UInt32(input[7])) : nil
            default: return input.count
            }
        }
    }

    private func handle(_ message: [UInt8]) async {
        switch stage {
        case .version:
            stage = .security
            emit(Data([1, 1]))
        case .security:
            stage = .clientInit
            emit(Data([0, 0, 0, 0]))
        case .clientInit:
            stage = .ready
            let name = Array("hermes:demo".utf8)
            var out: [UInt8] = []
            out.appendBigEndian(UInt16(DemoBotDesktop.size.width))
            out.appendBigEndian(UInt16(DemoBotDesktop.size.height))
            out += RFBPixelFormat.bgrx.bytes
            out.appendBigEndian(UInt32(name.count))
            emit(Data(out + name))
        case .ready:
            switch message[0] {
            case 3 where message[1] == 0:
                await sendUpdate([RFBRect(x: 0, y: 0, width: DemoBotDesktop.size.width, height: DemoBotDesktop.size.height)])
            case 3:
                if dirty.isEmpty { waitingForChange = true } else { await flush() }
            case 4 where message[1] == 1:
                let keysym = UInt32(message[4]) << 24 | UInt32(message[5]) << 16 | UInt32(message[6]) << 8 | UInt32(message[7])
                if let changed = await desktop.key(keysym) { await changedRect(changed) }
            case 5:
                let pressed = message[1] & 1 != 0 && buttons & 1 == 0
                buttons = message[1]
                if pressed {
                    let x = Int(message[2]) << 8 | Int(message[3])
                    let y = Int(message[4]) << 8 | Int(message[5])
                    await changedRect(await desktop.click(x: x, y: y))
                }
            default:
                break
            }
        }
    }

    private func changedRect(_ rect: RFBRect) async {
        dirty.append(rect)
        if waitingForChange { await flush() }
    }

    private func flush() async {
        waitingForChange = false
        let rects = dirty
        dirty = []
        await sendUpdate(rects)
    }

    private func sendUpdate(_ rects: [RFBRect]) async {
        var out: [UInt8] = [0, 0]
        out.appendBigEndian(UInt16(rects.count))
        for rect in rects {
            for value in [rect.x, rect.y, rect.width, rect.height] { out.appendBigEndian(UInt16(value)) }
            out.appendBigEndian(UInt32(bitPattern: RFBEncoding.raw.rawValue))
            out += await desktop.pixels(rect)
        }
        emit(Data(out))
    }

    private func emit(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbox.append(data)
        }
    }
}
