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
# Zero false positives across qml/ at the time of writing. If this ever fires on
# a comparison that genuinely cannot be NaN, rewrite it as `!(a > b)` anyway
# rather than adding an exception: the two are the same for every valid input,
# so there is nothing to trade away.
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
