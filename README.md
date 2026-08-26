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

```bash
git clone --recurse-submodules <this-repo-url>
# or, if already cloned without submodules:
git submodule update --init --recursive
```

## CI (Gitea Actions)

`.gitea/workflows/build-wheel.yml`:

- Triggers on push to `main` when the `litellm` submodule pointer changes, or
  manually via `workflow_dispatch`.
- Checks out this repo with `submodules: recursive` (no mirror repo, no
  cross-repo checkout needed).
- Builds the wheel with `poetry build -f wheel` (LiteLLM's `pyproject.toml` uses
  `poetry.core.masonry.api` as its build backend).
- Uploads the wheel as a workflow artifact and publishes it to the Gitea PyPI
  registry via `twine`.

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
