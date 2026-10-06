import Observation
import SwiftUI

@MainActor @Observable
final class ProviderAccountsStore {
    let hostName: String
    let profileID: String
    let servingProfileID: String?

    private(set) var snapshot: DirectHermesProviderSnapshot?
    private(set) var oauthSession: DirectHermesOAuthSession?
    private(set) var credentialValidation: DirectHermesProviderValidation?
    private(set) var endpointValidation: DirectHermesProviderValidation?
    private(set) var isLoading = false
    private(set) var operationTitle: String?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var isRetired = false
    /// Accounts only a terminal on the host signs in to, run by the plugin with the provider's own tool.
    let hostSignIn: ProviderHostSignInStore?
    /// Why the sign-in sheet's sign-in couldn't start.
    private(set) var signInFailure: String?
    private(set) var isStartingSignIn = false

    @ObservationIgnored private let client: DirectHermesProviderClient
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var oauthPollTask: Task<Void, Never>?
    @ObservationIgnored private var latestSetupInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var consumedSetupInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var setupRefreshTask: Task<Void, Never>?

    init(
        hostName: String,
        profileID: String,
        servingProfileID: String? = nil,
        client: DirectHermesProviderClient,
        hostSignIn: ProviderHostSignInStore? = nil
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.servingProfileID = servingProfileID
        self.client = client
        self.hostSignIn = hostSignIn
        hostSignIn?.onSignedIn = { [weak self] in
            guard let self, self.ownsScope else { return }
            try? await self.reloadAfterMutation(message: "Hermes confirmed the provider sign-in.")
        }
    }

