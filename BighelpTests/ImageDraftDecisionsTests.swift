import Foundation
import Testing
@testable import Bighelp

/// Exactly one write per Save (docs/IMAGE_DRAFTS.md › Exactly one write), against the demo
/// computer (the plugin's state rules) and a writer that counts what it writes.
@MainActor
struct ImageDraftDecisionsTests {
    typealias Fixture = ImageDraftTestData

    @MainActor
    private final class Harness {
        let demo: DemoImageDraftsClient
        let client: ScriptedImageDraftsClient
        let writer = CountingImageDraftWriter()
        let journal = ImageDraftMemoryJournal()
        let local: ImageDraftLocalFile
        lazy var decisions: ImageDraftDecisions = makeDecisions()
        var api: ImageDraftsAPI { ImageDraftsAPI(client: client) }

        init() {
            let demo = DemoImageDraftsClient(registersUnknownDrafts: false)
            demo.register(draftID: Fixture.contactID, agentID: Fixture.key.agentID, sessionID: Fixture.key.sessionID)
            self.demo = demo
            client = ScriptedImageDraftsClient(demo)
            local = ImageDraftLocalFile(url: FileManager.default.temporaryDirectory
                .appending(path: "image-drafts-\(UUID().uuidString)").appending(path: "drafts-v1.json"))
        }

        /// A fresh coordinator over the same journal and file: the app after a relaunch.
        func makeDecisions() -> ImageDraftDecisions {
            ImageDraftDecisions(writer: writer, journal: journal, pending: local)
        }

        var hostState: DemoImageDraftsClient.Row? { demo.rows[Fixture.contactID] }

        func approval() throws -> ImageDraftApproval { try Fixture.readyContactReview().approval(key: Fixture.key) }

        /// What a Save leaves behind when bighelp closes after the claim and before the write's outcome.
        func interruptedSave() async throws -> ImageDraftApproval {
            let approval = try approval()
            try local.setPendingApproval(approval)
            try journal.save(DeviceToolJournalEntry(fingerprint: ImageDraftDecisions.fingerprint(approval),
                                                    expiresAt: Int(Date().timeIntervalSince1970) + 3_600, result: nil),
                             requestID: ImageDraftDecisions.requestID(approval), scope: ImageDraftDecisions.scope(approval.key))
            _ = try await api.claim(approval)
            return approval
        }
    }

    // MARK: Nothing is written without Save (F01, F04)

    @Test func nothingIsWrittenBeforeSaveOrAfterDiscard() async throws {
        let harness = Harness()
        _ = ImageDraftReview(draft: Fixture.contact)
        #expect(harness.writer.writes.isEmpty)
        #expect(await harness.decisions.discard(Fixture.key, client: harness.api) == .discarded)
        #expect(harness.hostState?.state == .discarded)
        let result = await harness.decisions.save(try harness.approval(), client: harness.api)
        guard case .refused(let current) = result else { Issue.record("Saved a discarded draft: \(result)"); return }
        #expect(current?.state == .discarded)
        #expect(harness.writer.writes.isEmpty)
    }

    @Test func aSaveWritesTheApprovalOnceAndTellsTheHost() async throws {
        let harness = Harness()
        let approval = try harness.approval()
        #expect(await harness.decisions.save(approval, client: harness.api) == .saved(recordID: "record-1", verified: true))
        #expect(harness.writer.writes == [approval])
        #expect(harness.hostState?.state == .saved)
        #expect(harness.hostState?.verified == true)
        #expect(harness.hostState?.fieldsHash == approval.fieldsHash)
        #expect(harness.local.pendingApproval(for: Fixture.key) == nil)
        let entry = try harness.journal.entry(requestID: ImageDraftDecisions.requestID(approval), scope: ImageDraftDecisions.scope(approval.key))
        #expect(entry?.result?.status == "completed")
        #expect(entry?.result?.payload["id"] == .string("record-1"))
        // The journal of a Save never holds the person's details.
        #expect(entry?.result?.payload.keys.sorted() == ["id", "verified"])
    }

    // MARK: One write (B06)

