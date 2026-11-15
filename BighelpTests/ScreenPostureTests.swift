import Foundation
import SwiftUI
import Testing
@testable import Bighelp

/// The iPhone Duo's screens: which layouts each gets, and where the chat switcher shows.
@MainActor
struct ScreenPostureTests {
    private func posture(phone: Bool = true, _ horizontal: UserInterfaceSizeClass, _ vertical: UserInterfaceSizeClass,
                         _ width: CGFloat, _ height: CGFloat) -> BighelpScreenPosture {
        BighelpScreenPosture.classify(isPhone: phone, horizontal: horizontal, vertical: vertical,
                                      size: CGSize(width: width, height: height))
    }

    @Test func theDuoFoldedAndHalfOfItOpenAreCoverScreens() {
        #expect(posture(.compact, .regular, 466, 678) == .cover)
        // Half of the inner screen in iOS's 50/50 Split View.
        #expect(posture(.compact, .regular, 475, 669) == .cover)
    }

    @Test func theDuoOpenIsTheOnlyPhoneWithRoomForAList() {
        #expect(posture(.regular, .regular, 951, 669) == .open)
        // Held upright, the fold across it: a big phone, never the cover screen's layouts.
        #expect(posture(.regular, .regular, 669, 951) == .openUpright)
        #expect(posture(.compact, .regular, 669, 951) == .standard)
    }

    @Test func halfFoldedLikeALaptopKeepsTheChatAboveTheFold() {
        var screen = BighelpScreenGeometry(posture: .openUpright, size: CGSize(width: 669, height: 951),
                                           fold: CGRect(x: 0, y: 470, width: 669, height: 12), isFoldActive: true)
        #expect(screen.isLaptop)
        screen.isFoldActive = false
        #expect(!screen.isLaptop, "Lying flat, the screen is one page")
        // Open wide, the fold runs down the middle: that's a book, not a laptop.
        let book = BighelpScreenGeometry(posture: .open, size: CGSize(width: 951, height: 669),
                                         fold: CGRect(x: 470, y: 0, width: 12, height: 669), isFoldActive: true)
        #expect(!book.isLaptop)
    }

    @Test func theListStopsAtTheFold() {
        let open = BighelpScreenGeometry(posture: .open, size: CGSize(width: 951, height: 669),
                                         fold: CGRect(x: 470, y: 0, width: 12, height: 669))
        #expect(open.splitColumnWidth == 470)
        // Without a fold to go by, about an iPhone's width.
        #expect(BighelpScreenGeometry(posture: .open, size: CGSize(width: 951, height: 669)).splitColumnWidth == 340)
    }

