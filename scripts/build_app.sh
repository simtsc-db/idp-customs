#!/usr/bin/env bash
# Build the AppKit app into a self-contained app_dist/ (dependencies inlined, no install at deploy).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"

npm ci --no-audit --no-fund
npm run typecheck
npm run lint
npx appkit lint
npm run build:client

rm -rf "$ROOT/app_dist"
npx tsdown -c tsdown.deploy.config.ts
mkdir -p "$ROOT/app_dist/client"
cp -R client/dist "$ROOT/app_dist/client/dist"
cp appkit.plugins.json "$ROOT/app_dist/"

cat > "$ROOT/app_dist/package.json" <<'EOF'
{
  "name": "permit-review",
  "private": true,
  "type": "module",
  "scripts": { "start": "node server.js" }
}
EOF
echo "app_dist ready: $(du -sh "$ROOT/app_dist" | cut -f1)"
