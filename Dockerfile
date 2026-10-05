# syntax=docker/dockerfile:1
# lists-web: the self-hosted web interface. Build from the repository root.
# The binary is linked statically against musl, so the image holds nothing
# but it and a minimal init.

FROM rust:1.94.1-alpine AS build
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
    && mkdir /data

FROM scratch
COPY --from=build /sbin/tini-static /tini
COPY --from=build /lists-web /lists-web
COPY --from=build --chown=10001:10001 /data /data
USER 10001:10001
WORKDIR /data
ENV LISTS_WEB_LISTEN=0.0.0.0:8080 \
    LISTS_WEB_DATA=/data
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/tini", "--", "/lists-web"]
