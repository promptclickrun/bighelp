import Foundation

/// How a decision on a draft ended, for the review and the card.
enum ImageDraftDecisionResult: Equatable, Sendable {
    /// `recordID` is nil when Apple's editor saved without telling bighelp the id.
    case saved(recordID: String?, verified: Bool)
    case failed(ImageDraftFailureReason)
    /// The record may be there: the person checks before saving again.
    case outcomeUnknown
    case discarded
    /// Back to the review; nothing was written.
    case reopened
    /// The host claimed it for Apple's editor: open it now, filled in from the approval.
    case readyForEditor
    /// Already decided, or being saved on another device. `current` is the host's state.
    case refused(ImageDraftHostState?)
    /// The approval doesn't hold up (changed on disk, or not this draft's kind).
    case invalidApproval
    case needsPluginUpdate
    /// The computer or the phone's storage didn't answer before anything was written.
    case unavailable
    /// The card in the chat isn't the card the plugin made for this draft. Nothing was written.
    case mismatched
}

/// What Apple's new-contact or new-event screen reported.
enum ImageDraftEditorOutcome: Equatable, Sendable {
    case saved(recordID: String?, verified: Bool)
    case cancelled
}

/// Where a Save in progress keeps its approval, so a relaunch can finish it. Personal data:
/// protected file storage only, never UserDefaults (`ImageDraftLocalFile`).
@MainActor
protocol ImageDraftPendingStoring: AnyObject {
    func pendingApproval(for key: ImageDraftKey) -> ImageDraftApproval?
    func setPendingApproval(_ approval: ImageDraftApproval) throws
    func clearPendingApproval(for key: ImageDraftKey)
}

/// Exactly one write per Save (docs/IMAGE_DRAFTS.md › Exactly one write):
///
/// 1. The approval is journaled as started before anything else (`DeviceToolFileJournal`, scoped
///    by computer and agent, request `image-draft:<draftID>:<decisionID>`).
/// 2. The host's claim must succeed; another device or tap gets the draft's current state.
/// 3. The writer writes the frozen approval and reads it back; the journal records how it went.
/// 4. The host hears the outcome. If it doesn't answer, the next load tells it again.
///
/// A started entry without an outcome (bighelp closed mid-write) makes the draft
/// `outcome_unknown`: the app looks for the record and finishes it as saved when found, else the
/// person checks, and only their "It's not there, save again" reopens it.
@MainActor
final class ImageDraftDecisions {
    static let journalLifetime = 7 * 86_400
    /// Journal codes for outcomes that aren't the host's failure reasons.
    static let outcomeUnknownCode = "outcome_unknown"
    static let notClaimedCode = "not_claimed"

    private let writer: any ImageDraftWriting
    private let journal: any DeviceToolJournal
    private let pending: any ImageDraftPendingStoring
    private let clock: () -> Date
    private var inFlight: [ImageDraftKey: Task<ImageDraftDecisionResult, Never>] = [:]
    private var inFlightDecision: [ImageDraftKey: String] = [:]
    private var reconciling = Set<ImageDraftKey>()

    init(writer: any ImageDraftWriting, journal: any DeviceToolJournal, pending: any ImageDraftPendingStoring,
         clock: @escaping () -> Date = { Date() }) {
        self.writer = writer
        self.journal = journal
        self.pending = pending
        self.clock = clock
    }

    /// Whether a Save or Discard for this draft is running now.
    func isBusy(_ key: ImageDraftKey) -> Bool { inFlight[key] != nil || reconciling.contains(key) }

    // MARK: Save

    /// Saves the approval. A second Save for the same draft while one runs gets that one's result.
    func save(_ approval: ImageDraftApproval, client: ImageDraftsAPI, cardHash: String? = nil) async -> ImageDraftDecisionResult {
        // A second tap shares the first one's result: both mean the same Save.
        await once(approval.key) { [self] in
            await performSave(approval, client: client, cardHash: cardHash)
        }
    }

    /// Claims the draft for Apple's own editor (no Contacts or Calendar access). The app writes
    /// nothing itself; `finishFromEditor` records what the editor did.
    func claimForEditor(_ approval: ImageDraftApproval, client: ImageDraftsAPI,
                        cardHash: String? = nil) async -> ImageDraftDecisionResult {
        await once(approval.key, decisionID: approval.decisionID) { [self] in
            if let earlier = await settleEarlierDecision(before: approval, client: client) { return earlier }
            switch begin(approval) {
            case .go: break
            case .stop(let result): return result
            case .alreadyStarted: return .unavailable
            }
            if let stop = await claimOrStop(approval, client: client, cardHash: cardHash) { return stop }
            return .readyForEditor
        }
    }

