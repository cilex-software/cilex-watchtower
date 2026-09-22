#!/usr/bin/env bash
# Capture the pilot host WHILE an API stall is happening, at 1 Hz.
#
# WHY. On 2026-09-22 the API answered nothing for 111 s while go2rtc on the same
# host kept serving video. cilex-vision found the mechanism from source: /events
# takes TWO sequential DB commands, each bounded by command_timeout=30 s, but
# `pool.acquire()` is called with NO timeout (utils/db.py) against max_size=10, so
# asyncpg waits indefinitely — twice — and nothing counts or caps that wait. All
# three of us reasoned about it from source AFTER the fact. Nobody measured it
# happening. This does.
#
# Run it from the pilot host (the Linux dev box) the moment a reproduction starts:
#   tools/pilot-stall-capture.sh 300        # seconds, default 180
#
# WHAT IT SAMPLES, and why each one is here:
#
#  1. query_db_latency_ms {count,sum} per query_type, from :8000/metrics.
#     THE ACQUIRE WAIT IS ALREADY IN THIS HISTOGRAM: utils/db.py starts t0 BEFORE
#     `async with pool.acquire()`, so the timer covers queue + query. A stall shows
#     as _count rising while the le<=1000 buckets do not, and the magnitude comes
#     from the _sum delta. Caveat: the top finite bucket is le=1000.0, so anything
#     over a second is just "+Inf" — the sum is what carries the size.
#
#  2. pg_stat_activity per client: total, active, wait_event_type, and the OLDEST
#     state_change. cilex-vision's point: a queue on acquire shows up as
#     connections PINNED with an old state_change, not as a high total.
#
#  3. Host pressure: load, MemAvailable, and pswpin/pswpout deltas from /proc.
#     sar only samples every 10 minutes, which is useless against a 111 s event.
#
# WHAT IT CANNOT SEE, stated so the output is not over-read. A task waiting inside
# asyncpg's `pool.acquire()` HOLDS NO BACKEND — it is an asyncio waiter, not a
# connection — so the queue DEPTH is invisible to pg_stat_activity by construction.
# This captures the queue's CAUSE (connections pinned) and its EFFECT (latency in
# the histogram). Depth itself needs in-process telemetry that does not exist today
# (no pool.get_size()/get_idle_size() anywhere in query-api, checked 2026-09-22).
#
# Read-only throughout: one unauthenticated GET, one SELECT on pg_stat_activity,
# and /proc. Writes nothing to the pilot.
set -uo pipefail
SECS="${1:-180}"
OUT="${2:-/tmp/pilot-stall-$(date +%Y%m%d-%H%M%S).tsv}"
API="${WT_CV_URL:-http://127.0.0.1:8000}"

PGU=$(docker exec timescaledb printenv POSTGRES_USER 2>/dev/null || echo cilex)
PGD=$(docker exec timescaledb printenv POSTGRES_DB   2>/dev/null || echo vidanalytics)

printf 'ts\tsource\tkey\tvalue\n' > "$OUT"
echo "capturing ${SECS}s -> $OUT   (api=$API db=$PGU/$PGD)"

emit() { printf '%s\t%s\t%s\t%s\n' "$(date -u +%H:%M:%S)" "$1" "$2" "$3" >> "$OUT"; }

END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
    # 1. DB latency histogram — count and sum per query_type (acquire wait included)
    # Default FS, label pulled by regex. An earlier version split on [{}" ]+ and
    # tested for a field equal to "query_type" — but that split leaves the field as
    # `query_type=`, so the test never matched and EVERY series was emitted with an
    # empty label, silently collapsing all query types into one line. Caught in the
    # smoke output, which is the only reason it is not still there.
    curl -s -m 2 -L "$API/metrics" 2>/dev/null \
      | awk '/^query_db_latency_ms_(count|sum)\{/ {
            t = $0; sub(/.*query_type="/, "", t); sub(/".*/, "", t);
            k = ($0 ~ /^query_db_latency_ms_count/) ? "count" : "sum";
            print t "." k "\t" $NF }' \
      | while IFS=$'\t' read -r k v; do emit metrics "$k" "$v"; done

    # 2. Connections: totals, and the oldest state_change per client. A queue on
    #    acquire pins existing connections; it does not add new ones.
    docker exec timescaledb psql -U "$PGU" -d "$PGD" -t -A -F'|' -c \
      "select coalesce(host(client_addr),'local'),
              count(*), count(*) filter (where state='active'),
              count(*) filter (where wait_event_type='Client'),
              round(extract(epoch from now()-min(state_change))::numeric,1)
       from pg_stat_activity where backend_type='client backend' group by 1;" 2>/dev/null \
      | while IFS='|' read -r c tot act cli oldest; do
            [ -n "$c" ] || continue
            emit pg "$c.total" "$tot"; emit pg "$c.active" "$act"
            emit pg "$c.wait_client" "$cli"; emit pg "$c.oldest_state_change_s" "$oldest"
        done

    # 3. Host pressure at 1 Hz — sar's 10-minute average cannot see a 111 s event
    emit host load1 "$(awk '{print $1}' /proc/loadavg)"
    emit host mem_available_kb "$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
    emit host pswpin_total  "$(awk '/^pswpin/{print $2}'  /proc/vmstat)"
    emit host pswpout_total "$(awk '/^pswpout/{print $2}' /proc/vmstat)"
    sleep 1
done
echo "done: $OUT  ($(wc -l < "$OUT") rows)"
