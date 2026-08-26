#!/usr/bin/env bash
# Pin the litellm submodule to a specific upstream release tag and commit the bump.
#
# Usage: scripts/bump-litellm.sh v1.99.0
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <release-tag>" >&2
  exit 1
fi

tag="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

git -C litellm fetch --depth 1 origin tag "$tag"
git -C litellm checkout -q "$tag"
resolved="$(git -C litellm rev-parse HEAD)"

git config -f .gitmodules submodule.litellm.branch "$tag"
git add .gitmodules litellm

git commit -m "Bump litellm submodule to ${tag}" -m "Commit: ${resolved}"

echo "Pinned litellm submodule to ${tag} (${resolved})"
echo "Review with 'git show --stat HEAD' then push."
