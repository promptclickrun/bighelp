import Foundation
import os
import Testing
import zlib
@testable import Bighelp

/// The RFB client against hand-built bytes: what it sends, and what it draws from
/// what a server sends.
struct BotScreenRFBTests {
    // MARK: Client messages

    @Test func clientMessagesAreTheRFCBytes() {
        #expect(Array(RFBClientMessage.setPixelFormat(.bgrx)) == [0, 0, 0, 0,
            32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        #expect(Array(RFBClientMessage.setEncodings(RFB.encodings)) == [2, 0, 0, 4,
            0, 0, 0, 16, 0, 0, 0, 1, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x21])
        #expect(Array(RFBClientMessage.updateRequest(incremental: true, x: 1, y: 2, width: 1_440, height: 900))
                == [3, 1, 0, 1, 0, 2, 0x05, 0xA0, 0x03, 0x84])
        #expect(Array(RFBClientMessage.key(RFBKeysym.returnKey, down: true)) == [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])
        #expect(Array(RFBClientMessage.key(0x61, down: false)) == [4, 0, 0, 0, 0, 0, 0, 0x61])
        #expect(Array(RFBClientMessage.pointer(x: 300, y: 2, buttons: [.left, .right])) == [5, 5, 0x01, 0x2C, 0, 2])
        #expect(Array(RFBClientMessage.pointer(x: -4, y: 70_000, buttons: .wheelDown)) == [5, 16, 0, 0, 0xFF, 0xFF])
    }

    @Test func versionIsCappedAtThreePointEight() {
        #expect(RFBVersion(serverGreeting: Array("RFB 003.008\n".utf8)) == .v38)
        #expect(RFBVersion(serverGreeting: Array("RFB 003.889\n".utf8)) == .v38)
        #expect(RFBVersion(serverGreeting: Array("RFB 003.007\n".utf8)) == .v37)
        #expect(RFBVersion(serverGreeting: Array("RFB 003.003\n".utf8)) == .v33)
        #expect(RFBVersion(serverGreeting: Array("RFB 004.001\n".utf8)) == nil)
        #expect(RFBVersion(serverGreeting: Array("HTTP/1.1 200".utf8)) == nil)
    }

    // MARK: Keysyms

    @Test func typedTextBecomesKeysyms() {
        #expect(RFBKeysym.forText("aZ 9") == [0x61, 0x5A, 0x20, 0x39])
        #expect(RFBKeysym.forText("é€") == [0xE9, 0x0100_20AC])
        #expect(RFBKeysym.forText("a\r\nb\n") == [0x61, 0xFF0D, 0x62, 0xFF0D])
        #expect(RFBKeysym.forText("\t\u{7}") == [0xFF09])
    }

    @Test func hardwareKeysGoByPlaceThenCharacter() {
        func key(_ usage: Int, _ characters: String = "", plain: String = "", modified: Bool = false) -> UInt32? {
            RFBKeysym.forHardwareKey(usage: usage, characters: characters, charactersIgnoringModifiers: plain,
                                     controlOrAlt: modified)
        }
        #expect(key(0x28, "\r", plain: "\r") == RFBKeysym.returnKey)
        #expect(key(0x2A) == RFBKeysym.backSpace)
        #expect(key(0x29) == RFBKeysym.escape)
        #expect(key(0x50) == RFBKeysym.left)
        #expect(key(0x3A) == 0xFFBE)
        #expect(key(0x45) == 0xFFC9)
        #expect(key(0x04, "A", plain: "a") == 0x41)
        // Control-C: the screen applies Control itself, so the plain "c" goes.
        #expect(key(0x06, "\u{3}", plain: "c", modified: true) == 0x63)
        #expect(RFBKeysym.forModifier(usage: 0xE1) == RFBKeysym.shiftLeft)
        #expect(RFBKeysym.forModifier(usage: 0xE0) == RFBKeysym.controlLeft)
        #expect(RFBKeysym.forModifier(usage: 0xE2) == RFBKeysym.altLeft)
        #expect(RFBKeysym.forModifier(usage: 0xE3) == nil, "Command stays the Mac's")
    }

    // MARK: Framebuffer

    @Test func copyRectHandlesOverlap() throws {
        let framebuffer = try RFBFramebuffer(width: 4, height: 4)
        for y in 0..<4 { framebuffer.fill(RFBRect(x: 0, y: y, width: 4, height: 1), color: UInt32(y + 1)) }
        // Down by one row over itself: rows 0–2 land on rows 1–3.
        try framebuffer.copy(from: (x: 0, y: 0), to: RFBRect(x: 0, y: 1, width: 4, height: 3))
        #expect((0..<4).map { framebuffer.pixel(x: 0, y: $0) } == [1, 1, 2, 3])
        #expect(throws: RFBError.self) { try framebuffer.copy(from: (x: 3, y: 3), to: RFBRect(x: 0, y: 0, width: 2, height: 2)) }
    }

    @Test func rectanglesOutsideTheScreenAreRefused() throws {
        let framebuffer = try RFBFramebuffer(width: 10, height: 10)
        #expect(throws: RFBError.self) { try framebuffer.check(RFBRect(x: 8, y: 0, width: 4, height: 1)) }
        #expect(throws: RFBError.self) { try RFBFramebuffer(width: 0, height: 10) }
        #expect(throws: RFBError.self) { try RFBFramebuffer(width: 8_192, height: 8_192) }
    }

    // MARK: ZRLE

    /// One tile of each kind, side by side: a 64-pixel-wide rectangle is one tile, so each
    /// call below is one tile. CPIXELs are blue, green, red.
    @Test func zrleTilesDecode() throws {
        let framebuffer = try RFBFramebuffer(width: 4, height: 2)
        let rect = RFBRect(x: 0, y: 0, width: 4, height: 2)
        // Solid: one colour.
        try RFBZRLEDecoder.decodeTiles([1, 0x30, 0x20, 0x10], rect: rect, into: framebuffer)
        #expect(framebuffer.pixel(x: 3, y: 1) == 0x10_2030)
        // Raw: eight CPIXELs.
        let raw: [UInt8] = [0] + (0..<8).flatMap { [UInt8($0), 0, 0] }
        try RFBZRLEDecoder.decodeTiles(raw, rect: rect, into: framebuffer)
        #expect((0..<4).map { framebuffer.pixel(x: $0, y: 1) } == [4, 5, 6, 7])
        // Packed palette, two colours, one bit each; rows pad to a byte.
        try RFBZRLEDecoder.decodeTiles([2, 0xFF, 0, 0, 0, 0xFF, 0, 0b1010_0000, 0b0101_0000], rect: rect, into: framebuffer)
        #expect((0..<4).map { framebuffer.pixel(x: $0, y: 0) } == [0xFF00, 0xFF, 0xFF00, 0xFF])
        #expect((0..<4).map { framebuffer.pixel(x: $0, y: 1) } == [0xFF, 0xFF00, 0xFF, 0xFF00])
        // Plain RLE: a run of 3, then a run of 5 (1 + 4).
        try RFBZRLEDecoder.decodeTiles([128, 1, 0, 0, 2, 2, 0, 0, 4], rect: rect, into: framebuffer)
        #expect((0..<4).map { framebuffer.pixel(x: $0, y: 0) } == [1, 1, 1, 2])
        // Palette RLE: index 0 once, then index 1 run of 7.
        try RFBZRLEDecoder.decodeTiles([130, 9, 0, 0, 8, 0, 0, 0x00, 0x81, 6], rect: rect, into: framebuffer)
        #expect((0..<4).map { framebuffer.pixel(x: $0, y: 0) } == [9, 8, 8, 8])
        #expect(throws: RFBError.self) { try RFBZRLEDecoder.decodeTiles([128, 1, 0, 0, 20], rect: rect, into: framebuffer) }
        #expect(throws: RFBError.self) { try RFBZRLEDecoder.decodeTiles([0, 1, 2], rect: rect, into: framebuffer) }
    }

    @Test func zrleSplitsRectanglesIntoSixtyFourPixelTiles() throws {
        let framebuffer = try RFBFramebuffer(width: 70, height: 1)
        // Two tiles across: 64 wide, then 6 wide.
        try RFBZRLEDecoder.decodeTiles([1, 1, 0, 0, 1, 2, 0, 0], rect: RFBRect(x: 0, y: 0, width: 70, height: 1),
                                       into: framebuffer)
        #expect(framebuffer.pixel(x: 63, y: 0) == 1)
        #expect(framebuffer.pixel(x: 64, y: 0) == 2)
    }

    /// One zlib stream for the whole connection, flushed after each rectangle.
    @Test func zrleKeepsOneZlibStreamAcrossRectangles() throws {
        var deflater = TestDeflater()
        let first = deflater.compress([1, 0x11, 0x22, 0x33])
        let second = deflater.compress([1, 0x44, 0x55, 0x66])
        #expect(first.prefix(1) == [0x78], "The first piece carries the zlib header")
        let framebuffer = try RFBFramebuffer(width: 2, height: 1)
        let decoder = try RFBZRLEDecoder()
        try decoder.decode(first, rect: RFBRect(x: 0, y: 0, width: 1, height: 1), into: framebuffer)
        try decoder.decode(second, rect: RFBRect(x: 1, y: 0, width: 1, height: 1), into: framebuffer)
        #expect(framebuffer.pixel(x: 0, y: 0) == 0x33_2211)
        #expect(framebuffer.pixel(x: 1, y: 0) == 0x66_5544)
        #expect(throws: RFBError.self) {
            try RFBZRLEDecoder().decode([0x12, 0x34, 0x56], rect: RFBRect(x: 0, y: 0, width: 1, height: 1),
                                        into: framebuffer)
        }
    }

    // MARK: Session

    @Test func handshakeThenARawUpdate() async throws {
        let transport = ScriptedTransport()
        transport.serve(Array("RFB 003.008\n".utf8))
        transport.serve([1, 1])           // one security type: None
        transport.serve([0, 0, 0, 0])     // SecurityResult OK
        var serverInit: [UInt8] = [0, 2, 0, 1] + RFBPixelFormat.bgrx.bytes + [0, 0, 0, 11]
        serverInit += Array("hermes:demo".utf8)
        transport.serve(serverInit)
        // FramebufferUpdate: one Raw 2×1 rectangle, split across two messages.
        transport.serve([0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0, 0x03, 0x02])
        transport.serve([0x01, 0x00, 0x06, 0x05, 0x04, 0x00])
        let session = RFBSession(transport: transport)
        let frames = FrameCollector()
        let run = Task {
            try await session.run(onServerInit: { info in await frames.record(info) },
                                  onFrame: { frame in await frames.record(frame) })
        }
        let frame = try await frames.firstFrame()
        #expect(frame.width == 2 && frame.height == 1)
        #expect(await frames.info == RFBSession.ServerInfo(width: 2, height: 1, name: "hermes:demo"))
        let pixels = try #require(frame.image.dataProvider?.data as Data?)
        #expect(Array(pixels.prefix(8)) == [0x03, 0x02, 0x01, 0x00, 0x06, 0x05, 0x04, 0x00])

        try await transport.waitForSent(count: 7)
        let sent = transport.sent
        #expect(sent[0] == Data("RFB 003.008\n".utf8))
        #expect(sent[1] == Data([1]), "Security type None")
        #expect(sent[2] == Data([1]), "ClientInit, shared")
        #expect(sent[3] == RFBClientMessage.setPixelFormat(.bgrx))
        #expect(sent[4] == RFBClientMessage.setEncodings(RFB.encodings))
        #expect(sent[5] == RFBClientMessage.updateRequest(incremental: false, width: 2, height: 1))
        #expect(sent[6] == RFBClientMessage.updateRequest(incremental: true, width: 2, height: 1),
                "The next update is asked for only after this one is drawn")
        run.cancel()
        _ = await run.result
        #expect(transport.closedWithHandBack == true, "Cancelling closes with 1000, which hands control back")
    }

    @Test func aScreenThatWantsAPasswordIsRefusedPlainly() async throws {
        let transport = ScriptedTransport()
        transport.serve(Array("RFB 003.008\n".utf8))
        transport.serve([1, 2])  // VNC password only
        let session = RFBSession(transport: transport)
        await #expect(throws: RFBError.unsupportedSecurity) {
            try await session.run(onServerInit: { _ in }, onFrame: { _ in })
        }
    }

    @Test func aRefusalCarriesItsReason() async throws {
        let transport = ScriptedTransport()
        transport.serve(Array("RFB 003.008\n".utf8))
        transport.serve([0, 0, 0, 0, 4] + Array("busy".utf8))
        let session = RFBSession(transport: transport)
        await #expect(throws: RFBError.refused("busy")) {
            try await session.run(onServerInit: { _ in }, onFrame: { _ in })
        }
    }

    @Test func desktopSizeResizesAndAsksForTheWholeScreen() async throws {
        let transport = ScriptedTransport()
        transport.serve(Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0])
        transport.serve([0, 2, 0, 2] + RFBPixelFormat.bgrx.bytes + [0, 0, 0, 0])
        // DesktopSize (-223) to 3×1, then a CopyRect in the same update.
        transport.serve([0, 0, 0, 2, 0, 0, 0, 0, 0, 3, 0, 1, 0xFF, 0xFF, 0xFF, 0x21,
                         0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0])
        let session = RFBSession(transport: transport)
        let frames = FrameCollector()
        let run = Task { try await session.run(onServerInit: { _ in }, onFrame: { await frames.record($0) }) }
        let frame = try await frames.firstFrame()
        #expect(frame.width == 3 && frame.height == 1)
        try await transport.waitForSent(count: 7)
        #expect(transport.sent[6] == RFBClientMessage.updateRequest(incremental: false, width: 3, height: 1))
        run.cancel()
        _ = await run.result
    }
}

