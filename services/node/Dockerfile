ARG NODE_VERSION=20
FROM node:${NODE_VERSION}-slim

ARG DEBIAN_FRONTEND=noninteractive

# ── Common tools ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# ── Global tools ──
RUN npm install -g nodemon pm2

WORKDIR /var/www/html

EXPOSE 3000

# NODE_COMMAND can be overridden at runtime via environment variable
CMD ["sh", "-c", "exec ${NODE_COMMAND:-node server.js}"]
