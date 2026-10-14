import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Bighelp

/// Hermes' `display.*` answers as the app reads them, who's in control, and when the
/// viewer connects again.
struct BotScreenStateTests {
    // MARK: Status

    @Test func statusReadsHermesFieldsAndIgnoresTheRest() throws {
        let status = BotScreenStatus([
            "profile": .string("default"), "supported": .boolean(true), "installed": .boolean(true),
            "missing": .array([]), "running": .boolean(true), "pid": .integer(41), "display": .string(":20"),
            "geometry": .string("1280x720"), "install_command": .null, "browser": .string("/usr/bin/chromium"),
            "blocker": .null, "placement": .string("terminal:docker"), "image_switch": .null,
            "lease": .object(["holder": .string("human"), "viewer_id": .null, "viewer_hash": .string("63a9e8a8c2d8"),
                              "since": .number(1_760_000_000.5), "epoch": .integer(7), "reason": .string("login")]),
            "profile_key": .string("/opt/data"), "something_new": .object(["x": .integer(1)]),
        ])
        #expect(status.supported && status.installed && status.running)
        #expect(status.size == BotScreenSize(width: 1_280, height: 720))
        #expect(status.isInSandbox)
        #expect(status.profileKey == "/opt/data")
        #expect(status.lease == BotScreenLease(holder: .human, viewerHash: "63a9e8a8c2d8", epoch: 7, reason: "login"))
        #expect(status.installCommand == nil && status.blocker == nil)
    }

    @Test func aSparseOrOddStatusStillReads() {
        let empty = BotScreenStatus([:])
        #expect(!empty.supported && !empty.installed && !empty.running)
        #expect(empty.size == .standard && empty.lease == .agent && empty.placement == "gateway")
        let odd = BotScreenStatus([
            "supported": .string("yes"), "geometry": .string("wide"), "lease": .string("agent"),
            "missing": .array([.string("Xvnc"), .integer(3)]), "install_command": .string(""),
            "blocker": .string("only 300 MB free"),
        ])
        #expect(!odd.supported, "Only a real true means supported")
        #expect(odd.size == .standard)
        #expect(odd.lease == .agent)
        #expect(odd.missing == ["Xvnc"])
        #expect(odd.installCommand == nil)
        #expect(odd.blocker == "only 300 MB free")
        #expect(BotScreenSize(geometry: "1440X900") == .standard)
        #expect(BotScreenSize(geometry: "0x900") == nil)
        #expect(BotScreenSize(geometry: "99999x900") == nil)
    }

    @Test func viewerHashMatchesHermes() {
        // hashlib.sha256(b"viewer-1").hexdigest()[:12]
        #expect(BotScreenLease.hash(viewerID: "viewer-1") == "63a9e8a8c2d8")
        let lease = BotScreenLease(holder: .human, viewerHash: "63a9e8a8c2d8", epoch: 1)
        #expect(lease.isHeld(byViewerID: "viewer-1"))
        #expect(!lease.isHeld(byViewerID: "viewer-2"))
        #expect(!lease.isHeld(byViewerID: nil))
        #expect(!BotScreenLease(holder: .agent, viewerHash: "63a9e8a8c2d8", epoch: 1).isHeld(byViewerID: "viewer-1"))
    }

    @Test func observationAcceptsOnlyHermesOwnSocketPath() {
        let good: [String: BighelpJSONValue] = ["ticket": .string("t1"), "path": .string("/api/display/ws"),
                                                "viewer_id": .string("v1"), "running": .boolean(true)]
        #expect(BotScreenObservation(good)?.viewerID == "v1")
        #expect(BotScreenObservation(good)?.status.running == true)
        var elsewhere = good
        elsewhere["path"] = .string("/api/ws")
        #expect(BotScreenObservation(elsewhere) == nil)
        var noTicket = good
        noTicket["ticket"] = .string("")
        #expect(BotScreenObservation(noTicket) == nil)
    }

    @Test func thumbnailsDecodeOrSayWhyNot() async throws {
        let png = try Self.onePixelPNG()
        switch await BotScreenThumbnail.decode(["data_url": .string("data:image/png;base64," + png.base64EncodedString())]) {
        case .image(let frame): #expect(frame.width == 1 && frame.height == 1)
        default: Issue.record("A picture was expected")
        }
        guard case .hidden = await BotScreenThumbnail.decode(["data_url": .null, "suppressed": .string("human_has_control")])
        else { Issue.record("A person in control hides the picture"); return }
        guard case .none = await BotScreenThumbnail.decode(["data_url": .null]) else { Issue.record("Off"); return }
        guard case .none = await BotScreenThumbnail.decode(["data_url": .string("https://example.com/x.jpg")])
        else { Issue.record("Only data URLs"); return }
    }

    @Test func eventsSayWhichScreenTheyAreAbout() {
        let lease = BotScreenEvent(DirectHermesEvent(type: "display.lease", sessionID: nil, payload: [
            "profile_key": .string("/opt/data"), "lease": .object(["holder": .string("agent"), "epoch": .integer(3)]),
        ], sequence: nil))
        #expect(lease?.profileKey == "/opt/data")
        let status = BotScreenEvent(DirectHermesEvent(type: "display.status", sessionID: nil, payload: [
            "profile_key": .string("/opt/data"), "running": .boolean(false), "supported": .boolean(true),
        ], sequence: nil))
        guard case .status(let pushed)? = status else { Issue.record("A status event"); return }
        #expect(!pushed.running)
        #expect(BotScreenEvent(DirectHermesEvent(type: "display.status", sessionID: nil, payload: [:], sequence: nil)) == nil)
        #expect(BotScreenEvent(DirectHermesEvent(type: "display.install.log", sessionID: nil, payload: [:], sequence: nil)) == nil)
    }

