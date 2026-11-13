import SwiftUI

extension TodayPanelSize {
    init(_ size: SpaceSize) {
        switch size {
        case .small: self = .small
        case .wide: self = .wide
        case .tall: self = .tall
        }
    }
}

extension SpaceSize {
    init(_ size: TodayPanelSize) {
        switch size {
        case .small: self = .small
        case .wide: self = .wide
        case .tall: self = .tall
        }
    }
}

/// The spaces on Today's grid: a descriptor for each space, its panel, and what the grid's menu
/// and Edit do to it. A space's size, hidden state and place live on its computer (the bot designs
/// for its size), so its descriptor `keepsOwnLayout` and the layout store hands those changes here
/// (`ownedChanges`), to go there through `TodaySpacesModel`, which shows each at once and undoes it
/// if the computer says no.
@MainActor
struct SpacesTodayBridge {
    static let kind = "space"

    let model: TodaySpacesModel
    /// Opens a space's page full screen. The shell presents `HTMLAppScreen` with the page's card
    /// (`space.page?.card(title:description:)`) on the space's own computer (`model.pageConnection`).
    let openPage: (TodaySpace) -> Void

    init(model: TodaySpacesModel = .shared, openPage: @escaping (TodaySpace) -> Void) {
        self.model = model
        self.openPage = openPage
    }

    /// A panel id that stays the same across launches and reconnects: the space's own id
    /// (`TodaySpace.id`, its key and its computer's cache scope, hashed).
    static func panelID(for item: TodaySpace) -> String { item.id }

    /// Every space Today has, hidden ones too (Edit lists them), in the computers' order.
    func descriptors(from items: [TodaySpace]) -> [TodayPanelDescriptor] {
        items.map { item in
            TodayPanelDescriptor(id: Self.panelID(for: item), kind: Self.kind,
                                 title: item.space.title.isEmpty ? String(localized: "Space") : item.space.title,
                                 size: TodayPanelSize(item.space.size), canDelete: true,
                                 keepsOwnLayout: true, isHidden: item.space.hidden)
        }
    }

    /// What the layout store sends here for a space's panel (`TodayPanelLayoutStore.ownedChanges`).
    var ownedChanges: TodayOwnedPanelChanges {
        TodayOwnedPanelChanges(resize: { resize($0, to: $1) }, setHidden: { setHidden($0, $1) },
                               reorder: { reorder($0) })
    }

    func item(for panel: TodayPanelDescriptor) -> TodaySpace? {
        guard panel.kind == Self.kind else { return nil }
        return model.items.first { Self.panelID(for: $0) == panel.id }
    }

    /// The panel for a space descriptor, at the descriptor's size. Empty for one that's gone.
    func panel(for panel: TodayPanelDescriptor) -> AnyView {
        guard let item = item(for: panel) else { return AnyView(EmptyView()) }
        let model = model
        let openPage = openPage
        let id = item.id
        return AnyView(SpacePanelView(
            space: item.space, size: SpaceSize(panel.size), botName: botLine(item), isConnected: item.isConnected,
            onOpen: item.space.page == nil ? nil : { openPage(item) },
            runNow: { () async throws(SpacesError) -> SpaceRefreshRun in try await model.runNow(id) }))
    }

    /// A space's own rows in its panel's long-press menu, beside Resize, Hide and Delete: Open and
    /// Update now. Update now shows its result on the panel itself.
    func menuItems(for panel: TodayPanelDescriptor) -> AnyView {
        guard let item = item(for: panel) else { return AnyView(EmptyView()) }
        let model = model
        let openPage = openPage
        let id = item.id
        return AnyView(Group {
            if item.space.page != nil {
                Button("Open", systemImage: "arrow.up.forward.app") { openPage(item) }
                    .accessibilityIdentifier("today.space.menu.open")
            }
            Button("Update now", systemImage: "arrow.clockwise") {
                Task { await Self.updateNow(id, model: model) }
            }
            .disabled(!item.isConnected)
            .accessibilityIdentifier("today.space.menu.update")
        })
    }

    /// Update now from the menu. What the person can act on shows as Today's notice line: the panel's
    /// own footer only says it for the panel's Try again.
    private static func updateNow(_ id: String, model: TodaySpacesModel) async {
        do throws(SpacesError) {
            let run = try await model.runNow(id)
            if let message = SpacesTodayMessage.updateNow(ran: run) { TodayNotice.shared.show(message) }
        } catch {
            TodayNotice.shared.show(SpacesTodayMessage.updateNow(error))
        }
    }

    /// The bot's name, and its computer's when Today shows spaces from two or more.
    private func botLine(_ item: TodaySpace) -> String {
        model.showsComputerNames ? "\(item.botName) · \(item.computerName)" : item.botName
    }

