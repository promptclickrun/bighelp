import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesSessionControlClientTests {
    @Test func pickerUsesAuthoritativeRuntimePairRatherThanCatalogCurrentPair() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.pendingInfoModel = "new-model"
        let client = fixture.client()
        let picker = try #require(try await client.openPicker(fixture.open(.model)).model)
        #expect(picker.sessionID == fixture.appID)
        #expect(picker.currentModel == "new-model")
        #expect(picker.currentProvider == "native-provider")
        #expect(fixture.calls.filter { $0.operation == .sessionActivate }.count == 1)
        let activation = try #require(fixture.calls.first { $0.operation == .sessionActivate })
        #expect(activation.payload == ["session_id": .string("runtime-chat"), "omit_messages": .boolean(true)])
        let options = try #require(fixture.calls.first { $0.operation == .modelOptions })
        #expect(options.payload == ["profile": .string("studio"), "session_id": .string("runtime-chat")])
    }

    @Test func repeatedModelPickerUsesCachedCatalogAndRevalidatesSessionMetadata() async throws {
        let fixture = try SessionControlWorkspace()
        let client = fixture.client()
        _ = try await client.openPicker(fixture.open(.model))
        _ = try await client.openPicker(fixture.open(.model))
        #expect(fixture.calls.filter { $0.operation == .modelOptions }.count == 1)
        #expect(fixture.calls.filter { $0.operation == .sessionActivate }.count == 2)
        fixture.model = "new-model"
        let changed = try #require(try await client.openPicker(fixture.open(.model)).model)
        #expect(changed.currentModel == "new-model")
        #expect(fixture.calls.filter { $0.operation == .modelOptions }.count == 1)
    }

    @Test func sharedCatalogIsReusedAcrossSessionsWhileRuntimePairIsReadPerSession() async throws {
        let first = try SessionControlWorkspace()
        first.models.append("session-two-model")
        let second = try SessionControlWorkspace(anchorID: "stored-chat-2")
        second.model = "session-two-model"
        second.models = first.models
        let cache = DirectHermesModelCatalogCache()

        let firstPicker = try #require(try await first.client(modelCache: cache).openPicker(first.open(.model)).model)
        let secondPicker = try #require(try await second.client(modelCache: cache).openPicker(second.open(.model)).model)

        #expect(firstPicker.currentModel == "old-model")
        #expect(secondPicker.currentModel == "session-two-model")
        #expect(first.calls.filter { $0.operation == .modelOptions }.count == 1)
        #expect(second.calls.filter { $0.operation == .modelOptions }.count == 0)
        #expect(secondPicker.providers == firstPicker.providers)
    }

    @Test func concurrentModelAndReasoningPickersShareOneAuthoritativeActivation() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.yieldOnActivation = true
        let client = fixture.client()

        async let model = client.openPicker(fixture.open(.model))
        async let reasoning = client.openPicker(fixture.open(.reasoning))
        _ = try await (model, reasoning)

        #expect(fixture.calls.filter { $0.operation == .sessionActivate }.count == 1)
        #expect(fixture.calls.filter { $0.operation == .modelOptions }.count == 1)
    }

    @Test func productionAppIDBeyondLegacyWireLimitOpensBothLocalPickers() async throws {
        let fixture = try SessionControlWorkspace(anchorID: String(repeating: "a", count: 512))
        #expect(fixture.appID.utf8.count > 180)
        #expect(fixture.appID.hasPrefix("native-session-v1:"))
        let client = fixture.client()
        #expect(client.selectionSupport(sessionID: fixture.appID, agentID: "studio").modelUnavailableReason == nil)
        let model = try #require(try await client.openPicker(fixture.open(.model)).model)
        let reasoning = try #require(try await client.openPicker(fixture.open(.reasoning)).choice)
        #expect(model.sessionID == fixture.appID)
        #expect(reasoning.sessionID == fixture.appID)
        let selection = try await fixture.selection(client)
        let result = try await client.selectPicker(selection)
        #expect(result.sessionID == fixture.appID)
        #expect(result.status == .completed)
        #expect(try await client.selectPicker(selection).status == .expired)
    }

    @Test func nativeAppIdentityMustMatchOwnerProfileAndCanonicalEncodingBeforeHostCalls() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.resolveAnySession = true
        let otherOwner = WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://other.example.test",
                                   providerID: "fixture-provider", userID: "fixture-user"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        let invalidIDs = [
            "session_native",
            fixture.appID + "=",
            "native-session-v1:" + String(repeating: "a", count: 4096),
            try DirectHermesSessionIdentity.appID(owner: otherOwner, profileID: "studio", anchorID: "stored-chat"),
            try DirectHermesSessionIdentity.appID(owner: fixture.originalOwner, profileID: "other", anchorID: "stored-chat")
        ]
        let client = fixture.client()
        for appID in invalidIDs {
            #expect(client.selectionSupport(sessionID: appID, agentID: "studio").modelUnavailableReason != nil)
            await #expect(throws: WorkspaceClientError.invalidRequest) {
                _ = try await client.openPicker(fixture.open(.model, sessionID: appID))
            }
        }
        #expect(fixture.calls.isEmpty)
    }

    @Test func resolverCannotSubstituteAnotherVisibleNativeSession() async throws {
        let fixture = try SessionControlWorkspace()
        let otherID = try DirectHermesSessionIdentity.appID(
            owner: fixture.originalOwner, profileID: "studio", anchorID: "other-chat"
        )
        fixture.coordinate = try WorkspaceSessionCoordinate(
            owner: fixture.originalOwner, profileID: "studio", sessionID: otherID,
            storedSessionID: "stored-chat", runtimeSessionID: "runtime-chat"
        )
        let client = fixture.client()
        #expect(client.selectionSupport(sessionID: fixture.appID, agentID: "studio").modelUnavailableReason != nil)
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            _ = try await client.openPicker(fixture.open(.model))
        }
        #expect(fixture.calls.isEmpty)
    }

    @Test func nativePickerProjectionDoesNotWidenLinkWireContracts() async throws {
        let fixture = try SessionControlWorkspace()
        let selection = try await fixture.selection(fixture.client())
        #expect(throws: BighelpLinkWireError.invalidValue) {
            _ = try JSONEncoder().encode(selection)
        }
        #expect(throws: BighelpLinkWireError.invalidValue) {
            _ = try BighelpLinkPickerSelection(
                pickerID: selection.pickerID, sessionID: fixture.appID, kind: .model,
                provider: "native-provider", model: "new-model", value: nil, sentAt: 1_800_000_000
            )
        }
        let coordinate = try NativeSessionRuntimePickerCoordinate(#require(fixture.coordinate))
        #expect(throws: BighelpLinkWireError.invalidValue) {
            _ = try BighelpLinkPickerSelection(
                pickerID: selection.pickerID, sessionID: "different-session", kind: .model,
                provider: "native-provider", model: "new-model", value: nil, sentAt: 1_800_000_000,
                nativeCoordinate: coordinate
            )
        }
        let common: [String: Any] = [
            "version": 1, "pickerId": selection.pickerID, "sessionId": fixture.appID, "sentAt": 1_800_000_000
        ]
        let model = common.merging([
            "type": "picker.model", "currentModel": "old-model", "currentProvider": "native-provider",
            "providers": [["id": "native-provider", "name": "Native Provider", "isCurrent": true,
                           "isCustom": false, "models": ["old-model"]]]
        ]) { _, new in new }
        let choice = common.merging([
            "type": "picker.choice", "kind": "reasoning", "title": "Reasoning",
            "choices": [["value": "medium", "label": "Medium", "isCurrent": true]]
        ]) { _, new in new }
        let result = common.merging([
            "type": "picker.result", "kind": "model", "status": "completed", "message": "Complete"
        ]) { _, new in new }
        #expect(throws: BighelpLinkWireError.invalidValue) {
            _ = try JSONDecoder().decode(BighelpLinkModelPicker.self, from: JSONSerialization.data(withJSONObject: model))
        }
        #expect(throws: BighelpLinkWireError.invalidValue) {
            _ = try JSONDecoder().decode(BighelpLinkChoicePicker.self, from: JSONSerialization.data(withJSONObject: choice))
        }
        #expect(throws: BighelpLinkWireError.invalidValue) {
            _ = try JSONDecoder().decode(BighelpLinkPickerResult.self, from: JSONSerialization.data(withJSONObject: result))
        }
    }

    @Test func absentLiveMappingNeverCreatesOrFallsBackToProfileDefaults() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.coordinate = nil
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            _ = try await fixture.client().openPicker(fixture.open(.model))
        }
        #expect(fixture.calls.isEmpty)
    }

    @Test func mismatchedProfileOrDurableReceiptIsRejected() async throws {
        for field in ["profile_name", "stored_session_id"] {
            let fixture = try SessionControlWorkspace()
            fixture.invalidInfoField = field
            await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
                _ = try await fixture.client().openPicker(fixture.open(.model))
            }
            #expect(!fixture.calls.contains { $0.operation == .configSet })
        }
    }

    @Test func lazyOrMissingReasoningCannotMasqueradeAsAnActualSession() async throws {
        for lazy in [true, false] {
            let fixture = try SessionControlWorkspace()
            fixture.lazy = lazy
            fixture.reasoning = nil
            await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
                _ = try await fixture.client().openPicker(fixture.open(.reasoning))
            }
        }
    }

    @Test func explicitReasoningLevelsAreEditableAndAutomaticIsOnlyAReadRepresentation() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.reasoning = ""
        let client = fixture.client()
        let picker = try #require(try await client.openPicker(fixture.open(.reasoning)).choice)
        #expect(picker.choices.count == 9)
        #expect(picker.choices.first?.value == "reset")
        #expect(picker.choices.first?.isCurrent == true)
        #expect(client.selectionSupport(sessionID: fixture.appID, agentID: "studio").reasoningUnavailableReason == nil)
        let selection = try BighelpLinkPickerSelection(
            pickerID: picker.pickerID, sessionID: fixture.appID, kind: .reasoning,
            provider: nil, model: nil, value: "reset", sentAt: 1_800_000_000,
            nativeCoordinate: picker.nativeCoordinate
        )
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            _ = try await client.selectPicker(selection)
        }
        #expect(!fixture.calls.contains { $0.operation == .configSet })
    }

    @Test func nativeSelectionUsesProviderAndSessionFlagsAndRequiresActualReadback() async throws {
        let fixture = try SessionControlWorkspace()
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        let result = try await client.selectPicker(selection)
        #expect(result.status == .completed)
        let write = try #require(fixture.calls.first { $0.operation == .configSet })
        #expect(write.payload == [
            "profile": .string("studio"), "session_id": .string("runtime-chat"),
            "key": .string("model"), "value": .string("new-model --provider native-provider --session")
        ])
        #expect(!fixture.calls.contains { $0.operation == .sessionCreate || $0.operation == .agentDefaultsSet })
        #expect(try await client.selectPicker(selection).status == .expired)
    }

    @Test func modelChangePreservesExplicitSessionReasoningWhenHermesResolvesNewModelDefaults() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.reasoning = "high"
        fixture.resetReasoningOnModelChange = true
        let client = fixture.client()
        let selection = try await fixture.selection(client)

        let result = try await client.selectPicker(selection)

        #expect(result.status == .completed)
        #expect(fixture.reasoning == "high")
        #expect(fixture.calls.filter { $0.operation == .configSet }.compactMap { $0.payload["key"]?.string } == [
            "model", "reasoning"
        ])
        #expect(fixture.calls.filter { $0.operation == .configGet }.count == 1)
    }

    @Test func reopeningAfterModelMutationOnlyReadsAuthoritativeState() async throws {
        let fixture = try SessionControlWorkspace()
        let client = fixture.client()
        let selection = try await fixture.selection(client)

        _ = try await client.selectPicker(selection)
        let beforeReopen = fixture.calls.filter { $0.operation == .configSet }.count
        let reopened = try #require(try await client.openPicker(fixture.open(.model)).model)

        #expect(reopened.currentModel == "new-model")
        #expect(fixture.calls.filter { $0.operation == .configSet }.count == beforeReopen)
    }

    @Test func selectingTheAlreadyActiveModelIsReadOnlyAndDoesNotRepeatTheMutation() async throws {
        let fixture = try SessionControlWorkspace()
        let client = fixture.client()
        let picker = try #require(try await client.openPicker(fixture.open(.model)).model)
        let selection = try BighelpLinkPickerSelection(
            pickerID: picker.pickerID, sessionID: fixture.appID, kind: .model,
            provider: "native-provider", model: "old-model", value: nil,
            sentAt: 1_800_000_000, nativeCoordinate: picker.nativeCoordinate
        )

        let result = try await client.selectPicker(selection)

        #expect(result.status == .completed)
        #expect(fixture.calls.filter { $0.operation == .configSet }.isEmpty)
    }

    @Test func canonicalRuntimeProviderForAnAliasedCatalogSlugConfirmsTheSelection() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.runtimeProviderAlias = "canonical-provider"
        let client = fixture.client()
        let picker = try #require(try await client.openPicker(fixture.open(.model)).model)
        // The picker reports the catalog slug so the current tile is selected and an
        // unchanged model is not mistaken for a pending model change.
        #expect(picker.currentProvider == "native-provider")
        let selection = try BighelpLinkPickerSelection(
            pickerID: picker.pickerID, sessionID: fixture.appID, kind: .model,
            provider: "native-provider", model: "new-model", value: nil, sentAt: 1_800_000_000,
            nativeCoordinate: picker.nativeCoordinate
        )

        let result = try await client.selectPicker(selection)

        #expect(result.status == .completed)
        #expect(fixture.model == "new-model")
    }

    @Test func aliasedProviderIsNotConfirmedWhenTheCatalogDoesNotMarkItCurrent() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.runtimeProviderAlias = "canonical-provider"
        fixture.catalogMarksCurrent = false
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            _ = try await client.selectPicker(selection)
        }
    }

    @Test func optimisticStockValueWithoutMatchingActualPairIsNotCompleted() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.applyModel = false
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            _ = try await client.selectPicker(selection)
        }
    }

    @Test func deferredReceiptDoesNotBecomeAppliedSelection() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.deferModel = true
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        do {
            _ = try await client.selectPicker(selection)
            Issue.record("Expected a typed next-turn outcome")
        } catch let deferred as SessionRuntimeModelDeferred {
            #expect(deferred.selection == selection)
            #expect(deferred.coordinate == fixture.coordinate)
        }
        #expect(fixture.model == "old-model")
    }

    @Test func nativeConfirmationIsExplicitExactAndSingleUse() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.needsConfirmation = true
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        let confirmation = try await requiredConfirmation(client, selection)
        #expect(fixture.model == "old-model")
        #expect(fixture.calls.filter { $0.operation == .configSet }.count == 1)
        let result = try await client.confirmPicker(confirmation)
        #expect(result.status == .completed)
        #expect(fixture.calls.contains {
            $0.operation == .configSet && $0.payload["key"] == .string("model")
                && $0.payload["confirm_expensive_model"] == .boolean(true)
        })
        await #expect(throws: WorkspaceClientError.conflict) { _ = try await client.confirmPicker(confirmation) }
    }

    @Test func replacementOwnerRetiresAnIssuedConfirmation() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.needsConfirmation = true
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        let confirmation = try await requiredConfirmation(client, selection)
        fixture.owner = nil
        await #expect(throws: WorkspaceClientError.ownerChanged) { _ = try await client.confirmPicker(confirmation) }
        #expect(fixture.calls.filter { $0.operation == .configSet }.count == 1)
    }

    @Test func cancellingConfirmationRevokesItWithoutAnotherHostCall() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.needsConfirmation = true
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        let confirmation = try await requiredConfirmation(client, selection)
        client.cancelPickerConfirmation(confirmation)
        await #expect(throws: WorkspaceClientError.conflict) { _ = try await client.confirmPicker(confirmation) }
        #expect(fixture.calls.filter { $0.operation == .configSet }.count == 1)
        #expect(fixture.model == "old-model")
    }

    @Test func aNewPickerRetiresOldSelectionsAndConfirmations() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.needsConfirmation = true
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        let confirmation = try await requiredConfirmation(client, selection)
        _ = try await client.openPicker(fixture.open(.model))
        await #expect(throws: WorkspaceClientError.conflict) { _ = try await client.confirmPicker(confirmation) }
        #expect(try await client.selectPicker(selection).status == .expired)
    }

    @Test func retainedModelPickerCanRecoverAfterRuntimeControlClientReplacement() async throws {
        let fixture = try SessionControlWorkspace()
        let original = fixture.client()
        let replacement = fixture.client()
        let messaging = ReplacingSessionControlMessaging(client: original)
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: messaging,
            allowsAgentDefaults: false
        )

        await controls.loadModelPicker()
        #expect(controls.modelPicker != nil)
        messaging.client = replacement

        await controls.selectModel(providerID: "native-provider", modelID: "new-model")

        #expect(controls.errorMessage == nil)
        #expect(controls.currentModel == "new-model")
        #expect(fixture.calls.filter { $0.operation == .configSet }.compactMap {
            $0.payload["key"]?.string
        } == ["model", "reasoning"])
    }

    @Test func retainedReasoningPickerCanRecoverAfterRuntimeControlClientReplacement() async throws {
        let fixture = try SessionControlWorkspace()
        let original = fixture.client()
        let replacement = fixture.client()
        let messaging = ReplacingSessionControlMessaging(client: original)
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: messaging,
            allowsAgentDefaults: false
        )

        await controls.loadReasoningPicker()
        #expect(controls.reasoningPicker != nil)
        messaging.client = replacement

        await controls.selectReasoning(value: "high")

        #expect(controls.errorMessage == nil)
        #expect(controls.currentReasoningValue == "high")
        #expect(fixture.calls.filter { $0.operation == .configSet }.count == 1)
    }

    @Test func expiredModelRefreshRejectsAChoiceRemovedFromTheFreshCatalog() async throws {
        let fixture = try SessionControlWorkspace()
        let original = fixture.client()
        let replacement = fixture.client()
        let messaging = ReplacingSessionControlMessaging(client: original)
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: messaging,
            allowsAgentDefaults: false
        )

        await controls.loadModelPicker()
        fixture.models = ["old-model"]
        messaging.client = replacement

        await controls.selectModel(providerID: "native-provider", modelID: "new-model")

        #expect(controls.errorMessage == "That model is no longer available. Reopen the picker.")
        #expect(controls.currentModel == "old-model")
        #expect(fixture.calls.filter { $0.operation == .configSet }.isEmpty)
    }

    @Test func expiredModelRefreshStopsWhenTheOwnerBecomesUnavailable() async throws {
        let fixture = try SessionControlWorkspace()
        let original = fixture.client()
        let replacement = fixture.client()
        let messaging = ReplacingSessionControlMessaging(client: original)
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: messaging,
            allowsAgentDefaults: false
        )

        await controls.loadModelPicker()
        messaging.client = replacement
        messaging.afterSelection = { fixture.owner = nil }

        await controls.selectModel(providerID: "native-provider", modelID: "new-model")

        #expect(controls.errorMessage != nil)
        #expect(controls.currentModel == "old-model")
        #expect(fixture.calls.filter { $0.operation == .configSet }.isEmpty)
    }

    @Test func anExpiredRefreshRetriesSelectionOnlyOnce() async throws {
        let fixture = try SessionControlWorkspace()
        let client = fixture.client()
        let expiryClient = fixture.client()
        let messaging = ReplacingSessionControlMessaging(client: client)
        messaging.expiryClient = expiryClient
        messaging.forcedExpiredSelections = 2
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: messaging,
            allowsAgentDefaults: false
        )

        await controls.loadModelPicker()
        await controls.selectModel(providerID: "native-provider", modelID: "new-model")

        #expect(messaging.selections.count == 2)
        #expect(controls.errorMessage == "That model choice expired. Reopen the picker.")
        #expect(controls.currentModel == "old-model")
        #expect(fixture.calls.filter { $0.operation == .configSet }.isEmpty)
    }

    @Test func changedMappingDuringReadCannotPublishAnotherRuntime() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.retireMappingAfterOptions = true
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await fixture.client().openPicker(fixture.open(.model))
        }
    }

    @Test func parserFlagLikeCatalogTokensNeverReachConfigSet() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.models.append("--once")
        let client = fixture.client()
        let picker = try #require(try await client.openPicker(fixture.open(.model)).model)
        let selection = try BighelpLinkPickerSelection(
            pickerID: picker.pickerID, sessionID: fixture.appID, kind: .model,
            provider: "native-provider", model: "--once", value: nil, sentAt: 1_800_000_000,
            nativeCoordinate: picker.nativeCoordinate
        )
        await #expect(throws: WorkspaceClientError.invalidRequest) { _ = try await client.selectPicker(selection) }
        #expect(!fixture.calls.contains { $0.operation == .configSet })
    }

    @Test func currentModelNeverFallsBackAfterRuntimeReaping() async throws {
        let fixture = try SessionControlWorkspace()
        let client = fixture.client()
        let selection = try await fixture.selection(client)
        fixture.rejectModelAsMissing = true
        await #expect(throws: WorkspaceClientError.rejected(code: "4001")) {
            _ = try await client.selectPicker(selection)
        }
        #expect(fixture.model == "old-model")
        #expect(!fixture.calls.contains { $0.operation == .agentDefaultsSet || $0.operation == .profilesConfigure })
    }

    @Test func existingControlModelChangesReasoningForThisSessionAndConfirmsModelSeparately() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.needsConfirmation = true
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: fixture.client(),
            allowsAgentDefaults: false
        )
        await controls.loadPickersIfNeeded()
        #expect(controls.currentReasoningValue == "medium")
        await controls.selectReasoning(value: "high")
        #expect(controls.currentReasoningValue == "high")
        #expect(controls.errorMessage == nil)
        let reasoningWrite = try #require(fixture.calls.first { $0.operation == .configSet })
        #expect(reasoningWrite.payload["session_id"] == .string("runtime-chat"))
        #expect(reasoningWrite.payload["scope"] == .string("session"))
        controls.clearError()
        await controls.selectModel(providerID: "native-provider", modelID: "new-model")
        #expect(controls.pendingModelConfirmation != nil)
        #expect(controls.currentModel == "old-model")
        let confirmation = try #require(controls.pendingModelConfirmation)
        #expect(await controls.confirmModelSelection(confirmation))
        #expect(controls.currentModel == "new-model")
        #expect(controls.pendingModelConfirmation == nil)
    }

    @Test func existingControlModelDoesNotOptimisticallyApplyDeferredChoices() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.deferModel = true
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: fixture.client(),
            allowsAgentDefaults: false
        )
        await controls.loadPickersIfNeeded()
        await controls.selectModel(providerID: "native-provider", modelID: "new-model")
        #expect(controls.currentModel == "old-model")
        #expect(controls.statusMessage?.contains("queued") == true)
        #expect(controls.hasPendingSelection)
        #expect(!controls.isApplyingSelection)
        fixture.model = "new-model"
        await controls.loadModelPicker()
        #expect(controls.currentModel == "new-model")
        #expect(!controls.hasPendingSelection)
    }

    @Test func controlModelCannotConfirmAReplacementForTheDisplayedChallenge() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.needsConfirmation = true
        let controls = SessionRuntimeControlModel(
            sessionID: fixture.appID, agentID: "studio", messaging: fixture.client(),
            allowsAgentDefaults: false
        )
        await controls.loadPickersIfNeeded()
        await controls.selectModel(providerID: "native-provider", modelID: "new-model")
        let issued = try #require(controls.pendingModelConfirmation)
        let different = SessionRuntimeModelConfirmation(
            id: UUID(), selection: issued.selection, coordinate: issued.coordinate, message: issued.message
        )
        #expect(await controls.confirmModelSelection(different) == false)
        #expect(controls.currentModel == "old-model")
        #expect(fixture.calls.filter { $0.operation == .configSet }.count == 1)
        controls.cancelModelConfirmation(expected: issued)
        #expect(controls.pendingModelConfirmation == nil)
    }

    @Test func nativeUICatalogDoesNotTruncateAtLegacyWirePageSize() async throws {
        let fixture = try SessionControlWorkspace()
        fixture.models = (0..<75).map { "model-\($0)" } + ["old-model"]
        let picker = try #require(try await fixture.client().openPicker(fixture.open(.model)).model)
        #expect(picker.providers.first?.models.count == 76)
        #expect(picker.providers.first?.models.last == "old-model")
    }

    @Test func fastModeChangesOnlyTheVerifiedChatAndReadsBackTheSavedValue() async throws {
        let fixture = try fastFixture()
        let client = fixture.client()
        #expect(try await client.loadFastMode(sessionID: fixture.appID, agentID: "studio").mode == .off)
        #expect(try await client.setFastMode(.on, sessionID: fixture.appID, agentID: "studio").mode == .on)
        #expect(try await client.setFastMode(.off, sessionID: fixture.appID, agentID: "studio").mode == .off)
        let writes = fixture.calls.filter { $0.operation == .configSet }
        #expect(writes.count == 2)
        for write in writes {
            #expect(write.payload["profile"] == .string("studio"))
            #expect(write.payload["session_id"] == .string("runtime-chat"))
            #expect(write.payload["scope"] == .string("session"))
            #expect(write.payload["key"] == .string("fast"))
        }
        #expect(fixture.calls.filter { $0.operation == .configGet }.count == 2)
        #expect(fixture.model == "gpt-5.5")
        #expect(fixture.reasoning == "medium")
    }

    @Test func unsupportedRouteAndMissingHostFieldsNeverClaimFastModeIsEffective() async throws {
        for provider in ["openrouter", "custom:proxy", "openai"] {
            let fixture = try fastFixture()
            fixture.providerID = provider
            if provider == "openai" { fixture.fastValue = nil }
            let client = fixture.client()
            let state = try await client.loadFastMode(sessionID: fixture.appID, agentID: "studio")
            #expect(state.title == "Unavailable")
            #expect(state.unavailableReason != nil)
            await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
                _ = try await client.setFastMode(.on, sessionID: fixture.appID, agentID: "studio")
            }
            #expect(!fixture.calls.contains { $0.operation == .configSet })
        }
    }

    @Test func fastModeRejectsAnActiveTurnOrRetiredMappingBeforeMutation() async throws {
        for retire in [false, true] {
            let fixture = try fastFixture()
            fixture.running = !retire
            fixture.retireMappingAfterOptions = retire
            let client = fixture.client()
            await #expect(throws: (any Error).self) {
                _ = try await client.setFastMode(.on, sessionID: fixture.appID, agentID: "studio")
            }
            #expect(!fixture.calls.contains { $0.operation == .configSet })
        }
    }

    @Test func rejectedAndUncertainFastSavesNeverInventSuccessOrRetryTheWrite() async throws {
        for uncertain in [false, true] {
            let fixture = try fastFixture()
            fixture.rejectFast = !uncertain
            fixture.loseFastReceipt = uncertain
            let controls = SessionRuntimeControlModel(sessionID: fixture.appID, agentID: "studio", messaging: fixture.client())
            await controls.loadFastModeIfNeeded()
            await controls.selectFastMode(.on)
            #expect(controls.fastModeError != nil)
            #expect(controls.fastMode?.mode == (uncertain ? .on : .off))
            #expect(fixture.calls.filter { $0.operation == .configSet }.count == 1)
        }
    }

    @Test func newerHostFastModesRemainDistinctFromOffAndOldEventsCannotUndoAChoice() async throws {
        let fixture = try fastFixture()
        fixture.fastValue = "future-mode"
        let controls = SessionRuntimeControlModel(sessionID: fixture.appID, agentID: "studio", messaging: fixture.client())
        await controls.loadFastModeIfNeeded()
        #expect(controls.fastMode?.mode == FastMode("future-mode"))
        #expect(controls.fastMode?.title == "Set on host")
        await controls.selectFastMode(.on)
        controls.reconcileFastMode(.off, observedAt: .distantPast)
        #expect(controls.fastMode?.mode == .on)
    }

    private func fastFixture() throws -> SessionControlWorkspace {
        let fixture = try SessionControlWorkspace()
        fixture.providerID = "openai"
        fixture.model = "gpt-5.5"
        fixture.models = ["gpt-5.5"]
        fixture.fastValue = "normal"
        return fixture
    }

    private func requiredConfirmation(
        _ client: DirectHermesSessionControlClient, _ selection: BighelpLinkPickerSelection
    ) async throws -> SessionRuntimeModelConfirmation {
        do {
            _ = try await client.selectPicker(selection)
            throw WorkspaceClientError.invalidResponse
        } catch let required as SessionRuntimeModelConfirmationRequired {
            return required.confirmation
        }
    }
}

