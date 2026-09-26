#!/usr/bin/env bash
# The pre-push version check, on a REAL collision made in throwaway repositories:
# two clones, one pull --rebase, the exact shape the Windows agent found on main
# (a replayed commit that made the same N -> N+1 bump as the one it landed on).
# Then the fix the hook prints, and the hook again. Hermetic: nothing leaves $TMP.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

seed="$TMP/seed"; mkdir -p "$seed/tools/git-hooks" "$seed/packaging/windows"
cp "$ROOT/tools/bump-version.sh" "$ROOT/tools/renumber-version.sh" "$seed/tools/"
cp "$ROOT/tools/git-hooks/pre-push" "$seed/tools/git-hooks/"
cp "$ROOT/CMakeLists.txt" "$seed/"
cp "$ROOT/packaging/windows/watchtower.rc" "$ROOT/packaging/windows/installer.nsi" \
   "$ROOT/packaging/windows/app.manifest" "$seed/packaging/windows/"
g() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }
# The printed fix runs as PLAIN git (as a person would run it), so the throwaway repos need
# an identity that does not come from g(). The booth has no global one, and without this
# the renumber amend died there: "unable to auto-detect email address" (Windows agent,
# 2026-09-26; reproduced here with HOME emptied -- the same 3 FAILs).
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
( cd "$seed" && git init -q -b main . && echo base > notes.txt ) || exit 1
g "$seed" add -A && g "$seed" commit -q -m seed
git init -q --bare -b main "$TMP/origin.git"
g "$seed" push -q "$TMP/origin.git" main
git clone -q "$TMP/origin.git" "$TMP/a"; git clone -q "$TMP/origin.git" "$TMP/b"
commit() {   # what pre-commit does: bump, then commit the change with it
    echo "$3" >> "$1/$2"; "$1/tools/bump-version.sh" >/dev/null
    g "$1" add -A && g "$1" commit -q -m "$3"
}
prepush() {  # feed the hook exactly what git feeds it
    local repo="$1"; local rsha; rsha=$(g "$repo" rev-parse origin/main)
    ( cd "$repo" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$rsha" |
        env ${2:-} tools/git-hooks/pre-push origin "$TMP/origin.git" )
}
V0=$("$seed/tools/bump-version.sh" --print)

commit "$TMP/a" notes.txt "x from A"
check "control: an ordinary commit (parent + 1) passes the hook" 'prepush "$TMP/a" >/dev/null 2>&1'
g "$TMP/a" push -q origin main

commit "$TMP/b" notes2.txt "y from B"
commit "$TMP/b" notes3.txt "z from B"
g "$TMP/b" pull -q --rebase origin main
vy=$(g "$TMP/b" show HEAD~1:CMakeLists.txt | sed -n 's/^ *VERSION \([0-9.]*\) *$/\1/p' | head -1)
vx=$(g "$TMP/b" show HEAD~2:CMakeLists.txt | sed -n 's/^ *VERSION \([0-9.]*\) *$/\1/p' | head -1)
check "the collision is real: after pull --rebase, y sits on x's version ($vy = $vx)" '[[ -n "$vy" && "$vy" == "$vx" ]]'
out=$(prepush "$TMP/b" 2>&1); rc=$?
check "the hook REFUSES it (exit 1)" '[[ $rc -eq 1 ]]'
check "...naming the commit and both versions" '[[ "$out" == *"y from B"*"carries $vy; its parent carries $vx"* ]]'
check "...and printing the fix" '[[ "$out" == *"git rebase -x tools/renumber-version.sh"* ]]'
check "WT_ALLOW_SAME_VERSION=1 lets it through (the emergency hatch)" 'prepush "$TMP/b" WT_ALLOW_SAME_VERSION=1 >/dev/null 2>&1'
slow_hatch() {   # a feeder SLOWER than the hook: deterministic, where the race was not
    ( sleep 0.3; printf 'refs/heads/main %s refs/heads/main %s\n' "$(g "$TMP/b" rev-parse HEAD)" \
        "$(g "$TMP/b" rev-parse origin/main)" ) |
        ( cd "$TMP/b" && WT_ALLOW_SAME_VERSION=1 tools/git-hooks/pre-push origin "$TMP/origin.git" )
}
check "...and the hatch still drains its input (a slow feeder is not killed by SIGPIPE)" 'slow_hatch >/dev/null 2>&1'

fix=$(printf '%s\n' "$out" | sed -n 's/^  \(git rebase -x .*\)$/\1/p')
( cd "$TMP/b" && GIT_EDITOR=true $fix >/dev/null 2>&1 )
chain=$(for r in HEAD~2 HEAD~1 HEAD; do g "$TMP/b" show "$r:CMakeLists.txt" | sed -n 's/^ *VERSION \([0-9.]*\) *$/\1/p' | head -1; done | tr '\n' ' ')
IFS=. read -r M m p <<<"$vx"
want="$M.$m.$p $M.$m.$((p + 1)) $M.$m.$((p + 2)) "
check "the printed fix renumbers the whole chain in one pass (x, y, z = $want)" '[[ "$chain" == "$want" ]]'
check "...and every other file of y and z survived it" '[[ -f "$TMP/b/notes2.txt" && -f "$TMP/b/notes3.txt" ]] && g "$TMP/b" diff --quiet'
check "the hook now lets the push through" 'prepush "$TMP/b" >/dev/null 2>&1'
before=$(g "$TMP/b" rev-parse HEAD)
( cd "$TMP/b" && tools/renumber-version.sh >/dev/null )
check "renumber is IDEMPOTENT: a commit already at parent + 1 is left alone (same sha)" '[[ "$(g "$TMP/b" rev-parse HEAD)" == "$before" ]]'
[[ "$V0" == "$M.$m.$((p - 1))" ]] || { echo "FAIL sanity: seed was $V0, x should be seed + 1 ($vx)"; fails=$((fails + 1)); }

echo
if (( fails )); then echo "$fails FAILED" >&2; exit 1; fi
echo "all passed"
