#!/usr/bin/env bash
# Starts a built Lists.app and fails when the launch does not go well.
#
#   scripts/check-launch.sh <path to Lists.app> debug     # a Debug build, as `make apple` makes
#   scripts/check-launch.sh <path to Lists.app> release   # a Release build, as scripts/release-macos.sh makes
#
# debug: the helper of quick entry is switched on, so that the launch reads its state from the
# system, and the app is started with the launch probe (LISTS_DEBUG_LAUNCH_PROBE): a launch that
# runs the event loop while the model is built stops the app, as 0.3.1 did. The run has a data
# folder of its own and the debug agent of the helper, which is switched off at the end.
#
# release: the app is started as it is and must still be running after a while. A Release build
# has no debug script and no probe, and it uses the data folder and the notifications of the
# account it runs under: meant for a build machine, not for a Mac with Lists installed.
set -euo pipefail

app="${1:?usage: check-launch.sh <Lists.app> debug|release}"
mode="${2:?usage: check-launch.sh <Lists.app> debug|release}"
app="$(cd "$app" && pwd)"
binary="$app/Contents/MacOS/Lists"
[ -x "$binary" ] || { echo "launch: no app at $app" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/lists-launch-XXXXXX")"
log="$work/out.log"

running() { pgrep -f "^$binary\$" >/dev/null; }

# Starts the app hidden with the given steps of the debug script and waits until it has quit.
run() {
    local steps="$1"
    shift
    : > "$log"
    open -g -j -n --env "LISTS_DEBUG_DIR=$work/data" --env LISTS_DEBUG_QUIET=1 "$@" \
        --env "LISTS_DEBUG_SCRIPT=$steps" --stdout "$log" --stderr "$work/err.log" "$app"
    local waited=0
    while [ "$waited" -lt 60 ]; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -gt 2 ] && ! running; then return 0; fi
    done
    echo "launch: the app did not quit within a minute" >&2
    pkill -f "^$binary\$" || true
    return 1
}

case "$mode" in
debug)
    mkdir -p "$work/data"
    cleanup() { run "loginitems:helper=off;quit" >/dev/null 2>&1 || true; rm -rf "$work"; }
    trap cleanup EXIT
    run "loginitems:helper=on;sleep:1;loginitems;quit"
    grep -q "helper on" "$log" || { echo "launch: the helper could not be switched on:" >&2; cat "$log" >&2; exit 1; }
    run "apphidden;quit" --env LISTS_DEBUG_LAUNCH_PROBE=1 || true
    if grep -q "debug: launch probe ran after the model was built" "$log" && grep -q "debug: app " "$log"; then
        echo "launch: the probe passed"
    else
        echo "launch: the app stopped at launch, or the probe did not run. Output:" >&2
        cat "$log" "$work/err.log" >&2 || true
        exit 1
    fi
    ;;
release)
    trap 'pkill -f "^$binary\$" || true; rm -rf "$work"' EXIT
    open -g -j -n --stdout "$log" --stderr "$work/err.log" "$app"
    sleep 15
    if running; then
        echo "launch: the app is running 15 s after its start"
    else
        echo "launch: the app is not running 15 s after its start. Output:" >&2
        cat "$log" "$work/err.log" >&2 || true
        exit 1
    fi
    ;;
*)
    echo "launch: the mode is debug or release" >&2
    exit 2
    ;;
esac
