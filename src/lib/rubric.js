/* The rubric: the mechanical half of this site's judgement.
 *
 * Plain JavaScript on purpose — no `import.meta.glob`, no `node:` imports, no
 * framework. Both the Astro build (src/lib/projects.js) and the zero-dependency
 * validator (scripts/validate-projects.mjs) import this file, so the twelve
 * categories, the four tiers, the tier rules and the SPDX allowlist exist in
 * exactly one place. A vocabulary that lives in two places drifts; this is the
 * lesson the sibling project paid for.
 *
 * Everything in here is published verbatim on /methodology. Write it as if a
 * skeptical reader on r/selfhosted is reading it, because they are.
 */

/* ------------------------------------------------------------------ *
 * Categories — closed enum (PRD §6.1 + the §13 "Design & whiteboard" row,
 * reconciled during Phase-0 verification: thirteen shelves)
 * ------------------------------------------------------------------ */

/** slug → { label }. The slug is the URL (/category/<slug>/); the label is prose. */
export const CATEGORIES = {
  'photos-media': { label: 'Photos & media' },
  'files-docs': { label: 'Files & docs' },
  'notes-wikis': { label: 'Notes & wikis' },
  'passwords-security': { label: 'Passwords & security' },
  'analytics': { label: 'Analytics' },
  'automation-dev': { label: 'Automation & dev' },
  'monitoring': { label: 'Monitoring' },
  'comms-scheduling': { label: 'Comms & scheduling' },
  'marketing-content': { label: 'Marketing & content' },
  'work-pm': { label: 'Work & PM' },
  'design-whiteboard': { label: 'Design & whiteboard' },
  'money-home': { label: 'Money & home' },
  'ai-tools': { label: 'AI tools' },
};

/** Ordered [{ slug, label }] — the canonical order for hub navigation. */
export const CATEGORY_LIST = Object.entries(CATEGORIES).map(([slug, meta]) => ({
  slug,
  label: meta.label,
}));

export function categoryLabel(slug) {
  return CATEGORIES[slug]?.label ?? null;
}

/* ------------------------------------------------------------------ *
 * Setup tiers — the verdict the domain name asks for (PRD §0, §8)
 * ------------------------------------------------------------------ */

/** slug → badge label. The verdict *word* ("YES", "YES, BUT") lives in site.js. */
export const TIERS = {
  'one-command': 'ONE COMMAND',
  'one-evening': 'ONE EVENING',
  'one-weekend': 'ONE WEEKEND',
  'ongoing-ops': 'ONGOING OPS',
};

/** Easiest → hardest. Sort order for the directory and the 4-dot meter. */
export const TIER_ORDER = ['one-command', 'one-evening', 'one-weekend', 'ongoing-ops'];

export function tierLabel(tier) {
  return TIERS[tier] ?? null;
}

/** 0-indexed position in TIER_ORDER — the 4-dot meter fills `tierRank + 1` dots. */
export function tierRank(tier) {
  return TIER_ORDER.indexOf(tier);
}

/* ------------------------------------------------------------------ *
 * tierFactors — the seven inputs, and nothing else
 * ------------------------------------------------------------------ */

/**
 * The only inputs to the verdict. Each one is a countable or a yes/no that a
 * reviewer can check against the compose file in under a minute — that is the
 * whole point. No "difficulty" field, no vibes, no score anyone can nudge.
 *
 * - containers          how many services the app itself runs. The shared Caddy
 *                       reverse proxy is NOT counted: every install here has one,
 *                       so counting it would add 1 to every project and mean
 *                       nothing.
 * - externalDb          the app needs a database process you operate (Postgres,
 *                       MySQL, MariaDB). Embedded SQLite inside the app's own
 *                       container is false — there is no second thing to run.
 * - needsSmtp           the core loop does not work until outbound mail works.
 *                       Optional niceties (password-reset mail on a single-user
 *                       install) are false, and the page says so out loud.
 * - needsOauth          an outside identity provider must be configured before
 *                       first login.
 * - needsDns            a public hostname has to point at the box. Display only:
 *                       see the note under TIER_RULES.
 * - needsGpu            a GPU is required for the advertised behaviour.
 * - secretsToGenerate   how many secrets are generated on the server during the
 *                       install. Not passwords you choose in a browser later.
 */
