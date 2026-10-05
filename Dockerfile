# Lightweight, pinned major version of Node on Alpine
FROM node:20-alpine

ENV NODE_ENV=production

# Set the working directory before copying so files land in /app
WORKDIR /app

# 1) Copy only the dependency manifests first. This layer (and the npm ci
#    layer below) stays cached until package*.json changes.
COPY package.json package-lock.json ./

# Install exactly what package-lock.json pins (production deps only)
RUN npm ci --omit=dev && npm cache clean --force

# 2) Copy application source last: editing code only rebuilds from here.
COPY --chown=node:node app.js ./
COPY --chown=node:node src ./src
COPY --chown=node:node public ./public

# Run as the unprivileged user that ships with the node image
USER node

EXPOSE 8080

# Start the server directly (same as the "start" script in package.json)
CMD ["node", "app.js"]
