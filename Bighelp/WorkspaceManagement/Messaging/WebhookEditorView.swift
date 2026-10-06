import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class WebhookEditorStore {
    enum Review: Identifiable, Equatable {
        case enablePlatform
        case create(HermesWebhookDraft)
        case setEnabled(name: String, enabled: Bool)
        case delete(name: String)

        var id: String {
            switch self {
            case .enablePlatform: "enable-platform"
            case .create(let draft): "create:\(draft.name)"
            case .setEnabled(let name, let enabled): "toggle:\(name):\(enabled)"
            case .delete(let name): "delete:\(name)"
            }
        }

        var title: String {
            switch self {
            case .enablePlatform: "Enable webhooks?"
            case .create: "Create this webhook?"
            case .setEnabled(_, let enabled): enabled ? "Enable this webhook?" : "Disable this webhook?"
            case .delete: "Delete this webhook?"
            }
        }

        var actionTitle: String {
            switch self {
            case .enablePlatform: "Enable Webhooks"
            case .create: "Create Webhook"
            case .setEnabled(_, let enabled): enabled ? "Enable" : "Disable"
            case .delete: "Delete"
            }
        }

        var destructive: Bool {
            switch self {
            case .delete, .setEnabled(_, false): true
            default: false
            }
        }

        var message: String {
            switch self {
            case .enablePlatform:
                "Hermes will enable its host-wide webhook listener. A gateway restart may be required."
            case .create(let draft):
                "Create \(draft.name) on Hermes. Hermes will generate its signing secret and show it once."
            case .setEnabled(let name, let enabled):
                enabled ? "Allow \(name) to accept matching events again." : "Stop \(name) from accepting incoming events without deleting it."
            case .delete(let name):
                "Permanently delete \(name) from Hermes. Its current signing secret cannot be recovered."
            }
        }
    }

    let hostName: String
    private(set) var catalog: HermesWebhookCatalog?
    private(set) var creationReceipt: HermesWebhookCreationReceipt?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var isRetired = false
    var review: Review?

    @ObservationIgnored private let client: any HermesWebhooksManaging
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(
        hostName: String,
        client: any HermesWebhooksManaging,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { !isRetired && isCurrent() }
    var canAct: Bool { ownsScope && !isLoading && !isMutating && errorMessage == nil }

    func load() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let value = try await client.list()
            guard accepts(token) else { return }
            catalog = value
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == token else { return }
            errorMessage = Self.message(error)
        }
    }

    func refresh() async { await load() }

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
        defer { if generation == token { isMutating = false } }
        do {
            switch expected {
            case .enablePlatform:
                let updated = try await client.enablePlatform()
                guard accepts(token) else { return }
                catalog = updated
                successMessage = "Hermes confirmed the webhook platform is enabled."
            case .create(let draft):
                let receipt = try await client.create(draft)
                guard accepts(token) else { return }
                creationReceipt = receipt
                insert(receipt.subscription)
                successMessage = "Hermes confirmed the webhook was created. Save its one-time secret now."
            case .setEnabled(let name, let enabled):
                let updated = try await client.setEnabled(enabled, name: name)
                guard accepts(token) else { return }
                replace(updated)
                successMessage = "Hermes confirmed the webhook is \(enabled ? "enabled" : "disabled")."
            case .delete(let name):
                try await client.delete(name: name)
                guard accepts(token) else { return }
                remove(name)
                successMessage = "Hermes confirmed the webhook was deleted."
            }
            guard accepts(token) else { return }
        } catch is CancellationError {
            guard ownsScope, generation == token else { return }
            errorMessage = "The operation was interrupted. Refresh webhooks before trying again."
        } catch {
            guard ownsScope, generation == token else { return }
            errorMessage = Self.message(error)
        }
    }

    func discardCreationSecret() {
        creationReceipt = nil
    }

    func retire() {
        isRetired = true
        generation = UUID()
        catalog = nil
        creationReceipt = nil
        review = nil
        errorMessage = nil
        successMessage = nil
        isLoading = false
        isMutating = false
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private func insert(_ subscription: HermesWebhookSubscription) {
        guard let catalog else { return }
        var values = catalog.subscriptions.filter { !$0.name.utf8.elementsEqual(subscription.name.utf8) }
        values.append(subscription)
        values.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.catalog = .init(
            isPlatformEnabled: catalog.isPlatformEnabled,
            baseURL: catalog.baseURL,
            subscriptions: values
        )
    }

    private func replace(_ subscription: HermesWebhookSubscription) {
        guard let catalog,
              let index = catalog.subscriptions.firstIndex(where: {
                  $0.name.utf8.elementsEqual(subscription.name.utf8)
              }) else { return }
        var values = catalog.subscriptions
        values[index] = subscription
        self.catalog = .init(
            isPlatformEnabled: catalog.isPlatformEnabled,
            baseURL: catalog.baseURL,
            subscriptions: values
        )
    }

    private func remove(_ name: String) {
        guard let catalog else { return }
        self.catalog = .init(
            isPlatformEnabled: catalog.isPlatformEnabled,
            baseURL: catalog.baseURL,
            subscriptions: catalog.subscriptions.filter { !$0.name.utf8.elementsEqual(name.utf8) }
        )
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? WorkspaceClientError { return error.localizedDescription }
        return "Hermes could not complete the webhook request. Refresh its current state before trying again."
    }
}

