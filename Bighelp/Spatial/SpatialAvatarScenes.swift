#if os(visionOS)
import RealityKit
import SwiftUI

/// The values every bighelp window reads, for scenes outside the main window.
struct SpatialSceneEnvironment: ViewModifier {
    let settings: SettingsStore
    let companion: CompanionStore
    let companionAgentScope: String

    func body(content: Content) -> some View {
        content
            .environment(\.appAppearance, settings.appearanceContext)
            .environment(\.companionStore, companion)
            .environment(\.companionAgentScope, companionAgentScope)
            .environment(\.bighelpUIV2Enabled, settings.uiV2Enabled)
            .environment(\.bighelpUIV3Enabled, settings.interfaceVersion == .v3)
            .environment(\.nerdModeEnabled, settings.nerdModeEnabled)
    }
}

/// Your agent standing in the room, in its own volume so it stays put while
/// you use other apps. Look at it and pinch to talk or type (Settings
/// decides); pinch and hold for how to move and anchor it.
struct SpatialAvatarVolume: View {
    @Bindable var model: SpatialAvatarModel
    let settings: SettingsStore
    let permissionCenter: PermissionCenter

    @Environment(\.openWindow) private var openWindow
    @Environment(\.surfaceSnappingInfo) private var snapping
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme
    @State private var facing: SquareAzimuth = .front
    @FocusState private var isPromptFocused: Bool
    @State private var rig = SpatialAvatarRig()
    @State private var spin = Self.demoSpin
    @State private var spinAtDragStart = Self.demoSpin
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope
    @Environment(\.physicalMetrics) private var metrics

    @AppStorage(SpatialAvatarVolumeSize.key) private var rememberedScale = 1.0

    /// The agent's space at the volume's default size; it grows and shrinks with the volume.
    static let avatarSize: CGFloat = 300

    /// "-test-spatial-avatar-spin 0.7" (demo only) starts it turned, so screenshots show its depth.
    private static var demoSpin: Float {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-use-demo-fixtures"),
              let index = arguments.firstIndex(of: "-test-spatial-avatar-spin"),
              arguments.indices.contains(index + 1) else { return 0 }
        return Float(arguments[index + 1]) ?? 0
    }

    var body: some View {
        // Width and height are enough; a 3D reader would push the flat parts to the back.
        GeometryReader { proxy in
            stage(scale: scale(for: proxy.size))
        }
        // The volume can be this much smaller or bigger; its corners resize it.
        // Depth has to be able to change too, or visionOS locks the size.
        .frame(minWidth: points(SpatialAvatarVolumeSize.width * SpatialAvatarVolumeSize.smallest),
               maxWidth: points(SpatialAvatarVolumeSize.width * SpatialAvatarVolumeSize.largest),
               minHeight: points(SpatialAvatarVolumeSize.height * SpatialAvatarVolumeSize.smallest),
               maxHeight: points(SpatialAvatarVolumeSize.height * SpatialAvatarVolumeSize.largest))
        .frame(minDepth: points(SpatialAvatarVolumeSize.depth * SpatialAvatarVolumeSize.smallest),
               maxDepth: points(SpatialAvatarVolumeSize.depth * SpatialAvatarVolumeSize.largest))
        // Turn to face you as you walk around it. The system's floor guide shows
        // when you look near it, so the volume's edges are easy to find and grab.
        .rotation3DEffect(facing.orientation)
        .volumeBaseplateVisibility(.automatic)
        .supportedVolumeViewpoints(.all)
        .onVolumeViewpointChange { _, viewpoint in
            withAnimation(reduceMotion ? nil : .smooth) { facing = viewpoint.squareAzimuth }
        }
        .ornament(visibility: model.isPromptPresented ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottomFront), contentAlignment: .top) {
            promptBar
        }
        // Voice sits on the agent's own volume, just to its right, and moves with it.
        // A separate window landed low and tilted, nearly edge-on, until the volume moved.
        // Its bottom lines up with the agent's base, so End stays at the agent's level.
        .ornament(visibility: model.voice == nil ? .hidden : .visible,
                  attachmentAnchor: .scene(.bottomTrailingFront), contentAlignment: .bottomLeading) {
            voicePanel
        }
        .animation(reduceMotion ? nil : .snappy, value: model.isPromptPresented)
        .animation(reduceMotion ? nil : .snappy, value: model.voice?.id)
        .animation(reduceMotion ? nil : .snappy, value: model.reply)
        .task { await model.connectIfNeeded() }
        .task(id: model.isShowingMoveTip) {
            guard model.isShowingMoveTip else { return }
            try? await Task.sleep(for: .seconds(6))
            model.isShowingMoveTip = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spatial-avatar")
    }

