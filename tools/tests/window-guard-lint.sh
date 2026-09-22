#!/usr/bin/env bash
# Makes ONE rule structural instead of remembered.
#
# WHY THIS EXISTS. On 2026-09-22 four window guards read `end <= start`, meaning
# "I have no usable window, do nothing". Against NaN that comparison is FALSE, so
# the guard failed OPEN and the next line threw on new Date(NaN).toISOString().
# The correct form — `!(end > start)` — was ALREADY in this codebase at
# WallPlayback.qml:156 and had not propagated to three guards written after it.
#
# cilex-pro-mobile named the general mechanism the same evening, having hit it in
# their own repo the same day: "the rule was written once and not made
# structural, so it held where it was written and nowhere else." A fifth
# instance (PlaybackScreen.qml, the _wasFitted view check) was found by THIS
# SCRIPT after four had been found by hand — which is the argument for it.
#
# THE RULE: never `<=` or `>=` between two millisecond-timestamp identifiers.
# `!(a > b)` is identical for every finite pair by trichotomy and fires on NaN,
# so it is a free upgrade with no behaviour change on valid input.
#
# DISCRIMINATION, measured rather than assumed — the rule finds all five known
# instances and nothing else:
#     git grep -nE "$RULE" HEAD~1 -- 'qml/*'   -> 5 hits (the five real ones)
#     git grep -nE "$RULE" HEAD   -- 'qml/*'   -> 0
# Zero false positives across qml/ at the time of writing.
#
# WHAT THIS RULE CANNOT SEE, and the limit was found by cilex-pro-mobile running
# it against their own code before deciding whether to adopt it (2026-09-22).
# It keys on a NAMING CONVENTION, not on types, so it cannot tell an INSTANT from
# a DURATION. The justification "rewrite it anyway, the two forms are identical
# for valid input so there is nothing to trade away" is TRUE FOR INSTANT vs
# INSTANT and was overclaimed as universal when this script was first written.
# For a DURATION compared to a threshold — mobile's `startMs - last.endMs <=
# joinGapMs`, or `overlapMs >= OVERLAP_FLOOR_MS` — neither operand is a
# wire-derived instant, `!(a > b)` costs readability, and it buys nothing.
#
# WHY THE RULE IS STILL SAFE HERE: measured, every `*Ms <op> *Ms` comparison in
# qml/ is instant-vs-instant — 22 of them with `<`/`>`, zero duration-vs-
# threshold. That is a property of THIS codebase's naming, not of the rule. On a
# codebase where durations are also named `*Ms`, the rule would flag correct
# sites and force either pointless rewrites or the exception list this comment
# argues against — which is exactly why mobile measured five hits, zero
# reachable, two of them durations, and correctly declined to build it. A rule
# that starts life with an exception list is one nobody trusts.
#
# So if this ever fires on a comparison whose operands are durations: do not add
# an exception here. Check that neither operand can be NaN, and if that holds,
# the naming is what needs fixing — a duration called `*Ms` is what made the
# rule ambiguous in the first place.
set -uo pipefail
cd "$(dirname "$0")/../.."
RULE='[A-Za-z_][A-Za-z0-9_.]*Ms[[:space:]]*(<=|>=)[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*Ms\b'
hits=$(grep -rnE "$RULE" qml/ || true)
if [ -n "$hits" ]; then
    echo "FAIL  a millisecond-timestamp guard uses <= or >=, which is FALSE against NaN."
    echo "      Rewrite as !(a > b) — identical for finite pairs, and it fires on NaN."
    echo "$hits" | sed 's/^/      /'
    exit 1
fi
echo "PASS  no <=/>= between millisecond-timestamp identifiers in qml/"
