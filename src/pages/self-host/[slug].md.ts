/* /self-host/<saas-slug>.md — the plain-text mirror of an answer page.
 *
 * Keyed by the PAID app, like the HTML page it mirrors: /self-host/miro.md asks
 * "Can I self-host Miro?" and answers with Excalidraw. Old project-keyed URLs
 * 301 here (public/_redirects).
 *
 * Two jobs, one file (PRD §4.5, §10.8):
 *   1. What an agent gets when it follows /llms.txt — the same facts as the HTML
 *      page with the chrome, the charts and the navigation removed.
 *   2. The deeplink payload behind the copy block on the page: "give this URL to
 *      Claude Code" only works if the URL returns something a model can act on
 *      without parsing a layout.
 *
 * Everything here is derived from the same two calls the HTML page makes —
 * getAllSaasPages() for the facts, getProjectFiles() for the raw prompt and
 * artifact text. Nothing is retyped, so the mirror cannot drift from the page it
 * mirrors: change the data, both move together. Sections whose file does not
 * exist are omitted rather than stubbed, because an empty ```bash block reads to
 * a model as "there is no install script", which would be a lie.
 *
 * The install sections belong to the PRIMARY option only. A model handed two
 * competing compose files would have to pick one, and picking is the job this
 * site already did — the runners-up are named under "Also evaluated" so the
 * choice is visible, not hidden.
 */
import type { APIRoute, GetStaticPaths } from 'astro';
import { SITE } from '../../lib/site.js';
import { getAllSaasPages, getSaasPage, getProjectFiles } from '../../lib/projects.js';

/* ------------------------------------------------------------------ *
 * Formatting helpers — all pure, all deterministic
 * ------------------------------------------------------------------ */

/** "$10/mo" but "$5.99/mo": cents only when the price actually has cents. */
function money(amount: number): string {
  return Number.isInteger(amount)
    ? `$${amount.toLocaleString('en-US')}`
    : `$${amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/** Minutes as a reader would say them: "~8 minutes", "~1.5 hours". */
function timePhrase(minutes: number | null | undefined): string | null {
  if (typeof minutes !== 'number' || minutes <= 0) return null;
  if (minutes < 60) return `~${minutes} minutes`;
  return `~${Number((minutes / 60).toFixed(1))} hours`;
}

/** Megabytes as a reader would say them: "512 MB", "1 GB", "1.5 GB". */
function ramPhrase(mb: number | null | undefined): string | null {
  if (typeof mb !== 'number' || mb <= 0) return null;
  if (mb < 1024) return `${mb} MB`;
  return `${Number((mb / 1024).toFixed(1))} GB`;
}

/**
 * The money clause, taken from `page.swap` — the primary project's resolved swap
 * for THIS SaaS, already seat-multiplied and already dated by the data layer. It
 * is the one figure on the page, so the .md and the HTML cannot disagree.
 *
 * The vendor is already named in the H1, so this says "the Starter plan" rather
 * than repeating the brand. A plan with no honest price (a free tier, a
 * quote-only enterprise tier) produces nothing at all rather than a zero.
 */
function swapPhrase(swap: any): string | null {
  if (!swap || typeof swap.monthlyCost !== 'number' || swap.monthlyCost <= 0) return null;
  const seats =
    swap.unit === 'per-seat' && swap.seatsAssumed > 1 ? `, ${swap.seatsAssumed} seats assumed` : '';
  const yearly =
    typeof swap.yearlyCost === 'number' && swap.yearlyCost > 0
      ? ` (${money(swap.yearlyCost)}/yr on the ${swap.plan} plan${seats})`
      : ` (the ${swap.plan} plan${seats})`;
  // A metered plan is a rate, not a bill — the HTML page qualifies it, so the
  // mirror must too or it becomes the less careful of the two.
  const metered = swap.unit === 'usage' ? ' — a metered rate, not a whole bill' : '';
  return `${money(swap.monthlyCost)}/mo you stop paying${yearly}${metered}`;
}

/**
 * The one-line answer to the question in the H1: verdict word, then the name of
 * the thing that answers it, then the four facts a reader decides on. Derived,
 * never authored — the verdict comes from the tier, and the tier comes from
 * seven countable factors.
 */
function answerLine(page: any): string {
  const primary = page.primary;
  const facts = [`${primary.tierLabel} setup`];
  const time = timePhrase(primary.timeToRunningMin);
  if (time) facts.push(`${time} to running`);
  const ram = ramPhrase(primary.ramMinMB);
  if (ram) facts.push(`${ram} RAM minimum`);
  const swap = swapPhrase(page.swap);
  if (swap) facts.push(swap);
  return `**${page.verdictWord ?? 'YES'}** — it's called ${primary.name}. ${facts.join(' · ')}.`;
}

