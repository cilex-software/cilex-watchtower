#!/bin/bash
# Install the newest built DMG on this Mac, or select one with --installer PATH.
set -eu
umask 077
HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
exec "$HERE/generic/run-simple.sh" install-local "$@"
