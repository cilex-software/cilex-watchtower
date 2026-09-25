#!/bin/bash
# Standing capture on a macOS client (A4, 2026-09-25) — the CLIENT half of "catch the
# next API stall from both sides". The server half is a request to CV (docs/letters).
#
#   tools/capture/install-macos.sh            install / refresh (idempotent)
#   tools/capture/install-macos.sh --status   what is running, where it writes
#   tools/capture/install-macos.sh --uninstall remove both agents and the env
#
# Installs two per-user LaunchAgents (no sudo, nothing outside ~/Library):
#   com.cilex.watchtower.netprobe   tools/capture/netprobe.py, KeepAlive — the
#                                   app-independent 1 Hz keep/fresh probe + Tailscale path
#   com.cilex.watchtower.traceenv   at every login: launchctl setenv WT_TRACE=1 and the
#                                   flight-recorder sizing, so Watchtower launched from
#                                   the Dock/Finder/open traces without anyone remembering
#
# Flight-recorder sizing: WT_TRACE measured 2026-09-25 at 549 B/s ≈ 47 MB/day over the
# first 103 s after launch (startup-weighted, so an upper bound). 20 MB x 10 = 200 MB
# holds >= 4 days of it: a stall noticed the next morning is still on disk.
# The recorder itself is the app's (src/models/FlightRecorder.h) — it tees EVERY Qt log
# line, crash-durable, to ~/Library/Application Support/Cilex Vision/Watchtower/flightrec.
set -euo pipefail

LABEL_PROBE=com.cilex.watchtower.netprobe
LABEL_ENV=com.cilex.watchtower.traceenv
AGENTS="$HOME/Library/LaunchAgents"
HOME_DIR="$HOME/Library/Application Support/Cilex Vision/capture"
LOG_DIR="$HOME/Library/Logs/watchtower-capture"
SRC="$(cd "$(dirname "$0")" && pwd)/netprobe.py"
DOMAIN="gui/$(id -u)"
FR_BYTES="${WT_CAPTURE_FLIGHTREC_BYTES:-20971520}"
FR_KEEP="${WT_CAPTURE_FLIGHTREC_KEEP:-10}"
ENV_VARS=(WT_TRACE WT_FLIGHTREC_BYTES WT_FLIGHTREC_KEEP)

status() {
  for l in "$LABEL_PROBE" "$LABEL_ENV"; do
    if launchctl print "$DOMAIN/$l" >/dev/null 2>&1; then
      printf '  %-32s loaded  %s\n' "$l" "$(launchctl print "$DOMAIN/$l" | awk -F'= ' '/^\tstate =/{print "state="$2} /^\tpid =/{print "pid="$2}' | tr '\n' ' ')"
    else
      printf '  %-32s NOT loaded\n' "$l"
    fi
  done
  for v in "${ENV_VARS[@]}"; do printf '  launchctl env %-20s = %s\n' "$v" "$(launchctl getenv "$v" || true)"; done
  echo "  probe log: $LOG_DIR/$(ls -t "$LOG_DIR" 2>/dev/null | grep -m1 '^netprobe-.*\.log$' || echo '(none yet)')"
  echo "  flightrec: $HOME/Library/Application Support/Cilex Vision/Watchtower/flightrec/"
}

unload() {
  for l in "$LABEL_PROBE" "$LABEL_ENV"; do
    launchctl bootout "$DOMAIN/$l" 2>/dev/null || true
  done
}

case "${1:-}" in
  --status) status; exit 0 ;;
  --uninstall)
    unload
    rm -f "$AGENTS/$LABEL_PROBE.plist" "$AGENTS/$LABEL_ENV.plist"
    for v in "${ENV_VARS[@]}"; do launchctl unsetenv "$v" || true; done
    echo "  removed both agents and unset ${ENV_VARS[*]}"
    echo "  logs kept: $LOG_DIR (delete by hand if unwanted)"
    echo "  a Watchtower ALREADY running keeps WT_TRACE until it is restarted"
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--status|--uninstall]" >&2; exit 2 ;;
esac

mkdir -p "$AGENTS" "$HOME_DIR" "$LOG_DIR"
# Copy, do not run from the checkout: a branch switch must not change what launchd runs.
install -m 0755 "$SRC" "$HOME_DIR/netprobe.py"

cat > "$AGENTS/$LABEL_PROBE.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_PROBE</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>$HOME_DIR/netprobe.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/netprobe.launchd.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/netprobe.launchd.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>WT_PROBE_DIR</key><string>$LOG_DIR</string></dict>
</dict>
</plist>
PLIST

cat > "$AGENTS/$LABEL_ENV.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_ENV</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>launchctl setenv WT_TRACE 1; launchctl setenv WT_FLIGHTREC_BYTES $FR_BYTES; launchctl setenv WT_FLIGHTREC_KEEP $FR_KEEP</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

plutil -lint -s "$AGENTS/$LABEL_PROBE.plist" "$AGENTS/$LABEL_ENV.plist"
unload
launchctl bootstrap "$DOMAIN" "$AGENTS/$LABEL_ENV.plist"
launchctl bootstrap "$DOMAIN" "$AGENTS/$LABEL_PROBE.plist"
echo "  installed. status:"
status
