/* Open Graph cards, rendered at build time.
 *
 * satori turns a plain object tree (React-element shaped, no React) into an SVG;
 * resvg rasterises it; sharp quantises the PNG down to something you can commit
 * ~1000 of without regret. The card is "The Swap" at 1200x630 (PRD 11): the bill
 * you already pay on the left, the thing you would run instead on the right.
 *
 * One card per SaaS, named for the SaaS slug, because that is what the canonical
 * page is keyed by: /og/miro.png is the preview for /self-host/miro/, and the
 * question it asks is "Can I self-host Miro?" The replacement project answers it
 * — on the right of the swap, in the badge, and in the facts under the headline —
 * but it does not name the file and it is not the protagonist.
 *
 * Three things about this file are load-bearing, and all three are lessons the
 * MIT sibling (canivibecodeit, credited on /about) paid for first:
 *
 *   1. The content-hash cache. Rendering is slow and almost always unnecessary.
 *      .og-cache.json maps each output file to a hash of everything that fed it —
 *      this script's own source, the fonts, the SaaS entity, the index.json of
 *      the project answering for it, and the resolved price. Edit the template
 *      and every card is invalidated at once; add a SaaS entity and exactly one
 *      card renders.
 *
 *   2. The chunked self-respawn. satori and resvg both leak native memory per
 *      render, so one process rendering the whole catalogue eventually OOMs a CI
 *      box. The parent renders the singleton cards, then re-invokes itself once
 *      per slice of pages via OG_RANGE; each child's leaked memory dies with the
 *      child. It is overkill at six pages and exactly right at six hundred.
 *
 *   3. WE COMMIT THE OUTPUT. This is the one place we deliberately diverge from
 *      the sibling, which gitignores both public/og/ and its cache. That works on
 *      a machine with a persistent disk and inverts on ephemeral CI: with nothing
 *      committed, every deploy is a cold cache and re-renders the entire
 *      catalogue. public/og/*.png and .og-cache.json are tracked files here. If
 *      you find yourself adding either to .gitignore, read this paragraph again.
 *
 * Deliberately light theme only. Warm paper is the brand; a card that flipped to
 * the dark palette based on the renderer's mood would just be two brands.
 *
 * Data is read with node:fs, NOT through src/lib/projects.js — that module is
 * Vite-only (import.meta.glob). The shared vocabulary comes from src/lib/rubric.js
 * and src/lib/site.js, which are both plain Node-safe JavaScript, so the tier a
 * card prints is derived by the same rules the page and the validator use.
 */
import satori from 'satori';
import { Resvg } from '@resvg/resvg-js';
import sharp from 'sharp';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import { TIERS, explainTier, tierRank, categoryLabel } from '../src/lib/rubric.js';
import { SITE, TIER_VERDICTS } from '../src/lib/site.js';

const self = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(self), '..');
const outDir = path.join(root, 'public/og');
const cacheFile = path.join(root, '.og-cache.json');
const fontsDir = path.join(root, 'scripts/fonts');

const WIDTH = 1200;
const HEIGHT = 630;

/* ------------------------------------------------------------------ *
 * Tokens — the light half of src/styles/global.css, transcribed
 * ------------------------------------------------------------------ */

// satori has no cascade and no custom properties, so the tokens are copied here
// as literals. They are checked against global.css by eye; if the palette moves,
// it moves in both places, and the template hash re-renders every card.
const C = {
  bg: '#fbfaf7',
  surface: '#ffffff',
  border: '#e4dfd4',
  ink: '#1a1917',
  muted: '#6e695d',
  accent: '#a8420b', // copper — brand and machinery. NEVER a verdict colour.
  grid: 'rgba(26, 25, 23, 0.07)',
};

// The four tiers, and nothing else, carry verdict colour. Copper is not in this
// scale by rule (global.css says so at the top of the file).
const TIER_COLOR = {
  'one-command': '#0e7a55',
  'one-evening': '#2f5fa8',
  'one-weekend': '#b45309',
  'ongoing-ops': '#a32d3a',
};

