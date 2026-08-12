#!/usr/bin/env bash
# Cilex Watchtower — version bumper.
#
# ONE source of truth: project(VERSION x.y.z) in CMakeLists.txt. Everything else
# (the Windows resource block, the installer, the app manifest) is DERIVED from
# it here, so the four Windows spots can never drift out of sync with the number
# the app prints in its top-left corner.
#
# Policy (operator decision 2026-08-12): the PATCH component increments on every
# commit — 1.1.1, 1.1.2, 1.1.3 … Major and minor never move on their own; they
# change only when explicitly set:
#
#   tools/bump-version.sh              # 1.1.4 -> 1.1.5   (what the hook calls)
#   tools/bump-version.sh --set 1.2.0  # explicit, for when the operator says so
#   tools/bump-version.sh --print      # current version, no write
#
# Called automatically by tools/git-hooks/pre-commit. See docs/DEVELOPMENT.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CMAKE=CMakeLists.txt
RC=packaging/windows/watchtower.rc
NSI=packaging/windows/installer.nsi
MANIFEST=packaging/windows/app.manifest

cur() { sed -n 's/^ *VERSION \([0-9]\+\.[0-9]\+\.[0-9]\+\) *$/\1/p' "$CMAKE" | head -1; }

CURRENT="$(cur)"
[[ -n "$CURRENT" ]] || { echo "bump-version: no 'VERSION x.y.z' in $CMAKE" >&2; exit 1; }

case "${1:-}" in
    --print) echo "$CURRENT"; exit 0 ;;
    --set)
        NEW="${2:-}"
        [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bump-version: --set needs x.y.z" >&2; exit 1; }
        ;;
    "")  IFS=. read -r MA MI PA <<<"$CURRENT"; NEW="$MA.$MI.$((PA + 1))" ;;
    *)   echo "usage: bump-version.sh [--set x.y.z | --print]" >&2; exit 1 ;;
esac

IFS=. read -r MA MI PA <<<"$NEW"

# CMake — the source of truth. Anchored to the 3-component form so the unrelated
# 'VERSION 1.0' further down (the QML module version) is never touched.
sed -i "s/^\( *VERSION \)[0-9]\+\.[0-9]\+\.[0-9]\+ *$/\1$NEW/" "$CMAKE"

# Windows resource block: comma form for the binary fields, dotted 4-part for the
# human-readable strings. Both must agree or the file properties dialog disagrees
# with the installer.
if [[ -f "$RC" ]]; then
    sed -i -e "s/^\( *FILEVERSION *\)[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+/\1$MA,$MI,$PA,0/" \
           -e "s/^\( *PRODUCTVERSION *\)[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+/\1$MA,$MI,$PA,0/" \
           -e "s/\(VALUE \"FileVersion\", *\)\"[0-9.]\+\"/\1\"$NEW.0\"/" \
           -e "s/\(VALUE \"ProductVersion\", *\)\"[0-9.]\+\"/\1\"$NEW.0\"/" "$RC"
fi
[[ -f "$NSI" ]]      && sed -i "s/\(!define VERSION *\)\"[0-9.]\+\"/\1\"$NEW\"/" "$NSI"
[[ -f "$MANIFEST" ]] && sed -i "s/\(version=\)\"[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\"/\1\"$NEW.0\"/" "$MANIFEST"

echo "$NEW"
