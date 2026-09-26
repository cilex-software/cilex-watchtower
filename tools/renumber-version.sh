#!/usr/bin/env bash
# Cilex Watchtower — give HEAD its parent's version + 1 (patch) and amend.
#
# The fix tools/git-hooks/pre-push prints when a rebase has left two commits on one
# version. Meant for `git rebase -x tools/renumber-version.sh <base>`: every replayed
# commit becomes its parent + 1, so a whole chain renumbers in one pass. Each pick
# still merges cleanly, because it makes the same N -> N+1 change the renumbered
# parent already made. Idempotent: a commit already at parent + 1 is left alone.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
prev=$(git show HEAD~1:CMakeLists.txt |
       sed -n 's/^ *VERSION \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) *$/\1/p' | head -1)
[[ -n "$prev" ]] || { echo "renumber-version: no VERSION in HEAD~1:CMakeLists.txt" >&2; exit 1; }
IFS=. read -r a b c <<<"$prev"
new="$a.$b.$((c + 1))"
[[ "$(tools/bump-version.sh --print)" == "$new" ]] && exit 0
tools/bump-version.sh --set "$new" >/dev/null
git add CMakeLists.txt packaging/windows/watchtower.rc packaging/windows/installer.nsi \
        packaging/windows/app.manifest
WT_NO_BUMP=1 git commit --amend --no-edit -q
echo "renumbered $(git rev-parse --short HEAD) -> $new"
