import Foundation
import ImageIO
import Observation
import OSLog
import UIKit

/// What a draft card shows: the host's state, this phone's journal, and whether a Save runs here.
enum ImageDraftStatus: Equatable, Sendable {
    /// Not read yet: the card shows the draft as waiting, without a spinner.
    case unknown
    case awaitingReview
    /// A Save is running, here or on another device.
    case applying
    case saved(destination: String?, recordID: String?, verified: Bool)
    case failed(ImageDraftFailureReason?)
    /// The person checks Contacts or Calendar before saving again.
    case outcomeUnknown
    case discarded
    case replaced(by: String?)
    /// The card in the chat isn't the card the plugin made for this draft: it can't be saved.
    case mismatched

    init(_ state: ImageDraftHostState) {
        switch state.state {
        case .awaitingReview: self = .awaitingReview
        case .applying: self = .applying
        case .saved: self = .saved(destination: state.destination, recordID: nil, verified: state.verified ?? false)
        case .failed: self = .failed(state.reason)
        case .outcomeUnknown: self = .outcomeUnknown
        case .discarded: self = .discarded
        case .replaced: self = .replaced(by: state.replacedBy)
        }
    }
}

/// The computer in use: its cache scope, its draft routes, and the phone's Contacts and Calendar.
typealias ImageDraftsConnection = (scope: String, api: ImageDraftsAPI, writer: ImageDraftWriter)

/// Drafts in chats on the computer in use (docs/IMAGE_DRAFTS.md › The app): each card's state,
/// the person's edits, the photo, and every decision. Cards read `status(_:)`; nothing here
/// rebuilds the chat, and no view decodes or encodes a picture.
@MainActor
@Observable
final class ImageDraftStore {
    /// Set up by the app with the computer in use (`BighelpApp`).
    static let shared = ImageDraftStore()

