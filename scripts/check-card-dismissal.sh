#!/usr/bin/env bash
# R44 (#466). Dispatch mouse events in a transparent, non-activating Debug app.
set -euo pipefail

app="$(cd "${1:?usage: check-card-dismissal.sh <Debug Lists.app>}" && pwd -P)"
binary="$app/Contents/MacOS/Lists"
running() {
    ps -Ao pid=,comm= | awk -v binary="$binary" '{ pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == binary) print pid }'
}
if [[ -n "$(running)" ]]; then
    echo "R44: the app at $app is already running" >&2
    exit 1
fi

work="$(mktemp -d -t lists-r44)"
cleanup() {
    local pid
    pid="$(running)"
    if [[ -n "$pid" ]]; then kill "$pid"; fi
    find "$work" \( -type f -o -type l \) -exec unlink {} \;
    find "$work" -depth -type d -exec rmdir {} \;
}
trap cleanup EXIT

steps='ghost;newtask;title:beta;finish;newtask;title:alpha;finish;inbox'
steps+=';pick:alpha;edit;sleep:0.4;type: revised;click:view-title;sleep:0.4;cards;state'
steps+=';edit;sleep:0.4;key:tab;type:note kept;click:titlebar;sleep:0.4;cards;state'
steps+=';edit;sleep:0.4;notes;click:sidebar-empty;cards;state'
steps+=';pick:beta;edit;sleep:0.4;click:sidebar-heading;sidebarrows;cards;state'
steps+=';edit;sleep:0.4;click:card-title;cards;click:task:alpha revised;cards'
steps+=';edit;sleep:0.4;click:task-empty;cards;state;quit'

open -g -j -n --env "LISTS_DEBUG_DIR=$work/data" --env LISTS_DEBUG_QUIET=1 \
    --env "LISTS_DEBUG_SCRIPT=$steps" --stdout "$work/out" --stderr "$work/err" "$app"
for (( waited = 0; waited < 45; waited++ )); do
    sleep 1
    if [[ $waited -ge 2 && -z "$(running)" ]]; then break; fi
done

printf '%s\n' \
    'debug: open [], selected alpha revised, draft false' TaskTableView \
    'debug: open [], selected alpha revised, draft false' TaskTableView \
    'debug: open [], selected alpha revised, draft false' 'SidebarTableView (sidebar)' \
    'debug: open [], selected beta, draft false' 'SidebarTableView (sidebar)' \
    'debug: open ["beta"], selected beta, draft false' \
    'debug: open [], selected alpha revised, draft false' \
    'debug: open [], selected none, draft false' TaskTableView > "$work/expected"

if [[ -n "$(running)" ]] || ! diff -u "$work/expected" <(
    sed -n -e '/^debug: open /p' -e 's/^debug: key window .*first responder //p' "$work/out"
) || ! grep -Fq 'text "note kept"' "$work/out" || ! grep -Fq ' ▸]' "$work/out"; then
    echo "R44: card dismissal check failed" >&2
    cat "$work/out" "$work/err" >&2
    exit 1
fi
echo "R44: card dismissal check passed"
