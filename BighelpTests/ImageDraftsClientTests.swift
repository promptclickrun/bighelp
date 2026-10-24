import Foundation
import Testing
@testable import Bighelp

/// The `image-drafts` routes' state rules (docs/IMAGE_DRAFTS.md › Routes), through the typed API
/// over the demo computer, which answers and refuses the way the plugin does.
@MainActor
struct ImageDraftsClientTests {
    typealias Fixture = ImageDraftTestData

    private func setUp() -> (DemoImageDraftsClient, ImageDraftsAPI) {
        let demo = DemoImageDraftsClient(registersUnknownDrafts: false)
        demo.register(draftID: Fixture.contactID, agentID: Fixture.key.agentID, sessionID: Fixture.key.sessionID)
        return (demo, ImageDraftsAPI(client: demo))
    }

    private func approval() throws -> ImageDraftApproval {
        try Fixture.readyContactReview().approval(key: Fixture.key)
    }

    // MARK: Claim (B06)

    @Test func theSameDecisionClaimsAgainAndAnotherIsRefusedWithTheState() async throws {
        let (_, api) = setUp()
        let first = try approval(), second = try approval()
        #expect(try await api.claim(first).state == .applying)
        #expect(try await api.claim(first).state == .applying)
        do throws(ImageDraftsError) {
            _ = try await api.claim(second)
            Issue.record("A second decision claimed a busy draft")
        } catch {
            guard case .busy(let current?) = error else { Issue.record("Expected busy, got \(error)"); return }
            #expect(current.state == .applying)
            #expect(current.decisionID == first.decisionID)
            #expect(current.destination == "iCloud")
        }
        _ = try await api.finish(first, outcome: .saved, verified: true)
        do throws(ImageDraftsError) {
            _ = try await api.claim(second)
            Issue.record("A decided draft was claimed again")
        } catch {
            guard case .decided(let current?) = error else { Issue.record("Expected decided, got \(error)"); return }
            #expect(current.state == .saved)
            #expect(current.decisionID == first.decisionID)
        }
    }

    // MARK: Finish (B07)

    @Test func onlyTheClaimingDecisionFinishes() async throws {
        let (_, api) = setUp()
        let first = try approval(), second = try approval()
        _ = try await api.claim(first)
        await #expect(throws: ImageDraftsError.self) { _ = try await api.finish(second, outcome: .saved, verified: true) }
        let unclear = try await api.finish(first, outcome: .outcomeUnknown, verified: false)
        #expect(unclear.state == .outcomeUnknown)
        // An unclear outcome may later finish as saved, once.
        let saved = try await api.finish(first, outcome: .saved, verified: true)
        #expect(saved.state == .saved)
        #expect(saved.verified == true)
        await #expect(throws: ImageDraftsError.self) { _ = try await api.finish(first, outcome: .failed, reason: .writeFailed, verified: false) }
    }