    /// The editor's Done is the Save; its Cancel writes nothing and gives the draft back.
    func finishFromEditor(_ approval: ImageDraftApproval, outcome: ImageDraftEditorOutcome,
                          client: ImageDraftsAPI) async -> ImageDraftDecisionResult {
        await once(approval.key, decisionID: approval.decisionID) { [self] in
            switch outcome {
            case .cancelled:
                complete(approval, status: "failed", code: Self.notClaimedCode)
                return await reopen(approval.key, decisionID: approval.decisionID, client: client)
            case .saved(let recordID, let verified):
                let write = ImageDraftWriteResult.saved(recordID: recordID, verified: verified)
                record(approval, write)
                return await tellHost(approval, write, client: client)
            }
        }
    }

    private func performSave(_ approval: ImageDraftApproval, client: ImageDraftsAPI,
                             cardHash: String?) async -> ImageDraftDecisionResult {
        if let earlier = await settleEarlierDecision(before: approval, client: client) { return earlier }
        switch begin(approval) {
        case .go: break
        case .stop(let result): return result
        case .alreadyStarted:
            // The same decision again after a relaunch: settle it, never write twice.
            return await settle(approval.key, hostState: nil, client: client) ?? .outcomeUnknown
        }
        if let stop = await claimOrStop(approval, client: client, cardHash: cardHash) { return stop }
        // What already looks like this record, so a check after an interrupted write never takes
        // an old contact or event for the one this Save made.
        var approval = approval
        let existing = await writer.lookAlikeIDs(approval)
        if !existing.isEmpty {
            approval.existingRecordIDs = existing
            try? pending.setPendingApproval(approval)
        }
        let write = await writer.write(approval)
        record(approval, write)
        return await tellHost(approval, write, client: client)
    }

    /// An earlier Save of this draft that the host hasn't heard the end of is settled first, so a
    /// new decision never hides it. Nil when it's settled (or there was none) and this one may go.
    private func settleEarlierDecision(before approval: ImageDraftApproval,
                                       client: ImageDraftsAPI) async -> ImageDraftDecisionResult? {
        guard let earlier = pending.pendingApproval(for: approval.key), earlier.decisionID != approval.decisionID else {
            return nil
        }
        let settled = await settle(approval.key, hostState: nil, client: client)
        guard pending.pendingApproval(for: approval.key) != nil else { return nil }
        return settled ?? .unavailable
    }

    private enum Start {
        case go
        case stop(ImageDraftDecisionResult)
        /// This decision was journaled before and never finished: settle it instead.
        case alreadyStarted
    }

    /// Journals the approval as started, once, before the host or the writer hear of it.
    private func begin(_ approval: ImageDraftApproval) -> Start {
        guard approval.isIntact else { return .stop(.invalidApproval) }
        let requestID = Self.requestID(approval), scope = Self.scope(approval.key)
        do {
            if let prior = try journal.entry(requestID: requestID, scope: scope) {
                guard prior.fingerprint == Self.fingerprint(approval) else { return .stop(.invalidApproval) }
                guard let result = prior.result else { return .alreadyStarted }
                // An earlier try that never reached the host may go again; it wrote nothing.
                if result.code != Self.notClaimedCode { return .stop(Self.result(journaled: result)) }
            }
            try pending.setPendingApproval(approval)
            try journal.save(DeviceToolJournalEntry(fingerprint: Self.fingerprint(approval),
                                                    expiresAt: Self.seconds(clock()) + Self.journalLifetime, result: nil),
                             requestID: requestID, scope: scope)
        } catch {
            pending.clearPendingApproval(for: approval.key)
            return .stop(.unavailable)
        }
        return .go
    }

    private enum Claim {
        case claimed(ImageDraftHostState)
        case refused(ImageDraftDecisionResult)
        /// The host may or may not have taken it: nothing is written, and the claim is given back.
        case unclear
    }

