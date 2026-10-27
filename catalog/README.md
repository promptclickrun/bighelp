# Template catalog

The live catalog is managed in the private reviewer webapp, behind Cloudflare Access. This directory
keeps source snapshots, one file or folder per template. Normal merges validate these files but **do not
publish them**: they must not overwrite reviewer edits or recreate deleted live templates.
The catalog's Worker is in [services/catalog](../services/catalog/README.md).

```
catalog/
  agents/<name>/
    template.json      id, name, role, vibe, description, category, symbol, variables, credit
    instructions.md    the agent's personality text, with {{agent_name}} and its other {{keys}}
  blueprints/<board>/  feed, ideas or goals
    <id>.json          id, board, category, text, goalCategory (goals only), credit
```

The fields, limits and topics are the Worker's (`services/catalog/src/templates.ts`). Fill-in fields follow
[TEMPLATE_VARIABLES.md](../services/catalog/docs/TEMPLATE_VARIABLES.md). `symbol` is an SF Symbol name.
`credit` is optional and shows on the template's card.

## Add or change a template

1. Add a folder under `agents/` (with `template.json` and `instructions.md`) or a file under `blueprints/<board>/`.
   Give it an `id` of lowercase letters, digits and dashes. The id is permanent: a changed id is a new template.
2. Open a pull request. It runs the Worker's own checks on every file in this directory
   (`services/catalog/test/repo-catalog.test.ts`), so a bad template fails the pull request.
3. Merge it, then explicitly run the Template Catalog workflow with **publish** enabled if you intend to
   replace live content from these files. Inspect `catalog-sync.py sync` first: publication overwrites
   matching live edits, recreates missing IDs and approves matching pending templates. Prefer the webapp
   for ordinary catalog editing.

To remove a live template, use the reviewer webapp. For an intentional repo-driven replacement, delete its file and start the workflow by hand with **publish** and **prune** on. That unpublishes it
(it goes back to pending, so it can be restored). Without prune, a deleted file does nothing.

Community submissions still go through the review queue. When one is approved, run
`python3 services/catalog/scripts/catalog-sync.py export` and commit the result, so it is kept here too.

## Scripts

`services/catalog/scripts/catalog-sync.py` does the work. Only `sync --apply` needs a secret.

```sh
python3 services/catalog/scripts/catalog-sync.py check            # validate catalog/, offline
python3 services/catalog/scripts/catalog-sync.py export           # rewrite catalog/ from the public catalog
python3 services/catalog/scripts/catalog-sync.py sync             # dry run: what would change
python3 services/catalog/scripts/catalog-sync.py sync --apply     # publish
```

## Setup (maintainer, once)

The workflow reads two repository secrets, `CATALOG_REVIEW_CLIENT_ID` and `CATALOG_REVIEW_CLIENT_SECRET`: a
service token for the catalog's review API (see "Reviewing" in the Worker's README). Pull requests never get
them. The publish job runs only on `main`. Naming a template's `id` needs the Worker with that change deployed;
before that, `sync` can update and approve templates but stops when it must create one.
