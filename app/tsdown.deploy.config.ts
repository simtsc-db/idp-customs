import { appkitServerConfig } from '@databricks/appkit/tsdown';

// Deploy build: inline all runtime dependencies (no node_modules at deploy time).
export default appkitServerConfig((base) => ({
  ...base,
  unbundle: false,
  // Dev-only tooling stays external.
  external: [/^(vite|@vitejs\/|lightningcss|esbuild|rollup|fsevents|tsx|@tailwindcss\/)/],
  noExternal: [/^(?!(vite|@vitejs\/|lightningcss|esbuild|rollup|fsevents|tsx|@tailwindcss\/))/],
  // Native dev-only module used by AppKit typegen: stub it.
  alias: { '@ast-grep/napi': new URL('./server/deploy-stubs/ast-grep-napi.ts', import.meta.url).pathname },
  platform: 'node',
  target: 'node22',
  outDir: '../app_dist',
  clean: false,
  shims: true,
}));