    @Test func aSecondSaveWhileOneRunsGetsThatOnesResult() async throws {
        let harness = Harness()
        harness.writer.pause = true
        let first = try harness.approval(), second = try harness.approval()
        let decisions = harness.decisions, api = harness.api
        let one = Task { await decisions.save(first, client: api) }
        let two = Task { await decisions.save(second, client: api) }
        while harness.writer.writes.isEmpty { await Task.yield() }
        harness.writer.pause = false
        let results = await [one.value, two.value]
        #expect(results == [.saved(recordID: "record-1", verified: true), .saved(recordID: "record-1", verified: true)])
        #expect(harness.writer.writes.count == 1)
    }

    @Test func anotherDevicesSaveRefusesThisOneWithItsState() async throws {
        let harness = Harness()
        let elsewhere = try harness.approval()
        _ = try await harness.api.claim(elsewhere)
        let result = await harness.decisions.save(try harness.approval(), client: harness.api)
        guard case .refused(let current?) = result else { Issue.record("Expected refused, got \(result)"); return }
        #expect(current.state == .applying)
        #expect(current.decisionID == elsewhere.decisionID)
        #expect(harness.writer.writes.isEmpty)
        #expect(harness.local.pendingApproval(for: Fixture.key) == nil)
    }

    @Test func aLostClaimAnswerIsAskedAgainNotRetriedAsANewSave() async throws {
        let harness = Harness()
        harness.client.loseAnswer[.claim] = 1
        let approval = try harness.approval()
        #expect(await harness.decisions.save(approval, client: harness.api) == .saved(recordID: "record-1", verified: true))
        #expect(harness.writer.writes.count == 1)
        #expect(harness.demo.calls.filter { $0.operation == .claim }.count == 2)
    }

    /// The host took the claim but both answers were lost: nothing is written, the claim is given
    /// back with this decision, and the draft can be saved again (it never stays "Saving…").
    @Test func aClaimLostTwiceIsGivenBackAndTheDraftCanBeSavedAgain() async throws {
        let harness = Harness()
        harness.client.loseAnswer[.claim] = 2
        let approval = try harness.approval()
        #expect(await harness.decisions.save(approval, client: harness.api) == .unavailable)
        #expect(harness.writer.writes.isEmpty, "Nothing was written")
        #expect(harness.hostState?.state == .awaitingReview, "The claim was given back")
        #expect(harness.local.pendingApproval(for: Fixture.key) == nil)
        let again = try harness.approval()
        #expect(await harness.decisions.save(again, client: harness.api) == .saved(recordID: "record-1", verified: true))
        #expect(harness.writer.writes == [again])
    }

    /// The claim and the give-back both fail: the decision stays on the phone, and the next load
    /// gives the claim back. Still nothing is written.
    @Test func aClaimThatCantBeGivenBackNowIsGivenBackOnTheNextLoad() async throws {
        let harness = Harness()
        harness.client.loseAnswer[.claim] = 2
        harness.client.failBefore[.reopen] = 1
        let approval = try harness.approval()
        #expect(await harness.decisions.save(approval, client: harness.api) == .unavailable)
        #expect(harness.hostState?.state == .applying)
        #expect(harness.local.pendingApproval(for: Fixture.key) != nil, "Kept to give the claim back later")
        let relaunched = harness.makeDecisions()
        #expect(await relaunched.reconcile(Fixture.key, client: harness.api) == .reopened)
        #expect(harness.hostState?.state == .awaitingReview)
        #expect(harness.writer.writes.isEmpty)
    }

