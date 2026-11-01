import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesFileAttachmentTests {
    @Test func nativeFileOnlyMessageUsesAttachmentReferenceWithoutInventingCaption() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let attachment = try file()
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client, initialItems: [])
        fixture.client.model = model
        try model.addDraftAttachment(attachment)
        #expect(model.canSend)
        await model.send()
        #expect(fixture.rpc.transferCalls.map(\.method) == ["file.attach", "prompt.submit"])
        #expect(fixture.rpc.transferCalls.last?.params["text"]?.string?.contains("@file:") == true)
        #expect(model.items.first?.content == .message(""))
        #expect(model.items.first?.attachments == [attachment])
        #expect(fixture.client.journal.unresolved.isEmpty)
    }

    @Test func filesStayLocalUntilSendAndPreserveCaptionAndDisclosure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let attachment = try file(name: "report one.txt")
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client,
                              initialItems: [], initialDraft: "Keep this caption")
        fixture.client.model = model
        try model.addDraftAttachment(attachment)
        #expect(fixture.rpc.transferCalls.isEmpty)
        await model.send()
        #expect(fixture.rpc.transferCalls.map(\.method) == ["file.attach", "prompt.submit"])
        #expect(fixture.rpc.transferCalls[0].params["path"] == nil)
        #expect(fixture.rpc.transferCalls[0].params["session_id"] == .string("runtime"))
        #expect(fixture.rpc.transferCalls[0].params["data_url"] == .string("data:text/plain;base64,aGVsbG8="))
        #expect(fixture.rpc.transferCalls[1].params["text"] == .string("Keep this caption\n@file:`/fixture/attachments/report one.txt`"))
        #expect(fixture.rpc.transferCalls[1].params["queued"] == .boolean(true))
        #expect(model.items.first?.content == .message("Keep this caption"))
        #expect(model.items.first?.attachments == [attachment])
        #expect(fixture.client.journal.unresolved.isEmpty)
    }

    @Test func completeBatchIsValidatedBeforeAnyUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let data = Data(repeating: 65, count: ChatAttachment.maximumBytes)
        let batch = try (0..<4).map { index in
            try ChatAttachment(id: "attachment_\(index)_fixture", fileName: "\(index).txt", mimeType: "text/plain", data: data)
        }
        await #expect(throws: ChatAttachmentError.invalidSize) {
            try await fixture.client.send(message: "Caption", attachments: batch,
                                          conversationID: fixture.client.conversationID, onDraft: { _ in })
        }
        #expect(fixture.rpc.transferCalls.isEmpty)
        #expect(fixture.client.journal.unresolved.isEmpty)
    }

    @Test func imagesCannotBeDisguisedAsOrdinaryFiles() async throws {
        let mime = "application/octet-stream"
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ1kAAAAASUVORK5CYII="))
        let attachment = try ChatAttachment(id: "attachment_image_fixture", fileName: "renamed.bin", mimeType: mime, data: image)
        await #expect(throws: ChatAttachmentError.unsupportedKind) {
            try await fixture.client.send(message: "Image", attachments: [attachment],
                                          conversationID: fixture.client.conversationID, onDraft: { _ in })
        }
        #expect(fixture.rpc.transferCalls.isEmpty)
        #expect(fixture.client.supportedAttachmentKinds == [.file, .image])
    }

    @Test func nativeModelStagesLocalImagesWithoutSending() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client, initialItems: [])
        let image = try ChatAttachment(id: "attachment_image_fixture", fileName: "image.png",
                                       mimeType: "image/png", data: Data([1, 2, 3]))
        try model.addDraftAttachment(image)
        #expect(model.draftAttachments == [image])
        #expect(fixture.rpc.transferCalls.isEmpty)
    }

    @Test func unknownUploadSurvivesRecreationAndCannotRetryOrSubmit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.rpc.uploadFailure = .timedOut(outcomeUnknown: true)
        let attachment = try file()
        await #expect(throws: DirectHermesError.timedOut(outcomeUnknown: true)) {
            try await fixture.client.send(message: "Retained", attachments: [attachment],
                                          conversationID: fixture.client.conversationID, onDraft: { _ in })
        }
        #expect(fixture.rpc.transferCalls.map(\.method) == ["file.attach"])
        #expect(fixture.client.needsRecovery)
        let reopened = try fixture.makeClient()
        #expect(reopened.needsRecovery)
        #expect(reopened.journal.unresolved.first?.text == "Retained")
        await #expect(throws: DirectHermesWorkspaceError.reviewRequired) {
            try await reopened.send(message: "Retained", attachments: [attachment],
                                    conversationID: reopened.conversationID, onDraft: { _ in })
        }
        #expect(fixture.rpc.transferCalls.count == 1)
    }

    @Test func ownerChangeAfterUploadReceiptCannotSubmit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.rpc.afterUpload = { [weak client = fixture.client] in client?.suspend() }
        await #expect(throws: DirectHermesError.disconnected(outcomeUnknown: true)) {
            try await fixture.client.send(message: "Retained", attachments: [file()],
                                          conversationID: fixture.client.conversationID, onDraft: { _ in })
        }
        #expect(fixture.rpc.transferCalls.map(\.method) == ["file.attach"])
        #expect(fixture.client.needsRecovery)
        #expect(fixture.client.journal.unresolved.count == 1)
    }

    @Test func cancellationBeforeSendDoesNotUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let attachment = try file()
        let task = Task { @MainActor in
            try await fixture.client.send(message: "Unsent", attachments: [attachment],
                                          conversationID: fixture.client.conversationID, onDraft: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.rpc.transferCalls.isEmpty)
        #expect(fixture.client.journal.unresolved.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationAtFinalUploadReceiptDoesNotSubmitAndRetainsReview(queued: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let attachment = try file()
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client,
                              initialItems: [], initialDraft: "Retain this draft")
        fixture.client.model = model
        fixture.rpc.afterUpload = {
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        let task = Task { @MainActor in
            if queued {
                _ = try await fixture.client.sendMidSession(
                    message: "Retain this draft", attachments: [attachment],
                    conversationID: fixture.client.conversationID, behavior: .queued, onDraft: { _ in }
                )
            } else {
                _ = try await fixture.client.send(
                    message: "Retain this draft", attachments: [attachment],
                    conversationID: fixture.client.conversationID, onDraft: { _ in }
                )
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.rpc.transferCalls.map(\.method) == ["file.attach"])
        #expect(model.draft == "Retain this draft")
        #expect(fixture.client.needsRecovery)
        let retained = try #require(fixture.client.journal.unresolved.first)
        #expect(retained.method == "file.attach")
        #expect(retained.text == "Retain this draft\n@file:`/fixture/attachments/report.txt`")
        let reopened = try fixture.makeClient()
        #expect(reopened.needsRecovery)
        #expect(reopened.journal.unresolved.first?.text == retained.text)
        await #expect(throws: DirectHermesWorkspaceError.reviewRequired) {
            try await reopened.send(message: "Retain this draft", attachments: [attachment],
                                    conversationID: reopened.conversationID, onDraft: { _ in })
        }
        #expect(fixture.rpc.transferCalls.count == 1)
    }

    @Test func malformedReferenceCannotBecomePromptText() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.rpc.invalidReference = true
        await #expect(throws: DirectHermesError.invalidResponse) {
            try await fixture.client.send(message: "Retained", attachments: [file()],
                                          conversationID: fixture.client.conversationID, onDraft: { _ in })
        }
        #expect(fixture.rpc.transferCalls.map(\.method) == ["file.attach"])
        #expect(fixture.client.needsRecovery)
    }

    @Test func eightMiBUploadBudgetIsNarrowAndCountsEncodedBytes() throws {
        let attachment = try file(data: Data(repeating: 65, count: ChatAttachment.maximumBytes))
        let payload = DirectHermesFileAttachments.payload(attachment, runtimeID: "runtime")
        let frame: BighelpJSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .string(UUID().uuidString),
            "method": .string("file.attach"), "params": .object(payload)
        ])
        let bytes = try JSONEncoder().encode(frame).count
        #expect(bytes > 8 * 1_024 * 1_024)
        #expect(bytes <= DirectHermesClient.outboundLimit(method: "file.attach", params: payload))
        #expect(DirectHermesClient.outboundLimit(method: "prompt.submit", params: payload) == 2 * 1_024 * 1_024)
        #expect(DirectHermesClient.outboundLimit(method: "image.attach_bytes", params: payload) == 2 * 1_024 * 1_024)
        var pathPayload = payload
        pathPayload["path"] = .string("/not-permitted")
        #expect(DirectHermesClient.outboundLimit(method: "file.attach", params: pathPayload) == 2 * 1_024 * 1_024)
    }

    @Test func attachmentPreparationClosesAdvertisedReadiness() async throws {
        let fixture = try Fixture()
        defer { fixture.client.suspend(); fixture.cleanup() }
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client,
                              initialItems: [], initialDraft: "Keep this caption\nAnd the second line")
        fixture.client.model = model
        let image = try fixtureImage()
        try model.addDraftAttachment(image)
        fixture.client.receive(.init(type: "session.info", sessionID: "runtime",
                                    payload: ["running": .boolean(true)], sequence: 1))
        #expect(model.canSend)
        fixture.rpc.duringUpload = {
            #expect(!fixture.client.isReadyForSubmission)
            #expect(fixture.client.hasAuthoritativeEventCoverage)
            #expect(!model.canSend)
            #expect(fixture.client.journal.unresolved.count == 1)
        }
        _ = try await fixture.client.sendMidSession(message: model.draft, attachments: [image],
            conversationID: fixture.client.conversationID, behavior: .queued, onDraft: { _ in })
        #expect(fixture.client.isReadyForSubmission)
        #expect(model.canSend)
        #expect(fixture.client.journal.unresolved.isEmpty)
    }

    @Test func suspendedUploadCannotBlockRecoveredSteeringOrResendOriginalIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.client.suspend(); fixture.cleanup() }
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client,
                              initialItems: [], initialDraft: "Keep this caption\nAnd the second line")
        fixture.client.model = model
        let image = try fixtureImage()
        try model.addDraftAttachment(image)
        fixture.client.receive(.init(type: "session.info", sessionID: "runtime",
                                    payload: ["running": .boolean(true)], sequence: 1))
        fixture.rpc.duringUpload = {
            let originalIDs = fixture.client.journal.unresolved.map(\.id)
            fixture.client.suspend()
            #expect(!fixture.client.isReadyForSubmission)
            fixture.client.rebind(fixture.rpc)
            #expect(!fixture.client.isReadyForSubmission)
            try await fixture.client.recover(epoch: "epoch")
            #expect(fixture.client.isReadyForSubmission)
            #expect(model.canSend)
            #expect(model.draftAttachments == [image])
            #expect(model.draft == "Keep this caption\nAnd the second line")
            // The original upload is still awaiting its response here. Only a
            // separate explicit new instruction may be admitted after recovery.
            _ = try await fixture.client.sendMidSession(message: "Independent steering",
                attachments: [], conversationID: fixture.client.conversationID,
                behavior: .steer, onDraft: { _ in })
            #expect(fixture.client.journal.unresolved.map(\.id) == originalIDs)
        }
        await #expect(throws: DirectHermesError.disconnected(outcomeUnknown: true)) {
            _ = try await fixture.client.sendMidSession(message: model.draft, attachments: [image],
                conversationID: fixture.client.conversationID, behavior: .queued, onDraft: { _ in })
        }
        #expect(fixture.rpc.calls.filter { $0.method == "image.attach_bytes" }.count == 1)
        #expect(fixture.rpc.calls.filter { $0.method == "session.steer" }.count == 1)
        #expect(!fixture.rpc.calls.contains { $0.method == "prompt.submit" })
        #expect(fixture.client.journal.unresolved.count == 1)
        #expect(fixture.client.journal.unresolved.first?.method == "file.attach")
        #expect(fixture.client.isReadyForSubmission)
    }

    private func fixtureImage() throws -> ChatAttachment {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ1kAAAAASUVORK5CYII="))
        return try ChatAttachment(id: "attachment_readiness_fixture", fileName: "image.png", mimeType: "image/png", data: png)
    }

    @Test func staleCatalogActivityDuringAttachmentPreparationCannotLatchRecoveredComposerDisabled() async throws {
        let fixture = try Fixture()
        defer { fixture.client.suspend(); fixture.cleanup() }
        let model = ChatModel(
            conversationID: fixture.client.conversationID,
            client: fixture.client,
            initialItems: [],
            initialDraft: "Connected draft"
        )
        fixture.client.model = model
        let attachment = try file()
        try model.addDraftAttachment(attachment)
        let staleCatalog = SessionRecord(
            id: fixture.client.conversationID,
            kind: .direct,
            agentIDs: ["default"],
            title: "Files",
            remoteStoredID: "stored",
            isActive: true
        )
        let invalidated = FileAttachmentObservationFlag()

        fixture.rpc.duringUpload = {
            #expect(fixture.client.connected)
            #expect(fixture.client.hasAuthoritativeEventCoverage)
            #expect(!fixture.client.isReadyForSubmission)

            model.beginHistoryHydration(from: staleCatalog)
            #expect(!model.isSending, "Navigation hydration must not revive stale catalog activity")
            model.finishHistoryHydration()
            model.reconcileHydratedSession(staleCatalog)

            #expect(!model.isSending, "A menu or sheet return must not revive stale catalog activity")
            #expect(!model.canSend, "The in-flight attachment preparation remains a valid temporary submission gate")
            withObservationTracking {
                _ = model.canSend
            } onChange: {
                invalidated.set()
            }
        }

        _ = try await fixture.client.send(
            message: model.draft,
            attachments: [attachment],
            conversationID: fixture.client.conversationID,
            onDraft: { _ in }
        )

        #expect(invalidated.value, "Completing attachment preparation must invalidate the observed composer action")
        #expect(fixture.client.isReadyForSubmission)
        #expect(!model.isSending)
        #expect(model.canSend, "A connected recovered draft must re-enable Send")

        // Send stays on through both (a message waits in the chat), but nothing goes to Hermes.
        fixture.client.requireTransportCatchup()
        #expect(fixture.client.connected)
        #expect(!model.takesMessageNow, "Connected but unverified event coverage must remain blocked")
        fixture.client.suspend()
        #expect(!model.takesMessageNow, "Disconnected authority must remain blocked")
    }

    // One at a time: the three cases share one conversation ID, and run side by side on the main actor
    // their sends and reconciles could interleave (a case passed in one run and failed in the next).
    @Test(.serialized, arguments: ["accepted", "rejected", "unknown"])
    func staleCatalogIdleCannotSupersedeModelAttachmentSend(outcome: String) async throws {
        let fixture = try Fixture()
        defer { fixture.client.suspend(); fixture.cleanup() }
        fixture.rpc.admissionOutcome = outcome
        fixture.rpc.recoveryRunning = false
        fixture.rpc.uploadGate = FileAttachmentAsyncGate()
        fixture.rpc.admissionGate = FileAttachmentAsyncGate()
        let model = ChatModel(
            conversationID: fixture.client.conversationID,
            client: fixture.client,
            initialItems: [],
            initialDraft: "Connected draft"
        )
        fixture.client.model = model
        try model.addDraftAttachment(file())
        let staleCatalog = SessionRecord(
            id: fixture.client.conversationID,
            kind: .direct,
            agentIDs: ["default"],
            title: "Files",
            remoteStoredID: "stored",
            isActive: true
        )
        let send = Task { @MainActor in await model.send() }

        await fixture.rpc.uploadGate?.waitUntilEntered()
        #expect(model.isSending)
        #expect(!fixture.client.isReadyForSubmission)
        #expect(!model.canSend)
        reconcileStaleCatalog(staleCatalog, into: model)
        #expect(model.isSending, "Idle catalog hydration must not retire the send while its attachment upload is pending")
        #expect(!model.canSend, "The composer must stay unavailable while attachment upload is pending")
        #expect(fixture.rpc.mutationCalls.map(\.method) == ["file.attach"])

        fixture.rpc.uploadGate?.open()
        await fixture.rpc.admissionGate?.waitUntilEntered()
        #expect(model.isSending)
        #expect(!fixture.client.isReadyForSubmission)
        #expect(!model.canSend)
        reconcileStaleCatalog(staleCatalog, into: model)
        #expect(model.isSending, "Idle catalog hydration must not retire the send while admission is pending")
        #expect(!model.canSend, "The composer must stay unavailable while admission is pending")
        #expect(fixture.rpc.mutationCalls.map(\.method) == ["file.attach", "prompt.submit"])

        fixture.rpc.admissionGate?.open()
        await send.value

        #expect(fixture.rpc.mutationCalls.map(\.method) == ["file.attach", "prompt.submit"])
        #expect(!model.isSending)
        switch outcome {
        case "accepted":
            #expect(fixture.client.journal.unresolved.isEmpty)
            #expect(!fixture.client.needsRecovery)
            #expect(fixture.client.isReadyForSubmission)
            #expect(model.failureMessage == nil)
        case "rejected":
            #expect(fixture.client.journal.unresolved.count == 1)
            #expect(fixture.client.journal.unresolved.first?.rejectionCode == 4001)
            #expect(fixture.client.journal.unresolved.first?.text == "Connected draft")
            #expect(!fixture.client.needsRecovery)
            #expect(!fixture.client.isReadyForSubmission)
            #expect(fixture.client.requiresDurableReattachment)
            #expect(!model.canRetry)
            #expect(model.failureMessage?.contains("Reopen it before sending") == true)
            #expect(model.draft == "Connected draft")
            #expect(model.items.allSatisfy { $0.role != .human })
        default:
            #expect(fixture.client.journal.unresolved.count == 1)
            #expect(!model.canRetry)
            #expect(model.failureMessage == "Message delivery is unconfirmed. It will not be sent again automatically.")
        }
    }

    /// The client releases a lost submission's waiter and reports the chat idle in one step (a
    /// replacement snapshot; the recovery after an unknown outcome does the same). The send runs
    /// after that, and still says its delivery is unconfirmed: retired by the idle report, it said
    /// nothing, and the "unknown" case above failed whenever the recovery ran first.
    @Test func anIdleReportBeforeTheSendResumesKeepsTheUnconfirmedDelivery() async throws {
        let fixture = try Fixture()
        defer { fixture.client.suspend(); fixture.cleanup() }
        fixture.rpc.admissionGate = FileAttachmentAsyncGate()
        let model = ChatModel(conversationID: fixture.client.conversationID, client: fixture.client,
                              initialItems: [], initialDraft: "Connected draft")
        fixture.client.model = model
        try model.addDraftAttachment(file())
        let send = Task { @MainActor in await model.send() }
        await fixture.rpc.admissionGate?.waitUntilEntered()
        #expect(model.isSending)

        fixture.client.applySnapshot(.object(["session_id": .string("runtime"), "stored_session_id": .string("stored"),
                                              "running": .boolean(false), "messages": .array([])]), epoch: "epoch")
        await send.value
        fixture.rpc.admissionGate?.open()

        #expect(!model.isSending)
        #expect(fixture.client.journal.unresolved.count == 1)
        #expect(!model.canRetry)
        #expect(model.failureMessage == "Message delivery is unconfirmed. It will not be sent again automatically.")
    }

    private func reconcileStaleCatalog(_ session: SessionRecord, into model: ChatModel) {
        model.beginHistoryHydration(from: session)
        model.finishHistoryHydration()
        model.reconcileHydratedSession(session)
    }
    private func file(name: String = "report.txt", data: Data = Data("hello".utf8)) throws -> ChatAttachment {
        try ChatAttachment(id: "attachment_file_fixture", fileName: name, mimeType: "text/plain", data: data)
    }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let rpc = RPC()
        let client: DirectHermesConversationClient
        init() throws {
            client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "test-host", profile: "default",
                                                        runtimeID: "runtime", storedID: "stored", title: "Files", epoch: "epoch",
                                                        drafts: DirectHermesDraftStore(root: directory))
        }
        func makeClient() throws -> DirectHermesConversationClient {
            try DirectHermesConversationClient(rpc: rpc, hostIdentity: "test-host", profile: "default",
                                                runtimeID: "runtime", storedID: "stored", title: "Files", epoch: "epoch",
                                                drafts: DirectHermesDraftStore(root: directory))
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private final class RPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        var calls: [(method: String, params: [String: BighelpJSONValue])] = []
        // Goal hydration is an independent read, not an upload or submission.
        // Preserve the complete log while asserting the consequential sequence.
        var transferCalls: [(method: String, params: [String: BighelpJSONValue])] {
            calls.filter { $0.method != "session.control.read" }
        }
        var uploadFailure: DirectHermesError?
        var duringUpload: (() async throws -> Void)?
        var afterUpload: (() -> Void)?
        var invalidReference = false
        var uploadGate: FileAttachmentAsyncGate?
        var admissionGate: FileAttachmentAsyncGate?
        var admissionOutcome = "accepted"
        var recoveryRunning = true
        var mutationCalls: [(method: String, params: [String: BighelpJSONValue])] {
            calls.filter { ["file.attach", "prompt.submit"].contains($0.method) }
        }
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            calls.append((method, params))
            if method == "session.control.read" {
                #expect(params["session_id"] == .string("runtime"))
                return .object(["control": .object([
                    "goal": .null, "loop": .null, "heartbeat": .null,
                    "revision": .string("fixture-empty"), "updated_at": .integer(0)
                ])])
            }
            if method == "session.events.since" {
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(1),
                                "truncated": .boolean(false), "events": .array([])])
            }
            if method == "session.activate" {
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("stored"),
                                "session_key": .string("stored"), "running": .boolean(recoveryRunning), "messages": .array([])])
            }
            if method == "subagent.list" { return .object(["subagents": .array([])]) }
            if method == "session.steer" { return .object(["status": .string("queued")]) }
            if method == "image.attach_bytes" {
                try await duringUpload?()
                let bytes = Data(base64Encoded: params["content_base64"]?.string ?? "")?.count ?? 0
                return .object(["attached": .boolean(true), "path": .string("/fixture/images/image.png"),
                                "name": .string("image.png"), "count": .integer(1), "bytes": .integer(bytes),
                                "text": .string("[User attached image: image.png]")])
            }
            if method == "file.attach" {
                await uploadGate?.wait()
                try await duringUpload?()
                if let uploadFailure { throw uploadFailure }
                let name = params["name"]?.string ?? "report.txt"
                let path = "/fixture/attachments/" + name
                afterUpload?()
                return .object(["attached": .boolean(true), "uploaded": .boolean(true), "name": .string(name),
                                "path": .string(path), "ref_path": .string(path),
                                "ref_text": .string(invalidReference ? "@file:other.txt" : "@file:`\(path)`")])
            }
            if method == "prompt.submit" {
                await admissionGate?.wait()
                if admissionOutcome == "rejected" {
                    throw DirectHermesError.rpcRejected(code: 4001)
                }
                if admissionOutcome == "unknown" {
                    throw DirectHermesError.timedOut(outcomeUnknown: true)
                }
                return .object(["status": .string("queued")])
            }
            throw DirectHermesError.invalidResponse
        }
        func disconnect() async {}
    }
}

@MainActor
private final class FileAttachmentAsyncGate {
    private var entered = false
    private var isOpen = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !entered {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume() }
            else { blocked = continuation }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        blocked?.resume()
        blocked = nil
    }
}

private final class FileAttachmentObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }

    func set() {
        lock.withLock { isSet = true }
    }
}
