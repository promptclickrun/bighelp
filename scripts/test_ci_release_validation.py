import copy
import tempfile
import unittest
from pathlib import Path

from ci_ui_test_shard import assignments, selectors

from ci_release_validation import (
    PROFILE, UI_TESTS, WORKFLOW, completed_ui_tests, validate_receipt, validate_run,
)


class ReleaseValidationTests(unittest.TestCase):
    def test_discovery_keeps_native_and_shared_base_test_classes_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "BighelpUITests"
            tests.mkdir()
            (tests / "Native.swift").write_text("""
import XCTest
class BighelpUITestCase: XCTestCase {
    func makeApp() {}
}
@MainActor
final class NativeTests: XCTestCase {
    func testNativeLaunch() {}
}
final class SharedTests: BighelpUITestCase {
    @MainActor func testSharedLaunch() {}
}
""")
            self.assertEqual(selectors(root), [
                "-only-testing:BighelpUITests/NativeTests/testNativeLaunch",
                "-only-testing:BighelpUITests/SharedTests/testSharedLaunch",
            ])

    def test_discovery_rejects_test_methods_with_an_unknown_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "BighelpUITests"
            tests.mkdir()
            (tests / "Unknown.swift").write_text(
                "final class UnknownTests: UnknownBase {\n    func testUnknown() {}\n}\n"
            )
            with self.assertRaisesRegex(ValueError, "test class"):
                selectors(root)

    def test_current_shards_cover_every_test_once_and_have_real_ipad_assignments(self):
        root = Path(__file__).resolve().parents[1]
        shards = assignments(root)
        assigned = [test for tests in shards.values() for test in tests]
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertEqual(set(assigned), set(selectors(root)))
        self.assertIn(
            "-only-testing:BighelpUITests/AgentsUITests/testLastRowClearsSearchAndNavigationInPortraitAndLandscape",
            shards["ui-ipad"],
        )

    def test_every_release_ui_selector_exists_in_the_current_test_target(self):
        discovered = set(selectors(Path(__file__).resolve().parents[1]))
        self.assertEqual(len(UI_TESTS), len(set(UI_TESTS)))
        self.assertTrue(set("-only-testing:BighelpUITests/" + test for test in UI_TESTS) <= discovered)

    def setUp(self):
        self.tree = "a" * 40
        self.run = {"id": 123, "repository": {"full_name": "example/app"},
                    "path": WORKFLOW, "event": "pull_request", "status": "completed",
                    "conclusion": "success", "run_attempt": 2}
        self.receipt = {"profile": PROFILE, "run_id": 123, "run_attempt": 2,
                        "repository": "example/app", "source_tree": self.tree,
                        "ui_tests": list(UI_TESTS), "native_suite": "BighelpTests"}
        self.records = []
        for test in UI_TESTS:
            suite, method = test.split("/")
            self.records.extend(f"Test Case '-[BighelpUITests.{suite} {method}]' {state}."
                                for state in ("started", "passed"))
        self.log = "\n".join(self.records + ["Test run with 1705 tests passed.", "** TEST SUCCEEDED **"])

    def test_merge_commit_with_identical_source_tree_can_reuse_successful_validation(self):
        validate_receipt(self.receipt, self.run, self.tree, "example/app")
        self.assertEqual(completed_ui_tests(self.log), list(UI_TESTS))

    def test_changed_source_cannot_reuse_old_success(self):
        with self.assertRaises(ValueError):
            validate_receipt(self.receipt, self.run, "b" * 40, "example/app")

    def test_failed_cancelled_incomplete_foreign_or_wrong_workflow_run_is_rejected(self):
        for field, value in [("conclusion", "failure"), ("conclusion", "cancelled"),
                             ("status", "in_progress"), ("id", 124),
                             ("path", ".github/workflows/unrelated.yml"),
                             ("event", "push"), ("repository", {"full_name": "other/app"})]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                run = copy.deepcopy(self.run)
                run[field] = value
                validate_run(run, 123, "example/app")

    def test_old_attempt_wrong_profile_or_incomplete_coverage_is_rejected(self):
        for field, value in [("run_attempt", 1), ("profile", "unrelated"),
                             ("ui_tests", list(UI_TESTS[:-1])), ("native_suite", "")]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                receipt = copy.deepcopy(self.receipt)
                receipt[field] = value
                validate_receipt(receipt, self.run, self.tree, "example/app")

    def test_ui_skip_failure_omission_and_repetition_do_not_mint_receipts(self):
        for log in [self.log.replace("passed.", "skipped.", 1),
                    self.log.replace("passed.", "failed.", 1),
                    self.log.replace(self.records[1], ""),
                    self.log + "\n" + self.records[1]]:
            with self.subTest(log=log[:100]), self.assertRaises(ValueError):
                completed_ui_tests(log)

    def test_partial_logs_do_not_mint_receipts(self):
        with self.assertRaises(ValueError):
            completed_ui_tests("\n".join(self.records))


if __name__ == "__main__":
    unittest.main()
