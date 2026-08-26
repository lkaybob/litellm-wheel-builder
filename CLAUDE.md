# CLAUDE.md

Operating notes for working on this repo's CI (`.gitea/workflows/build-wheel.yml`)
and submodule setup — constraints specific to the Gitea instance and runner
this actually deploys to, found by testing against it directly rather than
assumed. See [README.md](README.md) for what this project is and
[docs/upgrading.md](docs/upgrading.md) for the version-bump procedure; this
file is deliberately narrower than either.

## The Gitea Actions runner

- Self-hosted `act_runner`, not a GitHub-hosted runner. Don't assume
  GitHub-hosted behavior (pre-populated tool cache, pre-installed SDKs,
  `@v4`-generation actions) works here without checking.
- Confirmed base image: Debian bullseye, root user, Python 3.9 with **no
  `pip3`** at all, `apt-get` available. litellm requires Python >=3.10, so the
  system interpreter can't build or install it — this is why the workflow
  provisions its own Python via `uv` instead of relying on the runner's.
- The "Runner environment" step at the top of the workflow exists to
  re-discover this if the runner's image ever changes. Check its output
  before debugging a mysterious failure further down the workflow, rather
  than assuming the facts above still hold.

## Known-broken GitHub Actions on this Gitea instance

- `actions/setup-python` — fails with "Version X.Y was not found in the local
  cache". Self-hosted runners don't get the pre-populated tool cache
  GitHub-hosted runners have. Use `uv` to provision Python instead.
- `actions/upload-artifact@v4` / `download-artifact@v4` — fail with "not
  currently supported on GHES". Gitea hasn't implemented the newer
  `@actions/artifact` v2 backend these use. Use `@v3`.
- Gitea rejects Actions variable/secret names starting with `GITEA_` (reserved
  for its own built-in ones) — see README.md's repo variables/secrets table
  for the names actually in use.

## Submodule / build conventions

- `litellm/` is a git submodule, always pinned to an upstream **release
  tag**, never a branch. Bump it only via `scripts/bump-litellm.sh` — never
  by manually editing `.gitmodules` or checking out a different ref by hand.
- Never do a full (non-shallow) `git clone`/`submodule update` against it —
  LiteLLM's history is large enough that a full clone reliably times out.
  Always `--depth 1` / `--shallow-submodules`.
- LiteLLM's build backend has changed across releases (`poetry-core` →
  `uv_build` → `maturin`, currently `maturin`). Don't assume the current
  build command (`uv build --wheel`) stays correct forever — if the build
  starts failing after a version bump, check `litellm/pyproject.toml`'s
  `[build-system]` first.
- The produced `litellm` wheel is platform/ABI-specific (it compiles a native
  Rust/PyO3 extension), not a universal wheel. A single CI run only covers
  the runner's own OS/arch/Python combination.
- `litellm-proxy-extras` and `litellm-enterprise` are exact-pinned `uv`
  workspace members, not independent packages — always build and publish all
  three together from the same commit, never `litellm` alone. This is what
  prevents the Prisma-schema-mismatch class of bug this project hit before
  this setup existed.
