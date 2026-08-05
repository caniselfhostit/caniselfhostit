/* The data layer. Reads data/ at BUILD time through Vite's import.meta.glob —
 * there is no filesystem on Workers, so the sibling project's readdirSync loader
 * could not survive the move to Cloudflare (PRD §12).
 *
 * Everything derived is derived here, once: the setup tier from tierFactors, the
 * verdict word from the tier, the SaaS price from the referenced plan. Pages read
 * finished objects and never do arithmetic on raw JSON — that is how the number
 * in a title stays equal to the number in the badge.
 *
 * The rubric itself lives in ./rubric.js as plain JavaScript, because
 * scripts/validate-projects.mjs runs under bare Node and has to enforce exactly
 * the vocabulary this file renders.
 *
 * NOTE: this module is Astro/Vite-only. Node scripts import ./rubric.js instead.
 */
import { TIER_VERDICTS } from './site.js';
import {
  CATEGORIES,
  CATEGORY_LIST,
  TIERS,
  TIER_ORDER,
  categoryLabel,
  deriveTier,
  explainTier,
  tierBand,
  tierBandLabel,
  tierRank,
} from './rubric.js';

export {
  CATEGORIES,
  CATEGORY_LIST,
  TIERS,
  TIER_ORDER,
  categoryLabel,
  deriveTier,
  explainTier,
  tierBand,
  tierBandLabel,
  tierRank,
};

/* ------------------------------------------------------------------ *
 * Raw glob loaders
 * ------------------------------------------------------------------ */

// Vite rewrites these calls at build time into static imports. Under bare Node
// `import.meta.glob` does not exist and the call throws — caught here so the
// error names the actual mistake instead of "not a function".
function globOrExplain(load, what) {
  try {
    return load();
  } catch (err) {
    throw new Error(
      `src/lib/projects.js cannot load ${what} outside the Astro/Vite build. ` +
        `Node scripts should read data/ with node:fs and import src/lib/rubric.js ` +
        `for the shared vocabulary. (${err.message})`
    );
  }
}

// The prompts (prompt.md, prompt-chat.md, prompt-local.md) are deliberately NOT
// loaded here: they are large, and only the project page needs them. Phase 1
// reads them where they are rendered.
const projectModules = () =>
  globOrExplain(
    () => import.meta.glob('/data/projects/*/index.json', { eager: true }),
    'data/projects/*/index.json'
  );

const saasModules = () =>
  globOrExplain(
    () => import.meta.glob('/data/saas/*.json', { eager: true }),
    'data/saas/*.json'
  );

function unwrap(mod) {
  return mod && typeof mod === 'object' && 'default' in mod ? mod.default : mod;
}

/* ------------------------------------------------------------------ *
 * SaaS entities
 * ------------------------------------------------------------------ */

let saasCache;

/** Every SaaS entity, keyed nowhere — sorted by name for stable output. */
export function getAllSaas() {
  if (!saasCache) {
    saasCache = Object.entries(saasModules())
      .map(([path, mod]) => {
        const entity = unwrap(mod);
        const slug = path.split('/').pop().replace(/\.json$/, '');
        if (entity.slug !== slug) {
          throw new Error(`data/saas/${slug}.json declares slug "${entity.slug}"`);
        }
        return entity;
      })
      .sort((a, b) => a.name.localeCompare(b.name));
  }
  return saasCache;
}

export function getSaas(slug) {
  return getAllSaas().find((s) => s.slug === slug) ?? null;
}

export function getSaasPlan(slug, planName) {
  return getSaas(slug)?.plans?.find((p) => p.name === planName) ?? null;
}

/* ------------------------------------------------------------------ *
 * The join: a project's `replaces` entries become priced swaps
 * ------------------------------------------------------------------ */

/**
 * `replaces: [{ saas, plan, seatsAssumed }]` in index.json carries no prices —
 * a price lives in exactly one file (data/saas/<slug>.json) so re-checking it
 * once updates every page that quotes it. This resolves the reference.
 */
function resolveReplaces(entry) {
  return (entry.replaces ?? []).map((ref) => {
    const entity = getSaas(ref.saas);
    const plan = entity?.plans?.find((p) => p.name === ref.plan) ?? null;
    const seats = ref.seatsAssumed ?? 1;
    const priceMonthly = plan?.priceMonthly ?? null;
    // per-seat multiplies by the assumed seats; everything else is already the
    // whole bill. `null` means "no honest number" and the page says that, rather
    // than printing a zero.
    const monthlyCost =
      priceMonthly === null
        ? null
        : plan.unit === 'per-seat'
          ? Number((priceMonthly * seats).toFixed(2))
          : priceMonthly;
    return {
      // --- the contract the UI builds against ---
      saas: ref.saas,
      name: entity?.name ?? ref.saas,
      priceMonthly,
      unit: plan?.unit ?? null,
      // --- context the money band needs ---
      plan: ref.plan,
      seatsAssumed: seats,
      domain: entity?.domain ?? null,
      monthlyCost,
      yearlyCost: monthlyCost === null ? null : Number((monthlyCost * 12).toFixed(2)),
      priceCheckedOn: entity?.pricing?.checkedOn ?? null,
      priceSource: entity?.pricing?.source ?? null,
      priceConfidence: entity?.pricing?.confidence ?? null,
    };
  });
}

