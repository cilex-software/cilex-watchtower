#!/usr/bin/env bash
# One-time ROOT setup for the netem harness. Run: sudo tools/netem-harness/setup-root.sh
# Everything is idempotent and reversible (--remove). Scope of privilege granted:
# NOPASSWD sudo for /usr/sbin/tc ONLY (exact binary), for user cilex-vision.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
USER_NAME="${SUDO_USER:-cilex-vision}"
SUDOERS=/etc/sudoers.d/watchtower-netem

BR=$(ip route get 10.0.0.9 2>/dev/null | grep -oP 'dev \K\S+' | head -1)

if [ "${1:-}" = "--remove" ]; then
  rm -f "$SUDOERS" /etc/modules-load.d/watchtower-netem.conf
  tc qdisc del dev lo root 2>/dev/null || true
  [ -n "$BR" ] && { tc qdisc del dev "$BR" root 2>/dev/null; tc qdisc del dev "$BR" ingress 2>/dev/null; } || true
  tc qdisc del dev ifb0 root 2>/dev/null || true
  ip link del ifb0 2>/dev/null || true
  ethtool -K lo tso on gso on gro on 2>/dev/null || true
  echo "removed sudoers rule, module persistence, qdiscs, ifb0; lo offloads restored"
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

echo "== 5/6 IFB device (response-direction shaping: bridge ingress -> ifb0) =="
# Docker OUTPUT-DNAT sends host->backend traffic over the docker bridge, NOT lo
# (proven 2026-07-18: bridge netem shaped connects, lo counters stayed 0). Bridge
# egress covers requests; responses are bridge INGRESS -> must be redirected to an
# IFB device to be shaped. Creating ifb needs root, so it happens here once.
modprobe ifb numifbs=0 2>/dev/null || modprobe ifb || true
ip link add dev ifb0 type ifb 2>/dev/null || true
ip link set dev ifb0 up
echo ifb >> /etc/modules-load.d/watchtower-netem.conf
sort -u -o /etc/modules-load.d/watchtower-netem.conf /etc/modules-load.d/watchtower-netem.conf
echo "   ifb0 up (recreate after reboot by re-running this script)"

echo "== 6/6 offloads OFF on the real path (bridge + ifb0) =="
if [ -n "$BR" ]; then
  ethtool -K "$BR" tso off gso off gro off 2>/dev/null || true
  echo "   $BR offloads off"
else
  echo "   WARN: docker bridge for 10.0.0.0/24 not found — re-run when backend is up"
fi
ethtool -K ifb0 tso off gso off gro off 2>/dev/null || true

echo "== 4/4->7 verify as $USER_NAME =="
su -s /bin/bash "$USER_NAME" -c "sudo -n /usr/sbin/tc qdisc show dev lo" >/dev/null
echo "   OK — unprivileged 'sudo -n tc' works"
echo "DONE. The harness can now apply/clear impairment without your terminal."