const FONT = { serif: 'Newsreader', sans: 'Inter', mono: 'IBM Plex Mono' };

/* ------------------------------------------------------------------ *
 * Fonts
 * ------------------------------------------------------------------ */

// Static cuts, on purpose: satori does not instantiate variable axes, so the
// site's variable woff2 files would silently render every weight as Regular.
// Provenance and licences: scripts/fonts/README.md.
const FONT_FILES = [
  { name: FONT.serif, weight: 600, file: 'Newsreader-SemiBold.ttf' },
  { name: FONT.sans, weight: 400, file: 'Inter-Regular.ttf' },
  { name: FONT.sans, weight: 600, file: 'Inter-SemiBold.ttf' },
  { name: FONT.mono, weight: 400, file: 'IBMPlexMono-Regular.ttf' },
];

const fonts = FONT_FILES.map(({ name, weight, file }) => ({
  name,
  weight,
  style: 'normal',
  data: readFileSync(path.join(fontsDir, file)),
}));

/* ------------------------------------------------------------------ *
 * The cache
 * ------------------------------------------------------------------ */

const loadCache = () => {
  try {
    return JSON.parse(readFileSync(cacheFile, 'utf8'));
  } catch {
    return {};
  }
};
// Pretty-printed and key-sorted because this file IS committed — a cache that
// reshuffles its own key order produces a diff on every build and teaches
// reviewers to stop reading it.
const saveCache = (cache) => {
  const sorted = Object.fromEntries(Object.keys(cache).sort().map((k) => [k, cache[k]]));
  writeFileSync(cacheFile, `${JSON.stringify(sorted, null, 2)}\n`);
};

// Everything that is not per-project: this script, the shared vocabulary it
// prints, and the font bytes it prints with. Any change here invalidates every
// card at once — which is the only case where a stale image would otherwise
// survive, because a template edit leaves the data untouched.
const templateHash = (() => {
  const h = createHash('sha256')
    .update(readFileSync(self))
    .update(readFileSync(path.join(root, 'src/lib/rubric.js')))
    .update(readFileSync(path.join(root, 'src/lib/site.js')));
  for (const f of fonts) h.update(f.data);
  return h.digest('hex');
})();

const hashFor = (key) => createHash('sha256').update(templateHash).update(key).digest('hex');

/* ------------------------------------------------------------------ *
 * Data — node:fs, because there is no Vite here
 * ------------------------------------------------------------------ */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readJsonDir(dir, pattern) {
  return readdirSync(dir)
    .filter((f) => pattern.test(f))
    .sort()
    .map((f) => ({ file: path.join(dir, f), json: JSON.parse(readFileSync(path.join(dir, f), 'utf8')) }));
}

function readDataOnce() {
  const projectsDir = path.join(root, 'data/projects');
  const projects = readdirSync(projectsDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => path.join(projectsDir, d.name, 'index.json'))
    .filter((p) => existsSync(p))
    .sort()
    .map((p) => JSON.parse(readFileSync(p, 'utf8')));
  const saas = readJsonDir(path.join(root, 'data/saas'), /\.json$/).map((e) => e.json);
  return { projects, saas };
}

/**
 * data/ is authored by a different workflow that may be mid-write when the build
 * fires. A half-written JSON file is a transient condition, not a bug in the
 * catalogue, so it gets exactly one patient retry before it becomes an error.
 */
async function readData() {
  try {
    return readDataOnce();
  } catch (err) {
    console.warn(`og: could not read data/ (${err.message}) — waiting 60s and retrying once`);
    await sleep(60_000);
    return readDataOnce();
  }
}

const money = (n) =>
  `$${n.toLocaleString('en-US', {
    minimumFractionDigits: Number.isInteger(n) ? 0 : 2,
    maximumFractionDigits: 2,
  })}`;

/**
 * The price join, kept deliberately identical to resolveReplaces() in
 * src/lib/projects.js: a price lives in exactly one file (data/saas/<slug>.json),
 * per-seat plans multiply by the assumed seats, everything else is already the
 * whole bill, and null means "no honest number" rather than zero.
 *
 * Keyed by the SaaS now, so there is nothing to choose between: the bill on the
 * card is the plan THIS entity's primary project says it replaces, and no other.
 * A project that lists several `replaces` alternatives contributes exactly one of
 * them here — the one belonging to the page being rendered.
 */
