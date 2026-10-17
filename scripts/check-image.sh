#!/usr/bin/env bash
# Starts a built image of lists-web as compose.yaml runs it and fails when it does not work.
#
#   scripts/check-image.sh <image>
#
# The container runs with a read-only root filesystem, no capabilities and no-new-privileges.
# It must report itself healthy (R144), and a file must upload to a task: the upload is written
# to a temporary file first, which the image keeps on the data volume (#334).
set -euo pipefail

image="${1:?usage: check-image.sh <image>}"
name="lists-check-$$"
port=18080
password=check

docker run -d --name "$name" -p "127.0.0.1:$port:8080" -e "LISTS_WEB_PASSWORD=$password" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true "$image" >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT

fail() {
    echo "image: $1. Log:" >&2
    docker logs "$name" >&2 || true
    exit 1
}

status=starting
for _ in $(seq 1 30); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$name")"
    [ "$status" = starting ] || break
    sleep 2
done
[ "$status" = healthy ] || fail "the container is $status, not healthy"

base="http://127.0.0.1:$port"
cookie="$(curl -fsS -i -X POST -H 'X-Lists: 1' -H 'Content-Type: application/json' \
    -d "{\"password\":\"$password\"}" "$base/api/login" | sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p')"
[ -n "$cookie" ] || fail "no session after the login"
api() { curl -sS -H 'X-Lists: 1' -H "Cookie: $cookie" "$@"; }
task="$(api -X POST -H 'Content-Type: application/json' -d '{"op":"quickAdd","text":"image check"}' \
    "$base/api/call" | jq -r '.id // empty')"
[ -n "$task" ] || fail "no task was added"
uploaded="$(api -X POST --data-binary 'image check' "$base/api/upload?task=$task&name=check.txt")"
[[ "$uploaded" == *'"name":"check.txt"'* ]] || fail "the upload failed: $uploaded"
echo "image: healthy, and a file uploads: $image"
