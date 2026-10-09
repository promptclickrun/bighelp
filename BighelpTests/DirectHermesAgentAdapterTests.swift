import CryptoKit
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesAgentAdapterTests {
    @Test func unchangedDirectorySyncDoesNotReloadEveryProfileDetail() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let first = try await client.list()
        let second = try await client.list()
        #expect(first == second)
        #expect(workspace.calls.filter { $0.operation == .profilesSoulGet }.count == 1)
        #expect(workspace.calls.filter { $0.operation == .profilesList }.allSatisfy { $0.payload["include_sessions"] == .boolean(false) })
        workspace.rows["studio"]?["description"] = .string("Changed role")
        let changed = try await client.list()
        #expect(changed.first?.role == "Changed role")
        #expect(workspace.calls.filter { $0.operation == .profilesSoulGet }.count == 2)
    }

    @Test func directoryLoadsIndependentProfilesConcurrentlyInCatalogOrder() async throws {
        let workspace = try AgentNativeWorkspace()
        for id in ["alpha", "bravo", "charlie"] {
            workspace.rows[id] = workspace.rows["studio"]
            workspace.rows[id]?["name"] = .string(id)
        }
        workspace.measureSoulConcurrency = true
        let profiles = try await directory(workspace).list()
        #expect(profiles.map(\.id) == ["alpha", "bravo", "charlie", "studio"])
        #expect(workspace.maximumConcurrentSoulReads > 1)
        #expect(workspace.maximumConcurrentSoulReads <= 4)
    }

    @Test func directoryUsesNativePresentationAndCanonicalSessionWithoutScratchFallback() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profiles = try await client.list()
        #expect(profiles.first?.id == "studio")
        #expect(profiles.first?.name == "Studio Display")
        #expect(profiles.first?.role == "Planning")
        #expect(profiles.first?.summary == "A synthetic studio.")
        #expect(profiles.first?.instructions == "Exact instructions.\n")
        #expect(try client.canonicalSession(profileID: "studio") == .init(id: "canonical", resolvedID: "compressed-tip"))
        #expect(workspace.calls.first?.payload == ["include_sessions": .boolean(false)])
        #expect(workspace.calls.contains { $0.operation == .profilesSoulGet })
    }

    @Test func missingCanonicalSessionDoesNotSelectTheNewestScratchChat() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.rows["studio"]?["canonical_session"] = .null
        let client = directory(workspace)
        _ = try await client.list()
        #expect(try client.canonicalSession(profileID: "studio") == nil)
    }

    @Test func displayRenamePreservesNamespaceSiblingsAndUsesCAS() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        var draft = draft(profile)
        draft.name = "Renamed display"
        let saved = try await client.update(id: profile.id, draft: draft)
        #expect(saved.id == "studio")
        #expect(saved.name == "Renamed display")
        let call = try #require(workspace.calls.first { $0.operation == .profilesConfigure })
        #expect(call.payload["name"] == .string("studio"))
        #expect(call.payload["new_name"] == nil)
        #expect(call.payload["ui_meta_expected_revisions"] == .object(["hermes-bots": .integer(7)]))
        let meta = call.payload["ui_meta"]?.object?["hermes-bots"]?.object
        #expect(meta?["pinned"] == .boolean(true))
        #expect(meta?["groups"] == .array([.string("desktop-section")]))
    }

    /// Sections and hidden agents use Hermes Desktop's keys in the agent's
    /// `hermes-bots` display settings, written whole with its revision.
    @Test func listPlacementWritesDesktopKeysAndKeepsOtherSettings() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        _ = try await client.list()
        try await client.setPlacement(AgentListPlacement(sectionID: "sec-1", sectionName: "Work", isHidden: true),
                                      profileID: "studio")
        let call = try #require(workspace.calls.first { $0.operation == .profilesConfigure })
        #expect(call.payload["ui_meta_expected_revisions"] == .object(["hermes-bots": .integer(7)]))
        let meta = try #require(call.payload["ui_meta"]?.object?["hermes-bots"]?.object)
        #expect(meta["sectionId"] == .string("sec-1"))
        #expect(meta["sectionName"] == .string("Work"))
        #expect(meta["hidden"] == .boolean(true))
        #expect(meta["title"] == .string("Studio Display"))
        #expect(meta["pinned"] == .boolean(true))

        let listed = try #require(try await client.list().first)
        #expect(listed.placement == AgentListPlacement(sectionID: "sec-1", sectionName: "Work", isHidden: true))

        try await client.setPlacement(AgentListPlacement(), profileID: "studio")
        let cleared = try #require(workspace.calls.last { $0.operation == .profilesConfigure })
        let clearedMeta = try #require(cleared.payload["ui_meta"]?.object?["hermes-bots"]?.object)
        #expect(clearedMeta["sectionId"] == .null)
        #expect(clearedMeta["sectionName"] == .null)
        #expect(clearedMeta["hidden"] == .boolean(false))
    }

    /// Another device changed the agent meanwhile: read again, try once
    /// more, and keep what that device saved.
    @Test func listPlacementConflictReloadsAndRetriesOnce() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        _ = try await client.list()
        workspace.otherDeviceEditsOnce = true
        try await client.setPlacement(AgentListPlacement(isHidden: true), profileID: "studio")
        let configures = workspace.calls.filter { $0.operation == .profilesConfigure }
        #expect(configures.count == 2)
        #expect(configures.last?.payload["ui_meta_expected_revisions"] == .object(["hermes-bots": .integer(8)]))
        let meta = configures.last?.payload["ui_meta"]?.object?["hermes-bots"]?.object
        #expect(meta?["color"] == .string("teal"))
        #expect(meta?["hidden"] == .boolean(true))

        workspace.rejectMetadata = true
        await #expect(throws: WorkspaceClientError.conflict) {
            try await client.setPlacement(AgentListPlacement(isHidden: false), profileID: "studio")
        }
        #expect(workspace.calls.filter { $0.operation == .profilesConfigure }.count == 4)
    }

    /// A host too old to keep revisions can't save placements: "update Hermes".
    @Test func listPlacementNeedsAHostWithRevisions() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.rows["studio"]?["ui_meta_revisions"] = nil
        let client = directory(workspace)
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedHost)) {
            try await client.setPlacement(AgentListPlacement(isHidden: true), profileID: "studio")
        }
        #expect(!workspace.calls.contains { $0.operation == .profilesConfigure })
    }

    @Test func metadataConflictReportsOnlyUnappliedFieldsAfterReadback() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        var draft = draft(profile)
        draft.name = "New title"
        draft.role = "New role"
        workspace.rejectMetadata = true
        do {
            _ = try await client.update(id: profile.id, draft: draft)
            Issue.record("Expected a partial profile result")
        } catch let error as AgentDirectoryPartialMutationError {
            #expect(error.committedProfile.role == "New role")
            #expect(error.committedProfile.name == "Studio Display")
            #expect(error.unappliedFields == [.name])
            #expect(!error.isOutcomeUncertain)
        }
    }

    @Test func soulUpdatesUseAtomicNativeRouteAndExactReadback() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        var draft = draft(profile)
        draft.instructions = "Unicode preserved: 🌱\nSecond line.\n"
        let saved = try await client.update(id: profile.id, draft: draft)
        #expect(saved.instructions == draft.instructions)
        let write = try #require(workspace.calls.first { $0.operation == .profilesSoulSet })
        #expect(write.payload == ["profile": .string("studio"), "content": .string(draft.instructions)])
        #expect(!workspace.calls.contains { $0.operation == .profilesConfigure })
    }

    @Test func unreadableSoulCannotBecomeAnEmptySuccessfulProfile() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.failSoulRead = true
        await #expect(throws: WorkspaceClientError.transportUnavailable) {
            _ = try await directory(workspace).list()
        }
    }

    @Test func concurrentSoulEditIsDetectedBeforeWriting() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        var draft = draft(profile)
        draft.instructions = "My edit"
        workspace.souls["studio"] = "A newer host edit"
        await #expect(throws: WorkspaceClientError.conflict) {
            _ = try await client.update(id: profile.id, draft: draft)
        }
        #expect(!workspace.calls.contains { $0.operation == .profilesSoulSet })
    }

    @Test func avatarUploadAndRemovalAreConfirmedByNativeAssetReads() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        var draft = draft(profile)
        draft.avatar = workspace.image
        let saved = try await client.update(id: profile.id, draft: draft)
        #expect(saved.avatar == workspace.image)
        draft.avatar = nil
        draft.removesAvatar = true
        let cleared = try await client.update(id: profile.id, draft: draft)
        #expect(cleared.avatar == nil)
        #expect(workspace.calls.contains { $0.operation == .profilesSetAsset && $0.payload["clear"] == .boolean(true) })
    }

    @Test func faceAvatarAlsoTellsHermesDesktopHowToDrawIt() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        var draft = draft(profile)
        draft.avatar = workspace.image
        draft.look = AgentAvatarLook(style: .face, shape: "blobatar::sun", faceSeed: "studio")
        let saved = try await client.update(id: profile.id, draft: draft)
        #expect(saved.avatar == workspace.image)
        #expect(saved.look == AgentAvatarLook(style: .face, shape: "blobatar::sun"))
        let call = try #require(workspace.calls.first { $0.operation == .profilesConfigure })
        #expect(call.payload["ui_meta_expected_revisions"] == .object(["hermes-bots": .integer(7)]))
        let meta = try #require(call.payload["ui_meta"]?.object?["hermes-bots"]?.object)
        #expect(meta["shape"] == .string("blobatar::sun"))
        #expect(meta["imageKind"] == .string("shape"))
        #expect(meta["custom"] == .boolean(true))
        #expect(meta["image"] == nil)
        #expect(meta["title"] == .string("Studio Display"))
        #expect(meta["pinned"] == .boolean(true))
    }

    @Test func photoAvatarMarksAPictureAndKeepsDesktopsShape() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.rows["studio"]?["ui_meta"] = .object(["hermes-bots": .object([
            "title": .string("Studio Display"), "shape": .string("hexagon"), "color": .string("#2e3238")
        ])])
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        #expect(profile.look == AgentAvatarLook(style: .shape, shape: "hexagon", color: "#2e3238"))
        var draft = draft(profile)
        draft.avatar = workspace.image
        draft.look = .photo
        let saved = try await client.update(id: profile.id, draft: draft)
        #expect(saved.look == .photo)
        let meta = try #require(workspace.calls.first { $0.operation == .profilesConfigure }?
            .payload["ui_meta"]?.object?["hermes-bots"]?.object)
        #expect(meta["imageKind"] == .string("photo"))
        #expect(meta["shape"] == .string("hexagon"))
        #expect(meta["color"] == .string("#2e3238"))
    }

    @Test func aLookTheHostRefusesStillSavesThePicture() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try #require(try await client.list().first)
        var draft = draft(profile)
        draft.avatar = workspace.image
        draft.look = AgentAvatarLook(style: .shape, shape: "cloud", color: "hsl(30 68% 58%)")
        workspace.rejectMetadata = true
        let saved = try await client.update(id: profile.id, draft: draft)
        #expect(saved.avatar == workspace.image)
        #expect(saved.look == nil)
        // One fresh retry after a stale revision, then the picture stands alone.
        #expect(workspace.calls.filter { $0.operation == .profilesConfigure }.count == 2)
    }

    @Test func petsAndTheirFirstFramesComeFromTheHost() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.petRows = [
            .object(["slug": .string("boba"), "displayName": .string("Boba"), "installed": .boolean(true),
                     "spritesheetUrl": .string("https://assets.petdex.dev/curated/boba/sprite-v2.webp"),
                     "generated": .boolean(false), "futureKey": .integer(3)]),
            .object(["slug": .string("hatched"), "displayName": .string("Hatched"), "spritesheetUrl": .string("")]),
            .object(["slug": .string("elsewhere"), "spritesheetUrl": .string("https://cdn.example.com/sheet.webp")]),
            .object(["slug": .string("boba"), "displayName": .string("Second Boba")]),
            .object(["displayName": .string("No slug")]),
            .string("not a pet"),
        ]
        let client = directory(workspace)
        let pets = try await client.petGallery()
        #expect(pets.map(\.slug) == ["boba", "hatched", "elsewhere"])
        #expect(pets[0].installed && pets[0].curated)
        #expect(pets[1].spritesheetURL == nil)
        #expect(pets[2].displayName == "elsewhere")
        #expect(pets[2].spritesheetURL == nil, "Only petdex's own addresses are passed on")

        let frame = try await client.petThumbnail(pets[0])
        #expect(frame == PetdexFixtures.thumbnail(slug: "pip"))
        let thumb = try #require(workspace.calls.last { $0.operation == .petThumb })
        #expect(thumb.payload == ["slug": .string("boba"),
                                  "url": .string("https://assets.petdex.dev/curated/boba/sprite-v2.webp")])
        _ = try await client.petThumbnail(pets[1])
        #expect(workspace.calls.last { $0.operation == .petThumb }?.payload == ["slug": .string("hatched")])

        workspace.petThumbURI = "data:image/jpeg;base64,/9j/4AAQ"
        await #expect(throws: PetdexError.invalidImage) { _ = try await client.petThumbnail(pets[0]) }
        workspace.petThumbURI = nil
        await #expect(throws: PetdexError.unsupported) { _ = try await client.petThumbnail(pets[0]) }
    }

    @Test func freshCreateDoesNotMirrorCredentialsOrInstallAnAlias() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let profile = try await client.create(AgentDraft(
            name: "Garden Guide", role: "Garden planning", summary: "Practical ideas",
            instructions: "Keep exact trailing text.\n", isDefault: false
        ))
        #expect(profile.id == "garden-guide")
        #expect(profile.name == "Garden Guide")
        let create = try #require(workspace.calls.first { $0.operation == .profilesCreate })
        #expect(create.payload["mirror_credentials"] == .boolean(false))
        #expect(create.payload["no_alias"] == .boolean(true))
        #expect(create.payload["clone_from"] == nil)
        #expect(create.payload["soul"] == nil)
        #expect(workspace.calls.contains { $0.operation == .profilesSoulSet })
    }

    @Test func creationUsesLowercaseIDAndKeepsTypedDisplayName() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let displayName = "MiXeD Bot 🎸"
        let profile = try await client.create(AgentDraft(name: displayName, role: "Helper",
            summary: "Fixture", instructions: "Help.", isDefault: false))
        #expect(profile.id == "mixed-bot")
        #expect(profile.name == displayName)
        let create = try #require(workspace.calls.first { $0.operation == .profilesCreate })
        #expect(create.payload["name"] == .string("mixed-bot"))
        let renamed = try await client.update(id: profile.id, draft: AgentDraft(name: "LOUDER Name",
            role: "Helper", summary: "Fixture", instructions: "Help.", isDefault: false))
        #expect(renamed.id == profile.id)
        #expect(renamed.name == "LOUDER Name")
    }

    @Test func uncertainCreateCannotBeRepeatedByRetryingTheSameDraft() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.loseCreateReceipt = true
        let client = directory(workspace)
        let draft = AgentDraft(name: "Garden Guide", role: "Garden", summary: "Ideas", instructions: "Help.", isDefault: false)
        for _ in 0..<2 {
            await #expect(throws: WorkspaceClientError.outcomeUnknown) { _ = try await client.create(draft) }
        }
        #expect(workspace.calls.filter { $0.operation == .profilesCreate }.count == 1)
    }

    @Test func creationCannotMakeTheHostCatalogExceedTheSupportedBound() async throws {
        let workspace = try AgentNativeWorkspace()
        for index in 1..<DirectHermesAgentProfileService.maximumProfiles {
            let id = "profile-\(index)"
            workspace.rows[id] = [
                "name": .string(id), "is_default": .boolean(false),
                "has_avatar": .boolean(false), "ui_meta_revisions": .object([:])
            ]
        }
        let draft = AgentDraft(name: "Another agent", role: "Planning", summary: "Synthetic", instructions: "Help.", isDefault: false)
        await #expect(throws: WorkspaceClientError.capacityExceeded) {
            _ = try await directory(workspace).create(draft)
        }
        let owner = try #require(workspace.owner)
        let clone = DirectHermesAgentProfileCloneClient(workspace: workspace, owner: owner, currentOwner: { workspace.owner })
        await #expect(throws: WorkspaceClientError.capacityExceeded) {
            _ = try await clone.prepareClone(sourceProfileID: "studio", destinationProfileID: "copy", owner: owner)
        }
        #expect(!workspace.calls.contains { [.profilesCreate, .profilesClone].contains($0.operation) })
    }

    @Test func replacedOwnerCannotPublishDirectoryResults() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        workspace.replaceOwnerAfterSoul = true
        await #expect(throws: WorkspaceClientError.ownerChanged) { _ = try await client.list() }
    }

    @Test func nativeCreationOptionsForwardExactPayloadWithoutChangingSource() async throws {
        for source in [String?.none, String?.some("studio")] {
            for skip in [false, true] {
                if source != nil && skip { continue }
                let workspace = try AgentNativeWorkspace()
                let originalRow = workspace.rows["studio"]
                let originalSoul = workspace.souls["studio"]
                let client = directory(workspace)
                let profile = try await client.create(AgentDraft(
                    name: "New MiXeD Agent", role: "Helper", summary: "A distinct purpose",
                    instructions: "Keep my new purpose.\n", avatar: workspace.image,
                    isDefault: false, cloneSourceProfileID: source, skipBundledSkills: skip
                ))
                #expect(profile.id == "new-mixed-agent")
                #expect(profile.name == "New MiXeD Agent")
                #expect(profile.instructions == "Keep my new purpose.\n")
                #expect(profile.avatar == workspace.image)
                let calls = workspace.calls.filter { [.profilesCreate, .profilesClone].contains($0.operation) }
                #expect(calls.count == 1)
                let call = try #require(calls.first)
                #expect(call.operation == (source == nil ? .profilesCreate : .profilesClone))
                #expect(call.payload["no_skills"] == .boolean(skip))
                #expect(call.payload["clone_from"] == source.map(BighelpJSONValue.string))
                #expect(call.payload["clone_all"] == (source == nil ? nil : .boolean(false)))
                #expect(call.payload["mirror_credentials"] == .boolean(false))
                #expect(call.payload["no_alias"] == .boolean(true))
                #expect(call.payload["skip_bundled_skills"] == nil)
                #expect(workspace.rows["studio"] == originalRow)
                #expect(workspace.souls["studio"] == originalSoul)
                #expect(!workspace.calls.contains {
                    [.profilesConfigure, .profilesSoulSet, .profilesSetAsset].contains($0.operation)
                        && ($0.payload["name"] == .string("studio") || $0.payload["profile"] == .string("studio"))
                })
            }
        }
    }

    @Test func nativeCloneRejectsMissingSourceBeforeMutationAndNeverRetriesLostReceipt() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        var draft = AgentDraft(name: "New Agent", role: "Helper", summary: "Distinct",
            instructions: "New purpose", isDefault: false, cloneSourceProfileID: "missing", skipBundledSkills: false)
        await #expect(throws: WorkspaceClientError.invalidRequest) { _ = try await client.create(draft) }
        #expect(!workspace.calls.contains { [.profilesCreate, .profilesClone].contains($0.operation) })
        draft.cloneSourceProfileID = "studio"
        workspace.loseCreateReceipt = true
        for _ in 0..<2 {
            await #expect(throws: WorkspaceClientError.outcomeUnknown) { _ = try await client.create(draft) }
        }
        #expect(workspace.calls.filter { $0.operation == .profilesClone }.count == 1)
    }

    @Test func nativeCreationEditorRequiresNewNameAndClearsOptionsAfterSave() async throws {
        let workspace = try AgentNativeWorkspace()
        let store = AgentDirectoryStore(client: directory(workspace), defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor(),
            profileCloneSupport: .nativeBundleOnly)
        model.draft = AgentDraft(name: "", role: "Helper", summary: "Distinct",
            instructions: "New purpose", isDefault: false, cloneSourceProfileID: "studio", skipBundledSkills: false)
        await #expect(throws: AgentEditorModel.ValidationError.requiredFields) { _ = try await model.save() }
        #expect(model.fieldErrors[.name] != nil)
        #expect(!workspace.calls.contains { [.profilesCreate, .profilesClone].contains($0.operation) })
        model.draft.name = "New MiXeD Agent"
        let saved = try await model.save()
        #expect(saved.id == "new-mixed-agent")
        #expect(model.isEditing)
        #expect(model.draft.cloneSourceProfileID == nil)
        #expect(!model.draft.skipBundledSkills)
        #expect(!model.hasUnsavedChanges)
        model.draft.summary = "Updated purpose"
        _ = try await model.save()
        #expect(workspace.calls.filter { [.profilesCreate, .profilesClone].contains($0.operation) }.count == 1)
    }

    @Test func nativeSkipSkillsCanBeSelectedWithoutAnySource() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.rows = [:]
        let store = AgentDirectoryStore(client: directory(workspace), defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor(),
            profileCloneSupport: .nativeBundleOnly)
        model.draft = AgentDraft(name: "Fresh Agent", role: "Helper", summary: "Distinct",
            instructions: "New purpose", isDefault: false, skipBundledSkills: true)
        #expect(model.cloneSources.isEmpty)
        #expect(model.hasUnsavedChanges)
        _ = try await model.save()
        let call = try #require(workspace.calls.first { $0.operation == .profilesCreate })
        #expect(call.payload["no_skills"] == .boolean(true))
        #expect(call.payload["clone_from"] == nil)
    }

    @Test func nativeCloneAndSkipAreMutuallyExclusiveBeforeAnyMutation() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = directory(workspace)
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor(),
            profileCloneSupport: .nativeBundleOnly)
        model.setSkipBundledSkills(true)
        model.selectCloneSource("studio")
        #expect(!model.draft.skipBundledSkills)
        model.setSkipBundledSkills(true)
        #expect(model.draft.cloneSourceProfileID == nil)
        model.draft = AgentDraft(name: "New", role: "Helper", summary: "Distinct", instructions: "New purpose",
            isDefault: false, cloneSourceProfileID: "studio", skipBundledSkills: true)
        await #expect(throws: AgentEditorModel.ValidationError.requiredFields) { _ = try await model.save() }
        #expect(model.fieldErrors[.cloning] != nil)
        await #expect(throws: WorkspaceClientError.invalidRequest) { _ = try await client.create(model.draft) }
        #expect(!workspace.calls.contains { [.profilesCreate, .profilesClone].contains($0.operation) })
    }

    @Test func creationDraftDecodeDefaultsAndNativeOptionsRoundTrip() throws {
        let old = Data(#"{"name":"Fresh","role":"Helper","summary":"Distinct","instructions":"Help","isDefault":false}"#.utf8)
        var draft = try JSONDecoder().decode(AgentDraft.self, from: old)
        #expect(draft.cloneSourceProfileID == nil)
        #expect(!draft.skipBundledSkills)
        draft.cloneSourceProfileID = "studio"
        draft.skipBundledSkills = true
        #expect(try JSONDecoder().decode(AgentDraft.self, from: JSONEncoder().encode(draft)) == draft)
    }

    @Test func nativeCloneReviewsSensitiveScopeAndUsesOneExactCreate() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.avatars["studio"] = workspace.image
        workspace.rows["studio"]?["has_avatar"] = .boolean(true)
        let owner = try #require(workspace.owner)
        let client = DirectHermesAgentProfileCloneClient(workspace: workspace, owner: owner, currentOwner: { workspace.owner })
        let plan = try await client.prepareClone(sourceProfileID: "studio", destinationProfileID: "studio-copy", owner: owner)
        #expect(plan.includesCredentials && plan.includesMemory && plan.includesSkills && plan.includesAvatar)
        #expect(!plan.includesHistory)
        let result = try await client.clone(plan)
        #expect(result == .committed(.init(profileID: "studio-copy")))
        let call = try #require(workspace.calls.first { $0.operation == .profilesClone })
        #expect(call.payload["clone_all"] == .boolean(false))
        #expect(call.payload["mirror_credentials"] == .boolean(false))
        #expect(call.payload["no_alias"] == .boolean(true))
        #expect(call.payload["no_skills"] == nil)
        await #expect(throws: WorkspaceClientError.conflict) { _ = try await client.clone(plan) }
        #expect(workspace.calls.filter { $0.operation == .profilesClone }.count == 1)
    }

    @Test func lostNativeCloneReceiptIsUnconfirmedAndNeverRetried() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.loseCreateReceipt = true
        let owner = try #require(workspace.owner)
        let client = DirectHermesAgentProfileCloneClient(workspace: workspace, owner: owner, currentOwner: { workspace.owner })
        let plan = try await client.prepareClone(sourceProfileID: "studio", destinationProfileID: "copy", owner: owner)
        #expect(try await client.clone(plan) == .unconfirmed)
        await #expect(throws: WorkspaceClientError.conflict) { _ = try await client.clone(plan) }
    }

    @Test func runtimeDefaultsKeepNativeKeysAndScheduledReasoningInheritance() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = runtime(workspace)
        let catalog = try await client.loadCatalog(agentID: "studio")
        #expect(catalog.defaults.mainChats.providerID == "native-provider")
        #expect(catalog.defaults.subagents.reasoningEffort == "none")
        #expect(catalog.defaults.scheduledTasks.reasoningEffort == "")
        #expect(catalog.support.reasoningUnavailableReasons[.scheduledTasks] != nil)
        #expect(catalog.providers.first?.models == ["one", "two"])
        var changed = catalog.defaults
        changed.scheduledTasks.providerID = "native-provider"
        changed.scheduledTasks.modelID = "two"
        try await client.saveDefaults(changed, agentID: "studio")
        let call = try #require(workspace.calls.first { $0.operation == .agentDefaultsSet })
        #expect(call.payload["config"] == .object([
            "cron": .object(["model_provider": .string("native-provider"), "model": .string("two")])
        ]))
    }

    @Test func ignoredCronReasoningKeyIsRejectedWithoutMutation() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = runtime(workspace)
        var value = try await client.loadCatalog(agentID: "studio").defaults
        value.scheduledTasks.reasoningEffort = "high"
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.saveDefaults(value, agentID: "studio")
        }
        #expect(!workspace.calls.contains { $0.operation == .agentDefaultsSet })
    }

    @Test func automaticMainReasoningUsesTheScopedBlankLeafNotConfigSet() async throws {
        let workspace = try AgentNativeWorkspace()
        let client = runtime(workspace)
        var value = try await client.loadCatalog(agentID: "studio").defaults
        value.mainChats.reasoningEffort = ""
        try await client.saveDefaults(value, agentID: "studio")
        #expect(!workspace.calls.contains { $0.operation == .configSet })
        let write = try #require(workspace.calls.first { $0.operation == .agentDefaultsSet })
        #expect(write.payload["config"] == .object(["agent": .object(["reasoning_effort": .string("")])]))
    }

    @Test func nativeReasoningAliasesPreserveOffVersusAutomatic() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.config["agent"] = .object(["reasoning_effort": .string("disabled")])
        workspace.config["delegation"] = .object(["reasoning_effort": .boolean(true), "has_base_url_override": .boolean(false)])
        let value = try await runtime(workspace).loadDefaults(agentID: "studio")
        #expect(value.mainChats.reasoningEffort == "none")
        #expect(value.subagents.reasoningEffort == "")
    }

    @Test func profileEditorKeepsOnlyTheRejectedDraftFieldsAfterPartialSave() async throws {
        let workspace = try AgentNativeWorkspace()
        let store = AgentDirectoryStore(client: directory(workspace), defaults: isolatedDefaults())
        try await store.load()
        let profile = try #require(store.profiles.first)
        let model = AgentEditorModel.editing(profile, store: store, processor: AvatarImageProcessor())
        model.draft.name = "Wanted title"
        model.draft.role = "Saved role"
        workspace.rejectMetadata = true
        await #expect(throws: AgentDirectoryPartialMutationError.self) { _ = try await model.save() }
        #expect(model.draft.name == "Wanted title")
        #expect(model.draft.role == "Saved role")
        #expect(store.profiles.first?.name == "Studio Display")
        #expect(store.profiles.first?.role == "Saved role")
        #expect(model.hasUnsavedChanges)
    }

    @Test func subagentEndpointOverrideIsPreservedAndExplained() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.config["delegation"] = .object(["has_base_url_override": .boolean(true)])
        let client = runtime(workspace)
        let catalog = try await client.loadCatalog(agentID: "studio")
        #expect(catalog.support.modelUnavailableReasons[.subagents] != nil)
        var desired = catalog.defaults
        desired.subagents.providerID = "native-provider"
        desired.subagents.modelID = "two"
        await #expect(throws: WorkspaceClientError.unavailable(.policyRestricted)) {
            try await client.saveDefaults(desired, agentID: "studio")
        }
    }

    @Test func modelWarningRequiresExactConsentBeforeAnySiblingWrites() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.warnBeforeModelChange = true
        let client = runtime(workspace)
        var desired = try await client.loadCatalog(agentID: "studio").defaults
        desired.mainChats.modelID = "two"
        desired.mainChats.reasoningEffort = "high"
        let token: AgentRuntimeDefaultsSaveConfirmation
        do {
            try await client.saveDefaults(desired, agentID: "studio")
            Issue.record("Expected explicit model confirmation")
            return
        } catch let required as AgentRuntimeDefaultsConfirmationRequired {
            token = required.confirmation
        }
        #expect(!workspace.calls.contains { $0.operation == .configSet })
        try await client.saveDefaults(desired, agentID: "studio", confirmation: token)
        #expect(workspace.mainModel == "two")
        #expect(workspace.config["agent"]?.object?["reasoning_effort"] == .string("high"))
        let write = try #require(workspace.calls.last { $0.operation == .profilesConfigure })
        #expect(Set(write.payload.keys) == ["name", "model", "provider", "confirm_expensive_model"])
        await #expect(throws: WorkspaceClientError.conflict) {
            try await client.saveDefaults(desired, agentID: "studio", confirmation: token)
        }
    }

    private func directory(_ workspace: AgentNativeWorkspace) -> DirectHermesAgentDirectoryClient {
        DirectHermesAgentDirectoryClient(workspace: workspace, owner: workspace.initialOwner, currentOwner: { workspace.owner })
    }

    @Test func fastDefaultIsSavedForOneProfileWithoutChangingModelOrReasoning() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.mainProvider = "openai"
        workspace.mainModel = "gpt-5.5"
        workspace.availableModels = ["gpt-5.5"]
        let client = runtime(workspace)
        var desired = try await client.loadCatalog(agentID: "studio").defaults
        #expect(desired.mainChats.fastMode == .off)
        desired.mainChats.fastMode = .on
        try await client.saveDefaults(desired, agentID: "studio")
        #expect(try await client.loadDefaults(agentID: "studio") == desired)
        let writes = workspace.calls.filter { $0.operation == .configSet }
        #expect(writes.count == 1)
        #expect(writes.first?.payload == ["profile": .string("studio"), "key": .string("fast"),
                                         "value": .string("fast"), "scope": .string("global")])
        #expect(workspace.config["agent"]?.object?["reasoning_effort"] == .string("medium"))
        #expect(workspace.mainModel == "gpt-5.5")
    }

    @Test func fastDefaultRejectsAggregatorsAndKeepsUnknownHostModesWhenSavingReasoning() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.mainProvider = "openrouter"
        workspace.mainModel = "gpt-5.5"
        workspace.availableModels = ["gpt-5.5"]
        workspace.config["agent"] = .object(["reasoning_effort": .string("medium"), "service_tier": .string("future-mode")])
        let client = runtime(workspace)
        var desired = try await client.loadCatalog(agentID: "studio").defaults
        #expect(desired.mainChats.fastMode == FastMode("future-mode"))
        desired.mainChats.fastMode = .on
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.saveDefaults(desired, agentID: "studio")
        }
        #expect(!workspace.calls.contains { $0.operation == .configSet })
        desired.mainChats.fastMode = FastMode("future-mode")
        desired.mainChats.reasoningEffort = "high"
        try await client.saveDefaults(desired, agentID: "studio")
        #expect(workspace.config["agent"]?.object?["service_tier"] == .string("future-mode"))
        #expect(!workspace.calls.contains { $0.payload["key"] == .string("fast") })
    }

    @Test func speedOnlySaveKeepsReasoningChangedElsewhereOnTheModelsPage() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.mainProvider = "openai"
        workspace.mainModel = "gpt-5.5"
        workspace.availableModels = ["gpt-5.5"]
        let client = runtime(workspace)
        let editor = AgentRuntimeDefaultsEditorModel(agentID: "studio", client: client)
        await editor.load()
        var changed = try await client.loadDefaults(agentID: "studio")
        changed.mainChats.reasoningEffort = "high"
        try await client.saveDefaults(changed, agentID: "studio")
        await editor.saveFastMode(.on)
        #expect(editor.errorMessage == nil)
        #expect(editor.draft.mainChats.reasoningEffort == "high")
        #expect(workspace.config["agent"]?.object?["reasoning_effort"] == .string("high"))
        #expect(workspace.calls.filter { $0.payload["key"] == .string("reasoning") }.count == 1)
    }

    @Test func uncertainFastDefaultSaveReportsWhatWasActuallyCommitted() async throws {
        let workspace = try AgentNativeWorkspace()
        workspace.mainProvider = "openai"
        workspace.mainModel = "gpt-5.5"
        workspace.availableModels = ["gpt-5.5"]
        workspace.loseFastReceipt = true
        let editor = AgentRuntimeDefaultsEditorModel(agentID: "studio", client: runtime(workspace))
        await editor.load()
        editor.selectFastMode(.on)
        await #expect(throws: AgentRuntimeDefaultsPartialSaveError.self) { try await editor.saveIfNeeded() }
        #expect(editor.draft.mainChats.fastMode == .on)
        #expect(!editor.isDirty)
        #expect(editor.errorMessage != nil)
        #expect(workspace.calls.filter { $0.payload["key"] == .string("fast") }.count == 1)
    }

    private func runtime(_ workspace: AgentNativeWorkspace) -> DirectHermesAgentRuntimeDefaultsClient {
        DirectHermesAgentRuntimeDefaultsClient(workspace: workspace, owner: workspace.initialOwner, currentOwner: { workspace.owner })
    }

    private func draft(_ profile: AgentProfile) -> AgentDraft {
        AgentDraft(name: profile.name, role: profile.role, summary: profile.summary,
                   instructions: profile.instructions, avatar: profile.avatar, isDefault: profile.isDefault)
    }
}