function resolveSwapFor(entity, project) {
  const ref = (project.replaces ?? []).find((r) => r.saas === entity.slug) ?? null;
  if (!ref) return null;
  const plan = entity.plans?.find((p) => p.name === ref.plan) ?? null;
  const seats = ref.seatsAssumed ?? 1;
  const priceMonthly = plan?.priceMonthly ?? null;
  const monthlyCost =
    priceMonthly === null
      ? null
      : plan.unit === 'per-seat'
        ? Number((priceMonthly * seats).toFixed(2))
        : priceMonthly;
  return { plan: ref.plan, seats, unit: plan?.unit ?? null, monthlyCost };
}

/**
 * The page join, kept in step with getAllSaasPages() in src/lib/projects.js: an
 * entity's `ranked` array is editorial, best first, and the top entry is the one
 * whose verdict the page inherits.
 *
 * The one deliberate difference is what happens to a rank that points at nothing:
 * the Astro build throws, because a page it cannot render is a broken build. Here
 * the rank is skipped and the next one gets the job, because a missing card is
 * worse than a card sourced from the runner-up, and the build has already said
 * its piece. An entity with no runnable rank at all gets no card and gets named.
 */
function saasPages(saas, projects) {
  const bySlug = new Map(projects.map((p) => [p.slug, p]));
  return saas
    .map((entity) => {
      const ranked = (entity.ranked ?? []).map((r) => r.project);
      const primary = ranked.map((slug) => bySlug.get(slug)).find(Boolean) ?? null;
      const missing = ranked.filter((slug) => !bySlug.has(slug));
      return { entity, primary, missing };
    })
    .sort((a, b) => a.entity.slug.localeCompare(b.entity.slug));
}

/* ------------------------------------------------------------------ *
 * The blueprint dot grid
 * ------------------------------------------------------------------ */

// 8px dot grid, same as the site's ::before overlay. Rasterised once per process
// by resvg (already loaded) rather than tiled by satori, because a single
// full-bleed background image is the one path through satori/resvg with no
// pattern-repeat ambiguity in it — the sibling reached the same conclusion and
// shipped a committed background PNG. Ours is generated, so it cannot drift from
// the tokens above.
const backgroundDataUri = (() => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}">
  <defs>
    <pattern id="dots" width="8" height="8" patternUnits="userSpaceOnUse">
      <circle cx="1" cy="1" r="1" fill="${C.grid}"/>
    </pattern>
  </defs>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="${C.bg}"/>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#dots)"/>
