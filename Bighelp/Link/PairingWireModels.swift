import CryptoKit
import Foundation

enum BighelpIncomingURLRoute: Equatable, Sendable {
    case home
    case chat(sessionID: String)
    case newChat(agentID: String?)
    case scheduledTasks
    case scheduledTask(id: String)
    case sessions
    /// "loopdy://agent/feed?agent=…": a tab of the agent home (chat, feed, ideas,
    /// goals, apps), optionally for one agent.
    case agent(tab: String, agentID: String? = nil)
    /// "loopdy://approval/<id>": one approval, from the Watch.
    case approval(id: String)
    /// "loopdy://kanban?board=…&task=…": Kanban, a board, or one card.
    case kanban(board: String?, task: String?)
    /// "loopdy://group/<room>": a group chat hosted on the computer, from Shortcuts.
    case group(roomID: String)
    /// "loopdy://agents", "loopdy://projects", "loopdy://settings": ☰'s pages.
    case agents
    case projects
    case settings
    case pairBighelpLink(BighelpLinkPairingReference)

    static func parse(_ url: URL) -> BighelpIncomingURLRoute? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "loopdy" || scheme == "app.loopdy.mobile" else { return nil }
        var pairingComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        pairingComponents?.scheme = "loopdy"
        if
            let pairingPayload = pairingComponents?.string,
            let reference = BighelpLinkPairingReference.fromQRPayload(pairingPayload)
        {
            return .pairBighelpLink(reference)
        }
        let legacyDestination = url.host?.lowercased()
            ?? url.pathComponents.dropFirst().first?.lowercased()
        if
            legacyDestination == "inbox" || legacyDestination == "dashboard",
            url.pathComponents.count <= 2
        {
            return .home
        }
        if url.host?.lowercased() == "new-chat", url.pathComponents.count <= 1 {
            let agent = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "agent" })?.value
            return .newChat(agentID: agent.flatMap { $0.isEmpty || $0.count > 96 ? nil : $0 })
        }
        if url.host?.lowercased() == "tasks", url.pathComponents.count <= 1 { return .scheduledTasks }
        if url.host?.lowercased() == "tasks", url.pathComponents.count == 2,
           let id = url.pathComponents.last, !id.isEmpty, id.utf8.count <= 256 {
            return .scheduledTask(id: id)
        }
        if url.host?.lowercased() == "sessions", url.pathComponents.count <= 1 { return .sessions }
        if url.host?.lowercased() == "kanban", url.pathComponents.count <= 1 {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value.flatMap { $0.isEmpty || $0.utf8.count > 240 ? nil : $0 }
            }
            return .kanban(board: value("board"), task: value("task"))
        }
        if url.host?.lowercased() == "agent", url.pathComponents.count <= 2 {
            let tab = url.pathComponents.dropFirst().first?.lowercased() ?? "chat"
            let agent = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "agent" })?.value
                .flatMap { $0.isEmpty || $0.utf8.count > 96 ? nil : $0 }
            return .agent(tab: ["chat", "feed", "ideas", "goals", "apps"].contains(tab) ? tab : "chat", agentID: agent)
        }
        if url.host?.lowercased() == "approval", url.pathComponents.count == 2,
           let id = url.pathComponents.last, !id.isEmpty, id.utf8.count <= 240 {
            return .approval(id: id)
        }
        if url.host?.lowercased() == "group", url.pathComponents.count == 2,
           let id = url.pathComponents.last, !id.isEmpty, id != "/", id.utf8.count <= 240 {
            return .group(roomID: id)
        }
        if url.pathComponents.count <= 1 {
            switch url.host?.lowercased() {
            case "agents": return .agents
            case "projects": return .projects
            case "settings": return .settings
            default: break
            }
        }
        guard
            url.host?.lowercased() == "chat",
            url.pathComponents.count == 2,
            let sessionID = url.pathComponents.dropFirst().first,
            !sessionID.isEmpty
        else { return nil }
        return .chat(sessionID: sessionID)
    }
}

struct BighelpLinkPairingSheetRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let reference: BighelpLinkPairingReference?

    init(id: UUID = UUID(), reference: BighelpLinkPairingReference?) {
        self.id = id
        self.reference = reference
    }

    func replacing(with reference: BighelpLinkPairingReference) -> Self {
        Self(reference: reference)
    }
}

