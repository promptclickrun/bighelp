import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentEditorModel: Identifiable {
    enum Field: Hashable, Sendable {
        case name
        case role
        case summary
        case instructions
        case cloning
    }

    enum ValidationError: Swift.Error, Equatable {
        case requiredFields
        case saveInProgress
    }

    var draft: AgentDraft
    private(set) var fieldErrors: [Field: String] = [:]
    private(set) var avatarError: String?
    private(set) var saveError: String?
    private(set) var isSaving = false
    private(set) var hasUnconfirmedSave = false
    private(set) var pendingAvatar: PreparedAvatar?
    /// The avatar-creator look behind a pending companion avatar. Saving an
    /// agent with one also makes it that agent's animated chat companion.
    private(set) var selectedCompanionAppearance: CompanionAppearance?
    var selectedCompanionCharacter: CompanionCharacter? { selectedCompanionAppearance?.character }
    /// How Hermes Desktop should draw the pending avatar; saved alongside it.
    private(set) var pendingLook: AgentAvatarLook?
    /// Whether the last save put in a new avatar or removed it.
    private(set) var lastSaveChangedAvatar = false
    /// The petdex pet behind a pending pet avatar; its moves play in chats.
    private(set) var selectedPet: PetdexPet?

    let id = UUID()

    let store: AgentDirectoryStore
    let profileCloneSupport: AgentProfileCreationCloneSupport
    private let processor: AvatarImageProcessor
    private var editingID: String?
    private let avatarDirectory: URL?
    private var savedDraft: AgentDraft
    private let isCurrent: @MainActor () -> Bool

    private init(
        editingID: String?,
        draft: AgentDraft,
        store: AgentDirectoryStore,
        processor: AvatarImageProcessor,
        avatarDirectory: URL?,
        profileCloneSupport: AgentProfileCreationCloneSupport,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.editingID = editingID
        self.draft = draft
        savedDraft = draft
        self.store = store
        self.processor = processor
        self.avatarDirectory = avatarDirectory
        self.profileCloneSupport = profileCloneSupport
        self.isCurrent = isCurrent
    }

    static func creating(
        store: AgentDirectoryStore,
        processor: AvatarImageProcessor,
        avatarDirectory: URL? = nil,
        profileCloneSupport: AgentProfileCreationCloneSupport = .unavailable(
            "Native profile creation options are not available on this connection."
        ),
        template: SavedAgentTemplate? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> AgentEditorModel {
        var draft = AgentDraft(name: "", role: "", summary: "", instructions: "", avatarFileName: nil, isDefault: false)
        // New agents start as a copy of the default agent's setup (skills,
        // memories, settings) unless unchecked in Advanced. Name, role,
        // about and instructions still come from this editor.
        if profileCloneSupport.unavailableReason == nil {
            draft.cloneSourceProfileID = store.profiles.first(where: \.isDefault)?.id
        }
        let model = AgentEditorModel(
            editingID: nil,
            draft: draft,
            store: store,
            processor: processor,
            avatarDirectory: avatarDirectory ?? store.avatarDirectory,
            profileCloneSupport: profileCloneSupport,
            isCurrent: isCurrent
        )
        if let template { model.startFrom(template) }
        return model
    }

    static func editing(
        _ profile: AgentProfile,
        store: AgentDirectoryStore,
        processor: AvatarImageProcessor,
        avatarDirectory: URL? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> AgentEditorModel {
        AgentEditorModel(
            editingID: profile.id,
            draft: AgentDraft(
                name: profile.name,
                role: profile.role,
                summary: profile.summary,
                instructions: profile.instructions,
                avatarFileName: profile.avatarFileName,
                avatar: profile.avatar,
                isDefault: profile.isDefault
            ),
            store: store,
            processor: processor,
            avatarDirectory: avatarDirectory ?? store.avatarDirectory,
            profileCloneSupport: .unavailable("Profile cloning is available only while creating an agent."),
            isCurrent: isCurrent
        )
    }

    var isEditing: Bool { editingID != nil }
    /// The saved agent being edited, as the directory has it now.
    var editedProfile: AgentProfile? { editingID.flatMap { id in store.profiles.first { $0.id == id } } }
    var editingAgentID: String? { editingID }
    var isCurrentContext: Bool { isCurrent() }

    var hasUnsavedChanges: Bool {
        pendingAvatar != nil
            || draft.name != savedDraft.name
            || draft.role != savedDraft.role
            || draft.summary != savedDraft.summary
            || draft.instructions != savedDraft.instructions
            || draft.avatarFileName != savedDraft.avatarFileName
            || draft.avatar != savedDraft.avatar
            || draft.removesAvatar != savedDraft.removesAvatar
            || draft.isDefault != savedDraft.isDefault
            || draft.cloneSourceProfileID != savedDraft.cloneSourceProfileID
            || draft.skipBundledSkills != savedDraft.skipBundledSkills
    }

    var handlePreview: String {
        AgentHandle.unique(base: draft.name, excluding: editingID, profiles: store.profiles)
    }

    var cloneSources: [AgentProfile] {
        guard !isEditing else { return [] }
        return store.profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Display name of the agent this new one starts as a copy of.
    var cloneSourceName: String? {
        guard !isEditing, let id = draft.cloneSourceProfileID else { return nil }
        return store.profiles.first { $0.id == id }?.name
    }

    func selectCloneSource(_ profileID: String?) {
        draft.cloneSourceProfileID = profileID
        if profileID != nil { draft.skipBundledSkills = false }
    }

    func setSkipBundledSkills(_ enabled: Bool) {
        draft.skipBundledSkills = enabled
        if enabled { draft.cloneSourceProfileID = nil }
    }

    // MARK: Starting point

    /// Where a new agent starts: nothing, a built-in personality, or one of the person's saved templates.
    enum StartChoice: String, CaseIterable, Sendable {
        case scratch, builtIn, saved
    }

    /// The Start from choice showing in the studio.
    private(set) var startChoice: StartChoice = .scratch
    /// "builtin:<id>" or "saved:<uuid>", for the template applied now.
    private(set) var appliedTemplateID: String?
    /// The applied template's instructions with `{{agent_name}}` still in them.
    private var templateInstructions: String?
    /// What the applied template put in each field, so another choice replaces
    /// only those values and never what the person typed.
    private var applied = AppliedValues()

    private struct AppliedValues {
        var name = ""
        var role = ""
        var summary = ""
        var instructions = ""
        var avatar: AgentAvatar?
    }

    /// Shows a choice. From scratch clears what a template filled in; the others
    /// wait for a template to be picked.
    func showStartChoice(_ choice: StartChoice) {
        guard !isEditing else { return }
        startChoice = choice
        if choice == .scratch { apply(AppliedValues(), template: nil, id: nil) }
    }

    func startFrom(_ template: AgentSoulTemplate) {
        guard !isEditing, let soul = template.soul else { return }
        startChoice = .builtIn
        // A personality doesn't name the agent: the person's own name goes into it.
        apply(AppliedValues(role: template.profile, summary: template.about), template: soul,
              id: "builtin:\(template.id)")
    }

    func startFrom(_ template: SavedAgentTemplate) {
        guard !isEditing else { return }
        startChoice = .saved
        // Everything but a fresh, unused name, and the saved agent's own name
        // in its instructions becomes the new one's.
        let taken = Set(store.profiles.map { $0.name.lowercased() })
        var name = template.title
        var number = 2
        while taken.contains(name.lowercased()) { name = "\(template.title) \(number)"; number += 1 }
        apply(AppliedValues(name: name, role: template.role, summary: template.summary, avatar: template.avatar),
              template: AgentNamePlaceholder.generalize(template.instructions, name: template.sourceAgentName),
              id: "saved:\(template.id.uuidString)")
    }

    /// Keeps the applied template's instructions in step with the name as it's typed,
    /// until the person edits the instructions themselves.
    func nameDidChange() {
        guard let templateInstructions, draft.instructions == applied.instructions else { return }
        let filled = AgentNamePlaceholder.fill(templateInstructions, name: draft.name)
        draft.instructions = filled
        applied.instructions = filled
    }

    private func apply(_ next: AppliedValues, template: String?, id: String?) {
        var next = next
        func merged(_ current: String, previous: String, next: String) -> String {
            current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == previous ? next : current
        }
        draft.name = merged(draft.name, previous: applied.name, next: next.name)
        next.instructions = template.map { AgentNamePlaceholder.fill($0, name: draft.name) } ?? ""
        draft.role = merged(draft.role, previous: applied.role, next: next.role)
        draft.summary = merged(draft.summary, previous: applied.summary, next: next.summary)
        draft.instructions = merged(draft.instructions, previous: applied.instructions, next: next.instructions)
        if draft.avatar == applied.avatar, pendingAvatar == nil { draft.avatar = next.avatar }
        applied = next
        templateInstructions = template
        appliedTemplateID = id
        let filled: [(Field, String)] = [
            (.name, draft.name), (.role, draft.role), (.summary, draft.summary), (.instructions, draft.instructions)
        ]
        for (field, value) in filled where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[field] = nil
        }
    }

    var avatarURL: URL? {
        guard let avatarDirectory, let fileName = draft.avatarFileName, !fileName.isEmpty else {
            return nil
        }
        return avatarDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    func importAvatar(data: Data) async throws {
        try await prepareAvatar(data: data, companionAppearance: nil, look: .photo)
    }

    func importCompanionAvatar(data: Data, appearance: CompanionAppearance) async throws {
        try await prepareAvatar(data: data, companionAppearance: appearance, look: .photo)
    }

    /// A Hermes face or shape: its picture, plus the look Hermes Desktop draws.
    func importLookAvatar(data: Data, look: AgentAvatarLook) async throws {
        try await prepareAvatar(data: data, companionAppearance: nil, look: look)
    }

    /// A petdex pet: its first frame is the picture everyone sees.
    func importPetAvatar(data: Data, pet: PetdexPet) async throws {
        try await prepareAvatar(data: data, companionAppearance: nil, look: .photo)
        selectedPet = pet
    }

    /// Where the avatar creator opens: the avatar this agent has now. That's this
    /// visit's pick, else its saved character or pet (what chats draw first), its
    /// Hermes face or shape, or its picture. Only a new agent with nothing picked
    /// opens on `surprise`.
    func avatarCreatorStart(
        savedCharacter: CompanionAppearance?,
        savedPetSlug: String?,
        surprise: CompanionAppearance
    ) -> AvatarCreatorStart {
        if let pending = pendingAvatar {
            if let look = selectedCompanionAppearance { return .character(look) }
            if let pet = selectedPet { return .pet(slug: pet.slug, picture: pending.data) }
            if let look = pendingLook, look.style != .photo { return .look(look) }
            return .photo(pending.data)
        }
        guard isEditing else { return .surprise(surprise) }
        if draft.removesAvatar { return .photo(nil) }
        if let savedCharacter { return .character(savedCharacter) }
        let picture = avatarURL.flatMap { try? Data(contentsOf: $0) }
        if let savedPetSlug { return .pet(slug: savedPetSlug, picture: picture) }
        if let look = editedProfile?.look, look.style != .photo { return .look(look) }
        return .photo(picture)
    }

    /// The profile name a face follows: the agent's, or the one a new agent will get.
    var faceName: String {
        editingID ?? AgentProfileID.generated(from: draft.name, occupied: Set(store.profiles.map(\.id)))
    }

    private func prepareAvatar(
        data: Data,
        companionAppearance: CompanionAppearance?,
        look: AgentAvatarLook
    ) async throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        do {
            let preparedAvatar = try processor.prepare(data: data)
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            pendingAvatar = preparedAvatar
            selectedCompanionAppearance = companionAppearance
            selectedPet = nil
            pendingLook = look
            draft.removesAvatar = false
            avatarError = nil
        } catch let error as AvatarImageProcessor.Error {
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            avatarError = recoveryMessage(for: error)
            throw error
        }
    }

    func cancelAvatarSelection() async {
        pendingAvatar = nil
        selectedCompanionAppearance = nil
        selectedPet = nil
        pendingLook = nil
        avatarError = nil
    }

    func removeAvatar() {
        pendingAvatar = nil
        selectedCompanionAppearance = nil
        selectedPet = nil
        pendingLook = nil
        draft.avatarFileName = nil
        draft.avatar = nil
        draft.removesAvatar = true
        avatarError = nil
    }

    func reportAvatarLoadFailure() {
        guard isCurrent() else { return }
        avatarError = "We couldn’t read that photo. Choose a PNG, JPEG, or HEIF image and try again."
    }

    /// Chats draw the agent's saved character (or pet) ahead of its picture,
    /// so both follow the saved avatar: a new one replaces the old, and any
    /// other kind of avatar, or none, retires it.
    func applySavedLook(companions: CompanionStore, pets: PetAvatarStore, key: String) {
        if let look = selectedCompanionAppearance {
            companions.setOverride(look, for: key)
        } else if lastSaveChangedAvatar {
            companions.setOverride(nil, for: key)
        }
        if let pet = selectedPet {
            let store = store
            pets.assign(pet, to: key) { try await store.petSheet(pet) }
        } else if lastSaveChangedAvatar {
            pets.remove(key)
        }
    }

    func reportCompanionAvatarRenderFailure() {
        guard isCurrent() else { return }
        avatarError = "We couldn’t prepare that companion avatar. Choose it again or use a photo."
    }

    func save() async throws -> AgentProfile {
        guard !isSaving else { throw ValidationError.saveInProgress }
        guard !hasUnconfirmedSave else { throw WorkspaceClientError.outcomeUnknown }
        guard isCurrent() else {
            saveError = "The host connection changed. Your edits are still here. Reopen this agent before saving."
            throw CancellationError()
        }
        guard validate() else { throw ValidationError.requiredFields }
        isSaving = true
        saveError = nil
        let oldFileName = draft.avatarFileName
        let requestedAvatarRemoval = draft.removesAvatar
        let changesAvatar = pendingAvatar != nil || requestedAvatarRemoval
        lastSaveChangedAvatar = false
        var storedFileName: String?
        // Any `{{agent_name}}` still in the instructions gets the agent's name.
        draft.instructions = AgentNamePlaceholder.fill(draft.instructions, name: draft.name)
        var savedDraft = draft

        do {
            if let pendingAvatar {
                guard let avatarDirectory else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let fileName = try processor.store(pendingAvatar, in: avatarDirectory)
                storedFileName = fileName
                savedDraft.avatarFileName = fileName
                savedDraft.avatar = try AgentAvatar(preparedAvatar: pendingAvatar)
                savedDraft.look = pendingLook
                savedDraft.removesAvatar = false
            }
            let profile: AgentProfile
            if let editingID {
                profile = try await store.update(id: editingID, draft: savedDraft)
            } else {
                profile = try await store.create(savedDraft)
            }
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            editingID = profile.id
            adopt(profile, removesAvatar: false)
            lastSaveChangedAvatar = changesAvatar
            pendingAvatar = nil
            pendingLook = nil
            isSaving = false
            return profile
        } catch {
            if let storedFileName, let avatarDirectory {
                try? FileManager.default.removeItem(at: avatarDirectory.appending(path: storedFileName))
            }
            if !isCurrent() || error is CancellationError {
                saveError = "The host connection changed. This editor cannot confirm the save."
            } else if let partial = error as? AgentDirectoryPartialMutationError {
                editingID = partial.committedProfile.id
                adopt(
                    partial.committedProfile,
                    removesAvatar: requestedAvatarRemoval && partial.unappliedFields.contains(.avatar)
                )
                if partial.unappliedFields.contains(.name) { draft.name = savedDraft.name }
                if partial.unappliedFields.contains(.role) { draft.role = savedDraft.role }
                if partial.unappliedFields.contains(.summary) { draft.summary = savedDraft.summary }
                if partial.unappliedFields.contains(.instructions) { draft.instructions = savedDraft.instructions }
                hasUnconfirmedSave = partial.isOutcomeUncertain
                saveError = partial.isOutcomeUncertain
                    ? "The agent exists, but some changes could not be confirmed. Reopen it to review the current state before saving again."
                    : "The agent was saved, but some changes were not. Your remaining edits are still here, so you can try again."
            } else {
                draft.avatarFileName = oldFileName
                hasUnconfirmedSave = (error as? WorkspaceClientError) == .outcomeUnknown
                saveError = hasUnconfirmedSave
                    ? "Hermes may have saved this agent. Refresh Agents and review its current state before trying again."
                    : (error as? WorkspaceClientError)?.localizedDescription
                        ?? "We couldn’t save this agent. Your changes are still here, so you can try again."
            }
            isSaving = false
            throw error
        }
    }

    private func adopt(_ profile: AgentProfile, removesAvatar: Bool) {
        draft = AgentDraft(
            name: profile.name,
            role: profile.role,
            summary: profile.summary,
            instructions: profile.instructions,
            avatarFileName: profile.avatarFileName,
            avatar: profile.avatar,
            removesAvatar: removesAvatar,
            isDefault: profile.isDefault,
            cloneSourceProfileID: nil,
            skipBundledSkills: false
        )
        savedDraft = draft
        savedDraft.removesAvatar = false
    }

    private func validate() -> Bool {
        fieldErrors = [:]
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.name] = "Enter a display name."
        }
        if draft.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.role] = "Enter a role or title."
        }
        if draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.summary] = "Enter a vibe."
        }
        if draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.instructions] = "Enter instructions."
        }
        if draft.cloneSourceProfileID != nil || draft.skipBundledSkills,
           let reason = profileCloneSupport.unavailableReason {
            fieldErrors[.cloning] = reason
        } else if let source = draft.cloneSourceProfileID {
            if draft.skipBundledSkills {
                fieldErrors[.cloning] = "Cloning includes the source’s skills. Choose Start fresh to skip bundled skills."
            } else if !cloneSources.contains(where: { $0.id == source }) {
                fieldErrors[.cloning] = "That source agent is no longer available. Refresh Agents and choose again."
            }
        }
        return fieldErrors.isEmpty
    }

    private func recoveryMessage(for error: AvatarImageProcessor.Error) -> String {
        switch error {
        case .invalidData, .unsupportedFormat:
            "Choose a PNG, JPEG, or HEIF image and try again."
        case .sourceTooLarge, .outputTooLarge:
            "That image is still too large after preparation. Choose a smaller photo and try again."
        case .processingFailed:
            "We couldn’t prepare that image. Choose another photo and try again."
        }
    }
}

private extension AgentAvatar {
    init(preparedAvatar avatar: PreparedAvatar) throws {
        let mimeType: String
        switch avatar.fileExtension {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "webp":
            mimeType = "image/webp"
        default:
            throw AvatarImageProcessor.Error.unsupportedFormat
        }
        self.init(
            mimeType: mimeType,
            byteCount: avatar.data.count,
            sha256: BighelpLinkBase64URL.encode(Data(SHA256.hash(data: avatar.data))),
            dataURL: "data:\(mimeType);base64,\(avatar.data.base64EncodedString())"
        )
    }
}
