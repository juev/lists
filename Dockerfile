# syntax=docker/dockerfile:1
# lists-web: the self-hosted web interface. Build from the repository root.

FROM rust:1.94.1-slim-bookworm AS build
WORKDIR /src
COPY core core
COPY web web
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/web/target,sharing=locked \
    cargo build --release --locked --manifest-path web/Cargo.toml \
    && cp web/target/release/lists-web /lists-web

FROM debian:bookworm-slim
# tini forwards SIGTERM: lists-web installs no signal handlers and would
# otherwise ignore `docker stop` as PID 1.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /data --no-create-home lists \
    && install -d -o lists -g lists /data
COPY --from=build /lists-web /usr/local/bin/lists-web
USER lists
WORKDIR /data
ENV LISTS_WEB_LISTEN=0.0.0.0:8080 \
    LISTS_WEB_DATA=/data
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["tini", "--", "lists-web"]