    /// People resize the volume from its corners; the agent keeps its proportions.
    private func scale(for size: CGSize) -> CGFloat {
        let scale = min(size.width / points(SpatialAvatarVolumeSize.width),
                        size.height / points(SpatialAvatarVolumeSize.height))
        return SpatialAvatarVolumeSize.clamped(scale)
    }

    private func points(_ meters: Double) -> CGFloat {
        metrics.convert(CGFloat(meters), from: .meters)
    }

    private func stage(scale: CGFloat) -> some View {
        VStack(spacing: BighelpTokens.space16) {
            avatar(scale: scale)
            statusChip
            if !model.isMainWindowOpen {
                // Simple mode: the way back to the whole app.
                Button("Open bighelp", systemImage: "macwindow") {
                    openWindow(id: SpatialAvatarSceneID.main)
                }
                .font(.bighelp(.callout))
                .accessibilityIdentifier("spatial-avatar.open-app")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay(alignment: .top) { topCard }
        // Opens at the size it had last time.
        .onChange(of: scale) { _, scale in rememberedScale = Double(scale) }
    }

    // MARK: Avatar

    private func avatar(scale: CGFloat) -> some View {
        let size = Self.avatarSize * scale
        // Feet on the bottom edge of its space, so the name under it stays in view.
        let floor = -Float(metrics.convert(size * 1.15, to: .meters)) / 2
        return ZStack {
            RealityView { content in
                content.add(rig.root)
                rig.updates = content.subscribe(to: SceneEvents.Update.self) { [rig] _ in rig.update() }
            } update: { _ in
                rig.root.position = [0, floor, 0]
                rig.root.scale = SIMD3(repeating: Float(scale))
                rig.show(look)
                rig.mood = mood
                rig.reduceMotion = reduceMotion
                rig.root.orientation = simd_quatf(angle: spin, axis: [0, 1, 0])
            }
            .allowsHitTesting(false)
            // Taps, holds and drags land on the space it stands in, which is
            // bigger than its outline and so easier to pinch. Vision Pro only
            // targets what's drawn, so this can't be fully clear.
            Color.white.opacity(0.001)
        }
        .frame(width: size, height: size * 1.15)
        .onTapGesture(perform: poked)
        .onLongPressGesture(minimumDuration: 0.6) { model.isShowingMoveTip = true }
        // Alongside, so a pinch that moves a little still counts as a tap.
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { turn(by: $0.translation.width) }
            .onEnded { _ in spinAtDragStart = spin })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.agent?.name ?? "Your agent")
        .accessibilityValue(model.activity.label)
        .accessibilityHint(settings.spatialAvatarPinchAction == .talk ? "Starts talking" : "Opens a message box")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, pinch)
        .accessibilityIdentifier("spatial-avatar.avatar")
    }

    /// A pinch: a happy hop, then talk or type.
    private func poked() {
        rig.poke()
        pinch()
    }

    /// Dragging sideways turns it around.
    private func turn(by width: CGFloat) {
        spin = spinAtDragStart + Float(width) * 0.012
    }

    /// The Agent Studio look being tried on, or the agent's own.
    private var appearance: CompanionAppearance? {
        if let preview = model.previewAppearance { return preview }
        guard let companionStore, !companionAgentScope.isEmpty else { return nil }
        return companionStore.override(for: CompanionStore.agentKey(agentScope: companionAgentScope,
                                                                    agentID: model.agent?.id ?? "agent"))
    }

    /// The agent's own look: its kit character, the default body, or its picture.
    private var look: SpatialAvatarLook {
        let agentID = model.agent?.id ?? "agent"
        if let appearance, let look = SpatialAvatarLook(appearance: appearance, themeHex: theme.actionHex) {
            return look
        }
        if let url = model.agent?.imageURL, FileManager.default.fileExists(atPath: url.bighelpFileSystemPath) {
            return .photo(url)
        }
        let persona = AgentPersona(stableID: agentID)
        return .persona(colorHex: persona.colorHex, isOrb: persona.body == .orb)
    }

    /// What it acts out: the agent's work, listening, or its chosen moves.
    private var mood: String? {
        if model.activity != .idle { return model.activity.moodID }
        if model.restingState == .listening { return "listening" }
        return appearance?.vibe?.moodID
    }

    private var statusChip: some View {
        HStack(spacing: BighelpTokens.space8) {
            if snapping.isSnapped {
                Image(systemName: "pin.fill")
                    .accessibilityLabel("Anchored")
            }
            if let name = model.agent?.name {
                Text(name).fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
            }
            if let connection = HostConnectionStatus(spatial: model.connection) {
                BighelpConnectionIndicator(phase: connection.phase)
            }
            Text(model.status(pinch: settings.spatialAvatarPinchAction))
                .foregroundStyle(.secondary)
        }
        .font(.bighelp(.callout))
        .lineLimit(1)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .glassBackgroundEffect(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spatial-avatar.status")
    }

    // MARK: Reply, tip and errors

    @ViewBuilder
    private var topCard: some View {
        if model.isShowingMoveTip {
            card {
                Label {
                    Text("Pinch and hold the bar under me, then drag to move me. Let go near a table and I'll stay anchored there.")
                } icon: {
                    Image(systemName: "hand.pinch")
                }
                .font(.bighelp(.callout))
            }
            .accessibilityIdentifier("spatial-avatar.move-tip")
        } else if let message = model.errorMessage {
            card {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.callout))
            }
            .accessibilityIdentifier("spatial-avatar.error")
        } else if let reply = model.reply {
            card {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    // A glance; Open chat has the whole answer.
                    Text(reply)
                        .font(.bighelp(.body))
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("spatial-avatar.reply.text")
                    HStack {
                        Button("Open chat", systemImage: "bubble.left.and.bubble.right", action: openChat)
                            .accessibilityIdentifier("spatial-avatar.reply.open")
                        Spacer()
                        Button("Done", systemImage: "checkmark") { model.dismissReply() }
                            .accessibilityIdentifier("spatial-avatar.reply.done")
                    }
                    .font(.bighelp(.callout))
                    .buttonStyle(.borderless)
                }
            }
            .accessibilityIdentifier("spatial-avatar.reply")
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(BighelpTokens.space16)
            .frame(maxWidth: 420, alignment: .leading)
            .glassBackgroundEffect(in: .rect(cornerRadius: 24))
            .offset(z: 24)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
    }

    // MARK: Typing

    private var promptBar: some View {
        HStack(alignment: .bottom, spacing: BighelpTokens.space12) {
            TextField("Message \(model.agent?.name ?? "your agent")", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($isPromptFocused)
                .onSubmit(send)
                .submitLabel(.send)
                .accessibilityIdentifier("spatial-avatar.prompt.field")
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSubmitting)
                .accessibilityIdentifier("spatial-avatar.prompt.send")
            Button("Close", systemImage: "xmark") {
                model.isPromptPresented = false
                isPromptFocused = false
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("spatial-avatar.prompt.close")
        }
        .padding(BighelpTokens.space12)
        .frame(width: 520)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spatial-avatar.prompt")
    }

    // MARK: Actions

    private func pinch() {
        switch model.pinch(settings.spatialAvatarPinchAction) {
        case .prompt:
            isPromptFocused = true
        case .voice:
            Task { _ = await model.startVoice(settings) }
        case .retrying:
            Task { await model.connectIfNeeded() }
        }
    }

    private func send() {
        isPromptFocused = false
        Task { await model.send() }
    }

    private func openChat() {
        guard model.openConversation() else { return }
        model.dismissReply()
        // Brings the main window back if it was closed; the chat is already selected.
        if !model.isMainWindowOpen { openWindow(id: SpatialAvatarSceneID.main) }
    }

    // MARK: Voice

    /// The same voice screen as in a chat, so both voice modes behave the same.
    @ViewBuilder private var voicePanel: some View {
        if let voice = model.voice {
            VoicePresentationContainer(
                presentation: voice,
                agentID: model.agent?.id,
                agentImageURL: model.agent?.imageURL,
                permissionCenter: permissionCenter,
                onEnded: { model.endVoice() },
                onWorkspaceTap: openChat,
                onUseTurnBased: useTurnBasedVoice,
                chatActivity: { model.activity }
            )
            .id(voice.id)
            .frame(width: 360, height: 500)
            .glassBackgroundEffect(in: .rect(cornerRadius: 32))
        }
    }

    private func useTurnBasedVoice() {
        settings.useTurnBasedVoice(computer: model.voiceComputer, agentID: model.agent?.id)
        model.endVoice()
        Task { _ = await model.startVoice(settings) }
    }
}

