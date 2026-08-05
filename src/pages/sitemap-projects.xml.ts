/* /sitemap-projects.xml — one URL per canonical answer page.
 *
 * The pages are keyed by the PAID app, not the replacement: the indexable URL is
 * /self-host/miro/, and Excalidraw is what it answers with. The filename keeps
 * saying "projects" because Search Console reports coverage per submitted
 * sitemap URL, and renaming the file would reset that history for no gain.
 *
 * <lastmod> is real: it comes from the primary project's `contentUpdatedAt`,
 * which is guarded by `contentHash` (scripts/validate-projects.mjs fails CI when
 * the content moved and the date did not), so this date means "the prose or the
 * prompt actually changed" rather than "a build ran". A date-only value is valid
 * W3C-datetime per the sitemaps protocol; a fake timestamp would be worse than
 * no timestamp, so nothing here is invented.
 *
 * KNOWN GAP: the SaaS side of a page — a price re-check, a rewritten
 * whyPeoplePay — moves the page without moving this date, because
 * `contentUpdatedAt` only covers data/projects/. Under-reporting freshness is
 * the safe direction to be wrong in; over-reporting is the one Google punishes.
 *
 * No <priority> and no <changefreq>: Google has ignored both for years, and
 * emitting numbers nobody reads is how a sitemap starts lying by accident.
 *
 * Ordering follows getAllSaasPages() — editorial pagePriority, then alphabetical
 * by SaaS name. Sitemap order carries no ranking signal; it is here so the file
 * diffs cleanly.
 *
 * Old project-keyed URLs are not listed: they 301 to these (public/_redirects),
 * and a sitemap that advertises redirects is a sitemap Google reads twice.
 *
 * FUTURE (PRD §10.2): pages that fail the publish gate ship `pending` — noindex
 * and unsitemapped, with inbound links retained. When that gate lands, filter it
 * here (one `.filter()`), not by hand-editing a list.
 */
import type { APIRoute } from 'astro';
import { SITE } from '../lib/site.js';
import { getAllSaasPages } from '../lib/projects.js';
import { isIsoDate } from '../lib/rubric.js';

/**
 * The sitemaps protocol requires entity-escaped URLs. Slugs are filenames and
 * the validator only checks that they match, so an `&` in one would otherwise
 * produce a file every parser rejects — cheaper to escape than to discover in
 * Search Console.
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
  const entries = getAllSaasPages().map((page: any) => {
    const loc = xmlEscape(`${SITE.origin}/self-host/${page.slug}/`);
    // An unparseable date would invalidate the whole file for a strict parser,
    // so a bad value drops the element instead of shipping it.
    const lastmod = isIsoDate(page.contentUpdatedAt)
      ? `<lastmod>${page.contentUpdatedAt}</lastmod>`
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
