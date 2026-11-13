import Testing
@testable import Bighelp

@MainActor
struct ApprovalModelTests {
    @Test func everyHermesApprovalScopeIsSubmittedWithoutCollapsingItsMeaning() async {
        let decisions: [ApprovalDecision] = [.once, .session, .always, .deny]

        for decision in decisions {
            let client = RecordingApprovalClient()
            let model = ApprovalModel(
                request: .vendorFixture,
                allowedDecisions: Set(decisions),
                client: client
            )

            await model.submit(decision)

            #expect(client.decisions == [decision])
            #expect(model.status == .resolved(decision))
        }
    }

    @Test func dynamicHermesSubsetExposesOnlyOfferedActionsInCanonicalOrder() {
        let model = ApprovalModel(
            request: .vendorFixture,
            allowedDecisions: [.always, .once, .deny],
            client: RecordingApprovalClient()
        )

        #expect(model.availableDecisions == [.once, .always, .deny])
    }

    @Test func approvalActionsUseTheExactHermesScopeLabels() {
        #expect(ApprovalDecision.once.buttonTitle == "Approve this time")
        #expect(ApprovalDecision.session.buttonTitle == "Approve this chat")
        #expect(ApprovalDecision.always.buttonTitle == "Always Approve")
        #expect(ApprovalDecision.deny.buttonTitle == "Deny")
    }

    @Test func approvalActionsUseNeutralBorderlessGlassPresentation() {
        for decision in ApprovalDecision.allCases {
            let presentation = ApprovalActionPresentation.resolve(for: decision)

            #expect(presentation.controlStyle == .neutralGlass)
            #expect(!presentation.usesColoredBackground)
            #expect(!presentation.drawsExplicitBorder)
            #expect(presentation.isDestructive == (decision == .deny))
        }
    }

    @Test func decisionHermesDidNotOfferCannotBeSubmitted() async {
        let client = RecordingApprovalClient()
        let model = ApprovalModel(
            request: .vendorFixture,
            allowedDecisions: [.once, .deny],
            client: client
        )

        await model.submit(.always)

        #expect(client.decisions.isEmpty)
        #expect(model.status == .idle)
    }

    @Test func pendingApprovalBlocksDuplicateSubmission() async {
        let client = ControlledApprovalClient()
        let model = ApprovalModel(request: .vendorFixture, client: client)

        let firstSubmission = Task { await model.submit(.once) }
        await client.waitUntilRequested()

        #expect(model.status == .pending)

        await model.submit(.deny)
        client.succeed(decision: .once)
        await firstSubmission.value

        #expect(client.submissionCount == 1)
        #expect(model.status == .resolved(.once))
    }

    @Test func failureRemainsVisibleAndCanRetry() async {
        let client = SequenceApprovalClient(results: [
            .failure(.offline),
            .success(.approvedFixture)
        ])
        let model = ApprovalModel(request: .vendorFixture, client: client)

        await model.submit(.once)

        #expect(model.status == .failed("Approval could not be confirmed. Try again."))

        await model.submit(.once)

        #expect(model.status == .resolved(.once))
    }

    @Test func declineSettlesOnlyFromReturnedReceipt() async {
        let client = SequenceApprovalClient(results: [.success(.declinedFixture)])
        let model = ApprovalModel(request: .vendorFixture, client: client)

        await model.submit(.deny)

        #expect(model.status == .resolved(.deny))
    }

    @Test func returnedDecisionOverridesAttemptedDecision() async {
        let client = SequenceApprovalClient(results: [.success(.declinedFixture)])
        let model = ApprovalModel(request: .vendorFixture, client: client)

        await model.submit(.once)

        #expect(model.status == .resolved(.deny))
    }

    @Test func receiptForAnotherRequestDoesNotSettleApproval() async {
        let invalidReceipt = ApprovalReceipt(
            requestID: "approval-for-another-request",
            decision: .once
        )
        let client = SequenceApprovalClient(results: [.success(invalidReceipt)])
        let model = ApprovalModel(request: .vendorFixture, client: client)

        await model.submit(.once)

        #expect(model.status == .failed("Approval could not be confirmed. Try again."))
    }
}

@MainActor
private final class RecordingApprovalClient: ApprovalClient {
    private(set) var decisions: [ApprovalDecision] = []

    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt {
        decisions.append(decision)
        return ApprovalReceipt(requestID: request.id, decision: decision)
    }
}

@MainActor
private final class ControlledApprovalClient: ApprovalClient {
    private var continuation: CheckedContinuation<ApprovalReceipt, Error>?
    private(set) var submissionCount = 0

    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt {
        submissionCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while submissionCount == 0 {
            await Task.yield()
        }
    }

    func succeed(decision: ApprovalDecision) {
        continuation?.resume(
            returning: ApprovalReceipt(
                requestID: ApprovalRequest.vendorFixture.id,
                decision: decision
            )
        )
        continuation = nil
    }
}

@MainActor
private final class SequenceApprovalClient: ApprovalClient {
    enum Failure: Error {
        case offline
    }

    private var results: [Result<ApprovalReceipt, Failure>]

    init(results: [Result<ApprovalReceipt, Failure>]) {
        self.results = results
    }

    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt {
        guard !results.isEmpty else { throw Failure.offline }
        return try results.removeFirst().get()
    }
}
