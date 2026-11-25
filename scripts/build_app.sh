#!/usr/bin/env bash
# Build the officer review app (AppKit) into a self-contained deploy folder.
#
# Why: in our environment the Databricks Apps build could not fetch packages
# from the internal npm mirror, and public registries were not allowed. So we
# install via the mirror locally, inline all runtime dependencies into one
# server bundle, and deploy app_dist/ with no dependencies to install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"

: "${NPM_REGISTRY:?set NPM_REGISTRY to your organisation's npm mirror}"
npm ci --registry "$NPM_REGISTRY" --no-audit --no-fund
npm run typecheck
npm run lint
npx appkit lint
npm run build:client

rm -rf "$ROOT/app_dist"
npx tsdown -c tsdown.deploy.config.ts
mkdir -p "$ROOT/app_dist/client"
cp -R client/dist "$ROOT/app_dist/client/dist"
cp appkit.plugins.json "$ROOT/app_dist/"

cat > "$ROOT/app_dist/app.yaml" <<'EOF'
command: ['node', 'server.js']
env:
  - name: NODE_ENV
    value: production
  - name: DATABRICKS_VOLUME_FILES
    valueFrom: files
  - name: LAKEBASE_ENDPOINT
    valueFrom: postgres
EOF
cat > "$ROOT/app_dist/package.json" <<'EOF'
{
  "name": "permit-review",
  "private": true,
  "type": "module",
  "scripts": { "start": "node server.js" }
}
EOF
echo "app_dist ready: $(du -sh "$ROOT/app_dist" | cut -f1)"
