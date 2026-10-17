#!/usr/bin/env bash
# Throwaway diagnostic for the release launch check: mounts the disk image, starts the app the
# way scripts/check-launch.sh release does, and records what happens second by second instead of
# looking once after 15 s.
set -uo pipefail

dmg="${1:?usage: diag-launch.sh <dmg>}"
seclevel() { while IFS= read -r line; do printf '%s %s\n' "$(date +%H:%M:%S)" "$line"; done; }

mount="$(mktemp -d "${TMPDIR:-/tmp}/lists-diag-XXXXXX")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg" || { echo "diag: cannot mount $dmg"; exit 1; }
trap 'pkill -f "/Lists.app/Contents/MacOS/Lists$" || true; hdiutil detach -quiet -force "$mount" || true; rmdir "$mount"' EXIT
app="$mount/Lists.app"
binary="$app/Contents/MacOS/Lists"
echo "diag: app=$app"
ls -l "$binary" | seclevel
codesign -dv "$app" 2>&1 | seclevel

work="$(mktemp -d "${TMPDIR:-/tmp}/lists-diag-run-XXXXXX")"
log="$work/out.log"; err="$work/err.log"
: > "$log"; : > "$err"

echo "diag: launching with open -g -j -n" | seclevel
start=$(date +%s)
open -g -j -n --stdout "$log" --stderr "$err" "$app"
echo "diag: open exit=$?" | seclevel

seen=0
for i in $(seq 1 90); do
    sleep 1
    now=$(( $(date +%s) - start ))
    # Every process of the app: the exact binary, and anything else that carries the name.
    exact=$(pgrep -f "^$binary$" | tr '\n' ' ')
    any=$(pgrep -fl "Lists" | grep -v pgrep | tr '\n' '|' )
    if [ -n "$exact" ] && [ "$seen" -eq 0 ]; then
        seen=$now
        echo "diag: the app process appeared ${now}s after open (pids: $exact)" | seclevel
    fi
    if [ -z "$exact" ] && [ "$seen" -ne 0 ]; then
        echo "diag: the app process was gone ${now}s after open" | seclevel
        break
    fi
    if [ "$i" -le 20 ] || [ $((i % 10)) -eq 0 ]; then
        echo "diag: t=${now}s exact='${exact}' others='${any}'" | seclevel
    fi
    if [ "$seen" -eq 0 ] && [ "$now" -ge 60 ]; then
        echo "diag: no app process 60 s after open" | seclevel
        break
    fi
done

if [ "$seen" -ne 0 ] && pgrep -f "^$binary$" >/dev/null; then
    echo "diag: the app is running $(( $(date +%s) - start ))s after open" | seclevel
    ps -axo pid,ppid,stat,etime,command | grep -i "Lists" | grep -v grep | seclevel
    sleep 10
    if pgrep -f "^$binary$" >/dev/null; then
        echo "diag: still running 10 s later" | seclevel
    else
        echo "diag: it quit within 10 s of being seen" | seclevel
    fi
fi

echo "diag: stdout:" | seclevel; cat "$log" 2>/dev/null | seclevel
echo "diag: stderr:" | seclevel; cat "$err" 2>/dev/null | seclevel
echo "diag: crash reports:" | seclevel
ls -la ~/Library/Logs/DiagnosticReports 2>/dev/null | seclevel
for f in ~/Library/Logs/DiagnosticReports/*Lists*; do
    [ -e "$f" ] || continue
    echo "diag: --- $f" | seclevel
    head -60 "$f" | seclevel
done
echo "diag: unified log for the app:" | seclevel
log show --last 5m --style compact --predicate 'process CONTAINS "Lists" OR eventMessage CONTAINS "org.evsyukov.lists"' 2>/dev/null | tail -80 | seclevel
echo "diag: done" | seclevel
