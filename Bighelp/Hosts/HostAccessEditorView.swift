import SwiftUI

/// One editable custom header row.
struct HostCustomHeaderRow: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var value = ""

    static func rows(_ headers: [DirectHermesCustomHeader]) -> [HostCustomHeaderRow] {
        headers.map { HostCustomHeaderRow(name: $0.name, value: $0.value) }
    }

    static func headers(_ rows: [HostCustomHeaderRow]) throws -> [DirectHermesCustomHeader] {
        try DirectHermesCustomHeader.list(rows.map { ($0.name, $0.value) })
    }
}

/// Name and (masked) value pairs a reverse proxy asks for, like Pangolin's.
struct HostCustomHeaderFields: View {
    @Binding var rows: [HostCustomHeaderRow]
    @BighelpThemeReader private var theme

    var body: some View {
        ForEach($rows) { $row in
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack {
                    TextField("Header name, like X-Access-Id", text: $row.name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .bighelpFont(.code)
                        .accessibilityIdentifier("host-access.header-name")
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(theme.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(row.name.isEmpty ? "header" : row.name)")
                }
                SecureField("Value", text: $row.value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityIdentifier("host-access.header-value")
            }
        }
        Button("Add header", systemImage: "plus") { rows.append(HostCustomHeaderRow()) }
            .disabled(rows.count >= 16)
            .accessibilityIdentifier("host-access.add-header")
        Text("For a reverse proxy that checks its own headers, like Pangolin or an nginx rule. Bighelp sends them with every request and connection to this address only, and keeps them in Keychain.")
            .bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
    }
}

/// Change or remove what a saved host sends to get past a proxy or
/// Cloudflare Access. Saved on this device right away; the host reconnects.
struct HostAccessEditorView: View {
    enum Gate: String, CaseIterable, Identifiable {
        case none, cloudflareAccess, basic
        var id: Self { self }
        var title: String {
            switch self {
            case .none: "Nothing"
            case .cloudflareAccess: "Cloudflare Access"
            case .basic: "Username and password"
            }
        }
    }

    let endpoint: DirectHermesEndpoint
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var gate: Gate
    @State private var clientID: String
    @State private var clientSecret: String
    @State private var username: String
    @State private var password: String
    @State private var rows: [HostCustomHeaderRow]
    @State private var error: String?
    @State private var isRemoveConfirmationPresented = false
    @BighelpThemeReader private var theme

    init(endpoint: DirectHermesEndpoint, store: DirectHermesAccessCredentialStore = .shared,
         onSaved: @escaping () -> Void) {
        self.endpoint = endpoint
        self.onSaved = onSaved
        let saved = store.savedCredentials(for: endpoint)
        _gate = State(initialValue: saved.map { $0.kind == .basic ? .basic : .cloudflareAccess } ?? .none)
        _clientID = State(initialValue: saved?.kind == .cloudflareAccess ? saved?.clientID ?? "" : "")
        _clientSecret = State(initialValue: saved?.kind == .cloudflareAccess ? saved?.clientSecret ?? "" : "")
        _username = State(initialValue: saved?.kind == .basic ? saved?.clientID ?? "" : "")
        _password = State(initialValue: saved?.kind == .basic ? saved?.clientSecret ?? "" : "")
        _rows = State(initialValue: HostCustomHeaderRow.rows(store.savedCustomHeaders(for: endpoint)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Protection", selection: $gate) {
                        ForEach(Gate.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("host-access.gate")
                    switch gate {
                    case .none:
                        EmptyView()
                    case .cloudflareAccess:
                        TextField("Client ID", text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("host-access.cloudflare-client-id")
                        SecureField("Client secret", text: $clientSecret)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityIdentifier("host-access.cloudflare-client-secret")
                    case .basic:
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("host-access.username")
                        SecureField("Password", text: $password)
                            .privacySensitive()
                            .accessibilityIdentifier("host-access.password")
                    }
                } header: {
                    Text("In front of Hermes")
                } footer: {
                    Text(gate == .cloudflareAccess
                         ? "A Cloudflare Zero Trust service token, allowed by a Service Auth policy on this app."
                         : "What a proxy in front of Hermes asks for before Hermes's own sign-in.")
                }
                .listRowBackground(theme.surface)

                Section("Custom headers") {
                    HostCustomHeaderFields(rows: $rows)
                }
                .listRowBackground(theme.surface)

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.danger)
                            .accessibilityIdentifier("host-access.error")
                    }
                    .listRowBackground(theme.surface)
                }

                Section {
                    Button("Remove All", role: .destructive) { isRemoveConfirmationPresented = true }
                        .accessibilityIdentifier("host-access.remove-all")
                }
                .listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Connection access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("host-access.save")
                }
            }
            .confirmationDialog("Remove everything Bighelp sends to get past a proxy?",
                                isPresented: $isRemoveConfirmationPresented, titleVisibility: .visible) {
                Button("Remove All", role: .destructive) { apply(access: nil, headers: []) }
            } message: {
                Text("If a proxy or Cloudflare Access still protects this address, Bighelp won't be able to connect.")
            }
        }
    }

    private func save() {
        do {
            let headers = try HostCustomHeaderRow.headers(rows)
            let access: DirectHermesAccessCredentials?
            switch gate {
            case .none:
                access = nil
            case .cloudflareAccess:
                guard endpoint.baseURL.scheme == "https" else { throw HostSetupAccessError.needsHTTPS }
                access = try DirectHermesAccessCredentials(clientID: clientID, clientSecret: clientSecret)
            case .basic:
                guard let credentials = try? DirectHermesAccessCredentials(username: username, password: password)
                else { throw HostSetupAccessError.invalidProxyCredentials }
                guard credentials.canSend(to: endpoint) else { throw HostSetupAccessError.blockedBeforeSignIn }
                access = credentials
            }
            guard headers.isEmpty || DirectHermesAccessCredentialStore.mayCarrySecrets(endpoint) else {
                throw HostSetupAccessError.customHeadersNeedPrivateOrHTTPS
            }
            apply(access: access, headers: headers)
        } catch let problem as DirectHermesCustomHeader.Problem {
            error = problem.errorDescription
        } catch let problem as HostSetupAccessError {
            error = problem.errorDescription
        } catch {
            self.error = "Check the Client ID and secret: letters, numbers and symbols, no spaces."
        }
    }

    private func apply(access: DirectHermesAccessCredentials?, headers: [DirectHermesCustomHeader]) {
        do {
            try DirectHermesAccessCredentialStore.shared.replace(access: access, customHeaders: headers, for: endpoint)
            onSaved()
            dismiss()
        } catch {
            self.error = "Keychain couldn't save these. Try again."
        }
    }
}