    /// Claims the draft for this decision, or says why not. Nil when the claim holds and the
    /// card is the one the plugin made; otherwise the result to return, with nothing written.
    private func claimOrStop(_ approval: ImageDraftApproval, client: ImageDraftsAPI,
                             cardHash: String?) async -> ImageDraftDecisionResult? {
        switch await claim(approval, client: client) {
        case .claimed(let state):
            guard let made = state.cardHash, let shown = cardHash?.lowercased(), made != shown else { return nil }
            // An edited card: give the claim back before anything is written.
            complete(approval, status: "failed", code: Self.notClaimedCode)
            _ = await reopen(approval.key, decisionID: approval.decisionID, client: client)
            return .mismatched
        case .refused(let result):
            complete(approval, status: "failed", code: Self.notClaimedCode)
            pending.clearPendingApproval(for: approval.key)
            return result
        case .unclear:
            // Nothing is written; the claim is given back now, or on the next load (the pending
            // approval and its not-claimed entry stay until the host has it back).
            complete(approval, status: "failed", code: Self.notClaimedCode)
            _ = await reopen(approval.key, decisionID: approval.decisionID, client: client)
            return .unavailable
        }
    }

    /// A draft whose last Save failed is reopened and claimed again: this Save is the person's try again.
    private func claim(_ approval: ImageDraftApproval, client: ImageDraftsAPI) async -> Claim {
        var reopenedAfterFailure = false
        var askedAgain = false
        while true {
            do throws(ImageDraftsError) {
                return .claimed(try await client.claim(approval))
            } catch {
                switch error {
                case .outcomeUnknown where !askedAgain:
                    // A claim is the same for the same decision: ask once more.
                    askedAgain = true
                case .decided(let current?) where current.state == .failed && !reopenedAfterFailure:
                    reopenedAfterFailure = true
                    do throws(ImageDraftsError) {
                        _ = try await client.reopen(approval.key, decisionID: current.decisionID ?? approval.decisionID)
                    } catch {
                        return .refused(.refused(current))
                    }
                case .decided(let current), .busy(let current): return .refused(.refused(current))
                case .notFound: return .refused(.refused(nil))
                case .needsPluginUpdate: return .refused(.needsPluginUpdate)
                case .outcomeUnknown, .noConnection, .failed: return .unclear
                default: return .refused(.unavailable)
                }
            }
        }
    }

    /// Tells the host how the write went. If it doesn't answer, the approval stays pending and the
    /// next load tells it again; the write happened either way.
    private func tellHost(_ approval: ImageDraftApproval, _ write: ImageDraftWriteResult,
                          client: ImageDraftsAPI) async -> ImageDraftDecisionResult {
        let (outcome, reason, verified, result): (ImageDraftOutcome, ImageDraftFailureReason?, Bool, ImageDraftDecisionResult)
            = switch write {
            case .saved(let recordID, let check): (.saved, nil, check, .saved(recordID: recordID, verified: check))
            case .failed(let why): (.failed, why, false, .failed(why))
            case .outcomeUnknown: (.outcomeUnknown, nil, false, .outcomeUnknown)
            }
        do throws(ImageDraftsError) {
            _ = try await client.finish(approval, outcome: outcome, reason: reason, verified: verified)
            // An unclear outcome stays pending: the next load looks for the record again.
            if outcome != .outcomeUnknown { pending.clearPendingApproval(for: approval.key) }
        } catch {}
        return result
    }

    // MARK: Discard and reopen

    /// Records `discarded`. Writes nothing; refused while a Save is writing.
    func discard(_ key: ImageDraftKey, client: ImageDraftsAPI) async -> ImageDraftDecisionResult {
        guard inFlight[key] == nil else { return .refused(nil) }
        return await once(key) { [self] in
            do throws(ImageDraftsError) {
                _ = try await client.discard(key)
                pending.clearPendingApproval(for: key)
                return .discarded
            } catch {
                return Self.result(refusal: error)
            }
        }
    }

    /// The person checked Contacts or Calendar after an unclear Save and says it isn't there:
    /// the draft goes back to review, and the next Save is a new decision.
    func reopenAfterCheck(_ key: ImageDraftKey, hostState: ImageDraftHostState?, client: ImageDraftsAPI) async
        -> ImageDraftDecisionResult {
        guard let decisionID = pending.pendingApproval(for: key)?.decisionID ?? hostState?.decisionID else {
            return .refused(hostState)
        }
        return await once(key) { [self] in await reopen(key, decisionID: decisionID, client: client) }
    }

