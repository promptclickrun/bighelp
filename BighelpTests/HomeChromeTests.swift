import Foundation
import SwiftUI
import Testing
@testable import Bighelp

@MainActor
struct HomeChromeTests {
    @Test(arguments: HomeConversationsView.allCases)
    func firstTabTakesTheDefaultViewsName(view: HomeConversationsView) {
        let items = HomeTabItem.standard(view: view)
        #expect(items.map(\.id) == [.conversations, .today, .work])
        #expect(items[0].title == view.title)
        #expect(items.map(\.accessibilityIdentifier) == ["home.tab.conversations", "home.tab.today", "home.tab.work"])
    }

    @Test func onlyTodayCarriesTheDot() {
        let items = HomeTabItem.standard(view: .chats, todayHasNew: true)
        #expect(items.filter(\.showsDot).map(\.id) == [.today])
        #expect(HomeTabItem.standard(view: .chats).allSatisfy { !$0.showsDot })
    }

    @Test func dotHidesOnThePlaceShowing() {
        let today = HomeTabItem.standard(view: .bots, todayHasNew: true)[1]
        #expect(today.showsDot(selected: false))
        #expect(!today.showsDot(selected: true))
    }

    @Test func selectedPlaceDrawsItsFilledSymbol() {
        let work = HomeTabItem.standard(view: .bots)[2]
        #expect(work.symbol(selected: false) == "hammer")
        #expect(work.symbol(selected: true) == "hammer.fill")
    }

    @Test func switchWinsOverTitle() {
        var context = header()
        #expect(context.center == .empty)
        context.title = "Today"
        #expect(context.center == .title("Today"))
        context.viewSwitch = HomeViewSwitch(current: .chats, select: { _ in })
        #expect(context.center == .viewSwitch(.chats))
    }

    @Test func emptyTitleShowsNothing() {
        var context = header()
        context.title = ""
        #expect(context.center == .empty)
    }

    @Test func computerMenuNeedsTwoComputers() {
        var context = header()
        context.computer = HomeHeaderComputer(name: "Home Mac", hosts: [host("home", selected: true)], select: { _ in })
        #expect(context.shownComputer == nil)
        context.computer = HomeHeaderComputer(name: "Home Mac",
                                              hosts: [host("home", selected: true), host("studio")],
                                              select: { _ in })
        #expect(context.shownComputer?.name == "Home Mac")
    }

    @Test func centeredRowKeepsTheMiddleClearOfTheWiderSide() {
        // 44-point circle on the left, search and + (96) on the right, a 120-point switch.
        #expect(HomeHeaderRowLayout.requiredWidth(leading: 44, middle: 120, trailing: 96, spacing: 8) == 328)
    }

    private func header() -> HomeHeaderContext {
        HomeHeaderContext(personName: "Sam", personImageURL: nil, onOpenSettings: {})
    }

    private func host(_ id: String, selected: Bool = false) -> BighelpMenuHosts.Host {
        BighelpMenuHosts.Host(id: id, name: id, isSelected: selected)
    }
}