/**
 * A fence long enough to survive its own contents. Prompts are markdown and may
 * one day contain their own ``` blocks; three backticks would then close early
 * and hand a model a truncated prompt.
 */
function fence(lang: string, body: string): string {
  const runs = String(body).match(/`{3,}/g) ?? [];
  const longest = runs.reduce((max, run) => Math.max(max, run.length), 0);
  const ticks = '`'.repeat(Math.max(3, longest + 1));
  return `${ticks}${lang}\n${String(body).replace(/\s+$/, '')}\n${ticks}`;
}

/* ------------------------------------------------------------------ *
 * The route
 * ------------------------------------------------------------------ */

export const getStaticPaths: GetStaticPaths = () =>
  getAllSaasPages().map((page: any) => ({ params: { slug: page.slug } }));

export const GET: APIRoute = ({ params }) => {
  const page: any = getSaasPage(String(params.slug));
  if (!page) return new Response('Not found', { status: 404 });

  const primary = page.primary;
  const files = getProjectFiles(primary.slug);
  const pageUrl = `${SITE.origin}/self-host/${page.slug}/`;

  // Provenance in one line, stated the way the page states it. Nothing has been
  // through the harness yet, so the honest form is the pending one; when a run
  // earns the stamp, verified.status carries the date and this line changes with
  // it rather than being edited by hand. The subject is the replacement — it is
  // the thing that either installed on a clean machine or did not.
  const provenance =
    primary.verified?.status === 'verified' && primary.verified?.date
      ? `${primary.name} verified by the caniselfhostit harness · ${primary.verified.date} · source: ${pageUrl}`
      : `${primary.name} authored from upstream docs · not yet machine-verified · source: ${pageUrl}`;

  const sections: string[] = [];
  const section = (heading: string, lang: string, body: string | null) => {
    if (!body || !String(body).trim()) return;
    sections.push(`## ${heading}`, '', fence(lang, body), '');
  };

  section('Install prompt (Claude Code)', 'text', files.prompt);
  section('Chat fallback', 'text', files.promptChat);
  // Only projects with `localVariant: true` ship this file; the rest skip it.
  section('Local variant (no server, no domain)', 'text', files.promptLocal);
  section('docker-compose.yml', 'yaml', files.compose);
  section('Caddyfile', 'text', files.caddyfile);
  section('install.sh', 'bash', files.installSh);

  // The runners-up. Named, with the reason they lost, because a ranking whose
  // rejects are invisible is indistinguishable from having looked at one thing.
  // The prompts above install the primary and nothing else, so say that here.
  const alternatives: string[] = [];
  const others = Array.isArray(page.options) ? page.options.slice(1) : [];
  if (others.length) {
    alternatives.push(
      '## Also evaluated',
      '',
      `Ranked below ${primary.name} for this swap. The prompts above install ${primary.name} only.`,
      '',
      ...others.map((option: any) => {
        const why = option.rationale ? ` ${option.rationale}` : '';
        return `- **${option.name}** — ${option.tagline}${why}`;
      }),
      ''
    );
  }

  const lines = [
    `# Can I self-host ${page.name}?`,
    '',
    answerLine(page),
    '',
    provenance,
    '',
    ...sections,
    ...alternatives,
    `The page this mirrors: ${pageUrl} · How the verdict, the timings and the prices are derived: ${SITE.origin}/methodology/ · Source, data and corrections: ${SITE.repoUrl}`,
    '',
  ];

  return new Response(lines.join('\n'), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
};
