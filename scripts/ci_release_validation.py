"""Bounded release checks and exact-source reuse of successful CI evidence."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from urllib.request import Request, urlopen

PROFILE = "release-smoke-v2"
WORKFLOW = ".github/workflows/ios-ci.yml"
UI_TESTS = (
    "ReferenceHubUITests/testMiddleSlashCommandWorksWithoutRetiredProviders",
    "ReferenceHubUITests/testDarkLargeTextDrawerPreservesKeyboardAndDraft",
    "ReferenceHubUITests/testSendKeepsKeyboardClosedWhileChatUpdates",
    "AgentsUITests/testChatsOpenedFromAgentsKeepTheTabBar",
    "BoardSwipeBlueprintsUITests/testBlueprintsAskForTheBlanksThenSendOrEdit",
    "DefaultModelUITests/testDefaultModelSurvivesProviderKeysAndComingBack",
)


def git(revision):
    return subprocess.check_output(["git", "rev-parse", revision], text=True).strip()


def completed_ui_tests(log):
    records = re.findall(
        r"Test Case '-\[BighelpUITests\.(\w+) (test\w+)\]' "
        r"(started|passed|failed|skipped)\b", log,
    )
    observed = {}
    for suite, method, status in records:
        observed.setdefault(suite + "/" + method, []).append(status)
    if set(observed) != set(UI_TESTS) or any(
        observed.get(test) != ["started", "passed"] for test in UI_TESTS
    ):
        raise ValueError("Every assigned release UI regression must run and pass once without skips")
    if "** TEST SUCCEEDED **" not in log or "Test run with " not in log:
        raise ValueError("Native and UI test completion evidence is missing")
    return list(UI_TESTS)


def validate_run(run, run_id, repository):
    if (
        str(run.get("id")) != str(run_id)
        or run.get("repository", {}).get("full_name") != repository
        or run.get("path", "").split("@")[0] != WORKFLOW
        or run.get("event") not in {"pull_request", "workflow_dispatch"}
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
    ):
        raise ValueError("Release requires a completed successful iOS CI run in this repository")


def validate_receipt(receipt, run, source_tree, repository):
    validate_run(run, receipt.get("run_id"), repository)
    if (
        receipt.get("profile") != PROFILE
        or receipt.get("run_attempt") != run.get("run_attempt")
        or receipt.get("repository") != repository
        or receipt.get("source_tree") != source_tree
        or re.fullmatch(r"[0-9a-f]{40}", source_tree) is None
        or receipt.get("ui_tests") != list(UI_TESTS)
        or receipt.get("native_suite") != "BighelpTests"
    ):
        raise ValueError("Successful validation does not cover this exact release source tree")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["selectors", "receipt", "check-run", "verify"])
    parser.add_argument("--log", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--run", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if args.command == "selectors":
        print("-only-testing:BighelpTests")
        print("\n".join("-only-testing:BighelpUITests/" + test for test in UI_TESTS))
    elif args.command == "receipt":
        tests = completed_ui_tests(args.log.read_text(errors="replace"))
        receipt = {
            "profile": PROFILE,
            "repository": os.environ["GITHUB_REPOSITORY"],
            "run_id": int(os.environ["GITHUB_RUN_ID"]),
            "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
            "source_commit": git("HEAD"),
            "source_tree": git("HEAD^{tree}"),
            "native_suite": "BighelpTests",
            "ui_tests": tests,
        }
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"Verified native suite and all {len(tests)} release UI regressions")
    elif args.command == "check-run":
        run_id = os.environ["VALIDATED_RUN_ID"]
        repository = os.environ["GITHUB_REPOSITORY"]
        if not run_id.isascii() or not run_id.isdecimal():
            raise ValueError("CI run ID must contain digits only")
        request = Request(
            f"https://api.github.com/repos/{repository}/actions/runs/{run_id}",
            headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                     "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28"},
        )
        with urlopen(request, timeout=30) as response:
            data = response.read(1_000_001)
        if len(data) > 1_000_000:
            raise ValueError("Unexpectedly large workflow metadata")
        run = json.loads(data)
        validate_run(run, run_id, repository)
        args.output.write_text(json.dumps(run))
        print("Verified successful CI run and workflow identity")
    else:
        validate_receipt(json.loads(args.receipt.read_text()), json.loads(args.run.read_text()),
                         git("HEAD^{tree}"), os.environ["GITHUB_REPOSITORY"])
        print("Release source exactly matches the tested source; no duplicate simulator run needed")


if __name__ == "__main__":
    main()