    /// A card whose content was changed and rehashed isn't the card the plugin made: the host's
    /// `cardHash` differs, so the claim is given back before anything is written.
    @Test func aClaimForACardThePluginDidntMakeWritesNothing() async throws {
        let harness = Harness()
        harness.demo.setCardHash(String(repeating: "a", count: 64), for: Fixture.contactID)
        let approval = try harness.approval()
        #expect(await harness.decisions.save(approval, client: harness.api, cardHash: String(repeating: "b", count: 64))
                == .mismatched)
        #expect(harness.writer.writes.isEmpty)
        #expect(harness.hostState?.state == .awaitingReview)
    }

    // MARK: After a relaunch (B10, B19)

    @Test func anInterruptedSaveIsUnclearUntilTheRecordIsFound() async throws {
        let harness = Harness()
        let approval = try await harness.interruptedSave()
        let relaunched = harness.makeDecisions()
        harness.writer.found = .notFound
        #expect(await relaunched.reconcile(Fixture.key, client: harness.api) == .outcomeUnknown)
        #expect(harness.hostState?.state == .outcomeUnknown)
        #expect(harness.writer.writes.isEmpty)
        #expect(harness.local.pendingApproval(for: Fixture.key) == approval)
        // Not found again: still unclear, still nothing written.
        #expect(await harness.makeDecisions().reconcile(Fixture.key, client: harness.api) == .outcomeUnknown)
        #expect(harness.writer.writes.isEmpty)
        harness.writer.found = .found("record-9")
        #expect(await harness.makeDecisions().reconcile(Fixture.key, client: harness.api) == .saved(recordID: "record-9", verified: true))
        #expect(harness.hostState?.state == .saved)
        #expect(harness.hostState?.verified == true)
        #expect(harness.writer.writes.isEmpty)
        #expect(harness.local.pendingApproval(for: Fixture.key) == nil)
    }

    @Test func onlyThePersonsCheckReopensAnUnclearSave() async throws {
        let harness = Harness()
        _ = try await harness.interruptedSave()
        let decisions = harness.makeDecisions()
        #expect(await decisions.reconcile(Fixture.key, client: harness.api) == .outcomeUnknown)
        // A new Save can't hide the unclear one.
        let blocked = await decisions.save(try harness.approval(), client: harness.api)
        #expect(blocked == .outcomeUnknown)
        #expect(harness.writer.writes.isEmpty)
        let host = try await harness.api.state(of: Fixture.key)
        #expect(await decisions.reopenAfterCheck(Fixture.key, hostState: host, client: harness.api) == .reopened)
        #expect(harness.hostState?.state == .awaitingReview)
        #expect(await decisions.save(try harness.approval(), client: harness.api) == .saved(recordID: "record-1", verified: true))
        #expect(harness.writer.writes.count == 1)
    }

    @Test func aSaveThatNeverReachedTheHostWroteNothing() async throws {
        let harness = Harness()
        let approval = try harness.approval()
        try harness.local.setPendingApproval(approval)
        try harness.journal.save(DeviceToolJournalEntry(fingerprint: ImageDraftDecisions.fingerprint(approval),
                                                        expiresAt: Int(Date().timeIntervalSince1970) + 3_600, result: nil),
                                 requestID: ImageDraftDecisions.requestID(approval), scope: ImageDraftDecisions.scope(approval.key))
        #expect(await harness.makeDecisions().reconcile(Fixture.key, client: harness.api) == nil)
        #expect(harness.local.pendingApproval(for: Fixture.key) == nil)
        #expect(harness.writer.finds == 0)
        #expect(harness.writer.writes.isEmpty)
    }

    @Test func aLostFinishIsToldAgainOnTheNextLoad() async throws {
        let harness = Harness()
        harness.client.failBefore[.finish] = 1
        let approval = try harness.approval()
        #expect(await harness.decisions.save(approval, client: harness.api) == .saved(recordID: "record-1", verified: true))
        #expect(harness.hostState?.state == .applying)
        #expect(harness.local.pendingApproval(for: Fixture.key) == approval)
        #expect(await harness.makeDecisions().reconcile(Fixture.key, client: harness.api) == .saved(recordID: "record-1", verified: true))
        #expect(harness.hostState?.state == .saved)
        #expect(harness.writer.writes.count == 1)
    }

    // MARK: Failures (B11)

    @Test func aRevokedPermissionFailsAndTheNextSaveCanGo() async throws {
        let harness = Harness()
        harness.writer.result = .failed(.permissionDenied)
        #expect(await harness.decisions.save(try harness.approval(), client: harness.api) == .failed(.permissionDenied))
        #expect(harness.hostState?.state == .failed)
        #expect(harness.hostState?.reason == .permissionDenied)
        harness.writer.result = .saved(recordID: "record-2", verified: true)
        #expect(await harness.decisions.save(try harness.approval(), client: harness.api) == .saved(recordID: "record-2", verified: true))
        #expect(harness.hostState?.state == .saved)
    }

    // MARK: Apple's editor

    @Test func cancellingTheEditorWritesNothingAndGivesTheDraftBack() async throws {
        let harness = Harness()
        let approval = try harness.approval()
        #expect(await harness.decisions.claimForEditor(approval, client: harness.api) == .readyForEditor)
        #expect(harness.hostState?.state == .applying)
        #expect(await harness.decisions.finishFromEditor(approval, outcome: .cancelled, client: harness.api) == .reopened)
        #expect(harness.hostState?.state == .awaitingReview)
        #expect(harness.writer.writes.isEmpty)
        let next = try harness.approval()
        #expect(await harness.decisions.claimForEditor(next, client: harness.api) == .readyForEditor)
        #expect(await harness.decisions.finishFromEditor(next, outcome: .saved(recordID: nil, verified: false), client: harness.api)
                == .saved(recordID: nil, verified: false))
        #expect(harness.hostState?.state == .saved)
        #expect(harness.hostState?.verified == false)
        #expect(harness.writer.writes.isEmpty)
    }

    @Test func aCheckedRecordFinishesAsSavedUnverified() async throws {
        let harness = Harness()
        _ = try await harness.interruptedSave()
        let decisions = harness.makeDecisions()
        _ = await decisions.reconcile(Fixture.key, client: harness.api)
        let host = try await harness.api.state(of: Fixture.key)
        #expect(await decisions.confirmSaved(Fixture.key, hostState: host, client: harness.api) == .saved(recordID: nil, verified: false))
        #expect(harness.hostState?.state == .saved)
        #expect(harness.writer.writes.isEmpty)
    }
}