    /// One `image-drafts/states` call at most this often, for every draft that came on screen since.
    static let refreshInterval: Duration = .seconds(3)
    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "ImageDrafts")
    static let thumbnailPixels: CGFloat = 192
    static let photoPixels: CGFloat = 2_048
    static let maximumThumbnails = 60
    static let maximumPhotos = 2

    /// Each draft's state in its own observed object, so one draft's change redraws its own card
    /// and not every card in the chat.
    @ObservationIgnored private var entries: [ImageDraftKey: ImageDraftLiveState] = [:]
    @ObservationIgnored private var cardHashes: [ImageDraftKey: String] = [:]
    @ObservationIgnored private var tampered = Set<ImageDraftKey>()
    @ObservationIgnored private var editorConnections: [String: ImageDraftsConnection] = [:]
    @ObservationIgnored private var failedReads = 0
    static let maximumFailedReads = 5
    /// A plain note for the review when a call failed without changing the draft (no connection,
    /// an older plugin, a Save that can't go yet).
    private(set) var lastError: [ImageDraftKey: String] = [:]

    @ObservationIgnored var connection: @MainActor () -> ImageDraftsConnection?
    @ObservationIgnored private let local: ImageDraftLocalFile
    @ObservationIgnored private let journal: any DeviceToolJournal
    @ObservationIgnored private let attachmentCache: AgentAttachmentCache?
    @ObservationIgnored private var decisionsByWriter: (writer: ImageDraftWriter, decisions: ImageDraftDecisions)?
    @ObservationIgnored private var hostStates: [ImageDraftKey: ImageDraftHostState] = [:]
    @ObservationIgnored private var queued = Set<ImageDraftKey>()
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var loadingImages: [ImageDraftKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var imageUse: [ImageDraftKey] = []

    init(connection: @escaping @MainActor () -> ImageDraftsConnection? = { nil },
         local: ImageDraftLocalFile = ImageDraftLocalFile(),
         journal: any DeviceToolJournal = DeviceToolFileJournal(url: ImageDraftLocalFile.directory.appending(path: "decisions-v1.json")),
         attachmentCache: AgentAttachmentCache? = .shared) {
        self.connection = connection
        self.local = local
        self.journal = journal
        self.attachmentCache = attachmentCache
    }

    // MARK: Card state

    func status(_ key: ImageDraftKey) -> ImageDraftStatus { entry(key).status }

    private func entry(_ key: ImageDraftKey) -> ImageDraftLiveState {
        if let entry = entries[key] { return entry }
        let entry = ImageDraftLiveState()
        entries[key] = entry
        return entry
    }

    /// A card came on screen. Its state is read with every other card shown since the last read,
    /// up to 50 a call, a few seconds apart; a Save this phone didn't finish telling the host
    /// about is settled then.
    /// A card whose content isn't what its hash says (an edited copy) can't be saved, whatever the host says.
    func markMismatched(_ key: ImageDraftKey) {
        tampered.insert(key)
        entry(key).status = .mismatched
    }

    /// The card's own `content_hash`: when the host's record of the card it made differs, the card
    /// in the chat isn't that card (an edited copy), so it shows as not matching and can't be saved.
    func noteVisible(_ key: ImageDraftKey, cardHash: String?) {
        if let cardHash { cardHashes[key] = cardHash.lowercased() }
        noteVisible(key)
    }

    func noteVisible(_ key: ImageDraftKey) {
        queued.insert(key)
        guard refreshing == nil else { return }
        refreshing = Task { @MainActor [weak self] in
            await self?.refreshQueued()
            self?.refreshing = nil
            // Cards that came on screen during the read go in the next one.
            if let self, !self.queued.isEmpty, let next = self.queued.first { self.noteVisible(next) }
        }
    }

    private func refreshQueued() async {
        if let lastRefresh {
            let wait = Self.refreshInterval - (ContinuousClock.now - lastRefresh)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        lastRefresh = .now
        let keys = queued
        queued.removeAll()
        guard let connection = connection() else { return requeue(keys) }
        let groups = Dictionary(grouping: keys.filter { $0.scope == connection.scope }) { ChatGroup(agentID: $0.agentID, sessionID: $0.sessionID) }
        for (chat, members) in groups {
            let states: [ImageDraftHostState]
            do throws(ImageDraftsError) {
                states = try await connection.api.states(agentID: chat.agentID, sessionID: chat.sessionID,
                                                         draftIDs: members.map(\.draftID))
            } catch {
                if error == .needsPluginUpdate {
                    for key in members { lastError[key] = Self.note(ImageDraftDecisionResult.needsPluginUpdate) }
                } else {
                    requeue(members)
                }
                continue
            }
            failedReads = 0
            let byID = Dictionary(states.map { ($0.draftID, $0) }) { first, _ in first }
            for key in members {
                guard let state = byID[key.draftID] else { continue }
                hostStates[key] = state
                if tampered.contains(key) { continue }
                if let made = state.cardHash, let shown = cardHashes[key], made != shown {
                    apply(.mismatched, to: key)
                    continue
                }
                if !decisions(connection).isBusy(key) { apply(ImageDraftStatus(state), to: key) }
                if let pending = local.pendingApproval(for: key),
                   let result = await decisions(connection).reconcile(key, hostState: state, client: connection.api) {
                    apply(result, key: key, destination: pending.destination.label)
                }
            }
        }
    }

    /// A read that didn't happen is tried again with the next one, a few times; the cards stay
    /// as they were meanwhile, and are read again whenever they come back on screen.
    private func requeue(_ keys: some Sequence<ImageDraftKey>) {
        failedReads += 1
        guard failedReads <= Self.maximumFailedReads else { return }
        queued.formUnion(keys)
    }

    private struct ChatGroup: Hashable {
        let agentID: String
        let sessionID: String
    }

    /// A saved record's id from this phone stays when the host reports the same save without it.
    private func apply(_ status: ImageDraftStatus, to key: ImageDraftKey) {
        guard !tampered.contains(key) else {
            entry(key).status = .mismatched
            return
        }
        if case .saved(_, let recordID?, _) = entry(key).status, case .saved(let destination, nil, let verified) = status {
            entry(key).status = .saved(destination: destination, recordID: recordID, verified: verified)
        } else {
            entry(key).status = status
        }
    }

    // MARK: Pictures

    func thumbnail(_ key: ImageDraftKey) -> UIImage? { entry(key).thumbnail }

    func photo(_ key: ImageDraftKey) -> UIImage? { entry(key).photo }

    /// Downloads the person's picture once (kept with the chat files the agent sent), and makes the
    /// card's thumbnail and the review's photo off the main actor.
    func loadImages(_ key: ImageDraftKey, source: ImageDraftSource) async {
        if entry(key).thumbnail != nil, entry(key).photo != nil { return }
        if let loading = loadingImages[key] { return await loading.value }
        let task = Task { @MainActor [weak self] in
            guard let self, let data = await self.imageData(key, source: source) else { return }
            let sizes = (thumbnail: Self.thumbnailPixels, photo: Self.photoPixels)
            let decoded = await Task.detached(priority: .userInitiated) {
                (ImageDraftDecodedImage.make(data, maxPixels: sizes.thumbnail),
                 ImageDraftDecodedImage.make(data, maxPixels: sizes.photo))
            }.value
            if let thumbnail = decoded.0 { self.entry(key).thumbnail = UIImage(cgImage: thumbnail.image) }
            if let photo = decoded.1 { self.entry(key).photo = UIImage(cgImage: photo.image) }
            self.trimImages(using: key)
        }
        loadingImages[key] = task
        await task.value
        loadingImages[key] = nil
    }

    private func imageData(_ key: ImageDraftKey, source: ImageDraftSource) async -> Data? {
        let cacheKey = AgentAttachmentCache.key(key.scope, key.agentID, key.sessionID, "image-draft", key.draftID, source.imageID)
        if let cached = await attachmentCache?.entry(for: cacheKey)?.attachments.first { return cached.data }
        guard let connection = connection(), connection.scope == key.scope else { return nil }
        do throws(ImageDraftsError) {
            let image = try await connection.api.sourceImage(key)
            if let attachment = try? ChatAttachment.agentArtifact(id: source.imageID, fileName: "photo",
                                                                  mimeType: image.mimeType, data: image.data) {
                await attachmentCache?.store(.init(text: "", attachments: [attachment]), for: cacheKey)
            }
            return image.data
        } catch {
            // Codes only: never the picture or the draft's details.
            Self.log.error("A draft's picture didn't load: \(String(describing: error), privacy: .public)")
            if error == .needsPluginUpdate { lastError[key] = Self.note(ImageDraftDecisionResult.needsPluginUpdate) }
            return nil
        }
    }

    /// Keeps the most recently loaded pictures; the bytes stay on disk to make them again.
    private func trimImages(using key: ImageDraftKey) {
        imageUse.removeAll { $0 == key }
        imageUse.append(key)
        for (index, old) in imageUse.reversed().enumerated() {
            if index >= Self.maximumPhotos { entries[old]?.photo = nil }
            if index >= Self.maximumThumbnails { entries[old]?.thumbnail = nil }
        }
        if imageUse.count > Self.maximumThumbnails { imageUse.removeFirst(imageUse.count - Self.maximumThumbnails) }
    }

    // MARK: Edits

    func edits(_ key: ImageDraftKey) -> ImageDraftEdits? { local.edits(for: key) }

    /// Closing the review keeps the person's edits.
    func keepEdits(_ edits: ImageDraftEdits, for key: ImageDraftKey) { local.keepEdits(edits, for: key) }

    // MARK: Destinations

    func options(for preset: ImageDraftPreset) async -> ImageDraftDestinationOptions {
        guard let writer = connection()?.writer else {
            return ImageDraftDestinationOptions(access: .restricted, choices: [],
                                                suggested: .systemDefault(ImageDraftDestination.kind(for: preset)))
        }
        return await writer.options(for: preset)
    }

    func requestAccess(for preset: ImageDraftPreset) async -> ImageDraftDestinationOptions {
        guard let writer = connection()?.writer else { return await options(for: preset) }
        return await writer.requestAccess(for: preset)
    }

    func duplicates(of fields: ImageDraftFields) async -> ImageDraftDuplicateCheck {
        await connection()?.writer.duplicates(of: fields) ?? .cannotCheck
    }

    // MARK: Decisions

    /// Saves exactly the reviewed fields: approval, journal, claim, write, read back, finish. A
    /// second call for the same draft while one runs gets that run's result.
    func save(_ review: ImageDraftReview, key: ImageDraftKey) async -> ImageDraftStatus {
        if entry(key).status == .mismatched { return .mismatched }
        guard let connection = connection(), connection.scope == key.scope else { return failedCall(key, .unavailable) }
        let coordinator = decisions(connection)
        let approval: ImageDraftApproval
        do throws(ImageDraftReviewError) {
            approval = try review.approval(key: key)
        } catch {
            if case .blocked(let blockers) = error { lastError[key] = blockers.first?.message }
            return status(key)
        }
        local.keepEdits(review.edits, for: key)
        entry(key).status = .applying
        let result = await coordinator.save(approval, client: connection.api, cardHash: cardHashes[key])
        return apply(result, key: key, destination: approval.destination.label)
    }

    /// Apple's editor (no access): claims the draft and returns the approval whose fields the editor
    /// opens with. Nil when the claim was refused or the review can't be saved yet.
    func beginEditorSave(_ review: ImageDraftReview, key: ImageDraftKey) async -> ImageDraftApproval? {
        if entry(key).status == .mismatched { return nil }
        guard let connection = connection(), connection.scope == key.scope else {
            _ = failedCall(key, .unavailable)
            return nil
        }
        let approval: ImageDraftApproval
        do throws(ImageDraftReviewError) {
            approval = try review.approval(key: key)
        } catch {
            if case .blocked(let blockers) = error { lastError[key] = blockers.first?.message }
            return nil
        }
        local.keepEdits(review.edits, for: key)
        entry(key).status = .applying
        let result = await decisions(connection).claimForEditor(approval, client: connection.api, cardHash: cardHashes[key])
        guard result == .readyForEditor else {
            _ = apply(result, key: key, destination: approval.destination.label)
            return nil
        }
        // Apple's screen answers on this connection, even if the app has moved on by then.
        editorConnections[approval.decisionID] = connection
        return approval
    }

    /// The editor's Done saves (verified when bighelp can read the record back); Cancel writes
    /// nothing and gives the draft back for review.
    func finishEditorSave(_ approval: ImageDraftApproval, result: ImageDraftEditorResult) async -> ImageDraftStatus {
        let key = approval.key
        // The connection the claim was made on: the editor's Done or Cancel is journaled whatever the
        // app is connected to now, and the host hears it when it can.
        guard let connection = editorConnections.removeValue(forKey: approval.decisionID)
                ?? connection().flatMap({ $0.scope == key.scope ? $0 : nil }) else { return failedCall(key, .unavailable) }
        let outcome: ImageDraftEditorOutcome
        switch result {
        case .saved(let recordID):
            var readable = false
            if let recordID { readable = await connection.writer.isReadable(recordID, preset: approval.preset) }
            outcome = .saved(recordID: recordID, verified: readable)
        case .cancelled:
            outcome = .cancelled
        }
        let decision = await decisions(connection).finishFromEditor(approval, outcome: outcome, client: connection.api)
        return apply(decision, key: key, destination: approval.destination.label)
    }

    /// Records `discarded`; the person's edits go with it. Writes nothing.
    func discard(_ key: ImageDraftKey) async -> ImageDraftStatus {
        guard let connection = connection(), connection.scope == key.scope else { return failedCall(key, .unavailable) }
        let result = await decisions(connection).discard(key, client: connection.api)
        if result == .discarded { local.keepEdits(nil, for: key) }
        return apply(result, key: key, destination: nil)
    }

    /// The person checked after an unclear or failed Save and the record isn't there: back to review.
    func reopen(_ key: ImageDraftKey) async -> ImageDraftStatus {
        guard let connection = connection(), connection.scope == key.scope else { return failedCall(key, .unavailable) }
        let result = await decisions(connection).reopenAfterCheck(key, hostState: hostStates[key], client: connection.api)
        return apply(result, key: key, destination: nil)
    }

    /// The person checked and the record is there: saved, not verified by bighelp.
    func confirmSaved(_ key: ImageDraftKey) async -> ImageDraftStatus {
        guard let connection = connection(), connection.scope == key.scope else { return failedCall(key, .unavailable) }
        let destination = local.pendingApproval(for: key)?.destination.label ?? hostStates[key]?.destination
        let result = await decisions(connection).confirmSaved(key, hostState: hostStates[key], client: connection.api)
        return apply(result, key: key, destination: destination)
    }

    /// One decisions coordinator per writer, sharing this phone's journal and pending approvals.
    private func decisions(_ connection: ImageDraftsConnection) -> ImageDraftDecisions {
        if let current = decisionsByWriter, current.writer === connection.writer { return current.decisions }
        let made = ImageDraftDecisions(writer: connection.writer, journal: journal, pending: local)
        decisionsByWriter = (connection.writer, made)
        return made
    }

    @discardableResult
    private func apply(_ result: ImageDraftDecisionResult, key: ImageDraftKey, destination: String?) -> ImageDraftStatus {
        lastError[key] = nil
        switch result {
        case .saved(let recordID, let verified): entry(key).status = .saved(destination: destination, recordID: recordID, verified: verified)
        case .failed(let reason): entry(key).status = .failed(reason)
        case .outcomeUnknown: entry(key).status = .outcomeUnknown
        case .discarded: entry(key).status = .discarded
        case .reopened: entry(key).status = .awaitingReview
        case .readyForEditor: entry(key).status = .applying
        case .refused(let current?):
            hostStates[key] = current
            entry(key).status = ImageDraftStatus(current)
            lastError[key] = Self.note(result)
        case .mismatched:
            entry(key).status = .mismatched
        case .refused(nil), .invalidApproval, .needsPluginUpdate, .unavailable:
            return failedCall(key, result)
        }
        return status(key)
    }

    /// Nothing changed: the draft keeps the state it had, and the review says why.
    private func failedCall(_ key: ImageDraftKey, _ result: ImageDraftDecisionResult) -> ImageDraftStatus {
        if entry(key).status == .applying { entry(key).status = hostStates[key].map(ImageDraftStatus.init) ?? .awaitingReview }
        lastError[key] = Self.note(result)
        return status(key)
    }

    static func note(_ result: ImageDraftDecisionResult) -> String? {
        switch result {
        case .refused(let current):
            switch current?.state {
            case .applying?: return "This draft is being saved on another device."
            case .saved?, .discarded?, .replaced?: return "This draft was already decided."
            default: return "This draft can't be saved now. Close it and try again."
            }
        case .invalidApproval: return "Check the details, then save again."
        case .needsPluginUpdate: return "Update the bighelp plugin to save drafts from photos."
        case .unavailable: return "Couldn't reach your computer. Nothing was saved; try again."
        case .mismatched: return "This card doesn't match the draft the agent made. Ask for it again."
        default: return nil
        }
    }

    /// Erases every draft's edits and pending Saves on this phone (a removed computer).
    func eraseLocalData() {
        local.erase()
        // Cleared in place: cards on screen observe these objects.
        for entry in entries.values {
            entry.status = .unknown
            entry.thumbnail = nil
            entry.photo = nil
        }
        lastError = [:]
        hostStates = [:]
    }
}

/// A decoded picture crossing from the decoder to the main actor. CGImage is immutable.
struct ImageDraftDecodedImage: @unchecked Sendable {
    let image: CGImage

    /// Downscaled and decoded now, so drawing it never decodes on the main thread.
    nonisolated static func make(_ data: Data, maxPixels: CGFloat) -> ImageDraftDecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        return ImageDraftDecodedImage(image: image)
    }
}

extension ImageDraftWriter {
    /// Whether bighelp can read a record Apple's editor saved (it can't without access).
    func isReadable(_ recordID: String, preset: ImageDraftPreset) async -> Bool {
        switch preset {
        case .businessCard: (try? await contacts.readBack(id: recordID)) != nil
        case .eventPoster: (try? await calendar.readBack(id: recordID)) != nil
        }
    }
}

/// One draft's status and pictures. Cards observe their own.
@MainActor
@Observable
final class ImageDraftLiveState {
    var status: ImageDraftStatus = .unknown
    var thumbnail: UIImage?
    var photo: UIImage?
}
