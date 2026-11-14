import Foundation
import Observation

@MainActor
@Observable
final class SkillsAndToolsStore {
    private let client: any HermesSkillsAndToolsCatalogClient
    private(set) var catalog: HermesSkillsAndToolsCatalog?
    private(set) var document: HermesSkillDocument?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private var loadGeneration = 0
    private var accountGeneration = 0
    private var documentGeneration = 0
    private var documentMutationSequence: UInt64 = 0
    private var currentAgentID: String?
    private var controlGeneration = 0
    private(set) var capabilityControl: HermesCapabilityControl?
    private(set) var isLoadingControl = false
    private(set) var isChangingCapability = false
    private(set) var statusMessage: String?

    var compatibilityMessage: String? {
        guard let catalog else { return nil }
        guard let management = catalog.management else {
            return HermesCapabilityCompatibilityError.updateRequired.localizedDescription
        }
        if !management.canRead || !management.canCreate || !management.canUpdate || !management.canImport {
            return catalog.toolsNotice.isEmpty ? "Some capability actions are unavailable on this computer." : catalog.toolsNotice
        }
        return nil
    }

    func loadControl(kind: HermesCapabilityKind, id: String, agentID: String) async {
        guard !Task.isCancelled else { return }
        activateAgent(agentID)
        controlGeneration += 1
        let generation = controlGeneration
        let account = accountGeneration
        capabilityControl = nil
        statusMessage = nil
        isLoadingControl = true
        defer { if generation == controlGeneration { isLoadingControl = false } }
        do {
            guard catalog?.management != nil else { throw HermesCapabilityCompatibilityError.updateRequired }
            let control = try await client.control(kind: kind, id: id, agentID: agentID)
            guard generation == controlGeneration, account == accountGeneration,
                  currentAgentID == agentID, !Task.isCancelled else { return }
            capabilityControl = control
            errorMessage = nil
        } catch {
            guard generation == controlGeneration, account == accountGeneration,
                  currentAgentID == agentID, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, confirmedControl: HermesCapabilityControl) async {
        guard !isChangingCapability, !isSaving,
              capabilityControl == confirmedControl,
              currentAgentID == confirmedControl.agentID,
              confirmedControl.canToggle else {
            errorMessage = "Capability state changed. Refresh and confirm again."
            return
        }
        let generation = controlGeneration
        let account = accountGeneration
        isChangingCapability = true
        statusMessage = nil
        defer {
            if generation == controlGeneration, account == accountGeneration {
                isChangingCapability = false
            }
        }
        do {
            let verified = try await client.setEnabled(enabled, control: confirmedControl)
            guard generation == controlGeneration, account == accountGeneration,
                  currentAgentID == confirmedControl.agentID else { return }
            capabilityControl = verified
            statusMessage = "Saved and confirmed on Hermes. " + verified.activation
            errorMessage = nil
            await load(agentID: verified.agentID)
        } catch {
            guard generation == controlGeneration, account == accountGeneration,
                  currentAgentID == confirmedControl.agentID else { return }
            // A timeout may follow a successful host write. Do not flip state
            // or retry automatically; require a fresh authoritative read.
            capabilityControl = nil
            errorMessage = error.localizedDescription
        }
    }

    func clearControl() {
        controlGeneration += 1
        capabilityControl = nil
        isLoadingControl = false
        isChangingCapability = false
    }

    init(client: any HermesSkillsAndToolsCatalogClient) {
        self.client = client
    }

    func load(agentID: String) async {
        activateAgent(agentID)
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let loaded = try await client.load(agentID: agentID)
            guard
                generation == loadGeneration,
                currentAgentID == agentID,
                loaded.agentID == agentID
            else { return }
            catalog = loaded
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, currentAgentID == agentID else { return }
            errorMessage = "Skills, plugins, and MCP servers could not be loaded from Hermes."
        }
    }