/// Hooks on the main window: Settings and the menu find the avatar, and the
/// avatar knows whether it must offer to reopen this window. The avatar never
/// opens by itself; the person chooses it (☰ › Simple mode, or Settings).
struct SpatialAvatarMainWindowHooks: ViewModifier {
    let model: SpatialAvatarModel

    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .environment(\.spatialAvatar, model)
            .onAppear { model.isMainWindowOpen = true }
            .onDisappear { model.isMainWindowOpen = false }
            // Close only once the avatar is up: closing in the same moment it opens is ignored.
            .onChange(of: model.entersSimpleMode && model.isVolumeOpen) { _, ready in
                guard ready else { return }
                model.entersSimpleMode = false
                dismissWindow()
            }
    }
}

/// Simple mode: just your agent in the room. bighelp's window closes, and the
/// avatar's Open bighelp button brings it back. bighelp always starts in its
/// own window (the avatar scenes are never launched or restored on their own).
@MainActor
enum SpatialSimpleMode {
    static func enter(_ model: SpatialAvatarModel?, openWindow: OpenWindowAction) {
        model?.entersSimpleMode = true
        openWindow(id: SpatialAvatarSceneID.avatar)
    }
}

/// The avatar volume's default size, in meters, and how far people can resize it.
enum SpatialAvatarVolumeSize {
    static let key = "bighelp.spatial-avatar.size"
    static let width = 0.36
    static let height = 0.44
    static let depth = 0.28
    /// Half to three times the default size.
    static let smallest = 0.5
    static let largest = 3.0

