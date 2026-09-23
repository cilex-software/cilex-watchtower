#!/usr/bin/env python3
"""EventModel::pollMotion() must NOT send exclude_types. Pin the omission.

WHY THIS EXISTS. kExcludeTypes drops motion_not_ready, motion_started and
motion_ended at the wire. Three of the four /events queries in EventModel.cpp
carry it; pollMotion() deliberately does not, because m_lastStarted and
m_lastEnded are populated from that poll and NOWHERE else. Add the parameter
there -- which looks like tidying up an oversight, since every sibling call has
it -- and motionActive() goes permanently false: the live MOTION indicator on
the wall goes dark, silently, while every other events path keeps working.

A comment at the line asks a future reader to notice. This asks the build to.
Same reasoning as received-letter-lint.sh: a rule is not structural until
something enforces it, and this one fails in the direction the house rule cares
about most -- a control that keeps rendering while reporting nothing.

cilex-vision offered to change the API default so omitting were safer. Declined,
and this file is the reason: `omit means no filtering` is the correct default,
a special case for one caller would be worse, and the invariant belongs in the
code that depends on it rather than in their endpoint.
"""
import re, sys, pathlib

SRC = pathlib.Path(__file__).resolve().parents[2] / "src" / "models" / "EventModel.cpp"
text = SRC.read_text(encoding="utf-8")

def body_of(sig):
    i = text.index(sig)
    j = text.index("{", i)
    depth, k = 0, j
    while k < len(text):
        if text[k] == "{": depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0: return text[j:k + 1]
        k += 1
    raise SystemExit(f"FAIL  could not find the end of {sig}")

def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)

fails = []

# 1. pollMotion must not filter -- comments don't count, code does.
pm = strip_comments(body_of("void EventModel::pollMotion()"))
if "exclude_types" in pm:
    fails.append("pollMotion() sends exclude_types. m_lastStarted/m_lastEnded are fed\n"
                 "      from this poll and nowhere else, so the live MOTION indicator on the\n"
                 "      wall would go permanently dark while every other events path works.")
else:
    print("PASS  pollMotion() sends no exclude_types")

# 2. ...and it must still feed the motion tracker, or the omission is pointless.
if "trackMotionRow" not in pm:
    fails.append("pollMotion() no longer calls trackMotionRow(); nothing populates\n"
                 "      m_lastStarted/m_lastEnded and motionActive() is dead either way.")
else:
    print("PASS  pollMotion() still feeds trackMotionRow()")

# 3. The bookends must still be the thing kExcludeTypes excludes -- if that list
#    stops naming them, this whole invariant dissolves and the comment lies.
m = re.search(r'kExcludeTypes\s*=\s*"([^"]*)"', text)
if not m:
    fails.append("kExcludeTypes not found; this lint can no longer verify anything.")
else:
    missing = [t for t in ("motion_started", "motion_ended") if t not in m.group(1)]
    if missing:
        fails.append(f"kExcludeTypes no longer excludes {', '.join(missing)}. If the server\n"
                     "      stopped filtering the bookends, pollMotion()'s special case is\n"
                     "      obsolete -- delete it deliberately rather than leaving it unexplained.")
    else:
        print("PASS  kExcludeTypes still excludes the motion bookends")

# 4. The siblings must still carry it, or the asymmetry is accidental, not chosen.
n = len(re.findall(r'addQueryItem\("exclude_types"', strip_comments(text)))
if n != 3:
    fails.append(f"expected exactly 3 filtered /events queries, found {n}. The asymmetry\n"
                 "      between pollMotion() and its siblings is deliberate; a change in the\n"
                 "      count means someone moved a boundary this lint was pinning.")
else:
    print("PASS  the other 3 /events queries still carry exclude_types")

if fails:
    print("\nFAIL  " + "\n\nFAIL  ".join(fails), file=sys.stderr)
    sys.exit(1)
print("all passed")
