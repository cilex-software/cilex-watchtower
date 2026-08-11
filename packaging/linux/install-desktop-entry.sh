#!/usr/bin/env bash
# Register Watchtower with the desktop shell so the dock shows the Cilex logo
# instead of a generic gear. Per-user, no root. Safe to re-run.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
exec_path="${1:-$here/build/watchtower}"
[ -x "$exec_path" ] || { echo "no executable at $exec_path" >&2; exit 1; }

icon_dir="$HOME/.local/share/icons/hicolor/512x512/apps"
app_dir="$HOME/.local/share/applications"
mkdir -p "$icon_dir" "$app_dir"

cp "$here/assets/images/cilex-logo.png" "$icon_dir/cilex-watchtower.png"
sed "s|__EXEC__|$exec_path|" "$here/packaging/linux/cilex-watchtower.desktop" \
    > "$app_dir/cilex-watchtower.desktop"
chmod 644 "$app_dir/cilex-watchtower.desktop"

command -v gtk-update-icon-cache >/dev/null && \
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
command -v update-desktop-database >/dev/null && \
    update-desktop-database "$app_dir" 2>/dev/null || true

echo "installed:"
echo "  $app_dir/cilex-watchtower.desktop  (Exec=$exec_path)"
echo "  $icon_dir/cilex-watchtower.png"
echo "Restart Watchtower to pick up the new app-id."
