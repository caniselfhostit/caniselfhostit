/* /self-host/<slug>.md — the plain-text mirror of a project page.
 *
 * Two jobs, one file (PRD §4.5, §10.8):
 *   1. What an agent gets when it follows /llms.txt — the same facts as the HTML
 *      page with the chrome, the charts and the navigation removed.
 *   2. The deeplink payload behind the copy block on the page: "give this URL to
 *      Claude Code" only works if the URL returns something a model can act on
 *      without parsing a layout.
 *
 * Everything here is derived from the same two calls the HTML page makes —
 * getAllProjects() for the facts, getProjectFiles() for the raw prompt and
 * artifact text. Nothing is retyped, so the mirror cannot drift from the page it
 * mirrors: change the data, both move together. Sections whose file does not
 * exist are omitted rather than stubbed, because an empty ```bash block reads to
 * a model as "there is no install script", which would be a lie.
 */
import type { APIRoute, GetStaticPaths } from 'astro';
import { SITE } from '../../lib/site.js';
import { getAllProjects, getProject, getProjectFiles } from '../../lib/projects.js';

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
 * The subscription clause. Names every SaaS the project replaces, but prices
 * only the most expensive one — `replaces` is a list of ALTERNATIVES, and adding
 * them together would invent a bill nobody actually pays (src/lib/projects.js
 * makes the same choice for `yearlySaving`).
 */
function swapPhrase(project: any): string | null {
  const replaces = Array.isArray(project.replaces) ? project.replaces.filter(Boolean) : [];
  if (!replaces.length) return null;

  const names = replaces.map((r: any) => r.name ?? r.saas).filter(Boolean);
  const priced = replaces
    .filter((r: any) => typeof r.yearlyCost === 'number' && r.yearlyCost > 0)
    .sort((a: any, b: any) => b.yearlyCost - a.yearlyCost);
  const top = priced[0];

  if (!top) return `replaces ${names.join(', ')}`;

  const seats =
    top.unit === 'per-seat' && top.seatsAssumed > 1 ? `, ${top.seatsAssumed} seats assumed` : '';
  // With one alternative the vendor is already named; with several, say which of
  // them the figure belongs to.
  const plan = names.length > 1 ? `${top.name} ${top.plan}` : `the ${top.plan} plan`;
  return (
    `replaces ${names.join(', ')} — ${money(top.monthlyCost)}/mo you stop paying ` +
    `(${money(top.yearlyCost)}/yr on ${plan}${seats})`
  );
}

/**
 * The one-line answer to the question in the H1: verdict word first, then the
 * four facts a reader decides on. Derived, never authored — the verdict comes
 * from the tier, and the tier comes from seven countable factors.
 */
function answerLine(project: any): string {
  const facts = [`${project.tierLabel} setup`];
  const time = timePhrase(project.timeToRunningMin);
  if (time) facts.push(`${time} to running`);
  const ram = ramPhrase(project.ramMinMB);
  if (ram) facts.push(`${ram} RAM minimum`);
  const swap = swapPhrase(project);
  if (swap) facts.push(swap);
  return `**${project.verdictWord ?? 'YES'}** — ${facts.join(' · ')}.`;
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
  getAllProjects().map((project) => ({ params: { slug: project.slug } }));

export const GET: APIRoute = ({ params }) => {
  const project: any = getProject(String(params.slug));
  if (!project) return new Response('Not found', { status: 404 });

  const files = getProjectFiles(project.slug);
  const pageUrl = `${SITE.origin}/self-host/${project.slug}/`;

  // Provenance in one line, stated the way the page states it. Nothing has been
  // through the harness yet, so the honest form is the pending one; when a run
  // earns the stamp, verified.status carries the date and this line changes with
  // it rather than being edited by hand.
  const provenance =
    project.verified?.status === 'verified' && project.verified?.date
      ? `Verified by the caniselfhostit harness · ${project.verified.date} · source: ${pageUrl}`
      : `Authored from upstream docs · not yet machine-verified · source: ${pageUrl}`;

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

  const lines = [
    `# Can I self-host ${project.name}?`,
    '',
    answerLine(project),
    '',
    provenance,
    '',
    ...sections,
    `How the verdict, the timings and the prices are derived: ${SITE.origin}/methodology/ · Source, data and corrections: ${SITE.repoUrl}`,
    '',
  ];

  return new Response(lines.join('\n'), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
};
