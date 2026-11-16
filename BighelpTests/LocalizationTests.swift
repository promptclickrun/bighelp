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
        let name = "Mina"
        for count in [0, 1, 2, 12] {
            let en = String(localized: "\(count) messages with \(name)", bundle: english, locale: Locale(identifier: "en"))
            let zh = String(localized: "\(count) messages with \(name)", bundle: chinese,
                            locale: Locale(identifier: "zh-Hans"))
            #expect(en == (count == 1 ? "1 message with Mina" : "\(count) messages with Mina"))
            #expect(zh == "与Mina交流了 \(count) 条消息")
        }
    }

    @Test func botsTeamworkTheHomeAndTheirSettingsHaveChinese() throws {
        let chinese = try bundle("zh-Hans")
        let english = try bundle("en")
        let expected = [
            ("Search bots", "搜索机器人"), ("Mark Unread", "标为未读"), ("Make Primary Bot", "设为主机器人"),
            ("Rearrange", "重新排列"), ("Instructions", "指令"), ("Default Model", "默认模型"),
            ("Routines", "例行任务"), ("Teamwork", "团队协作"), ("Bots messaging each other", "机器人之间的消息"),
            ("Quiet hours", "勿扰时段"), ("Chat layout", "聊天布局"), ("Show every computer", "显示所有电脑"),
            ("Bots", "机器人"), ("Chats", "聊天"), ("Today", "今天"), ("Work", "工作"),
            ("Make a space", "创建空间"), ("How do you want to start?", "你想怎么开始？"),
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
        #expect(HomeLanding.allCases.map(\.rawValue) == ["bots", "chats", "today", "work"])
        #expect(HomeConversationsView.bots.rawValue == "bots")
        #expect(MidSessionChatBehavior.steer.rawValue == "steer")
        #expect(FirstRunHome.bots.rawValue == "bots")
    }

    /// App-written errors are plain Strings, so each is translated where it is made (#1039): the
    /// shell's alert, voice errors and the Mixture of Agents page.
    @Test func appWrittenErrorsHaveChinese() throws {
        let chinese = try bundle("zh-Hans")
        let english = try bundle("en")
        let expected = [
            ("Connect to your computer to use Workflows.", "请连接到你的电脑以使用工作流。"),
            ("This chat could not be prepared. Try again.", "无法准备这个聊天。请重试。"),
            ("Live voice isn't available", "实时语音不可用"),
            ("Your computer didn't answer in time. Try again.", "你的电脑没有及时应答。请重试。"),
            ("Voice chat could not end. Try again.", "无法结束语音聊天。请重试。"),
            ("Hermes could not confirm this model operation. Refresh before trying it again.", "Hermes 无法确认这项模型操作。请先刷新，再重试。"),
        ]
        for (key, value) in expected {
            #expect(chinese.localizedString(forKey: key, value: nil, table: nil) == value)
            #expect(english.localizedString(forKey: key, value: nil, table: nil) == key)
        }
    }

    /// What a computer or a provider said goes into the translated sentence exactly as it came, and so
    /// do names, even one that is a catalog key itself.
    @Test func aHostsOwnWordsPassThroughTranslatedErrors() throws {
        let chinese = try bundle("zh-Hans")
        let zh = Locale(identifier: "zh-Hans")
        let hostWords = "Session busy: Settings / 海风 🐚."
        #expect(String(localized: "This chat couldn't be opened. \(hostWords)", bundle: chinese, locale: zh)
                == "无法打开这个聊天。Session busy: Settings / 海风 🐚.")
        #expect(String(localized: "Gemini didn't start the call. Gemini said: “\(hostWords)”", bundle: chinese, locale: zh)
                == "Gemini 未能开始通话。Gemini 表示：“Session busy: Settings / 海风 🐚.”")
        // Two names keep their places.
        #expect(String(localized: "Couldn't reach \("Settings"). You're still on \("Desk").", bundle: chinese, locale: zh)
                == "无法连接到Settings。你仍在使用Desk。")
        // The app's own code makes these with the phone's language; here that is English.
        #expect(FleetSwitchFallback.message(unreachable: "Studio", stillOn: "Desk") == "Couldn't reach Studio. You're still on Desk.")
        #expect(LiveVoiceUnavailable.connecting.title == "Not connected yet")
        // A code is text, never a number with a thousands separator.
        #expect(GeminiLiveClose(ready: false, code: 1011).message == "Gemini didn't start the call (code 1011).")
    }
}
