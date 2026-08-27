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
  "litellm[proxy,extra_proxy]==X.Y.Z" \
  "litellm-proxy-extras==<version pinned by litellm X.Y.Z's pyproject.toml>" \
  "litellm-enterprise==<same, if used>"
```

Both `proxy` and `extra_proxy` are needed — they're separate extras in
`litellm/pyproject.toml`. `proxy` alone pulls in fastapi/uvicorn/etc. but
*not* `prisma`; without `extra_proxy` the proxy fails or hangs at startup
when it tries to run its Prisma-based DB migration/connection logic, since
`prisma` (and the query-engine binary it fetches on first use) is missing.

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
cd "$(python -c 'import litellm.proxy, os; print(os.path.dirname(litellm.proxy.__file__))')" && python prisma_migration.py
```

The `cd` matters: litellm's own migration code resolves the schema relative
to the current directory (`./schema.prisma` in
`litellm/proxy/db/check_migration.py`), not relative to the script. The
official Docker image gets this for free because its `WORKDIR` is already
the repo root containing `schema.prisma`; a bare wheel install has no such
directory; running from wherever the schema actually lives
(`litellm/proxy/schema.prisma`, bundled into the wheel) is what the Docker
image effectively relies on too.

There's no shortcut around the `cd` via a `--schema` flag or env var:
`prisma_migration.py` never reads `sys.argv` (confirmed by reading the
script — it imports `sys` only for `sys.path.insert`), and its
`subprocess.run(["prisma", "generate"], ...)` call is a hardcoded list, not
built from any variable. Anything passed on the command line when invoking
this script is silently discarded; it never reaches the `prisma generate`
subprocess. `prisma`'s own config (`prisma/_config.py`) likewise has no
schema-path env var, only `PRISMA_VERSION`/`PRISMA_BINARY_CACHE_DIR`/etc. —
confirmed against the installed package, not just its `--schema` CLI flag's
docs. Changing directory is the only way to make this resolve correctly
short of patching the installed script itself, which would silently break
again on every version bump.

This requires the `prisma` CLI to be available (installed as part of
litellm's `extra_proxy` extra — see step 5) and a reachable database
configured the same way the proxy itself expects (`DATABASE_URL`, etc.).

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
  "litellm[proxy,extra_proxy]==<previous>" \
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
