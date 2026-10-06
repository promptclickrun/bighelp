import CoreGraphics
import Foundation
import SwiftUI
import Testing
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
