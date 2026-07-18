#!/usr/bin/env bash
# Port-scoped netem impairment for the client<->backend path. See README.md.
#
# TOPOLOGY (proven 2026-07-18): Docker's OUTPUT-chain DNAT rewrites host traffic
# to published ports (8000/8554/1984) toward the container IPs BEFORE routing, so
# it rides the docker bridge — NOT lo (lo qdisc counters stayed at 0 while a
# bridge netem shaped connects). Therefore:
#   REQUEST direction  (host -> container): shaped on the BRIDGE EGRESS qdisc.
#   RESPONSE direction (container -> host): bridge INGRESS, redirected to IFB0
#     (created once by setup-root.sh) and shaped there; rate caps (tbf) live on
#     this direction — it carries the segment downloads.
# Inter-container traffic switches through the bridge at L2 and never enters the
# host qdisc — it stays unshaped, as intended (server-internal).
#
# impair.sh [--dry] apply <profile> | off | status | verify | list
set -uo pipefail
PORTS="${WT_NETEM_PORTS:-8000 8554 1984}"
BACKEND="${WT_NETEM_VERIFY_URL:-192.168.1.79:8000}"
DRY=0; [ "${1:-}" = "--dry" ] && { DRY=1; shift; }
CMD="${1:-status}"; PROFILE="${2:-}"

BR="${WT_NETEM_DEV:-$(ip route get 10.0.0.9 2>/dev/null | grep -oP 'dev \K\S+' | head -1)}"
# Host's own bridge address: scoping filters to it exempts every OTHER backend
# client (e.g. Cilex Pro Mobile on the LAN, whose DNAT'd packets keep their
# 192.168.1.x source) — only Watchtower<->backend traffic is impaired, and
# external clients can't drain the tbf bucket mid-row (2026-07-18).
HOSTIP="${WT_NETEM_HOSTIP:-$(ip route get 10.0.0.9 2>/dev/null | grep -oP 'src \K\S+' | head -1)}"
IFB=ifb0

# profile -> "netem args|tbf args-or-empty"  (values are PER-DIRECTION)
prof() {
  case "$1" in
    baseline)   echo "|" ;;
    lan-jitter) echo "delay 5ms 3ms distribution normal|" ;;
    wan50)      echo "delay 50ms 10ms distribution normal|" ;;
    wan200)     echo "delay 200ms 40ms distribution normal|" ;;
    loss1)      echo "delay 20ms 5ms distribution normal loss random 1%|" ;;
    loss5)      echo "delay 30ms 8ms distribution normal loss random 5%|" ;;
    burst-ge)   echo "delay 30ms 8ms distribution normal loss gemodel 1% 25% 80% 0.1%|" ;;
    reorder)    echo "delay 15ms reorder 25% 50% gap 5|" ;;
    corrupt)    echo "delay 10ms corrupt 0.5%|" ;;
    bw4m)       echo "delay 20ms 5ms distribution normal|rate 4mbit burst 32kbit latency 400ms" ;;
    bw1m)       echo "delay 40ms 10ms distribution normal|rate 1mbit burst 16kbit latency 600ms" ;;
    mobile3g)   echo "delay 100ms 20ms distribution normal loss random 1%|rate 2mbit burst 32kbit latency 500ms" ;;
    worst)      echo "delay 150ms 30ms distribution normal loss random 2%|rate 3mbit burst 32kbit latency 500ms" ;;
    *)          return 1 ;;
  esac
}
PROFILES="baseline lan-jitter wan50 wan200 loss1 loss5 burst-ge reorder corrupt bw4m bw1m mobile3g worst"

TC_BIN=/usr/sbin/tc
tc_priv() {
  if [ $DRY = 1 ]; then echo "DRY: tc $*"; return 0; fi
  if sudo -n "$TC_BIN" "$@" 2>/tmp/impair-tc.err; then return 0; fi
  if "$TC_BIN" "$@" 2>>/tmp/impair-tc.err; then return 0; fi
  return 1
}
authorized() { sudo -n "$TC_BIN" qdisc show dev "${BR:-lo}" >/dev/null 2>&1; }
clear_all() {
  [ -n "$BR" ] && { tc_priv qdisc del dev "$BR" root 2>/dev/null; tc_priv qdisc del dev "$BR" ingress 2>/dev/null; }
  tc_priv qdisc del dev $IFB root 2>/dev/null
  return 0
}

