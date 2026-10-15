#!/bin/bash
# Run from an authorized source checkout. Passwords are entered at SSH's prompt.
set -eu
umask 077
HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
exec "$HERE/generic/run-simple.sh" install-remote "$@"