export const TIER_FACTOR_KEYS = [
  'containers',
  'externalDb',
  'needsSmtp',
  'needsOauth',
  'needsDns',
  'needsGpu',
  'secretsToGenerate',
];

/** key → 'count' (non-negative integer) | 'bool'. Used by the validator. */
export const TIER_FACTOR_TYPES = {
  containers: 'count',
  externalDb: 'bool',
  needsSmtp: 'bool',
  needsOauth: 'bool',
  needsDns: 'bool',
  needsGpu: 'bool',
  secretsToGenerate: 'count',
};

/* ------------------------------------------------------------------ *
 * The tier rules — ordered, first match wins
 * ------------------------------------------------------------------ */

/**
 * Read top to bottom; the first rule that matches decides the tier. That is the
 * entire algorithm. It is deterministic, it takes seven numbers, and you can run
 * it on a napkin — which is exactly what stops "ONE EVENING" from being an
 * opinion we defend in a comment thread.
 *
 * Two deliberate omissions, stated here because the omissions are the part
 * people argue with:
 *
 *   `needsDns` never changes the tier. Pointing one A record at one IP takes a
 *   couple of minutes, you do it once, and after the first project you already
 *   know how. It belongs on the Before You Start strip ("domain? yes"), not in
 *   the verdict.
 *
 *   Stars, downloads and project age never enter here. Popularity is not
 *   difficulty. Those numbers live on the health card, where they belong.
 *
 * `test` is the rule in prose and `expr` is the rule in code; /methodology
 * renders both from this array, so the published rubric cannot drift from the
 * one the build actually ran.
 */
export const TIER_RULES = [
  {
    id: 1,
    tier: 'ongoing-ops',
    test: 'the app needs a GPU',
    expr: 'needsGpu === true',
    because:
      'A GPU means driver versions, a container runtime that agrees with them, and hardware you keep matched as both move. That is a standing commitment, not an install.',
    match: (f) => f.needsGpu === true,
  },
  {
    id: 2,
    tier: 'ongoing-ops',
    test: 'five or more containers',
    expr: 'containers >= 5',
    because:
      'Five or more services is a stack. On any given morning one of them is unhappy, and you are the only person who is going to notice.',
    match: (f) => f.containers >= 5,
  },
  {
    id: 3,
    tier: 'ongoing-ops',
    test: 'a database, mail, and an identity provider — all three',
    expr: 'externalDb && needsSmtp && needsOauth',
    because:
      'A database you back up, mail that has to actually land in inboxes, and an identity integration that breaks when the provider rotates something. Three separate on-call surfaces bolted to one app.',
    match: (f) => f.externalDb === true && f.needsSmtp === true && f.needsOauth === true,
  },
  {
    id: 4,
    tier: 'one-weekend',
    test: 'four containers',
    expr: 'containers >= 4',
    because:
      'Four services still fits in a weekend, but part of that weekend is spent reading logs to work out which of the four is the one that is wrong.',
    match: (f) => f.containers >= 4,
  },
  {
    id: 5,
    tier: 'one-weekend',
    test: 'a database plus one outside integration',
    expr: 'externalDb && (needsSmtp || needsOauth)',
    because:
      'A database and an outside service fail in completely different ways, and you have to learn both failure modes before you trust the thing with real data. Budget the second day for whichever one surprises you.',
    match: (f) => f.externalDb === true && (f.needsSmtp === true || f.needsOauth === true),
  },
  {
    id: 6,
    tier: 'one-weekend',
    test: 'six or more secrets to generate',
    expr: 'secretsToGenerate >= 6',
    because:
      'Six generated secrets is a configuration surface where one transposed character costs an hour, and the error message will not be about the transposed character.',
    match: (f) => f.secretsToGenerate >= 6,
  },
  {
    id: 7,
    tier: 'one-command',
    test: 'one container, no database, no outside integration, at most one secret',
    expr: 'containers <= 1 && !externalDb && !needsSmtp && !needsOauth && secretsToGenerate <= 1',
    because:
      'Nothing to negotiate with anyone else, nothing to back up separately, at most one secret to generate. This is the case where the compose file honestly is the whole install.',
    match: (f) =>
      f.containers <= 1 &&
      f.externalDb === false &&
      f.needsSmtp === false &&
      f.needsOauth === false &&
      f.secretsToGenerate <= 1,
  },
  {
    id: 8,
    tier: 'one-evening',
    test: 'up to three containers and at most one outside integration',
    expr: 'containers <= 3 && (needsSmtp ? 1 : 0) + (needsOauth ? 1 : 0) <= 1',
    because:
      'You will type more than one command and read a page of documentation, and it will be running before you go to bed.',
    match: (f) =>
      f.containers <= 3 && (f.needsSmtp ? 1 : 0) + (f.needsOauth ? 1 : 0) <= 1,
  },
  {
    id: 9,
    tier: 'one-weekend',
    test: 'everything else',
    expr: 'true',
    because:
      'Whatever the rules above did not catch has enough moving parts that promising you an evening would be a lie. Set aside a weekend.',
    match: () => true,
  },
];

