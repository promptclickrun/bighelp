"""Assign every UI test once across four phone shards and one real iPad lane."""

import argparse
import json
import re
import sys
from pathlib import Path


IPAD_TESTS = (
    "AgentsUITests/testLastRowClearsSearchAndNavigationInPortraitAndLandscape",
)
SELECTOR_PREFIX = "-only-testing:BighelpUITests/"


def selectors(root: Path) -> list[str]:
    tests = []
    method_pattern = re.compile(r"^\s*(?:@MainActor\s+)?func\s+(test\w+)\s*\(\s*\)", re.MULTILINE)
    class_pattern = re.compile(
        r"^(?:@MainActor\s+)?(?:final\s+)?class\s+(\w+)(?:\s*:\s*(\w+))?",
        re.MULTILINE,
    )
    for path in sorted((root / "BighelpUITests").glob("*.swift")):
        source = path.read_text()
        methods = list(method_pattern.finditer(source))
        if not methods:
            continue
        # A shared base and several concrete suites may occupy one file. Bind
        # each method to its top-level class rather than borrowing another
        # suite's name, and never silently omit an unrecognized test class.
        classes = list(class_pattern.finditer(source))
        for method in methods:
            preceding = [declaration for declaration in classes if declaration.start() < method.start()]
            if not preceding or preceding[-1].group(2) not in {"XCTestCase", "BighelpUITestCase"}:
                raise ValueError(f"Unrecognized UI test class in {path}: {method.group(1)}")
            tests.append(f"{SELECTOR_PREFIX}{preceding[-1].group(1)}/{method.group(1)}")
    if not tests or len(tests) != len(set(tests)):
        raise ValueError("UI test selection is empty or contains duplicate methods")
    return sorted(tests)


def assignments(root: Path) -> dict[str, list[str]]:
    tests = selectors(root)
    ipad = {SELECTOR_PREFIX + name for name in IPAD_TESTS}
    if len(ipad) != len(IPAD_TESTS):
        raise ValueError("Duplicate test in the iPad assignment")
    missing = ipad - set(tests)
    if missing:
        raise ValueError(f"iPad assignments absent from test discovery: {sorted(missing)}")
    phone = [test for test in tests if test not in ipad]
    result = {f"ui-{index}": phone[index::4] for index in range(4)}
    result["ui-ipad"] = [test for test in tests if test in ipad]
    assigned = [test for shard in result.values() for test in shard]
    if len(assigned) != len(set(assigned)) or set(assigned) != set(tests):
        raise ValueError("UI assignments must cover discovery exactly once")
    return result


def verify_ipad_log(log: Path, expected: list[str]) -> dict:
    # These are the XCTest start/completion records in the hosted xcodebuild
    # logs, not an assumed xcresult JSON schema. A changed/missing log format
    # fails closed rather than letting omitted or skipped tests look green.
    records = re.findall(
        r"Test Case '-\[(?:BighelpUITests\.)?(\w+) (test\w+)\]' "
        r"(started|passed|failed|skipped)\b",
        log.read_text(errors="replace"),
    )
    observed: dict[str, list[str]] = {}
    for suite, method, status in records:
        observed.setdefault(SELECTOR_PREFIX + suite + "/" + method, []).append(status)
    invalid = {
        test: observed.get(test, [])
        for test in expected
        if observed.get(test) != ["started", "passed"]
    }
    unexpected = sorted(set(observed) - set(expected))
    return {
        "valid": not invalid and not unexpected,
        "expectedCount": len(expected),
        "expectedSelectors": expected,
        "observedRecords": observed,
        "missingSkippedFailedOrRepeated": invalid,
        "unexpectedSelectors": unexpected,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=[*(f"ui-{index}" for index in range(4)), "ui-ipad"])
    parser.add_argument("--verify-log", type=Path, help="Require each assigned iPad test to start and pass once")
    args = parser.parse_args()
    if args.verify_log and args.suite != "ui-ipad":
        parser.error("--verify-log is supported only for ui-ipad")
    selected = assignments(Path(__file__).resolve().parents[1])[args.suite]
    if args.verify_log:
        result = verify_ipad_log(args.verify_log, selected)
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["valid"] else 1)
    print("\n".join(selected))
