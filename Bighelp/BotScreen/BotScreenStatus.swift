import CryptoKit
import Foundation
import ImageIO

/// Hermes' `display.status` for one agent: can it have a screen here, is it
/// installed and on, how big is it, and who's in control. Hosts differ, so every
/// part is optional and unknown fields are ignored.
struct BotScreenStatus: Equatable, Sendable {
    var supported = false
    var installed = false
    var running = false
    var missing: [String] = []
    var size = BotScreenSize.standard
    var installCommand: String?
    /// Why Start would be refused now (low memory, a sandbox image without a desktop).
    var blocker: String?
    /// "gateway", or "terminal:docker" and the like when the screen lives in the agent's sandbox.
    var placement = "gateway"
    var lease = BotScreenLease.agent
    /// Hermes' name for this agent's home; `display.*` events say which screen they're about with it.
    var profileKey: String?

    init(supported: Bool = true, installed: Bool = true, running: Bool = false, size: BotScreenSize = .standard,
         lease: BotScreenLease = .agent, profileKey: String? = nil) {
        self.supported = supported
        self.installed = installed
        self.running = running
        self.size = size
        self.lease = lease
        self.profileKey = profileKey
    }

    init(_ object: [String: BighelpJSONValue]) {
        supported = object["supported"]?.boolean ?? false
        installed = object["installed"]?.boolean ?? false
        running = object["running"]?.boolean ?? false
        missing = (object["missing"]?.array ?? []).compactMap(\.string).prefix(64).map { String($0.prefix(200)) }
        size = object["geometry"]?.string.flatMap(BotScreenSize.init(geometry:)) ?? .standard
        installCommand = object["install_command"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(4_096)) }
        blocker = object["blocker"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(1_000)) }
        placement = object["placement"]?.string.map { String($0.prefix(100)) } ?? "gateway"
        lease = BotScreenLease(object["lease"]) ?? .agent
        profileKey = object["profile_key"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(4_096)) }
    }

    /// The screen lives in the agent's sandbox (Docker, SSH, Singularity), not on the host itself.
    var isInSandbox: Bool { placement.hasPrefix("terminal:") }
}

/// The screen's size in pixels, for its shape on the phone before the first picture arrives.
struct BotScreenSize: Equatable, Sendable {
    var width: Int
    var height: Int

    /// Hermes' default, `bot_desktop.geometry: "1440x900"`.
    static let standard = BotScreenSize(width: 1_440, height: 900)

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init?(geometry: String) {
        let parts = geometry.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              (1...RFB.maximumDimension).contains(width), (1...RFB.maximumDimension).contains(height) else { return nil }
        self.init(width: width, height: height)
    }

    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
}

/// Who's in control of the screen. Hermes names a person only by `viewer_hash`,
/// the first 12 hex digits of SHA-256 of their viewer ID, so a viewer can tell
/// "that's me" without the ID itself (a capability) ever leaving the host.
struct BotScreenLease: Equatable, Sendable {
    enum Holder: String, Sendable { case agent, human }

    var holder: Holder
    var viewerHash: String?
    /// Moves on every change of hands, so an older answer can't undo a newer one.
    var epoch: Int
    /// Why a person took over, when they said.
    var reason: String

    static let agent = BotScreenLease(holder: .agent, viewerHash: nil, epoch: 0, reason: "")

    init(holder: Holder, viewerHash: String?, epoch: Int, reason: String = "") {
        self.holder = holder
        self.viewerHash = viewerHash
        self.epoch = epoch
        self.reason = reason
    }

    init?(_ value: BighelpJSONValue?) {
        guard let object = value?.object else { return nil }
        holder = object["holder"]?.string == Holder.human.rawValue ? .human : .agent
        viewerHash = object["viewer_hash"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        epoch = object["epoch"]?.integer ?? object["epoch"]?.number.map { Int($0) } ?? 0
        reason = object["reason"]?.string.map { String($0.prefix(200)) } ?? ""
    }

    func isHeld(byViewerID viewerID: String?) -> Bool {
        guard holder == .human, let viewerID, let viewerHash else { return false }
        return Self.hash(viewerID: viewerID) == viewerHash
    }

    static func hash(viewerID: String) -> String {
        SHA256.hash(data: Data(viewerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}

/// `display.observe`: a single-use, 30-second ticket for the screen's socket and the
/// viewer ID Hermes made for this connection.
struct BotScreenObservation: Equatable, Sendable {
    var ticket: String
    var path: String
    var viewerID: String
    var status: BotScreenStatus

    /// The only socket path bighelp opens; anything else from the host is refused.
    static let streamPath = "/api/display/ws"

    init(ticket: String, viewerID: String, status: BotScreenStatus) {
        self.ticket = ticket
        path = Self.streamPath
        self.viewerID = viewerID
        self.status = status
    }

    init?(_ object: [String: BighelpJSONValue]) {
        guard let ticket = object["ticket"]?.string, !ticket.isEmpty, ticket.utf8.count <= 1_024,
              let viewerID = object["viewer_id"]?.string, !viewerID.isEmpty, viewerID.utf8.count <= 256 else { return nil }
        let path = object["path"]?.string ?? Self.streamPath
        guard path == Self.streamPath else { return nil }
        self.ticket = ticket
        self.path = path
        self.viewerID = viewerID
        status = BotScreenStatus(object)
    }
}

/// `display.thumbnail`: one still picture, or why there is none.
enum BotScreenThumbnail: Sendable {
    case image(RFBFrame)
    /// A person is in control: the picture could show what they type.
    case hidden
    /// The screen is off.
    case none

    /// Thumbnails come as `data:image/jpeg;base64,…`. Decoded off the main thread.
    static func decode(_ object: [String: BighelpJSONValue]) async -> BotScreenThumbnail {
        if object["suppressed"]?.string?.isEmpty == false { return .hidden }
        guard let url = object["data_url"]?.string else { return .none }
        return await Task.detached(priority: .utility) {
            guard url.utf8.count <= 6_000_000, url.hasPrefix("data:image/"),
                  let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width <= RFB.maximumDimension, image.height <= RFB.maximumDimension else { return .none }
            return .image(RFBFrame(image: image))
        }.value
    }
}

/// `display.lease` and `display.status` as they arrive, for the screen they name.
enum BotScreenEvent: Sendable {
    case lease(profileKey: String, BotScreenLease)
    case status(BotScreenStatus)

    init?(_ event: DirectHermesEvent) {
        switch event.type {
        case "display.lease":
            guard let key = event.payload["profile_key"]?.string, let lease = BotScreenLease(event.payload["lease"]) else {
                return nil
            }
            self = .lease(profileKey: key, lease)
        case "display.status":
            let status = BotScreenStatus(event.payload)
            guard status.profileKey != nil else { return nil }
            self = .status(status)
        default:
            return nil
        }
    }

    var profileKey: String? {
        switch self {
        case .lease(let key, _): key
        case .status(let status): status.profileKey
        }
    }
}
