# syncthing-hardened

Rebuilds upstream [Syncthing](https://github.com/syncthing/syncthing) release tags from source with the newest
stable Go and bumped Go modules, on current Alpine with `apk upgrade`. Each build is gated on a Trivy scan and a smoke
test, and the result is published to `ghcr.io/rmonk/syncthing`. It is a drop-in replacement for
`docker.io/syncthing/syncthing`: same entrypoint, environment, health check, volume and paths.

No fork: each build clones upstream at the tag in `UPSTREAM_VERSION` and builds it with `overlay/Dockerfile`.

At v2.1.7 (tested 2026-11-18): Trivy findings went from 1 critical / 6 high in `syncthing/syncthing:2`
(Alpine `brotli`, `curl`, `musl`, `zlib`, and `golang.org/x/net` 0.60.0 in the binary) to none at any severity.

## What gets changed

| | Upstream image | Hardened |
|---|---|---|
| Alpine packages | frozen at the release build | `apk upgrade`, rebuilt weekly |
| `syncthing` binary | release build (go1.27.3 at v2.1.7) | built from the tag with the newest stable Go; modules in `overlay/go-bumps.txt` raised to latest (same major) |
| SQLite driver | cgo (`mattn/go-sqlite3`) | the same: built with cgo against musl, so the version string shows `[noupgrade]` only (no `modernc-sqlite`) |

Everything else is upstream's: `script/docker-entrypoint.sh`, `PUID`/`PGID`/`HOME`, `STGUIADDRESS`, `STHOMEDIR`,
the health check, `VOLUME /var/syncthing` and the entrypoint.

## Running it

It works like the upstream image. To run without root at all (as on futomaki), set `user:`; the entrypoint then skips
`su-exec` and runs syncthing directly, so no capabilities are needed:

```yaml
image: ghcr.io/rmonk/syncthing:latest-hardened
user: "22000:22000"
cap_drop: [ALL]
security_opt: [no-new-privileges:true]
read_only: true
tmpfs: [/tmp]
```

The volumes must be owned by that uid/gid. Moving from upstream's default (`PUID=1000`), once, with the container
stopped: `chown -R 22000:22000 <config volume> <data volume>` on the host.

## Tags

- `latest-hardened`: newest successful build of the current `UPSTREAM_VERSION`
- `<upstream>-hardened`, e.g. `v2.1.7-hardened`
- `<upstream>-hardened-<YYYYMMDD>`: immutable, use this to pin or roll back

amd64 only.

## Automation

- `build.yml`: runs on push/PR, manually, and weekly (Mon 06:07 UTC). It runs prepare, then build, then the Trivy
  gate (fixable CRITICAL/HIGH fail the build; exceptions go in `.trivyignore.yaml`, scoped to a package URL with a
  reason and an expiry date), then the smoke test, then pushes (on main only). The Trivy JSON/table output is kept as
  a build artifact. If the `HC_PING_URL` secret is set, a successful run pings it.
- `watch-upstream.yml`: runs daily. When Syncthing publishes a new (non-prerelease) release, it opens a PR that bumps
  `UPSTREAM_VERSION` and dispatches the build on that branch. Merge it when it is green.

## Keeping in step with upstream

Our Dockerfile replaces upstream's, so `scripts/prepare.sh` checks anchors in upstream's tree at the tag (the build
command, the runtime base and packages, the entrypoint and its non-root branch, env defaults, the volume, the health
check, and that `build.go` still reads `RELEASE`). If one is missing, the build fails instead of shipping something
that only looks right. Then compare upstream's `Dockerfile` with `overlay/Dockerfile` and adjust.

## Smoke test

`scripts/smoke-test.sh` starts two instances on a private network:
- A the way futomaki runs it (user 22000, no capabilities, `no-new-privileges`, read-only root, tmpfs `/tmp`)
- B with upstream's defaults (starts as root, the entrypoint drops to uid 1000 with `su-exec`)

It checks the version (and that the binary uses cgo SQLite), the health endpoint, the uid of each, that A and B pair
over TCP with discovery, relays and NAT off, that a file written on A arrives on B unchanged, that a restart keeps A's
device ID, and that A's logs have no panics or permission errors.

## Local build

```bash
scripts/prepare.sh
podman build -f build/src/Dockerfile.hardened $(sed 's/^/--build-arg /' build/build-args) \
  -t syncthing:hardened build/src
DOCKER=podman scripts/smoke-test.sh syncthing:hardened
```
