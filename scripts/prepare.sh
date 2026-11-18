#!/usr/bin/env bash
# Set up the hardened build context for syncthing at the pinned upstream version.
# Result: build/src (Docker context: upstream source + hardening/ + RELEASE) with
# build/src/Dockerfile.hardened, and build/build-args (KEY=VALUE lines for --build-arg).
#
# Our Dockerfile replaces upstream's, so it depends on how upstream builds and lays out its
# image. The anchors below are read from upstream's tree at the same tag; if any is missing,
# upstream changed its image and overlay/Dockerfile must be reviewed before the build can go on.
#
# Usage: scripts/prepare.sh [upstream-version]   (default: contents of UPSTREAM_VERSION)
# Needs: git, curl, jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")}"
src="$root/build/src"
upstream_repo="${UPSTREAM_REPO:-https://github.com/syncthing/syncthing.git}"

rm -rf "$root/build"
mkdir -p "$root/build"
git clone --quiet --depth 1 --branch "$ref" "$upstream_repo" "$src" 2>/dev/null
sha="$(git -C "$src" rev-parse HEAD)"
echo "prepare: upstream $ref @ ${sha:0:12}"
rm -rf "$src/.git" "$src/.github"
# build.go reads the version from RELEASE when there is no git history.
echo "$ref" > "$src/RELEASE"

fail() { echo "prepare: $*" >&2; echo "prepare: upstream changed its image; review overlay/Dockerfile." >&2; exit 1; }
need() {  # need <description> <file> <extended regex>: must occur exactly once
  local n
  [ -f "$src/$2" ] || fail "anchor '$1': $2 is missing"
  n="$(grep -cE "$3" "$src/$2" || true)"
  [ "$n" = 1 ] || fail "anchor '$1' matched $n times in $2 (expected 1)"
}

need "build command"            Dockerfile 'go run build\.go -no-upgrade build syncthing'
need "runtime on plain alpine"  Dockerfile '^FROM alpine$'
need "runtime packages"         Dockerfile '^RUN apk add --no-cache ca-certificates curl libcap su-exec tzdata$'
need "entrypoint script copied" Dockerfile '^COPY --from=builder /src/script/docker-entrypoint\.sh /bin/entrypoint\.sh$'
need "volume"                   Dockerfile '^VOLUME \["/var/syncthing"\]$'
need "PUID/PGID/HOME defaults"  Dockerfile '^ENV PUID=1000 PGID=1000 HOME=/var/syncthing$'
need "GUI address"              Dockerfile '^ENV STGUIADDRESS=0\.0\.0\.0:8384$'
need "home dir"                 Dockerfile '^ENV STHOMEDIR=/var/syncthing/config$'
need "health check"             Dockerfile '127\.0\.0\.1:8384/rest/noauth/health'
need "entrypoint"               Dockerfile '^ENTRYPOINT \["/bin/entrypoint\.sh", "/bin/syncthing"\]$'
need "entrypoint skips su-exec when not root" script/docker-entrypoint.sh '^if \[ "\$\(id -u\)" = .0. \]; then$'
need "version from RELEASE"     build.go   'os\.ReadFile\("RELEASE"\)'

go_min="$(sed -nE 's/^go ([0-9.]+)$/\1/p' "$src/go.mod")"
go_version="$(curl -fsS 'https://go.dev/dl/?mode=json' | jq -r '[.[] | select(.stable)][0].version' | sed 's/^go//')"
for v in go_min go_version; do
  [ -n "${!v}" ] || { echo "prepare: could not determine $v" >&2; exit 1; }
done
[ "$(printf '%s\n%s\n' "$go_min" "$go_version" | sort -V | head -1)" = "$go_min" ] \
  || { echo "prepare: go.mod wants go $go_min, newer than the latest stable $go_version" >&2; exit 1; }
echo "prepare: go $go_version (go.mod: $go_min)"

mkdir -p "$src/hardening"
cp "$root/overlay/go-bump.sh" "$root/overlay/go-bumps.txt" "$src/hardening/"
cp "$root/overlay/Dockerfile" "$src/Dockerfile.hardened"

cat > "$root/build/build-args" <<EOF
GO_IMAGE=docker.io/library/golang:$go_version-alpine
RUNTIME_IMAGE=docker.io/library/alpine:latest
UPSTREAM_VERSION=$ref
UPSTREAM_SHA=$sha
EOF
echo "prepare: build context ready at $src"
