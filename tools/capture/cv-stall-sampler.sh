#!/bin/bash
# cv-stall-sampler — the SERVER half of the standing capture (A4, 2026-09-25).
# Proposed to cilex-vision; runs on the pilot box, owned and operated by CV.
#
# READ-ONLY. One SELECT on pg_stat_activity per second over ONE persistent psql
# connection (psql's \watch — not 86,400 new backends a day), /proc reads, and a
# localhost GET /health. No writes, no config change, no extension, no restart.
#
# Why each stream exists — the two readings the 2026-09-22 111 s stall left alive:
#   db     every non-idle backend grouped by state + wait event, with the oldest
#          query's age: pool exhaustion / lock / IO queueing is reading (2)
#   host   runnable + blocked processes, iowait, loadavg: the box itself
#   local  GET /health from localhost: if THIS stays fast while the client's
#          keep-alive probe stalls, the server is fine and the path is not (reading 1)
#
# Usage:   PSQL='docker exec -i <pg-container> psql -U <user> -d <db>' ./cv-stall-sampler.sh
# Env:     OUT (/var/log/cv-sampler)  KEEP_DAYS (14)  API (http://127.0.0.1:8000/health)
# Stop:    kill the process group, or: pkill -f cv-stall-sampler
# Output:  $OUT/{db,host,local}-YYYYMMDD.log, UTC, one line per second per stream.
set -u
: "${PSQL:?set PSQL to a psql invocation that reaches the application database}"
OUT="${OUT:-/var/log/cv-sampler}"; KEEP_DAYS="${KEEP_DAYS:-14}"
API="${API:-http://127.0.0.1:8000/health}"
mkdir -p "$OUT"
day() { date -u +%Y%m%d; }
utc() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

# db: \watch 1 re-runs the query every second on the SAME connection. now() is the
# server's clock, so each row is self-timestamped. One row per (state, wait) group.
db_stream() {
  # $PSQL is deliberately UNQUOTED: it is a whole command line ("docker exec -i … psql …")
  # and must word-split. Quoted, it would be looked up as one program name and fail.
  # shellcheck disable=SC2086
  $PSQL -XAt -F' ' -v ON_ERROR_STOP=0 <<'SQL' | while IFS= read -r l; do printf '%s\n' "$l" >> "$OUT/db-$(day).log"; done
SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
       coalesce(state,'-'), coalesce(wait_event_type,'-'), coalesce(wait_event,'-'),
       coalesce(application_name,'-'), count(*),
       coalesce(round(max(extract(epoch FROM clock_timestamp()-query_start))*1000)::bigint,0) AS oldest_ms,
       coalesce(round(max(extract(epoch FROM clock_timestamp()-xact_start))*1000)::bigint,0)  AS oldest_xact_ms
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid()
GROUP BY 2,3,4,5 ORDER BY 2,3,4,5
\watch 1
SQL
}

host_stream() {
  local prev_cpu; read -r _ u n s i w q sq st _ < /proc/stat; prev_cpu="$u $n $s $i $w $q $sq $st"
  while :; do
    sleep 1
    read -r _ u n s i w q sq st _ < /proc/stat
    set -- $prev_cpu; local du=$(( (u+n+s+q+sq+st) - ($1+$2+$3+$6+$7+$8) )) di=$(( i-$4 )) dw=$(( w-$5 ))
    local tot=$(( du+di+dw )); [ "$tot" -gt 0 ] || tot=1
    prev_cpu="$u $n $s $i $w $q $sq $st"
    printf '%s busy=%d%% iowait=%d%% %s %s\n' "$(utc)" $(( 100*du/tot )) $(( 100*dw/tot )) \
      "$(awk '{print "load="$1" run/total="$4}' /proc/loadavg)" \
      "$(awk '/^procs_running/{r=$2} /^procs_blocked/{b=$2} END{print "running="r" blocked="b}' /proc/stat)" \
      >> "$OUT/host-$(day).log"
  done
}

local_stream() {
  while :; do
    local t0; t0=$(date +%s%N)
    local r; r=$(curl -sS -m 10 -o /dev/null -w '%{http_code} connect=%{time_connect}' "$API" 2>&1 | tr -d '\n')
    printf '%s ms=%d %s\n' "$(utc)" $(( ($(date +%s%N)-t0)/1000000 )) "$r" >> "$OUT/local-$(day).log"
    sleep 1   # plain: a stalled curl stretching the interval is itself the signal
  done
}

prune() { while :; do find "$OUT" -name '*.log' -mtime +"$KEEP_DAYS" -delete; sleep 3600; done; }

echo "$(utc) cv-stall-sampler start pid=$$ out=$OUT keep_days=$KEEP_DAYS api=$API" >> "$OUT/host-$(day).log"
db_stream & host_stream & local_stream & prune &
wait
