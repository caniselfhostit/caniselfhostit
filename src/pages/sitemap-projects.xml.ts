/* /sitemap-projects.xml — one URL per project page.
 *
 * <lastmod> is real: `contentUpdatedAt` in data/projects/<slug>/index.json is
 * guarded by `contentHash` (scripts/validate-projects.mjs fails CI when the
 * content moved and the date did not), so this date means "the prose or the
 * prompt actually changed" rather than "a build ran". A date-only value is valid
 * W3C-datetime per the sitemaps protocol; a fake timestamp would be worse than
 * no timestamp, so nothing here is invented.
 *
 * No <priority> and no <changefreq>: Google has ignored both for years, and
 * emitting numbers nobody reads is how a sitemap starts lying by accident.
 *
 * Ordering follows getAllProjects() — editorial pagePriority, then alphabetical.
 * Sitemap order carries no ranking signal; it is here so the file diffs cleanly.
 *
 * FUTURE (PRD §10.2): pages that fail the publish gate ship `pending` — noindex
 * and unsitemapped, with inbound links retained. When that gate lands, filter it
 * here (one `.filter()`), not by hand-editing a list.
 */
import type { APIRoute } from 'astro';
import { SITE } from '../lib/site.js';
import { getAllProjects } from '../lib/projects.js';
import { isIsoDate } from '../lib/rubric.js';

/**
 * The sitemaps protocol requires entity-escaped URLs. Slugs are directory names
 * and the validator only checks that they match, so an `&` in one would
 * otherwise produce a file every parser rejects — cheaper to escape than to
 * discover in Search Console.
 */
function xmlEscape(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/'/g, '&apos;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

export const GET: APIRoute = () => {
  const entries = getAllProjects().map((project) => {
    const loc = xmlEscape(`${SITE.origin}/self-host/${project.slug}/`);
    // An unparseable date would invalidate the whole file for a strict parser,
    // so a bad value drops the element instead of shipping it.
    const lastmod = isIsoDate(project.contentUpdatedAt)
      ? `<lastmod>${project.contentUpdatedAt}</lastmod>`
      : '';
    return `  <url><loc>${loc}</loc>${lastmod}</url>`;
  });

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${entries.join('\n')}
</urlset>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