// MARK: - The store

@MainActor
struct ImageDraftStoreTests {
    typealias Fixture = ImageDraftTestData

    private func makeStore() -> (ImageDraftStore, DemoImageDraftsClient, DemoImageDraftContacts) {
        let demo = DemoImageDraftsClient(registersUnknownDrafts: false)
        demo.register(draftID: Fixture.contactID, agentID: Fixture.key.agentID, sessionID: Fixture.key.sessionID)
        let contacts = DemoImageDraftContacts()
        let writer = ImageDraftWriter(contacts: contacts, calendar: DemoImageDraftCalendar())
        let store = ImageDraftStore(
            connection: { (Fixture.key.scope, ImageDraftsAPI(client: demo), writer) },
            local: ImageDraftLocalFile(url: FileManager.default.temporaryDirectory
                .appending(path: "image-drafts-\(UUID().uuidString)").appending(path: "drafts-v1.json")),
            journal: ImageDraftMemoryJournal(), attachmentCache: nil)
        return (store, demo, contacts)
    }

    private func review(destination: ImageDraftDestination = DemoImageDraftContacts.accounts[1].destination) -> ImageDraftReview {
        var review = ImageDraftReview(draft: Fixture.contact)
        review.contact?.emails[0].value = "riley@example.com"
        review.destination = destination
        return review
    }

    @Test func savingWritesToTheChosenAccountAndTheCardSaysSo() async {
        let (store, demo, contacts) = makeStore()
        let status = await store.save(review(), key: Fixture.key)
        guard case .saved(let destination, let recordID?, let verified) = status else { Issue.record("Not saved: \(status)"); return }
        #expect(destination == "Gmail")
        #expect(verified)
        #expect(contacts.containers[recordID] == "demo-container-gmail")
        #expect(contacts.records.count == 2)
        #expect(store.status(Fixture.key) == status)
        #expect(demo.rows[Fixture.contactID]?.state == .saved)
    }

    @Test func aBlockedReviewSavesNothingAndSaysWhy() async {
        let (store, demo, contacts) = makeStore()
        var blocked = review()
        blocked.contact?.givenName = nil
        blocked.contact?.organization = nil
        #expect(await store.save(blocked, key: Fixture.key) == .unknown)
        #expect(store.lastError[Fixture.key] == "Add a first name, last name or company.")
        #expect(contacts.records.count == 1)
        #expect(demo.calls.isEmpty)
    }

