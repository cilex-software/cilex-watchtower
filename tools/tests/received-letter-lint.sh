#!/usr/bin/env bash
# A letter that ARRIVED from another agent gets its own commit.
#
# WHY. Peers write letters directly into this checkout's docs/letters/ while work is
# in progress, so at any moment there may be untracked files that are not yours. On
# 2026-09-23 a top-level `git add -A` published 219 lines of cilex-vision's
# correspondence inside a commit titled "feat(warden): app_version on the beat";
# an audit found the same in fb909a0. cilex-pro-mobile audited their own log on the
# strength of that and found 5a95fdd — a commit titled "полоса кадров ждала ПРОСЬБЫ
# играть" that also published a letter of Vision's to them. Same shape, same cause.
#
# THE OUTCOME WAS NEVER THE DAMAGE. CLAUDE.md says received letters are committed
# verbatim, so those files belonged in the repo either way. What breaks is the LOG:
# a commit whose message describes a Warden change also published somebody's
# correspondence, so its arrival cannot be found by reading the history — which is
# the one thing the history is for.
#
# WHY THIS EXISTS RATHER THAN THE RULE ALONE. The pre-commit hook has carried
# "never `git add -A`, which would sweep unrelated work into someone's commit" since
# the day it was written — about its OWN staging — and it did not stop the hand that
# types `git commit`. That is the third time in one day that a rule held exactly
# where it was written and nowhere else (the others: `!(a > b)` present at
# WallPlayback.qml:156 and absent from four later guards, and "never use -m with
# backticks", broken forty minutes after being recorded). A rule is not structural
# until something enforces it.
#
# THE SENDER MATCH WAS BLIND TO MOST OF THE CORPUS (found 2026-09-23, hours after
# this file was written). The original extractor was `grep -m1 '^From:'`. Letters in
# this directory are written in two header styles, and 379 of 655 use the markdown
# form `**From:**`, which that pattern does not match AT ALL — so for the majority of
# arrivals the lint saw no sender, classified the letter as ordinary work, and passed.
# It passed on the very letter that arrived the day it was written.
#
# This is the same defect, in the same shape, as one I had corrected in somebody
# else's grep that same morning: cilex-vision enumerated Labs' error codes with
# `CodedError(40[0-9]` and silently missed every call whose status sat on the next
# line, which cost them a "there is no 403 on this path" that was false. I wrote this
# pattern AFTER telling them why theirs was wrong. A grep over a corpus you have not
# counted reports the absence of what it cannot see; the fix in both cases was to
# count the corpus first. Verified after: 317 foreign / 324 mine / 14 with no
# recognisable header, against 201 / 0 / 454 before.
#
# WT_NO_LETTER_LINT=1 skips it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ "${WT_NO_LETTER_LINT:-}" == "1" ]] && exit 0

# Files the version bumper owns are staged by the hook itself and are never "other work".
BUMPED="CMakeLists.txt packaging/windows/watchtower.rc packaging/windows/installer.nsi packaging/windows/app.manifest"

foreign=() other=()
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case " $BUMPED " in *" $f "*) continue;; esac
    if [[ "$f" == docs/letters/*.md ]]; then
        # Only ADDED letters can have "arrived"; edits to my own are ordinary work.
        if git diff --cached --diff-filter=A --name-only -- "$f" | grep -q .; then
            # Tolerates: leading spaces, a `> ` preface blockquote, and markdown
            # emphasis in any of the forms seen in this directory -- **From:**,
            # *From:*, **From**:.
            from=$(git show ":$f" 2>/dev/null \
                   | sed -E -n 's/^[[:space:]]*>?[[:space:]]*\**[[:space:]]*From[[:space:]]*\**[[:space:]]*:[[:space:]]*\**[[:space:]]*//p' \
                   | head -1)
            # "Mine" stays narrow on purpose: the Windows station agent and the macOS
            # agent are also @ cilex-watchtower, and their letters ARRIVE here. Only
            # this box's own qualifier counts. An unqualified header is treated as
            # foreign -- fail-closed costs one extra commit, the other direction costs
            # a letter buried in the log, which is the thing this exists to prevent.
            if [[ -n "$from" && "$from" != *"cilex-watchtower (Linux"* ]]; then
                foreign+=("$f|$from"); continue
            fi
            # No recognisable header at all. Do not claim it arrived -- but do not
            # swallow it either, because that silence is what this whole file is about.
            [[ -z "$from" ]] && echo "note  added letter has no recognisable 'From:' header: $f"
        fi
    fi
    other+=("$f")
done < <(git diff --cached --name-only)

if [[ ${#foreign[@]} -gt 0 && ${#other[@]} -gt 0 ]]; then
    echo "FAIL  a letter that ARRIVED from another agent is staged alongside other work."
    echo "      Commit it on its own, with a message saying it arrived and from whom."
    for e in "${foreign[@]}"; do
        echo "      letter: ${e%%|*}"
        echo "              ${e#*|}"
    done
    echo "      also staged (${#other[@]} files): ${other[*]:0:6}"
    exit 1
fi
echo "PASS  no received letter bundled with unrelated work"
