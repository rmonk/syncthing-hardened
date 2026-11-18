# Hardened Syncthing image: upstream source at the release tag, built with the newest stable Go
# and bumped Go modules, on current Alpine with `apk upgrade`. Runtime layout, entrypoint,
# environment, health check and volume are upstream's (script/docker-entrypoint.sh and the
# runtime stage of upstream's Dockerfile), so it is a drop-in replacement for
# docker.io/syncthing/syncthing.
#
# Build context: build/src (upstream source + hardening/), prepared by scripts/prepare.sh.
# Build args come from build/build-args.

ARG GO_IMAGE
ARG RUNTIME_IMAGE

FROM ${GO_IMAGE} AS build
# Use the image's Go, never download another toolchain. cgo is on so the database uses
# mattn/go-sqlite3, like upstream's release binaries (with cgo off, syncthing falls back to the
# pure-Go modernc driver). The build stage is Alpine, so the binary links against musl, which the
# Alpine runtime provides.
ENV GOTOOLCHAIN=local CGO_ENABLED=1
RUN apk add --no-cache build-base
WORKDIR /src
COPY . .
RUN sh hardening/go-bump.sh hardening/go-bumps.txt
# build.go takes the version from the RELEASE file written by prepare.sh (no .git in the context).
RUN go run build.go -no-upgrade build syncthing \
 && ./syncthing --version

FROM ${RUNTIME_IMAGE}
ARG UPSTREAM_VERSION
ARG UPSTREAM_SHA
ARG HARDENED_VERSION=dev
ARG HARDENED_SOURCE=

LABEL org.opencontainers.image.title="syncthing (hardened)" \
      org.opencontainers.image.version="${HARDENED_VERSION}" \
      org.opencontainers.image.source="${HARDENED_SOURCE}" \
      org.opencontainers.image.description="Syncthing ${UPSTREAM_VERSION} built from source with current Go/Alpine" \
      org.opencontainers.image.licenses="MPL-2.0" \
      net.syncthing.version="${UPSTREAM_VERSION}" \
      net.syncthing.revision="${UPSTREAM_SHA}"

EXPOSE 8384 22000/tcp 22000/udp 21027/udp

VOLUME ["/var/syncthing"]

# Same packages as upstream, upgraded to current.
RUN apk upgrade --no-cache \
 && apk add --no-cache ca-certificates curl libcap su-exec tzdata

COPY --from=build /src/syncthing /bin/syncthing
COPY --from=build /src/script/docker-entrypoint.sh /bin/entrypoint.sh

# Upstream defaults. With `user:` set (as on futomaki), the entrypoint skips su-exec and
# runs syncthing directly as that user.
ENV PUID=1000 PGID=1000 HOME=/var/syncthing

HEALTHCHECK --interval=1m --timeout=10s \
  CMD curl -fkLsS -m 2 127.0.0.1:8384/rest/noauth/health | grep -o --color=never OK || exit 1

ENV STGUIADDRESS=0.0.0.0:8384
ENV STHOMEDIR=/var/syncthing/config
RUN chmod 755 /bin/entrypoint.sh
ENTRYPOINT ["/bin/entrypoint.sh", "/bin/syncthing"]