    /// The person checked after an unclear Save and the record is there: saved, not verified by bighelp.
    func confirmSaved(_ key: ImageDraftKey, hostState: ImageDraftHostState?, client: ImageDraftsAPI) async
        -> ImageDraftDecisionResult {
        let approval = pending.pendingApproval(for: key)
        guard let decisionID = approval?.decisionID ?? hostState?.decisionID,
              let destination = approval?.destination.label ?? hostState?.destination else { return .refused(hostState) }
        return await once(key) { [self] in
            do throws(ImageDraftsError) {
                _ = try await client.finish(key, decisionID: decisionID, destination: destination, outcome: .saved,
                                            reason: nil, verified: false)
            } catch {
                return Self.result(refusal: error)
            }
            if let approval { record(approval, .saved(recordID: nil, verified: false)) }
            pending.clearPendingApproval(for: key)
            return .saved(recordID: nil, verified: false)
        }
    }

    private func reopen(_ key: ImageDraftKey, decisionID: String, client: ImageDraftsAPI) async -> ImageDraftDecisionResult {
        do throws(ImageDraftsError) {
            _ = try await client.reopen(key, decisionID: decisionID)
            pending.clearPendingApproval(for: key)
            return .reopened
        } catch {
            return Self.result(refusal: error)
        }
    }

    // MARK: After a relaunch

    /// Settles a Save this phone started and didn't finish telling the host about. Nil when there's
    /// nothing local to settle, or the host's state isn't known yet.
    func reconcile(_ key: ImageDraftKey, hostState given: ImageDraftHostState? = nil,
                   client: ImageDraftsAPI) async -> ImageDraftDecisionResult? {
        guard inFlight[key] == nil, !reconciling.contains(key) else { return nil }
        reconciling.insert(key)
        defer { reconciling.remove(key) }
        return await settle(key, hostState: given, client: client)
    }

    private func settle(_ key: ImageDraftKey, hostState given: ImageDraftHostState?,
                        client: ImageDraftsAPI) async -> ImageDraftDecisionResult? {
        guard let approval = pending.pendingApproval(for: key) else { return nil }
        guard approval.isIntact,
              let entry = try? journal.entry(requestID: Self.requestID(approval), scope: Self.scope(approval.key)),
              entry.fingerprint == Self.fingerprint(approval) else {
            // Never journaled: nothing was claimed or written.
            pending.clearPendingApproval(for: key)
            return nil
        }
        var known = given
        if known == nil {
            do throws(ImageDraftsError) { known = try await client.state(of: key) } catch { return nil }
        }
        guard let hostState = known else { return nil }
        let ours = hostState.decisionID == approval.decisionID
        guard ours, hostState.state == .applying || hostState.state == .outcomeUnknown else {
            // The host never had this claim (the write comes after it, so nothing was written), or
            // it already recorded the outcome.
            if entry.result == nil { complete(approval, status: "failed", code: Self.notClaimedCode) }
            pending.clearPendingApproval(for: key)
            return ours || hostState.state != .awaitingReview ? Self.result(host: hostState) : nil
        }
        guard let result = entry.result else { return await settleUnclear(approval, hostState, client: client) }
        switch result.code {
        case nil:
            let write = ImageDraftWriteResult.saved(recordID: result.payload["id"]?.string,
                                                    verified: result.payload["verified"]?.boolean ?? false)
            return await tellHost(approval, write, client: client)
        case .some(Self.notClaimedCode):
            return await reopen(key, decisionID: approval.decisionID, client: client)
        case let code? where ImageDraftFailureReason(rawValue: code) != nil:
            return await tellHost(approval, .failed(ImageDraftFailureReason(rawValue: code)!), client: client)
        default:
            return await settleUnclear(approval, hostState, client: client)
        }
    }

    /// The write may or may not have happened. Found: saved. Otherwise `outcome_unknown`, and the
    /// approval stays so the next load looks again. Never writes.
    private func settleUnclear(_ approval: ImageDraftApproval, _ hostState: ImageDraftHostState,
                               client: ImageDraftsAPI) async -> ImageDraftDecisionResult {
        if case .found(let recordID) = await writer.find(approval) {
            let write = ImageDraftWriteResult.saved(recordID: recordID, verified: true)
            record(approval, write)
            return await tellHost(approval, write, client: client)
        }
        record(approval, .outcomeUnknown)
        if hostState.state == .applying { return await tellHost(approval, .outcomeUnknown, client: client) }
        return .outcomeUnknown
    }

    // MARK: Journal

