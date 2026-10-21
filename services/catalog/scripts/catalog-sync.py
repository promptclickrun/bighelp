#!/usr/bin/env python3
"""Keep the bighelp Template Catalog and the repo's `catalog/` directory in step.

  catalog-sync check                    validate the files in catalog/ (no network, no secrets)
  catalog-sync export                   rewrite catalog/ from the public catalog (no secrets)
  catalog-sync sync [--apply] [--prune] publish catalog/ to the catalog; without --apply it only prints the plan

`catalog/` is the source of truth for the templates it lists: `sync` creates what is missing, updates what
differs and approves what is waiting, so an edit made only in the catalog is overwritten by the next sync.
Templates the repo doesn't list are left alone, unless --prune, which unpublishes them (reversible).

Layout (see catalog/README.md):
  catalog/agents/<slug>/template.json + instructions.md
  catalog/blueprints/<board>/<id>.json

`sync` needs a review-API service token in CATALOG_REVIEW_CLIENT_ID and CATALOG_REVIEW_CLIENT_SECRET
(CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET also work, and ~/.config/bighelp-catalog/reviewer.env is read
if present). CATALOG_URL overrides the default https://catalog.bighelp.app.
"""

import argparse
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_CATALOG = Path(__file__).resolve().parents[3] / "catalog"
DEFAULT_URL = "https://catalog.bighelp.app"
DEFAULT_ENV = Path.home() / ".config/bighelp-catalog/reviewer.env"
BOARDS = ("feed", "ideas", "goals")
ID = re.compile(r"^[a-z0-9][a-z0-9-]{2,63}$")

# Field order in the files, and the fields each kind compares and sends.
AGENT_FIELDS = ("name", "role", "vibe", "description", "category", "symbol", "variables")
BLUEPRINT_FIELDS = ("board", "category", "text", "goalCategory")


class CatalogError(Exception):
    pass


# MARK: - Files

def normalize(kind: str, fields: dict, credit) -> dict:
    """The comparable form of a template: only its own fields, text cleaned the way the Worker cleans it,
    `required` filled in on variables, and absent optional fields as None."""
    names = AGENT_FIELDS + ("instructions",) if kind == "agent" else BLUEPRINT_FIELDS
    out = {}
    for name in names:
        value = fields.get(name)
        if isinstance(value, str):
            value = value.replace("\r\n", "\n").strip()
            if name != "instructions" and name != "text":
                value = " ".join(value.split())
            value = value or None
        if name == "variables" and value:
            value = [{**variable, "required": variable.get("required", True)} for variable in value]
        out[name] = value or None
    if kind == "blueprint" and out["board"] != "goals":
        out["goalCategory"] = None
    out["credit"] = credit or None
    return out


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise CatalogError(f"{path}: {error}")
    if not isinstance(value, dict):
        raise CatalogError(f"{path}: expected a JSON object")
    return value


def load_repo(root: Path = REPO_CATALOG) -> dict[str, dict]:
    """Every template in catalog/, by id: {kind, fields (normalized), path}."""
    templates: dict[str, dict] = {}

    def add(template_id: str, kind: str, fields: dict, credit, path: Path) -> None:
        if not ID.match(template_id):
            raise CatalogError(f"{path}: id {template_id!r} must be lowercase letters, digits and dashes")
        if template_id in templates:
            raise CatalogError(f"{path}: id {template_id} is also used by {templates[template_id]['path']}")
        templates[template_id] = {"kind": kind, "fields": normalize(kind, fields, credit), "path": path}

    for folder in sorted((root / "agents").glob("*/")):
        meta_path, text_path = folder / "template.json", folder / "instructions.md"
        if not meta_path.is_file() or not text_path.is_file():
            raise CatalogError(f"{folder}: needs template.json and instructions.md")
        meta = read_json(meta_path)
        add(str(meta.get("id") or folder.name), "agent",
            {**meta, "instructions": text_path.read_text()}, meta.get("credit"), folder)

    for path in sorted((root / "blueprints").glob("*/*.json")):
        meta = read_json(path)
        if meta.get("board") != path.parent.name or path.parent.name not in BOARDS:
            raise CatalogError(f"{path}: board must be {path.parent.name!r}, one of {', '.join(BOARDS)}")
        add(str(meta.get("id") or path.stem), "blueprint", meta, meta.get("credit"), path)
    return templates


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def export_catalog(url: str, root: Path = REPO_CATALOG) -> tuple[int, int]:
    """Rewrite catalog/ from the public catalog. Returns (agents, blueprints)."""
    with urllib.request.urlopen(urllib.request.Request(
            f"{url}/v1/catalog.json", headers={"User-Agent": "bighelp-catalog-sync/1"}), timeout=30) as response:
        catalog = json.loads(response.read())
    for folder in ("agents", "blueprints"):
        shutil.rmtree(root / folder, ignore_errors=True)

    used: set[str] = set()
    for agent in catalog["agents"]:
        # Hand-picked ids (anchor) name their folder; generated ones (agent-1ba9…) use the template's name.
        slug = agent["id"] if not agent["id"].startswith("agent-") else slugify(agent["name"])
        if slug in used:
            slug = f"{slug}-{agent['id'].removeprefix('agent-')}"
        used.add(slug)
        meta = {"id": agent["id"], **{name: agent[name] for name in AGENT_FIELDS if agent.get(name)}}
        if agent.get("credit"):
            meta["credit"] = agent["credit"]
        write_json(root / "agents" / slug / "template.json", meta)
        (root / "agents" / slug / "instructions.md").write_text(agent["instructions"].strip() + "\n")

    for blueprint in catalog["blueprints"]:
        meta = {"id": blueprint["id"], **{name: blueprint[name] for name in BLUEPRINT_FIELDS if blueprint.get(name)}}
        if blueprint.get("credit"):
            meta["credit"] = blueprint["credit"]
        write_json(root / "blueprints" / blueprint["board"] / f"{blueprint['id']}.json", meta)
    return len(catalog["agents"]), len(catalog["blueprints"])


