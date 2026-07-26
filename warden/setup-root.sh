#!/usr/bin/env bash
# One-time ROOT setup for Warden core dumps (CW-07). Optional: without it,
# bundles simply carry no core (marker + flightrec + console still collected).
#
# Points kernel.core_pattern at the app's crash dir. NOTE: core_pattern is
# GLOBAL — on a dedicated guard box that is exactly right; on a shared dev
# machine it also redirects other apps' cores away from apport. Say so.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

USER_NAME="${SUDO_USER:-$(logname)}"
CRASH_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)/.local/share/Cilex Vision/Watchtower/crash"
mkdir -p "$CRASH_DIR"
chown "$USER_NAME": "$CRASH_DIR"

cat > /etc/sysctl.d/90-watchtower-core.conf <<EOF
# Watchtower Warden (CW-07): cores into the app crash dir for bundle collection.
# %e=exe %t=epoch %P=global pid — matches warden.py find_core().
kernel.core_pattern=${CRASH_DIR}/core-%e-%t-%P
EOF
sysctl -p /etc/sysctl.d/90-watchtower-core.conf

echo "core_pattern -> ${CRASH_DIR}/core-%e-%t-%P"
echo "(revert: rm /etc/sysctl.d/90-watchtower-core.conf && sysctl -w kernel.core_pattern='|/usr/share/apport/apport -p%p -s%s -c%c -d%d -P%P -u%u -g%g -F%F -- %E')"
