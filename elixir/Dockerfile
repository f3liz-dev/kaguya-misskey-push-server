# Elixir push server — multi-stage build for minimal image
FROM elixir:1.17-otp-27-alpine AS build

RUN apk add --no-cache build-base

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency files first for caching
COPY mix.exs ./
ENV MIX_ENV=prod
RUN mix deps.get --only prod && mix deps.compile

# Copy source
COPY config/ config/
COPY lib/ lib/

# Build release
RUN mix release

# --- Runtime stage ---
FROM alpine:3.20 AS runtime

RUN apk add --no-cache libstdc++ libgcc ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/push_server ./

# Data volume for SQLite
RUN mkdir -p /data
VOLUME /data

ENV DB_PATH=/data/push_server.db
ENV PORT=4000

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://localhost:4000/health || exit 1

ENTRYPOINT ["/app/bin/push_server"]
CMD ["start"]
