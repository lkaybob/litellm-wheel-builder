# Upgrading LiteLLM

Manual for bumping the pinned LiteLLM version, getting the resulting wheels
published, and rolling them out.

## 1. Pick a target release tag

Check available tags:

```bash
git ls-remote --tags --refs https://github.com/BerriAI/litellm.git | tail -20
```

Read the release notes for the target tag before upgrading, in particular
looking for:

- Database/Prisma schema changes.
- Changes to `pyproject.toml`'s `[build-system]` (the workflow currently
  assumes a maturin/Rust build — see the "Build backend note" in the main
  [README](../README.md)).
- Node.js version bumps in `ui/litellm-dashboard/.nvmrc` (the workflow reads
  this automatically, so a bump doesn't need a workflow change, just a longer
  first build while the new Node version downloads).

## 2. Bump the pinned submodule

```bash
scripts/bump-litellm.sh vX.Y.Z
git push origin main
```

Always pin to a release tag, never a branch. This commits the updated
submodule gitlink and triggers `.gitea/workflows/build-wheel.yml`
automatically (it watches the `litellm` path for changes), or trigger it
manually via `workflow_dispatch` if needed.

## 3. What the workflow publishes

Every run builds and publishes **three** wheels together, all from the exact
same pinned commit:

- `litellm`
- `litellm-proxy-extras`
- `litellm-enterprise`

This is deliberate, not incidental: litellm's own `pyproject.toml` exact-pins
both of the other two (e.g. `litellm-proxy-extras==0.4.86`) and builds them as
`uv` workspace members from that same commit. Installing a mismatched
combination is exactly what caused the Prisma schema mismatch this project
hit before — `litellm-proxy-extras` ships the actual migration files
(`litellm_proxy_extras/migrations/`) that the proxy expects to match its own
code. Publishing all three together on every run means the registry never
holds a combination that didn't ship from the same upstream commit.

## 4. Verify the build

- Gitea → `litellm-wheel-builder` → Actions → confirm the run is green,
  especially the three `Build *.whl` steps and the publish step.
- Gitea → `$GITEA_ORG` → Packages → `pypi` → confirm all three packages show
  up at the new version.

## 5. Install / upgrade in a target environment

Pin the extras explicitly rather than installing `litellm` alone, so a
resolver mistake can't silently pick a different (but technically
index-available) combination:

```bash
pip install --index-url "$REGISTRY_HOST/api/packages/$REGISTRY_ORG/pypi/simple" \
  --upgrade \
  "litellm[proxy]==X.Y.Z" \
  "litellm-proxy-extras==<version pinned by litellm X.Y.Z's pyproject.toml>" \
  "litellm-enterprise==<same, if used>"
```

The exact `litellm-proxy-extras`/`litellm-enterprise` versions for a given
`litellm` release are in that tag's root `pyproject.toml`
(`litellm-proxy-extras==...`, `litellm-enterprise==...`) — or just check what
version numbers the workflow run in step 4 actually built and published.

## 6. Apply database migrations

Migrations live inside the `litellm-proxy-extras` wheel you just installed
(`litellm_proxy_extras/migrations/`), not in `litellm` itself. Before
starting the proxy against the new version, run the same migration step the
official Docker image runs at container start
(`docker/entrypoint.sh` → `litellm/proxy/prisma_migration.py`):

```bash
python "$(python -c 'import litellm.proxy, os; print(os.path.dirname(litellm.proxy.__file__))')/prisma_migration.py"
```

This requires the `prisma` CLI to be available (installed as part of
litellm's `proxy` extras) and a reachable database configured the same way
the proxy itself expects (`DATABASE_URL`, etc.).

## 7. Post-upgrade smoke checks

- Admin UI loads: `GET /ui` returns the dashboard, not blank/404 — the UI is
  rebuilt fresh from source on every CI run (see README), so this should
  always work, but is exactly the kind of thing that broke silently before.
- `GET /health` (or equivalent) succeeds.
- `pip show litellm-proxy-extras litellm-enterprise` on the deployed
  environment to confirm the versions actually installed match what step 4
  showed, not some other resolvable combination.

## 8. Rollback

Previous wheel versions stay in the Gitea registry (nothing deletes old
versions automatically). To roll back, reinstall the previous exact triple:

```bash
pip install --index-url "$REGISTRY_HOST/api/packages/$REGISTRY_ORG/pypi/simple" \
  "litellm[proxy]==<previous>" \
  "litellm-proxy-extras==<previous>" \
  "litellm-enterprise==<previous>"
```

Optionally also `git revert` the submodule bump commit in this repo so the
pinned tag on `main` matches what's actually deployed — not required for the
rollback itself, but keeps this repo's history honest about what's live.

## Note: re-running a build without a new tag

Gitea's package registry rejects re-uploading an existing version+filename.
If you need to force a rebuild of the *same* LiteLLM version (e.g. you fixed
something in this repo's own workflow, not in LiteLLM itself), delete the
existing package version in Gitea first (`$GITEA_ORG` → Packages → the
package → delete the version), then re-run the workflow.