    // MARK: Control

    @Test func olderLeasesNeverUndoNewerOnes() {
        var control = BotScreenControl()
        control.adopt(viewerID: "viewer-1")
        let mine = control.apply(BotScreenLease(holder: .human, viewerHash: BotScreenLease.hash(viewerID: "viewer-1"), epoch: 2))
        #expect(mine && control.holder == .me)
        // A slow display.status from before the takeover.
        let stale = control.apply(BotScreenLease(holder: .agent, viewerHash: nil, epoch: 1))
        #expect(!stale && control.holder == .me)
        let taken = control.apply(BotScreenLease(holder: .human, viewerHash: "someoneelse1", epoch: 3))
        #expect(taken && control.holder == .someoneElse)
        let back = control.apply(BotScreenLease(holder: .agent, viewerHash: nil, epoch: 4))
        #expect(back && control.holder == .agent)
    }

    @Test func aReconnectRemembersThisPersonsControl() {
        var control = BotScreenControl()
        control.adopt(viewerID: "viewer-1")
        control.apply(BotScreenLease(holder: .human, viewerHash: BotScreenLease.hash(viewerID: "viewer-1"), epoch: 5))
        // The app came back: a new connection, so Hermes made a new viewer ID.
        control.adopt(viewerID: "viewer-2")
        #expect(control.holder == .meBeforeReconnect)
        control.apply(BotScreenLease(holder: .human, viewerHash: BotScreenLease.hash(viewerID: "viewer-2"), epoch: 6))
        #expect(control.holder == .me)
        control.adopt(viewerID: "viewer-2")
        #expect(control.holder == .me, "The same ID again changes nothing")
    }

    @Test func closeCodesSayWhatHappened() {
        #expect(BotScreenStreamEnd(closeCode: 4000) == .controlTaken)
        #expect(BotScreenStreamEnd(closeCode: 4001) == .screenGone)
        #expect(BotScreenStreamEnd(closeCode: 4401) == .ticketRefused)
        #expect(BotScreenStreamEnd(closeCode: 4403) == .notAllowed)
        #expect(BotScreenStreamEnd(closeCode: 1000) == .dropped)
        #expect(BotScreenStreamEnd(closeCode: nil) == .dropped)
    }

    @Test func takeoversReconnectAtOnceButNotForever() {
        var reconnects = BotScreenReconnects()
        let start = Date(timeIntervalSince1970: 1_000)
        var delays: [Duration?] = (0..<3).map { second in
            reconnects.delay(after: .controlTaken, now: start.addingTimeInterval(Double(second)))
        }
        // A fourth within ten seconds: something keeps taking it.
        delays.append(reconnects.delay(after: .ticketRefused, now: start.addingTimeInterval(3)))
        #expect(delays == [.zero, .zero, .zero, nil])

        var later = BotScreenReconnects()
        for second in 0..<3 { _ = later.delay(after: .controlTaken, now: start.addingTimeInterval(Double(second))) }
        let afterAWhile = later.delay(after: .controlTaken, now: start.addingTimeInterval(30))
        let gone = later.delay(after: .screenGone)
        let refused = later.delay(after: .notAllowed)
        #expect(afterAWhile == .zero)
        #expect(gone == nil && refused == nil)
    }

    @Test func droppedLinksBackOff() {
        var reconnects = BotScreenReconnects()
        let delays = (0..<6).map { _ in reconnects.delay(after: .dropped) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), nil])
        reconnects.connected()
        let next = reconnects.delay(after: .dropped)
        #expect(next == .seconds(1))
    }

    // MARK: Routes

    @MainActor
    @Test func displayRequestsCarryOnlyTheirFields() throws {
        #expect(try DirectHermesWorkspaceClient.route(.displayObserve, payload: [
            "profile": .string("default"), "viewer_id": .string("v1"),
        ]) == .rpc("display.observe", ["profile": .string("default"), "viewer_id": .string("v1")]))
        #expect(try DirectHermesWorkspaceClient.route(.displayStatus, payload: ["profile": .string("default")])
                == .rpc("display.status", ["profile": .string("default")]))
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.displayStop, payload: ["profile": .string("p"), "force": .boolean(true)])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.displayLeaseAcquire, payload: ["profile": .string("p")])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.displayLeaseRelease, payload: ["viewer_id": .string("v")])
        }
    }

    @MainActor
    @Test func theScreenSocketCarriesOnlyItsTicket() throws {
        let authenticator = DirectHermesAuthenticator(endpoint: try DirectHermesEndpoint(address: "https://hermes.example/base"))
        let request = try authenticator.botScreenStreamRequest(path: "/api/display/ws", ticket: "tk-1")
        #expect(request.url?.absoluteString == "wss://hermes.example/base/api/display/ws?display_ticket=tk-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try authenticator.botScreenStreamRequest(path: "/api/ws", ticket: "tk-1")
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try authenticator.botScreenStreamRequest(path: "/api/display/ws", ticket: "")
        }
    }

    private static func onePixelPNG() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
