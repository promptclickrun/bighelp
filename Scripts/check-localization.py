#!/usr/bin/env python3
"""Validate the staged catalog without building the app (Python standard library only)."""

from collections import Counter
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Bighelp/Resources/Localizable.xcstrings"
# Representative boundaries; this is intentionally not a whole-app coverage claim.
REQUIRED = {
    "Your bots, right at home.", "Get Started", "Connect your computer",
    "Add the Bighelp plugin", "Use %@", "Chat", "Feed",
    "Ideas", "Goals", "Files", "Agents", "Settings", "New chat", "Send message",
    "Stop response", "Message %@", "Ask %@", "Appearance", "Your name", "Done",
    "Advanced options", "Default model", "AI providers", "Help & feedback",
    "Add", "Voice mode", "Drawing",
    "Document scanning requires a supported camera device.",
    "PDF pages require a current native Hermes conversation.",
    "hermes.example.com or 192.168.1.20",
}
# The Bots view, Teamwork and the Settings pages they open (#527).
SIMPLE_BOTS_AND_TEAMWORK = {
    "Search bots", "New Bot", "New Group Chat", "Mark Unread", "Mark Read", "Pin", "Unpin",
    "Make Primary Bot", "Replace Primary Bot…", "Rearrange", "Hide", "Bot Profile", "Templates",
    "Drag your bots and group chats into the order you want, then tap Save.", "No bots yet",
    "Create New Bot", "Instructions", "Default Model", "Routines", "Computer", "Media", "Character",
    "Your computer isn't connected", "Saved. This is how %@ looks everywhere.",
    "Auto-review", "Your computers", "Your bots see your name.",
    "Asked %@", "%@ answered", "%@ didn't answer", "Asking %@…", "Waiting for %@",
    "%@ is working on it…", "%lld messages with %@", "%@ and %@", "%@, %@ and %@",
    "What %@ did", "Bots ask each other for help",
    "The computer didn't save it for %@. Try again.",
    "Bots messaging each other", "Quiet hours", "Notify me about", "Send a test",
    "Turn off notifications", "Channels", "Opens on", "Return sends", "A bot opens",
    "Chat layout", "Light mode", "Dark mode", "Text and buttons",
    "Bots", "Chat", "Code",
}
# The one home's screens: the header and bar, Chats, New chat, Today, Work, spaces, the bot page
# and the first-run question (#977).
ONE_HOME = {
    "Today", "Work", "Chats", "Sidebar", "Recent chats", "Bot page", "Pick a chat, or start a new one.",
    "Search chats", "Chat name", "Mark unread", "Archive", "No chats yet", "No chats on %@",
    "%@ isn't connected. Showing its last chats.",
    "Add a bot", "Group chats", "Where should this chat run?", "How should this chat work?", "Stage",
    "Send all %lld", "Group chat · %lld bots", "%lld coding sessions in %@",
    "Group chats start with text only", "Starting the chat…",
    "How do you want to start?", "With a bot", "Across chats", "First tab shows",
    "Approvals", "Handle", "Delete bot", "Chats with this bot",
    "Make a space", "Add to Today", "Delete this space?", "Updated %@", "Try again in a minute",
    "Hide from Today", "Every panel is hidden. Tap Edit to show one.",
    "Nothing needs you", "Open a board", "Pull requests (%lld)", "step %lld of %lld",
    "Open Work, then try again.",
}
PLURALS = {"%lld messages with %@"}
# These screens' plain-String parameters show text verbatim, so app copy handed to them has to be
# resolved with String(localized:) first. A bare English literal here never reaches the catalog.
SCOPED_SOURCES = [
    *sorted((ROOT / "Bighelp/SimpleBots").glob("*.swift")),
    *sorted((ROOT / "Bighelp/Home").rglob("*.swift")),
    *sorted((ROOT / "Bighelp/Today").glob("*.swift")),
    *sorted((ROOT / "Bighelp/Work").glob("*.swift")),
    *sorted((ROOT / "Bighelp/Spaces").glob("*.swift")),
    ROOT / "Bighelp/Chat/ChatNewChatSlot.swift", ROOT / "Bighelp/Hosts/FirstRunOnboardingSteps.swift",
    ROOT / "Bighelp/App/RootSimpleBots.swift", ROOT / "Bighelp/Agents/Teamwork.swift",
    ROOT / "Bighelp/Chat/ChatAgentTalkRail.swift", ROOT / "Bighelp/Settings/SettingsView.swift",
    ROOT / "Bighelp/Settings/SettingsView+Preferences.swift", ROOT / "Bighelp/Settings/SettingsView+Identity.swift",
    ROOT / "Bighelp/Settings/ChatLayoutSettingsView.swift", ROOT / "Bighelp/Settings/AppearanceStudioView.swift",
    ROOT / "Bighelp/Settings/AppearanceSizeControls.swift",
    ROOT / "Bighelp/Settings/BighelpNotificationSettingsView.swift",
]
VERBATIM = re.compile(
    r'\b(?:SimpleBotsRow|SimpleBotsSectionLabel|SimpleBotsMessageCard)\([^()]*?\b(?:title|detail):\s*"'
    r'|\b(?:rowText|settingLabel|settingTitle|note)\(\s*"'
    r'|\bsettingsPage\(title:\s*"'
    r'|\b(?:errorMessage|saveState|notice|hideError|templateNotice|testMessage|turnOffMessage|preferenceError'
    r'|runtimeError|avatarError|actionErrorMessage|quietHoursNote)\s*=\s*(?:[^"\n]*\?\s*)?"[A-Z]'
    r'|\?\?\s*"[A-Z][a-z]+[ .…’\']'
    r'|\breplacingOccurrences\(of:\s*"agents?"', re.S)
