#!/usr/bin/env bash
# wt-warden user-level install (CW-07). No sudo needed; run setup-root.sh once
# separately for kernel core dumps (optional — Warden works core-less without it).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIB="$HOME/.local/lib/watchtower-warden"
CONF="$HOME/.config/watchtower-warden/warden.conf"
UNIT="$HOME/.config/systemd/user/wt-warden.service"

mkdir -p "$LIB" "$(dirname "$CONF")" "$(dirname "$UNIT")"
install -m 0755 "$HERE/warden.py" "$LIB/warden.py"
install -m 0644 "$HERE/wt-warden.service" "$UNIT"
if [ ! -f "$CONF" ]; then
    install -m 0600 "$HERE/warden.conf.example" "$CONF"
    echo "NOTE: edit $CONF — set STATION_TOKEN and APP_CMD before enabling."
fi

systemctl --user daemon-reload
echo "Installed. Enable with:  systemctl --user enable --now wt-warden"
echo "Kiosk boxes: also 'loginctl enable-linger $USER' so the unit starts at boot."
