#!/usr/bin/env bash
# Comparable-station connection collector (booth vs server room).
#
# Corrected from the Windows station agent's 2026-08-15 §6 listing, which could
# not run: it carried `\]` for a test bracket and `\'` inside command
# substitutions. Also adds guards the original lacked — see GUARDS below.
#
#   ./net-diag.sh <hours> [--label NAME] [--allow-loopback]
#   CV=100.107.51.72 ./net-diag.sh 6 --label booth
#
# GUARDS (each exists because its absence would produce a silently wrong file):
#   * refuses to start if `ss` cannot emit pid= — otherwise every connection
#     column fills with a confident 0
#   * refuses to start if the route to CV resolves to `lo`, unless
#     --allow-loopback — a NIC compared against loopback is not a comparison
#   * writes the header only once and flushes each row, so a killed run still
#     yields usable data
#
# Read-only: /proc, /sys, ss, ping. Nothing written to the fleet.
set -u

HOURS="${1:-6}"; shift || true
LABEL="$(hostname)"; ALLOW_LO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --allow-loopback) ALLOW_LO=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

CV="${CV:-192.168.1.79}"
IF="${IF:-$(ip route get "$CV" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)}"
[ -n "$IF" ] || { echo "cannot resolve interface to $CV" >&2; exit 1; }

if [ "$IF" = "lo" ] && [ "$ALLOW_LO" -eq 0 ]; then
  echo "route to $CV is loopback ($IF)." >&2
  echo "This station IS the server. rx/tx would measure loopback, which is not" >&2
  echo "comparable to a remote station's NIC. Re-run with --allow-loopback if" >&2
  echo "that is understood and intended." >&2
  exit 1
fi

# Assert ss can attribute sockets to a pid before trusting any count.
if ! ss -tnp 2>/dev/null | grep -q 'pid='; then
  echo "ss is not emitting pid= (needs iproute2 with -p support, and privileges" >&2
  echo "to see other users' sockets). Every connection column would read 0." >&2
  exit 1
fi

OUT="net-diag-${LABEL}.csv"
END=$(( $(date +%s) + HOURS * 3600 ))

rxb() { cat "/sys/class/net/$IF/statistics/rx_bytes"; }
txb() { cat "/sys/class/net/$IF/statistics/tx_bytes"; }
retx() { awk '/^Tcp:/{i++; if (i==2) print $13}' /proc/net/snmp; }   # TcpRetransSegs
outs() { awk '/^Tcp:/{i++; if (i==2) print $11}' /proc/net/snmp; }   # TcpOutSegs

[ -s "$OUT" ] || echo "ts,label,app_pid,app_rss_mb,est_cv,synsent,timewait,rx_mbps,tx_mbps,rtt_min,rtt_avg,rtt_max,loss_pct,retrans_delta,outseg_delta" > "$OUT"

PR=$(rxb); PT=$(txb); PX=$(retx); PO=$(outs)

while [ "$(date +%s)" -lt "$END" ]; do
  sleep 60

  PID=$(pgrep -x watchtower | head -1)
  RSS=0
  if [ -n "$PID" ] && [ -r "/proc/$PID/status" ]; then
    RSS=$(( $(awk '/VmRSS/{print $2}' "/proc/$PID/status") / 1024 ))
  fi

  if [ -n "$PID" ]; then
    EST=$(ss -tnp state established "dst $CV" 2>/dev/null | grep -c "pid=$PID,")
    SYN=$(ss -tnp state syn-sent 2>/dev/null | grep -c "pid=$PID,")
  else
    EST=0; SYN=0
  fi
  TW=$(ss -tn state time-wait "dst $CV" 2>/dev/null | tail -n +2 | wc -l)

  NR=$(rxb); NT=$(txb); NX=$(retx); NO=$(outs)
  RX=$(awk -v a="$NR" -v b="$PR" 'BEGIN{printf "%.3f",(a-b)*8/60/1000000}')
  TX=$(awk -v a="$NT" -v b="$PT" 'BEGIN{printf "%.3f",(a-b)*8/60/1000000}')
  DX=$(( NX - PX )); DO=$(( NO - PO ))
  PR=$NR; PT=$NT; PX=$NX; PO=$NO

  P=$(ping -n -c 5 -W 2 "$CV" 2>/dev/null)
  LOSS=$(echo "$P" | grep -oP '\d+(?=% packet loss)' | head -1); [ -n "$LOSS" ] || LOSS=100
  RTT=$(echo "$P" | awk -F'/' '/rtt|round-trip/{print $4","$5","$6}')
  [ -n "$RTT" ] || RTT="-1,-1,-1"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%F %T')" "$LABEL" "${PID:-0}" "$RSS" "$EST" "$SYN" "$TW" \
    "$RX" "$TX" "$RTT" "$LOSS" "$DX" "$DO" >> "$OUT"
done
