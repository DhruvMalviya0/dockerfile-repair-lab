FROM node:20-alpine

# Set the working directory before copying so files land in /app
WORKDIR /app
COPY . .

# Install exactly what package-lock.json pins (production deps only)
RUN npm ci --omit=dev

EXPOSE 8080

# Start the server directly (same as the "start" script in package.json)
CMD ["node", "app.js"]
