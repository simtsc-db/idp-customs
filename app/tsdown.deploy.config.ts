import { appkitServerConfig } from '@databricks/appkit/tsdown';

// Deploy build: inline every dependency so the deployed app has no runtime
// node_modules and the Apps platform's npm install has nothing to fetch.
// Packages are installed locally from your organisation's npm mirror only.
export default appkitServerConfig((base) => ({
  ...base,
  unbundle: false,
  // Dev-only tooling (Vite dev server, lint, CSS compiler) is reached only via
  // AppKit's development code path; keep it external. Everything else is inlined.
  external: [/^(vite|@vitejs\/|lightningcss|esbuild|rollup|fsevents|tsx|@tailwindcss\/)/],
  noExternal: [/^(?!(vite|@vitejs\/|lightningcss|esbuild|rollup|fsevents|tsx|@tailwindcss\/))/],
  // Native dev-only module statically imported by AppKit's type generator: stub it.
  alias: { '@ast-grep/napi': new URL('./server/deploy-stubs/ast-grep-napi.ts', import.meta.url).pathname },
  platform: 'node',
  target: 'node22',
  outDir: '../app_dist',
  clean: false,
  shims: true,
}));
