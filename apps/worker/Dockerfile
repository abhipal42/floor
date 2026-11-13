# The always-on live worker (M3). Build from the REPO ROOT, because the worker imports the
# workspace packages (@floor/shared, @floor/db) and npm needs every workspace's manifest:
#
#   docker build -f apps/worker/Dockerfile -t floor-worker .
#   docker run --rm --env-file .env floor-worker
#
# fly.toml next to this file points here; see docs/HANDOFF.md, "M3: Live layer", for deploying.
FROM node:22-slim

WORKDIR /app
ENV NODE_ENV=production

# Manifests first, so the dependency layer is cached until a package.json or the lockfile changes.
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/
COPY apps/worker/package.json apps/worker/
COPY packages/db/package.json packages/db/
COPY packages/shared/package.json packages/shared/
# Dev dependencies included: the worker runs TypeScript through tsx, as it does locally.
RUN npm ci --include=dev --workspace @floor/worker --include-workspace-root=false && npm cache clean --force

COPY packages/ packages/
COPY apps/worker/src/ apps/worker/src/

# Never root: the worker only makes outbound requests.
USER node
WORKDIR /app/apps/worker
# SIGTERM from the platform reaches node directly (no npm wrapper), so the poll in flight finishes.
CMD ["node", "--import", "tsx", "src/cli.ts", "live"]
