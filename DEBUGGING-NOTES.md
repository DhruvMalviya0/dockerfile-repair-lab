# Dockerfile Repair — Debugging Notes

Branch: `fix/dockerfile-build` · Raw logs and screenshots are in [`evidence/`](evidence/).

## TL;DR

The original `Dockerfile` failed to build, and when you got past each build error the next one appeared. Some faults didn't stop the build at all: they broke things quietly or crashed the container at runtime. I found **six faults across all five break families** and fixed them one commit at a time. I then reordered the layers for caching, tightened `.dockerignore` and switched the container to a non-root user.

Result: `docker build -t app:fixed .` succeeds and `docker run -p 8080:8080 app:fixed` serves the success page and `/api/status`.

## Before

```dockerfile
FROM node:notfound

# Copy files first, then change directory
COPY . .
WORKDIR /wrong

# Broken dependency installation
RUN npm install package-lock.json

# Copying a folder that doesn't exist in the project
COPY missing-folder ./missing-folder

EXPOSE 8080

# Incorrect startup command
CMD ["npm", "run", "production"]
```

`.dockerignore` (before):

```
node_modules
src
.env
```

## How I worked it

I ran `docker build --progress=plain` and read the first failing step plus the error above it. I fixed only that step and rebuilt. BuildKit's output shows `#N [x/y]` step numbers, which correspond to the classic builder's `Step X/Y`.

| # | Failing step / symptom | Error seen | Family | Root cause | Fix | Commit |
|---|---|---|---|---|---|---|
| 1 | `Dockerfile:1 FROM node:notfound` (metadata load) | `docker.io/library/node:notfound: not found` | **Base image** | The tag `notfound` doesn't exist on Docker Hub. | `FROM node:20-alpine`: a real tag, and Alpine keeps it small. It matches `"engines": {"node": ">=18"}`. | `fix: correct base image tag to node:20-alpine` |
| 2 | `[3/5] WORKDIR /wrong` (no error, silent) | Files land in `/`, mixed in with `/bin`, `/etc`… and the working dir `/wrong` is empty (see `evidence/03`, `04`). | **WORKDIR / paths** | `COPY . .` runs *before* `WORKDIR`, so it copies into the default `/`. Then the working dir moves to an empty `/wrong`. | Set `WORKDIR /app` **before** any `COPY`. | `fix: set WORKDIR before copy` |
| 3 | `[4/5] RUN npm install package-lock.json` | Builds, but `package.json` gains `"package-lock.json": "^1.0.0"` (see `evidence/04`). The build doesn't fail, so this bug is silent. | **Dependencies** | `npm install <arg>` treats the argument as a *package name to add*. It isn't a lockfile path. The step pulls an unrelated package from npm and rewrites the manifest. Because `/wrong` has no `package.json`, npm also walks up to `/`. | `RUN npm ci --omit=dev`: a reproducible install from the lockfile without devDeps. It fails loudly if `package.json` and the lockfile drift apart. | `fix: install dependencies from the lockfile with npm ci` |
| 4 | `[5/5] COPY missing-folder ./missing-folder` | `failed to calculate checksum of ref …: "/missing-folder": not found` | **Build context** | No `missing-folder` exists in the repo, so it's not in the build context. The app never references it either. | Removed the instruction. | `fix: remove COPY of missing-folder, …` |
| 5 | Runtime: `node app.js` | `Error: Cannot find module './src/routes'` | **Build context** | `.dockerignore` listed `src`, so `src/` was never sent to the daemon, but `app.js` requires `./src/routes`. | Removed `src` from `.dockerignore`. | `fix: stop .dockerignore excluding src/ …` |
| 6 | Runtime: `docker run app:broken` exits with code 1 | `npm error Missing script: "production"` | **Startup command** | `package.json` defines only a `start` script. | `CMD ["node", "app.js"]` (what `npm start` runs). Calling node directly avoids an extra npm process, so Docker's signals reach node itself. | `fix: replace nonexistent npm run production with node app.js` |

Fault 4 hid fault 3: BuildKit computes the `COPY missing-folder` checksum early and cancels the build before `npm install` runs. Fixes 1 and 4 got the image to build, and that exposed the silent dependency bug and the two runtime crashes.

