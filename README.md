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

The workflow file's own inline comments explain the non-obvious choices (why
`uv` instead of system pip, why the UI gets rebuilt instead of trusting the
committed export, why the wheel is platform/ABI-specific, why three wheels
instead of one, etc.). [`CLAUDE.md`](CLAUDE.md) has a distilled list of this
Gitea instance's operating constraints — read it before editing this workflow.

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
