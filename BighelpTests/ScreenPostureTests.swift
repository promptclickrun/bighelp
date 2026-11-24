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
        #expect(reported.sideColumnEdge == .trailing)
        #expect(reported.sideColumnWidth == 84)
        #expect(reported.sideColumnFreeTop == 174)
        // No report: the same screen, so nothing in the column moves.
        measured.occlusion = nil
        #expect(screen() == reported)
        // Split View's half: no column, as before.
        measured.trailingInset = 0
        #expect(screen().sideColumnWidth == 0)
        #expect(screen().sideColumnFreeTop == 0)
    }

    @Test func theColumnFollowsTheEdgeItIsOn() {
        // The cover screen: the camera and the status trail, as the Duo reports them.
        let trailing = BighelpScreenGeometry.sideColumn(
            leading: nil, trailing: CGRect(x: 382, y: 0, width: 84, height: 174),
            leadingInset: 0, trailingInset: 84)
        #expect(trailing.edge == .trailing)
        #expect(trailing.width == 84)
        #expect(trailing.freeTop == 174)
        // Split View, the app left of the divider: the same column, on its leading edge. This is the
        // case that made the chat switcher sit opposite the camera and squeezed the page.
        let leading = BighelpScreenGeometry.sideColumn(
            leading: CGRect(x: 0, y: 0, width: 84, height: 174), trailing: nil,
            leadingInset: 84, trailingInset: 0)
        #expect(leading.edge == .leading)
        #expect(leading.width == 84)
        #expect(leading.freeTop == 174)
        // An inset with no reported area still counts: the column is there before the API answers.
        #expect(BighelpScreenGeometry.sideColumn(leading: nil, trailing: nil,
                                                 leadingInset: 84, trailingInset: 0) == (leading.edge, 84, 174))
        // Nothing anywhere: the trailing edge stays, so a screen that reports nothing doesn't move.
        let none = BighelpScreenGeometry.sideColumn(leading: nil, trailing: nil, leadingInset: 0, trailingInset: 0)
        #expect(none.edge == .trailing)
        #expect(none.width == 0)
        #expect(none.freeTop == 0)
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

    @Test func picturesTakeTheWholeDisplayOnlyWhereTheBarHasAColumn() {
        // The cover screen and the inner one held wide stand the bar up in the trailing column, so
        // a picture opens over the display there instead of inset in a sheet beside it.
        #expect(ChatImageStackContent.isFullBleed(BighelpScreenGeometry(posture: .cover)))
        #expect(ChatImageStackContent.isFullBleed(BighelpScreenGeometry(posture: .open)))
        // Held upright (and half-folded as a laptop) the bar lies along the bottom, and the pictures
        // keep their sheet so they stay clear of the fold.
        #expect(!ChatImageStackContent.isFullBleed(BighelpScreenGeometry(posture: .openUpright)))
        #expect(!ChatImageStackContent.isFullBleed(BighelpScreenGeometry(posture: .standard)))
    }

    @Test func aPictureKeepsTheWayItOpenedWhenTheScreenTurns() throws {
        // The viewer's container and its body both read this one value, fixed when the picture
        // opens. Reading the live posture instead is what would dismiss the cover on a turn and
        // bring the pictures back as a sheet on the first one.
        let picture = try ChatAttachment(id: "photo-0000000001", fileName: "a.png", mimeType: "image/png",
                                         data: Data([0x89, 0x50, 0x4E, 0x47]))
        let opened = ChatPhotoStart(images: [picture], index: 2,
                                    screen: BighelpScreenGeometry(posture: .cover))
        #expect(opened.presentsFullScreen)
        #expect(opened.index == 2, "It opens on the picture that was chosen")
        let inASheet = ChatPhotoStart(images: opened.images, index: 0,
                                      screen: BighelpScreenGeometry(posture: .openUpright))
        #expect(!inASheet.presentsFullScreen, "A screen with a bar along the bottom keeps the sheet")
        #expect(ChatImageStackStart(index: 1, screen: BighelpScreenGeometry(posture: .open)).presentsFullScreen)
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