function assertFactors(tierFactors) {
  if (!tierFactors || typeof tierFactors !== 'object' || Array.isArray(tierFactors)) {
    throw new TypeError('deriveTier: tierFactors must be an object');
  }
  for (const key of TIER_FACTOR_KEYS) {
    const value = tierFactors[key];
    if (TIER_FACTOR_TYPES[key] === 'bool') {
      if (typeof value !== 'boolean') {
        throw new TypeError(`deriveTier: tierFactors.${key} must be a boolean`);
      }
    } else if (!Number.isInteger(value) || value < 0) {
      throw new TypeError(`deriveTier: tierFactors.${key} must be a non-negative integer`);
    }
  }
}

/** The rule that fired, with its published rationale. */
export function explainTier(tierFactors) {
  assertFactors(tierFactors);
  return TIER_RULES.find((rule) => rule.match(tierFactors));
}

/**
 * The verdict. Derived from tierFactors on every build — never stored in
 * index.json, so a rubric change re-verdicts the whole catalogue at once and
 * nobody can quietly pin a favourite project to an easier badge.
 */
export function deriveTier(tierFactors) {
  return explainTier(tierFactors).tier;
}

/* ------------------------------------------------------------------ *
 * Time bands
 * ------------------------------------------------------------------ */

/**
 * `timeToRunningMin` is the time to tell a reader to set aside — the planning
 * figure printed in the title and the Before You Start strip. It is not a
 * stopwatch reading: the harness's measured wall clock lives with the
 * verification run, where it can be wrong without changing a published promise.
 * Budgets include the parts people forget — the first backup, and actually
 * reading the candor section.
 *
 * The gap between 10 and 60 minutes is intentional. "One command" means done
 * before your coffee cools; "one evening" means clear an evening. There is no
 * honest badge for 35 minutes, so nothing claims one.
 *
 * maxMinutes `null` means open-ended: ONGOING OPS is measured in the months
 * after the install, not the hour of it.
 */
export const TIER_BANDS = {
  'one-command': { minMinutes: 1, maxMinutes: 10 },
  'one-evening': { minMinutes: 60, maxMinutes: 180 },
  'one-weekend': { minMinutes: 180, maxMinutes: 1440 },
  'ongoing-ops': { minMinutes: 180, maxMinutes: null },
};

export function tierBand(tier) {
  return TIER_BANDS[tier] ?? null;
}

/** Human copy for the band, e.g. "1–3 hours". Used by the badge and the title. */
export function tierBandLabel(tier) {
  const band = tierBand(tier);
  if (!band) return null;
  if (band.maxMinutes === null) return `${Math.round(band.minMinutes / 60)}+ hours, then ongoing`;
  if (band.maxMinutes <= 60) return `under ${band.maxMinutes} minutes`;
  return `${Math.round(band.minMinutes / 60)}–${Math.round(band.maxMinutes / 60)} hours`;
}

/* ------------------------------------------------------------------ *
 * Other closed vocabularies
 * ------------------------------------------------------------------ */

/** Does upstream publish a compose file, and how seriously do they mean it? */
export const OFFICIAL_COMPOSE = {
  'upstream-maintained': 'Upstream ships and maintains a compose file',
  'upstream-example': 'Upstream documents an example compose file',
  'none': 'No upstream compose file — ours is authored from the docs',
};