@MainActor
private final class AgentNativeWorkspace: WorkspaceOperationPerforming {
    struct Call {
        let operation: WorkspaceOperation
        let payload: [String: BighelpJSONValue]
    }

    let initialOwner: WorkspaceOwner
    var owner: WorkspaceOwner?
    var calls: [Call] = []
    var rows: [String: [String: BighelpJSONValue]]
    var souls: [String: String] = ["studio": "Exact instructions.\n"]
    var avatars: [String: AgentAvatar] = [:]
    var rejectMetadata = false
    var petRows: [BighelpJSONValue] = []
    var petThumbURI: String? = "data:image/png;base64," + (PetdexFixtures.thumbnail(slug: "pip")?.base64EncodedString() ?? "")
    /// Another device saves the agent's display settings just before the next configure.
    var otherDeviceEditsOnce = false
    var failSoulRead = false
    var measureSoulConcurrency = false
    var concurrentSoulReads = 0
    var maximumConcurrentSoulReads = 0
    var loseCreateReceipt = false
    var replaceOwnerAfterSoul = false
    var warnBeforeModelChange = false
    var mainModel = "one"
    var mainProvider = "native-provider"
    var availableModels = ["one", "two", "unavailable"]
    var loseFastReceipt = false
    var config: [String: BighelpJSONValue] = [
        "agent": .object(["reasoning_effort": .string("medium")]),
        "delegation": .object(["reasoning_effort": .boolean(false), "has_base_url_override": .boolean(false)]),
        "cron": .object([:])
    ]

