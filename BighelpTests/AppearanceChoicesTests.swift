import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// Settings › Colors: the page and bubble picks reach the live theme and the
/// widgets.
@MainActor
struct AppearanceChoicesTests {
    private func theme(_ scheme: ColorScheme, light: BighelpLightBackground = .cream,
                       dark: BighelpDarkBackground = .graphite, bubble: BighelpBubbleColor? = nil,
                       contrast: ColorSchemeContrast = .standard) -> BighelpTheme {
        BighelpTheme.resolve(
            appearance: BighelpAppearanceContext(appearance: scheme == .dark ? .dark : .light,
                                                lightBackground: light, darkBackground: dark, bubbleColor: bubble),
            colorScheme: scheme, contrast: contrast)
    }

    @Test func pageColorsFollowTheLightAndDarkPicks() {
        #expect(theme(.light, light: .cream).canvasHex.uppercased() == "FFF9F5")
        #expect(theme(.light, light: .paper).canvasHex.uppercased() == "FFFFFF")
        #expect(theme(.dark, dark: .graphite).canvasHex.uppercased() == "1C1C1F")
        #expect(theme(.dark, dark: .black).canvasHex.uppercased() == "000000")
        // A light pick never changes dark mode, and the other way round.
        #expect(theme(.dark, light: .paper).canvasHex == theme(.dark, light: .cream).canvasHex)
        #expect(theme(.light, dark: .black).canvasHex == theme(.light, dark: .graphite).canvasHex)
    }

    @Test func bubbleColorsDriveTheActionColor() {
        // No pick is Ink, the default, the same as picking it.
        let ink = theme(.light)
        #expect(theme(.light, bubble: .graphite).actionHex == ink.actionHex)
        for bubble in BighelpBubbleColor.allCases where bubble != .graphite {
            let light = theme(.light, bubble: bubble)
            #expect(light.actionHex != ink.actionHex, "\(bubble) should change the bubble color")
            #expect(!light.actionForegroundHex.isEmpty)
        }
    }

    /// Your own messages in chat used bighelp's purple whatever you picked.
    @Test func yourChatBubblesUseThePickedColor() {
        for scheme in [ColorScheme.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let ink = UIColor(theme(scheme).outgoingMessageBackground).resolvedColor(with: traits)
            for bubble in [BighelpBubbleColor.ocean, .mint, .rose, .tangerine, .lavender] {
                let mine = UIColor(theme(scheme, bubble: bubble).outgoingMessageBackground).resolvedColor(with: traits)
                #expect(!mine.isEqual(ink), "\(bubble) bubbles in \(scheme) mode")
                if let hex = bubble.hex {
                    #expect(Self.hueDistance(mine, UIColor(Color(hex: hex))) < 0.03, "\(bubble) in \(scheme) mode")
                }
            }
        }
        // Ink, the default, is the same with or without the pick.
        #expect(theme(.light, bubble: .graphite).outgoingMessageBackground == theme(.light).outgoingMessageBackground)
    }

    @Test func aCustomColorWorksLikeTheBuiltInOnes() {
        func resolve(_ scheme: ColorScheme, bubble: BighelpBubbleColor? = nil, custom: String?) -> BighelpTheme {
            BighelpTheme.resolve(appearance: BighelpAppearanceContext(appearance: scheme == .dark ? .dark : .light,
                                                                     bubbleColor: bubble, customBubbleHex: custom),
                                 colorScheme: scheme, contrast: .standard)
        }
        for scheme in [ColorScheme.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let custom = resolve(scheme, custom: "0E7C66")
            #expect(custom.actionHex != theme(scheme).actionHex)
            let bubble = UIColor(custom.outgoingMessageBackground).resolvedColor(with: traits)
            #expect(Self.hueDistance(bubble, UIColor(Color(hex: "0E7C66"))) < 0.03)
            // The custom color wins over an older preset pick.
            #expect(resolve(scheme, bubble: .rose, custom: "0E7C66") == custom)
        }
        let extras = BighelpWidgetExtras()
        extras.update(appearance: BighelpAppearanceContext(appearance: .system, customBubbleHex: "0E7C66"))
        #expect(extras.lightPalette?.accentHex == resolve(.light, custom: "0E7C66").actionHex)
    }

    @Test func pickedColorsBecomeSixDigitHex() {
        #expect(BighelpCustomBubbleColor.hex(from: Color(hex: "12AB34")) == "12AB34")
        #expect(BighelpCustomBubbleColor.hex(from: Color(red: 1.2, green: -0.1, blue: 0.5)) == "FF0080")
        #expect(BighelpCustomBubbleColor.validated("#12ab34") == "12AB34")
        #expect(BighelpCustomBubbleColor.validated("12AB3") == nil)
        #expect(BighelpCustomBubbleColor.validated("GGGGGG") == nil)
    }

    private static func hueDistance(_ a: UIColor, _ b: UIColor) -> CGFloat {
        var (ha, hb): (CGFloat, CGFloat) = (0, 0)
        a.getHue(&ha, saturation: nil, brightness: nil, alpha: nil)
        b.getHue(&hb, saturation: nil, brightness: nil, alpha: nil)
        let distance = abs(ha - hb)
        return min(distance, 1 - distance)
    }

    @Test func highContrastKeepsItsOwnPages() {
        #expect(theme(.light, light: .cream, contrast: .increased).canvasHex
                == theme(.light, light: .paper, contrast: .increased).canvasHex)
    }

    @Test func widgetsGetTheSameColors() {
        let extras = BighelpWidgetExtras()
        extras.update(appearance: BighelpAppearanceContext(appearance: .system,
                                                          lightBackground: .paper, darkBackground: .black,
                                                          bubbleColor: .teal))
        #expect(extras.lightPalette?.canvasHex.uppercased() == "FFFFFF")
        #expect(extras.darkPalette?.canvasHex.uppercased() == "000000")
        #expect(extras.lightPalette?.accentHex == theme(.light, light: .paper, bubble: .teal).actionHex)
    }
}

@MainActor
struct BighelpAgentWidgetDataTests {
    @Test func agentLinksOpenTheAgentHomeTabs() {
        for tab in ["chat", "feed", "ideas", "goals", "apps"] {
            #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.agentURL(tab)) == .agent(tab: tab))
        }
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://agent/elsewhere")!) == .agent(tab: "chat"))
    }

    @Test func olderSnapshotsStillDecode() throws {
        let json = #"{"defaultAgentID":"default","defaultAgentName":"Juno","generatedAt":1800000000,"#
            + #""sessions":[{"id":"a","title":"T","agentName":"Juno","status":"Replied","isRunning":false,"updatedAt":1800000000}],"#
            + #""tasks":[]}"#
        let snapshot = try JSONDecoder.bighelpWidget.decode(BighelpWidgetSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.sessions.first?.agentID == nil)
        #expect(snapshot.feed == nil && snapshot.lightPalette == nil)
        #expect(snapshot.agentPose == nil)
    }

    @Test func theAgentWidgetShowsTheDefaultAgentsWork() {
        var snapshot = BighelpWidgetSnapshot.preview
        #expect(snapshot.agentPose == .coding)
        #expect(snapshot.agentRunningSession?.id == "a")
        snapshot.sessions = snapshot.sessions.map { session in
            var copy = session
            copy.activity = nil
            return copy
        }
        // Running without a known kind of work still reads as thinking.
        #expect(snapshot.agentPose == .thinking)
        snapshot.sessions = []
        #expect(snapshot.agentPose == nil)
        #expect(snapshot.agentDisplayName == "Juno")
    }
}