/** Pricing shapes for a SaaS plan. Matches how the vendors themselves bill. */
export const PRICE_UNITS = ['flat', 'per-seat', 'usage', 'one-time', 'custom'];

/** How much we trust a recorded price. Anything below 'high' shows on the page. */
export const CONFIDENCE_LEVELS = ['high', 'medium', 'low'];

/**
 * Licenses we accept in `index.json`, cross-checked against the SPDX id GitHub
 * reports. Mostly real SPDX identifiers, plus the source-available licenses this
 * catalogue keeps running into, spelled the way their vendors spell them.
 *
 * Two spellings worth knowing apart: `BSL-1.0` is the Boost Software License (a
 * permissive open source license). `BSL-1.1` is how the Business Source License
 * is written in the wild — SPDX calls it `BUSL-1.1`, and it is not open source.
 * Both spellings are listed so a typo cannot silently turn one into the other.
 */
export const SPDX_ALLOWLIST = [
  // Permissive
  'MIT',
  'MIT-0',
  'Apache-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'BSD-4-Clause',
  'ISC',
  'Zlib',
  'Unlicense',
  'CC0-1.0',
  'BSL-1.0',
  'PostgreSQL',
  'Artistic-2.0',
  // Weak copyleft
  'MPL-2.0',
  'LGPL-2.1-only',
  'LGPL-2.1-or-later',
  'LGPL-3.0',
  'LGPL-3.0-only',
  'LGPL-3.0-or-later',
  'EPL-2.0',
  'EUPL-1.2',
  'CDDL-1.0',
  'OSL-3.0',
  // Strong copyleft
  'GPL-2.0-only',
  'GPL-2.0-or-later',
  'GPL-3.0',
  'GPL-3.0-only',
  'GPL-3.0-or-later',
  'AGPL-3.0',
  'AGPL-3.0-only',
  'AGPL-3.0-or-later',
  // Source-available — not open source, and the candor section has to say so
  'BSL-1.1',
  'BUSL-1.1',
  'SSPL-1.0',
  'Elastic-2.0',
  'FSL-1.1',
  'FSL-1.1-ALv2',
  'FSL-1.1-MIT',
];

/** Source-available licenses that oblige a line in `whatYouSignUpFor`. */
export const SOURCE_AVAILABLE_LICENSES = [
  'BSL-1.1',
  'BUSL-1.1',
  'SSPL-1.0',
  'Elastic-2.0',
  'FSL-1.1',
  'FSL-1.1-ALv2',
  'FSL-1.1-MIT',
];

/* ------------------------------------------------------------------ *
 * Content hashing
 * ------------------------------------------------------------------ */

/**
 * Keys excluded from the content hash: the hash itself, and the date the hash
 * governs. Everything else in index.json is content — if it changed, the page
 * changed, and `dateModified` and the sitemap `lastmod` have to move with it.
 */
export const CONTENT_HASH_EXCLUDED = ['contentHash', 'contentUpdatedAt'];

/** Sibling files whose bytes also count as page content. */
export const CONTENT_HASH_FILES = [
  'prompt.md',
  'prompt-chat.md',
  'prompt-local.md',
  'compose.yml',
  'Caddyfile',
  'install.sh',
];

/**
 * Deterministic JSON: object keys sorted, array order preserved (arrays here are
 * ranked — `related`, `citations` — so reordering them IS a content change), no
 * whitespace. Same input, same string, on every machine.
 */
export function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value ?? null);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
}

/**
 * The exact string that gets hashed. `fileDigests` is { filename: sha256 } for
 * the sibling files that exist, so editing a prompt moves the hash too — a
 * prompt rewrite is a content change even when index.json never changed.
 */
export function contentHashInput(entry, fileDigests = {}) {
  const fields = {};
  for (const [key, value] of Object.entries(entry)) {
    if (!CONTENT_HASH_EXCLUDED.includes(key)) fields[key] = value;
  }
  return canonicalJson({ fields, files: fileDigests });
}

/* ------------------------------------------------------------------ *
 * Small shared shapes
 * ------------------------------------------------------------------ */

export const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isIsoDate(value) {
  if (typeof value !== 'string' || !DATE_RE.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export function isHttpUrl(value) {
  return typeof value === 'string' && /^https:\/\/[^\s"'<>]+$/.test(value);
}
