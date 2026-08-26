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
- Installs a Rust toolchain and a C toolchain (`build-essential`), then builds
  the wheel with `pip wheel . -w dist --no-deps`.
- Uploads the wheel as a workflow artifact and publishes it to the Gitea PyPI
  registry via `twine`.

**Build backend note:** LiteLLM's `pyproject.toml` build backend has changed
across releases — `poetry-core` (through ~1.6x), `uv_build` (~1.85-1.90), and
`maturin` from 1.95 onward, including the currently pinned `v1.98.0`. Maturin
compiles a native PyO3 extension (`litellm.rust_bridge._native`) from the
`litellm-rust/` Cargo workspace, so **the produced wheel is platform/ABI-specific**
(e.g. `litellm-1.98.0-cp311-cp311-linux_x86_64.whl`), not a universal
`py3-none-any` wheel — a single CI run only covers the runner's own OS/arch/Python
combination. `pip wheel .` deliberately isn't pinned to a specific maturin
version in this workflow: it reads `[build-system] requires` from the submodule's
own `pyproject.toml` via PEP 517 build isolation, so a future `bump-litellm.sh`
run that lands on a different backend/maturin version doesn't require editing
the workflow too — though a bump back to a pure-Python backend or a new backend
entirely may still need this build step revisited.

### Repo variables / secrets required

| Name | Kind | Purpose |
|---|---|---|
| `GITEA_HOST` | variable | e.g. `https://git.internal.example.com` |
| `GITEA_ORG` | variable | org/owner to publish the package under |
| `GITEA_PYPI_USER` | secret | Gitea username for package publishing |
| `GITEA_PYPI_TOKEN` | secret | Gitea access token with package write scope |

No token is needed to check out the submodule — it points at the public
`https://github.com/BerriAI/litellm.git`.

### Duplicate version note

Gitea's package registry rejects re-uploading the same version+filename. Since a
build is only ever triggered by an intentional submodule bump to a new tag, this
should not come up in normal use — just don't re-run a build against an unchanged
submodule pin without expecting the publish step to fail.
