#!/bin/bash
# Invoked only by one Git authentication operation. No credential is stored.
case "$1" in
  *Username*|*username*) printf '%s\n' 'x-access-token' ;;
  *Password*|*password*)
    case "${CILEX_GH_TOKEN_FD:-}" in ''|*[!0-9]*) exit 1 ;; esac
    IFS= read -r credential <&"$CILEX_GH_TOKEN_FD" || exit 1
    printf '%s\n' "$credential"
    unset credential
    ;;
  *) exit 1 ;;
esac