    var overview: ProviderKeysOverview? {
        snapshot.map { ProviderKeysOverview(snapshot: $0, hostSignIns: hostSignIn?.providers ?? []) }
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var isBusy: Bool { isLoading || operationTitle != nil }
    var canManageServingState: Bool { servingProfileID == profileID && ownsScope }
    var hasActiveOAuthSession: Bool { oauthSession?.status == .pending }

    func load() async {
        await load(preservingMessages: false)
    }

    func receiveSetupInvalidation(revision: UInt64) {
        guard ownsScope, revision > latestSetupInvalidationRevision else { return }
        latestSetupInvalidationRevision = revision
        scheduleSetupRefreshIfNeeded()
    }

    private func load(preservingMessages: Bool) async {
        guard ownsScope, !isBusy else { return }
        let request = UUID()
        generation = request
        isLoading = true
        if !preservingMessages {
            errorMessage = nil
            successMessage = nil
        }
        defer {
            if generation == request { isLoading = false }
            scheduleSetupRefreshIfNeeded()
        }
        let hostSignIns = Task { [hostSignIn] in await hostSignIn?.load() }
        defer { hostSignIns.cancel() }
        do {
            let value = try await client.loadSnapshot(
                profileID: profileID,
                servingProfileID: servingProfileID,
                includeServingCredentialPools: canManageServingState
            )
            await hostSignIns.value
            guard canPublish(request) else { return }
            snapshot = value
        } catch is CancellationError {
        } catch {
            guard canPublish(request) else { return }
            if !preservingMessages || (errorMessage == nil && successMessage == nil) {
                errorMessage = Self.message(error)
            }
        }
    }

    func refresh() async {
        guard operationTitle == nil else { return }
        isLoading = false
        await load()
    }

    func retire() {
        isRetired = true
        generation = UUID()
        setupRefreshTask?.cancel()
        setupRefreshTask = nil
        latestSetupInvalidationRevision = 0
        consumedSetupInvalidationRevision = 0
        oauthPollTask?.cancel()
        oauthPollTask = nil
        oauthSession = nil
        hostSignIn?.retire()
        signInFailure = nil
        credentialValidation = nil
        endpointValidation = nil
        snapshot = nil
        isLoading = false
        operationTitle = nil
        errorMessage = nil
        successMessage = nil
    }

    func clearCredentialValidation() { credentialValidation = nil }
    func clearEndpointValidation() { endpointValidation = nil }

    func testCredential(key: String, value: String, companionAPIKey: String = "") async {
        guard begin("Testing credential") else { return }
        defer { finish() }
        do {
            let result = try await client.validateCredential(
                profileID: profileID, key: key, value: value, companionAPIKey: companionAPIKey
            )
            guard ownsScope else { return }
            credentialValidation = result
            successMessage = result.isAccepted
                ? (result.isReachable ? "Hermes confirmed that the provider accepted this credential." : "Hermes has no live probe for this credential type.")
                : nil
            errorMessage = result.isAccepted ? nil : (result.message.isEmpty ? "The provider did not accept this credential." : result.message)
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func replaceCredential(key: String, value: String, companionAPIKey: String = "") async -> Bool {
        guard begin("Replacing credential") else { return false }
        defer { finish() }
        do {
            _ = try await client.replaceCredential(
                profileID: profileID, key: key, value: value, companionAPIKey: companionAPIKey
            )
            guard ownsScope else { return false }
            credentialValidation = nil
            try await reloadAfterMutation(message: "Hermes replaced the credential and confirmed its presence.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func deleteCredential(key: String) async -> Bool {
        guard begin("Removing credential") else { return false }
        defer { finish() }
        do {
            try await client.deleteCredential(profileID: profileID, key: key)
            guard ownsScope else { return false }
            credentialValidation = nil
            try await reloadAfterMutation(message: "Hermes removed the credential and its provider mirrors.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func testEndpoint(_ draft: DirectHermesCustomEndpointDraft) async {
        guard begin("Testing endpoint") else { return }
        defer { finish() }
        do {
            let result = try await client.validateCustomEndpoint(draft)
            guard ownsScope else { return }
            endpointValidation = result
            successMessage = result.isAccepted ? "Hermes reached the endpoint and found \(result.models.count) model(s)." : nil
            errorMessage = result.isAccepted ? nil : (result.message.isEmpty ? "The endpoint test failed." : result.message)
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func saveEndpoint(_ draft: DirectHermesCustomEndpointDraft) async -> Bool {
        guard begin("Saving endpoint") else { return false }
        defer { finish() }
        do {
            _ = try await client.saveCustomEndpoint(profileID: profileID, draft: draft)
            guard ownsScope else { return false }
            endpointValidation = nil
            try await reloadAfterMutation(message: "Hermes saved the custom endpoint and confirmed its profile state.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func activateEndpoint(id: String) async {
        guard begin("Activating endpoint") else { return }
        defer { finish() }
        do {
            try await client.activateCustomEndpoint(profileID: profileID, endpointID: id)
            guard ownsScope else { return }
            try await reloadAfterMutation(message: "Hermes made this endpoint the profile default.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func deleteEndpoint(id: String) async -> Bool {
        guard begin("Removing endpoint") else { return false }
        defer { finish() }
        do {
            try await client.deleteCustomEndpoint(profileID: profileID, endpointID: id)
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes removed the custom endpoint and detached its profile default.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func startOAuth(providerID: String) async -> DirectHermesOAuthSession? {
        guard !hasActiveOAuthSession, begin("Starting sign-in") else { return nil }
        defer { finish() }
        do {
            let session = try await client.startOAuth(profileID: profileID, providerID: providerID)
            guard ownsScope else { return nil }
            oauthSession = session
            if session.flow == .deviceCode { startPolling(session) }
            return session
        } catch is CancellationError {
            return nil
        } catch {
            guard ownsScope else { return nil }
            errorMessage = Self.message(error)
            return nil
        }
    }

    func submitOAuthCode(_ code: String) async -> Bool {
        guard let session = oauthSession, session.flow == .pkce, session.status == .pending,
              begin("Completing sign-in") else { return false }
        defer { finish() }
        do {
            let completed = try await client.submitOAuthCode(
                profileID: profileID, session: session, code: code
            )
            guard ownsScope, oauthSession?.id == session.id else { return false }
            oauthSession = completed
            guard completed.status == .approved else {
                errorMessage = completed.errorMessage ?? "Provider sign-in was not accepted."
                return false
            }
            try await reloadAfterMutation(message: "Hermes confirmed the provider sign-in and profile account state.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope, oauthSession?.id == session.id else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func cancelOAuth() async {
        guard let session = oauthSession, begin("Cancelling sign-in") else { return }
        oauthPollTask?.cancel()
        oauthPollTask = nil
        defer { finish() }
        do {
            try await client.cancelOAuth(profileID: profileID, sessionID: session.id)
            guard ownsScope else { return }
            oauthSession = nil
            successMessage = "Sign-in was cancelled before Hermes saved an account."
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    /// The sign-in sheet closed: a sign-in still waiting is cancelled on Hermes,
    /// a finished one is cleared.
    func closeOAuthSession() async {
        guard let session = oauthSession else { return }
        if session.status == .pending {
            await cancelOAuth()
        } else {
            oauthSession = nil
        }
    }

    func disconnectOAuth(providerID: String) async {
        guard begin("Disconnecting account") else { return }
        defer { finish() }
        do {
            try await client.disconnectOAuth(profileID: profileID, providerID: providerID)
            guard ownsScope else { return }
            try await reloadAfterMutation(message: "Hermes disconnected the provider account.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func addPoolCredential(providerID: String, apiKey: String, label: String) async -> Bool {
        guard canManageServingState, begin("Adding account credential") else { return false }
        defer { finish() }
        do {
            try await client.addServingCredentialPoolEntry(
                profileID: profileID, servingProfileID: servingProfileID,
                providerID: providerID, apiKey: apiKey,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
            )
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes added and confirmed the serving-profile account credential.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func deletePoolCredential(providerID: String, entry: DirectHermesCredentialPool.Entry) async {
        guard canManageServingState, begin("Removing account credential") else { return }
        defer { finish() }
        do {
            try await client.deleteServingCredentialPoolEntry(
                profileID: profileID, servingProfileID: servingProfileID,
                providerID: providerID, entry: entry
            )
            guard ownsScope else { return }
            try await reloadAfterMutation(message: "Hermes removed the account credential and confirmed that it did not return.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    // MARK: Signing in from the phone

    var isSigningIn: Bool {
        isStartingSignIn || hasActiveOAuthSession || hostSignIn?.session?.isRunning == true
    }

    /// Starts a sign-in the way this account signs in: Hermes' own, or the host's tool.
    func startSignIn(_ target: ProviderSignInTarget) async {
        guard !isStartingSignIn else { return }
        isStartingSignIn = true
        signInFailure = nil
        defer { isStartingSignIn = false }
        if target.client != nil, let hostSignIn {
            if !(await hostSignIn.start(providerID: target.id)) {
                signInFailure = hostSignIn.errorMessage ?? "\(hostName) couldn't start the sign-in. Try again."
            }
        } else if await startOAuth(providerID: target.id) == nil {
            signInFailure = errorMessage ?? "Hermes couldn't start the sign-in. Try again."
            errorMessage = nil
        }
    }

    func submitSignInCode(_ code: String, for target: ProviderSignInTarget) async {
        if target.client != nil {
            await hostSignIn?.submit(code: code)
        } else {
            _ = await submitOAuthCode(code)
        }
    }

    /// The sign-in sheet closed: anything still running stops.
    func closeSignIn(_ target: ProviderSignInTarget) async {
        signInFailure = nil
        if target.client != nil {
            await hostSignIn?.close()
        } else {
            await closeOAuthSession()
        }
    }

    /// What the sign-in sheet shows for this account right now.
    func signInProgress(for target: ProviderSignInTarget) -> ProviderSignInProgress {
        if let signInFailure { return .init(step: .failed(signInFailure)) }
        if isStartingSignIn { return .init(step: .starting) }
        if target.client != nil {
            guard let session = hostSignIn?.session, session.providerID == target.id else {
                return .init(step: .starting)
            }
            let pastes = session.flow == .paste
            switch session.status {
            case .starting: return .init(step: .starting)
            case .waiting, .needsCode:
                return .init(step: .waiting, link: session.link, code: pastes ? nil : session.code, pastes: pastes,
                             problem: hostSignIn?.errorMessage)
            case .finishing: return .init(step: .finishing, pastes: pastes)
            case .signedIn: return .init(step: .connected(email: nil))
            case .failed, .expired, .cancelled:
                return .init(step: .failed(session.message ?? "The sign-in didn't finish. Try again."))
            }
        }
        guard let session = oauthSession, session.providerID == target.id else { return .init(step: .starting) }
        switch session.status {
        case .pending:
            if isBusy, operationTitle == "Completing sign-in" { return .init(step: .finishing, pastes: true) }
            return .init(step: .waiting, link: session.verificationURL,
                         code: session.flow == .deviceCode && !session.userCode.isEmpty ? session.userCode : nil,
                         pastes: session.flow == .pkce, problem: errorMessage)
        case .approved: return .init(step: .connected(email: session.accountEmail))
        default:
            return .init(step: .failed(session.errorMessage ?? (session.status == .expired
                ? "The sign-in code expired." : "The sign-in didn't finish.")))
        }
    }

    private func startPolling(_ initial: DirectHermesOAuthSession) {
        oauthPollTask?.cancel()
        oauthPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var current = initial
            while !Task.isCancelled, self.ownsScope, current.status == .pending, Date.now < current.expiresAt {
                do { try await Task.sleep(for: .seconds(current.pollInterval)) }
                catch { return }
                do {
                    current = try await self.client.pollOAuth(profileID: self.profileID, session: current)
                    guard self.ownsScope, self.oauthSession?.id == current.id else { return }
                    if current.status != .pending {
                        self.oauthSession = .init(
                            id: current.id, providerID: current.providerID, flow: current.flow,
                            userCode: "", verificationURL: current.verificationURL,
                            expiresAt: current.expiresAt, pollInterval: current.pollInterval,
                            status: current.status, errorMessage: current.errorMessage,
                            completionReason: current.completionReason, accountEmail: current.accountEmail,
                            selectedModel: current.selectedModel
                        )
                        self.oauthPollTask = nil
                        if current.status == .approved {
                            try await self.reloadAfterMutation(message: "Hermes confirmed the provider sign-in.")
                        } else {
                            self.errorMessage = current.errorMessage ?? "Provider sign-in ended with status \(current.status.rawValue)."
                        }
                        return
                    }
                    self.oauthSession = current
                } catch is CancellationError {
                    return
                } catch {
                    guard self.ownsScope else { return }
                    self.errorMessage = Self.message(error)
                    return
                }
            }
            guard !Task.isCancelled, self.ownsScope,
                  self.oauthSession?.id == current.id, current.status == .pending else { return }
            self.oauthSession = .init(
                id: current.id, providerID: current.providerID, flow: current.flow,
                userCode: "", verificationURL: current.verificationURL,
                expiresAt: current.expiresAt, pollInterval: current.pollInterval,
                status: .expired, errorMessage: "The provider sign-in code expired.",
                completionReason: current.completionReason, accountEmail: nil,
                selectedModel: current.selectedModel
            )
            self.oauthPollTask = nil
            self.errorMessage = "The provider sign-in code expired. Start a new sign-in to continue."
        }
    }

    private func reloadAfterMutation(message: String) async throws {
        let value = try await client.loadSnapshot(
            profileID: profileID, servingProfileID: servingProfileID,
            includeServingCredentialPools: canManageServingState
        )
        guard ownsScope else { throw CancellationError() }
        snapshot = value
        errorMessage = nil
        successMessage = message
    }

    private func begin(_ title: String) -> Bool {
        guard ownsScope, !isBusy else { return false }
        operationTitle = title
        errorMessage = nil
        successMessage = nil
        return true
    }

    private func finish() {
        operationTitle = nil
        scheduleSetupRefreshIfNeeded()
    }

    private func scheduleSetupRefreshIfNeeded() {
        guard ownsScope, setupRefreshTask == nil, !isBusy,
              latestSetupInvalidationRevision != consumedSetupInvalidationRevision else { return }
        setupRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            await self?.drainSetupRefreshes()
        }
    }

    private func drainSetupRefreshes() async {
        defer {
            setupRefreshTask = nil
            scheduleSetupRefreshIfNeeded()
        }
        while ownsScope, !isBusy, !Task.isCancelled,
              latestSetupInvalidationRevision != consumedSetupInvalidationRevision {
            let revision = latestSetupInvalidationRevision
            await load(preservingMessages: true)
            guard ownsScope, !Task.isCancelled else { return }
            consumedSetupInvalidationRevision = revision
        }
    }

    private func canPublish(_ request: UUID) -> Bool { ownsScope && generation == request && !Task.isCancelled }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Hermes could not confirm this provider operation. Refresh before trying it again."
    }
}

@MainActor
struct ProviderAccountsView: View {
    private struct PoolRemoval: Identifiable {
        let providerID: String
        let entry: DirectHermesCredentialPool.Entry
        var id: String { "\(providerID.utf8.count):\(providerID)\(entry.id)" }
    }

    let store: ProviderAccountsStore
    @State private var addingEndpoint = false
    @State private var addingPoolCredential = false
    @State private var disconnectOAuthID: String?
    @State private var poolRemoval: PoolRemoval?
    @State private var signingIn: ProviderSignInTarget?
    /// The sheet's account, kept past dismissal so closing can stop its sign-in.
    @State private var lastSignIn: ProviderSignInTarget?
    @State private var search = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if store.ownsScope {
                Form {
                    statusSections
                    if let snapshot = store.snapshot, let overview = store.overview {
                        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                            searchResults(overview.matching(search), portal: snapshot.portal)
                        } else {
                            yourProvidersSection(overview.connected, portal: snapshot.portal)
                            signInSection(overview.signIns)
                            Section {
                                NavigationLink {
                                    ProviderKeyPickerView(store: store, choices: overview.keyChoices)
                                } label: {
                                    Label("Add an API key", systemImage: "key")
                                }
                                .accessibilityIdentifier("providers.add-key")
                            } footer: {
                                Text("For providers that use a key instead of an account. Keys are saved on \(store.hostName) and never shown again.")
                            }
                            Section {
                                NavigationLink {
                                    advancedForm
                                } label: {
                                    Label("Advanced", systemImage: "gearshape.2")
                                }
                                .accessibilityIdentifier("providers.advanced")
                            } footer: {
                                Text("Custom endpoints, extra accounts, every key setting, and which provider new chats use.")
                            }
                        }
                    }
                }
                .searchable(text: $search, prompt: "Search providers")
                .refreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Provider keys unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("The selected host changed. Reopen Provider Keys from the current workspace.")
                )
            }
        }
        .navigationTitle("Provider Keys")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.snapshot == nil { await store.load() } }
        .bighelpSheet(item: $signingIn, onDismiss: {
            if let target = lastSignIn { Task { await store.closeSignIn(target) } }
        }) { provider in
            ProviderSignInSheet(store: store, provider: provider)
                .bighelpSheetSize(.standard)
        }
        .confirmationDialog(
            "Disconnect this account?", isPresented: Binding(
                get: { disconnectOAuthID != nil },
                set: { if !$0 { disconnectOAuthID = nil } }
            ), titleVisibility: .visible
        ) {
            if let id = disconnectOAuthID {
                Button("Disconnect", role: .destructive) {
                    disconnectOAuthID = nil
                    Task { await store.disconnectOAuth(providerID: id) }
                }
            }
            Button("Cancel", role: .cancel) { disconnectOAuthID = nil }
        } message: {
            Text("Hermes removes its saved sign-in for this profile. Chats already running keep going.")
        }
        .accessibilityIdentifier("providers.accounts")
    }

    // MARK: Overview

    @ViewBuilder
    private func searchResults(_ overview: ProviderKeysOverview, portal: DirectHermesPortalStatus?) -> some View {
        if overview.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            if !overview.connected.isEmpty { yourProvidersSection(overview.connected, portal: portal) }
            signInSection(overview.signIns)
            if !overview.keyChoices.isEmpty {
                Section("Add an API key") {
                    ForEach(overview.keyChoices) { choice in
                        NavigationLink {
                            ProviderCredentialEditorView(store: store, credentialID: choice.id)
                        } label: {
                            ProviderRowLabel(logoID: choice.logoID, name: choice.providerName, detail: choice.title)
                        }
                        .accessibilityIdentifier("providers.key-choice.\(choice.id)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func yourProvidersSection(_ rows: [ProviderKeysOverview.Connected],
                                      portal: DirectHermesPortalStatus?) -> some View {
        Section {
            if rows.isEmpty {
                Text("None yet. Sign in to an account or add an API key below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                switch row.kind {
                case .key(let credentialID):
                    NavigationLink {
                        ProviderCredentialEditorView(store: store, credentialID: credentialID)
                    } label: {
                        ProviderRowLabel(logoID: row.logoID, name: row.name, detail: row.detail)
                    }
                    .accessibilityIdentifier("providers.connected.\(row.id)")
                case .account(let providerID, let canDisconnect, let hint):
                    HStack {
                        ProviderRowLabel(logoID: row.logoID, name: row.name, detail: row.detail)
                        Spacer(minLength: 0)
                        Menu {
                            if providerID == portal?.providerID, let url = portal?.subscriptionURL {
                                Button("Manage subscription", systemImage: "arrow.up.right.square") { openURL(url) }
                            }
                            if canDisconnect {
                                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    disconnectOAuthID = providerID
                                }
                            } else if let hint {
                                Text(hint)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.bighelp(.title3))
                                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                                .contentShape(.rect)
                        }
                        .disabled(store.isBusy)
                        .accessibilityLabel("\(row.name) options")
                        .accessibilityIdentifier("providers.account-menu.\(providerID)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("providers.connected.\(row.id)")
                }
            }
        } header: {
            Text("Your providers")
        }
    }

    @ViewBuilder
    private func signInSection(_ rows: [ProviderKeysOverview.SignIn]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    switch row.method {
                    case .onPhone:
                        signInRow(row, detail: row.problem ?? "Sign in here", client: nil)
                    case .withHostTool(let client, _):
                        signInRow(row, detail: row.problem
                                      ?? (client == "Hermes" ? "Sign in here" : "Uses \(client) on \(store.hostName)"),
                                  client: client)
                    case .needsTool(let client, let install, let command):
                        NavigationLink {
                            ProviderComputerSignInView(hostName: store.hostName, name: row.name, logoID: row.logoID,
                                                       command: command, documentationURL: row.documentationURL,
                                                       reason: .needsTool(client: client, install: install))
                        } label: {
                            ProviderRowLabel(logoID: row.logoID, name: row.name,
                                             detail: "Needs \(client) on \(store.hostName)")
                        }
                        .accessibilityIdentifier("providers.signin-row.\(row.id)")
                    case .onComputer(let command):
                        NavigationLink {
                            ProviderComputerSignInView(hostName: store.hostName, name: row.name, logoID: row.logoID,
                                                       command: command, documentationURL: row.documentationURL,
                                                       reason: store.hostSignIn?.isSupported == true
                                                           ? .terminalOnly : .pluginUpdate)
                        } label: {
                            ProviderRowLabel(logoID: row.logoID, name: row.name,
                                             detail: row.problem ?? "Sign in on \(store.hostName)")
                        }
                        .accessibilityIdentifier("providers.signin-row.\(row.id)")
                    case .retired(let message, let replacementKey):
                        NavigationLink {
                            ProviderRetiredSignInView(store: store, name: row.name, logoID: row.logoID, message: message,
                                                      replacementKey: replacementKey)
                        } label: {
                            ProviderRowLabel(logoID: row.logoID, name: row.name, detail: "No longer offered")
                        }
                        .accessibilityIdentifier("providers.signin-row.\(row.id)")
                    }
                }
            } header: {
                Text("Sign in with your account")
            } footer: {
                Text("Subscriptions and accounts like Nous Portal, ChatGPT, GitHub Copilot or Claude. You approve on the provider's own page; bighelp never sees your password.")
            }
        }
    }

    private func signInRow(_ row: ProviderKeysOverview.SignIn, detail: String, client: String?) -> some View {
        HStack {
            ProviderRowLabel(logoID: row.logoID, name: row.name, detail: detail)
            Spacer(minLength: 0)
            Button("Sign in") {
                let target = ProviderSignInTarget(id: row.id, name: row.name, logoID: row.logoID, client: client)
                lastSignIn = target
                signingIn = target
            }
            .bighelpProminentButtonStyle()
            .controlSize(.small)
            .disabled(store.isBusy || store.isSigningIn)
            .accessibilityIdentifier("providers.sign-in.\(row.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers.signin-row.\(row.id)")
    }

    // MARK: Advanced

    private var advancedForm: some View {
        Form {
            statusSections
            scopeSection
            if let snapshot = store.snapshot {
                if snapshot.setup != nil || snapshot.runtime != nil { runtimeSection(snapshot) }
                if let portal = snapshot.portal { portalSection(portal) }
                accountSourcesSection(snapshot.oauthProviders)
                credentialSection(snapshot.credentials)
                supportedProvidersSection(snapshot.providers)
                endpointsSection(snapshot.customEndpoints)
                poolsSection(snapshot.credentialPools)
                SkippedPartsNote(parts: snapshot.skippedParts)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .bighelpSheet(isPresented: $addingEndpoint) {
            NavigationStack {
                ProviderEndpointEditorView(store: store, endpoint: nil) { addingEndpoint = false }
            }
            .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: $addingPoolCredential) {
            NavigationStack {
                ProviderPoolCredentialEditorView(store: store) { addingPoolCredential = false }
            }
            .bighelpSheetSize(.standard)
        }
        .confirmationDialog(
            "Remove this account credential?", isPresented: Binding(
                get: { poolRemoval != nil },
                set: { if !$0 { poolRemoval = nil } }
            ), titleVisibility: .visible
        ) {
            if let removal = poolRemoval {
                Button("Remove", role: .destructive) {
                    poolRemoval = nil
                    Task {
                        await store.deletePoolCredential(
                            providerID: removal.providerID, entry: removal.entry
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { poolRemoval = nil }
        } message: {
            Text("Hermes will remove the selected credential-pool entry and suppress its backing source when required so it does not return on refresh.")
        }
        .accessibilityIdentifier("providers.advanced.screen")
    }

    /// Where each signed-in account's credentials come from, for troubleshooting.
    @ViewBuilder
    private func accountSourcesSection(_ providers: [DirectHermesOAuthProvider]) -> some View {
        let signedIn = providers.filter(\.status.isLoggedIn)
        if !signedIn.isEmpty {
            Section("Account sources") {
                ForEach(signedIn) { provider in
                    LabeledContent(provider.name,
                                   value: provider.status.sourceLabel ?? provider.status.source ?? "Hermes")
                }
            }
        }
    }

    private var scopeSection: some View {
        Section {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
        } header: {
            Text("Applies to")
        } footer: {
            Text("Saved credentials stay on this host and are never displayed in bighelp.")
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if store.isLoading || store.operationTitle != nil {
            Section { ProgressView(store.operationTitle ?? "Loading providers") }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.isBusy)
            }
            .accessibilityIdentifier("providers.error")
        }
        if let message = store.successMessage {
            Section { Label(message, systemImage: "checkmark.circle") }
                .accessibilityIdentifier("providers.confirmed")
        }
    }

    private func runtimeSection(_ snapshot: DirectHermesProviderSnapshot) -> some View {
        Section("New chats") {
            if let setup = snapshot.setup {
                LabeledContent("Provider configured", value: setup.providerConfigured == true ? "Yes" : "No")
            }
            if let runtime = snapshot.runtime {
                LabeledContent("New sessions", value: runtime.isUsable ? "Ready" : "Needs attention")
            }
            if let provider = snapshot.runtime?.providerID { LabeledContent("Effective provider", value: provider) }
            if let model = snapshot.runtime?.modelID { LabeledContent("Effective model", value: model) }
            if let error = snapshot.runtime?.errorMessage, !error.isEmpty {
                Text(error).font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func portalSection(_ portal: DirectHermesPortalStatus) -> some View {
        Section("Nous account") {
            LabeledContent("Account", value: portal.isLoggedIn ? (portal.isFreeTier ? "Free tier" : "Connected") : "Not connected")
            if let tier = portal.accountTier { LabeledContent("Tier", value: tier) }
            ForEach(portal.features) { feature in LabeledContent(feature.label, value: feature.state) }
            if let url = portal.subscriptionURL {
                Button("Manage subscription", systemImage: "arrow.up.right.square") { openURL(url) }
            }
        }
    }

    private func supportedProvidersSection(_ providers: [DirectHermesProviderDescriptor]) -> some View {
        Section("Advanced · Provider support") {
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.name)
                        Spacer()
                        if provider.isAuthenticated == true {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Authenticated")
                        }
                    }
                    Text([provider.authType, "\(provider.modelCount) models"].compactMap { $0 }.joined(separator: " · "))
                        .font(.bighelp(.caption)).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("providers.supported.\(provider.id)")
            }
        }
    }

    private func credentialSection(_ credentials: [DirectHermesProviderCredential]) -> some View {
        Section("Every key setting") {
            let rows = ProviderCredentialPresentation.sorted(
                credentials.filter { !$0.isChannelManaged && ($0.category == "provider" || $0.providerID != nil || $0.isCustom) }
            )
            ForEach(rows) { credential in
                NavigationLink {
                    ProviderCredentialEditorView(store: store, credentialID: credential.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ProviderCredentialPresentation.title(credential))
                        Text(ProviderCredentialPresentation.subtitle(credential))
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityIdentifier("providers.credential.\(credential.id)")
            }
            if rows.isEmpty { Text("No provider key fields were reported.").foregroundStyle(.secondary) }
        }
    }

    private func endpointsSection(_ endpoints: [DirectHermesCustomEndpoint]) -> some View {
        Section("Advanced · Custom endpoints") {
            ForEach(endpoints) { endpoint in
                NavigationLink {
                    ProviderEndpointEditorView(store: store, endpoint: endpoint)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(endpoint.name)
                            if endpoint.isCurrent { Image(systemName: "checkmark").accessibilityLabel("Profile default") }
                        }
                        Text(endpoint.baseURL).font(.bighelp(.caption)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
            Button("Add endpoint", systemImage: "plus") { addingEndpoint = true }.disabled(store.isBusy)
        }
    }

    @ViewBuilder
    private func poolsSection(_ pools: [DirectHermesCredentialPool]) -> some View {
        if store.canManageServingState {
            Section {
                ForEach(pools) { pool in
                    DisclosureGroup(pool.id) {
                        ForEach(pool.entries) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.label)
                                    Text(entry.source).font(.bighelp(.caption)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    poolRemoval = .init(providerID: pool.id, entry: entry)
                                }
                                .disabled(store.isBusy)
                            }
                        }
                    }
                }
                Button("Add account credential", systemImage: "plus") { addingPoolCredential = true }
                    .disabled(store.isBusy)
            } header: {
                Text("Advanced · Credential pools")
            } footer: {
                Text("Entries belong to the host’s serving profile. Saved values are never shown.")
            }
        }
    }
}

/// Names a key row by provider and the setting it holds ("OpenRouter API key",
/// "DeepSeek base URL"). Hermes leaves some provider labels blank, so the name
/// falls back to the provider ID, then to the variable name itself.
enum ProviderCredentialPresentation {
    static func title(_ credential: DirectHermesProviderCredential) -> String {
        let field = field(for: credential.id)
        let provider = providerName(credential)
        guard let field else { return provider }
        // "Meta Model API" + "API key" reads "Meta Model API key".
        if provider.hasSuffix(" API"), field.hasPrefix("API ") { return provider + field.dropFirst(3) }
        return "\(provider) \(field)"
    }

    static func subtitle(_ credential: DirectHermesProviderCredential) -> String {
        "\(credential.id) · \(credential.isSet ? "Configured on Hermes" : "Not configured")"
    }

    static func providerName(_ credential: DirectHermesProviderCredential) -> String {
        if let label = credential.providerName?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if let id = credential.providerID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let known = AIProviderBrandRegistry.displayName(id: id, authoritativeName: nil)
            if known != id { return known }
        }
        let suffix = fields.first { credential.id.hasSuffix($0.suffix) }?.suffix ?? ""
        let words = credential.id.dropLast(suffix.count).split(separator: "_").map { word in
            knownWords[String(word)] ?? String(word.prefix(1)) + word.dropFirst().lowercased()
        }
        return words.isEmpty ? credential.id : words.joined(separator: " ")
    }

    /// Same provider's settings sit together, alphabetically.
    static func sorted(_ credentials: [DirectHermesProviderCredential]) -> [DirectHermesProviderCredential] {
        credentials.sorted {
            let order = title($0).localizedStandardCompare(title($1))
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func field(for key: String) -> String? {
        fields.first { key.hasSuffix($0.suffix) }?.name
    }

    /// Longest suffix first.
    private static let fields: [(suffix: String, name: String)] = [
        ("_CREDENTIALS_PATH", "credentials file"), ("_API_BASE_URL", "base URL"), ("_OAUTH_TOKEN", "sign-in token"),
        ("_API_SECRET", "secret"), ("_BASE_URL", "base URL"), ("_API_KEY", "API key"), ("_TOKEN", "token"),
        ("_SECRET", "secret"), ("_REGION", "region"), ("_PROFILE", "profile"), ("_PATH", "file path"),
        ("_URL", "URL"), ("_KEY", "key"),
    ]

    private static let knownWords: [String: String] = [
        "AI": "AI", "API": "API", "AWS": "AWS", "CN": "China", "GH": "GitHub", "GITHUB": "GitHub", "GLM": "GLM",
        "HF": "Hugging Face", "LLM": "LLM", "LM": "LM", "MCP": "MCP", "NVIDIA": "NVIDIA", "OPENAI": "OpenAI",
        "OPENROUTER": "OpenRouter", "XAI": "xAI", "DEEPSEEK": "DeepSeek", "MINIMAX": "MiniMax", "ZAI": "Z.AI",
    ]
}

struct ProviderCredentialEditorView: View {
    let store: ProviderAccountsStore
    let credentialID: String
    @State private var value = ""
    @State private var confirmReplace = false
    @State private var confirmDelete = false

    private var credential: DirectHermesProviderCredential? {
        store.snapshot?.credentials.first { $0.id == credentialID }
    }

    var body: some View {
        Form {
            if let credential {
                Section("Credential") {
                    LabeledContent("Field", value: credential.id)
                    LabeledContent("Provider", value: ProviderCredentialPresentation.providerName(credential))
                    LabeledContent("Status", value: credential.isSet ? "Configured" : "Not configured")
                    if !credential.description.isEmpty { Text(credential.description).font(.bighelp(.footnote)) }
                }
                Section {
                    SecureField("New value", text: $value)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityIdentifier("providers.credential.value")
                    Button("Test with provider") {
                        Task { await store.testCredential(key: credential.id, value: value) }
                    }
                    .disabled(value.isEmpty || value.utf8.count > 16_384 || store.isBusy)
                    Button("Review replacement") { confirmReplace = true }
                        .disabled(value.isEmpty || value.utf8.count > 16_384 || store.isBusy)
                    if credential.isSet {
                        Button("Remove credential", role: .destructive) { confirmDelete = true }
                            .disabled(store.isBusy)
                    }
                } header: {
                    Text("New value")
                } footer: {
                    Text("Replace validates before saving. The saved value is never read back.")
                }
            } else {
                ContentUnavailableView("Credential unavailable", systemImage: "key.slash")
            }
        }
        .navigationTitle(credential.map(ProviderCredentialPresentation.title) ?? "Credential")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: value) { _, _ in store.clearCredentialValidation() }
        .onDisappear { value = "" }
        .confirmationDialog("Replace this credential?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Validate and replace") {
                let submitted = value
                Task {
                    if await store.replaceCredential(key: credentialID, value: submitted) { value = "" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will test this value, replace the selected profile's saved credential, and reconcile provider mirrors.")
        }
        .confirmationDialog("Remove this credential?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { if await store.deleteCredential(key: credentialID) { value = "" } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will remove the environment value and matching provider mirrors. OAuth and unrelated pooled accounts remain separate.")
        }
    }
}

@MainActor
private struct ProviderEndpointEditorView: View {
    let store: ProviderAccountsStore
    let endpoint: DirectHermesCustomEndpoint?
    let onDone: (() -> Void)?

    @State private var name: String
    @State private var baseURL: String
    @State private var model: String
    @State private var contextLength: String
    @State private var discoversModels: Bool
    @State private var makeDefault = false
    @State private var apiKey = ""
    @State private var removeSavedKey = false
    @State private var confirmSave = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(store: ProviderAccountsStore, endpoint: DirectHermesCustomEndpoint?, onDone: (() -> Void)? = nil) {
        self.store = store
        self.endpoint = endpoint
        self.onDone = onDone
        _name = State(initialValue: endpoint?.name ?? "")
        _baseURL = State(initialValue: endpoint?.baseURL ?? "")
        _model = State(initialValue: endpoint?.defaultModel ?? "")
        _contextLength = State(initialValue: endpoint?.contextLength.map(String.init) ?? "")
        _discoversModels = State(initialValue: endpoint?.discoversModels ?? true)
    }

    private var draft: DirectHermesCustomEndpointDraft {
        .init(
            id: endpoint?.id, name: name, baseURL: baseURL, model: model,
            models: endpoint?.models ?? [], contextLength: Int(contextLength),
            discoversModels: discoversModels, makeDefault: makeDefault,
            apiKey: removeSavedKey ? "" : (apiKey.isEmpty ? nil : apiKey)
        )
    }

    var body: some View {
        Form {
            Section("Basics") {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Default model", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Make profile default", isOn: $makeDefault)
            }
            Section("Advanced") {
                TextField("Context length (optional)", text: $contextLength).keyboardType(.numberPad)
                Toggle("Discover models", isOn: $discoversModels)
            }
            Section {
                SecureField(endpoint?.hasCredential == true ? "Replacement key (optional)" : "API key (optional)", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                if endpoint?.hasCredential == true {
                    Toggle("Remove saved key", isOn: $removeSavedKey).disabled(!apiKey.isEmpty)
                }
            } header: {
                Text("Credential")
            } footer: {
                Text("Blank preserves the saved key. Removing it is explicit; tests use only a key entered here.")
            }
            Section("Actions") {
                Button("Test endpoint") { Task { await store.testEndpoint(draft) } }
                    .disabled(!valid || store.isBusy)
                Button(endpoint == nil ? "Review new endpoint" : "Review changes") { confirmSave = true }
                    .disabled(!valid || store.isBusy)
                if let endpoint {
                    Button(endpoint.isCurrent ? "Profile default" : "Make profile default") {
                        Task { await store.activateEndpoint(id: endpoint.id) }
                    }
                    .disabled(endpoint.isCurrent || store.isBusy)
                    Button("Delete endpoint", role: .destructive) { confirmDelete = true }
                        .disabled(store.isBusy)
                }
            }
        }
        .navigationTitle(endpoint?.name ?? "New Endpoint")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onDone != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone?() }.keyboardShortcut(.cancelAction).bighelpToolbarText() }
            }
        }
        .onChange(of: apiKey) { _, _ in store.clearEndpointValidation() }
        .onChange(of: baseURL) { _, _ in store.clearEndpointValidation() }
        .onDisappear { apiKey = "" }
        .confirmationDialog("Save this endpoint?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save") {
                let submitted = draft
                Task {
                    if await store.saveEndpoint(submitted) {
                        apiKey = ""
                        if let onDone { onDone() } else { dismiss() }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will merge these fields into the selected profile's endpoint entry. Hidden hand-edited fields remain on the host.")
        }
        .confirmationDialog("Delete this endpoint?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let endpoint {
                Button("Delete", role: .destructive) {
                    Task {
                        if await store.deleteEndpoint(id: endpoint.id) {
                            if let onDone { onDone() } else { dismiss() }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will remove this endpoint, its managed key, and any matching main-model endpoint mirror. Other provider settings remain.")
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && apiKey.utf8.count <= 16_384
            && (contextLength.isEmpty || (Int(contextLength) ?? 0) > 0)
    }
}

@MainActor
private struct ProviderPoolCredentialEditorView: View {
    let store: ProviderAccountsStore
    let onDone: () -> Void
    @State private var providerID = ""
    @State private var label = ""
    @State private var apiKey = ""
    @State private var confirm = false

    private var providers: [DirectHermesProviderDescriptor] { store.snapshot?.providers ?? [] }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $providerID) {
                    Text("Choose a provider").tag("")
                    ForEach(providers) { Text($0.name).tag($0.id) }
                }
                TextField("Account label (optional)", text: $label)
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            } header: { Text("Account") } footer: {
                Text("The key is sent once to the serving profile and is never read back into bighelp.")
            }
            Section {
                Button("Review account credential") { confirm = true }
                    .disabled(providerID.isEmpty || apiKey.isEmpty || apiKey.utf8.count > 16_384 || store.isBusy)
            }
        }
        .navigationTitle("Add Account Credential")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone).keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        .onDisappear { apiKey = "" }
        .confirmationDialog("Add this account credential?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Add") {
                let submitted = apiKey
                Task {
                    if await store.addPoolCredential(providerID: providerID, apiKey: submitted, label: label) {
                        apiKey = ""
                        onDone()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will add a separate credential-pool entry for this provider on the serving profile.")
        }
    }
}