struct BighelpLinkPairingReference: Equatable, Sendable {
    let flowID: String?
    let code: String
    let keyCommitment: String?
    let keyFingerprint: String?

    init(
        flowID: String?,
        code: String,
        keyCommitment: String? = nil,
        keyFingerprint: String? = nil
    ) {
        self.flowID = flowID
        self.code = code
        self.keyCommitment = keyCommitment
        self.keyFingerprint = keyFingerprint
    }

    static func fromQRPayload(_ payload: String) -> BighelpLinkPairingReference? {
        guard
            let components = URLComponents(string: payload),
            components.scheme?.lowercased() == "loopdy",
            components.host?.lowercased() == "link",
            components.path == "/pair"
        else { return nil }
        let flowItems = components.queryItems?.filter { $0.name == "flow" } ?? []
        let codeItems = components.queryItems?.filter { $0.name == "code" } ?? []
        let commitmentItems = components.queryItems?.filter { $0.name == "kc" } ?? []
        guard
            flowItems.count == 1,
            codeItems.count == 1,
            commitmentItems.count == 1,
            let flowID = flowItems[0].value,
            let code = codeItems[0].value,
            let keyCommitment = commitmentItems[0].value,
            (22...96).contains(flowID.count),
            flowID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
            let normalized = BighelpLinkPairingCode.normalized(code),
            BighelpLinkPairingKeyCommitment(encoded: keyCommitment) != nil
        else { return nil }
        return BighelpLinkPairingReference(
            flowID: flowID,
            code: normalized,
            keyCommitment: keyCommitment
        )
    }

    func verifies(_ actual: BighelpLinkPairingKeyCommitment) -> Bool {
        switch (keyCommitment, keyFingerprint) {
        case (.some(let encoded), nil):
            guard let expected = BighelpLinkPairingKeyCommitment(encoded: encoded) else {
                return false
            }
            return expected.constantTimeEquals(actual)
        case (nil, .some(let fingerprint)):
            guard let expected = BighelpLinkPairingKeyCommitment.normalizedFingerprint(fingerprint) else {
                return false
            }
            return Self.constantTimeEquals(expected, actual.fingerprint)
        default:
            return false
        }
    }

    var hasValidVerification: Bool {
        switch (keyCommitment, keyFingerprint) {
        case (.some(let encoded), nil):
            BighelpLinkPairingKeyCommitment(encoded: encoded) != nil
        case (nil, .some(let fingerprint)):
            BighelpLinkPairingKeyCommitment.normalizedFingerprint(fingerprint) != nil
        default:
            false
        }
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct BighelpLinkPairingKeyCommitment: Equatable, Sendable {
    private let digest: Data

    init?(encoded: String) {
        guard
            let decoded = try? BighelpLinkBase64URL.decode(encoded),
            decoded.count == SHA256.Digest.byteCount
        else { return nil }
        digest = decoded
    }

    private init(digest: Data) {
        self.digest = digest
    }

    var encoded: String { BighelpLinkBase64URL.encode(digest) }

    var fingerprint: String {
        digest.prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    var formattedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 4).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: 4)
            return String(fingerprint[start..<end])
        }.joined(separator: "-")
    }

    static func make(
        flowID: String,
        deviceID: String,
        signingPublicKeySPKI: String,
        agreementPublicKey: String
    ) -> BighelpLinkPairingKeyCommitment {
        let canonical = [
            "loopdy-link-host-key-v1",
            flowID,
            deviceID,
            signingPublicKeySPKI,
            agreementPublicKey,
        ].joined(separator: "\n")
        return BighelpLinkPairingKeyCommitment(
            digest: Data(SHA256.hash(data: Data(canonical.utf8)))
        )
    }

    static func normalizedFingerprint(_ value: String) -> String? {
        let normalized = value
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }
        guard normalized.count == 16 else { return nil }
        guard normalized.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return normalized
    }

    func constantTimeEquals(_ other: BighelpLinkPairingKeyCommitment) -> Bool {
        zip(digest, other.digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
