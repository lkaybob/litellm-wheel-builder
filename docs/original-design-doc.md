# LiteLLM Wheel Build CI on Gitea Actions — Setup Guide for Claude Code

## Goal

Build a PyPI wheel of LiteLLM on a schedule/on-demand, using Gitea Actions, **without
modifying the existing pull-mirror repository in any way**. The mirror stays a pure,
untouched read-only sync target from `https://github.com/BerriAI/litellm`.

## Why a separate repo (do not skip this)

The mirror repo is a Gitea **pull mirror**. Every sync force-syncs the tracked branches
to match upstream exactly. Any file you commit directly onto the mirrored branch
(including `.gitea/workflows/*.yml`) will be silently discarded on the next sync, and
push-triggered Actions on mirror-sync events have a history of not firing reliably
(Gitea issues #24926, #32412). So: **the mirror repo is never written to.** A second,
ordinary Gitea repo owns the workflow definition and checks out the mirror's content at
build time via `actions/checkout`'s `repository:` parameter.

```
┌─────────────────────────┐        pull mirror sync        ┌──────────────────────────┐
│ github.com/BerriAI/litellm │ ───────────────────────────▶ │ gitea: <org>/litellm-mirror │  (untouched)
└─────────────────────────┘                                 └──────────────────────────┘
                                                                          ▲
                                                                          │ checkout (read-only)
                                                                          │
                                                              ┌──────────────────────────┐
                                                              │ gitea: <org>/litellm-wheel-builder │
                                                              │  .gitea/workflows/build.yml         │
                                                              └──────────────────────────┘
                                                                          │
                                                                          ▼
                                                          Gitea PyPI package registry
                                                     (api/packages/<owner>/pypi)
```

Fill in the placeholders below before running anything:

| Placeholder | Meaning |
|---|---|
| `GITEA_HOST` | e.g. `https://git.internal.example.com` |
| `GITEA_ORG` | org/owner that holds the mirror repo |
| `MIRROR_REPO` | name of the existing mirror repo, e.g. `litellm-mirror` |
| `BUILDER_REPO` | new repo name, e.g. `litellm-wheel-builder` |
| `MIRROR_BRANCH` | branch to build from, usually `main` |

---

## Step 0 — Verify current mirror state (read-only, do not change anything)

```bash
# Confirm the mirror repo exists and is flagged as a mirror; note last sync time.
curl -s -H "Authorization: token $GITEA_TOKEN" \
  "$GITEA_HOST/api/v1/repos/$GITEA_ORG/$MIRROR_REPO" | jq '.mirror, .updated_at'
```

Expected: `"mirror": true`. If it prints `false`, stop — this repo is not actually a
pull mirror and the rest of this guide's assumptions don't apply.

Do not touch this repo's settings, branches, or webhooks for the rest of this guide.

---

## Step 1 — Create the builder repo in Gitea

Via UI: **+ New Repository** → name `litellm-wheel-builder` → same org/owner as the
mirror → do **not** check "This repository will be a mirror" → initialize with a
README.

Or via API:

```bash
curl -s -X POST -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"litellm-wheel-builder","auto_init":true,"private":true}' \
  "$GITEA_HOST/api/v1/orgs/$GITEA_ORG/repos"
```

---

## Step 2 — Enable Actions (skip anything already enabled)

- **Instance-wide** (only if not already on — LiteLLM proxy stack already implies
  Actions may be enabled elsewhere, so check first): in `app.ini`
  ```ini
  [actions]
  ENABLED = true
  ```
- **Repo-level**: in `litellm-wheel-builder` → Settings → Actions → enable.
- **Runner**: confirm an `act_runner` with a Python-capable label is already
  registered (`Site Admin → Actions → Runners`). If none exists:
  ```bash
  act_runner register \
    --instance "$GITEA_HOST" \
    --token "$RUNNER_REGISTRATION_TOKEN" \
    --name litellm-wheel-runner \
    --labels ubuntu-latest:docker://python:3.11-bookworm
  act_runner daemon
  ```

---

## Step 3 — Clone the new builder repo locally

```bash
mkdir -p ~/work && cd ~/work
git clone "$GITEA_HOST/$GITEA_ORG/litellm-wheel-builder.git"
cd litellm-wheel-builder
mkdir -p .gitea/workflows
```

---

## Step 4 — Add the workflow file

Create `.gitea/workflows/build-wheel.yml`:

```yaml
name: Build LiteLLM Wheel

on:
  schedule:
    # Adjust to match/trail your mirror's sync interval. This does NOT touch the
    # mirror repo — it only reads from it at checkout time.
    - cron: "0 3 * * *"
  workflow_dispatch:
    inputs:
      ref:
        description: "Branch/tag/commit on the mirror to build"
        required: false
        default: "main"

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout LiteLLM mirror (read-only)
        uses: actions/checkout@v4
        with:
          repository: ${{ github.repository_owner }}/MIRROR_REPO   # replace MIRROR_REPO
          ref: ${{ github.event.inputs.ref || 'MIRROR_BRANCH' }}   # replace MIRROR_BRANCH
          token: ${{ secrets.MIRROR_READ_TOKEN }}

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install Poetry
        run: pip install --no-cache-dir poetry poetry-core

      - name: Build wheel
        run: poetry build -f wheel

      - name: Upload wheel as build artifact
        uses: actions/upload-artifact@v4
        with:
          name: litellm-wheel
          path: dist/*.whl

      - name: Publish to Gitea PyPI registry
        env:
          TWINE_USERNAME: ${{ secrets.GITEA_PYPI_USER }}
          TWINE_PASSWORD: ${{ secrets.GITEA_PYPI_TOKEN }}
        run: |
          pip install --no-cache-dir twine
          python -m twine upload \
            --repository-url "$GITEA_HOST/api/packages/$GITEA_ORG/pypi/" \
            dist/*.whl
```

Notes:
- `MIRROR_READ_TOKEN` only needs **read** access to `MIRROR_REPO` — scope it to that
  single repo if your Gitea version supports fine-grained tokens.
- `poetry build -f wheel` is correct for LiteLLM: its `pyproject.toml` declares
  `build-backend = "poetry.core.masonry.api"`.
- Twine cannot overwrite an existing version+filename in Gitea's package registry —
  if you re-run a build against the same upstream commit/version, delete the old
  package version first or version artifacts by date/commit (e.g. via
  `poetry version` bump in a local step, not in the mirror).

---

## Step 5 — Add secrets to the builder repo

`litellm-wheel-builder` → Settings → Actions → Secrets:

| Secret | Value |
|---|---|
| `MIRROR_READ_TOKEN` | Gitea access token, read-only scope on `MIRROR_REPO` |
| `GITEA_PYPI_USER` | Gitea username for package publishing |
| `GITEA_PYPI_TOKEN` | Gitea access token with package write scope |

---

## Step 6 — Fix the two placeholders and push

```bash
sed -i "s/MIRROR_REPO/$MIRROR_REPO/g; s/MIRROR_BRANCH/$MIRROR_BRANCH/g" \
  .gitea/workflows/build-wheel.yml

git add .gitea/workflows/build-wheel.yml
git commit -m "Add scheduled LiteLLM wheel build workflow"
git push origin main
```

---

## Step 7 — Test run

- Trigger manually first: `litellm-wheel-builder` → Actions → "Build LiteLLM Wheel" →
  Run workflow.
- Confirm the checkout step pulls from `MIRROR_REPO`, not `litellm-wheel-builder`
  itself (check the step log's `Fetching` URL).
- Confirm the artifact `litellm-wheel` appears under the run's Artifacts tab.
- Confirm the package appears in Gitea: `$GITEA_ORG` → Packages → look for a `pypi`
  entry.
- Install to verify:
  ```bash
  pip install --index-url "$GITEA_HOST/api/packages/$GITEA_ORG/pypi/simple" \
    --no-deps litellm
  ```

---

## Step 8 — Confirm the mirror was never touched

```bash
curl -s -H "Authorization: token $GITEA_TOKEN" \
  "$GITEA_HOST/api/v1/repos/$GITEA_ORG/$MIRROR_REPO" | jq '.mirror, .updated_at'
```

`updated_at` should only change on the mirror's own periodic sync schedule, never as a
side effect of a builder-repo workflow run.

---

## Known caveats to keep in mind

- No native "mirror sync completed" webhook exists in Gitea yet (feature request
  #22774, still open), so `schedule:` on the builder repo is the reliable trigger —
  don't rely on push events fired by the mirror sync.
- If LiteLLM's `pyproject.toml` version hasn't changed since your last build, Twine
  upload will fail (Gitea package registry rejects duplicate version+file). Decide
  whether to skip-if-unchanged, or tag your internal wheel filenames with a build
  suffix/date so repeated builds off the same upstream version don't collide.
- Runner network egress must reach both `GITEA_HOST` (for checkout + publish) and
  PyPI (for `pip install poetry`/`twine` unless those are already mirrored
  internally too).
