#!/usr/bin/env bash
# Sourced by application build entry points; never installs or launches the app.
cilex_build_prepare() {
    local profile="$1" repository="$2"
    shift 2
    CILEX_BUILD_PYTHON=$(command -v python3) || { echo 'Python 3 is required for the build check.' >&2; return 1; }
    CILEX_BUILD_GUARD="$repository/packaging/build_state.py"
    CILEX_BUILD_PLAN=$(mktemp -t cilex-build-plan.XXXXXX)
    trap 'rm -f "$CILEX_BUILD_PLAN"' EXIT
    "$CILEX_BUILD_PYTHON" -I -B "$CILEX_BUILD_GUARD" prepare --repository "$repository" --profile "$profile" --plan "$CILEX_BUILD_PLAN" "$@" || return
    CILEX_BUILD_ENABLED=$("$CILEX_BUILD_PYTHON" -I -B "$CILEX_BUILD_GUARD" value --plan "$CILEX_BUILD_PLAN" --field build)
    CILEX_BUILD_SOURCE=$("$CILEX_BUILD_PYTHON" -I -B "$CILEX_BUILD_GUARD" value --plan "$CILEX_BUILD_PLAN" --field source)
    CILEX_BUILD_COMMIT=$("$CILEX_BUILD_PYTHON" -I -B "$CILEX_BUILD_GUARD" value --plan "$CILEX_BUILD_PLAN" --field commit)
}

cilex_build_record() {
    "$CILEX_BUILD_PYTHON" -I -B "$CILEX_BUILD_GUARD" record --plan "$CILEX_BUILD_PLAN" "$@"
}