    static func clamped<Scale: BinaryFloatingPoint>(_ scale: Scale) -> Scale {
        guard scale.isFinite else { return 1 }
        return min(max(scale, Scale(smallest)), Scale(largest))
    }
}

/// The avatar's volume, next to the main window. Its voice panel is attached to it.
struct SpatialAvatarScenes: SwiftUI.Scene {
    let model: SpatialAvatarModel
    let settings: SettingsStore
    let companion: CompanionStore
    let companionAgentScope: String
    let permissionCenter: PermissionCenter

    @AppStorage(SpatialAvatarVolumeSize.key) private var avatarScale = 1.0

    private var volumeScale: Double { SpatialAvatarVolumeSize.clamped(avatarScale) }

    var body: some SwiftUI.Scene {
        WindowGroup(id: SpatialAvatarSceneID.avatar) {
            SpatialAvatarVolume(model: model, settings: settings, permissionCenter: permissionCenter)
                .modifier(SpatialSceneEnvironment(settings: settings, companion: companion,
                                                  companionAgentScope: companionAgentScope))
                .onAppear { model.isVolumeOpen = true }
                .onDisappear {
                    model.isVolumeOpen = false
                    // Voice lives on the volume; closing the agent ends it.
                    model.endVoice()
                }
        }
        .windowStyle(.volumetric)
        // bighelp starts in its own window; the avatar comes only when chosen.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // About the size of a small pet on a desk, or the size you last made it.
        .defaultSize(width: SpatialAvatarVolumeSize.width * volumeScale,
                     height: SpatialAvatarVolumeSize.height * volumeScale,
                     depth: SpatialAvatarVolumeSize.depth * volumeScale, in: .meters)
        // Drag a corner to make your agent bigger or smaller, within the content's range.
        .windowResizability(.contentSize)
        // Within arm's reach, so its bar is easy to grab; after that it stays where you put it.
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }
    }
}
#endif