@MainActor
private final class ReplacingSessionControlMessaging: SessionRuntimeControlConfirming, SessionRuntimeControlSupporting {
    var client: DirectHermesSessionControlClient
    var expiryClient: DirectHermesSessionControlClient?
    var forcedExpiredSelections = 0
    var afterSelection: (@MainActor () -> Void)?
    private(set) var selections: [BighelpLinkPickerSelection] = []

    init(client: DirectHermesSessionControlClient) {
        self.client = client
    }

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        try await client.openPicker(request)
    }

    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        selections.append(selection)
        let result: BighelpLinkPickerResult
        if forcedExpiredSelections > 0, let expiryClient {
            forcedExpiredSelections -= 1
            result = try await expiryClient.selectPicker(selection)
        } else {
            result = try await client.selectPicker(selection)
        }
        afterSelection?()
        return result
    }

    func confirmPicker(_ confirmation: SessionRuntimeModelConfirmation) async throws -> BighelpLinkPickerResult {
        try await client.confirmPicker(confirmation)
    }

    func cancelPickerConfirmation(_ confirmation: SessionRuntimeModelConfirmation) {
        client.cancelPickerConfirmation(confirmation)
    }

    func selectionSupport(sessionID: String, agentID: String) -> SessionRuntimeControlSupport {
        client.selectionSupport(sessionID: sessionID, agentID: agentID)
    }

    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider] {
        client.cachedModelProviders(agentID: agentID)
    }
}

