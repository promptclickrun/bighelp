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
