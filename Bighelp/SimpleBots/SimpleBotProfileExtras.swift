import PhotosUI
import SwiftUI

/// Saves what the full avatar studio made for a bot, at once: the picture on the host (what every
/// screen, device and Hermes Desktop shows), and here the character or pet that chats draw over
/// it. The bot's mark goes, so Bots mode shows the new avatar.
@MainActor
enum SimpleBotAvatarSaving {
    enum Failure: Error { case render, photo }

    struct Look {
        let appearance: BighelpAppearanceContext
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
    }

    static func save(_ result: AvatarCreatorResult, for profile: AgentProfile, agents: AgentDirectoryStore,
                     companions: CompanionStore?, scope: String, look: Look) async throws {
        if case .mark(let mark) = result {
            try await SimpleBotMarkSaving.save(mark, for: profile, agents: agents, companions: companions, scope: scope)
            return
        }
        let editor = AgentEditorModel.editing(profile, store: agents, processor: AvatarImageProcessor())
        switch result {
        case .companion(let character):
            let data = try await AgentCompanionAvatarRenderer.renderPNG(
                companion: character, appearance: look.appearance, colorScheme: look.colorScheme,
                colorSchemeContrast: look.contrast)
            try await editor.importCompanionAvatar(data: data, appearance: character)
        case .look(let face):
            guard let data = HermesLookRenderer.png(look: face, name: editor.faceName) else { throw Failure.render }
            try await editor.importLookAvatar(data: data, look: face)
        case .pet(let pet, let data):
            try await editor.importPetAvatar(data: data, pet: pet)
        case .photo(let item):
            guard let data = try await item.loadTransferable(type: Data.self) else { throw Failure.photo }
            try await editor.importAvatar(data: data)
        case .mark:
            return
        }
        _ = try await editor.save()
        SimpleBotMarkStore.shared.set(nil, scope: scope, agentID: profile.id)
        guard let companions, !scope.isEmpty else { return }
        editor.applySavedLook(companions: companions, pets: .shared,
                              key: CompanionStore.agentKey(agentScope: scope, agentID: profile.id))
    }

    /// Where the studio opens: the bot's mark when it has one, else its character, pet or picture.
    static func start(for profile: AgentProfile, agents: AgentDirectoryStore, companions: CompanionStore?,
                      scope: String) -> AvatarCreatorStart {
        if let mark = SimpleBotMarkStore.shared.mark(scope: scope, agentID: profile.id) { return .mark(mark) }
        let key = CompanionStore.agentKey(agentScope: scope, agentID: profile.id)
        let editor = AgentEditorModel.editing(profile, store: agents, processor: AvatarImageProcessor())
        return editor.avatarCreatorStart(
            savedCharacter: scope.isEmpty ? nil : companions?.override(for: key),
            savedPetSlug: scope.isEmpty ? nil : PetAvatarStore.shared.slug(for: key),
            surprise: AvatarCreatorModel.surprise())
    }
}

/// The profile's tab frames, kept without redrawing the profile: at large text sizes the tab row
/// scrolls and they change every frame, and only a hold reads them.
final class SimpleBotTabFrameStore {
    var frames: [SimpleBotProfileTab: CGRect] = [:]
}

/// Each profile tab's frame in the row it sits in, for the bar over a held tab and for dragging.
struct SimpleBotTabFrames: PreferenceKey {
    static let defaultValue: [SimpleBotProfileTab: CGRect] = [:]
    static func reduce(value: inout [SimpleBotProfileTab: CGRect], nextValue: () -> [SimpleBotProfileTab: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Rearrange: the profile's tabs as glass chips, dragged into a new order right where they are.
/// They hold still until moved (no wiggle); VoiceOver moves them with Move Left and Move Right.
struct SimpleBotTabArranger: View {
    let tabs: [SimpleBotProfileTab]
    let onMove: (SimpleBotProfileTab, Int) -> Void
    @State private var frames: [SimpleBotProfileTab: CGRect] = [:]
    @State private var dragging: SimpleBotProfileTab?
    /// Where the dragged chip was when the drag began; it follows the finger from there.
    @State private var start: CGRect = .zero
    @State private var translation: CGSize = .zero
    /// Back to false when a drag ends or the system cancels it, which skips `onEnded`.
    @GestureState private var isPressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme

    private static let space = "simple-bots.profile.tab-arranger"

    var body: some View {
        BighelpFlowLayout(spacing: BighelpTokens.space8) {
            ForEach(tabs) { chip($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(SimpleBotTabFrames.self) { frames = $0 }
        .onChange(of: isPressing) { _, pressing in
            guard !pressing, dragging != nil else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                dragging = nil
                translation = .zero
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.profile.tabs.arranger")
    }

    private func chip(_ tab: SimpleBotProfileTab) -> some View {
        let isDragging = dragging == tab
        return HStack(spacing: BighelpTokens.space8) {
            Image(systemName: "line.3.horizontal")
                .font(.bighelp(.footnote, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(tab.title)
                .font(.bighelp(.body))
                .foregroundStyle(theme.primaryText)
        }
        .padding(.horizontal, BighelpTokens.space16)
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(Capsule())
        .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SimpleBotTabFrames.self, value: [tab: proxy.frame(in: .named(Self.space))])
            }
        }
        .offset(isDragging ? offset(of: tab) : .zero)
        .scaleEffect(isDragging ? 1.05 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 10, y: 6)
        .zIndex(isDragging ? 1 : 0)
        .gesture(drag(tab))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityHint(Text("Drag to move this tab."))
        .accessibilityActions {
            if let index = tabs.firstIndex(of: tab) {
                if index > 0 { Button("Move Left") { move(tab, to: index - 1) } }
                if index < tabs.count - 1 { Button("Move Right") { move(tab, to: index + 1) } }
            }
        }
        .accessibilityIdentifier("simple-bots.profile.tabs.chip.\(tab.rawValue)")
    }

    private func move(_ tab: SimpleBotProfileTab, to index: Int) {
        onMove(tab, index)
        AccessibilityNotification.Announcement(String(localized: "\(tab.title), \(index + 1) of \(tabs.count)")).post()
    }

    private func offset(of tab: SimpleBotProfileTab) -> CGSize {
        guard let now = frames[tab] else { return translation }
        return CGSize(width: start.minX + translation.width - now.minX,
                      height: start.minY + translation.height - now.minY)
    }

    private func drag(_ tab: SimpleBotProfileTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($isPressing) { _, pressing, _ in pressing = true }
            .onChanged { value in
                if dragging != tab {
                    dragging = tab
                    start = frames[tab] ?? .zero
                }
                translation = value.translation
                let center = CGPoint(x: start.midX + value.translation.width, y: start.midY + value.translation.height)
                guard let from = tabs.firstIndex(of: tab),
                      let target = tabs.indices.first(where: { index in
                          guard index != from, let frame = frames[tabs[index]],
                                frame.insetBy(dx: 0, dy: -BighelpTokens.space8).contains(center) else { return false }
                          // Past the other chip's middle the way it's going, so two chips never swap back and forth.
                          return index > from ? center.x > frame.midX : center.x < frame.midX
                      }) else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { onMove(tab, target) }
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    dragging = nil
                    translation = .zero
                }
            }
    }
}
