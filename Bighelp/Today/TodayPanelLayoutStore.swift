import Foundation
import Observation

/// How much room a panel on Today takes: half a row, the whole row, or the whole row and more height.
enum TodayPanelSize: String, CaseIterable, Codable, Sendable {
    case small, wide, tall

    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .wide: String(localized: "Wide")
        case .tall: String(localized: "Tall")
        }
    }

    /// Small shares its row; Wide and Tall take it.
    var takesRow: Bool { self != .small }
}

/// One panel on Today, as the shell lists it. The grid knows panels only by this and the shell's
/// factory, so a new kind of panel (a bot's Space) needs no change here.
struct TodayPanelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    /// What draws it, for the shell's factory ("boards", "space").
    let kind: String
    /// Its name in Edit and in VoiceOver, one to three words.
    let title: String
    /// The size it starts at; once the person picks one, `TodayPanelLayoutStore` keeps theirs.
    var size: TodayPanelSize
    /// The long-press menu offers Delete, which the shell confirms and carries out.
    var canDelete = false
    /// Its size, hidden state and place belong to its owner, not to this device (a bot's Space keeps
    /// them on its computer): `size` and `isHidden` are the owner's, and changes go to
    /// `TodayPanelLayoutStore.ownedChanges`.
    var keepsOwnLayout = false
    /// The owner's hidden state, for a panel that `keepsOwnLayout`.
    var isHidden = false
}

/// What the person chose for Today's panels: their order, which are hidden and each one's size.
/// Ids of panels not listed right now (a Space whose computer hasn't answered yet) are kept;
/// only `forget` drops one.
struct TodayPanelLayout: Codable, Equatable, Sendable {
    var order: [String] = []
    var hidden: Set<String> = []
    var sizes: [String: TodayPanelSize] = [:]

    /// The panels to show, in the person's order with their sizes. A panel the layout doesn't know
    /// goes last, in the order the shell listed it, at its own size (as `BighelpAppLayout` does).
    func shown(_ panels: [TodayPanelDescriptor]) -> [TodayPanelDescriptor] {
        arranged(panels).filter { !isHidden($0) }
    }

    /// The hidden panels, in the same order, for Edit's Hidden list.
    func hiddenPanels(_ panels: [TodayPanelDescriptor]) -> [TodayPanelDescriptor] {
        arranged(panels).filter { isHidden($0) }
    }

    /// The panels in the person's order with their sizes. Panels that keep their own layout fill
    /// the places they hold in the order the shell listed them (their owner's order), at their own
    /// sizes.
    func arranged(_ panels: [TodayPanelDescriptor]) -> [TodayPanelDescriptor] {
        var seen = Set<String>()
        var owned = panels.filter { $0.keepsOwnLayout && seen.insert($0.id).inserted }.makeIterator()
        return listed(panels).map { panel in
            if panel.keepsOwnLayout { return owned.next() ?? panel }
            var panel = panel
            if let size = sizes[panel.id] { panel.size = size }
            return panel
        }
    }

    /// The panels in `order`, then the ones it doesn't know in the shell's order; each id once.
    func listed(_ panels: [TodayPanelDescriptor]) -> [TodayPanelDescriptor] {
        var byID: [String: TodayPanelDescriptor] = [:]
        for panel in panels where byID[panel.id] == nil { byID[panel.id] = panel }
        var known = order.compactMap { byID.removeValue(forKey: $0) }
        known += panels.filter { byID.removeValue(forKey: $0.id) != nil }
        return known
    }

    private func isHidden(_ panel: TodayPanelDescriptor) -> Bool {
        panel.keepsOwnLayout ? panel.isHidden : hidden.contains(panel.id)
    }

