#!/bin/bash
set -eu
umask 077
HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf '%s\n' 'Run this command on a Mac.' >&2
    exit 1
fi
for PYTHON in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$PYTHON" ]; then exec "$PYTHON" -I -B "$HERE/easy.py" "$@"; fi
done
DEVELOPER=$(/usr/bin/xcode-select -p 2>/dev/null || true)
if [ -n "$DEVELOPER" ] && [ -d "$DEVELOPER" ] && [ -x /usr/bin/python3 ]; then
    exec /usr/bin/python3 -I -B "$HERE/easy.py" "$@"
fi
printf '%s\n' 'Apple command line tools are missing. Run xcode-select --install in Terminal, finish the Apple installer, then try again.' >&2
exit 1
