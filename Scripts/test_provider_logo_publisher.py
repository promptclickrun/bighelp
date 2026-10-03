import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProviderLogoPublisherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / "Scripts/publish-provider-logos.py"
        if path.is_file():
            spec = importlib.util.spec_from_file_location("provider_logo_publisher", path)
            assert spec is not None and spec.loader is not None
            cls.publisher = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.publisher)

    def test_rejects_active_or_external_svg_content(self):
        for body in [
            '<script>alert(1)</script>',
            '<image href="https://example.org/private.png"/>',
            '<foreignObject><div>html</div></foreignObject>',
            '<rect onload="alert(1)"/>',
            '<rect fill="url(https://example.org/pixels)"/>',
        ]:
            svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8">' + body + '</svg>').encode()
            with self.subTest(body=body), self.assertRaises(self.publisher.ExportError):
                self.publisher.validate_svg(svg)

    def test_rejects_ambiguous_json(self):
        with self.assertRaises(self.publisher.ExportError):
            self.publisher.load_json(b'{"revision": "one", "revision": "two"}')

    def test_export_is_repeatable_and_rejects_unrelated_public_files(self):
        with tempfile.TemporaryDirectory(prefix="loopdy-logos-repeat-") as output:
            path = Path(output)
            first, first_count = self.publisher.export(path)
            second, second_count = self.publisher.export(path)
            self.assertEqual(first, second)
            self.assertEqual(first_count, second_count)
            (path / "private-note.txt").write_text("do not publish")
            with self.assertRaises(self.publisher.ExportError):
                self.publisher.validate_output(path)

    def test_exports_both_appearances_of_every_approved_logo(self):
        script = ROOT / "Scripts" / "publish-provider-logos.py"
        self.assertTrue(script.is_file(), "Provider logo static-asset publisher is not implemented")
        with tempfile.TemporaryDirectory(prefix="loopdy-logos-") as output:
            result = subprocess.run(["python3", str(script), "--output", output], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            base = Path(output) / "provider-logos" / "v1"
            catalog = json.loads((base / "manifest.json").read_text())
            self.assertEqual(catalog["schemaVersion"], 1)
            sets = sorted((ROOT / "Bighelp/Resources/Assets.xcassets").glob("ProviderLogo*.imageset"))
            self.assertEqual(set(catalog["logos"]), {s.stem for s in sets})
            for name, entry in catalog["logos"].items():
                self.assertEqual(set(entry), {"light", "dark"})
                for appearance, image in entry.items():
                    data = (base / image["path"]).read_bytes()
                    self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"), (name, appearance))
                    digest = hashlib.sha256(data).hexdigest()
                    self.assertEqual(image["sha256"], digest)
                    self.assertEqual(image["path"], f"images/{digest}.png")
                    self.assertLessEqual(len(data), 1024 * 1024)
            self.assertTrue((Path(output) / "_headers").is_file())
            self.assertTrue((Path(output) / "ProviderLogos-NOTICES.txt").is_file())


if __name__ == "__main__":
    unittest.main()