    @Test func discardRecordsItAndDropsTheEdits() async throws {
        let (store, demo, contacts) = makeStore()
        store.keepEdits(review().edits, for: Fixture.key)
        #expect(store.edits(Fixture.key) != nil)
        #expect(await store.discard(Fixture.key) == .discarded)
        #expect(store.edits(Fixture.key) == nil)
        #expect(demo.rows[Fixture.contactID]?.state == .discarded)
        #expect(contacts.records.count == 1)
    }

    @Test func aFailedSaveKeepsThePersonsEdits() async {
        let (store, _, contacts) = makeStore()
        contacts.access = .denied
        let edited = review()
        #expect(await store.save(edited, key: Fixture.key) == .failed(.permissionDenied))
        #expect(store.edits(Fixture.key) == edited.edits)
        #expect(contacts.records.count == 1)
    }

    @Test func cardsOnScreenAreReadTogether() async throws {
        let (store, demo, _) = makeStore()
        store.noteVisible(Fixture.key)
        store.noteVisible(Fixture.key)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status(Fixture.key) == .unknown, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.status(Fixture.key) == .awaitingReview)
        #expect(demo.calls.filter { $0.operation == .states }.count == 1)
    }

    /// A card whose content isn't the card the plugin made for this draft (an agent pasted an edited
    /// copy, say) shows as not matching, and Save writes nothing.
    @Test func aCardThatIsntTheHostsCardCantBeSaved() async throws {
        let (store, demo, contacts) = makeStore()
        demo.setCardHash(String(repeating: "a", count: 64), for: Fixture.contactID)
        store.noteVisible(Fixture.key, cardHash: String(repeating: "b", count: 64))
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status(Fixture.key) == .unknown, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.status(Fixture.key) == .mismatched)
        #expect(await store.save(review(), key: Fixture.key) == .mismatched)
        #expect(contacts.records.count == 1, "Nothing was written")
        #expect(demo.rows[Fixture.contactID]?.state == .awaitingReview, "Nothing was claimed")
    }

    @Test func aCardThatIsTheHostsCardReadsAsWaiting() async throws {
        let (store, demo, _) = makeStore()
        let hash = String(repeating: "a", count: 64)
        demo.setCardHash(hash, for: Fixture.contactID)
        store.noteVisible(Fixture.key, cardHash: hash)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status(Fixture.key) == .unknown, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.status(Fixture.key) == .awaitingReview)
    }

    @Test func destinationsAndLookAlikesComeFromTheWriter() async {
        let (store, _, _) = makeStore()
        let options = await store.options(for: .businessCard)
        #expect(options.access == .granted)
        #expect(options.choices.map(\.destination.label) == ["iCloud", "Gmail", "On My iPhone"])
        #expect(options.suggested.label == "iCloud")
        #expect(!options.savesThroughAppleEditor)
        let calendars = await store.options(for: .eventPoster)
        #expect(calendars.choices.map { "\($0.group ?? "")/\($0.destination.label)" } == ["iCloud/Home", "iCloud/Work", "iCloud/Family", "Gmail/Personal"])
        let moss = ImageDraftFields.contact(ContactDraftFields(givenName: "Riley", familyName: "Moss"))
        guard case .found(let found) = await store.duplicates(of: moss) else { Issue.record("No look-alike"); return }
        #expect(found.map(\.title) == ["Riley Moss"])
        #expect(await store.duplicates(of: .contact(ContactDraftFields(givenName: "Jordan"))) == ImageDraftDuplicateCheck.none)
    }
}

// MARK: - Fakes

/// Counts writes; `pause` holds a write until the test lets it go.
@MainActor
final class CountingImageDraftWriter: ImageDraftWriting {
    var writes: [ImageDraftApproval] = []
    var result: ImageDraftWriteResult = .saved(recordID: "record-1", verified: true)
    var found: ImageDraftFindResult = .notFound
    var finds = 0
    var pause = false