# MARK: - Review API

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def load_env(path: Path) -> None:
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip())


def call(method: str, path: str, body=None):
    base = os.environ.get("CATALOG_URL", DEFAULT_URL).rstrip("/")
    client_id = os.environ.get("CATALOG_REVIEW_CLIENT_ID") or os.environ.get("CF_ACCESS_CLIENT_ID")
    secret = os.environ.get("CATALOG_REVIEW_CLIENT_SECRET") or os.environ.get("CF_ACCESS_CLIENT_SECRET")
    if not client_id or not secret:
        raise CatalogError("Set CATALOG_REVIEW_CLIENT_ID and CATALOG_REVIEW_CLIENT_SECRET.")
    request = urllib.request.Request(
        base + path, method=method, data=None if body is None else json.dumps(body).encode(),
        headers={"CF-Access-Client-Id": client_id, "CF-Access-Client-Secret": secret,
                 "Content-Type": "application/json", "User-Agent": "bighelp-catalog-sync/1"})
    try:
        # A bad token gets a redirect to a login page; don't follow it.
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308):
            raise CatalogError("The review API refused the service token (expired or revoked).")
        raise CatalogError(f"{method} {path} answered {error.code}: {error.read().decode(errors='replace')[:300]}")


def remote_templates() -> dict[str, dict]:
    result = call("GET", "/review/templates?status=all&limit=500")["templates"]
    if len(result) >= 500:
        raise CatalogError("The catalog holds 500 or more templates; the sync lists at most 500. Raise the limit first.")
    return {item["id"]: item for item in result}


def request_body(kind: str, fields: dict, credit) -> dict:
    """What the review API takes. Absent optional fields go as null so an edit can remove them."""
    body = {name: value for name, value in fields.items()}
    body["kind"] = kind
    body["creditName"] = credit
    return body


def sync(apply: bool, prune: bool) -> int:
    local = load_repo()
    remote = remote_templates()
    created = updated = approved = unpublished = unchanged = 0

    def say(verb: str, template_id: str, detail: str = "") -> None:
        print(f"{'' if apply else 'would '}{verb:<10} {template_id} {detail}".rstrip())

    for template_id, item in local.items():
        kind, fields = item["kind"], item["fields"]
        credit = fields.pop("credit")
        existing = remote.get(template_id)
        if existing is None:
            say("create", template_id, f"({kind})")
            created += 1
            if apply:
                made = call("POST", "/review/templates", {**request_body(kind, fields, credit), "id": template_id})
                if made["id"] != template_id:
                    # An older Worker ignores `id` and invents its own. Undo that, so the next run doesn't repeat it.
                    call("DELETE", f"/review/templates/{made['id']}")
                    raise CatalogError("The catalog Worker doesn't accept template ids yet. Deploy it, then run again.")
            continue
        if existing["kind"] != kind:
            raise CatalogError(f"{item['path']}: {template_id} is a {existing['kind']} in the catalog")
        current = normalize(kind, existing, existing.get("credit"))
        current_credit = current.pop("credit")
        changed = [name for name in fields if fields[name] != current[name]] + (
            ["credit"] if credit != current_credit else [])
        if changed:
            say("update", template_id, f"({', '.join(changed)})")
            updated += 1
            if apply:
                call("PATCH", f"/review/templates/{template_id}", request_body(kind, fields, credit))
        if existing["status"] != "approved":
            say("approve", template_id, f"(was {existing['status']})")
            approved += 1
            if apply:
                call("POST", f"/review/templates/{template_id}/approve", {})
        if not changed and existing["status"] == "approved":
            unchanged += 1

    orphans = [item for template_id, item in remote.items() if template_id not in local and item["status"] == "approved"]
    for item in orphans:
        if prune:
            say("unpublish", item["id"], f"({item['title']!r})")
            unpublished += 1
            if apply:
                call("POST", f"/review/templates/{item['id']}/unpublish", {"note": "Removed from the repo's catalog/."})
        else:
            print(f"not in repo {item['id']} ({item['source']}: {item['title']!r})")

    print(f"\n{len(local)} in repo: {created} new, {updated} changed, {approved} approved, {unchanged} unchanged;"
          f" {len(orphans)} live templates not in the repo" + (f", {unpublished} unpublished" if prune else "")
          + ("" if apply else ". Dry run: pass --apply to publish."))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("export")
    sync_parser = commands.add_parser("sync")
    sync_parser.add_argument("--apply", action="store_true")
    sync_parser.add_argument("--prune", action="store_true")
    args = parser.parse_args()
    load_env(args.env_file)
    try:
        if args.command == "check":
            templates = load_repo()
            kinds = [item["kind"] for item in templates.values()]
            print(f"catalog/ is well formed: {kinds.count('agent')} agents, {kinds.count('blueprint')} blueprints")
            return 0
        if args.command == "export":
            agents, blueprints = export_catalog(os.environ.get("CATALOG_URL", DEFAULT_URL).rstrip("/"))
            print(f"wrote {agents} agents and {blueprints} blueprints to {REPO_CATALOG}")
            return 0
        return sync(args.apply, args.prune)
    except CatalogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
