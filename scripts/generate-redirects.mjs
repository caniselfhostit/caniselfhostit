/* Derives public/_redirects from data/. Bare Node — src/lib/projects.js is
 * Vite-only (import.meta.glob), so this reads data/ with node:fs and mirrors
 * getAllSaasPages()'s ordering rules by hand.
 *
 * Usage: node gen-redirects.mjs [repo-root]
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
// rubric.js is plain dependency-free ESM on purpose (see its header), so bare
// Node imports it as-is — the category vocabulary is not retyped here.
import { CATEGORY_LIST } from '../src/lib/rubric.js';

const ROOT = process.argv[2] ?? '/Users/jashanpreetsingh/Documents/projects/caniselfhostit';
const SAAS_DIR = join(ROOT, 'data/saas');
const PROJ_DIR = join(ROOT, 'data/projects');

const read = (p) => JSON.parse(readFileSync(p, 'utf8'));

const projects = new Map(
  readdirSync(PROJ_DIR)
    .filter((d) => !d.startsWith('.'))
    .map((d) => {
      const entry = read(join(PROJ_DIR, d, 'index.json'));
      if (entry.slug !== d) throw new Error(`data/projects/${d} declares slug "${entry.slug}"`);
      return [d, entry];
    })
);

const saas = readdirSync(SAAS_DIR)
  .filter((f) => f.endsWith('.json'))
  .map((f) => read(join(SAAS_DIR, f)))
  .filter((e) => (e.ranked ?? []).length > 0)
  .map((e) => {
    const primary = projects.get(e.ranked[0].project);
    if (!primary) throw new Error(`data/saas/${e.slug}.json ranks unknown "${e.ranked[0].project}"`);
    return { ...e, primary };
  })
  // getAllSaasPages(): primary.pagePriority, then name.
  .sort(
    (a, b) =>
      (a.primary.pagePriority ?? 99) - (b.primary.pagePriority ?? 99) ||
      a.name.localeCompare(b.name)
  );

/* A project can appear on several SaaS pages — primary on one, runner-up on
 * another. Its old URL has exactly one right destination: the page where it is
 * the PRIMARY, because that is the page actually about installing it. Claiming
 * by page order alone would hand /self-host/uptime-kuma/ to whichever page sorts
 * first, which for a runner-up is the wrong answer. So: primary claims win, and
 * a runner-up only claims a project that is primary nowhere.
 */
const claims = new Map(); // project -> { saas, rank, self? }
for (const page of saas) {
  page.ranked.forEach((r, rank) => {
    /* A project that names its own SaaS page IS that page. /self-host/plausible/
     * is built, sitemapped, and about installing Plausible — there is nothing to
     * redirect. Returning early here left the project UNCLAIMED, so a later page
     * ranking it as a runner-up claimed it and emitted a 301 on top of a live
     * page. That is what happened to plausible -> matomo-cloud: redirects are
     * evaluated before assets, so the page became unreachable while still sitting
     * in sitemap-projects.xml, and Search Console filed it as "Page with
     * redirect". So a self-reference records a claim instead — it emits no rule
     * (skipped below), and it is unconditional in both directions: it overwrites
     * a wrong claim that landed first (matomo-cloud sorts before plausible), and
     * the guard below stops any later page from displacing it. Slugs are unique,
     * so two self-claims can never conflict.
     */
    if (r.project === page.slug) {
      claims.set(r.project, { saas: page.slug, rank, self: true });
      return;
    }
    const prior = claims.get(r.project);
    if (prior?.self) return; // its own page already claimed it — never redirect
    if (!prior) {
      claims.set(r.project, { saas: page.slug, rank });
      return;
    }
    if (prior.rank === 0 && rank === 0) {
      console.error(
        `COLLISION: ${r.project} is primary for BOTH ${prior.saas} and ${page.slug} — pick one.`
      );
      return;
    }
    if (rank < prior.rank) claims.set(r.project, { saas: page.slug, rank });
  });
}

// Emit in getAllSaasPages() order, grouped by destination page. Self-claims are
// held in `claims` so the orphan check still counts them as spoken for, but they
// produce no rule: a live page is never a redirect source.
const pairs = [];
for (const page of saas) {
  for (const [project, claim] of claims) {
    if (claim.self) continue;
    if (claim.saas === page.slug) pairs.push([project, page.slug]);
  }
}

const orphans = [...projects.keys()].filter((s) => !claims.has(s));
if (orphans.length) console.error(`ORPHAN PROJECTS (no redirect target): ${orphans.join(', ')}`);

const width = Math.max(...pairs.map(([p]) => `/self-host/${p}.md`.length));
const out = pairs
  .flatMap(([proj, sa]) => [
    // Three forms per pair: slashed, bare (Workers asset matching is exact-path,
    // so /self-host/excalidraw without the slash falls through to the 404 page
    // unless named), and the .md mirror.
    `${`/self-host/${proj}/`.padEnd(width)}  /self-host/${sa}/  301`,
    `${`/self-host/${proj}`.padEnd(width)}  /self-host/${sa}/  301`,
    `${`/self-host/${proj}.md`.padEnd(width)}  /self-host/${sa}.md  301`,
  ])
  .join('\n');

