#!/usr/bin/env bash
# One-time ROOT setup for the netem harness. Run: sudo tools/netem-harness/setup-root.sh
# Everything is idempotent and reversible (--remove). Scope of privilege granted:
# NOPASSWD sudo for /usr/sbin/tc ONLY (exact binary), for user cilex-vision.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
USER_NAME="${SUDO_USER:-cilex-vision}"
SUDOERS=/etc/sudoers.d/watchtower-netem

if [ "${1:-}" = "--remove" ]; then
  rm -f "$SUDOERS" /etc/modules-load.d/watchtower-netem.conf
  tc qdisc del dev lo root 2>/dev/null || true
  ethtool -K lo tso on gso on gro on 2>/dev/null || true
  echo "removed sudoers rule, module persistence, any lo qdisc; lo offloads restored"
  exit 0
fi

echo "== 1/4 netem kernel module =="
modprobe sch_netem
echo sch_netem > /etc/modules-load.d/watchtower-netem.conf
echo "   loaded + persisted"

echo "== 2/4 lo offloads OFF (per-packet netem fidelity; resets on reboot) =="
ethtool -K lo tso off gso off gro off
ethtool -k lo | grep -E "^tcp-segmentation-offload|^generic-segmentation-offload|^generic-receive-offload" | sed 's/^/   /'

echo "== 3/4 sudoers rule (tc only) =="
TMP=$(mktemp)
printf '%s ALL=(root) NOPASSWD: /usr/sbin/tc\n' "$USER_NAME" > "$TMP"
visudo -cf "$TMP"
install -m 0440 "$TMP" "$SUDOERS"; rm -f "$TMP"
echo "   installed $SUDOERS for $USER_NAME"

echo "== 4/4 verify as $USER_NAME =="
su -s /bin/bash "$USER_NAME" -c "sudo -n /usr/sbin/tc qdisc show dev lo" >/dev/null
echo "   OK — unprivileged 'sudo -n tc' works"
echo "DONE. The harness can now apply/clear impairment without your terminal."
