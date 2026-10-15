#!/bin/bash
# Build an unsigned internal DMG for Apple silicon. No arguments are required.
set -eu
umask 077
HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
exec "$HERE/generic/run-simple.sh" build-installer "$@"
