#!/usr/bin/env python3
"""Refuse a NEW comment that asserts how another system behaves without saying
when, or how we know.

WHY. On 2026-09-23 `qml/ExportDrawer.qml:12` still said cilex-vision's
POST /review/exports "accepts only {camera_id, wall_start, wall_end, mode}" and
that "Purpose ... ha[s] no server field yet". Written 2026-05-27, true then, and
false for months: CV's model carries group_id, purpose and hevc_capable, and our
OWN PlaybackClient::createExport sends all three. The comment contradicted a
change we made ourselves and nobody noticed, because nothing dated it.

Same family, same week: a comment of ours called `stream_type` the backend's
"authoritative" retention signal (it is a stream SELECTION), and cilex-vision's
own timefmt.py described a Hermes crash nobody had measured. A claim about
another system decays silently — the other system changes and our comment does
not, and the next reader has no way to tell a fresh fact from a stale one.

THE RULE. A comment naming another system AND asserting its behaviour must
carry ONE of:
  * a date          2026-09-23, or 2026-09
  * a citation      review.py:1430, a letter/reply reference, "measured",
                    "verified", "Server-Timing"
  * the marker      "(Claim about X, written YYYY-MM-DD and not re-checked since.)"

SCOPED TO ADDED LINES ONLY, deliberately. cilex-pro-mobile declined a lint of
mine on 2026-09-22 because it would have begun life with an exception list, and
they were right: a rule nobody trusts gets disabled the first time it is
inconvenient. This one reads `git diff` and judges only lines you are ADDING, so
it starts at zero violations and cannot be blamed for history.

  tools/tests/cross-system-claim-lint.py              # staged changes (pre-commit)
  tools/tests/cross-system-claim-lint.py HEAD~20      # audit a range, for calibration

LIMIT, found while calibrating this: block_at() reads the WORKING TREE, not the
file as of the audited commit. That is right for the pre-commit case — you are
judging the block you are about to commit — but it makes a historical audit
optimistic, because blocks fixed since will read as sourced. Do not quote a
range-audit as a false-positive rate; prove the rule by making it FAIL on a
deliberately bad line instead. Done 2026-09-23: it caught an undated 'CV returns
the fleet roster sorted by name', and passed the same line once cited.
"""
import re, subprocess, sys

SYS = re.compile(r"\b(CV|cilex-vision|Cilex Vision|query-api|playback-service|go2rtc"
                 r"|Pro Mobile|cilex-pro-mobile)\b")
VERB = re.compile(r"\b(returns?|sends?|serves?|answers?|emits?|rejects?|accepts?|requires?"
                  r"|refuses?|responds?|provides?|carries|carry|reports?|stamps?|drops?"
                  r"|caps?|limits?|expires?|403s?|401s?|500s?|writes?|stores?|keeps?)\b", re.I)
OK = re.compile(r"20\d{2}-\d{2}(-\d{2})?\b"                      # a date
                r"|\b[\w/]+\.(py|cpp|h|qml|ts|tsx):\d+"          # a source citation
                r"|\bletter\b|\breply\d*\b|\bmeasured\b|\bverified\b|\bServer-Timing\b"
                r"|\bClaim about\b", re.I)
COMMENT = re.compile(r"^\s*(//|#|\*)")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)")

def added_lines(rev):
    cmd = ["git", "diff", "-U0"] + ([rev] if rev else ["--cached"]) + \
          ["--", "src/", "qml/"]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    path, ln = None, 0
    for raw in out.split("\n"):
        if raw.startswith("+++ b/"):
            path, ln = raw[6:], 0
        elif raw.startswith("@@"):
            m = HUNK.match(raw)
            if m: ln = int(m.group(1))
        elif raw.startswith("+") and not raw.startswith("+++"):
            yield path, ln, raw[1:]
            ln += 1

def block_at(path, ln, cache={}):
    """The contiguous comment run containing line `ln` of the WORKING TREE file.

    The diff says which lines are NEW; the file says whether the claim is sourced.
    Judging the added line alone was wrong and this lint caught it on its own first
    run: a two-line claim can carry its citation on the second line, and a rule that
    forces the date onto the same line just produces worse comments.
    """
    if path not in cache:
        try: cache[path] = open(path, encoding="utf-8").read().split("\n")
        except OSError: cache[path] = []
    lines = cache[path]
    if not lines or ln > len(lines): return ""
    i = ln - 1
    lo = hi = i
    while lo > 0 and COMMENT.match(lines[lo - 1]): lo -= 1
    while hi + 1 < len(lines) and COMMENT.match(lines[hi + 1]): hi += 1
    return " ".join(lines[lo:hi + 1])

def main():
    rev = sys.argv[1] if len(sys.argv) > 1 else None
    bad = []
    for path, ln, text in added_lines(rev):
        if not path or not path.endswith((".cpp", ".h", ".qml", ".js")): continue
        if not COMMENT.match(text): continue
        if not (SYS.search(text) and VERB.search(text)): continue
        if OK.search(text): continue
        if OK.search(block_at(path, ln)): continue      # sourced elsewhere in its block
        bad.append((path, ln, text.strip()))
    if bad:
        print("FAIL  a new comment asserts how another system behaves, undated and uncited.")
        print("      Add a date, a source citation, or say how you know. See the header.")
        for p, ln, t in bad:
            print("      %s:%d  %s" % (p, ln, t[:92]))
        return 1
    print("PASS  no new undated, uncited cross-system claims")
    return 0

if __name__ == "__main__":
    sys.exit(main())