@MainActor
private final class SessionControlWorkspace: WorkspaceOperationPerforming {
    struct Call {
        let operation: WorkspaceOperation
        let payload: [String: BighelpJSONValue]
    }
    let originalOwner: WorkspaceOwner
    let appID: String
    var owner: WorkspaceOwner?
    var coordinate: WorkspaceSessionCoordinate?
    var calls: [Call] = []
    var model = "old-model"
    var providerID = "native-provider"
    var fastValue: String?
    var rejectFast = false
    var loseFastReceipt = false
    var running = false
    var models = ["old-model", "new-model"]
    var reasoning: String? = "medium"
    var lazy = false
    var invalidInfoField: String?
    var pendingInfoModel: String?
    var applyModel = true
    var deferModel = false
    var needsConfirmation = false
    var rejectModelAsMissing = false
    var retireMappingAfterOptions = false
    var resolveAnySession = false
    var yieldOnActivation = false
    var resetReasoningOnModelChange = false
    /// Canonical id the live runtime reports when the catalog lists an alias slug.
    var runtimeProviderAlias: String?
    var catalogMarksCurrent = true

    var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(owner: owner, values: [
            .modelsRead: .available, .sessionsRead: .available, .sessionModelEdit: .available,
            .reasoningEdit: .available
        ])
    }

    init(anchorID: String = "stored-chat") throws {
        originalOwner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://native.example.test",
                                                             providerID: "fixture-provider", userID: "fixture-user"),
                                       authenticationGeneration: UUID(), connectionGeneration: UUID())
        owner = originalOwner
        appID = try DirectHermesSessionIdentity.appID(owner: originalOwner, profileID: "studio", anchorID: anchorID)
        coordinate = try WorkspaceSessionCoordinate(
            owner: originalOwner, profileID: "studio", sessionID: appID,
            storedSessionID: "stored-chat", runtimeSessionID: "runtime-chat"
        )
    }

    func client(modelCache: DirectHermesModelCatalogCache = DirectHermesModelCatalogCache()) -> DirectHermesSessionControlClient {
        DirectHermesSessionControlClient(
            workspace: self, owner: originalOwner, currentOwner: { self.owner },
            resolveSession: { self.resolveAnySession || $0 == self.appID ? self.coordinate : nil },
            modelCache: modelCache
        )
    }

    func open(_ kind: BighelpLinkPickerKind, sessionID: String? = nil) -> BighelpLinkPickerOpenRequest {
        BighelpLinkPickerOpenRequest(requestID: "request-\(UUID().uuidString)",
                                   sessionID: sessionID ?? appID, agentID: "studio", kind: kind, sentAt: 1_800_000_000)
    }

    func selection(_ client: DirectHermesSessionControlClient) async throws -> BighelpLinkPickerSelection {
        let picker = try #require(try await client.openPicker(open(.model)).model)
        return try BighelpLinkPickerSelection(
            pickerID: picker.pickerID, sessionID: appID, kind: .model,
            provider: "native-provider", model: "new-model", value: nil, sentAt: 1_800_000_000,
            nativeCoordinate: picker.nativeCoordinate
        )
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard self.owner == owner else { throw WorkspaceClientError.ownerChanged }
        calls.append(Call(operation: operation, payload: payload))
        guard payload["session_id"] == .string("runtime-chat") else { throw WorkspaceClientError.invalidRequest }
        switch operation {
        case .sessionActivate:
            if yieldOnActivation { await Task.yield() }
            var info: [String: BighelpJSONValue] = [
                "stored_session_id": .string("stored-chat"), "profile_name": .string("studio"),
                "model": .string(pendingInfoModel ?? model), "provider": .string(runtimeProviderAlias ?? providerID),
                "system_prompt": .string("Synthetic private data must not enter picker models")
            ]
            if let reasoning { info["reasoning_effort"] = .string(reasoning) }
            if let fastValue { info["service_tier"] = .string(fastValue) }
            if lazy { info["lazy"] = .boolean(true) }
            if let invalidInfoField { info[invalidInfoField] = .string("wrong") }
            return [
                "session_id": .string("runtime-chat"), "session_key": .string("stored-chat"),
                "info": .object(info), "running": .boolean(running),
                "messages": .array([]), "messages_omitted": .boolean(true)
            ]
        case .modelOptions:
            if retireMappingAfterOptions { coordinate = nil }
            return [
                "model": .string(model), "provider": .string(providerID),
                "providers": .array([.object([
                    "slug": .string(providerID), "name": .string("Native Provider"),
                    "is_current": .boolean(catalogMarksCurrent), "is_user_defined": .boolean(false),
                    "models": .array(models.map(BighelpJSONValue.string)),
                    "capabilities": .object(Dictionary(uniqueKeysWithValues: models.map {
                        ($0, .object(["fast": .boolean(true)]))
                    }))
                ])])
            ]
        case .configGet:
            if payload["key"] == .string("fast"), let fastValue {
                return ["value": .string(FastMode(fastValue).value)]
            }
            guard payload["key"] == .string("reasoning"), let reasoning else { throw WorkspaceClientError.invalidResponse }
            return ["value": .string(reasoning), "display": .string("show")]
        case .configSet:
            if payload["key"] == .string("fast") {
                guard payload["scope"] == .string("session"), let value = payload["value"]?.string else {
                    throw WorkspaceClientError.invalidRequest
                }
                if rejectFast { throw WorkspaceClientError.rejected(code: nil) }
                fastValue = FastMode(value).value
                if loseFastReceipt { throw WorkspaceClientError.outcomeUnknown }
                return ["key": .string("fast"), "value": .string(fastValue!)]
            }
            if payload["key"] == .string("reasoning") {
                guard payload["scope"] == .string("session"), let value = payload["value"]?.string else { throw WorkspaceClientError.invalidRequest }
                reasoning = value
                return ["key": .string("reasoning"), "value": .string(value)]
            }
            guard payload["profile"] == .string("studio"), payload["key"] == .string("model"),
                  payload["value"] == .string("new-model --provider native-provider --session"),
                  payload["scope"] == nil else { throw WorkspaceClientError.invalidRequest }
            if rejectModelAsMissing { throw WorkspaceClientError.rejected(code: "4001") }
            let warning = needsConfirmation && payload["confirm_expensive_model"] != .boolean(true)
            if applyModel && !deferModel && !warning {
                model = "new-model"
                if resetReasoningOnModelChange { reasoning = "medium" }
            }
            return [
                "key": .string("model"), "value": .string("new-model"), "scope": .string("session"),
                "confirm_required": .boolean(warning),
                "confirm_message": .string(warning ? "This synthetic model has a different data policy. Confirm this choice." : ""),
                "deferred": .boolean(deferModel && !warning)
            ]
        default:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }
}