</svg>`;
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: WIDTH } }).render().asPng();
  return `data:image/png;base64,${png.toString('base64')}`;
})();

/* ------------------------------------------------------------------ *
 * Element helpers
 * ------------------------------------------------------------------ */

const el = (type, style, children) => ({
  type,
  props: { style, ...(children !== undefined && { children }) },
});
const row = (style, children) => el('div', { display: 'flex', alignItems: 'center', ...style }, children);
const col = (style, children) => el('div', { display: 'flex', flexDirection: 'column', ...style }, children);
const text = (style, content) => el('div', { display: 'flex', ...style }, content);

const serif = (size, color) => ({
  fontFamily: FONT.serif,
  fontWeight: 600,
  fontSize: size,
  color,
  lineHeight: 1.1,
});
const sans = (size, color, weight = 400) => ({
  fontFamily: FONT.sans,
  fontWeight: weight,
  fontSize: size,
  color,
});
const mono = (size, color) => ({ fontFamily: FONT.mono, fontWeight: 400, fontSize: size, color });

/**
 * Shrink-to-fit. satori gives us no text metrics, so this is an average-advance
 * estimate per family — deliberately pessimistic, because a card whose headline
 * is 4px smaller than it could be looks fine and a card whose headline runs off
 * the right edge does not. `max` is the size a typical name renders at.
 */
const fitSize = (chars, avail, max, min, advance) =>
  Math.max(min, Math.min(max, Math.floor(avail / (advance * Math.max(chars, 1)))));

const PAD_X = 72;
const CONTENT_W = WIDTH - PAD_X * 2;

/** The page shell: copper rail, warm paper, dot grid, generous margins. */
function page(children) {
  return col(
    {
      width: WIDTH,
      height: HEIGHT,
      backgroundColor: C.bg,
      backgroundImage: `url(${backgroundDataUri})`,
      backgroundSize: `${WIDTH}px ${HEIGHT}px`,
      fontFamily: FONT.sans,
    },
    [
      // The copper rule that runs across the top of every card. Brand, not verdict.
      el('div', { width: WIDTH, height: 6, backgroundColor: C.accent }),
      col({ flexGrow: 1, padding: `56px ${PAD_X}px 52px` }, children),
    ]
  );
}

/** Copper dot + domain. Bottom-left of every card, same size, same place. */
const wordmark = row({ gap: 11 }, [
  el('div', { width: 10, height: 10, borderRadius: 10, backgroundColor: C.accent }),
  text(sans(22, C.ink, 600), SITE.domain),
]);

/** Small caps-ish mono note, bottom-right. */
const footNote = (label) => text({ ...mono(17, C.muted), letterSpacing: 1.6 }, label.toUpperCase());

const footer = (note) =>
  row(
    {
      justifyContent: 'space-between',
      width: CONTENT_W,
      borderTop: `1px solid ${C.border}`,
      paddingTop: 24,
    },
    [wordmark, footNote(note)]
  );

/**
 * The headline. satori collapses a trailing space between two sibling text
 * nodes, so the word-space after "self-host" is an explicit margin rather than a
 * character — and the question mark gets pulled back a hair, because a serif "?"
 * carries a left sidebearing that reads as a gap at 80px.
 */
const headline = (size, parts) =>
  row(
    { flexWrap: 'nowrap', alignItems: 'baseline' },
    parts.map(([content, color, kind]) =>
      text(
        {
          ...serif(size, color),
          ...(kind === 'lead' && { marginRight: Math.round(size * 0.2) }),
          ...(kind === 'tail' && { marginLeft: -Math.round(size * 0.08) }),
        },
        content
      )
    )
  );

/** Head, verdict, swap — optically centred in the space above the footer. */
const stack = (children) => col({ flexGrow: 1, justifyContent: 'center', paddingBottom: 26 }, children);

/** The 4-dot effort meter — the channel that survives greyscale and a CDN recompress. */
function tierDots(tier, color) {
  const filled = tierRank(tier) + 1;
  return row({ gap: 7 }, [
    ...[1, 2, 3, 4].map((i) =>
      el('div', {
        width: 10,
        height: 10,
        borderRadius: 10,
        ...(i <= filled ? { backgroundColor: color } : { border: `2px solid ${color}`, opacity: 0.32 }),
      })
    ),
  ]);
}

/** Outlined badge: verdict word, tier label, meter. One row, one colour. */
function tierBadge(tier) {
  const color = TIER_COLOR[tier] ?? C.muted;
  const verdict = TIER_VERDICTS[tier] ?? 'YES';
  return row(
    {
      gap: 16,
      border: `2px solid ${color}`,
      borderRadius: 2,
      backgroundColor: C.surface,
      padding: '11px 20px',
    },
    [
      text({ ...mono(22, color), letterSpacing: 1.8 }, `${verdict} · ${TIERS[tier] ?? 'UNRATED'}`),
      tierDots(tier, color),
    ]
  );
}

/** Copper left rule + a stack. The site marks machine content this way. */
const machineBlock = (children) =>
  row({ alignItems: 'stretch' }, [
    el('div', { width: 3, backgroundColor: C.accent, marginRight: 22 }),
    col({ gap: 10, justifyContent: 'center' }, children),
  ]);

const microlabel = (label) => text({ ...mono(14, C.muted), letterSpacing: 2.4 }, label);

/* ------------------------------------------------------------------ *
 * The SaaS card
 * ------------------------------------------------------------------ */

/**
 * The question is asked about the app whose invoice the reader recognises; the
 * project answers it. So the headline names the SaaS, and everything below the
 * headline — verdict, dots, minutes, RAM, containers — comes from the project
 * that would replace it. Nothing on this card is the project's opinion of itself.
 */
function saasCard(entity, project, swap) {
  const { tier } = explainTier(project.tierFactors);

  // "Can I self-host Miro?" — the SaaS name in ink, the frame slightly muted,
  // because the name is the only part a reader is scanning for.
  const lead = 'Can I self-host';
  const headSize = fitSize(lead.length + entity.name.length + 2, CONTENT_W, 64, 34, 0.54);
  const head = headline(headSize, [
    [lead, C.muted, 'lead'],
    [entity.name, C.ink],
    ['?', C.muted, 'tail'],
  ]);

  // The Swap, in mono because it is a literal you could check against an invoice.
  // No price is not a zero: an unpriced plan (quote-only, or one we could not read
  // honestly) drops the money and still shows which way the arrow points.
  const priced = swap && typeof swap.monthlyCost === 'number' && swap.monthlyCost > 0;
  const payingLabel = priced ? `${entity.name} ${money(swap.monthlyCost)}/mo` : entity.name;
  const runLabel = `${project.name} · self-hosted`;
  const swapChars = payingLabel.length + runLabel.length + 4;
  const swapSize = fitSize(swapChars, CONTENT_W - 60, 27, 16, 0.62);

  const swapLine = machineBlock([
    microlabel('THE SWAP'),
    row({ gap: 14 }, [
      text(mono(swapSize, C.ink), payingLabel),
      text(mono(swapSize + 4, C.accent), '→'),
      text(mono(swapSize, C.ink), runLabel),
    ]),
  ]);

  // Facts, not adjectives: what the badge does not already say. All of them are
  // the replacement's, because they describe the install, not the subscription.
  const meta = [
    project.timeToRunningMin ? `~${project.timeToRunningMin} min to running` : null,
    project.resources?.ramMinMB ? `${project.resources.ramMinMB} MB RAM` : null,
    project.tierFactors?.containers === 1
      ? 'one container'
      : project.tierFactors?.containers
        ? `${project.tierFactors.containers} containers`
        : null,
  ]
    .filter(Boolean)
    .join('  ·  ');

  return page([
    stack([
      head,
      row({ marginTop: 34, gap: 22 }, [tierBadge(tier), text(sans(21, C.muted), meta)]),
      el('div', { display: 'flex', marginTop: 40 }, [swapLine]),
    ]),
    footer(categoryLabel(project.category) ?? 'self-hosted'),
  ]);
}

/* ------------------------------------------------------------------ *
 * The home card
 * ------------------------------------------------------------------ */

function homeCard() {
  return page([
    stack([
      headline(80, [
        ['Can I self-host', C.ink, 'lead'],
        ['___', C.accent],
        ['?', C.ink, 'tail'],
      ]),
      text({ ...sans(31, C.muted), marginTop: 30 }, SITE.tagline),
      el('div', { display: 'flex', marginTop: 44 }, [
        machineBlock([microlabel('THE PROMISE'), text(mono(22, C.ink), SITE.promise)]),
      ]),
    ]),
    footer('for every SaaS you pay for'),
  ]);
}

/* ------------------------------------------------------------------ *
 * Render
 * ------------------------------------------------------------------ */

async function render(node, file) {
  const svg = await satori(node, { width: WIDTH, height: HEIGHT, fonts });
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: WIDTH } }).render().asPng();
  // resvg's output is unquantised — roughly 400KB for a card this flat. These
  // cards use a couple of dozen distinct colours plus antialiasing, so a 64-entry
  // palette is visually identical and about 8x smaller. At one committed PNG per
  // project, that difference is the repo's weight.
  const optimized = await sharp(png)
    .png({ palette: true, colors: 64, effort: 10, compressionLevel: 9 })
    .toBuffer();
  writeFileSync(path.join(outDir, file), optimized);
  const kb = (optimized.length / 1024).toFixed(1);
  console.log(`og: ${file} (${kb} KB)`);
  if (optimized.length > 200 * 1024) {
    console.warn(`og: ${file} is ${kb} KB — larger than a social card has any business being`);
  }
}

async function renderCached(node, file, key, cache) {
  const hash = hashFor(key);
  if (cache[file] === hash && existsSync(path.join(outDir, file))) {
    console.log(`og: ${file} (cached)`);
    return false;
  }
  await render(node, file);
  cache[file] = hash;
  return true;
}

/* ------------------------------------------------------------------ *
 * Main — parent renders the singletons, children render slices
 * ------------------------------------------------------------------ */

mkdirSync(outDir, { recursive: true });

const { projects, saas } = await readData();
// Deterministic order, so OG_RANGE slices mean the same thing in parent and child.
// saasPages() sorts by SaaS slug, which is also the output filename.
const all = saasPages(saas, projects);
const pages = all.filter((p) => p.primary);

const range = process.env.OG_RANGE;

if (range) {
  const [start, end] = range.split(':').map(Number);
  const cache = loadCache();
  for (const { entity, primary } of pages.slice(start, end)) {
    const swap = resolveSwapFor(entity, primary);
    // The cache key is the render's whole input surface: the SaaS entity as
    // authored, the project entry that answers for it (contentHash included, so a
    // prompt edit moves it), and the price actually resolved between the two. A
    // plan renamed in data/saas or a re-rank of `ranked` must re-render the card,
    // and neither file alone would have told us.
    const key = `${JSON.stringify(entity)}|${JSON.stringify(primary)}|${JSON.stringify(swap)}`;
    await renderCached(saasCard(entity, primary, swap), `${entity.slug}.png`, key, cache);
  }
  saveCache(cache);
} else {
  // An entity whose whole `ranked` list points at projects that do not exist has
  // no answer to print, so it gets no card — said out loud, because the page it
  // belongs to will fall back to the home card and that is easy to miss.
  for (const { entity, primary, missing } of all) {
    if (!primary) {
      console.warn(`og: no card for ${entity.slug} — ranked project(s) missing: ${missing.join(', ') || 'none ranked'}`);
    } else if (missing.length) {
      console.warn(`og: ${entity.slug} answered by ${primary.slug}; missing rank(s): ${missing.join(', ')}`);
    }
  }

  const cache = loadCache();
  await renderCached(homeCard(), 'home.png', `home|${SITE.tagline}|${SITE.promise}|${SITE.domain}`, cache);
  saveCache(cache);

  const { spawnSync } = await import('node:child_process');
  const CHUNK = 50;
  for (let i = 0; i < pages.length; i += CHUNK) {
    const r = spawnSync(process.execPath, [self], {
      stdio: 'inherit',
      env: { ...process.env, OG_RANGE: `${i}:${i + CHUNK}` },
    });
    if (r.status !== 0) {
      console.error(`og: chunk ${i}:${i + CHUNK} failed (exit ${r.status})`);
      process.exit(1);
    }
  }

  // Cards that no longer have a page behind them. Left in place on purpose — a
  // retired page's URL keeps its social preview until someone decides what the
  // page at that URL should say — but named, so nobody has to wonder. The ten
  // project-slug cards this file used to emit are not in that category: their
  // URLs never existed, so they were deleted outright when the cards were re-keyed.
  const known = new Set(['home.png', ...pages.map(({ entity }) => `${entity.slug}.png`)]);
  const orphans = readdirSync(outDir).filter((f) => f.endsWith('.png') && !known.has(f));
  if (orphans.length) console.log(`og: ${orphans.length} orphaned card(s) left in place: ${orphans.join(', ')}`);

  const bytes = readdirSync(outDir)
    .filter((f) => f.endsWith('.png'))
    .reduce((sum, f) => sum + statSync(path.join(outDir, f)).size, 0);
  console.log(`og: done — ${pages.length + 1} cards, ${(bytes / 1024).toFixed(0)} KB total`);
}
