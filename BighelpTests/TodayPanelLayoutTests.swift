import Foundation
import Testing
@testable import Bighelp

/// Today's panel grid: how panels pack into rows, and the layout the person chose.
@MainActor
struct TodayPanelLayoutTests {
    private func panel(_ id: String, _ size: TodayPanelSize = .small, canDelete: Bool = false) -> TodayPanelDescriptor {
        TodayPanelDescriptor(id: id, kind: "space", title: id, size: size, canDelete: canDelete)
    }

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "today-panels-\(UUID().uuidString)"))
    }

    // MARK: Packing

    @Test func twoSmallPanelsShareARowAndWideAndTallTakeOne() {
        let rows = TodayPanelPacking.rows([panel("a"), panel("b"), panel("c", .wide), panel("d", .tall)])
        #expect(rows.map { $0.panels.map(\.id) } == [["a", "b"], ["c"], ["d"]])
        #expect(rows.map(\.takesRow) == [false, true, true])
    }

    @Test func aLoneSmallPanelKeepsItsOrderAndLeavesTheRestOfItsRowEmpty() {
        let rows = TodayPanelPacking.rows([panel("a"), panel("b", .wide), panel("c"), panel("d"), panel("e")])
        #expect(rows.map { $0.panels.map(\.id) } == [["a"], ["b"], ["c", "d"], ["e"]])
        #expect(rows[0].takesRow == false)
    }

    @Test func wideColumnsHoldMoreSmallPanelsAndOneColumnHoldsOne() {
        let panels = ["a", "b", "c", "d"].map { panel($0) }
        #expect(TodayPanelPacking.rows(panels, columns: 3).map(\.panels.count) == [3, 1])
        #expect(TodayPanelPacking.rows(panels, columns: 1).map(\.panels.count) == [1, 1, 1, 1])
        #expect(TodayPanelPacking.columns(width: 358, isAccessibilitySize: false) == 2)
        #expect(TodayPanelPacking.columns(width: 1_060, isAccessibilitySize: false) == 4)
        #expect(TodayPanelPacking.columns(width: 1_060, isAccessibilitySize: true) == 1)
    }

    // MARK: Layout

    @Test func aPanelTheLayoutDoesNotKnowGoesLastAtItsOwnSize() throws {
        let store = TodayPanelLayoutStore(defaults: try freshDefaults())
        let first = [panel("boards", .tall), panel("commute")]
        store.move(fromOffsets: [1], toOffset: 0, among: first)
        let shown = store.shown(first + [panel("workouts", .wide)])
        #expect(shown.map(\.id) == ["commute", "boards", "workouts"])
        #expect(shown.map(\.size) == [.small, .tall, .wide])
    }

    @Test func hideAndShowMoveAPanelBetweenTodayAndHidden() throws {
        let store = TodayPanelLayoutStore(defaults: try freshDefaults())
        let panels = [panel("boards", .tall), panel("commute")]
        store.setHidden("commute", true)
        #expect(store.shown(panels).map(\.id) == ["boards"])
        #expect(store.hiddenPanels(panels).map(\.id) == ["commute"])
        store.setHidden("commute", false)
        #expect(store.shown(panels).map(\.id) == ["boards", "commute"])
        #expect(store.hiddenPanels(panels).isEmpty)
    }

    @Test func theSizeThePersonPicksSticksAcrossLaunches() throws {
        let defaults = try freshDefaults()
        let panels = [panel("boards", .tall), panel("commute")]
        TodayPanelLayoutStore(defaults: defaults).setSize(.wide, for: "boards")
        let relaunched = TodayPanelLayoutStore(defaults: defaults)
        #expect(relaunched.shown(panels).map(\.size) == [.wide, .small])
        #expect(relaunched.size(of: panels[0]) == .wide)
    }

    @Test func reorderingMovesAmongShownPanelsAndKeepsHiddenOnes() throws {
        let store = TodayPanelLayoutStore(defaults: try freshDefaults())
        let panels = [panel("a"), panel("b"), panel("c"), panel("d")]
        store.setHidden("b", true)
        // Shown: a, c, d. Drag a below d.
        store.move(fromOffsets: [0], toOffset: 3, among: panels)
        #expect(store.shown(panels).map(\.id) == ["c", "d", "a"])
        #expect(store.hiddenPanels(panels).map(\.id) == ["b"])
    }

    @Test func aPanelNotListedKeepsItsChoicesUntilItIsDeleted() throws {
        let store = TodayPanelLayoutStore(defaults: try freshDefaults())
        let space = panel("commute", canDelete: true)
        let panels = [panel("boards", .tall), space]
        store.move(fromOffsets: [1], toOffset: 0, among: panels)
        store.setSize(.tall, for: "commute")
        // Its computer hasn't answered yet: the panel isn't listed, and nothing about it is lost.
        #expect(store.shown([panel("boards", .tall)]).map(\.id) == ["boards"])
        #expect(store.shown(panels).map(\.id) == ["commute", "boards"])
        #expect(store.size(of: space) == .tall)
        store.forget("commute")
        #expect(store.layout.order == ["boards"])
        #expect(store.size(of: space) == .small)
        #expect(store.shown(panels).map(\.id) == ["boards", "commute"])
    }

    // MARK: Panels that keep their own layout (Spaces)

    private func owned(_ id: String, _ size: TodayPanelSize = .small, hidden: Bool = false) -> TodayPanelDescriptor {
        TodayPanelDescriptor(id: id, kind: "space", title: id, size: size, canDelete: true,
                             keepsOwnLayout: true, isHidden: hidden)
    }

    /// What the store sent to the panels' owner.
    @MainActor
    final class OwnerCalls {
        var sizes: [(String, TodayPanelSize)] = []
        var hidden: [(String, Bool)] = []
        var orders: [[String]] = []

        func changes() -> TodayOwnedPanelChanges {
            TodayOwnedPanelChanges(resize: { self.sizes.append(($0.id, $1)) },
                                   setHidden: { self.hidden.append(($0.id, $1)) },
                                   reorder: { self.orders.append($0.map(\.id)) })
        }
    }

    @Test func anOwnedPanelsSizeAndHiddenAreItsOwners() throws {
        let store = TodayPanelLayoutStore(defaults: try freshDefaults())
        let calls = OwnerCalls()
        store.ownedChanges = calls.changes()
        let panels = [panel("boards", .tall), owned("a"), owned("b", .wide, hidden: true)]
        #expect(store.shown(panels).map(\.id) == ["boards", "a"])
        #expect(store.hiddenPanels(panels).map(\.id) == ["b"])

        store.setSize(.tall, for: panels[1])
        store.setHidden(panels[1], true)
        #expect(calls.sizes.map { $0.0 } == ["a"] && calls.sizes.map { $0.1 } == [.tall])
        #expect(calls.hidden.map { $0.0 } == ["a"] && calls.hidden.map { $0.1 } == [true])
        // Nothing about it is kept on this device: the owner's answer is what shows.
        #expect(store.layout.sizes.isEmpty && store.layout.hidden.isEmpty)
        #expect(store.size(of: panels[1]) == .small)
        // A panel of the device's own still keeps its choices here.
        store.setSize(.wide, for: panels[0])
        #expect(store.layout.sizes == ["boards": .wide])
    }

    @Test func aDragTellsTheOwnerItsOrderAndFollowsIt() throws {
        let store = TodayPanelLayoutStore(defaults: try freshDefaults())
        let calls = OwnerCalls()
        store.ownedChanges = calls.changes()
        let before = [panel("boards", .tall), owned("a"), owned("c")]
        // Drag c to the top.
        store.move(fromOffsets: [2], toOffset: 0, among: before)
        #expect(calls.orders == [["c", "boards", "a"]])
        // Until the owner moves them, its order fills the places the drag left.
        #expect(store.shown(before).map(\.id) == ["a", "boards", "c"])
        let after = [panel("boards", .tall), owned("c"), owned("a")]
        #expect(store.shown(after).map(\.id) == ["c", "boards", "a"])
    }
}