    @Test func theColumnStaysClearOfTheStatusWhenTheSystemReportsNoEndForIt() {
        // The system's report is taken as it is.
        #expect(BighelpScreenGeometry.columnFreeTop(reportedEnd: 174, systemColumnWidth: 84) == 174)
        #expect(BighelpScreenGeometry.columnFreeTop(reportedEnd: 120, systemColumnWidth: 84) == 120)
        // A column with no report (the first moments after launch): the area's own height.
        #expect(BighelpScreenGeometry.columnFreeTop(reportedEnd: nil, systemColumnWidth: 84)
            == BighelpScreenGeometry.statusAreaHeight)
        // What the Duo reports, and what the guides say.
        #expect(BighelpScreenGeometry.statusAreaHeight == 174)
        // Half of the open screen in Split View has no column of the system's: nothing to clear.
        #expect(BighelpScreenGeometry.columnFreeTop(reportedEnd: nil, systemColumnWidth: 0) == 0)
    }

    @Test func aMeasuredCoverScreenKeepsItsReportAndFallsBackWithoutOne() {
        // The posture comes from the device, so this reads as written only on a phone.
        guard BighelpScreenPosture.isPhone, BighelpScreenDebug.posture == nil else { return }
        var measured = BighelpScreenPostureReader.Measured(
            size: CGSize(width: 466, height: 678), trailingInset: 84,
            occlusion: CGRect(x: 382, y: 0, width: 84, height: 174))
        func screen() -> BighelpScreenGeometry {
            BighelpScreenPostureReader.geometry(measured, horizontal: .compact, vertical: .regular)
        }
        let reported = screen()
        #expect(reported.posture == .cover)
        #expect(reported.trailingColumnWidth == 84)
        #expect(reported.trailingColumnFreeTop == 174)
        // No report: the same screen, so nothing in the column moves.
        measured.occlusion = nil
        #expect(screen() == reported)
        // Split View's half: no column, as before.
        measured.trailingInset = 0
        #expect(screen().trailingColumnWidth == 0)
        #expect(screen().trailingColumnFreeTop == 0)
    }

    @Test func theSideBarIsForScreensWithAStatusColumn() {
        #expect(BighelpScreenGeometry(posture: .cover).usesSideBar)
        #expect(BighelpScreenGeometry(posture: .open).usesSideBar)
        #expect(!BighelpScreenGeometry(posture: .openUpright).usesSideBar)
        #expect(!BighelpScreenGeometry(posture: .standard).usesSideBar)
    }

    @Test func everyOtherPhoneKeepsItsLayout() {
        #expect(posture(.compact, .regular, 402, 874) == .standard) // iPhone 17 Pro
        #expect(posture(.compact, .regular, 375, 667) == .standard) // iPhone SE
        #expect(posture(.regular, .compact, 956, 440) == .standard) // Pro Max on its side
        #expect(posture(.compact, .compact, 874, 402) == .standard)
    }

    @Test func iPadAndMacNeverTakeTheDuosLayouts() {
        #expect(posture(phone: false, .regular, .regular, 1133, 744) == .standard)
        #expect(posture(phone: false, .compact, .regular, 507, 744) == .standard)
    }

    @Test func theSwitcherShowsFoldedNotOpenAndOnlyWhenOn() {
        let cover = BighelpScreenGeometry(posture: .cover, size: CGSize(width: 466, height: 678))
        let open = BighelpScreenGeometry(posture: .open, size: CGSize(width: 951, height: 669))
        #expect(BighelpChatSwitcher.isShown(isOn: true, screen: cover, horizontalSizeClass: .compact))
        #expect(!BighelpChatSwitcher.isShown(isOn: false, screen: cover, horizontalSizeClass: .compact))
        // Open, the list beside the chat already does its job.
        #expect(!BighelpChatSwitcher.isShown(isOn: true, screen: open, horizontalSizeClass: .regular))
        // An ordinary phone never shows it.
        let phone = BighelpScreenGeometry(posture: .standard, size: CGSize(width: 402, height: 874))
        if BighelpScreenPosture.isPhone {
            #expect(!BighelpChatSwitcher.isShown(isOn: true, screen: phone, horizontalSizeClass: .compact))
            #expect(!BighelpChatSwitcher.isOffered(screen: phone))
        }
    }

    @Test func theAppNeverDrawsItsOwnIslandOnTheDuo() {
        // Folded, open wide and half-folded: the camera and the status sit in a side column, so
        // there is no top-edge island to cover. Reserving space at the top also moved every
        // screen and fed back into the posture, so the stage shook the whole UI open.
        for posture in [BighelpScreenPosture.cover, .open, .openUpright] {
            #expect(!AgentIslandAvailability.isShown(isPhone: true, posture: posture))
        }
        #expect(AgentIslandAvailability.isShown(isPhone: true, posture: .standard))
        // iPad, the Mac and Vision Pro have no island to cover.
        #expect(!AgentIslandAvailability.isShown(isPhone: false, posture: .standard))
    }

    @Test func theSwitcherSettingStartsOnForPhonesAndKeepsTheChoice() {
        let name = "chat-switcher-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.chatSwitcherEnabled == BighelpChatSwitcher.isOnByDefault)
        settings.chatSwitcherEnabled = false
        #expect(!SettingsStore(defaults: defaults).chatSwitcherEnabled)
        settings.chatSwitcherEnabled = true
        #expect(SettingsStore(defaults: defaults).chatSwitcherEnabled)
    }
}