    /// One decision on a draft at a time; a second call gets the running one's result. Apple's
    /// editor path names its decision: a call for another decision is refused, so no editor ever
    /// opens on a claim made for another decision.
    private func once(_ key: ImageDraftKey, decisionID: String? = nil,
                      _ work: @escaping @MainActor () async -> ImageDraftDecisionResult) async -> ImageDraftDecisionResult {
        if let running = inFlight[key] {
            if let decisionID, let runningDecision = inFlightDecision[key], runningDecision != decisionID {
                return .refused(nil)
            }
            return await running.value
        }
        let task = Task { @MainActor in await work() }
        inFlight[key] = task
        inFlightDecision[key] = decisionID
        let result = await task.value
        inFlight[key] = nil
        inFlightDecision[key] = nil
        return result
    }

    private func record(_ approval: ImageDraftApproval, _ write: ImageDraftWriteResult) {
        switch write {
        case .saved(let recordID, let verified):
            var payload: [String: BighelpJSONValue] = ["verified": .boolean(verified)]
            if let recordID { payload["id"] = .string(recordID) }
            complete(approval, status: "completed", code: nil, payload: payload)
        case .failed(let reason): complete(approval, status: "failed", code: reason.rawValue)
        case .outcomeUnknown: complete(approval, status: "failed", code: Self.outcomeUnknownCode)
        }
    }

    /// A journal that can't be written now is settled on the next load by looking for the record.
    private func complete(_ approval: ImageDraftApproval, status: String, code: String?,
                          payload: [String: BighelpJSONValue] = [:]) {
        let now = Self.seconds(clock())
        let result = DeviceToolResult(request: Self.request(approval, now: now), status: status, code: code,
                                      payload: payload, sentAt: now)
        try? journal.save(DeviceToolJournalEntry(fingerprint: Self.fingerprint(approval),
                                                 expiresAt: now + Self.journalLifetime, result: result),
                          requestID: Self.requestID(approval), scope: Self.scope(approval.key))
    }

    static func requestID(_ approval: ImageDraftApproval) -> String {
        "image-draft:\(approval.key.draftID):\(approval.decisionID)"
    }

    /// One journal per computer and agent.
    static func scope(_ key: ImageDraftKey) -> DeviceToolScope {
        DeviceToolScope(deviceID: "image-drafts", authorizationEpoch: 1, hostID: key.scope + "\u{1F}" + key.agentID)
    }

    static func fingerprint(_ approval: ImageDraftApproval) -> String {
        ImageDraftHash.hex(approval.fieldsHash + "\u{1F}" + approval.destination.fingerprint)
    }

    /// The journal keeps results in the phone tools' shape; this request is never sent anywhere.
    private static func request(_ approval: ImageDraftApproval, now: Int) -> DeviceToolRequest {
        DeviceToolRequest(version: 1, type: "image.draft.decision", requestId: requestID(approval), deviceId: "image-drafts",
                          hostId: approval.key.scope, authorizationEpoch: 1, sessionId: approval.key.sessionID,
                          agentId: approval.key.agentID, turnId: approval.key.draftID,
                          operation: approval.preset == .businessCard ? "contacts.create" : "calendar.create",
                          arguments: [:], sentAt: now, expiresAt: now + journalLifetime)
    }

    private static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    private static func result(journaled result: DeviceToolResult) -> ImageDraftDecisionResult {
        switch result.code {
        case nil: return .saved(recordID: result.payload["id"]?.string, verified: result.payload["verified"]?.boolean ?? false)
        case let code?:
            if let reason = ImageDraftFailureReason(rawValue: code) { return .failed(reason) }
            return .outcomeUnknown
        }
    }

    private static func result(host state: ImageDraftHostState) -> ImageDraftDecisionResult {
        switch state.state {
        case .saved: .saved(recordID: nil, verified: state.verified ?? false)
        case .failed: .failed(state.reason ?? .writeFailed)
        case .outcomeUnknown: .outcomeUnknown
        case .discarded: .discarded
        case .awaitingReview: .reopened
        case .applying, .replaced: .refused(state)
        }
    }

    private static func result(refusal error: ImageDraftsError) -> ImageDraftDecisionResult {
        switch error {
        case .busy(let current), .decided(let current): .refused(current)
        case .notFound: .refused(nil)
        case .needsPluginUpdate: .needsPluginUpdate
        default: .unavailable
        }
    }
}
