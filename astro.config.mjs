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
  },
});
