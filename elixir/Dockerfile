# Multi-stage build — builder is large, final image is small
# Stage 1: build the release
FROM elixir:1.19.5-alpine AS builder

WORKDIR /build

# Install build deps
RUN apk add --no-cache git build-base

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
FROM alpine:3.23.3 AS runtime

RUN apk add --no-cache openssl ncurses-libs libstdc++ curl libgcc

WORKDIR /app

# Copy release from builder
COPY --from=builder /build/_build/prod/rel/push_server ./

# Non-root user
RUN adduser -S -D -H push
RUN mkdir -p /data && chown push:push /data
USER push

EXPOSE 4000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:4000/health || exit 1

CMD ["./bin/push_server", "start"]
