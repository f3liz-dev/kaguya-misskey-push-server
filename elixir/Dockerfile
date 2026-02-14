# Multi-stage build — builder is large, final image is small
# Stage 1: build the release
FROM hexpm/elixir:1.16.3-erlang-26.2.5-debian-bookworm-20240612 AS builder

WORKDIR /build

# Install build deps
RUN apt-get update -q && apt-get install -y -q git

# Copy mix files first — layer cache: deps only reinstall if mix.exs changes
COPY mix.exs mix.lock ./
RUN mix local.hex --force --quiet && \
    mix local.rebar --force --quiet && \
    MIX_ENV=prod mix deps.get --only prod

# Copy source and build release
COPY lib ./lib
COPY config ./config
RUN MIX_ENV=prod mix release

# Stage 2: minimal runtime image
FROM debian:bookworm-slim AS runtime

RUN apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
      libssl3 libncurses6 libstdc++6 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy release from builder
COPY --from=builder /build/_build/prod/rel/push_server ./

# Non-root user
RUN useradd --system --no-create-home push
RUN mkdir -p /data && chown push:push /data
USER push

EXPOSE 4000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:4000/health || exit 1

CMD ["./bin/push_server", "start"]
