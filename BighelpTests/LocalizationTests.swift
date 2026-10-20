import Foundation
import Testing
@testable import Bighelp

struct LocalizationTests {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func compiledCatalogContainsTheInitialLanguages() throws {
        for (language, expected) in [("en", "Settings"), ("zh-Hans", "设置")] {
            #expect(try bundle(language).localizedString(forKey: "Settings", value: nil, table: nil) == expected)
        }
        #expect(Bundle.main.developmentLocalization == "en")
    }

    @Test func uncoveredCopyAndUnsupportedLanguagesFallBackToEnglish() throws {
        // A real deeper Settings heading deliberately left untranslated in this stage.
        #expect(try bundle("zh-Hans").localizedString(forKey: "Connection details", value: nil, table: nil)
                == "Connection details")
        let fallback = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["fr"])
        #expect(fallback.first == "en")
    }

    @Test func interpolatedNamesStayVerbatimEvenWhenTheyMatchACatalogKey() throws {
        let name = "Settings / 海风 🐚"
        let chinese = try bundle("zh-Hans")
        let english = try bundle("en")
        #expect(String(localized: "Message \(name)", bundle: chinese, locale: Locale(identifier: "zh-Hans"))
                == "给Settings / 海风 🐚发消息")
        #expect(String(localized: "Message \(name)", bundle: english, locale: Locale(identifier: "en"))
                == "Message Settings / 海风 🐚")
    }

    @Test func pluralCatalogUsesEnglishAndChineseRules() throws {
        let chinese = try bundle("zh-Hans")
        let english = try bundle("en")
        for count in [0, 1, 2, 12] {
            let en = String(localized: "Your \(count) agents know each other and ask each other for help.",
                            bundle: english, locale: Locale(identifier: "en"))
            let zh = String(localized: "Your \(count) agents know each other and ask each other for help.",
                            bundle: chinese, locale: Locale(identifier: "zh-Hans"))
            #expect(en == (count == 1 ? "Your 1 agent can ask other agents for help."
                          : "Your \(count) agents know each other and ask each other for help."))
            #expect(zh == "你的 \(count) 个智能体会了解彼此，并相互寻求帮助。")
        }
    }

    @Test func localizedDisplayNamesDoNotChangeSavedNavigationOrSendBehavior() throws {
        let layout = BighelpAppLayout(pinned: [.agents, .feed], menuOrder: [.settings])
        let saved = try #require(layout.saved)
        #expect(saved.contains("agents") && saved.contains("feed") && saved.contains("settings"))
        #expect(BighelpAppLayout(saved: saved) == layout)
        #expect(MidSessionChatBehavior.steer.rawValue == "steer")
        #expect(FirstRunMode.bots.rawValue == "bots")
    }
}
