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
