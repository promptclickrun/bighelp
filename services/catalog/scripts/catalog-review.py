#!/usr/bin/env python3
"""Review bighelp Template Catalog submissions from a terminal or an agent.

Needs a Cloudflare Access service token for the review app, in the environment or an env file:
  CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET, optional CATALOG_URL (default https://catalog.bighelp.app)
  --env-file PATH (default ~/.config/bighelp-catalog/reviewer.env)

  catalog-review list [--status pending|approved|rejected|all] [--kind blueprint|agent]
  catalog-review show ID
  catalog-review approve ID [--note TEXT]
  catalog-review reject ID --note TEXT
  catalog-review unpublish ID [--note TEXT]
  catalog-review edit ID FIELD=VALUE ...     (e.g. vibe="Calm, organized" symbol=airplane)
  catalog-review publish FILE.json           (reviewer-authored template, approved at once)
  catalog-review delete ID
  catalog-review ban GITHUB_ID [--note TEXT]  (stops that account's agent submissions and signs out its installs)
  catalog-review unban GITHUB_ID
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_ENV = Path.home() / ".config/bighelp-catalog/reviewer.env"


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


def call(method: str, path: str, body=None):
    base = os.environ.get("CATALOG_URL", "https://catalog.bighelp.app").rstrip("/")
    client_id = os.environ.get("CF_ACCESS_CLIENT_ID")
    secret = os.environ.get("CF_ACCESS_CLIENT_SECRET")
    if not client_id or not secret:
        sys.exit("Set CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET (or pass --env-file).")
    request = urllib.request.Request(
        base + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "CF-Access-Client-Id": client_id,
            "CF-Access-Client-Secret": secret,
            "Content-Type": "application/json",
            "User-Agent": "bighelp-catalog-review/1",
        },
    )
    # Access answers a bad token with a redirect to its login page; don't follow it.
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=30) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308):
            sys.exit("Access refused the service token (expired, revoked, or not on the review app).")
        detail = error.read().decode(errors="replace")
        sys.exit(f"{error.code}: {detail}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def summary(item: dict) -> str:
    if item.get("submitterGithubId"):
        who = f"@{item['submitterUsername']} (github:{item['submitterGithubId']})"
    elif item.get("submitterEmail"):
        who = f"@{item['submitterUsername']} <{item['submitterEmail']}>"
    else:
        who = item.get("source")
    where = f"{item.get('board')}/{item.get('category')}" if item["kind"] == "blueprint" else item.get("category")
    return f"{item['id']:<22} {item['status']:<9} {item['kind']:<9} {where:<20} {who:<28} {item['title']}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--json", action="store_true", help="print raw JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list")
    listing.add_argument("--status", default="pending", choices=["pending", "approved", "rejected", "all"])
    listing.add_argument("--kind", choices=["blueprint", "agent"])
    listing.add_argument("--limit", type=int, default=100)
    for name in ("show", "delete"):
        sub.add_parser(name).add_argument("id")
    for name in ("approve", "unpublish"):
        action = sub.add_parser(name)
        action.add_argument("id")
        action.add_argument("--note")
    reject = sub.add_parser("reject")
    reject.add_argument("id")
    reject.add_argument("--note", required=True, help="why; the submitter sees it")
    edit = sub.add_parser("edit")
    edit.add_argument("id")
    edit.add_argument("fields", nargs="+", metavar="FIELD=VALUE")
    publish = sub.add_parser("publish")
    publish.add_argument("file", type=Path)
    ban = sub.add_parser("ban")
    ban.add_argument("github_id")
    ban.add_argument("--note")
    sub.add_parser("unban").add_argument("github_id")
    args = parser.parse_args()
    load_env(args.env_file)

    if args.command == "list":
        query = f"?status={args.status}&limit={args.limit}" + (f"&kind={args.kind}" if args.kind else "")
        result = call("GET", f"/review/templates{query}")
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            items = result["templates"]
            print(f"{len(items)} template(s)")
            for item in items:
                print(summary(item))
        return
    if args.command == "show":
        result = call("GET", f"/review/templates/{args.id}")
    elif args.command == "delete":
        result = call("DELETE", f"/review/templates/{args.id}")
    elif args.command in ("approve", "reject", "unpublish"):
        result = call("POST", f"/review/templates/{args.id}/{args.command}", {"note": args.note} if args.note else {})
    elif args.command in ("ban", "unban"):
        if not args.github_id.isdigit():
            sys.exit("Use the numeric GitHub user ID (shown as github:<id> in list).")
        body = {"note": args.note} if getattr(args, "note", None) else {}
        result = call("POST", f"/review/accounts/{args.github_id}/{args.command}", body)
    elif args.command == "edit":
        fields = dict(field.split("=", 1) for field in args.fields)
        result = call("PATCH", f"/review/templates/{args.id}", fields)
    else:
        result = call("POST", "/review/templates", json.loads(args.file.read_text()))
    print(json.dumps(result, indent=2) if args.json or args.command == "show" else summary(result)
          if "title" in result else json.dumps(result))


if __name__ == "__main__":
    main()
