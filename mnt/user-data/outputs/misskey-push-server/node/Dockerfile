FROM node:20-alpine

WORKDIR /app

# Install build deps for better-sqlite3 (native module)
RUN apk add --no-cache python3 make g++ curl

# Copy package files first — layer cache
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --quiet

# Copy server
COPY server.mjs ./

# Non-root user (node user exists in node:alpine)
RUN mkdir -p /data && chown node:node /data
USER node

EXPOSE 3000

CMD ["node", "--max-old-space-size=128", "server.mjs"]