    @Test func aFailedFinishNeedsItsReason() async throws {
        let (_, api) = setUp()
        let first = try approval()
        _ = try await api.claim(first)
        await #expect(throws: ImageDraftsError.refused("invalid_request")) {
            _ = try await api.finish(first, outcome: .failed, verified: false)
        }
        let failed = try await api.finish(first, outcome: .failed, reason: .permissionDenied, verified: false)
        #expect(failed.state == .failed)
        #expect(failed.reason == .permissionDenied)
    }

    // MARK: Discard and reopen (B08)

    @Test func discardIsHarmlessAgainAndRefusedWhileApplying() async throws {
        let (demo, api) = setUp()
        let first = try approval()
        _ = try await api.claim(first)
        await #expect(throws: ImageDraftsError.self) { _ = try await api.discard(Fixture.key) }
        _ = try await api.reopen(Fixture.key, decisionID: first.decisionID)
        #expect(try await api.discard(Fixture.key).state == .discarded)
        #expect(try await api.discard(Fixture.key).state == .discarded)
        await #expect(throws: ImageDraftsError.self) { _ = try await api.claim(try approval()) }
        #expect(demo.rows[Fixture.contactID]?.state == .discarded)
    }

    @Test func reopenFollowsTheContract() async throws {
        let (_, api) = setUp()
        let first = try approval(), second = try approval()
        _ = try await api.claim(first)
        // Only the claiming Save knows Apple's editor was cancelled.
        await #expect(throws: ImageDraftsError.self) { _ = try await api.reopen(Fixture.key, decisionID: second.decisionID) }
        let back = try await api.reopen(Fixture.key, decisionID: first.decisionID)
        #expect(back.state == .awaitingReview)
        #expect(back.decisionID == nil)
        _ = try await api.claim(second)
        _ = try await api.finish(second, outcome: .failed, reason: .writeFailed, verified: false)
        #expect(try await api.reopen(Fixture.key, decisionID: first.decisionID).state == .awaitingReview)
        let third = try approval()
        _ = try await api.claim(third)
        _ = try await api.finish(third, outcome: .saved, verified: true)
        await #expect(throws: ImageDraftsError.self) { _ = try await api.reopen(Fixture.key, decisionID: third.decisionID) }
    }

    @Test func aDraftBelongsToOneAgentAndOneChat() async throws {
        let (_, api) = setUp()
        let other = ImageDraftKey(scope: "computer-a", agentID: "helper", sessionID: Fixture.key.sessionID, draftID: Fixture.contactID)
        await #expect(throws: ImageDraftsError.notFound) { _ = try await api.discard(other) }
        let elsewhere = ImageDraftKey(scope: "computer-a", agentID: Fixture.key.agentID, sessionID: "session-2", draftID: Fixture.contactID)
        await #expect(throws: ImageDraftsError.notFound) { _ = try await api.discard(elsewhere) }
        #expect(try await api.states(agentID: "helper", sessionID: Fixture.key.sessionID, draftIDs: [Fixture.contactID]).isEmpty)
    }

    // MARK: States and source

    @Test func statesGoFiftyACallAndLeaveOutUnknownDrafts() async throws {
        let (demo, api) = setUp()
        let ids = (0..<60).map { String(format: "d_%032x", $0) } + [Fixture.contactID]
        let states = try await api.states(agentID: Fixture.key.agentID, sessionID: Fixture.key.sessionID, draftIDs: ids)
        #expect(states.map(\.draftID) == [Fixture.contactID])
        #expect(states.first?.state == .awaitingReview)
        #expect(demo.calls.filter { $0.operation == .states }.map { $0.payload["draftIds"]?.array?.count } == [50, 11])
    }

    @Test func thePictureComesInPiecesAndIsPutBackTogether() async throws {
        let (demo, api) = setUp()
        let bytes = Data((0..<10_000).map { UInt8($0 % 251) })
        demo.images[Fixture.contactID] = (bytes, "image/jpeg")
        demo.pieceBytes = 4_096
        let image = try await api.sourceImage(Fixture.key)
        #expect(image.data == bytes)
        #expect(image.mimeType == "image/jpeg")
        #expect(demo.calls.filter { $0.operation == .source }.map { $0.payload["offset"]?.integer } == [0, 4_096, 8_192])
    }

    // MARK: Settings

    @Test func settingsSaveWithTheRevisionTheyWereReadAt() async throws {
        let (_, api) = setUp()
        var page = try await api.settings(agentID: "default")
        #expect(page.settings.revision == 0)
        #expect(page.defaults == ImageActionsDefaults.standard)
        page.settings.set(offer: false, for: .businessCard)
        let saved = try await api.save(page.settings, agentID: "default")
        #expect(saved.revision == 1)
        #expect(saved[.businessCard].offer == false)
        await #expect(throws: ImageDraftsError.revisionConflict) { _ = try await api.save(page.settings, agentID: "default") }
    }

    // MARK: Wire

    @Test func everyRouteNeedsThePluginFeature() {
        for operation in ImageDraftsOperation.allCases {
            #expect(DirectHermesNativePluginClient.supports(operation.workspaceOperation))
        }
        #expect(ImageDraftsError(WorkspaceClientError.unavailable(.unsupportedOperation)) == .needsPluginUpdate)
        #expect(ImageDraftsError(WorkspaceClientError.rejected(code: "draft_busy")) == .busy(nil))
        #expect(ImageDraftsError(WorkspaceClientError.outcomeUnknown) == .outcomeUnknown)
    }

    @Test func hostStatesReadLeniently() {
        let state = ImageDraftHostState(json: [
            "draftId": .string(Fixture.contactID), "state": .string("saved"), "decisionId": .string("NOT-A-UUID"),
            "verified": .boolean(true), "future": .string("ignored"), "updatedAt": .string("2030-06-15T18:00:00Z"),
        ])
        #expect(state?.state == .saved)
        #expect(state?.decisionID == nil)
        #expect(state?.verified == true)
        #expect(ImageDraftHostState(json: ["state": .string("applying")], draftID: Fixture.contactID)?.draftID == Fixture.contactID)
        #expect(ImageDraftHostState(json: ["state": .string("melted")], draftID: Fixture.contactID) == nil)
    }

    /// Every draft route's largest answer gets through the HTTP client's size fence. On a real host
    /// the picture route was refused before it was even sent (`messageTooLarge`), which the demo,
    /// with no HTTP in between, never showed.
    @Test func everyDraftRoutesAnswerFitsTheHTTPSizeFence() throws {
        for operation in ImageDraftsOperation.allCases {
            let budget = try #require(DirectHermesNativePluginClient.responseBudget(operation.workspaceOperation))
            #expect(budget.maximumResponseBytes <= DirectHermesHTTP.responseLimit(route: budget.path, method: "POST", query: []),
                    "\(budget.path)")
        }
    }
}