    // MARK: What the grid and Edit do to a space

    /// Small, Wide or Tall, kept on the space's computer. Shown at once; a refusal is undone in the
    /// space's store, with nothing else to show.
    func resize(_ panel: TodayPanelDescriptor, to size: TodayPanelSize) {
        guard let id = item(for: panel)?.id else { return }
        model.changeNow(id, SpaceChanges(size: SpaceSize(size)))
    }

    /// Hidden spaces keep updating; Today only stops drawing them.
    func setHidden(_ panel: TodayPanelDescriptor, _ hidden: Bool) {
        guard let id = item(for: panel)?.id else { return }
        model.changeNow(id, SpaceChanges(hidden: hidden))
    }

    /// Every panel in its new order after Edit's drag: the spaces among them get new places on
    /// their computers, in that order. The places change before this returns.
    func reorder(_ panels: [TodayPanelDescriptor]) {
        let known = Set(model.items.map(\.id))
        let ids = panels.map(\.id).filter { known.contains($0) }
        guard !ids.isEmpty else { return }
        model.reorder(ids)
    }

    /// Stops its routine and removes it and its page; then the layout forgets its place. A delete
    /// the computer hasn't finished keeps the space off Today and goes again at the next read; a
    /// space the computer refused to delete comes back on Today, and keeps its place.
    func delete(_ panel: TodayPanelDescriptor, layout: TodayPanelLayoutStore) {
        guard let id = item(for: panel)?.id else { return }
        let model = model
        let panelID = panel.id
        Task {
            do throws(SpacesError) {
                try await model.delete(id)
                layout.forget(panelID)
            } catch {
                // A definite refusal: the store put the space back, and the person is told.
                TodayNotice.shared.show(SpacesTodayMessage.deleteRefused)
            }
        }
    }

    // MARK: Notes above the grid

    /// One for each computer whose plugin doesn't know spaces yet.
    var notes: [SpacesTodayNote] {
        model.statuses.filter { $0.phase == .needsPluginUpdate }.map { SpacesTodayNote(id: $0.scope, computerName: $0.name) }
    }
}

/// The short words for what a panel's action came back with. Words the panel and the draft card
/// already use stay the same (docs/SPACES.md).
enum SpacesTodayMessage {
    /// What Update now answered when it ran: only a paused routine has something to say.
    static func updateNow(ran: SpaceRefreshRun) -> String? {
        ran == .paused ? String(localized: "Paused in Scheduled tasks") : nil
    }

    static func updateNow(_ error: SpacesError) -> String {
        switch error {
        case .tooSoon: String(localized: "Try again in a minute")
        case .routineFailed: String(localized: "Its update failed")
        case .unreachable: String(localized: "Could not reach your computer. Try again.")
        case .schedulesUnavailable: String(localized: "Your computer can't run scheduled tasks right now.")
        default: String(localized: "Could not update it. Try again.")
        }
    }

    /// A delete only throws once the computer refused it for good.
    static var deleteRefused: String {
        String(localized: "Could not delete it. Try again.")
    }
}

/// A computer whose plugin has to be updated before Today can show its spaces.
struct SpacesTodayNote: Identifiable, Equatable, Sendable {
    /// The computer's cache scope.
    let id: String
    let computerName: String
}

/// The quiet lines Today shows above the grid, one per computer.
struct SpacesTodayNotes: View {
    let notes: [SpacesTodayNote]
    @BighelpThemeReader private var theme

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                ForEach(notes) { note in
                    Text("Update the plugin on \(note.computerName) to see its spaces.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today.spaces.notes")
        }
    }
}

/// Delete's confirmation for a space panel. The shell sets `panel` from Today's `onDeletePanel`.
private struct SpacesDeleteConfirmation: ViewModifier {
    @Binding var panel: TodayPanelDescriptor?
    let bridge: SpacesTodayBridge
    let layout: TodayPanelLayoutStore

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete this space?",
                                   isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } }),
                                   titleVisibility: .visible, presenting: panel) { panel in
            Button("Delete", role: .destructive) { bridge.delete(panel, layout: layout) }
                .accessibilityIdentifier("today.space.delete.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("today.space.delete.cancel")
        } message: { _ in
            Text("It stops its updates and removes its page.")
        }
    }
}

extension View {
    /// Asks before a space is deleted, then deletes it on its computer.
    func spacesDeleteConfirmation(_ panel: Binding<TodayPanelDescriptor?>, bridge: SpacesTodayBridge,
                                  layout: TodayPanelLayoutStore) -> some View {
        modifier(SpacesDeleteConfirmation(panel: panel, bridge: bridge, layout: layout))
    }
}