/* Root-level routes that are NOT product pages. A SaaS slug landing on one of
 * these would shadow a real page with a 301 — cheap to prevent, impossible to
 * notice in production. Today nothing collides; the throw is for the day
 * somebody adds data/saas/security.json.
 */
const RESERVED = new Set([
  'about',
  'colophon',
  'contribute',
  'methodology',
  'privacy',
  'prompt-zero',
  'security',
  'terms',
  'self-host',
  'category',
  'api',
  'og',
  'js',
  'llms.txt',
  'favicon.svg',
  'robots.txt',
  'sitemap.xml',
  'sitemap-core.xml',
  'sitemap-projects.xml',
  '_astro',
  '_headers',
  '_redirects',
]);

const collisions = saas.map((e) => e.slug).filter((slug) => RESERVED.has(slug));
if (collisions.length) {
  throw new Error(
    `SaaS slug(s) collide with reserved top-level routes: ${collisions.join(', ')} — ` +
      `a bare-slug redirect would shadow the real page. Rename the slug.`
  );
}

/* Bare product slugs at the root -> the canonical page.
 *
 * Search Console reported /acuity-scheduling as a 404: links in the wild drop
 * the /self-host/ prefix, and a dropped prefix is a reader who meant this page,
 * so it earns a 301 rather than a 404. Two forms per slug because Workers asset
 * matching is exact-path — /acuity-scheduling and /acuity-scheduling/ are
 * different keys and neither one implies the other.
 *
 * No root-level .md form: the mirrors are advertised at /self-host/<slug>.md in
 * robots.txt and llms.txt, nothing links them bare, and inventing an alias for
 * a URL nobody requests only adds surface to keep out of the index.
 */
const bareWidth = Math.max(...saas.map((e) => `/${e.slug}/`.length));
const bare = saas
  .flatMap((e) => [
    `${`/${e.slug}/`.padEnd(bareWidth)}  /self-host/${e.slug}/  301`,
    `${`/${e.slug}`.padEnd(bareWidth)}  /self-host/${e.slug}/  301`,
  ])
  .join('\n');

/* Bare category hubs -> their slashed canonical.
 *
 * Same exact-path problem as the product slugs above, one level in: Astro emits
 * /category/<slug>/index.html, so /category/<slug> without the slash matches no
 * asset. Only the bare form needs a rule — the slashed form IS the page.
 *
 * The shelf list is derived, not the raw enum: a category with no live SaaS page
 * gets no route (src/lib/projects.js saasShelves(), mirrored here), and a 301
 * pointing at a hub that was never built is a redirect to a 404. Ordered by
 * CATEGORY_LIST so the file diffs in the same canonical order the site uses.
 */
const liveCategories = new Set(saas.map((e) => e.primary.category));
const hubs = CATEGORY_LIST.filter((c) => liveCategories.has(c.slug)).map((c) => c.slug);

const unknown = [...liveCategories].filter((c) => !CATEGORY_LIST.some((x) => x.slug === c));
if (unknown.length) {
  throw new Error(
    `Project(s) declare categories outside the rubric enum: ${unknown.join(', ')} — ` +
      `add them to src/lib/rubric.js CATEGORIES or fix the data.`
  );
}

const hubWidth = Math.max(...hubs.map((slug) => `/category/${slug}`.length));
const hubRules = hubs
  .map((slug) => `${`/category/${slug}`.padEnd(hubWidth)}  /category/${slug}/  301`)
  .join('\n');

console.log(`# public/_redirects — old project-keyed URLs -> new SaaS-keyed URLs,
# then bare root-level product slugs and bare category hubs -> their canonical page.
# Cloudflare Workers static assets honor this file (same as public/_headers).
# GENERATED: node scripts/generate-redirects.mjs . > public/_redirects
# The validator fails CI when this file drifts from what data/ implies.
# Old project URLs: ${pairs.length} pairs, 3 rules each (slashed, bare, .md mirror).
# Bare product slugs: ${saas.length} slugs, 2 rules each (slashed, bare).
# Bare category hubs: ${hubs.length} slugs, 1 rule each (bare only — the slashed form is the page).
# ${pairs.length * 3 + saas.length * 2 + hubs.length} rules total, all 301.`);
console.log(out);
console.log(`
# ---------------------------------------------------------------------------
# Bare product slugs -> canonical page. GSC crawled /acuity-scheduling as a 404:
# external links drop the /self-host/ prefix, and Workers asset matching is
# exact-path, so both the bare and the slashed form must be named explicitly.
# ---------------------------------------------------------------------------`);
console.log(bare);
console.log(`
# ---------------------------------------------------------------------------
# Bare category hubs -> slashed canonical. Astro emits /category/<slug>/index.html,
# so only the unslashed form needs naming. Derived from the categories that
# actually have a live page, never from the raw enum.
# ---------------------------------------------------------------------------`);
console.log(hubRules);