case "$CMD" in
list)
  for p in $PROFILES; do IFS='|' read -r n t <<< "$(prof $p)"; printf "%-10s netem[%s] tbf[%s]\n" "$p" "${n:-none}" "${t:-none}"; done ;;

off)
  clear_all
  echo "impairment cleared (bridge egress + ingress redirect + $IFB)" ;;

apply)
  [ -n "$PROFILE" ] || { echo "usage: impair.sh apply <profile>"; exit 2; }
  SPEC=$(prof "$PROFILE") || { echo "unknown profile '$PROFILE' (see: impair.sh list)"; exit 2; }
  IFS='|' read -r NETEM TBF <<< "$SPEC"
  [ -n "$BR" ] || { echo "FATAL: docker bridge for 10.0.0.0/24 not found (backend down?)"; exit 4; }
  if [ $DRY = 0 ] && ! authorized; then
    echo "NOT AUTHORIZED: run once in your terminal:  sudo tools/netem-harness/setup-root.sh"; exit 3
  fi
  if [ $DRY = 0 ] && ! ip link show $IFB >/dev/null 2>&1; then
    echo "FATAL: $IFB missing — re-run: sudo tools/netem-harness/setup-root.sh (creates it)"; exit 3
  fi
  if [ $DRY = 0 ] && ethtool -k "$BR" 2>/dev/null | grep -qE "^generic-segmentation-offload: on"; then
    echo "WARN: GSO ON on $BR (reboot reset?) — loss %% acts on superpackets; re-run setup-root.sh" >&2
  fi
  clear_all
  [ -z "$NETEM" ] && { echo "profile baseline = no impairment"; exit 0; }
  # REQUEST direction: bridge egress, dport-scoped
  tc_priv qdisc add dev "$BR" root handle 1: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 || exit 4
  tc_priv qdisc add dev "$BR" parent 1:4 handle 40: netem $NETEM || exit 4
  for P in $PORTS; do
    tc_priv filter add dev "$BR" protocol ip parent 1: prio 1 u32 \
            match ip src "$HOSTIP"/32 match ip dport $P 0xffff flowid 1:4 || exit 4
  done
  # RESPONSE direction: bridge ingress -> ifb0 (sport-scoped), netem [+ tbf] there
  tc_priv qdisc add dev "$BR" handle ffff: ingress || exit 4
  for P in $PORTS; do
    tc_priv filter add dev "$BR" parent ffff: protocol ip prio 1 u32 \
            match ip dst "$HOSTIP"/32 match ip sport $P 0xffff \
            action mirred egress redirect dev $IFB || exit 4
  done
  tc_priv qdisc add dev $IFB root handle 2: netem $NETEM || exit 4
  [ -n "$TBF" ] && { tc_priv qdisc add dev $IFB parent 2: handle 20: tbf $TBF || exit 4; }
  echo "applied '$PROFILE' on $BR<->$IFB ports [$PORTS]: netem[$NETEM] tbf[${TBF:-none}] (per-direction)" ;;

status)
  [ -n "$BR" ] && { echo "-- $BR (egress=requests):"; "$TC_BIN" -s qdisc show dev "$BR" | grep -E "qdisc|Sent" ; }
  echo "-- $IFB (responses):"; "$TC_BIN" -s qdisc show dev $IFB 2>/dev/null | grep -E "qdisc|Sent" || echo "   (no ifb qdisc)" ;;

verify)
  # SYN delayed on bridge egress + SYNACK delayed via ifb -> connect ~= 2x delay
  for i in 1 2 3; do curl -so /dev/null -w "%{time_connect}\n" --connect-timeout 5 "http://$BACKEND/" 2>/dev/null; done | \
    awk '{s+=$1; n++} END{if(n) printf "connect RTT mean over %d tries: %.1f ms\n", n, s/n*1000; else print "verify FAILED (backend unreachable)"}'
  for D in "$BR" $IFB; do [ -n "$D" ] && "$TC_BIN" -s qdisc show dev "$D" 2>/dev/null | grep -A1 netem | head -4; done ;;

*) echo "usage: impair.sh [--dry] apply <profile> | off | status | verify | list"; exit 2 ;;
esac
