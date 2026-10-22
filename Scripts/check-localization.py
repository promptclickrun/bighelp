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
    "Your agents, right at home.", "Get Started", "Connect your computer",
    "Add the bighelp plugin", "Choose your mode", "Use %@", "Chat", "Feed",
    "Ideas", "Goals", "Files", "Agents", "Settings", "New chat", "Send message",
    "Stop response", "Message %@", "Ask %@", "Appearance", "Your name", "Done",
    "Nerd Mode", "Default model", "AI providers", "Help & feedback",
    "Add", "Voice mode", "PDF as pages",
    "Document scanning requires a supported camera device.",
    "PDF pages require a current native Hermes conversation.",
    "hermes.example.com or 192.168.1.20",
}
# Simple Bot mode, Teamwork and the Settings pages they open (#527).
SIMPLE_BOTS_AND_TEAMWORK = {
    "Search bots", "New Bot", "New Group Chat", "Mark Unread", "Mark Read", "Pin", "Unpin",
    "Make Primary Bot", "Replace Primary Bot…", "Rearrange", "Hide", "Bot Profile", "Templates",
    "Drag your bots and group chats into the order you want, then tap Save.", "No bots yet",
    "Create New Bot", "Instructions", "Default Model", "Routines", "Computer", "Media", "Character",
    "Your computer isn't connected", "Saved. This is how %@ looks everywhere.", "End voice",
    "Auto-review", "Multi-gateway", "All Settings", "Your name and photo in chats",
    "Asked %@", "%@ answered", "%@ didn't answer", "Asking %@…", "Waiting for %@",
    "%@ is working on it…", "%lld messages with %@", "%@ and %@", "%@, %@ and %@",
    "What %@ did", "Your bots learn about each other and ask each other for help.",
    "Your %lld bots know each other and ask each other for help.",
    "The computer didn't save it for %@. Try again.",
    "Agents messaging each other", "Quiet Hours", "Notify Me About", "Send Test Notification",
    "Turn Off Notifications", "Channels", "Open on", "Return sends", "Bot chat experience",
    "Chat layout", "App layout", "Light mode", "Dark mode", "Text and buttons", "Bottom bar",
}
PLURALS = {"Your %lld agents know each other and ask each other for help.",
           "Your %lld bots know each other and ask each other for help.", "%lld messages with %@"}
# These screens' plain-String parameters show text verbatim, so app copy handed to them has to be
# resolved with String(localized:) first. A bare English literal here never reaches the catalog.
SCOPED_SOURCES = [
    *sorted((ROOT / "Bighelp/SimpleBots").glob("*.swift")),
    ROOT / "Bighelp/App/RootSimpleBots.swift", ROOT / "Bighelp/Agents/Teamwork.swift",
    ROOT / "Bighelp/Chat/ChatAgentTalkRail.swift", ROOT / "Bighelp/Settings/SettingsView.swift",
    ROOT / "Bighelp/Settings/SettingsView+Preferences.swift", ROOT / "Bighelp/Settings/SettingsView+Identity.swift",
    ROOT / "Bighelp/Settings/ChatLayoutSettingsView.swift", ROOT / "Bighelp/Settings/AppearanceStudioView.swift",
    ROOT / "Bighelp/Settings/AppearanceSizeControls.swift", ROOT / "Bighelp/Settings/AppLayoutSettingsView.swift",
    ROOT / "Bighelp/Settings/BighelpNotificationSettingsView.swift",
]
VERBATIM = re.compile(
    r'\b(?:SimpleBotsRow|SimpleBotsSectionLabel|SimpleBotsMessageCard)\([^()]*?\b(?:title|detail):\s*"'
    r'|\b(?:rowText|settingLabel|note)\(\s*"'
    r'|\bsettingsPage\(title:\s*"'
    r'|\b(?:errorMessage|saveState|notice|hideError|templateNotice|testMessage|turnOffMessage|preferenceError'
    r'|runtimeError|avatarError|actionErrorMessage|quietHoursNote)\s*=\s*(?:[^"\n]*\?\s*)?"[A-Z]'
    r'|\?\?\s*"[A-Z][a-z]+[ .…’\']'
    r'|\breplacingOccurrences\(of:\s*"agents?"', re.S)
# A new bot's fallback role and instructions are saved on the host as the bot's own words, not shown as app copy.
SAVED_DATA = {("SimpleBotTemplates.swift", '?? "You '), ("SimpleBotTemplates.swift", '?? "Everyday ')}


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
