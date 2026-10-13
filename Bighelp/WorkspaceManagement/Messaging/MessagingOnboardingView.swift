import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

@MainActor
struct MessagingOnboardingView: View {
    @Bindable var store: MessagingOnboardingStore

    @State private var telegramBotName = ""
    @State private var telegramAllowedUsers = ""
    @State private var whatsAppMode: HermesWhatsAppOnboarding.Mode = .bot
    @State private var whatsAppAllowedUsers = ""
    @State private var confirmsApply = false
    @State private var confirmsCancel = false
    @State private var search = ""

    var body: some View {
        Group {
            if store.ownsScope {
                List {
                    Section("Workspace") {
                        LabeledContent("Host", value: store.hostName)
                        LabeledContent("Profile", value: store.profileID)
                    }
                    status
                    if let catalog = store.catalog {
                        if ManagementSearch.isActive(search) {
                            let platforms = catalog.platforms.filter {
                                ManagementSearch.matches(search, $0.name, $0.description)
                            }
                            if platforms.isEmpty {
                                ManagementSearchEmptySection(search: search)
                            } else {
                                platformSection(platforms)
                            }
                        } else {
                            platformSection(catalog.platforms)
                            onboardingSection
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $search, prompt: "Search platforms")
                .bighelpRefreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Workspace changed",
                    systemImage: "network.slash",
                    description: Text("Return to Workspace and reopen Messaging on the selected host.")
                )
            }
        }
        .navigationTitle("Messaging")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.catalog == nil { await store.load() } }
        .task(id: store.onboarding?.pairingID) {
            while !Task.isCancelled, store.ownsScope,
                  let onboarding = store.onboarding, !onboarding.canApply, !onboarding.isTerminal {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await store.pollOnboarding()
            }
        }
        .confirmationDialog("Finish messaging setup?", isPresented: $confirmsApply) {
            Button("Apply to Hermes") { applyOnboarding() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will save this platform configuration for the selected profile. Its gateway may need to restart before messages connect.")
        }
        .confirmationDialog("Cancel this setup?", isPresented: $confirmsCancel) {
            Button("Cancel Setup", role: .destructive) { Task { await store.cancelOnboarding() } }
            Button("Keep Setup", role: .cancel) {}
        } message: {
            Text("The current pairing session will be revoked. No saved platform configuration will be removed.")
        }
        .onChange(of: store.onboarding) { _, current in
            if case .telegram(let value) = current,
               telegramAllowedUsers.isEmpty,
               let owner = value.ownerUserID {
                telegramAllowedUsers = owner
            }
            if case .whatsApp(let value) = current {
                whatsAppMode = value.mode
                if whatsAppAllowedUsers.isEmpty { whatsAppAllowedUsers = value.allowedUsers }
            }
        }
        .onChange(of: store.ownsScope) { _, current in
            if !current { store.retire() }
        }
        .accessibilityIdentifier("workspace.messaging")
    }

    @ViewBuilder
    private var status: some View {
        if store.isLoading || store.isMutating {
            Section { ProgressView(store.isMutating ? "Waiting for Hermes confirmation" : "Loading messaging platforms") }
        }
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh") { Task { await store.refresh() } }
                    .disabled(!store.canAct)
            }
            .accessibilityIdentifier("messaging.error")
        }
        if let success = store.successMessage {
            Section { Label(success, systemImage: "checkmark.circle") }
                .accessibilityIdentifier("messaging.confirmed")
        }
        if let test = store.latestTest {
            Section("Connection test") {
                Label(test.message, systemImage: test.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                LabeledContent("Host state", value: test.state.replacingOccurrences(of: "_", with: " ").capitalized)
            }
        }
    }