@MainActor
struct WebhookEditorView: View {
    @Bindable var store: WebhookEditorStore
    @State private var presentsCreate = false
    @State private var search = ""

    var body: some View {
        Group {
            if store.ownsScope {
                List {
                    Section("Workspace") {
                        LabeledContent("Host", value: store.hostName)
                        Text("Webhooks are host-wide. Signing secrets remain on Hermes and are never included in this list.")
                            .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                    }
                    status
                    if let catalog = store.catalog {
                        if !ManagementSearch.isActive(search) { platform(catalog) }
                        subscriptions(catalog)
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $search, prompt: "Search webhooks")
                .refreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Workspace changed", systemImage: "arrow.triangle.branch",
                    description: Text("Return to Workspace and reopen Webhooks on the selected host.")
                )
            }
        }
        .navigationTitle("Webhooks")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.catalog == nil { await store.load() } }
        .bighelpSheet(isPresented: $presentsCreate) {
            NavigationStack {
                WebhookCreateForm { draft in
                    presentsCreate = false
                    store.review = .create(draft)
                }
            }
            .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: Binding(
            get: { store.creationReceipt != nil },
            set: { if !$0 { store.discardCreationSecret() } }
        )) {
            if let receipt = store.creationReceipt {
                NavigationStack {
                    WebhookSecretReceiptView(receipt: receipt) { store.discardCreationSecret() }
                }
                .interactiveDismissDisabled()
                .bighelpSheetSize(.standard)
            }
        }
        .confirmationDialog(
            store.review?.title ?? "Review webhook change",
            isPresented: Binding(
                get: { store.review != nil },
                set: { if !$0 { store.review = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let review = store.review {
                Button(review.actionTitle, role: review.destructive ? .destructive : nil) {
                    Task { await store.confirm(review) }
                }
                Button("Cancel", role: .cancel) { store.review = nil }
            }
        } message: {
            if let review = store.review { Text(review.message) }
        }
        .onChange(of: store.ownsScope) { _, current in if !current { store.retire() } }
        .accessibilityIdentifier("workspace.webhooks.native")
    }

    @ViewBuilder
    private var status: some View {
        if store.isLoading || store.isMutating {
            Section { ProgressView(store.isMutating ? "Waiting for Hermes confirmation" : "Loading webhooks") }
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

    private func platform(_ catalog: HermesWebhookCatalog) -> some View {
        Section("Status") {
            LabeledContent("Status", value: catalog.isPlatformEnabled ? "Enabled" : "Disabled")
            LabeledContent("Base URL", value: catalog.baseURL.absoluteString)
            if !catalog.isPlatformEnabled {
                Button("Review Enablement", systemImage: "power") { store.review = .enablePlatform }
                    .disabled(!store.canAct)
            } else {
                Button("Create Webhook", systemImage: "plus") { presentsCreate = true }
                    .disabled(!store.canAct)
                    .accessibilityIdentifier("webhooks.create")
            }
        }
    }

    private func subscriptions(_ catalog: HermesWebhookCatalog) -> some View {
        Section("Webhooks") {
            let shown = catalog.subscriptions.filter {
                ManagementSearch.matches(search, $0.name, $0.description, $0.events.joined(separator: " "))
            }
            if ManagementSearch.isActive(search), shown.isEmpty {
                ContentUnavailableView.search(text: search.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            ForEach(shown) { webhook in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(webhook.name).font(.bighelp(.headline))
                        Spacer()
                        Text(webhook.isEnabled ? "Enabled" : "Disabled")
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                    if !webhook.description.isEmpty { Text(webhook.description).foregroundStyle(.secondary) }
                    LabeledContent("Delivery", value: webhook.delivery.replacingOccurrences(of: "_", with: " ").capitalized)
                    LabeledContent("Signing secret", value: webhook.hasSecret ? "Configured" : "Not set")
                    if !webhook.events.isEmpty {
                        LabeledContent("Events", value: webhook.events.joined(separator: ", "))
                    }
                    Link("Webhook URL", destination: webhook.URL)
                    HStack {
                        Button(webhook.isEnabled ? "Disable" : "Enable") {
                            store.review = .setEnabled(name: webhook.name, enabled: !webhook.isEnabled)
                        }
                        .disabled(!store.canAct || (!catalog.isPlatformEnabled && !webhook.isEnabled))
                        Spacer()
                        Button("Delete", role: .destructive) { store.review = .delete(name: webhook.name) }
                            .disabled(!store.canAct)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
            if catalog.subscriptions.isEmpty {
                Text(catalog.isPlatformEnabled ? "No webhooks yet." : "Enable the platform before creating a webhook.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct WebhookCreateForm: View {
    let onSubmit: (HermesWebhookDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var events = ""
    @State private var prompt = ""
    @State private var skills = ""
    @State private var delivery: HermesWebhookDraft.Delivery = .log
    @State private var deliversWithoutAgent = false
    @State private var chatID = ""

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Description", text: $description, axis: .vertical)
                Text("Use lowercase letters, numbers, hyphens, or underscores. Existing names cannot be overwritten from bighelp.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
            Section("Events") {
                TextField("Events, comma separated", text: $events)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Prompt template", text: $prompt, axis: .vertical)
                    .lineLimit(3...10)
                TextField("Skills, comma separated", text: $skills)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("This native editor does not accept scripts or arbitrary API routes.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
            Section("Advanced · Delivery") {
                Picker("Destination", selection: $delivery) {
                    ForEach(HermesWebhookDraft.Delivery.allCases) { value in Text(value.title).tag(value) }
                }
                Toggle("Deliver without an agent run", isOn: $deliversWithoutAgent)
                    .disabled(delivery == .log)
                if delivery != .log && delivery != .origin {
                    TextField("Destination chat ID (optional)", text: $chatID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .navigationTitle("New Webhook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review") { submit() }
                    .disabled(!validName || (deliversWithoutAgent && delivery == .log))
            }
        }
        .onChange(of: delivery) { _, value in
            if value == .log { deliversWithoutAgent = false; chatID = "" }
            if value == .origin { chatID = "" }
        }
    }

    private var validName: Bool {
        guard let first = name.utf8.first,
              (48...57).contains(first) || (97...122).contains(first) else { return false }
        return !name.isEmpty && name.utf8.count <= 128 && name == name.lowercased()
            && name.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private func values(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func submit() {
        let draft = HermesWebhookDraft(
            name: name, description: description,
            events: values(events), prompt: prompt, skills: values(skills),
            delivery: delivery, deliversWithoutAgent: deliversWithoutAgent,
            deliveryChatID: chatID.isEmpty ? nil : chatID
        )
        prompt = ""
        chatID = ""
        onSubmit(draft)
    }
}

@MainActor
private struct WebhookSecretReceiptView: View {
    let receipt: HermesWebhookCreationReceipt
    let onDone: () -> Void

    var body: some View {
        List {
            Section("Webhook") {
                Label("Webhook created", systemImage: "checkmark.circle")
                LabeledContent("Name", value: receipt.subscription.name)
                LabeledContent("URL", value: receipt.subscription.URL.absoluteString)
            }
            Section("One-time signing secret") {
                Text(receipt.secret)
                    .font(.bighelp(.body).monospaced())
                    .textSelection(.enabled)
                    .privacySensitive()
                    .accessibilityLabel("Webhook signing secret")
                Text("Save this secret directly in the service that will send events. bighelp discards it when you close this sheet and cannot retrieve it again.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Save Signing Secret")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("I Saved It") { onDone() } }
        }
    }
}
