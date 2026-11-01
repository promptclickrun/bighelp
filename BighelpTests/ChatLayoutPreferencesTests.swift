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

    // The app-wide text size (#729). These use raw values, which are what's saved.

    @Test func appTextStartsOneStepUnderTheDeviceAndWritesNothing() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let size = BighelpInterfaceSize(defaults: defaults)
        #expect(size.textSize.rawValue == -1)
        #expect(size.textSize == .platformDefault)
        // `BighelpTextSizing` steps the device's own size by it.
        #expect(DynamicTypeSize.large.stepped(by: size.textSize.rawValue) == .medium)
        // The Mac's body text: 14pt, from 16pt.
        #expect((17 * size.textSize.macFactor * 2).rounded() / 2 == 14)
        // Opening the app saves nothing, so the default reaches everyone who never picked one.
        #expect(defaults.object(forKey: BighelpInterfaceSize.textSizeKey) == nil)
    }

    @Test func aSavedAppTextSizeStaysTheSameSize() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Every size someone could pick before #729, with the Mac's size for it then.
        let picks: [(raw: Int, macFactor: CGFloat)] = [(-1, 0.82), (0, 0.94), (1, 1.03), (2, 1.12), (3, 1.22)]
        for pick in picks {
            defaults.set(pick.raw, forKey: BighelpInterfaceSize.textSizeKey)
            let size = BighelpInterfaceSize(defaults: defaults).textSize
            #expect(size.rawValue == pick.raw)
            #expect(size.macFactor == pick.macFactor)
        }
        // Someone who picked the old Default keeps that size, now named for what it is.
        defaults.set(0, forKey: BighelpInterfaceSize.textSizeKey)
        #expect(BighelpInterfaceSize(defaults: defaults).textSize.title == "Medium")
    }

    @Test func resetGoesToTheNewDefaultAndSmallerTextHasRoomBelowIt() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let size = BighelpInterfaceSize(defaults: defaults)
        size.textSize = try #require(BighelpTextSize(rawValue: 3))
        size.reset()
        #expect(size.textSize.rawValue == -1)
        // ⌘− goes one step under Default, and no further.
        size.stepText(by: -1)
        #expect(size.textSize.rawValue == -2)
        size.stepText(by: -1)
        #expect(size.textSize.rawValue == -2)
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

        let typeSize = DynamicTypeSize.large.stepped(by: BighelpInterfaceSize(defaults: defaults).textSize.rawValue)
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
