import SwiftUI

/// Native content in the normal app tabs. Shared HostSetupView owns onboarding.
struct DirectHermesWorkspaceView: View {
    @Bindable var store: DirectHermesWorkspaceStore
    @Environment(\.bighelpHostRegistry) private var hostRegistry
    var showsProfiles = false
    @State private var showsSupport = false
    @State private var searchText = ""

    var body: some View {
        searchPresentation {
            List {
            Section {
                LabeledContent("Status", value: store.isConnected ? "Connected" : store.status)
                    .accessibilityIdentifier("direct-hermes.status")
                DisclosureGroup("Advanced connection details") {
                    Text(store.address).bighelpFont(.metadata).foregroundStyle(.secondary)
                    Text(store.status).bighelpFont(.metadata)
                }
                if !store.isConnected {
                    Button("Reconnect to host", systemImage: "arrow.clockwise") { Task { await store.reconnect() } }
                        .disabled(store.isConnecting).accessibilityIdentifier("direct-hermes.reconnect")
                    if let hostRegistry, let host = hostRegistry.selectedHost {
                        Button("Sign in again") { hostRegistry.beginAuthentication(for: host) }
                            .accessibilityIdentifier("hosts.sign-in")
                    }
                }
                if store.isConnecting {
                    let connection = HostConnectionStatus(workspace: store)
                    BighelpConnectionPill(phase: connection.phase, label: connection.label)
                }
            } header: { Text("Connection") }
            Section(showsProfiles ? "Your agents" : "Chat with") {
                if showsProfiles {
                    ForEach(store.profiles.filter { searchText.isEmpty || $0.name.localizedStandardContains(searchText) }) { profile in
                        Button { store.selectedProfile = profile.id } label: {
                            HStack(spacing: 12) {
                                AvatarView(stableID: profile.id, displayName: profile.name, imageURL: nil, size: 56)
                                Text(profile.name).bighelpFont(.label)
                                Spacer()
                                if store.selectedProfile == profile.id {
                                    Image(systemName: "checkmark").accessibilityLabel("Selected")
                                }
                            }
                            .frame(minHeight: 56)
                        }
                        .accessibilityIdentifier("direct-hermes.profile.\(profile.id)")
                    }
                } else {
                    Picker("Agent", selection: $store.selectedProfile) {
                        ForEach(store.profiles) { profile in Text(profile.name).tag(profile.id) }
                    }.accessibilityIdentifier("direct-hermes.profile")
                }
                Button("New chat", systemImage: "square.and.pencil") { Task { await store.newChat() } }
                    .disabled(!store.isConnected || store.selectedProfile.isEmpty)
                    .accessibilityIdentifier("direct-hermes.new-chat")
            }
            if !showsProfiles {
                Section("Saved sessions") {
                    if store.isLoadingSessions { ProgressView("Loading Hermes sessions") }
                    if store.sessions.isEmpty && !store.isLoadingSessions {
                        Text(store.isConnected ? "No saved sessions in this profile." : "Reconnect to load saved sessions.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sessions) { session in
                        Button { Task { await store.openSession(session) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                Text(session.preview).bighelpFont(.metadata).foregroundStyle(.secondary).lineLimit(2)
                                if !session.supportsNativeResume {
                                    Text("Continue in its original \(session.source) surface").bighelpFont(.metadata).foregroundStyle(.secondary)
                                }
                            }.frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(!store.isConnected || !session.supportsNativeResume)
                        .accessibilityIdentifier("direct-hermes.session.\(session.storedID)")
                    }
                }
            }
            if !store.localRecovery.isEmpty {
                Section("Local recovery") {
                    NavigationLink("Drafts & retained submissions") { DirectHermesLocalRecoveryView(records: store.localRecovery) }
                }
            }
            Section("Advanced") {
                Button("Host support & limits") { showsSupport = true }
            }
            }
        }
        .bighelpFormSurface()
        .navigationTitle(showsProfiles ? "Agents" : "Sessions")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showsSupport) { DirectHermesSupportView().bighelpSheetSize(.standard) }
        .onChange(of: store.selectedProfile) { _, _ in Task { await store.loadSessions() } }
        .refreshable { if store.isConnected { await store.loadSessions() } else { await store.reconnect() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("direct-hermes.workspace")
    }

    @ViewBuilder
    private func searchPresentation<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if showsProfiles {
            content()
                .searchable(text: $searchText, prompt: "Search agents")
                .autocorrectionDisabled()
                .accessibilityIdentifier("agents.search")
        } else {
            content()
        }
    }
}

struct DirectHermesSupportView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Native Hermes") {
                    Text("Messages, reasoning, tools, subagents, profiles, and saved sessions come directly from Hermes.")
                    Text("Stop, steer, queued prompts, approvals, clarification, and commands use native requests. Acceptance does not prove a queued prompt or steer was consumed; review retained submissions after an interrupted connection.")
                }
                Section("Separate integrations") {
                    Text("Wiki, Cards and forms, phone tools, voice, project changes, and notifications need their own supported integrations. They are never silently forwarded through Link.")
                    Text("Standalone hosts do not yet expose attachments, full provider picking, multi-question clarification, or subagent control windows in bighelp. Hermes may support more than this client shows.")
                }
                Section("History & recovery") {
                    Text("Saved history can have tool summaries without live IDs or results and may be less detailed than the live stream. Local text and uncertain submissions stay bound to the exact account, host, and profile.")
                    Text("Reopening reattaches without resending prompts. If the runtime is gone, choose a saved session. \(BighelpPlatform.isMac ? "macOS" : "iOS") can suspend sockets; notifications require separate verified enrollment.")
                }
            }
            .navigationTitle("Host support")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A host without an activity feed must not masquerade as an empty inbox or
/// repeat the Chats screen under a different tab.
struct DirectHermesActivityView: View {
    let store: DirectHermesWorkspaceStore
    let onOpenChats: () -> Void

    var body: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label("Activity isn’t connected", systemImage: "clock")
                } description: {
                    Text("This host’s work and requests are available inside each chat. A combined activity feed isn’t available yet.")
                } actions: {
                    Button("Open chats", action: onOpenChats)
                }
                .listRowBackground(Color.clear)
            }
            if !store.localRecovery.isEmpty {
                Section("Needs review") {
                    NavigationLink {
                        DirectHermesLocalRecoveryView(records: store.localRecovery)
                    } label: {
                        Label("Drafts & retained submissions", systemImage: "doc.text")
                    }
                }
            }
        }
        .bighelpFormSurface()
        .accessibilityIdentifier("direct-hermes.activity")
    }
}
