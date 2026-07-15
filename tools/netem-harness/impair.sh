#!/usr/bin/env bash
# Port-scoped netem impairment on lo (backend ports only). See README.md.
# impair.sh [--dry] apply <profile> | off | status | verify | list
set -uo pipefail
PORTS="${WT_NETEM_PORTS:-8000 8554 1984}"
DEV=lo
BACKEND="${WT_NETEM_VERIFY_URL:-192.168.1.79:8000}"
DRY=0; [ "${1:-}" = "--dry" ] && { DRY=1; shift; }
CMD="${1:-status}"; PROFILE="${2:-}"

# profile -> "netem args|tbf args-or-empty"
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
  if "$TC_BIN" "$@" 2>>/tmp/impair-tc.err; then return 0; fi   # file-caps fallback
  return 1
}
authorized() { sudo -n "$TC_BIN" qdisc show dev $DEV >/dev/null 2>&1 || "$TC_BIN" qdisc add dev $DEV 2>/dev/null; }

case "$CMD" in
list)
  for p in $PROFILES; do IFS='|' read -r n t <<< "$(prof $p)"; printf "%-10s netem[%s] tbf[%s]\n" "$p" "${n:-none}" "${t:-none}"; done ;;

off)
  tc_priv qdisc del dev $DEV root 2>/dev/null
  echo "impairment cleared (lo root qdisc removed)" ;;

apply)
  [ -n "$PROFILE" ] || { echo "usage: impair.sh apply <profile>"; exit 2; }
  SPEC=$(prof "$PROFILE") || { echo "unknown profile '$PROFILE' (see: impair.sh list)"; exit 2; }
  IFS='|' read -r NETEM TBF <<< "$SPEC"
  if [ $DRY = 0 ] && ! authorized; then
    echo "NOT AUTHORIZED: run once in your terminal:  sudo tools/netem-harness/setup-root.sh"; exit 3
  fi
  if [ $DRY = 0 ] && ethtool -k $DEV 2>/dev/null | grep -qE "^generic-segmentation-offload: on"; then
    echo "WARN: GSO is ON on $DEV (reboot reset?) — loss %% acts on superpackets; re-run setup-root.sh for fidelity" >&2
  fi
  tc_priv qdisc del dev $DEV root 2>/dev/null   # idempotent fresh start
  [ -z "$NETEM" ] && { echo "profile baseline = no impairment"; exit 0; }
  # prio root: bands 1:1-1:3 = untouched default traffic; 1:4 = our impaired branch
  tc_priv qdisc add dev $DEV root handle 1: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 || exit 4
  tc_priv qdisc add dev $DEV parent 1:4 handle 40: netem $NETEM || exit 4
  [ -n "$TBF" ] && { tc_priv qdisc add dev $DEV parent 40: handle 400: tbf $TBF || exit 4; }
  for P in $PORTS; do   # both directions: requests (dport) and responses (sport)
    tc_priv filter add dev $DEV protocol ip parent 1: prio 1 u32 match ip dport $P 0xffff flowid 1:4 || exit 4
    tc_priv filter add dev $DEV protocol ip parent 1: prio 1 u32 match ip sport $P 0xffff flowid 1:4 || exit 4
  done
  echo "applied '$PROFILE' to $DEV ports [$PORTS]: netem[$NETEM] tbf[${TBF:-none}]" ;;

status)
  "$TC_BIN" qdisc show dev $DEV
  "$TC_BIN" -s qdisc show dev $DEV 2>/dev/null | grep -A2 netem || true ;;

verify)
  # measured TCP connect RTT through the shaped path (SYN out=dport, SYN/ACK back=sport)
  for i in 1 2 3; do curl -so /dev/null -w "%{time_connect}\n" --connect-timeout 5 "http://$BACKEND/" 2>/dev/null; done | \
    awk '{s+=$1; n++} END{if(n) printf "connect RTT mean over %d tries: %.1f ms\n", n, s/n*1000; else print "verify FAILED (backend unreachable)"}'
  "$TC_BIN" -s qdisc show dev $DEV 2>/dev/null | grep -A1 netem | head -4 ;;

*) echo "usage: impair.sh [--dry] apply <profile> | off | status | verify | list"; exit 2 ;;
esac