## After

```dockerfile
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
```

`.dockerignore` (after): `node_modules`, `npm-debug.log`, `.env`, `.git`, `.gitignore`, `Dockerfile`, `.dockerignore`, `README.md`, `DEBUGGING-NOTES.md`, `evidence`, `.DS_Store`.

## Optimizations (commit `perf: order layers for cache, slim the build context, run as non-root`)

- **Layer order for cache:** `package.json` and `package-lock.json` are copied and installed *before* the source code. When only code changes, Docker reuses the cached `npm ci` layer, as `evidence/07-cache-rebuild.log` shows (`[4/7] RUN npm ci … CACHED`, only `src` and `public` rebuilt).
- **Lightweight base:** `node:20-alpine` (≈49 MB compressed) instead of the Debian-based `node:20` (≈1 GB unpacked).
- **Lean dependency layer:** `npm ci --omit=dev` plus `npm cache clean --force` keeps devDeps and npm's cache out of the image.
- **Explicit COPYs and `.dockerignore`:** only `app.js`, `src/` and `public/` reach the image. Local `node_modules`, `.git`, `.env`, docs and evidence are excluded from the build context, which makes builds faster and stops secrets or host binaries from leaking into the image.
- **Security:** the container runs as the `node` user (`docker exec lab whoami` → `node`), and `NODE_ENV=production` is set.

## Validation

| Check | Command | Result | Evidence |
|---|---|---|---|
| Clean build | `docker build --no-cache -t app:fixed .` | All 7 steps finish, exit 0 | `evidence/05-fixed-build.log` |
| Container starts | `docker run -d -p 8080:8080 app:fixed` | `Up`, logs `Server is running on port 8080` | `evidence/06-fixed-run.log` |
| UI served | `curl http://localhost:8080/` | HTTP 200, contains **Docker Repair Lab Running Successfully** | `evidence/06-fixed-run.log`, `evidence/08-running-container.png` |
| API served | `curl http://localhost:8080/api/status` | `{"status":"ok",…,"environment":"production"}` | `evidence/06-fixed-run.log`, `evidence/09-api-status.png` |
| No stray dependency | `grep -c '"package-lock.json"' /app/package.json` | `0` | `evidence/06-fixed-run.log` |
| Cache works | edit `src/utils.js`, rebuild | `npm ci` layer `CACHED` | `evidence/07-cache-rebuild.log` |

### Evidence index

- `01-broken-base-image.log`: fault 1
- `02-broken-missing-folder.log`: fault 4 (after fixing 1)
- `03-broken-npm-install.log`: the "successful" build that hides faults 2 and 3
- `04-broken-runtime.log`: faults 5 and 6 at runtime, plus the stray `package-lock.json` dependency
- `05-fixed-build.log`, `06-fixed-run.log`, `07-cache-rebuild.log`: validation
- `08-running-container.png`, `09-api-status.png`: screenshots of the running container

### Environment note

The evidence was captured in a sandbox whose outbound HTTPS goes through a TLS-intercepting proxy, and Docker Hub rate-limited (HTTP 429) tag lookups during the session. So that `npm ci` could reach the registry, I tagged a local `node:20-alpine` built from the official image (`node@sha256:fb4cd12c…`) plus the proxy's CA certificate and `NODE_EXTRA_CA_CERTS`. That's why the logs show the base digest `sha256:57af77cc…`. **The committed `Dockerfile` is unchanged by this** and builds as-is against the real `node:20-alpine` on a normal machine.

## Notes for the walkthrough video

1. Run `docker build -t app:broken .` on `main` and point at `Dockerfile:1` plus `node:notfound: not found`.
2. Go through the six faults in the table, naming the family for each.
3. Show the final `Dockerfile`, explaining manifest → `npm ci` → source, Alpine and non-root.
4. Run `docker build -t app:fixed .`, then `docker run -p 8080:8080 app:fixed`, and open `localhost:8080` and `/api/status`.
5. Edit a source file and rebuild to show `npm ci` coming from cache.
