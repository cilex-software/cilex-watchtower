#!/bin/bash
# macOS bootstrap: compatible with Apple's Bash 3.2; no Homebrew/Python required
# for the initial assessment. This entry never publishes source or releases.
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
mode=check
language=auto
dry_run=0
python_path=
use_agent=0
previous=
for argument in "$@"; do
    case "$previous" in
        --mode) mode=$argument ;;
        --language) language=$argument ;;
        --python) python_path=$argument ;;
        --dry-run) if [ "$argument" = yes ]; then dry_run=1; fi ;;
        --ssh-use-agent|--ssh-agent) if [ "$argument" = yes ]; then use_agent=1; fi ;;
    esac
    previous=$argument
done
if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf '%s\n' 'This bootstrap requires macOS. No changes were made.' >&2
    exit 10
fi
case "$language" in auto|en|ru) ;; *) printf '%s\n' '--language must be auto, en or ru.' >&2; exit 2 ;; esac
# Bundles include this frozen helper so clean targets need no Python or tools.
if [ -x "$SCRIPT_DIR/Setup.app/Contents/MacOS/cilex-setup" ]; then
    minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SCRIPT_DIR/Setup.app/Contents/Info.plist" 2>/dev/null || true)
    current=$(/usr/bin/sw_vers -productVersion)
    # Stock awk compares numeric components; never execute an incompatible helper.
    if [ -z "$minimum" ] || ! /usr/bin/awk -v have="$current" -v need="$minimum" 'BEGIN { split(have,h,"."); split(need,n,"."); for(i=1;i<=3;i++){ if(h[i]+0>n[i]+0)exit 0; if(h[i]+0<n[i]+0)exit 1;} exit 0 }'; then
        printf '%s\n' "Package runtime requires macOS ${minimum:-unknown}; this Mac has $current. No installation started." >&2
        exit 10
    fi
    if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ] || [ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
        printf '%s\n' 'Native arm64 is required / Требуется arm64 без Rosetta.' >&2
        exit 10
    fi
    agent_socket=
    if [ "$use_agent" = 1 ]; then agent_socket=${SSH_AUTH_SOCK:-}; fi
    # A CLI with no arguments assesses. Finder alone opens the setup dialog.
    if [ "$#" = 0 ]; then set -- --mode check; fi
    exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR=/tmp \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 CILEX_INIT_SSH_AUTH_SOCK="$agent_socket" \
        "$SCRIPT_DIR/Setup.app/Contents/MacOS/cilex-setup" "$@"
fi
# Never call Apple's developer-tool stubs without an installed selected toolchain.
if [ -z "$python_path" ]; then
    developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    if [ -n "$developer_dir" ] && [ -d "$developer_dir" ] && [ -x /usr/bin/python3 ]; then
        python_path=/usr/bin/python3
    fi
fi
if [ -z "$python_path" ]; then
    /usr/bin/osascript -l JavaScript "$SCRIPT_DIR/generic/bootstrap-check.js" "$mode" "$language" "$dry_run"
    # Even an inspection must report that the requested deep assessment is incomplete.
    exit 11
fi
case "$python_path" in /*) ;; *) printf '%s\n' '--python must be an absolute executable path.' >&2; exit 2 ;; esac
[ -x "$python_path" ] || { printf '%s\n' 'The selected Python executable is missing. Use the versioned bootstrap bundle on a clean Mac.' >&2; exit 11; }
agent_socket=
if [ "$use_agent" = 1 ]; then agent_socket=${SSH_AUTH_SOCK:-}; fi
# -I ignores user site/PYTHONPATH; deploy.py adds only its own frozen module root.
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR=/tmp \
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 CILEX_INIT_SSH_AUTH_SOCK="$agent_socket" \
    "$python_path" -I -B "$SCRIPT_DIR/generic/deploy.py" "$@"
