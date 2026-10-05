FROM node:20-alpine

# Set the working directory before copying so files land in /app
WORKDIR /app
COPY . .

# Broken dependency installation
RUN npm install package-lock.json

# Copying a folder that doesn't exist in the project
COPY missing-folder ./missing-folder

EXPOSE 8080

# Incorrect startup command
CMD ["npm", "run", "production"]
