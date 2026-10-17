import AuthenticationServices
import SwiftUI
import UIKit

/// Which provider's sign-in sheet is open. `client` names the host tool that
/// signs in (Claude Code, the Copilot CLI); nil when Hermes signs in itself.
struct ProviderSignInTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let logoID: String
    var client: String? = nil
}

/// What the sign-in sheet shows, whichever side runs the sign-in.
struct ProviderSignInProgress: Equatable {
    enum Step: Equatable {
        case starting
        /// Open the provider's page; device flows then wait, paste flows take the page's code.
        case waiting
        case finishing
        case connected(email: String?)
        case failed(String)
    }

    var step: Step
    var link: URL? = nil
    /// The code to enter on the provider's page (device flows).
    var code: String? = nil
    /// The provider's page shows a code to paste back here.
    var pastes = false
    var problem: String? = nil
}

/// A provider row: its logo, name and one line of status.
struct ProviderRowLabel: View {
    let logoID: String
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            AIProviderMarkView(providerID: logoID, providerName: name, context: .chatQuickChoice, size: 24)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.isDarkPalette ? Color(white: 0.16) : .white))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// Signing in to a provider account from the phone. Hermes, or the provider's
/// own tool on the host, runs the sign-in and saves the account; this shows the
/// code, opens the provider's page in the system sign-in sheet (with the phone's
/// saved logins), takes back a code the page shows, and closes once it's done.
struct ProviderSignInSheet: View {
    let store: ProviderAccountsStore
    let provider: ProviderSignInTarget

    @Environment(\.dismiss) private var dismiss
    @State private var browser = ProviderSignInBrowser()
    @State private var copiedCode: String?
    @State private var pastedCode = ""

