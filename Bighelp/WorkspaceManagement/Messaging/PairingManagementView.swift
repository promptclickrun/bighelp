import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class PairingManagementStore {
    enum Review: Identifiable, Equatable {
        case approve(HermesPairingPendingRequest)
        case revoke(HermesPairingApprovedUser)
        case clearPending(Int)

        var id: String {
            switch self {
            case .approve(let value): "approve:\(value.id.base64EncodedString())"
            case .revoke(let value): "revoke:\(value.id.base64EncodedString())"
            case .clearPending(let count): "clear:\(count)"
            }
        }

        var title: String {
            switch self {
            case .approve: "Approve this pairing?"
            case .revoke: "Revoke this user?"
            case .clearPending: "Clear all pending requests?"
            }
        }

        var actionTitle: String {
            switch self {
            case .approve: "Approve"
            case .revoke: "Revoke"
            case .clearPending: "Clear Requests"
            }
        }

        var isDestructive: Bool {
            switch self {
            case .approve: false
            case .revoke, .clearPending: true
            }
        }

        var message: String {
            switch self {
            case .approve(let value):
                "Approve \(value.userName.isEmpty ? value.userID : value.userName) for \(value.platform) using this exact pending request ID."
            case .revoke(let value):
                "Remove \(value.userName.isEmpty ? value.userID : value.userName) from the \(value.platform) approved list."
            case .clearPending(let count):
                "Remove all \(count) pending pairing request\(count == 1 ? "" : "s") for this profile. Approved users are unchanged."
            }
        }
    }

    let hostName: String
    let profileID: String
    private(set) var catalog: HermesPairingCatalog?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var isRetired = false
    var review: Review?

    @ObservationIgnored private let client: any HermesPairingManaging
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var latestInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var consumedInvalidationRevision: UInt64 = 0
    @ObservationIgnored private var invalidationRefreshTask: Task<Void, Never>?

    init(
        hostName: String,
        profileID: String,
        client: any HermesPairingManaging,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { !isRetired && isCurrent() }
    var canAct: Bool { ownsScope && !isLoading && !isMutating && errorMessage == nil }

    func load() async {
        await load(preservingMessages: false)
    }

    func refresh() async { await load() }

    func receivePairingInvalidation(revision: UInt64) {
        guard ownsScope, revision > latestInvalidationRevision else { return }
        latestInvalidationRevision = revision
        scheduleInvalidationRefreshIfNeeded()
    }

    private func load(preservingMessages: Bool) async {
        guard ownsScope, !isLoading, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        if !preservingMessages { errorMessage = nil }
        defer {
            if generation == token { isLoading = false }
            scheduleInvalidationRefreshIfNeeded()
        }
        do {
            let value = try await client.list(profileID: profileID)
            guard accepts(token) else { return }
            catalog = value
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == token else { return }
            if !preservingMessages || (errorMessage == nil && successMessage == nil) {
                errorMessage = Self.message(error)
            }
        }
    }

    func confirm(_ expected: Review) async {
        guard canAct, review == expected else {
            review = nil
            return
        }
        review = nil
        let token = UUID()
        generation = token
        isMutating = true
        errorMessage = nil
        successMessage = nil
        defer { finishMutation(token) }
        do {
            let message: String
            switch expected {
            case .approve(let request):
                _ = try await client.approve(request, profileID: profileID)
                message = "Hermes confirmed the pairing approval."
            case .revoke(let user):
                try await client.revoke(user, profileID: profileID)
                message = "Hermes confirmed the user was revoked."
            case .clearPending:
                let count = try await client.clearPending(profileID: profileID)
                message = "Hermes confirmed \(count) pending request\(count == 1 ? "" : "s") cleared."
            }
            let readback = try await client.list(profileID: profileID)
            guard accepts(token) else { return }
            catalog = readback
            successMessage = message
        } catch is CancellationError {
            guard ownsScope, generation == token else { return }
            errorMessage = "The operation was interrupted. Refresh pairing state before trying again."
        } catch {
            guard ownsScope, generation == token else { return }
            errorMessage = Self.message(error)
        }
    }

    func retire() {
        isRetired = true
        generation = UUID()
        invalidationRefreshTask?.cancel()
        invalidationRefreshTask = nil
        latestInvalidationRevision = 0
        consumedInvalidationRevision = 0
        catalog = nil
        review = nil
        errorMessage = nil
        successMessage = nil
        isLoading = false
        isMutating = false
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private func finishMutation(_ token: UUID) {
        if generation == token { isMutating = false }
        scheduleInvalidationRefreshIfNeeded()
    }

    private func scheduleInvalidationRefreshIfNeeded() {
        guard ownsScope, invalidationRefreshTask == nil, !isLoading, !isMutating,
              latestInvalidationRevision != consumedInvalidationRevision else { return }
        invalidationRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            await self?.drainInvalidationRefreshes()
        }
    }

    private func drainInvalidationRefreshes() async {
        defer {
            invalidationRefreshTask = nil
            scheduleInvalidationRefreshIfNeeded()
        }
        while ownsScope, !isLoading, !isMutating, !Task.isCancelled,
              latestInvalidationRevision != consumedInvalidationRevision {
            let revision = latestInvalidationRevision
            await load(preservingMessages: true)
            guard ownsScope, !Task.isCancelled else { return }
            consumedInvalidationRevision = revision
        }
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        return "Hermes could not complete the pairing request. Refresh its current state before trying again."
    }
}

@MainActor
struct PairingManagementView: View {
    @Bindable var store: PairingManagementStore

    var body: some View {
        Group {
            if store.ownsScope {
                List {
                    Section("Workspace") {
                        LabeledContent("Host", value: store.hostName)
                        LabeledContent("Profile", value: store.profileID)
                        Text("Messaging pairing approves people who can contact Hermes. It does not register this \(BighelpPlatform.isMac ? "Mac" : "phone") for bighelp notifications.")
                            .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                    }
                    status
                    if let catalog = store.catalog {
                        pending(catalog.pending)
                        approved(catalog.approved)
                    }
                }
                .listStyle(.insetGrouped)
                .bighelpRefreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Workspace changed", systemImage: "person.crop.circle.badge.xmark",
                    description: Text("Return to Workspace and reopen Pairing on the selected host.")
                )
            }
        }
        .navigationTitle("Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.catalog == nil { await store.load() } }
        .confirmationDialog(
            store.review?.title ?? "Review pairing change",
            isPresented: Binding(
                get: { store.review != nil },
                set: { if !$0 { store.review = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let review = store.review {
                Button(review.actionTitle, role: review.isDestructive ? .destructive : nil) {
                    Task { await store.confirm(review) }
                }
                Button("Cancel", role: .cancel) { store.review = nil }
            }
        } message: {
            if let review = store.review { Text(review.message) }
        }
        .onChange(of: store.ownsScope) { _, current in if !current { store.retire() } }
        .accessibilityIdentifier("workspace.pairing")
    }

    @ViewBuilder
    private var status: some View {
        if store.isLoading || store.isMutating {
            Section { ProgressView(store.isMutating ? "Waiting for Hermes confirmation" : "Loading pairing state") }
        }
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Refresh") { Task { await store.refresh() } }
                    .disabled(store.isLoading || store.isMutating)
            }
        }
        if let success = store.successMessage {
            Section { Label(success, systemImage: "checkmark.circle") }
        }
    }

    private func pending(_ requests: [HermesPairingPendingRequest]) -> some View {
        Section {
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.userName.isEmpty ? request.userID : request.userName).font(.bighelp(.headline))
                    LabeledContent("Platform", value: request.platform)
                    LabeledContent("User ID", value: request.userID)
                    LabeledContent("Waiting", value: "\(request.ageMinutes) min")
                    if request.canApproveByExactID {
                        Button("Approve") { store.review = .approve(request) }
                            .disabled(!store.canAct)
                            .frame(minHeight: BighelpTokens.hitTarget)
                    } else {
                        Text("This legacy request has no exact request ID and cannot be approved from bighelp.")
                            .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                    }
                }
            }
            if requests.isEmpty { Text("No pending pairing requests.").foregroundStyle(.secondary) }
            if !requests.isEmpty {
                Button("Clear All Pending", role: .destructive) {
                    store.review = .clearPending(requests.count)
                }
                .disabled(!store.canAct)
            }
        } header: { Text("Requests") }
    }

    private func approved(_ users: [HermesPairingApprovedUser]) -> some View {
        Section("People with access") {
            ForEach(users) { user in
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.userName.isEmpty ? user.userID : user.userName).font(.bighelp(.headline))
                    LabeledContent("Platform", value: user.platform)
                    LabeledContent("User ID", value: user.userID)
                    if let date = user.approvedAt { LabeledContent("Approved", value: date.formatted()) }
                    Button("Revoke", role: .destructive) { store.review = .revoke(user) }
                        .disabled(!store.canAct)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
            if users.isEmpty { Text("No approved users.").foregroundStyle(.secondary) }
        }
    }
}