    var capabilities: WorkspaceCapabilities {
        WorkspaceCapabilities(owner: owner, values: Dictionary(
            uniqueKeysWithValues: WorkspaceCapability.allCases.map { ($0, .available) }
        ))
    }

    init() throws {
        initialOwner = WorkspaceOwner(authority: try .fixture(id: "native-agent-adapters"),
                                      authenticationGeneration: UUID(), connectionGeneration: UUID())
        owner = initialOwner
        rows = ["studio": [
            "name": .string("studio"), "description": .string("Planning"),
            "display_name": .string("Ignored fallback"), "is_default": .boolean(false), "has_avatar": .boolean(false),
            "ui_meta": .object(["hermes-bots": .object([
                "title": .string("Studio Display"), "description": .string("A synthetic studio."),
                "pinned": .boolean(true), "groups": .array([.string("desktop-section")])
            ])]),
            "ui_meta_revisions": .object(["hermes-bots": .integer(7)]),
            "canonical_session": .object(["id": .string("canonical"), "resolved_id": .string("compressed-tip")]),
            "last_session": .object(["id": .string("newest-scratch")]),
            "path": .string("/synthetic/path-not-for-presentation")
        ]]
    }

    var image: AgentAvatar {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let data = Data(base64Encoded: encoded)!
        return AgentAvatar(mimeType: "image/png", byteCount: data.count,
                           sha256: BighelpLinkBase64URL.encode(Data(SHA256.hash(data: data))),
                           dataURL: "data:image/png;base64,\(encoded)")
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard self.owner == owner else { throw WorkspaceClientError.ownerChanged }
        calls.append(Call(operation: operation, payload: payload))
        let id = payload["name"]?.string ?? payload["profile"]?.string ?? "studio"
        switch operation {
        case .profilesList:
            return ["profiles": .array(rows.keys.sorted().compactMap { rows[$0].map(BighelpJSONValue.object) })]
        case .profilesSoulGet:
            if measureSoulConcurrency {
                concurrentSoulReads += 1
                maximumConcurrentSoulReads = max(maximumConcurrentSoulReads, concurrentSoulReads)
                try await Task.sleep(for: .milliseconds(30))
                concurrentSoulReads -= 1
            }
            if failSoulRead { throw WorkspaceClientError.transportUnavailable }
            if replaceOwnerAfterSoul { self.owner = nil }
            return ["content": .string(souls[id] ?? ""), "exists": .boolean(souls[id] != nil)]
        case .profilesSoulSet:
            souls[id] = payload["content"]?.string
            return ["ok": .boolean(true)]
        case .profilesGetAsset:
            guard let avatar = avatars[id] else { return ["found": .boolean(false)] }
            return ["found": .boolean(true), "mime": .string(avatar.mimeType),
                    "size": .integer(avatar.byteCount), "data": .string(avatar.dataURL)]
        case .profilesSetAsset:
            if payload["clear"] == .boolean(true) { avatars[id] = nil }
            else {
                guard payload["data"] == .string(image.dataURL) else { throw WorkspaceClientError.invalidRequest }
                avatars[id] = image
            }
            rows[id]?["has_avatar"] = .boolean(avatars[id] != nil)
            return ["ok": .boolean(true), "asset": .string("avatar"), "size": .integer(avatars[id]?.byteCount ?? 0)]
        case .profilesCreate, .profilesClone:
            guard rows[id] == nil else { throw WorkspaceClientError.conflict }
            rows[id] = [
                "name": .string(id), "description": payload["description"] ?? .string(""),
                "is_default": .boolean(false), "has_avatar": .boolean(false), "ui_meta_revisions": .object([:])
            ]
            souls[id] = (payload["clone_from"]?.string).flatMap { souls[$0] } ?? payload["soul"]?.string ?? ""
            if loseCreateReceipt { throw WorkspaceClientError.transportUnavailable }
            return ["ok": .boolean(true), "name": .string(id), "soul_written": .boolean(true),
                    "model_set": .boolean(false), "mirrored": .object([
                        "env": .boolean(false), "auth": .boolean(false),
                        "voice": .boolean(false), "model_inherited": .boolean(false)
                    ])]
        case .profilesConfigure:
            var applied: [String: BighelpJSONValue] = [:]
            if otherDeviceEditsOnce, var namespace = rows[id]?["ui_meta"]?.object?["hermes-bots"]?.object {
                otherDeviceEditsOnce = false
                namespace["color"] = .string("teal")
                let revision = rows[id]?["ui_meta_revisions"]?.object?["hermes-bots"]?.integer ?? 0
                rows[id]?["ui_meta"] = .object(["hermes-bots": .object(namespace)])
                rows[id]?["ui_meta_revisions"] = .object(["hermes-bots": .integer(revision + 1)])
            }
            if let incoming = payload["ui_meta"]?.object?["hermes-bots"] {
                let revision = rows[id]?["ui_meta_revisions"]?.object?["hermes-bots"]?.integer ?? 0
                if rejectMetadata || payload["ui_meta_expected_revisions"]?.object?["hermes-bots"] != .integer(revision) {
                    applied["ui_meta"] = .boolean(false)
                    applied["ui_meta_conflicts"] = .object(["hermes-bots": .object(["actual": .integer(revision)])])
                } else {
                    rows[id]?["ui_meta"] = .object(["hermes-bots": incoming])
                    rows[id]?["ui_meta_revisions"] = .object(["hermes-bots": .integer(revision + 1)])
                    applied["ui_meta"] = .boolean(true)
                    applied["ui_meta_revisions"] = .object(["hermes-bots": .integer(revision + 1)])
                }
            }
            if let description = payload["description"] { rows[id]?["description"] = description; applied["description"] = .boolean(true) }
            if let model = payload["model"]?.string {
                if warnBeforeModelChange, payload["confirm_expensive_model"] != .boolean(true) {
                    return ["ok": .boolean(true), "applied": .object(applied),
                            "confirm_required": .boolean(true), "confirm_message": .string("This synthetic model may cost more.")]
                }
                mainModel = model
                applied["model"] = .boolean(true)
            }
            return ["ok": .boolean(true), "applied": .object(applied)]
        case .petGallery:
            return ["enabled": .boolean(false), "active": .string(""), "pets": .array(petRows)]
        case .petThumb:
            guard let uri = petThumbURI else { return ["ok": .boolean(false), "slug": payload["slug"] ?? .null] }
            return ["ok": .boolean(true), "slug": payload["slug"] ?? .null, "dataUri": .string(uri)]
        case .profilesDescribe:
            return ["name": .string(id), "model": .object(["provider": .string(mainProvider), "default": .string(mainModel)])]
        case .modelOptions:
            return ["providers": .array([.object([
                "slug": .string(mainProvider), "name": .string("Native Provider"),
                "is_current": .boolean(true), "is_user_defined": .boolean(false),
                "models": .array(availableModels.map(BighelpJSONValue.string)),
                "capabilities": .object(Dictionary(uniqueKeysWithValues: availableModels.map {
                    ($0, .object(["fast": .boolean(true)]))
                })),
                "unavailable_models": .array([.string("unavailable")])
            ])]), "model": .string(mainModel), "provider": .string("native-provider")]
        case .agentDefaultsGet:
            return config
        case .agentDefaultsSet:
            guard let changes = payload["config"]?.object else { throw WorkspaceClientError.invalidRequest }
            for (section, value) in changes {
                var merged = config[section]?.object ?? [:]
                for (key, value) in value.object ?? [:] { merged[key] = value }
                config[section] = .object(merged)
            }
            return ["ok": .boolean(true)]
        case .configSet:
            guard let key = payload["key"]?.string, ["reasoning", "fast"].contains(key),
                  payload["scope"] == .string("global"), payload["session_id"] == nil,
                  let value = payload["value"] else { throw WorkspaceClientError.invalidRequest }
            var agent = config["agent"]?.object ?? [:]
            agent[key == "fast" ? "service_tier" : "reasoning_effort"] = value
            config["agent"] = .object(agent)
            if key == "fast", loseFastReceipt { throw WorkspaceClientError.outcomeUnknown }
            return ["key": .string(key), "value": value]
        default:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }
}
