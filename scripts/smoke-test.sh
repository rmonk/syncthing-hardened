#!/usr/bin/env bash
# Start two instances of the image on a private network and sync a file between them:
#   A: the way futomaki runs it (user 22000, no capabilities, no-new-privileges, read-only root)
#   B: upstream's default (starts as root, entrypoint drops to PUID/PGID with su-exec)
# Checks: version, health endpoint, both run as the expected uid, A and B pair over TCP with
# discovery/relays/NAT off, a file written on A arrives on B with the same content, and a
# restart of A keeps its device ID.
#
# Usage: scripts/smoke-test.sh <image>      (DOCKER=podman to use podman; needs jq)
set -euo pipefail
trap 'echo "smoke: FAIL command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

image="${1:?usage: smoke-test.sh <image>}"
docker="${DOCKER:-docker}"
root="$(cd "$(dirname "$0")/.." && pwd)"
want_version="$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")"
tag="st-smoke-$$"
net="$tag-net"
key="smoke$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then
    for c in a b; do echo "--- logs $c ---"; $docker logs --tail 40 "$tag-$c" 2>&1 || true; done
  fi
  $docker rm -f "$tag-a" "$tag-b" >/dev/null 2>&1 || true
  $docker volume rm -f "$tag-a-home" "$tag-b-home" >/dev/null 2>&1 || true
  $docker network rm "$net" >/dev/null 2>&1 || true
  exit $rc
}
trap cleanup EXIT

api() {  # api <a|b> <method> <path> [json]  -> body; fails on HTTP >= 400
  local c="$tag-$1" m="$2" p="$3" body="${4:-}"
  if [ -n "$body" ]; then
    $docker exec "$c" curl -fsS -X "$m" -H "X-API-Key: $key" -H 'Content-Type: application/json' -d "$body" "http://127.0.0.1:8384$p"
  else
    $docker exec "$c" curl -fsS -X "$m" -H "X-API-Key: $key" "http://127.0.0.1:8384$p"
  fi
}

wait_health() {
  for _ in $(seq 60); do
    $docker exec "$tag-$1" curl -fsS -m 2 http://127.0.0.1:8384/rest/noauth/health 2>/dev/null | grep -q OK && return 0
    sleep 1
  done
  echo "smoke: FAIL $1 health endpoint not OK"; return 1
}

$docker network create "$net" >/dev/null
# A's home volume must belong to 22000 (on futomaki the volumes are chowned once).
$docker volume create "$tag-a-home" >/dev/null
$docker run --rm -v "$tag-a-home:/var/syncthing" --entrypoint chown "$image" 22000:22000 /var/syncthing

start_a() {
  $docker run -d --name "$tag-a" --network "$net" --network-alias st-a \
    --user 22000:22000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
    -e STGUIAPIKEY="$key" -v "$tag-a-home:/var/syncthing" "$image" >/dev/null
}
start_a
$docker run -d --name "$tag-b" --network "$net" --network-alias st-b \
  -e STGUIAPIKEY="$key" -v "$tag-b-home:/var/syncthing" "$image" >/dev/null
wait_health a; wait_health b

version="$($docker exec "$tag-a" syncthing --version)"
grep -qF "syncthing $want_version " <<<"$version" || { echo "smoke: FAIL version '$version', expected $want_version"; exit 1; }
grep -q "modernc-sqlite" <<<"$version" && { echo "smoke: FAIL built without cgo (modernc-sqlite), upstream uses mattn/go-sqlite3"; exit 1; }
uid_a="$($docker exec "$tag-a" sh -c 'stat -c %u /proc/1')"
# The entrypoint execs su-exec, which execs syncthing, so syncthing is PID 1 in both containers.
uid_b="$($docker exec "$tag-b" sh -c 'stat -c %u /proc/1')"
[ "$uid_a" = 22000 ] || { echo "smoke: FAIL A runs as uid $uid_a, expected 22000"; exit 1; }
[ "$uid_b" = 1000 ] || { echo "smoke: FAIL B (default mode) runs as uid '$uid_b', expected 1000"; exit 1; }
echo "smoke: ${version%% (*}; A uid 22000 (hardened), B uid 1000 (default su-exec)"

id_a="$(api a GET /rest/system/status | jq -r .myID)"
id_b="$(api b GET /rest/system/status | jq -r .myID)"
off='{"globalAnnounceEnabled":false,"localAnnounceEnabled":false,"relaysEnabled":false,"natEnabled":false,"urAccepted":-1,"crashReportingEnabled":false}'
api a PATCH /rest/config/options "$off" >/dev/null
api b PATCH /rest/config/options "$off" >/dev/null
api a POST /rest/config/devices "$(jq -nc --arg id "$id_b" '{deviceID:$id,name:"b",addresses:["tcp://st-b:22000"]}')" >/dev/null
api b POST /rest/config/devices "$(jq -nc --arg id "$id_a" '{deviceID:$id,name:"a",addresses:["tcp://st-a:22000"]}')" >/dev/null
folder() {  # folder <a|b>
  api "$1" POST /rest/config/folders "$(jq -nc --arg a "$id_a" --arg b "$id_b" \
    '{id:"smoke",label:"smoke",path:"/var/syncthing/smoke",type:"sendreceive",rescanIntervalS:5,fsWatcherEnabled:false,devices:[{deviceID:$a},{deviceID:$b}]}')" >/dev/null
}
folder a; folder b

for _ in $(seq 60); do
  [ "$(api a GET /rest/system/connections | jq -r --arg b "$id_b" '.connections[$b].connected')" = true ] && break; sleep 1
done
[ "$(api a GET /rest/system/connections | jq -r --arg b "$id_b" '.connections[$b].connected')" = true ] \
  || { echo "smoke: FAIL A and B did not connect"; exit 1; }
echo "smoke: A and B connected over TCP"

payload="smoke-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
for _ in $(seq 30); do $docker exec "$tag-a" test -d /var/syncthing/smoke && break; sleep 1; done
$docker exec "$tag-a" sh -c "printf '%s' '$payload' > /var/syncthing/smoke/hello.txt"
api a POST '/rest/db/scan?folder=smoke' >/dev/null
for _ in $(seq 90); do
  got="$($docker exec "$tag-b" cat /var/syncthing/smoke/hello.txt 2>/dev/null || true)"
  [ "$got" = "$payload" ] && break; sleep 1
done
[ "$got" = "$payload" ] || { echo "smoke: FAIL file did not sync from A to B"; exit 1; }
echo "smoke: file synced A -> B"

$docker stop -t 15 "$tag-a" >/dev/null
$docker start "$tag-a" >/dev/null
wait_health a
[ "$(api a GET /rest/system/status | jq -r .myID)" = "$id_a" ] || { echo "smoke: FAIL device ID changed after restart"; exit 1; }
echo "smoke: restart keeps the device ID"

logs="$($docker logs "$tag-a" 2>&1)"
if grep -qiE 'panic:|permission denied|read-only file system' <<<"$logs"; then
  grep -iE 'panic:|permission denied|read-only file system' <<<"$logs" | head -5
  echo "smoke: FAIL panic or permission error in A's logs"; exit 1
fi
echo "smoke: PASS"
