# syntax=docker/dockerfile:1
# lists-web: the self-hosted web interface. Build from the repository root.
# The binary is linked statically against musl, so the image holds nothing
# but it and a minimal init.

# Pinned by digest as well: a tag can be pushed again. Dependabot raises both.
FROM rust:1.94.1-alpine@sha256:77237dd363a0b127bb5ef532c2d64c0deb380b738e43a9c4bdac73398d6d0a08 AS build
# tini forwards SIGTERM: lists-web installs no signal handlers and would
# otherwise ignore `docker stop` as PID 1.
RUN apk add --no-cache musl-dev tini-static
WORKDIR /src
COPY core core
COPY web web
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/web/target,sharing=locked \
    cargo build --release --locked --manifest-path web/Cargo.toml \
    && cp web/target/release/lists-web /lists-web \
    && mkdir -p /data/tmp

FROM scratch
COPY --from=build /sbin/tini-static /tini
COPY --from=build /lists-web /lists-web
COPY --from=build --chown=10001:10001 /data /data
USER 10001:10001
WORKDIR /data
# scratch has no /tmp, and the root filesystem may be read-only: uploads and
# imports are written to temporary files on the data volume instead (#334).
# A volume made by an older image has no tmp/; the server creates it.
ENV LISTS_WEB_LISTEN=0.0.0.0:8080 \
    LISTS_WEB_DATA=/data \
    TMPDIR=/data/tmp
VOLUME /data
EXPOSE 8080
# R144: the image has no shell or curl, so the server asks itself.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD ["/lists-web", "healthcheck"]
ENTRYPOINT ["/tini", "--", "/lists-web"]
