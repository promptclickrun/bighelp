import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct ChatLayoutPreferencesTests {
    @Test func autoAvatarIsLargeOnlyOnTheTallestPhones() {
        // iPhone 16 Pro / 17 Pro are 874 points tall; the Pro Max phones 932 and up.
        #expect(ChatAvatarSize.automatic.points(screenHeight: 874) == 60)
        #expect(ChatAvatarSize.automatic.points(screenHeight: 956) == 76)
        #expect(ChatAvatarSize.small.points(screenHeight: 956) == 44)
        #expect(ChatAvatarSize.large.points(screenHeight: 874) == 76)
    }

    @Test func tabBarDropsIntoTheHomeIndicatorAreaButNeverOffScreen() {
        #expect(FloatingTabBar.homeIndicatorSink(forBottomInset: 34) == 20)
        #expect(FloatingTabBar.homeIndicatorSink(forBottomInset: 21) == 7)
        #expect(FloatingTabBar.homeIndicatorSink(forBottomInset: 0) == 0)
        // A keyboard's inset is much larger; the bar still moves at most 20 points.
        #expect(FloatingTabBar.homeIndicatorSink(forBottomInset: 336) == 20)
    }

    @Test func textSizeStepsAroundTheSystemSize() {
        #expect(ChatTextSize.standard.scale == 1)
        let scales = ChatTextSize.allCases.map(\.scale)
        #expect(scales == scales.sorted())
        #expect(ChatTextSize(rawValue: 2) == .larger)
    }

    @Test func messagesStartOneStepSmallerButASavedSizeStays() throws {
        let suite = "bighelp.tests.chat-text-size.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func current() -> ChatTextSize {
            AppStorage(wrappedValue: ChatTextSize.defaultSize, ChatLayoutPreferences.textSizeKey, store: defaults).wrappedValue
        }

        #expect(ChatTextSize.defaultSize == .small)
        #expect(current() == .small)
        // Someone who picked the old default keeps it.
        defaults.set(ChatTextSize.standard.rawValue, forKey: ChatLayoutPreferences.textSizeKey)
        #expect(current() == .standard)
        defaults.set(ChatTextSize.larger.rawValue, forKey: ChatLayoutPreferences.textSizeKey)
        #expect(current() == .larger)
    }

    // The app-wide text size (#729). Raw values are what's saved.

    @Test func appTextStartsOneStepUnderTheDeviceAndWritesNothing() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let size = BighelpInterfaceSize(defaults: defaults, isMac: false)
        #expect(size.textSize.rawValue == -1)
        #expect(size.textSize == .platformDefault)
        #expect(!size.picksTextSize)
        #expect(size.dynamicTypeSize(onTopOf: .large) == .medium)
        // The Mac's body text: 15pt, from 16pt, one step like the iPhone's 17 to 16.
        #expect((17 * size.textSize.macFactor * 2).rounded() / 2 == 15)
        // Opening the app saves no size, so the default reaches everyone who never picked one.
        #expect(defaults.object(forKey: BighelpInterfaceSize.textSizeKey) == nil)
        _ = BighelpInterfaceSize(defaults: defaults, isMac: true)
        #expect(defaults.object(forKey: BighelpInterfaceSize.textSizeKey) == nil)
    }

    @Test func aSavedAppTextSizeStaysTheSameSize() throws {
        // Every size someone could pick before #729, with the Mac's factor for it then.
        let picks: [(raw: Int, macFactor: CGFloat)] = [(-1, 0.82), (0, 0.94), (1, 1.03), (2, 1.12), (3, 1.22)]
        for pick in picks {
            let (defaults, suite) = try freshDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(pick.raw, forKey: BighelpInterfaceSize.textSizeKey)
            // iPhone and iPad: the same raw value is the same Dynamic Type step.
            let phone = BighelpInterfaceSize(defaults: defaults, isMac: false)
            #expect(phone.textSize.rawValue == pick.raw)
            #expect(phone.picksTextSize)
            #expect(phone.dynamicTypeSize(onTopOf: .large) == DynamicTypeSize.large.stepped(by: pick.raw))
            // The Mac: the same factor.
            #expect(BighelpInterfaceSize(defaults: defaults, isMac: true).textSize.macFactor == pick.macFactor)
        }
        // Someone who picked the old Default keeps that size, now named for what it is.
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: BighelpInterfaceSize.textSizeKey)
        #expect(BighelpInterfaceSize(defaults: defaults, isMac: false).textSize.title == "Medium")
    }

    @Test func theMacMovesAnOldSmallOnceAndOnlyOnTheMac() throws {
        let key = BighelpInterfaceSize.textSizeKey
        let (mac, macSuite) = try freshDefaults()
        defer { mac.removePersistentDomain(forName: macSuite) }
        mac.set(-1, forKey: key)
        let moved = BighelpInterfaceSize(defaults: mac, isMac: true)
        #expect(moved.textSize == .small)
        #expect(moved.textSize.macFactor == 0.82)
        #expect(mac.integer(forKey: key) == -2)
        #expect(mac.bool(forKey: BighelpInterfaceSize.macSmallMovedKey))
        // A Default picked after the move stays Default.
        moved.textSize = .standard
        #expect(BighelpInterfaceSize(defaults: mac, isMac: true).textSize == .standard)

        let (phone, phoneSuite) = try freshDefaults()
        defer { phone.removePersistentDomain(forName: phoneSuite) }
        phone.set(-1, forKey: key)
        #expect(BighelpInterfaceSize(defaults: phone, isMac: false).textSize.rawValue == -1)
        #expect(phone.integer(forKey: key) == -1)
        #expect(phone.object(forKey: BighelpInterfaceSize.macSmallMovedKey) == nil)
    }

    @Test func accessibilitySizesKeepTheirSizeUntilSomeonePicksOne() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let size = BighelpInterfaceSize(defaults: defaults, isMac: false)
        #expect(size.dynamicTypeSize(onTopOf: .accessibility1) == .accessibility1)
        #expect(size.dynamicTypeSize(onTopOf: .accessibility3) == .accessibility3)
        #expect(size.dynamicTypeSize(onTopOf: .xxxLarge) == .xxLarge)
        #expect(size.dynamicTypeSize(onTopOf: .large) == .medium)
        // A size picked here applies at any device size, Default too.
        size.textSize = .small
        #expect(size.dynamicTypeSize(onTopOf: .accessibility1) == .xxLarge)
        size.textSize = .standard
        #expect(size.dynamicTypeSize(onTopOf: .accessibility1) == .xxxLarge)
        #expect(BighelpInterfaceSize(defaults: defaults, isMac: false).dynamicTypeSize(onTopOf: .accessibility1) == .xxxLarge)
    }

    /// iOS starts a sheet again from the device's size, so it steps once more; a size that
    /// came through from the root stays.
    @Test func aSheetTakesOneStepNotTwo() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let size = BighelpInterfaceSize(defaults: defaults, isMac: false)
        let root = size.dynamicTypeSize(onTopOf: .large)
        #expect(root == .medium)
        #expect(size.dynamicTypeSize(onTopOf: .large, sizedAbove: root) == .medium)
        #expect(size.dynamicTypeSize(onTopOf: root, sizedAbove: root) == .medium)
    }

    @Test func resetGoesToTheNewDefaultAndSmallerTextHasRoomBelowIt() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let size = BighelpInterfaceSize(defaults: defaults, isMac: false)
        size.textSize = try #require(BighelpTextSize(rawValue: 3))
        size.reset()
        #expect(size.textSize.rawValue == -1)
        // Reset forgets the pick, so it is the size out of the box again.
        #expect(!size.picksTextSize)
        #expect(defaults.object(forKey: BighelpInterfaceSize.textSizeKey) == nil)
        #expect(size.dynamicTypeSize(onTopOf: .accessibility1) == .accessibility1)
        // ⌘− goes one step under Default, and no further.
        size.stepText(by: -1)
        #expect(size.textSize.rawValue == -2)
        size.stepText(by: -1)
        #expect(size.textSize.rawValue == -2)
        // ⌘0
        size.resetText()
        #expect(size.textSize == .platformDefault)
        #expect(!size.picksTextSize)
    }

    @Test func onlyTheDefaultTextSizeIsCalledDefault() {
        #expect(BighelpTextSize.allCases.map(\.title) == ["Small", "Default", "Medium", "Large", "Larger", "Largest"])
        #expect(BighelpTextSize.allCases.filter { $0.title == "Default" } == [.platformDefault])
        #expect(BighelpTextSize.allCases.map(\.rawValue) == Array(-2...3))
        let factors = BighelpTextSize.allCases.map(\.macFactor)
        #expect(factors == factors.sorted())
        #expect(Set(factors).count == factors.count)
    }

    /// Chat messages size on top of the app's text size, so they get one step
    /// smaller from the app's default alone, not two.
    @Test func defaultMessageTextIsOneStepSmaller() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let typeSize = BighelpInterfaceSize(defaults: defaults, isMac: false).dynamicTypeSize(onTopOf: .large)
        #expect(ChatTextSize.defaultSize == .small)
        let style = ChatNativeMarkdownStyle(
            primaryText: .label, secondaryText: .secondaryLabel, accent: .systemBlue,
            codeBackground: .secondarySystemBackground, proseLineSpacing: 5,
            traitCollection: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)),
            textScale: ChatTextSize.defaultSize.scale)
        let rendered = ChatNativeMarkdownAttributedBuilder.build(document: MarkdownDocument("Hello"), style: style)
        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        // 16pt before #729, on an iPhone at its own default text size.
        #expect(font.pointSize == 15)
    }

    private func freshDefaults() throws -> (UserDefaults, String) {
        let suite = "bighelp.tests.text-size.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func compactSpacingIsTighterThanComfortable() {
        #expect(ChatDensity.compact.messageSpacing < ChatDensity.comfortable.messageSpacing)
        #expect(ChatDensity.compact.bubbleVerticalPadding < ChatDensity.comfortable.bubbleVerticalPadding)
    }

    @Test func everyBuiltInSpeechProviderIsUniqueAndLocalOnesNeedNoKey() {
        let ids = VoiceProviderSpec.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        for spec in VoiceProviderSpec.builtIn where spec.kind == .onYourComputer || spec.kind == .free {
            #expect(spec.keyNames.isEmpty, "\(spec.id)")
        }
        #expect(VoiceProviderSpec.builtIn.filter(\.supportsServerURL).map(\.id) == ["openai"])
    }
}
