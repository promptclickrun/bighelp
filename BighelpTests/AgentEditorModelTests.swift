import Foundation
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct AgentEditorModelTests {
    @Test func unchangedDraftCanCloseAndSavedChangesBecomeTheNewBaseline() async throws {
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
            defaults: isolatedDefaults()
        )
        try await store.load()
        let model = AgentEditorModel.editing(.financeFixture, store: store, processor: AvatarImageProcessor())
        #expect(!model.hasUnsavedChanges)

        model.draft.name = "Finley Updated"
        #expect(model.hasUnsavedChanges)
        _ = try await model.save()
        #expect(!model.hasUnsavedChanges)
    }

    @Test func createdProfileIsAdoptedSoAnotherSaveCannotCreateADuplicate() async throws {
        let client = AgentDirectoryFixtureClient(profiles: [])
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults())
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
        model.draft = AgentDraft(
            name: "Garden Guide", role: "Gardening",
            summary: "Helps plan a garden.", instructions: "Give practical advice.",
            isDefault: false
        )

        let created = try await model.save()
        #expect(model.editingAgentID == created.id)
        #expect(!model.hasUnsavedChanges)
        model.draft.summary = "Plans a small garden."
        _ = try await model.save()
        #expect(store.profiles.count == 1)
        #expect(store.profiles.first?.summary == "Plans a small garden.")
    }

    @Test func editingCopiesTheHermesAvatarIntoTheDraft() throws {
        let avatar = AgentAvatar(
            mimeType: "image/png",
            byteCount: 8,
            sha256: "sha256-agent-avatar-0001",
            dataURL: "data:image/png;base64,iVBORw0KGgo="
        )
        let profile = AgentProfile(
            id: "finance",
            name: "Finley",
            role: "Finance agent",
            summary: "Tracks finances.",
            instructions: "Be precise.",
            avatarFileName: nil,
            avatar: avatar,
            isDefault: false
        )
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [profile]),
            defaults: isolatedDefaults()
        )

        let model = AgentEditorModel.editing(
            profile,
            store: store,
            processor: AvatarImageProcessor()
        )

        #expect(model.draft.avatar == avatar)
    }

    @Test func editingRetainsStableIdentityAndPublishesTheUpdatedProfile() async throws {
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.editing(.financeFixture, store: store, processor: AvatarImageProcessor())
        model.draft.name = "Finley Updated"

        let saved = try await model.save()

        #expect(saved.id == "finance")
        #expect(store.profiles.first(where: { $0.id == "finance" })?.name == "Finley Updated")
    }

    @Test func savePublishesPreparedAvatarBytesToRemoteDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpAgentEditorAvatarTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture])
        let store = AgentDirectoryStore(
            client: client,
            defaults: isolatedDefaults(),
            avatarDirectory: directory
        )
        try await store.load()
        let model = AgentEditorModel.editing(
            .financeFixture,
            store: store,
            processor: AvatarImageProcessor(),
            avatarDirectory: directory
        )
        let source = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }

        try await model.importAvatar(data: source)
        let saved = try await model.save()

        let avatar = try #require(saved.avatar)
        #expect(avatar.mimeType == "image/png")
        #expect(avatar.byteCount > 0)
        #expect(avatar.sha256.count >= 16)
        #expect(avatar.dataURL.hasPrefix("data:image/png;base64,"))
        #expect(saved.avatarFileName != nil)
    }

    @Test func createAvatarFailureTransitionsToUpdateAndRetainsThePendingAvatar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BighelpAgentEditorPartialCreateTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let committed = AgentProfile(
            id: "weather-guide",
            name: "Canonical Weather Guide",
            role: "Hermes forecast specialist",
            summary: "Canonical remote summary.",
            instructions: "Canonical remote SOUL.",
            avatarFileName: nil,
            isDefault: false
        )
        let client = PartiallyFailingCreateAgentDirectoryClient(committedProfile: committed)
        let store = AgentDirectoryStore(
            client: client,
            defaults: isolatedDefaults(),
            avatarDirectory: directory
        )
        let model = AgentEditorModel.creating(
            store: store,
            processor: AvatarImageProcessor(),
            avatarDirectory: directory
        )
        model.draft.name = "Weather Guide"
        model.draft.role = "Forecast specialist"
        model.draft.summary = "Tracks local conditions."
        model.draft.instructions = "Use the weather tool."
        let source = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        try await model.importAvatar(data: source)

        await #expect(throws: AgentDirectoryPartialMutationError.self) {
            _ = try await model.save()
        }

        #expect(model.isEditing)
        #expect(model.editingAgentID == "weather-guide")
        #expect(model.draft.name == "Canonical Weather Guide")
        #expect(model.draft.instructions == "Canonical remote SOUL.")
        #expect(model.pendingAvatar != nil)
        #expect(model.hasUnsavedChanges)
        #expect(model.saveError?.contains("bot was saved") == true)
        #expect(store.profiles == [committed])

        let saved = try await model.save()

        #expect(saved.id == "weather-guide")
        #expect(saved.avatar != nil)
        #expect(client.createCallCount == 1)
        #expect(client.updatedIDs == ["weather-guide"])
    }

    @Test func cancelledAvatarImportRetainsExistingAvatarWithoutRequestingDeletion() async throws {
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
            defaults: isolatedDefaults()
        )
        let model = AgentEditorModel.editing(.financeFixture, store: store, processor: AvatarImageProcessor())
        let source = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }

        try await model.importAvatar(data: source)

        await model.cancelAvatarSelection()

        #expect(model.draft.avatarFileName == AgentProfile.financeFixture.avatarFileName)
        #expect(model.draft.removesAvatar == false)
        #expect(model.pendingAvatar == nil)
        #expect(!model.hasUnsavedChanges)
    }

    @Test func removingExistingAvatarMarksAnExplicitHermesDeletion() async throws {
        let client = AgentDirectoryFixtureClient(profiles: [.financeFixture])
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.editing(
            .financeFixture,
            store: store,
            processor: AvatarImageProcessor()
        )

        model.removeAvatar()
        #expect(model.draft.removesAvatar)
        #expect(model.hasUnsavedChanges)
        let saved = try await model.save()

        #expect(saved.avatarFileName == nil)
        #expect(saved.avatar == nil)
        #expect(model.draft.removesAvatar == false)
    }

    @Test func blankRequiredFieldsExposeRecoverableInlineValidation() async {
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: []),
            defaults: isolatedDefaults()
        )
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())

        await #expect(throws: AgentEditorModel.ValidationError.self) {
            try await model.save()
        }

        #expect(model.fieldErrors[.name] == "Enter a display name.")
        #expect(model.fieldErrors[.role] == "Enter a role or title.")
    }
}

@MainActor
private final class PartiallyFailingCreateAgentDirectoryClient: AgentDirectoryClient {
    let committedProfile: AgentProfile
    private(set) var createCallCount = 0
    private(set) var updatedIDs: [String] = []

    init(committedProfile: AgentProfile) {
        self.committedProfile = committedProfile
    }

    func list() async throws -> [AgentProfile] { [] }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        createCallCount += 1
        throw AgentDirectoryPartialMutationError(committedProfile: committedProfile)
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        updatedIDs.append(id)
        return AgentProfile(
            id: id,
            name: draft.name,
            role: draft.role,
            summary: draft.summary,
            instructions: draft.instructions,
            avatarFileName: draft.avatarFileName,
            avatar: draft.avatar,
            isDefault: draft.isDefault
        )
    }
}
