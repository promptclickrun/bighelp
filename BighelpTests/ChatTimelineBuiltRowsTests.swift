import Testing
import UIKit
@testable import Bighelp

@Suite @MainActor
struct ChatTimelineBuiltRowsTests {
    private final class State {}

    @Test func aRowThatComesBackIsTheOneBuiltBefore() {
        let rows = ChatTimelineBuiltRows<State>(limit: 4)
        let first = rows.row(for: "a")
        first.state = State()
        _ = rows.row(for: "b")
        let again = rows.row(for: "a")
        #expect(again === first)
        #expect(again.cell === first.cell)
        #expect(again.cell.reuseIdentifier == nil, "UIKit must never give a kept cell to another row.")
    }

    @Test func overTheLimitTheRowsFarthestFromTheScreenGoButNeverOneOnScreen() {
        let rows = ChatTimelineBuiltRows<State>(limit: 3)
        let table = UIView()
        let index = ["near": 9, "above": 6, "far": 0, "gone": nil, "shown": 30, "screen": 10]
        for id in ["near", "above", "far", "gone"] { _ = rows.row(for: id) }
        table.addSubview(rows.row(for: "screen").cell)
        rows.trim(around: 10...12) { index[$0] ?? nil }
        #expect(rows.count == 3)
        #expect(rows["gone"] == nil, "A row the chat no longer places goes first.")
        #expect(rows["far"] == nil)
        #expect(rows["near"] != nil && rows["above"] != nil, "Rows just past the screen stay: they show next.")

        table.addSubview(rows.row(for: "shown").cell)
        rows.trim(around: 10...12) { index[$0] ?? nil }
        #expect(rows["shown"] != nil && rows["screen"] != nil, "A row on screen stays, however far it is.")
        #expect(rows["above"] == nil)
    }

    @Test func rowsTheChatNoLongerHasAreForgottenAndOnlyParkedCellsAreTakenOut() {
        let rows = ChatTimelineBuiltRows<State>(limit: 8)
        let table = UIView()
        let onScreen = rows.row(for: "a")
        table.addSubview(onScreen.cell)
        let parked = rows.row(for: "b")
        rows.park("b")
        #expect(parked.cell.superview === rows.parking)
        rows.remove(notIn: ["c"])
        #expect(rows.count == 0)
        #expect(parked.cell.superview == nil)
        #expect(onScreen.cell.superview === table, "UIKit takes a cell on screen out itself.")
    }

    @Test func aMemoryWarningKeepsOnlyTheRowsOnScreen() {
        let rows = ChatTimelineBuiltRows<State>(limit: 8)
        let table = UIView()
        table.addSubview(rows.row(for: "a").cell)
        _ = rows.row(for: "b")
        rows.park("b")
        rows.removeAll(keepingOnScreen: true)
        #expect(rows["a"] != nil)
        #expect(rows["b"] == nil)
        #expect(rows.parking.subviews.isEmpty)
    }
}
