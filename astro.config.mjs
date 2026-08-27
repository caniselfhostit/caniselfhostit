import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';

// Content routes are prerendered at build time (Astro's static default) — every
// fact, prompt, and chart number ships in the initial HTML, because no AI
// crawler executes JavaScript. Data that changes (GitHub stats, verification
// state) is read at BUILD time; a nightly cron rebuilds the site. Only /api/*
// routes opt out with `export const prerender = false` and run on the Worker.
export default defineConfig({
  site: 'https://caniselfhostit.com',
  output: 'static',
  adapter: cloudflare(),
  vite: {
    // Build id for cache-busting unhashed public/ assets and OG image URLs.
    define: { __BUILD_ID__: JSON.stringify(Date.now().toString(36)) },
    // No tsconfig path aliases exist in this repo, so tsconfig discovery buys
    // the bundler nothing — and it breaks `astro dev`/`astro build` inside a
    // git worktree nested under the checkout: discovery walks up to the parent
    // repo's tsconfig.json and fails resolving its `extends` there, where no
    // node_modules exists. Every layer that discovers tsconfigs is pinned off
    // (the vite resolver's scan, rolldown's build loader, and the dep
    // optimizer's own rolldown pass) until the day an alias is introduced.
    resolve: { tsconfigPaths: false },
    build: { rollupOptions: { tsconfig: false } },
    plugins: [
      {
        // The dep optimizer runs per environment, and the adapter's extra
        // server environments (astro/ssr/prerender) don't inherit a top-level
        // `optimizeDeps` — this hook reaches every environment, including
        // those.
        name: 'tsconfig-discovery-off',
        configEnvironment: () => ({
          optimizeDeps: { rolldownOptions: { tsconfig: false } },
        }),
      },
    ],
  },
});
