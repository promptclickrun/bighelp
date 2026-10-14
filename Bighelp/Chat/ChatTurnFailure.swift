import Foundation

/// How Hermes says a turn failed: a `message.complete` with `status: "error"`
/// and its advisory `error_surface` (`agent/error_surface.py`), plus the
/// `billing` block a credit wall carries. Read tolerantly: any part may be
/// missing, renamed or new, and an unreadable part counts as absent.
struct ChatTurnFailure: Equatable, Sendable {
    /// provider, endpoint, streaming, auth, billing, gateway, runtime, disk.
    let layer: String?
    /// A Hermes failure reason (`rate_limit`, `auth`, `context_overflow`, …).
    let code: String?
    let retryable: Bool
    /// The failing provider's display name, as the host names it.
    let providerLabel: String?
    /// When the provider said its limit lifts.
    let resetsAt: Date?
    /// Where to add credit; https only.
    let billingURL: URL?

    static let maximumLabelLength = 80

    init(layer: String? = nil, code: String? = nil, retryable: Bool = true, providerLabel: String? = nil,
         resetsAt: Date? = nil, billingURL: URL? = nil) {
        self.layer = layer
        self.code = code
        self.retryable = retryable
        self.providerLabel = providerLabel
        self.resetsAt = resetsAt
        self.billingURL = billingURL
    }

    /// Nil unless the payload is a failed final (`status: "error"`).
    init?(completePayload payload: [String: BighelpJSONValue]) {
        guard payload["status"]?.string == "error" else { return nil }
        let surface = payload["error_surface"]?.object ?? [:]
        let billing = payload["billing"]?.object ?? [:]
        layer = Self.token(surface["layer"])
        code = Self.token(surface["code"]) ?? Self.token(payload["failure_reason"])
        retryable = surface["retryable"]?.boolean ?? true
        providerLabel = Self.label(surface["provider_label"]) ?? Self.label(billing["provider_label"])
        // Epoch seconds; a value outside a sane range is ignored, not trusted.
        resetsAt = surface["resets_at"]?.number.flatMap {
            $0.isFinite && $0 > 1_000_000_000 && $0 < 100_000_000_000 ? Date(timeIntervalSince1970: $0) : nil
        }
        billingURL = billing["billing_url"]?.string.flatMap(Self.httpsURL)
    }

    private static func token(_ value: BighelpJSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.utf8.count <= 64, text.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace })
        else { return nil }
        return text
    }

    private static func label(_ value: BighelpJSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return String(text.prefix(maximumLabelLength))
    }

    private static func httpsURL(_ text: String) -> URL? {
        guard text.utf8.count <= 2_048, let url = URL(string: text), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// One way out of a failed turn, as a button on its card.
enum ChatTurnFailureFix: Equatable, Sendable {
    case tryAgain
    /// Sends the message again when the limit lifts, while the chat is open.
    case tryAgainAt(Date)
    /// Opens Model & reasoning for this chat.
    case useAnotherModel
    case pickAnotherModel
    /// Opens Settings › AI providers.
    case fixSignIn
    case checkProviders
    case addCredit(URL)
    case startNewChat

    var identifier: String {
        switch self {
        case .tryAgain: "try-again"
        case .tryAgainAt: "try-again-at"
        case .useAnotherModel, .pickAnotherModel: "model"
        case .fixSignIn: "sign-in"
        case .checkProviders: "providers"
        case .addCredit: "add-credit"
        case .startNewChat: "new-chat"
        }
    }
}

/// What a failed turn's card says and offers. The desktop app maps the same
/// codes to its buttons (`apps/desktop/src/lib/error-surface.ts`); Hermes sends
/// no actions of its own.
struct ChatTurnFailurePresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case limit, busy, timeout, connectionDropped, signIn, billing, modelUnavailable, tooLong, couldNotStart
    }

    let kind: Kind
    let sentence: String
    let fixes: [ChatTurnFailureFix]

    /// A timed retry is offered only for a reset within this long.
    static let longestScheduledWait: TimeInterval = 24 * 60 * 60

    /// Nil for a failure the app has no words for: the chat stays as it was
    /// (Hermes' own reply text explains it).
    /// `canResend`: the failed message can be sent again from here.
    static func resolve(_ failure: ChatTurnFailure, canResend: Bool, now: Date,
                        locale: Locale = .current, timeZone: TimeZone = .current) -> Self? {
        guard let kind = kind(of: failure) else { return nil }
        let provider = failure.providerLabel
        func retry(_ fixes: [ChatTurnFailureFix]) -> [ChatTurnFailureFix] {
            canResend ? fixes : fixes.filter { $0 != .tryAgain && !$0.isScheduledRetry }
        }
        switch kind {
        case .limit:
            if let reset = failure.resetsAt, reset > now {
                let time = BighelpResetTime.describe(reset, now: now, locale: locale, timeZone: timeZone)
                let waitIsShort = reset.timeIntervalSince(now) <= longestScheduledWait
                return Self(kind: kind, sentence: "You've reached your limit. It resets \(time.phrase).",
                            fixes: retry(waitIsShort ? [.tryAgainAt(reset), .useAnotherModel] : [.useAnotherModel]))
            }
            return Self(kind: kind, sentence: "You've reached your limit for now.",
                        fixes: retry([.tryAgain, .useAnotherModel]))
        case .busy:
            return Self(kind: kind, sentence: "\(provider ?? "The AI provider") is busy right now.",
                        fixes: retry([.tryAgain]))
        case .timeout:
            return Self(kind: kind, sentence: "\(provider ?? "The AI provider") didn't answer in time.",
                        fixes: retry([.tryAgain]))
        case .connectionDropped:
            return Self(kind: kind, sentence: "The connection dropped before the reply finished.",
                        fixes: retry([.tryAgain]))
        case .signIn:
            return Self(kind: kind, sentence: "Sign-in to \(provider ?? "the AI provider") stopped working.",
                        fixes: [.fixSignIn])
        case .billing:
            return Self(kind: kind, sentence: "\(provider ?? "This AI provider") has no credit left.",
                        fixes: [.useAnotherModel] + (failure.billingURL.map { [.addCredit($0)] } ?? []))
        case .modelUnavailable:
            return Self(kind: kind, sentence: "This model isn't available.", fixes: [.pickAnotherModel])
        case .tooLong:
            return Self(kind: kind, sentence: "This chat is too long for the model.", fixes: [.startNewChat])
        case .couldNotStart:
            return Self(kind: kind, sentence: "Hermes couldn't start the agent. Check that an AI provider is set up.",
                        fixes: retry([.tryAgain, .checkProviders]))
        }
    }

    static func kind(of failure: ChatTurnFailure) -> Kind? {
        switch failure.code {
        case "rate_limit", "upstream_rate_limit", "free_tier_rate_limited": return .limit
        case "overloaded", "server_error", "free_tier_at_capacity", "free_tier_outage": return .busy
        case "timeout": return .timeout
        case "stream_drop": return .connectionDropped
        case "auth", "auth_permanent": return .signIn
        case "billing", "billing_unverified": return .billing
        case "model_not_found": return .modelUnavailable
        case "context_overflow", "payload_too_large": return .tooLong
        case "agent_init_failed": return .couldNotStart
        default: break
        }
        switch failure.layer {
        case "auth": return .signIn
        case "billing": return .billing
        case "streaming": return .connectionDropped
        default: return nil
        }
    }
}

extension ChatTurnFailureFix {
    var isScheduledRetry: Bool {
        if case .tryAgainAt = self { return true }
        return false
    }
}