/* ------------------------------------------------------------------ *
 * Projects
 * ------------------------------------------------------------------ */

function hydrate(entry, dirSlug) {
  if (entry.slug !== dirSlug) {
    throw new Error(`data/projects/${dirSlug}/index.json declares slug "${entry.slug}"`);
  }
  if (entry.setupTier !== undefined) {
    throw new Error(
      `data/projects/${dirSlug}/index.json stores setupTier; the tier is derived from tierFactors`
    );
  }
  const rule = explainTier(entry.tierFactors);
  const tier = rule.tier;
  const replaces = resolveReplaces(entry);
  // `replaces` lists ALTERNATIVES — a reader pays one of them, not all of them.
  // The headline saving is therefore the largest single yearly cost, never the
  // sum: summing Dropbox + Drive + iCloud would invent a bill nobody has, which
  // is the exact dishonesty this site exists to call out.
  const yearlySaving = replaces.reduce(
    (max, r) => (r.yearlyCost === null ? max : Math.max(max, r.yearlyCost)),
    0
  );

  return {
    // Everything the JSON carries stays available to the page.
    ...entry,

    // --- the contract (see the Phase-0 stub this file replaced) ---
    slug: entry.slug,
    name: entry.name,
    tagline: entry.tagline,
    category: entry.category,
    categoryLabel: categoryLabel(entry.category),
    tier,
    tierLabel: TIERS[tier],
    verdictWord: TIER_VERDICTS[tier],
    replaces,
    ramMinMB: entry.resources?.ramMinMB ?? null,
    timeToRunningMin: entry.timeToRunningMin,
    // Verification state lives in Supabase (PRD §6.2) so a failed re-test can
    // downgrade a page overnight without a human commit. Nothing has been
    // through the harness yet, so everything starts `pending`; Phase 1 overlays
    // the real run at build time.
    verified: { status: 'pending' },

    // --- derived extras the page templates want ---
    tierRule: rule,
    tierRank: tierRank(tier),
    tierBand: tierBand(tier),
    ramMeasuredMB: entry.resources?.ramMeasuredMB ?? null,
    diskGB: entry.resources?.diskGB ?? null,
    arm64: entry.resources?.arm64 ?? null,
    yearlySaving: replaces.length && yearlySaving > 0 ? Number(yearlySaving.toFixed(2)) : null,
  };
}

let projectCache;

/**
 * Every project, ranked: editorial `pagePriority` first (1 = highest, and the
 * basis is disclosed on /methodology), then alphabetically so the order never
 * depends on filesystem enumeration.
 */
export function getAllProjects() {
  if (!projectCache) {
    projectCache = Object.entries(projectModules())
      .map(([path, mod]) => {
        const dirSlug = path.split('/').slice(-2, -1)[0];
        return hydrate(unwrap(mod), dirSlug);
      })
      .sort((a, b) => (a.pagePriority ?? 99) - (b.pagePriority ?? 99) || a.name.localeCompare(b.name));
  }
  return projectCache;
}

export function getProject(slug) {
  return getAllProjects().find((p) => p.slug === slug) ?? null;
}

export function getProjectsByCategory(category) {
  return getAllProjects().filter((p) => p.category === category);
}

export function getProjectsByTier(tier) {
  return getAllProjects().filter((p) => p.tier === tier);
}

/** Categories that have at least one project, in canonical order, with counts. */
export function categoriesInUse() {
  const counts = new Map();
  for (const project of getAllProjects()) {
    counts.set(project.category, (counts.get(project.category) ?? 0) + 1);
  }
  return CATEGORY_LIST.filter((c) => counts.has(c.slug)).map((c) => ({
    ...c,
    count: counts.get(c.slug),
  }));
}

/** Which projects replace this SaaS, best first (§5.2 ranks them by hand). */
export function projectsReplacing(saasSlug) {
  const entity = getSaas(saasSlug);
  const ranked = (entity?.ranked ?? []).map((r) => r.project);
  return getAllProjects()
    .filter((p) => p.replaces.some((r) => r.saas === saasSlug))
    .sort((a, b) => {
      const ai = ranked.indexOf(a.slug);
      const bi = ranked.indexOf(b.slug);
      return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
    });
}

/**
 * Curated `related` first, then same-category siblings — "3 preferred, 1
 * minimum" (PRD §5.3).
 */
export function relatedProjects(project, limit = 3) {
  const rest = getAllProjects().filter((p) => p.slug !== project.slug);
  const curated = (project.related ?? []).map((s) => rest.find((p) => p.slug === s)).filter(Boolean);
  const siblings = rest.filter((p) => p.category === project.category && !curated.includes(p));
  const others = rest.filter((p) => !curated.includes(p) && !siblings.includes(p));
  return [...curated, ...siblings, ...others].slice(0, limit);
}