    func write(_ approval: ImageDraftApproval) async -> ImageDraftWriteResult {
        writes.append(approval)
        while pause { await Task.yield() }
        return result
    }

    func find(_ approval: ImageDraftApproval) async -> ImageDraftFindResult {
        finds += 1
        if case .found(let id) = found, approval.existingRecordIDs?.contains(id) == true { return .notFound }
        return found
    }

    var lookAlikes: [String] = []

    func lookAlikeIDs(_ approval: ImageDraftApproval) async -> [String] { lookAlikes }
}

/// The demo computer, with answers that fail before the host hears (`failBefore`) or after it acted
/// (`loseAnswer`, the host's change stands and the phone sees `outcomeUnknown`), as a real link can.
@MainActor
final class ScriptedImageDraftsClient: ImageDraftsClient {
    let host: DemoImageDraftsClient
    var failBefore: [ImageDraftsOperation: Int] = [:]
    var loseAnswer: [ImageDraftsOperation: Int] = [:]

    init(_ host: DemoImageDraftsClient) {
        self.host = host
    }

    func perform(_ operation: ImageDraftsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        if let count = failBefore[operation], count > 0 {
            failBefore[operation] = count - 1
            throw WorkspaceClientError.transportUnavailable
        }
        let reply = try await host.perform(operation, payload: payload)
        if let count = loseAnswer[operation], count > 0 {
            loseAnswer[operation] = count - 1
            throw WorkspaceClientError.outcomeUnknown
        }
        return reply
    }
}

@MainActor
final class ImageDraftMemoryJournal: DeviceToolJournal {
    var values: [String: DeviceToolJournalEntry] = [:]

    func entry(requestID: String, scope: DeviceToolScope) throws -> DeviceToolJournalEntry? {
        values[scope.storageKey + requestID]
    }

    func save(_ entry: DeviceToolJournalEntry, requestID: String, scope: DeviceToolScope) throws {
        values[scope.storageKey + requestID] = entry
    }
}

/// The writer's check after an interrupted Save, on the demo address book (one Riley Moss saved).
@MainActor
struct ImageDraftWriterTests {
    private func approval(existing: [String]?) throws -> ImageDraftApproval {
        var review = ImageDraftReview(draft: ImageDraftTestData.contact)
        review.fields = .contact(ContactDraftFields(givenName: "Riley", familyName: "Moss", organization: "Sample Studio",
                                                    emails: [ImageDraftLabeledValue(label: "work", value: "riley.moss@example.org")]))
        review.destination = ImageDraftDestination(kind: .contacts, identifier: nil, label: "iCloud")
        var approval = try review.approval(key: ImageDraftTestData.key)
        approval.existingRecordIDs = existing
        return approval
    }

    /// The person saved a contact that was already there (the review showed it as a look-alike) and
    /// bighelp closed mid-write: the old contact is never taken for the new one.
    @Test func aRecordThatWasThereBeforeTheSaveIsNeverTheOneItMade() async throws {
        let writer = ImageDraftWriter(contacts: DemoImageDraftContacts(), calendar: DemoImageDraftCalendar())
        let lookAlikes = await writer.lookAlikeIDs(try approval(existing: nil))
        #expect(lookAlikes == ["demo-contact-riley"])
        #expect(await writer.find(try approval(existing: nil)) == .found("demo-contact-riley"))
        #expect(await writer.find(try approval(existing: lookAlikes)) == .notFound)
    }
}

/// Fixing a wrongly guessed time zone keeps the poster's clock time.
@MainActor
struct ImageDraftTimeZoneTests {
    @Test func changingTheZoneKeepsTheTimeOnThePoster() {
        var timed = EventDraftFields.Timed(start: "2030-06-15T19:00:00-04:00", end: "2030-06-15T21:00:00-04:00",
                                           timeZone: "America/New_York")
        ImageDraftReviewSheet.change(&timed, toZone: "America/Los_Angeles")
        #expect(timed.timeZone == "America/Los_Angeles")
        #expect(timed.start == "2030-06-15T19:00:00-07:00")
        #expect(timed.end == "2030-06-15T21:00:00-07:00")
    }
}