    func loadSkill(id: String, agentID: String) async -> HermesSkillDocument? {
        guard !isSaving, !isChangingCapability else {
            errorMessage = "Wait for the current save to finish."
            return nil
        }
        activateAgent(agentID)
        guard catalog?.management?.canRead == true else {
            errorMessage = HermesCapabilityCompatibilityError.updateRequired.localizedDescription
            return nil
        }
        document = nil
        statusMessage = nil
        documentGeneration += 1
        let ownedDocumentGeneration = documentGeneration
        let ownedAccountGeneration = accountGeneration
        isLoading = true
        defer {
            if ownedDocumentGeneration == documentGeneration,
               ownedAccountGeneration == accountGeneration,
               currentAgentID == agentID {
                isLoading = false
            }
        }
        do {
            let loaded = try await client.skill(id: id, agentID: agentID)
            guard
                ownedDocumentGeneration == documentGeneration,
                ownedAccountGeneration == accountGeneration,
                currentAgentID == agentID,
                loaded.agentID == agentID,
                loaded.skillID == id
            else { return nil }
            document = loaded
            errorMessage = nil
            return loaded
        } catch {
            guard
                ownedDocumentGeneration == documentGeneration,
                ownedAccountGeneration == accountGeneration,
                currentAgentID == agentID
            else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func saveSkill(content: String, agentID: String, expectedDocument: HermesSkillDocument? = nil) async -> Bool {
        guard !isSaving, !isChangingCapability,
            let document,
            document.agentID == agentID,
            currentAgentID == agentID,
            expectedDocument == nil || expectedDocument == document
        else {
            errorMessage = "This editor is no longer current. Reopen the skill before saving."
            return false
        }
        let updated = await performSkillDocumentMutation(
            agentID: agentID,
            expectedSkillID: document.skillID,
            successMessage: { _ in "Saved and confirmed SKILL.md on Hermes." }
        ) {
            guard catalog?.management?.canUpdate == true else { throw HermesCapabilityCompatibilityError.updateRequired }
            return try await client.updateSkill(
                id: document.skillID,
                content: content,
                expectedSHA256: document.sha256,
                agentID: agentID
            )
        }
        return updated != nil
    }

    func createSkill(
        name: String,
        description: String,
        instructions: String,
        category: String,
        agentID: String
    ) async -> HermesSkillDocument? {
        guard !isSaving, !isChangingCapability else {
            errorMessage = "Wait for the current save to finish."
            return nil
        }
        activateAgent(agentID)
        let escapedDescription = description
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let content = """
        ---
        name: \(name)
        description: "\(escapedDescription)"
        ---

        \(instructions)
        """
        return await performSkillDocumentMutation(
            agentID: agentID,
            expectedSkillID: name,
            successMessage: { "Created and confirmed \($0.skillID) on Hermes." }
        ) {
            guard catalog?.management?.canCreate == true else { throw HermesCapabilityCompatibilityError.updateRequired }
            return try await client.createSkill(
                name: name,
                content: content,
                category: category.isEmpty ? nil : category,
                agentID: agentID
            )
        }
    }

    func importSkill(data: Data, kind: String, agentID: String) async -> HermesSkillDocument? {
        guard !isSaving, !isChangingCapability else {
            errorMessage = "Wait for the current save to finish."
            return nil
        }
        activateAgent(agentID)
        return await performSkillDocumentMutation(
            agentID: agentID,
            expectedSkillID: nil,
            successMessage: { "Created and confirmed \($0.skillID) on Hermes." }
        ) {
            guard catalog?.management?.canImport == true else { throw HermesCapabilityCompatibilityError.updateRequired }
            return try await client.importSkill(
                data: data,
                kind: kind,
                category: nil,
                agentID: agentID
            )
        }
    }

    private func performSkillDocumentMutation(
        agentID: String,
        expectedSkillID: String?,
        successMessage: (HermesSkillDocument) -> String,
        operation: @MainActor () async throws -> HermesSkillDocument
    ) async -> HermesSkillDocument? {
        documentGeneration += 1
        let ownedDocumentGeneration = documentGeneration
        let ownedAccountGeneration = accountGeneration
        documentMutationSequence &+= 1
        let ownedMutation = documentMutationSequence
        isSaving = true
        defer {
            // Closing an editor invalidates its document, not ownership of
            // the in-flight mutation's busy indicator. A newer mutation is
            // protected by its own sequence across navigation/account changes.
            if documentMutationSequence == ownedMutation { isSaving = false }
        }
        statusMessage = nil
        do {
            let updated = try await operation()
            guard
                ownedDocumentGeneration == documentGeneration,
                ownedAccountGeneration == accountGeneration,
                currentAgentID == agentID,
                updated.agentID == agentID,
                expectedSkillID == nil || updated.skillID == expectedSkillID
            else { return nil }
            document = updated
            isSaving = false
            statusMessage = successMessage(updated)
            errorMessage = nil
            await load(agentID: agentID)
            guard
                ownedAccountGeneration == accountGeneration,
                currentAgentID == agentID
            else { return nil }
            return updated
        } catch {
            guard
                ownedDocumentGeneration == documentGeneration,
                ownedAccountGeneration == accountGeneration,
                currentAgentID == agentID
            else { return nil }
            isSaving = false
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func activateAgent(_ agentID: String) {
        guard currentAgentID != agentID else { return }
        currentAgentID = agentID
        clearControl()
        statusMessage = nil
        loadGeneration += 1
        documentGeneration += 1
        catalog = nil
        document = nil
        errorMessage = nil
        isLoading = false
        isSaving = false
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    func clearError() { errorMessage = nil }

    func clearDocument() {
        documentGeneration += 1
        document = nil
    }

    func resetForAccountBoundary() {
        clearControl()
        statusMessage = nil
        loadGeneration += 1
        accountGeneration += 1
        documentGeneration += 1
        currentAgentID = nil
        catalog = nil
        document = nil
        errorMessage = nil
        isLoading = false
        isSaving = false
    }
}
