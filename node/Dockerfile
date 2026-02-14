# Node.js fallback server
FROM node:20-alpine AS build

WORKDIR /app
COPY package.json ./
RUN npm install --production

# --- Runtime stage ---
FROM node:20-alpine AS runtime

RUN apk add --no-cache tini

WORKDIR /app

COPY --from=build /app/node_modules ./node_modules
COPY package.json server.mjs ./

# Data volume for SQLite (shared with Elixir)
RUN mkdir -p /data
VOLUME /data

ENV DB_PATH=/data/push_server.db
ENV FALLBACK_PORT=3000
ENV NODE_ENV=production

EXPOSE 3000

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD node -e "require('http').get('http://localhost:3000/health',r=>{r.statusCode===200?process.exit(0):process.exit(1)}).on('error',()=>process.exit(1))"

ENTRYPOINT ["tini", "--"]
CMD ["node", "--max-old-space-size=128", "server.mjs"]