# A new bot's fallback role and instructions are saved on the host as the bot's own words, not shown as app copy.
# New chat's `note(_:)` takes a LocalizedStringKey, unlike the Settings helper of the same name.
SAVED_DATA = {("SimpleBotTemplates.swift", '?? "You '), ("SimpleBotTemplates.swift", '?? "Everyday '),
              ("NewChatView.swift", 'note("')}

# App-written error messages (#1039): the shell's alert text, voice errors and the Mixture of Agents page.
# They are plain Strings, so each is translated where it is made. A host's own words pass through as they came.
SHELL_SOURCES = sorted((ROOT / "Bighelp/App").glob("*.swift"))
ERROR_SOURCES = [
    *(ROOT / "Bighelp/Voice" / f"{name}.swift" for name in (
        "LiveVoiceUnavailable", "LiveVoiceModel", "LiveVoiceControlClient", "BighelpRealtimeAudioPeer",
        "VoiceModel", "VoicePresentationContainer", "GeminiLiveWire")),
    ROOT / "Bighelp/WorkspaceManagement/Providers/ModelsMixtureOfAgentsView.swift",
    ROOT / "Bighelp/Fleet/FleetSwitchFallback.swift",
]
BARE_LITERAL = re.compile(r'(?<!localized: )"(?:[^"\\\n]|\\.)*"')
# A sentence a person reads: a capital, more than one word, and a full stop or an ellipsis.
SENTENCE = re.compile(r'^"(?:[A-Z]|\\\()[^"]* [^"]*[.…]"$')
# SwiftUI translates a literal these take; a logger's line and an answer to the model are not app copy.
NOT_PLAIN_STRINGS = re.compile(r'\b(?:Text|Label|Button|Section|Toggle|Picker|ProgressView|LabeledContent|'
                               r'accessibility\w+|navigationTitle|alert|confirmationDialog|Logger|logger|log)\(\s*"'
                               r'|\.(?:error|info|debug|notice|warning|fault)\("|\.string\("|assert\w*\(|precondition')
ERRORS = {
    "This chat couldn't be opened. Try again from Chats.", "Connect to your computer to use Workflows.",
    "Couldn't reach %@. You're still on %@.", "This chat couldn't be opened. %@",
    "Live voice isn't available", "Gemini ended the call. Gemini said: “%@” Work you started keeps going.",
    "Your computer didn't answer in time. Try again.", "Voice chat could not end. Try again.",
    "Hermes could not confirm this model operation. Refresh before trying it again.",
}


def units(node):
    if "stringUnit" in node:
        yield node["stringUnit"]
    for child in node.values():
        if isinstance(child, dict):
            yield from units(child)


def placeholders(text):
    # Positional arguments may move, but their count and types must stay intact.
    return Counter(re.findall(r"%(?:\d+\$)?(lld|ld|llu|lu|@|d|u|f)", text.replace("%%", "")))


class LocalizationCatalogChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads(CATALOG.read_text())
        cls.strings = cls.catalog["strings"]

    def test_english_is_the_development_source(self):
        self.assertEqual(self.catalog["sourceLanguage"], "en")
        self.assertIn("developmentLanguage: en", (ROOT / "project.yml").read_text())
        self.assertIn("SWIFT_EMIT_LOC_STRINGS: YES", (ROOT / "project.yml").read_text())

    def test_initial_surfaces_have_chinese(self):
        for key in REQUIRED:
            with self.subTest(key=key):
                values = list(units(self.strings[key]["localizations"]["zh-Hans"]))
                self.assertTrue(values)
                self.assertTrue(all(unit["value"].strip() for unit in values))

    def test_simple_bots_teamwork_and_their_settings_have_chinese(self):
        for key in SIMPLE_BOTS_AND_TEAMWORK:
            with self.subTest(key=key):
                self.assertTrue(key in self.strings, f"{key!r} is missing from the catalog")
                values = list(units(self.strings[key]["localizations"]["zh-Hans"]))
                self.assertTrue(values)
                self.assertTrue(all(unit["value"].strip() for unit in values))

    def test_one_home_screens_have_chinese(self):
        for key in ONE_HOME:
            with self.subTest(key=key):
                self.assertTrue(key in self.strings, f"{key!r} is missing from the catalog")
                values = list(units(self.strings[key]["localizations"]["zh-Hans"]))
                self.assertTrue(values)
                self.assertTrue(all(unit["value"].strip() for unit in values))

    def test_counts_use_plural_variations(self):
        for key in PLURALS:
            with self.subTest(key=key):
                for language in ("en", "zh-Hans"):
                    self.assertIn("plural", self.strings[key]["localizations"][language].get("variations", {}))

    def test_scoped_screens_resolve_copy_before_verbatim_helpers(self):
        for source in SCOPED_SOURCES:
            text = "\n".join(line for line in source.read_text().splitlines()
                             if not line.lstrip().startswith("//"))
            for match in VERBATIM.finditer(text):
                if (source.name, match.group(0)) in SAVED_DATA:
                    continue
                line = text.count("\n", 0, match.start()) + 1
                with self.subTest(source=source.name, line=line):
                    self.fail(f"{source.relative_to(ROOT)}:{line} passes English to a plain String: {match.group(0)!r}")

    def test_error_messages_have_chinese(self):
        for key in ERRORS:
            with self.subTest(key=key):
                self.assertTrue(key in self.strings, f"{key!r} is missing from the catalog")
                values = list(units(self.strings[key]["localizations"]["zh-Hans"]))
                self.assertTrue(values)
                self.assertTrue(all(unit["value"].strip() for unit in values))

    def test_the_shell_translates_each_error_where_it_is_made(self):
        for source in SHELL_SOURCES:
            lines = source.read_text().splitlines()
            for number, line in enumerate(lines):
                if not re.search(r"\bactionErrorMessage\s*=[^=]", line):
                    continue
                # The statement: its line and the lines indented under it.
                indent = len(line) - len(line.lstrip())
                end = number + 1
                while end < len(lines) and lines[end].strip() and len(lines[end]) - len(lines[end].lstrip()) > indent:
                    end += 1
                for offset, part in enumerate(lines[number:end]):
                    if part.lstrip().startswith("//"):
                        continue
                    for literal in BARE_LITERAL.findall(part):
                        if re.match(r'"[A-Z]', literal):
                            with self.subTest(source=source.name, line=number + offset + 1):
                                self.fail(f"{source.relative_to(ROOT)}:{number + offset + 1} sets an English error: {literal}")

    def test_voice_and_model_page_errors_are_translated_where_they_are_made(self):
        for source in ERROR_SOURCES:
            for number, line in enumerate(source.read_text().splitlines(), 1):
                if line.lstrip().startswith("//") or NOT_PLAIN_STRINGS.search(line):
                    continue
                for literal in BARE_LITERAL.findall(line):
                    if SENTENCE.match(literal):
                        with self.subTest(source=source.name, line=number):
                            self.fail(f"{source.relative_to(ROOT)}:{number} is an English sentence in a plain String: {literal}")

    def test_placeholders_and_review_state(self):
        for key, entry in self.strings.items():
            for language, localized in entry.get("localizations", {}).items():
                for unit in units(localized):
                    with self.subTest(key=key, language=language):
                        self.assertEqual(placeholders(key), placeholders(unit["value"]))
                        self.assertNotIn(unit["state"], ("new", "stale"))

    def test_plural_rules_are_language_specific(self):
        for entry in self.strings.values():
            for language, localized in entry.get("localizations", {}).items():
                plural = localized.get("variations", {}).get("plural")
                if plural:
                    self.assertIn("other", plural)
                    if language == "en":
                        self.assertIn("one", plural)
                    if language == "zh-Hans":
                        self.assertEqual(set(plural), {"other"})

    def test_catalog_contains_copy_not_storage_or_protocol_ids(self):
        for key in self.strings:
            self.assertFalse(key.startswith(("loopdy.", "bighelp.", "chat.", "settings.", "onboarding.")), key)
            self.assertNotIn(key, {"session.create", "prompt.submit", "steer", "queued", "zh-Hans"})


if __name__ == "__main__":
    unittest.main()
