/* /sitemap.xml — the sitemap INDEX, not a list of pages.
 *
 * Split by archetype on purpose (PRD §10.8): Search Console reports coverage
 * per submitted sitemap, so "core" and "projects" in separate files turns
 * indexing into a per-template chart. One flat sitemap would only ever tell us
 * that some pages are missing, never which template Google is rejecting.
 *
 * Add a child here and in nothing else — the URL is derived from SITE.origin,
 * which is the one place the domain is written down (src/lib/site.js).
 */
import type { APIRoute } from 'astro';
import { SITE } from '../lib/site.js';

/** Filenames of the child sitemaps, each a real endpoint in this directory. */
const CHILDREN = ['sitemap-core.xml', 'sitemap-projects.xml'];

export const GET: APIRoute = () => {
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${CHILDREN.map((name) => `  <sitemap><loc>${SITE.origin}/${name}</loc></sitemap>`).join('\n')}
</sitemapindex>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
