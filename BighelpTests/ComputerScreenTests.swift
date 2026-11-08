import Foundation
import Testing
@testable import Bighelp

/// The computer's own screen: the VNC password a computer's screen sharing asks for.
struct ComputerScreenTests {
    /// Vectors from OpenSSL's DES-ECB with the bit-reversed key, as every VNC server computes them.
    @Test func vncAuthAnswersTheChallengeAsVNCServersExpect() throws {
        let challenge = Array(UInt8(0)...UInt8(15))
        #expect(try #require(RFBVNCAuth.response(challenge: challenge, password: "secret12")).hex
                == "adcd997f8e16fee575e973f93c2b62b4")
        #expect(try #require(RFBVNCAuth.response(challenge: challenge, password: "pw")).hex
                == "858600d9af143c9e6541d3dd92a835d0")
        #expect(try #require(RFBVNCAuth.response(challenge: challenge, password: "secret12-and-more")).hex
                == "adcd997f8e16fee575e973f93c2b62b4", "Only the first eight bytes count")
    }

    @Test(.timeLimit(.minutes(1)))
    func aMacsScreenSharingSignsInWithItsVNCPassword() async throws {
        let challenge = Array(UInt8(0)...UInt8(15))
        // macOS answers "RFB 003.889" and offers Apple's own sign-ins (30, 33) beside VNC (2).
        let server = ScriptedRFBServer(chunks: [
            Data("RFB 003.889\n".utf8), Data([3, 30, 33, 2]), Data(challenge), Data([0, 0, 0, 0]),
            serverInit(width: 2_880, height: 1_800, name: "Studio Mac"),
        ])
        let session = RFBSession(transport: server, password: "secret12")
        let size = SizeBox()
        await #expect(throws: (any Error).self) {
            try await session.run(onServerInit: { info in await size.set(info.width, info.height) }, onFrame: { _ in })
        }
        #expect(await size.value == [2_880, 1_800])
        let sent = await server.sent
        #expect(sent.first == Data("RFB 003.008\n".utf8), "Speaks 3.8 to Apple's 3.889")
        #expect(sent.dropFirst().first == Data([2]), "Picks VNC authentication")
        #expect(sent.dropFirst(2).first?.hex == "adcd997f8e16fee575e973f93c2b62b4")
    }

    @Test(.timeLimit(.minutes(1)))
    func withoutAPasswordOrWithAWrongOneItSaysSo() async throws {
        let challenge = Array(repeating: UInt8(7), count: 16)
        let noPassword = RFBSession(transport: ScriptedRFBServer(chunks: [
            Data("RFB 003.008\n".utf8), Data([1, 2]), Data(challenge),
        ]))
        await #expect(throws: RFBError.needsPassword) {
            try await noPassword.run(onServerInit: { _ in }, onFrame: { _ in })
        }
        let reason = Data("Authentication failed".utf8)
        let wrong = RFBSession(transport: ScriptedRFBServer(chunks: [
            Data("RFB 003.008\n".utf8), Data([1, 2]), Data(challenge), Data([0, 0, 0, 1]),
            Data([0, 0, 0, UInt8(reason.count)]) + reason,
        ]), password: "nope")
        await #expect(throws: RFBError.wrongPassword) {
            try await wrong.run(onServerInit: { _ in }, onFrame: { _ in })
        }
    }

    private func serverInit(width: UInt16, height: UInt16, name: String) -> Data {
        var data = Data([UInt8(width >> 8), UInt8(width & 0xff), UInt8(height >> 8), UInt8(height & 0xff)])
        data += Data(repeating: 0, count: 16)
        data += Data([0, 0, 0, UInt8(name.utf8.count)]) + Data(name.utf8)
        return data
    }
}

/// A VNC server that says its lines in order, then closes.
private actor ScriptedRFBServer: RFBTransport {
    private var chunks: [Data]
    private(set) var sent: [Data] = []

    init(chunks: [Data]) { self.chunks = chunks }

    func send(_ data: Data) async throws { sent.append(data) }

    func receive() async throws -> Data {
        guard !chunks.isEmpty else { throw RFBError.protocolViolation("closed") }
        return chunks.removeFirst()
    }

    nonisolated func close(handBack: Bool) {}
    nonisolated var closeCode: Int? { nil }
}

private actor SizeBox {
    private(set) var value: [Int] = []
    func set(_ width: Int, _ height: Int) { value = [width, height] }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