    private func platformSection(_ platforms: [HermesMessagingPlatform]) -> some View {
        Section("Platforms") {
            ForEach(platforms) { platform in
                NavigationLink {
                    MessagingPlatformConfigurationView(store: store, platformID: platform.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(platform.name)
                            Spacer()
                            Text(platform.isEnabled ? "Enabled" : "Disabled")
                                .font(.bighelp(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Text(platform.description)
                            .font(.bighelp(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
        }
    }

    @ViewBuilder
    private var onboardingSection: some View {
        if let onboarding = store.onboarding {
            Section("Setup in progress") {
                switch onboarding {
                case .telegram(let value): telegramOnboarding(value)
                case .whatsApp(let value): whatsAppOnboarding(value)
                }
                if onboarding.canApply {
                    Button("Review & Apply", systemImage: "checkmark.circle") { confirmsApply = true }
                        .disabled(!store.canAct || !hasValidApplyInput(onboarding))
                        .accessibilityIdentifier("messaging.onboarding.apply")
                }
                if onboarding.isTerminal {
                    Button("Dismiss") { store.dismissTerminalOnboarding() }
                } else {
                    Button("Cancel Setup", role: .destructive) { confirmsCancel = true }
                        .disabled(!store.canAct)
                }
            }
        } else {
            Section("Telegram") {
                TextField("Telegram bot name (optional)", text: $telegramBotName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("messaging.telegram.bot-name")
                Button("Start Telegram Setup", systemImage: "paperplane") {
                    let name = telegramBotName.trimmingCharacters(in: .whitespacesAndNewlines)
                    telegramBotName = ""
                    Task { await store.startTelegram(botName: name.isEmpty ? nil : name) }
                }
                .disabled(!store.canAct)
            }
            Section("WhatsApp") {
                Picker("WhatsApp mode", selection: $whatsAppMode) {
                    ForEach(HermesWhatsAppOnboarding.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                TextField("Allowed WhatsApp users (optional)", text: $whatsAppAllowedUsers)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Start WhatsApp Setup", systemImage: "qrcode") {
                    Task { await store.startWhatsApp(mode: whatsAppMode, allowedUsers: whatsAppAllowedUsers) }
                }
                .disabled(!store.canAct)
            }
            Section("About setup") {
                Text("Messaging pairing is managed by Hermes. It is separate from bighelp notification registration.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func telegramOnboarding(_ value: HermesTelegramOnboarding) -> some View {
        LabeledContent("Platform", value: "Telegram")
        LabeledContent("Status", value: value.status.capitalized)
        if let username = value.botUsername ?? value.suggestedUsername, !username.isEmpty {
            LabeledContent("Bot", value: username)
        }
        if let payload = value.qrPayload {
            MessagingQRCodeView(payload: payload, accessibilityLabel: "Telegram setup QR code")
                .privacySensitive()
        }
        if let link = value.deepLink {
            Link("Open Telegram Setup", destination: link)
        }
        if value.status == "ready" {
            TextField("Allowed Telegram user IDs", text: $telegramAllowedUsers)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("messaging.telegram.allowed-users")
            Text("Enter numeric user IDs separated by commas. The connected owner's ID is suggested when Hermes reports it.")
                .font(.bighelp(.footnote)).foregroundStyle(.secondary)
        }
        if !value.expiresAt.isEmpty {
            LabeledContent("Expires", value: value.expiresAt)
        }
    }

    @ViewBuilder
    private func whatsAppOnboarding(_ value: HermesWhatsAppOnboarding) -> some View {
        LabeledContent("Platform", value: "WhatsApp")
        LabeledContent("Status", value: value.status.capitalized)
        if let account = value.accountName ?? value.accountPhone ?? value.accountID {
            LabeledContent("Connected account", value: account)
        }
        if let payload = value.qrPayload {
            MessagingQRCodeView(payload: payload, accessibilityLabel: "WhatsApp setup QR code")
                .privacySensitive()
        }
        if let error = value.errorMessage { Label(error, systemImage: "exclamationmark.triangle") }
        if value.status == "connected" {
            Picker("Mode", selection: $whatsAppMode) {
                ForEach(HermesWhatsAppOnboarding.Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            TextField("Allowed users", text: $whatsAppAllowedUsers)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        if !value.expiresAt.isEmpty { LabeledContent("Expires", value: value.expiresAt) }
    }

    private func hasValidApplyInput(_ onboarding: MessagingOnboardingStore.Onboarding) -> Bool {
        switch onboarding {
        case .telegram:
            return !telegramUserIDs.isEmpty
        case .whatsApp:
            return true
        }
    }

    private var telegramUserIDs: [String] {
        telegramAllowedUsers.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func applyOnboarding() {
        switch store.onboarding {
        case .telegram:
            let values = telegramUserIDs
            telegramAllowedUsers = ""
            Task { await store.applyTelegram(allowedUserIDs: values) }
        case .whatsApp:
            let values = whatsAppAllowedUsers
            Task { await store.applyWhatsApp(mode: whatsAppMode, allowedUsers: values) }
        case nil:
            break
        }
    }
}

@MainActor
private struct MessagingPlatformConfigurationView: View {
    let store: MessagingOnboardingStore
    let platformID: String

    @State private var desiredEnabled: Bool?
    @State private var replacements: [String: String] = [:]
    @State private var clears: Set<String> = []
    @State private var confirmsSave = false

    private var platform: HermesMessagingPlatform? { store.platform(id: platformID) }

    var body: some View {
        List {
            if let platform {
                Section("Status") {
                    Text(platform.description)
                    LabeledContent("Configuration", value: platform.isConfigured ? "Complete" : "Incomplete")
                    LabeledContent("Gateway", value: platform.isGatewayRunning ? "Running" : "Stopped")
                    LabeledContent("Connection", value: platform.state.replacingOccurrences(of: "_", with: " ").capitalized)
                    if let message = platform.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                    }
                    if let URL = platform.documentationURL { Link("Setup documentation", destination: URL) }
                    if let URL = platform.ingressURL { LabeledContent("Ingress", value: URL.absoluteString) }
                }
                Section("Settings") {
                    Toggle("Enabled", isOn: Binding(
                        get: { desiredEnabled ?? platform.isEnabled },
                        set: { desiredEnabled = $0 }
                    ))
                    ForEach(platform.environment) { field in
                        VStack(alignment: .leading, spacing: 8) {
                            if field.isSecret {
                                SecureField(field.label, text: replacement(field.key))
                                    .textContentType(.password)
                                    .privacySensitive()
                            } else {
                                TextField(field.label, text: replacement(field.key))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            HStack {
                                Text(field.isSet ? "Saved on Hermes" : field.isRequired ? "Required" : "Not set")
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                Spacer()
                                if field.isSet {
                                    Button(clears.contains(field.key) ? "Keep" : "Clear", role: clears.contains(field.key) ? nil : .destructive) {
                                        if clears.contains(field.key) { clears.remove(field.key) }
                                        else { clears.insert(field.key); replacements[field.key] = nil }
                                    }
                                }
                            }
                            if !field.description.isEmpty { Text(field.description).font(.bighelp(.footnote)).foregroundStyle(.secondary) }
                            if let URL = field.documentationURL { Link("Field documentation", destination: URL).font(.bighelp(.footnote)) }
                        }
                    }
                    Button("Review Changes") { confirmsSave = true }
                        .disabled(!store.canAct || !hasChanges(platform))
                        .accessibilityIdentifier("messaging.platform.review")
                }
                Section("Connection") {
                    Button("Test Connection", systemImage: "checkmark.arrow.trianglehead.counterclockwise") {
                        Task { await store.testPlatform(id: platform.id) }
                    }
                    .disabled(!store.canAct)
                }
            } else {
                ContentUnavailableView("Platform unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            }
        }
        .navigationTitle(platform?.name ?? "Messaging")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Apply messaging changes?", isPresented: $confirmsSave) {
            Button("Apply to Hermes") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the listed fields are sent to this Hermes profile. Stored secret values are never read back into bighelp.")
        }
        .onDisappear {
            replacements.removeAll(keepingCapacity: false)
            clears.removeAll(keepingCapacity: false)
        }
    }

    private func replacement(_ key: String) -> Binding<String> {
        Binding(
            get: { replacements[key] ?? "" },
            set: { value in
                replacements[key] = value
                clears.remove(key)
            }
        )
    }

    private func hasChanges(_ platform: HermesMessagingPlatform) -> Bool {
        desiredEnabled.map { $0 != platform.isEnabled } == true
            || replacements.values.contains(where: { !$0.isEmpty })
            || !clears.isEmpty
    }

    private func save() {
        guard let platform else { return }
        let values = replacements.filter { !$0.value.isEmpty }
        let clear = Array(clears)
        let enabled = desiredEnabled.flatMap { $0 == platform.isEnabled ? nil : $0 }
        replacements.removeAll(keepingCapacity: false)
        clears.removeAll(keepingCapacity: false)
        desiredEnabled = nil
        Task {
            await store.updatePlatform(id: platform.id, enabled: enabled, replacements: values, clear: clear)
        }
    }
}

private struct MessagingQRCodeView: View {
    let payload: String
    let accessibilityLabel: String

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, minHeight: 160)
                    .accessibilityLabel(accessibilityLabel)
            } else {
                Label("QR code unavailable", systemImage: "qrcode")
            }
        }
        .frame(maxWidth: .infinity)
    }
}