    /// Moves among the shown panels (Edit's drag). Panels not shown keep their place after them.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, among panels: [TodayPanelDescriptor]) {
        var ids = shown(panels).map(\.id)
        let moving = source.sorted().filter { ids.indices.contains($0) }.map { ids[$0] }
        guard !moving.isEmpty else { return }
        let insertion = destination - source.filter { $0 < destination }.count
        ids.removeAll { moving.contains($0) }
        ids.insert(contentsOf: moving, at: max(0, min(insertion, ids.count)))
        let rest = arranged(panels).map(\.id).filter { !ids.contains($0) }
        let unlisted = order.filter { !ids.contains($0) && !rest.contains($0) }
        order = ids + rest + unlisted
    }

    mutating func setHidden(_ id: String, _ isHidden: Bool) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
    }

    mutating func forget(_ id: String) {
        order.removeAll { $0 == id }
        hidden.remove(id)
        sizes[id] = nil
    }
}

/// Where a panel that keeps its own layout sends the person's changes to it (a Space: its
/// computer, through `SpacesTodayBridge`). Each shows the change before it returns.
@MainActor
struct TodayOwnedPanelChanges {
    let resize: @MainActor (TodayPanelDescriptor, TodayPanelSize) -> Void
    let setHidden: @MainActor (TodayPanelDescriptor, Bool) -> Void
    /// Every panel in the order the person left them, owned or not.
    let reorder: @MainActor ([TodayPanelDescriptor]) -> Void
}

/// Today's panel layout on this device, saved under `bighelp.today.panels`.
@MainActor
@Observable
final class TodayPanelLayoutStore {
    static let key = "bighelp.today.panels"

    private(set) var layout: TodayPanelLayout
    /// Set by the shell for panels that `keepsOwnLayout`; their changes are dropped while it's nil.
    @ObservationIgnored var ownedChanges: TodayOwnedPanelChanges?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(TodayPanelLayout.self, from: $0) } ?? TodayPanelLayout()
    }

    func shown(_ panels: [TodayPanelDescriptor]) -> [TodayPanelDescriptor] { layout.shown(panels) }
    func hiddenPanels(_ panels: [TodayPanelDescriptor]) -> [TodayPanelDescriptor] { layout.hiddenPanels(panels) }

    func size(of panel: TodayPanelDescriptor) -> TodayPanelSize {
        panel.keepsOwnLayout ? panel.size : (layout.sizes[panel.id] ?? panel.size)
    }

    func setSize(_ size: TodayPanelSize, for id: String) {
        change { $0.sizes[id] = size }
    }

    /// The grid's and Edit's size picker: the owner's for a panel that keeps its own layout.
    func setSize(_ size: TodayPanelSize, for panel: TodayPanelDescriptor) {
        if panel.keepsOwnLayout {
            ownedChanges?.resize(panel, size)
        } else {
            setSize(size, for: panel.id)
        }
    }

    func setHidden(_ id: String, _ isHidden: Bool) {
        change { $0.setHidden(id, isHidden) }
    }

    /// Hide and Show: the owner's for a panel that keeps its own layout.
    func setHidden(_ panel: TodayPanelDescriptor, _ isHidden: Bool) {
        if panel.keepsOwnLayout {
            ownedChanges?.setHidden(panel, isHidden)
        } else {
            setHidden(panel.id, isHidden)
        }
    }

    /// Edit's drag. Panels that keep their own layout also get their new order from their owner
    /// (`ownedChanges.reorder`), which `arranged` then follows.
    func move(fromOffsets source: IndexSet, toOffset destination: Int, among panels: [TodayPanelDescriptor]) {
        change { $0.move(fromOffsets: source, toOffset: destination, among: panels) }
        // `listed`, not `arranged`: the owned panels' places from the drag, before their owner moves them.
        if panels.contains(where: \.keepsOwnLayout) { ownedChanges?.reorder(layout.listed(panels)) }
    }

    /// After the shell deletes a panel (a Space): its place, size and hidden state go with it.
    func forget(_ id: String) {
        change { $0.forget(id) }
    }

    private func change(_ edit: (inout TodayPanelLayout) -> Void) {
        var next = layout
        edit(&next)
        guard next != layout else { return }
        layout = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
    }
}
