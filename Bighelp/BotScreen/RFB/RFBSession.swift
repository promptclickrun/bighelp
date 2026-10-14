import CoreGraphics
import Foundation

/// The socket an RFB session talks over: the live WebSocket to Hermes'
/// `/api/display/ws`, or the demo's screen in the app.
protocol RFBTransport: Sendable {
    func send(_ data: Data) async throws
    /// The next binary message. Throws once the socket is closed.
    func receive() async throws -> Data
    /// `handBack` closes with 1000, which tells Hermes the viewer closed on purpose: it
    /// hands control back to the agent. Without it the link just drops, and Hermes keeps a
    /// person's control (they may be halfway through a login).
    func close(handBack: Bool)
    /// The WebSocket close code once `receive()` has thrown, when the server sent one.
    var closeCode: Int? { get }
}

/// A finished screen picture. `CGImage` is immutable, so it can cross actors.
struct RFBFrame: @unchecked Sendable {
    let image: CGImage
    var width: Int { image.width }
    var height: Int { image.height }
}

/// One connection to an agent's screen (RFB 3.8, RFC 6143): the handshake, then
/// updates in and input out until the socket closes or the task is cancelled.
///
/// Updates are asked for one at a time: the next request goes out only after the
/// last update is drawn and handed to the viewer, so a slow phone or link slows the
/// screen down instead of piling up data. Input shares that one ordered queue, so a
/// key's press always reaches the screen before its release.
actor RFBSession {
    struct ServerInfo: Equatable, Sendable {
        var width: Int
        var height: Int
        /// The desktop's name, `hermes:<profile>` on Hermes.
        var name: String
    }

    private let transport: any RFBTransport
    private var input = RFBInputBuffer()
    private var framebuffer: RFBFramebuffer?
    private var zrle: RFBZRLEDecoder?
    private let outbox: AsyncStream<Data>
    private let outboxContinuation: AsyncStream<Data>.Continuation

    init(transport: any RFBTransport) {
        self.transport = transport
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(512))
    }

    /// Queues a message for the screen, in order. Callable from any thread; held until
    /// the handshake finishes and dropped once the session has ended.
    nonisolated func send(_ message: Data) { outboxContinuation.yield(message) }

    /// Runs the session. Returns when the server closes cleanly; throws on anything else.
    /// Cancelling the calling task closes the socket with 1000 (control goes back).
    func run(onServerInit: @escaping @Sendable (ServerInfo) async -> Void,
             onFrame: @escaping @Sendable (RFBFrame) async -> Void) async throws {
        let transport = transport
        defer { outboxContinuation.finish() }
        try await withTaskCancellationHandler {
            let info = try await handshake()
            framebuffer = try RFBFramebuffer(width: info.width, height: info.height)
            zrle = try RFBZRLEDecoder()
            await onServerInit(info)
            try await transport.send(RFBClientMessage.setPixelFormat(.bgrx))
            try await transport.send(RFBClientMessage.setEncodings(RFB.encodings))
            try await transport.send(RFBClientMessage.updateRequest(incremental: false, width: info.width,
                                                                      height: info.height))
            let outbox = outbox
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await message in outbox { try await transport.send(message) }
                }
                group.addTask { try await self.readMessages(onFrame: onFrame) }
                defer { group.cancelAll() }
                do {
                    try await group.next()
                } catch {
                    // A failed send leaves the reader waiting on a socket that may still be open.
                    transport.close(handBack: false)
                    throw error
                }
            }
        } onCancel: {
            transport.close(handBack: true)
        }
    }

    // MARK: Handshake

    private func handshake() async throws -> ServerInfo {
        guard let version = RFBVersion(serverGreeting: try await bytes(12)) else {
            throw RFBError.protocolViolation("not an RFB 3 server")
        }
        try await transport.send(version.greeting)
        switch version {
        case .v33:
            let type = try await u32()
            if type == 0 { throw RFBError.refused(try await reason()) }
            guard type == 1 else { throw RFBError.unsupportedSecurity }
        case .v37, .v38:
            let count = try await u8()
            if count == 0 { throw RFBError.refused(try await reason()) }
            // Hermes' Xvnc offers None only: the gateway's ticket is the login.
            guard try await bytes(Int(count)).contains(1) else { throw RFBError.unsupportedSecurity }
            try await transport.send(Data([1]))
            if version == .v38, try await u32() != 0 {
                throw RFBError.refused(try await reason())
            }
        }
        // ClientInit: shared, so other viewers (and the agent's own tools) stay connected.
        try await transport.send(Data([1]))
        let width = Int(try await u16())
        let height = Int(try await u16())
        try await skip(16)
        let nameLength = Int(try await u32())
        guard nameLength <= 4_096 else { throw RFBError.protocolViolation("desktop name too long") }
        let name = String(decoding: try await bytes(nameLength), as: UTF8.self)
        try RFBFramebuffer.check(width: width, height: height)
        return ServerInfo(width: width, height: height, name: name)
    }

    private func reason() async throws -> String {
        let length = Int(try await u32())
        guard length <= 4_096 else { throw RFBError.protocolViolation("reason too long") }
        return String(decoding: try await bytes(length), as: UTF8.self)
    }

    // MARK: Server messages

    private func readMessages(onFrame: @Sendable (RFBFrame) async -> Void) async throws {
        while true {
            switch try await u8() {
            case 0:
                let resized = try await readUpdate()
                guard let framebuffer else { return }
                if let image = framebuffer.makeImage() { await onFrame(RFBFrame(image: image)) }
                send(RFBClientMessage.updateRequest(incremental: !resized, width: framebuffer.width,
                                                    height: framebuffer.height))
            case 1: // SetColourMapEntries: never sent for true colour; skip it if it comes.
                try await skip(3)
                try await skip(Int(try await u16()) * 6)
            case 2: // Bell
                continue
            case 3: // ServerCutText: Hermes never sends the screen's clipboard; ignore it.
                try await skip(3)
                let length = Int(try await u32())
                guard length <= 1 << 24 else { throw RFBError.protocolViolation("clipboard too large") }
                try await skip(length)
            case let type:
                throw RFBError.protocolViolation("server message \(type)")
            }
        }
    }

    /// One FramebufferUpdate. True when the screen changed size.
    private func readUpdate() async throws -> Bool {
        guard let framebuffer, let zrle else { throw RFBError.protocolViolation("update before init") }
        try await skip(1)
        var resized = false
        for _ in 0..<Int(try await u16()) {
            let rect = RFBRect(x: Int(try await u16()), y: Int(try await u16()),
                               width: Int(try await u16()), height: Int(try await u16()))
            let encoding = Int32(bitPattern: try await u32())
            switch RFBEncoding(rawValue: encoding) {
            case .raw:
                try framebuffer.check(rect)
                try await consume(rect.width * rect.height * 4) { framebuffer.writeRaw($0, rect: rect) }
            case .copyRect:
                try framebuffer.check(rect)
                let source = (x: Int(try await u16()), y: Int(try await u16()))
                try framebuffer.copy(from: source, to: rect)
            case .zrle:
                let length = Int(try await u32())
                guard length <= 64 << 20 else { throw RFBError.protocolViolation("ZRLE rectangle too large") }
                try zrle.decode(try await bytes(length), rect: rect, into: framebuffer)
            case .desktopSize:
                try framebuffer.resize(width: rect.width, height: rect.height)
                resized = true
            case nil:
                throw RFBError.protocolViolation("encoding \(encoding)")
            }
        }
        return resized
    }

    // MARK: Reading

    private func fill(_ count: Int) async throws {
        while input.available < count {
            try Task.checkCancellation()
            input.append(try await transport.receive())
        }
    }

    private func bytes(_ count: Int) async throws -> [UInt8] {
        try await consume(count) { Array($0) }
    }

    private func consume<T>(_ count: Int, _ body: (UnsafeRawBufferPointer) throws -> T) async throws -> T {
        try await fill(count)
        return try input.take(count, body)
    }

    private func skip(_ count: Int) async throws {
        var left = count
        while left > 0 {
            if input.available == 0 { try await fill(1) }
            let step = min(left, input.available)
            input.take(step) { _ in }
            left -= step
        }
    }

    private func u8() async throws -> UInt8 { try await consume(1) { $0[0] } }

    private func u16() async throws -> UInt16 {
        try await consume(2) { UInt16($0[0]) << 8 | UInt16($0[1]) }
    }

    private func u32() async throws -> UInt32 {
        try await consume(4) { UInt32($0[0]) << 24 | UInt32($0[1]) << 16 | UInt32($0[2]) << 8 | UInt32($0[3]) }
    }
}

/// Bytes received but not read yet. WebSocket messages don't line up with RFB
/// messages, so they collect here.
struct RFBInputBuffer {
    private var storage: [UInt8] = []
    private var offset = 0

    var available: Int { storage.count - offset }

    mutating func append(_ data: Data) {
        if offset > 0, offset >= storage.count / 2 {
            storage.removeFirst(offset)
            offset = 0
        }
        storage.append(contentsOf: data)
    }

    mutating func take<T>(_ count: Int, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        precondition(count <= available)
        let start = offset
        offset += count
        return try storage.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[start..<(start + count)])) }
    }
}