    private var progress: ProviderSignInProgress { store.signInProgress(for: provider) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BighelpTokens.space20) {
                    AIProviderMarkView(providerID: provider.logoID, providerName: provider.name,
                                       context: .chatQuickChoice, size: 40)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.isDarkPalette ? Color(white: 0.16) : .white))
                        .accessibilityHidden(true)
                    Text("Sign in to \(provider.name)")
                        .font(.bighelp(.title2).weight(.bold))
                        .multilineTextAlignment(.center)
                    content
                }
                .padding(BighelpTokens.space20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(theme.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isConnected ? "Done" : "Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("providers.sign-in.close")
                        .bighelpToolbarText()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await store.startSignIn(provider) }
        .onChange(of: progress.code) { _, _ in copyCode() }
        .onChange(of: progress.step) { _, step in
            switch step {
            case .finishing, .connected, .failed:
                // The host has the answer: close the provider's page if it's still up.
                browser.finish()
            default:
                break
            }
            if case .connected = step {
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    dismiss()
                }
            }
        }
        .onDisappear { browser.finish() }
        .accessibilityIdentifier("providers.sign-in.sheet")
    }

    private var isConnected: Bool {
        if case .connected = progress.step { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch progress.step {
        case .starting:
            VStack(spacing: BighelpTokens.space8) {
                ProgressView()
                Text(provider.client.flatMap { $0 == "Hermes" ? nil : "Starting \($0) on \(store.hostName)…" }
                    ?? "Starting the sign-in…")
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("providers.sign-in.starting")
        case .waiting:
            waiting(progress)
        case .finishing:
            HStack(spacing: BighelpTokens.space8) {
                ProgressView()
                Text("Finishing sign-in…")
                    .foregroundStyle(theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("providers.sign-in.finishing")
        case .connected(let email):
            VStack(spacing: BighelpTokens.space8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(theme.success)
                Text("Connected")
                    .font(.bighelp(.headline))
                if let email {
                    Text(email).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("providers.sign-in.connected")
        case .failed(let message):
            VStack(spacing: BighelpTokens.space12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(theme.warning)
                Text(message)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("providers.sign-in.failure")
                Button("Try again") {
                    pastedCode = ""
                    copiedCode = nil
                    Task { await store.startSignIn(provider) }
                }
                .bighelpProminentButtonStyle()
                .disabled(store.isStartingSignIn)
                .accessibilityIdentifier("providers.sign-in.retry")
            }
        }
    }

    @ViewBuilder
    private func waiting(_ progress: ProviderSignInProgress) -> some View {
        if let code = progress.code {
            VStack(spacing: BighelpTokens.space8) {
                Text("Your code")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                Text(code)
                    .font(.bighelp(.largeTitle, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .privacySensitive()
                    .accessibilityLabel("Sign-in code \(code.map(String.init).joined(separator: " "))")
                    .accessibilityIdentifier("providers.sign-in.code")
                Button(copiedCode == code ? "Copied" : "Copy code",
                       systemImage: copiedCode == code ? "checkmark" : "doc.on.doc") {
                    copyCode()
                }
                .font(.bighelp(.subheadline))
            }
        }
        if let link = progress.link {
            Button {
                copyCode()
                browser.start(link)
            } label: {
                Text("Continue to \(link.host() ?? "sign in")")
                    .frame(maxWidth: .infinity)
            }
            .bighelpProminentButtonStyle()
            .controlSize(.large)
            .accessibilityIdentifier("providers.sign-in.continue")
        }
        if progress.pastes {
            pasteBack(progress)
        } else {
            HStack(spacing: BighelpTokens.space8) {
                ProgressView()
                Text("Waiting for you to approve…")
                    .foregroundStyle(theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("providers.sign-in.waiting")
            Text("Your code is copied. Paste it on the page if it asks, then approve. This finishes on its own.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func pasteBack(_ progress: ProviderSignInProgress) -> some View {
        Text("Sign in on the page, then copy the code it shows and come back here.")
            .font(.bighelp(.footnote))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
        PasteButton(payloadType: String.self) { strings in
            guard let code = strings.first else { return }
            Task { @MainActor in submit(code) }
        }
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("providers.sign-in.paste")
        SecureField("Or paste the code here", text: $pastedCode)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            .padding(BighelpTokens.space12)
            .background(theme.surface, in: .rect(cornerRadius: 12))
            .onSubmit { submit(pastedCode) }
            .accessibilityIdentifier("providers.oauth.completion-code")
        Button("Finish signing in") { submit(pastedCode) }
            .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || pastedCode.utf8.count > 16_384 || store.isBusy)
            .accessibilityIdentifier("providers.sign-in.finish")
        if let problem = progress.problem {
            Text(problem)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.warning)
                .multilineTextAlignment(.center)
        }
    }

    private func submit(_ code: String) {
        let submitted = code.trimmingCharacters(in: .whitespacesAndNewlines)
        pastedCode = ""
        guard !submitted.isEmpty, submitted.utf8.count <= 16_384 else { return }
        browser.finish()
        Task { await store.submitSignInCode(submitted, for: provider) }
    }

    private func copyCode() {
        guard let code = progress.code, !code.isEmpty else { return }
        UIPasteboard.general.string = code
        copiedCode = code
    }

    @BighelpThemeReader private var theme
}

/// The provider's sign-in page in the system sign-in sheet, which shares the
/// phone's Safari logins. There's no redirect back to bighelp: the sheet stays
/// until Hermes confirms the sign-in, then `finish` closes it. The Mac opens the
/// page in your default browser instead.
@MainActor
final class ProviderSignInBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// `onClose` runs when the person closes the page (never on the Mac, which opens the default
    /// browser; there the app's return to the front is the signal).
    func start(_ url: URL, onClose: (@MainActor @Sendable () -> Void)? = nil) {
        #if targetEnvironment(macCatalyst)
        UIApplication.shared.open(url)
        #else
        session?.cancel()
        // Its completion may come on another queue; @Sendable keeps it off the main actor.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { @Sendable _, _ in
            guard let onClose else { return }
            Task { @MainActor in onClose() }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
        #endif
    }

    func finish() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return active?.keyWindow ?? active?.windows.first ?? ASPresentationAnchor()
        }
    }
}

/// Connect a provider: accounts to sign in to and providers that take an API
/// key, without the ones already connected. A finished sign-in goes back to
/// the list, where the new provider now shows.
struct ProviderConnectView: View {
    let store: ProviderAccountsStore
    @State private var search = ""
    @State private var signingIn: ProviderSignInTarget?
    /// The sheet's account, kept past dismissal so closing can stop its sign-in.
    @State private var lastSignIn: ProviderSignInTarget?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            BighelpSearchField(text: $search, prompt: "Search providers",
                               accessibilityIdentifier: "providers.connect.search")
                .bighelpListSearchRow()
            if let overview = store.overview?.matching(search) {
                // A sign-in the provider stopped offering can't be connected; its replacement key is below.
                let signIns = overview.signIns.filter { if case .retired = $0.method { false } else { true } }
                if signIns.isEmpty && overview.keyChoices.isEmpty {
                    if search.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Every provider \(store.hostName) knows about is already connected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
                if !signIns.isEmpty {
                    Section {
                        ForEach(signIns) { row in signInRow(row) }
                    } header: {
                        Text("Sign in with an account")
                    } footer: {
                        Text("You approve on the provider's own page. bighelp never sees your password.")
                    }
                }
                if !overview.keyChoices.isEmpty {
                    Section("Use an API key") {
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
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Connect a provider")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpSheet(item: $signingIn, onDismiss: {
            guard let target = lastSignIn else { return }
            Task {
                await store.closeSignIn(target)
                if store.overview?.connected.contains(where: { $0.id == "account:\(target.id)" }) == true { dismiss() }
            }
        }) { provider in
            ProviderSignInSheet(store: store, provider: provider)
                .bighelpSheetSize(.standard)
        }
        .accessibilityIdentifier("providers.connect.screen")
    }

    @ViewBuilder
    private func signInRow(_ row: ProviderKeysOverview.SignIn) -> some View {
        switch row.method {
        case .onPhone:
            signInButtonRow(row, detail: row.problem ?? "Sign in here", client: nil)
        case .withHostTool(let client, _):
            signInButtonRow(row, detail: row.problem
                                ?? (client == "Hermes" ? "Sign in here" : "Uses \(client) on \(store.hostName)"),
                            client: client)
        case .needsTool(let client, let install, let command):
            NavigationLink {
                ProviderComputerSignInView(hostName: store.hostName, name: row.name, logoID: row.logoID,
                                           command: command, documentationURL: row.documentationURL,
                                           reason: .needsTool(client: client, install: install))
            } label: {
                ProviderRowLabel(logoID: row.logoID, name: row.name, detail: "Needs \(client) on \(store.hostName)")
            }
            .accessibilityIdentifier("providers.signin-row.\(row.id)")
        case .onComputer(let command):
            NavigationLink {
                ProviderComputerSignInView(hostName: store.hostName, name: row.name, logoID: row.logoID,
                                           command: command, documentationURL: row.documentationURL,
                                           reason: store.hostSignIn?.isSupported == true ? .terminalOnly : .pluginUpdate)
            } label: {
                ProviderRowLabel(logoID: row.logoID, name: row.name, detail: row.problem ?? "Sign in on \(store.hostName)")
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

    private func signInButtonRow(_ row: ProviderKeysOverview.SignIn, detail: String, client: String?) -> some View {
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
}

/// An account the phone can't sign in to on this host yet: what to run on the
/// computer, and why (the provider's tool is missing, or the plugin is older).
struct ProviderComputerSignInView: View {
    enum Reason: Equatable {
        /// Hermes and the plugin only sign in to it from a terminal.
        case terminalOnly
        /// A newer bighelp plugin signs in to it from the phone.
        case pluginUpdate
        /// The provider's sign-in tool isn't installed on the host.
        case needsTool(client: String, install: String?)
    }

    let hostName: String
    let name: String
    let logoID: String
    let command: String?
    let documentationURL: URL?
    var reason: Reason = .terminalOnly
    @State private var copied: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                ProviderRowLabel(logoID: logoID, name: name, detail: "Signs in on \(hostName)")
            } footer: {
                Text(explanation)
            }
            if case .needsTool(let client, let install?) = reason {
                commandSection(install, header: "Install \(client) on \(hostName)",
                               footer: "Then pull down on Provider Keys to refresh, and sign in from here.",
                               identifier: "providers.computer.install")
            } else if let command {
                commandSection(command, header: "In Terminal on \(hostName), run",
                               footer: "Follow what it asks, then pull down on Provider Keys to refresh.",
                               identifier: "providers.computer.command")
            }
            if let documentationURL {
                Section {
                    Button("\(name) help", systemImage: "arrow.up.right.square") { openURL(documentationURL) }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("providers.computer-sign-in")
    }

    private var explanation: String {
        switch reason {
        case .terminalOnly:
            "Hermes doesn't sign in to \(name) from \(BighelpPlatform.isMac ? "this Mac" : "the phone"). It takes one command on the computer running Hermes."
        case .pluginUpdate:
            "Update the bighelp plugin on \(hostName) to sign in to \(name) from your \(BighelpPlatform.isMac ? "Mac" : "phone"). Until then, it takes one command on the computer."
        case .needsTool(let client, _):
            "\(name) signs in with \(client), which isn't installed on \(hostName) yet. Once it is, you can sign in from here."
        }
    }

    private func commandSection(_ command: String, header: String, footer: String, identifier: String) -> some View {
        Section {
            Text(command)
                .font(.bighelp(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
            Button(copied == command ? "Copied" : "Copy command",
                   systemImage: copied == command ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = command
                copied = command
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }
}

/// A sign-in the provider has ended, and what to use instead.
struct ProviderRetiredSignInView: View {
    let store: ProviderAccountsStore
    let name: String
    let logoID: String
    let message: String
    let replacementKey: String?

    private var replacement: DirectHermesProviderCredential? {
        replacementKey.flatMap { key in store.snapshot?.credentials.first { $0.id == key } }
    }

    var body: some View {
        Form {
            Section {
                ProviderRowLabel(logoID: logoID, name: name, detail: "No longer offered")
            } footer: {
                Text(message)
                    .accessibilityIdentifier("providers.retired.message")
            }
            if let replacement {
                Section {
                    NavigationLink {
                        ProviderCredentialEditorView(store: store, credentialID: replacement.id)
                    } label: {
                        Label("Add a \(ProviderCredentialPresentation.title(replacement))", systemImage: "key")
                    }
                    .accessibilityIdentifier("providers.retired.add-key")
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("providers.retired-sign-in")
    }
}
