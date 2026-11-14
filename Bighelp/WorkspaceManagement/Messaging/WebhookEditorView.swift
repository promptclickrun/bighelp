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

    /// Runs a change the page already settled in its own way (a switch, its own dialog), without
    /// the review dialog.
    func run(_ change: Review) async {
        review = change
        await confirm(change)
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

/// Settings › Hermes tools › Webhooks: the host's listener, then its webhooks by state, each with
/// its switch. A webhook's name opens its page.
@MainActor
struct WebhookEditorView: View {
    @Bindable var store: WebhookEditorStore
    @State private var presentsCreate = false
    @State private var search = ""
    @State private var filter: HermesToolFilter = .all
    /// The webhook whose switch is changing, so only its row shows the new value.
    @State private var changing: HermesToolChange?
    @State private var opened: String?

    var body: some View {
        Group {
            if store.ownsScope {
                List {
                    HermesToolSearchSection(search: $search, prompt: String(localized: "Search webhooks"),
                                            searchIdentifier: "webhooks.search", filters: [.all, .on, .off],
                                            filter: $filter, filtersIdentifier: "webhooks.filters")
                    WebhookStatusSections(store: store, showsProgress: changing == nil)
                    if let catalog = store.catalog {
                        if !ManagementSearch.isActive(search), filter == .all { platform(catalog) }
                        subscriptions(catalog)
                    }
                    Section("Workspace") {
                        LabeledContent("Host", value: store.hostName)
                        Text("Webhooks are host-wide. Signing secrets remain on Hermes and are never included in this list.")
                            .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                    }
                }
                .bighelpFormSurface()
                .bighelpRefreshable { await store.refresh() }
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
        .navigationDestination(item: $opened) { name in
            WebhookDetailView(store: store, name: name)
        }
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

    @ViewBuilder
    private func subscriptions(_ catalog: HermesWebhookCatalog) -> some View {
        let shown = catalog.subscriptions.filter {
            ManagementSearch.matches(search, $0.name, $0.description, $0.events.joined(separator: " "))
                && filter.admits(isOn: $0.isEnabled)
        }
        if ManagementSearch.isActive(search), shown.isEmpty {
            ManagementSearchEmptySection(search: search)
        } else if catalog.subscriptions.isEmpty {
            Section {
                Text(catalog.isPlatformEnabled ? "No webhooks yet." : "Enable the platform before creating a webhook.")
                    .foregroundStyle(.secondary)
            }
        } else if shown.isEmpty {
            Section { Text("No webhooks match this filter.").foregroundStyle(.secondary) }
        }
        section(String(localized: "On"), shown.filter(\.isEnabled), catalog: catalog)
        section(String(localized: "Off"), shown.filter { !$0.isEnabled }, catalog: catalog)
    }

    @ViewBuilder
    private func section(_ title: String, _ webhooks: [HermesWebhookSubscription],
                         catalog: HermesWebhookCatalog) -> some View {
        if !webhooks.isEmpty {
            Section(HermesTools.heading(title, webhooks.count)) {
                ForEach(webhooks) { row($0, catalog: catalog) }
            }
        }
    }

    private func row(_ webhook: HermesWebhookSubscription, catalog: HermesWebhookCatalog) -> some View {
        HermesToolRow(art: HermesWebhookSubscription.art(webhook.name), name: webhook.name,
                      detail: webhook.summary, open: { opened = webhook.name }) {
            HermesToolSwitch(title: webhook.name, isOn: webhook.isEnabled,
                             pending: changing?.pending(for: webhook.id),
                             isLocked: !store.canAct || (!catalog.isPlatformEnabled && !webhook.isEnabled),
                             identifier: "webhooks.switch.\(webhook.name)") { set($0, webhook) }
        }
        .accessibilityIdentifier("webhooks.webhook.\(webhook.name)")
    }

    private func set(_ isOn: Bool, _ webhook: HermesWebhookSubscription) {
        guard changing == nil, store.canAct else { return }
        changing = HermesToolChange(id: webhook.id, isOn: isOn)
        Task {
            await store.run(.setEnabled(name: webhook.name, enabled: isOn))
            changing = nil
        }
    }
}

private extension HermesWebhookSubscription {
    /// Webhooks have no logo or topic: an incoming-arrow tile, its color by name.
    static func art(_ name: String) -> HermesToolArt {
        .symbol("arrow.down.right.circle", key: name)
    }

    /// The row's one line: its description, else the events it takes.
    var summary: String {
        if !description.isEmpty { return description }
        return events.isEmpty ? String(localized: "Takes every event") : events.joined(separator: ", ")
    }
}

/// Loading, waiting, the last error with Refresh, and the last confirmation, at the top of the
/// webhook pages. A switch's change shows on its row instead of here (`showsProgress`).
@MainActor
private struct WebhookStatusSections: View {
    let store: WebhookEditorStore
    var showsProgress = true

    var body: some View {
        if store.isLoading || (store.isMutating && showsProgress) {
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
}

/// One webhook: its switch, the events it takes, where it delivers, its address and Delete.
@MainActor
private struct WebhookDetailView: View {
    @Bindable var store: WebhookEditorStore
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    /// The new value while this page's switch is changing.
    @State private var changing: Bool?

    private var webhook: HermesWebhookSubscription? {
        store.catalog?.subscriptions.first { $0.name.utf8.elementsEqual(name.utf8) }
    }

    var body: some View {
        List {
            if let webhook {
                Section {
                    HermesToolHeader(art: HermesWebhookSubscription.art(webhook.name), name: webhook.name,
                                     summary: webhook.description)
                }
                WebhookStatusSections(store: store, showsProgress: changing == nil)
                Section {
                    HermesToolSwitch(title: String(localized: "Turned on"), isOn: webhook.isEnabled,
                                     pending: changing,
                                     isLocked: !store.canAct
                                        || (store.catalog?.isPlatformEnabled != true && !webhook.isEnabled),
                                     showsTitle: true, identifier: "webhooks.enabled") { set($0, webhook) }
                } footer: {
                    Text("Turned off, it stops taking events but keeps its settings.")
                }
                Section("Events") {
                    if webhook.events.isEmpty {
                        Text("Takes every event.").foregroundStyle(.secondary)
                    }
                    ForEach(webhook.events, id: \.self) { Text($0).font(.bighelp(.body).monospaced()) }
                }
                Section("Delivery") {
                    LabeledContent("Sends to", value: HermesTools.readable(webhook.delivery))
                    LabeledContent("Signing secret", value: webhook.hasSecret ? "Configured" : "Not set")
                    Link("Webhook URL", destination: webhook.URL)
                }
                if !webhook.skills.isEmpty {
                    Section("Advanced · Skills") {
                        ForEach(webhook.skills, id: \.self) { Text($0).font(.bighelp(.footnote).monospaced()) }
                    }
                }
                Section {
                    Button("Delete", role: .destructive) { confirmsDelete = true }
                        .disabled(!store.canAct)
                        .accessibilityIdentifier("webhooks.delete")
                }
            } else {
                ContentUnavailableView("Webhook unavailable", systemImage: "arrow.down.right.circle")
            }
        }
        .bighelpFormSurface()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(WebhookEditorStore.Review.delete(name: name).title,
                            isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.run(.delete(name: name))
                    if store.errorMessage == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WebhookEditorStore.Review.delete(name: name).message)
        }
    }

    private func set(_ isOn: Bool, _ webhook: HermesWebhookSubscription) {
        guard changing == nil, store.canAct else { return }
        changing = isOn
        Task {
            await store.run(.setEnabled(name: webhook.name, enabled: isOn))
            changing = nil
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
                Text("Use lowercase letters, numbers, hyphens, or underscores. Existing names cannot be overwritten from Bighelp.")
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
        .bighelpFormSurface()
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
                Text("Save this secret directly in the service that will send events. Bighelp discards it when you close this sheet and cannot retrieve it again.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Save Signing Secret")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("I Saved It") { onDone() } }
        }
    }
}
