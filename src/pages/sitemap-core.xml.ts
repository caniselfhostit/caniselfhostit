/* /sitemap-core.xml — everything that is not an answer page: the directory
 * itself, Prompt Zero, methodology, the boring-but-required legal set, and the
 * category hubs.
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
import { saasShelves } from '../lib/projects.js';

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

/* The category hubs belong here rather than in sitemap-projects.xml: that file
 * is one URL per answer page and every entry carries a guarded `lastmod`, and a
 * hub has neither. It is generated, not hand-maintained, but it shares the thing
 * this file is actually organised around — no honest date. A hub's content
 * changes when any of its children changes or when the shelf gains an app, and
 * nothing records either event; max(child dates) would be a guess dressed up as
 * a guarantee. So: listed, undated, same as everything else above.
 *
 * Derived from saasShelves(), the same call src/pages/category/[category].astro
 * builds its paths from. A hardcoded list here would eventually name a shelf the
 * route stopped emitting, which is a 404 submitted to Google on purpose.
 */
const hubPaths = () => saasShelves().map((shelf) => `/category/${shelf.slug}/`);

export const GET: APIRoute = () => {
  const paths = [...PATHS, ...hubPaths()];
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${paths.map((path) => `  <url><loc>${SITE.origin}${path}</loc></url>`).join('\n')}
</urlset>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
