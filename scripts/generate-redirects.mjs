/* Derives public/_redirects from data/. Bare Node — src/lib/projects.js is
 * Vite-only (import.meta.glob), so this reads data/ with node:fs and mirrors
 * getAllSaasPages()'s ordering rules by hand.
 *
 * Usage: node gen-redirects.mjs [repo-root]
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

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
const claims = new Map(); // project -> { saas, rank }
for (const page of saas) {
  page.ranked.forEach((r, rank) => {
    if (r.project === page.slug) return; // no self-redirect
    const prior = claims.get(r.project);
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

// Emit in getAllSaasPages() order, grouped by destination page.
const pairs = [];
for (const page of saas) {
  for (const [project, claim] of claims) {
    if (claim.saas === page.slug) pairs.push([project, page.slug]);
  }
}

const orphans = [...projects.keys()].filter((s) => !claims.has(s));
if (orphans.length) console.error(`ORPHAN PROJECTS (no redirect target): ${orphans.join(', ')}`);

const width = Math.max(...pairs.map(([p]) => `/self-host/${p}.md`.length));
const out = pairs
  .flatMap(([proj, sa]) => [
    `${`/self-host/${proj}/`.padEnd(width)}  /self-host/${sa}/  301`,
    `${`/self-host/${proj}.md`.padEnd(width)}  /self-host/${sa}.md  301`,
  ])
  .join('\n');

console.log(`# ${pairs.length} pairs`);
console.log(out);