// MARK: - Helpers

/// A server that sends what the test queued and records what the client sends.
final class ScriptedTransport: RFBTransport, Sendable {
    private struct State {
        var queued: [Data] = []
        var waiter: CheckedContinuation<Data, any Error>?
        var sent: [Data] = []
        var closed: Bool?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var sent: [Data] { state.withLock { $0.sent } }
    var closedWithHandBack: Bool? { state.withLock { $0.closed } }

    func serve(_ bytes: [UInt8]) {
        let waiter = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            if let waiter = state.waiter { state.waiter = nil; return waiter }
            state.queued.append(Data(bytes))
            return nil
        }
        waiter?.resume(returning: Data(bytes))
    }

    func send(_ data: Data) async throws { state.withLock { $0.sent.append(data) } }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Data, any Error>? in
                if !state.queued.isEmpty { return .success(state.queued.removeFirst()) }
                if state.closed != nil { return .failure(CancellationError()) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close(handBack: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            if state.closed == nil { state.closed = handBack }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    var closeCode: Int? { nil }

    func waitForSent(count: Int) async throws {
        for _ in 0..<200 where sent.count < count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent.count >= count)
    }
}

actor FrameCollector {
    private(set) var info: RFBSession.ServerInfo?
    private var frames: [RFBFrame] = []

    func record(_ info: RFBSession.ServerInfo) { self.info = info }
    func record(_ frame: RFBFrame) { frames.append(frame) }

    func firstFrame() async throws -> RFBFrame {
        for _ in 0..<300 {
            if let frame = frames.first { return frame }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}

/// zlib the way Xvnc uses it for ZRLE: one stream, a sync flush after each rectangle.
struct TestDeflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    mutating func compress(_ input: [UInt8]) -> [UInt8] {
        var input = input
        var output = [UInt8](repeating: 0, count: 1_024)
        let produced = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.pointee.next_in = source.baseAddress
                stream.pointee.avail_in = uInt(source.count)
                stream.pointee.next_out = target.baseAddress
                stream.pointee.avail_out = uInt(target.count)
                deflate(stream, Z_SYNC_FLUSH)
                return target.count - Int(stream.pointee.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }
}
