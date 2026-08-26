# litellm-wheel-builder

Builds a PyPI wheel of [LiteLLM](https://github.com/BerriAI/litellm) on Gitea Actions and
publishes it to a Gitea PyPI package registry.

## Design

LiteLLM source is vendored as a **git submodule** at [`litellm/`](litellm), pinned to a
specific upstream **release tag** (currently `v1.98.0`). This repo never depends on a
live sync/mirror of LiteLLM:

- The submodule commit only changes when someone deliberately runs
  [`scripts/bump-litellm.sh`](scripts/bump-litellm.sh) and commits the result.
- Checking this repo out (`git clone --recurse-submodules` or
  `actions/checkout` with `submodules: recursive`) always reproduces the exact same
  LiteLLM source, with no separate mirror repo, no cross-repo checkout, and nothing
  that can silently drift or force-sync out from under a workflow file.
- Every submodule bump commit records the tag it was pinned to and the resolved
  commit SHA, so the history of "what LiteLLM version did we build" lives in this
  repo's own git log.

## Bumping the pinned LiteLLM version

```bash
scripts/bump-litellm.sh v1.99.0
git push origin main
```

This fetches the tag (shallow, no full-history clone), checks the submodule out to
it, and commits the updated gitlink + `.gitmodules` pin. Pushing to `main` triggers
[`.gitea/workflows/build-wheel.yml`](.gitea/workflows/build-wheel.yml), which builds
and publishes the wheel.

Always pin to a release **tag**, never a branch — this is the standard for this repo.

For the full upgrade procedure (verifying the build, installing/upgrading a
target environment, applying database migrations, rollback), see
[`docs/upgrading.md`](docs/upgrading.md).

## Cloning

LiteLLM's full git history is large, so always clone the submodule shallowly:

```bash
git clone --recurse-submodules --shallow-submodules <this-repo-url>
# or, if already cloned without submodules:
git submodule update --init --recursive --depth 1
```

(A plain `--recurse-submodules` without `--shallow-submodules` pulls LiteLLM's
entire history and is dramatically slower for no benefit here.)

## CI (Gitea Actions)

`.gitea/workflows/build-wheel.yml`:

- Triggers on push to `main` when the `litellm` submodule pointer changes, or
  manually via `workflow_dispatch`.
- Checks out this repo with `submodules: recursive` (no mirror repo, no
  cross-repo checkout needed).
- Installs a Rust toolchain, a C toolchain (`build-essential`), `uv`, and a
  pinned/checksum-verified Node.js (version read from
  `litellm/ui/litellm-dashboard/.nvmrc`).
- Builds the admin UI (`npm ci && npm run build`) and replaces the committed
  `litellm/proxy/_experimental/out` with the fresh export, matching what
  litellm's own `Dockerfile` does before packaging.
- Builds three wheels with `uv build --wheel --python 3.11`: `litellm` itself,
  and its two exact-pinned workspace-member dependencies,
  `litellm-proxy-extras` and `litellm-enterprise`.
- Uploads all three wheels as a workflow artifact and publishes them to the
  Gitea PyPI registry via `uvx twine`.

**Why rebuild the UI instead of trusting the committed one:** the bundle
already committed in the tag turned out to be a complete, self-consistent,
already-correct export of the same dashboard source (verified locally: same
947 files, same routes, differing only in Next.js's random per-build content-hash
directory name) — but litellm's own `Dockerfile` always discards it and
rebuilds fresh before packaging regardless, so this workflow matches that
rather than relying on whatever happened to be committed at tagging time. Past
experience installing plain `pip install litellm` and getting a broken/missing
admin UI is exactly what this step guards against.

**Why also build litellm-proxy-extras and litellm-enterprise:** litellm's
`pyproject.toml` exact-pins both (`litellm-proxy-extras==X.Y.Z`,
`litellm-enterprise==X.Y.Z`) and builds them as `uv` workspace members from
the same commit, which is what keeps e.g. the Prisma schema they ship in sync
with what litellm itself expects. That pinning only helps if the exact pinned
version is actually resolvable, though — an install pointed only at this
repo's own Gitea registry (not falling through to public PyPI) needs that
exact version published there too, so both get built and published alongside
`litellm` on every run.

**Why uv, not system pip:** on the actual Gitea `act_runner` this was tested
against, the runner's image turned out to be Debian bullseye with Python 3.9
and no `pip3` at all — too old for litellm's `requires-python >=3.10` and
nothing to build with anyway. `uv` provisions its own Python 3.11 and runs
tools (`uvx twine`) in isolated environments, independent of whatever the
runner's base image happens to ship. The "Runner environment" step earlier in
the workflow prints `whoami`/`/etc/os-release`/`python3 --version`/`cc`/`sudo`
availability so a different runner's mismatch is diagnosable from the log
alone, without needing to know the image ahead of time.

**Build backend note:** LiteLLM's `pyproject.toml` build backend has changed
across releases — `poetry-core` (through ~1.6x), `uv_build` (~1.85-1.90), and
`maturin` from 1.95 onward, including the currently pinned `v1.98.0`. Maturin
compiles a native PyO3 extension (`litellm.rust_bridge._native`) from the
`litellm-rust/` Cargo workspace, so **the produced wheel is platform/ABI-specific**
(e.g. `litellm-1.98.0-cp311-cp311-linux_x86_64.whl`), not a universal
`py3-none-any` wheel — a single CI run only covers the runner's own OS/arch/Python
combination. `uv build` deliberately isn't pinned to a specific maturin version
in this workflow: it reads `[build-system] requires` from the submodule's own
`pyproject.toml` via PEP 517 build isolation, so a future `bump-litellm.sh` run
that lands on a different backend/maturin version doesn't require editing the
workflow too — though a bump back to a pure-Python backend or a new backend
entirely may still need this build step revisited.

### Repo variables / secrets required

Gitea reserves the `GITEA_` prefix for its own built-in variables/secrets, so
none of these can be named `GITEA_*`:

| Name | Kind | Purpose |
|---|---|---|
| `REGISTRY_HOST` | variable | e.g. `https://git.internal.example.com` |
| `REGISTRY_ORG` | variable | org/owner to publish the package under |
| `PYPI_PUBLISH_USER` | secret | Gitea username for package publishing |
| `PYPI_PUBLISH_TOKEN` | secret | Gitea access token with package write scope |

No token is needed to check out the submodule — it points at the public
`https://github.com/BerriAI/litellm.git`.

### Duplicate version note

Gitea's package registry rejects re-uploading the same version+filename. Since a
build is only ever triggered by an intentional submodule bump to a new tag, this
should not come up in normal use — just don't re-run a build against an unchanged
submodule pin without expecting the publish step to fail.
