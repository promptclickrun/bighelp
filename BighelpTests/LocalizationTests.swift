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

    @Test func simpleBotModeTeamworkAndTheirSettingsHaveChinese() throws {
        let chinese = try bundle("zh-Hans")
        let english = try bundle("en")
        let expected = [
            ("Search bots", "搜索机器人"), ("Mark Unread", "标为未读"), ("Make Primary Bot", "设为主机器人"),
            ("Rearrange", "重新排列"), ("Instructions", "指令"), ("Default Model", "默认模型"),
            ("Routines", "例行任务"), ("Teamwork", "团队协作"), ("Agents messaging each other", "智能体之间的消息"),
            ("Quiet Hours", "勿扰时段"), ("Chat layout", "聊天布局"), ("Multi-gateway", "多网关"),
            ("Bots", "机器人"), ("Chat", "聊天"), ("Code", "代码"), ("Bots mode", "机器人模式"),
            ("Code mode", "代码模式"), ("Unified Mode Toggle", "统一模式切换"),
        ]
        for (key, value) in expected {
            #expect(chinese.localizedString(forKey: key, value: nil, table: nil) == value)
            #expect(english.localizedString(forKey: key, value: nil, table: nil) == key)
        }
    }

    @Test func teamworkLineKeepsNamesAndCountsInBothLanguages() throws {
        let chinese = try bundle("zh-Hans")
        let english = try bundle("en")
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        // Names are data: one that matches a catalog key still shows as written.
        let name = "Settings / 海风"
        #expect(String(localized: "Asked \(name)", bundle: chinese, locale: zh) == "已询问Settings / 海风")
        #expect(String(localized: "Asked \(name)", bundle: english, locale: en) == "Asked Settings / 海风")
        #expect(String(localized: "\(name) answered", bundle: chinese, locale: zh) == "Settings / 海风已回答")
        let names = String(localized: "\("Mina Shah") and \(name)", bundle: chinese, locale: zh)
        #expect(names == "Mina Shah和Settings / 海风")
        for count in [1, 2, 4] {
            #expect(String(localized: "\(count) messages with \(name)", bundle: english, locale: en)
                    == (count == 1 ? "1 message with \(name)" : "\(count) messages with \(name)"))
            #expect(String(localized: "\(count) messages with \(names)", bundle: chinese, locale: zh)
                    == "与Mina Shah和Settings / 海风交流了 \(count) 条消息")
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
