/* /sitemap-core.xml — the hand-maintained pages: the directory itself, Prompt
 * Zero, methodology, and the boring-but-required legal set.
 *
 * No <lastmod> anywhere in this file. There is no honest source for it yet:
 * these pages are edited by hand and nothing records when. A build-time
 * `new Date()` would put today's date on eight pages that did not change, which
 * is precisely the freshness lie the rest of this site is built to refuse — and
 * Google discounts a lastmod it catches lying. Project pages get a real one
 * (sitemap-projects.xml) because `contentUpdatedAt` is validated against a
 * content hash. When core pages grow the same guarantee, add it here.
 *
 * /colophon/ is deliberately absent: it is still a noindex stub, and a URL that
 * is noindexed has no business in a sitemap.
 */
import type { APIRoute } from 'astro';
import { SITE } from '../lib/site.js';

/** Trailing slashes match Astro's emitted directory URLs — no redirect hop. */
const PATHS = [
  '/',
  '/prompt-zero/',
  '/methodology/',
  '/about/',
  '/contribute/',
  '/terms/',
  '/privacy/',
  '/security/',
];

export const GET: APIRoute = () => {
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${PATHS.map((path) => `  <url><loc>${SITE.origin}${path}</loc></url>`).join('\n')}
</urlset>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
