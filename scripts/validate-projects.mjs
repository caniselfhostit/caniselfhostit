#!/usr/bin/env node
/* The reviewer that never gets tired.
 *
 * Every project arrives as a directory of six files, and every field on a page
 * is a claim someone can check. This script checks the ones a machine can:
 * shape, closed vocabularies, cross-references that must resolve, the derived
 * setup tier agreeing with the stated time, the content hash agreeing with the
 * content, and a security scan over everything a reader is invited to paste into
 * a root shell.
 *
 *   node scripts/validate-projects.mjs          check
 *   node scripts/validate-projects.mjs --fix    rewrite contentHash + contentUpdatedAt
 *
 * Zero dependencies, on purpose: CI runs it without an npm install, so a data PR
 * gets an answer in seconds. The vocabulary comes from src/lib/rubric.js — the
 * same module the Astro build renders from, so the rubric on /methodology and
 * the rubric CI enforces cannot drift apart.
 */
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  CATEGORIES,
  CONFIDENCE_LEVELS,
  CONTENT_HASH_FILES,
  OFFICIAL_COMPOSE,
  PRICE_UNITS,
  SOURCE_AVAILABLE_LICENSES,
  SPDX_ALLOWLIST,
  TIERS,
  contentHashInput,
  deriveTier,
  isHttpUrl,
  isIsoDate,
  TIER_FACTOR_KEYS,
  TIER_FACTOR_TYPES,
  tierBand,
} from '../src/lib/rubric.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PROJECTS_DIR = path.join(ROOT, 'data/projects');
const SAAS_DIR = path.join(ROOT, 'data/saas');
const FIX = process.argv.includes('--fix');
const TODAY = new Date().toISOString().slice(0, 10);

const problems = [];
const notes = [];
const fixed = [];

/* ------------------------------------------------------------------ *
 * Tiny predicates
 * ------------------------------------------------------------------ */

const isStr = (v) => typeof v === 'string' && v.trim() !== '';
const isStrArray = (v) => Array.isArray(v) && v.length > 0 && v.every(isStr);
const isBool = (v) => typeof v === 'boolean';
const isCount = (v) => Number.isInteger(v) && v >= 0;
const isPosInt = (v) => Number.isInteger(v) && v > 0;
const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

/* ------------------------------------------------------------------ *
 * index.json — required shape
 * ------------------------------------------------------------------ */

// Every key every entry carries. A missing one is a PR that copied an old
// template, and the page templates read all of them.
const REQUIRED = {
  slug: isStr,
  name: isStr,
  tagline: isStr,
  repo: (v) => isStr(v) && /^[\w.-]+\/[\w.-]+$/.test(v),
  site: isHttpUrl,
  category: isStr,
  replaces: (v) => Array.isArray(v),
  tierFactors: isObj,
  resources: isObj,
  timeToRunningMin: isPosInt,
  license: isStr,
  officialCompose: isStr,
  localVariant: isBool,
  quote: isObj,
  citations: (v) => Array.isArray(v),
  whatYouSignUpFor: isStrArray,
  sources: isObj,
  related: (v) => Array.isArray(v) && v.every(isStr),
  pagePriority: (v) => Number.isInteger(v) && v >= 1 && v <= 5,
  contentUpdatedAt: isIsoDate,
  contentHash: isStr,
};

// Keys that must never be stored, and why. Storing a derived value is how a
// catalogue quietly stops meaning anything.
const FORBIDDEN = {
  setupTier: 'the setup tier is derived from tierFactors on every build (src/lib/rubric.js)',
  tier: 'the setup tier is derived from tierFactors on every build (src/lib/rubric.js)',
  verified: 'verification state lives in Supabase (PRD §6.2) so a failed re-test can downgrade a page overnight',
  verificationStatus: 'verification state lives in Supabase (PRD §6.2), not in repo JSON',
  verifiedOneShot: 'this site does not carry an unearned verification flag; see /methodology',
  priceMonthly: 'prices live in data/saas/<slug>.json and are joined at build time',
};

const REQUIRED_FILES = ['index.json', 'prompt.md', 'prompt-chat.md', 'compose.yml', 'Caddyfile', 'install.sh'];

/* ------------------------------------------------------------------ *
 * Security scan (PRD §4.2)
 * ------------------------------------------------------------------ */

const SECRET_PATTERNS = [
  [/\bsk-(?:ant-|or-v1-|proj-)?[A-Za-z0-9_-]{16,}/g, 'an API key literal (sk-…)'],
  [/\bghp_[A-Za-z0-9]{20,}/g, 'a GitHub token literal (ghp_…)'],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, 'a GitHub fine-grained token literal'],
  [/\bAKIA[0-9A-Z]{16}\b/g, 'an AWS access key id (AKIA…)'],
  [/-----BEGIN [A-Z][A-Z ]*PRIVATE KEY-----/g, 'a private key block'],
  [/\bxox[baprs]-[A-Za-z0-9-]{10,}/g, 'a Slack token literal'],
  [/\bphc_[A-Za-z0-9]{20,}/g, 'a PostHog project key literal'],
];

// curl/wget straight into a shell. The whole promise of this site is that you can
// read what you are about to run; a pipe into bash is the opposite of that.
const PIPE_TO_SHELL = /\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:ba|z|k|da|fi|c)?sh\b/gi;

// Anything that looks like `PASSWORD=hunter2`.
const CREDENTIAL =
  /\b([A-Za-z0-9_]*(?:password|passwd|pwd|secret|token|api[_-]?key|apikey)[A-Za-z0-9_]*)\s*[:=]\s*("[^"\n]*"|'[^'\n]*'|[^\s,;#}\])]+)/gi;

// Values that are honestly not credentials: shell expansions, angle-bracket
// slots, and the spellings this repo uses for "you fill this in" and
// "install.sh generates this on the server".
function isPlaceholder(raw) {
  const v = String(raw).replace(/^["']|["']$/g, '').trim();
  if (v === '' || v === '-' || v === '""' || v === "''") return true;
  if (/^\$[({A-Za-z_]/.test(v)) return true; // ${VAR}, $(cmd …), $VAR — a shell expansion, not a literal
  if (/^<[^>]*>$/.test(v)) return true; // <the value install.sh printed>
  if (/^`[^`]*`?$/.test(v)) return true; // `generated on the server`
  if (/^(?:CHANGE_?ME|REPLACE_?ME|SET_?ME|YOUR_?[A-Z0-9_]*|TODO|TBD|EXAMPLE|PLACEHOLDER|NONE|null|true|false)[A-Za-z0-9_-]*$/i.test(v)) return true;
  if (/^generated[-_ ]at[-_ ]install$/i.test(v)) return true;
  if (/^[x*.]{3,}$/i.test(v)) return true;
  return false;
}

// In Markdown, only fenced blocks and inline code can be pasted into a shell.
// Prose is prose: "the admin password: read it from the file it wrote" is a
// sentence, not a leaked credential, and a scanner that cannot tell the
// difference is a scanner people learn to ignore.
function executableOnly(md) {
  const parts = [];
  for (const m of md.matchAll(/```[^\n]*\n([\s\S]*?)```/g)) parts.push(m[1]);
  for (const m of md.matchAll(/`([^`\n]+)`/g)) parts.push(m[1]);
  return parts.join('\n');
}

// A tag is "pinned" when it starts with a real version number, or when the image
// is addressed by digest. `:latest` and floating majors like `:2` are neither —
// they mean "whatever upstream pushed since we tested this".
function pinProblem(image) {
  if (/@sha256:[a-f0-9]{64}$/.test(image)) return null;
  const at = image.lastIndexOf(':');
  const slash = image.lastIndexOf('/');
  if (at === -1 || at < slash) return `image "${image}" has no tag (that is :latest with extra steps)`;
  const tag = image.slice(at + 1);
  if (tag === 'latest') return `image "${image}" uses the :latest tag`;
  if (!/^v?\d+\.\d+/.test(tag)) {
    return `image "${image}" is not pinned — the tag must start with a version (1.37.1) or be a @sha256 digest`;
  }
  return null;
}

function scanSecurity(text, isMarkdown, bad) {
  for (const [re, what] of SECRET_PATTERNS) {
    re.lastIndex = 0;
    const hit = re.exec(text);
    if (hit) bad(`security: contains ${what} — "${hit[0].slice(0, 24)}…"`);
  }

  PIPE_TO_SHELL.lastIndex = 0;
  let pipe;
  while ((pipe = PIPE_TO_SHELL.exec(text)) !== null) {
    bad(`security: pipes a download into a shell — "${pipe[0].trim().slice(0, 70)}"`);
  }

  const runnable = isMarkdown ? executableOnly(text) : text;
  CREDENTIAL.lastIndex = 0;
  let cred;
  while ((cred = CREDENTIAL.exec(runnable)) !== null) {
    if (!isPlaceholder(cred[2])) {
      bad(
        `security: hardcoded credential "${cred[1]}=${String(cred[2]).slice(0, 20)}" — ` +
          `secrets are generated on the server or written as CHANGE_ME`
      );
    }
  }

  // Image pinning. Two checks, both chosen because they cannot misfire:
  //   1. every `image:` line in a compose file — the authoritative artifact
  //      (PRD §4.3), where an unpinned tag is the actual defect;
  //   2. the literal string `:latest` anywhere at all, including prose.
  // Nothing tries to parse `docker run` command lines: `-p 3001:3001` and
  // `localhost:8080` look exactly like image references and a scanner that
  // cries wolf gets switched off.
  const images = new Set();
  for (const m of text.matchAll(/^\s*image:\s*["']?([^\s"'#]+)/gm)) images.add(m[1]);
  for (const m of text.matchAll(/(?:^|[\s"'=@/])([a-z0-9][\w.\-/]*:latest)(?![\w.\-])/gim)) images.add(m[1]);
  for (const image of images) {
    const problem = pinProblem(image);
    if (problem) bad(`security: ${problem}`);
  }
}

/* ------------------------------------------------------------------ *
 * SaaS entities — loaded first, because projects reference them
 * ------------------------------------------------------------------ */

const saasBySlug = new Map();

function loadSaas() {
  if (!existsSync(SAAS_DIR)) {
    problems.push('data/saas: directory is missing');
    return;
  }
  const files = readdirSync(SAAS_DIR).filter((f) => f.endsWith('.json'));
  for (const file of files) {
    const rel = `data/saas/${file}`;
    const bad = (msg) => problems.push(`${rel}: ${msg}`);
    let entity;
    try {
      entity = JSON.parse(readFileSync(path.join(SAAS_DIR, file), 'utf8'));
    } catch (err) {
      bad(`invalid JSON — ${err.message}`);
      continue;
    }
    const slug = path.basename(file, '.json');
    saasBySlug.set(slug, entity);

    if (entity.slug !== slug) bad(`slug "${entity.slug}" does not match the filename`);
    if (!isStr(entity.name)) bad('missing "name"');
    if (!isStr(entity.domain) || /^https?:/.test(entity.domain)) {
      bad('"domain" must be a bare hostname, e.g. "1password.com"');
    }
    if (!isStr(entity.whyPeoplePay)) bad('missing "whyPeoplePay" — one or two sentences, in our words');

    if (!Array.isArray(entity.plans) || entity.plans.length === 0) {
      bad('"plans" must be a non-empty plan ladder');
    } else {
      const seen = new Set();
      entity.plans.forEach((plan, i) => {
        if (!isObj(plan)) return bad(`plans[${i}] must be an object`);
        if (!isStr(plan.name)) bad(`plans[${i}] needs a "name"`);
        if (seen.has(plan.name)) bad(`plans[${i}] duplicates the plan name "${plan.name}"`);
        seen.add(plan.name);
        const price = plan.priceMonthly;
        if (!(price === null || (typeof price === 'number' && Number.isFinite(price) && price >= 0))) {
          bad(`plans[${i}] "priceMonthly" must be a number or null (null = quote-only)`);
        }
        if (!PRICE_UNITS.includes(plan.unit)) {
          bad(`plans[${i}] "unit" must be one of ${PRICE_UNITS.join(' | ')}`);
        }
      });
    }

    if (!isObj(entity.pricing)) {
      bad('missing "pricing" — { checkedOn, source, confidence, currency }');
    } else {
      if (!isIsoDate(entity.pricing.checkedOn)) bad('"pricing.checkedOn" must be YYYY-MM-DD');
      if (!isHttpUrl(entity.pricing.source)) bad('"pricing.source" must be the https URL we read the price from');
      if (!CONFIDENCE_LEVELS.includes(entity.pricing.confidence)) {
        bad(`"pricing.confidence" must be one of ${CONFIDENCE_LEVELS.join(' | ')}`);
      }
      if (entity.pricing.currency !== 'USD') bad('"pricing.currency" is USD only at launch (stated on /about)');
      if (entity.pricing.confidence !== 'high' && !isStr(entity.pricing.note)) {
        bad('"pricing.note" is required when confidence is not "high" — say what is uncertain');
      }
    }

    if (!Array.isArray(entity.ranked)) {
      bad('"ranked" must be an array of { project, rationale }');
    } else {
      entity.ranked.forEach((r, i) => {
        if (!isObj(r) || !isStr(r.project) || !isStr(r.rationale)) {
          bad(`ranked[${i}] needs a "project" slug and a "rationale"`);
        }
      });
    }

    if (!Array.isArray(entity.evaluatedNotTested)) {
      bad('"evaluatedNotTested" must be an array (empty is fine)');
    } else {
      entity.evaluatedNotTested.forEach((e, i) => {
        if (!isObj(e) || !isStr(e.name) || !isStr(e.repo) || !isStr(e.note)) {
          bad(`evaluatedNotTested[${i}] needs a "name", "repo" and "note"`);
        }
      });
    }
  }
}

/* ------------------------------------------------------------------ *
 * Projects
 * ------------------------------------------------------------------ */

const projectSlugs = new Set();

function projectDirs() {
  if (!existsSync(PROJECTS_DIR)) {
    problems.push('data/projects: directory is missing');
    return [];
  }
  return readdirSync(PROJECTS_DIR)
    .filter((d) => !d.startsWith('.') && statSync(path.join(PROJECTS_DIR, d)).isDirectory())
    .sort();
}

function checkProject(dir) {
  const abs = path.join(PROJECTS_DIR, dir);
  const rel = `data/projects/${dir}`;
  const bad = (msg) => problems.push(`${rel}: ${msg}`);

  // --- files on disk ---
  for (const file of REQUIRED_FILES) {
    if (!existsSync(path.join(abs, file))) bad(`missing required file ${file}`);
  }
  if (!existsSync(path.join(abs, 'index.json'))) return;

  let entry;
  try {
    entry = JSON.parse(readFileSync(path.join(abs, 'index.json'), 'utf8'));
  } catch (err) {
    bad(`index.json is invalid JSON — ${err.message}`);
    return;
  }
  projectSlugs.add(dir);

  if (entry.slug !== dir) bad(`index.json slug "${entry.slug}" does not match the directory name`);

  for (const [key, ok] of Object.entries(REQUIRED)) {
    if (!(key in entry)) bad(`index.json is missing "${key}"`);
    else if (!ok(entry[key])) bad(`index.json "${key}" has the wrong type or value`);
  }
  for (const [key, why] of Object.entries(FORBIDDEN)) {
    if (key in entry) bad(`index.json stores "${key}" — remove it: ${why}`);
  }

  // --- candor section: 3–5 bullets, as CONTRIBUTING.md promises ---
  if (isStrArray(entry.whatYouSignUpFor)) {
    const n = entry.whatYouSignUpFor.length;
    if (n < 3 || n > 5) {
      bad(`whatYouSignUpFor has ${n} bullet(s); it wants 3–5. Fewer reads as marketing, more reads as a disclaimer.`);
    }
  }

  // --- category ---
  if (!(entry.category in CATEGORIES)) {
    bad(`category "${entry.category}" is not one of the twelve in src/lib/rubric.js`);
  }

  // --- localVariant decides whether prompt-local.md exists ---
  const hasLocal = existsSync(path.join(abs, 'prompt-local.md'));
  if (entry.localVariant === true && !hasLocal) {
    bad('localVariant is true but prompt-local.md is missing');
  }
  if (entry.localVariant === false && hasLocal) {
    bad('prompt-local.md exists but localVariant is false — set it, or delete the file');
  }

  // --- tierFactors → derived tier → time band ---
  let tier = null;
  if (isObj(entry.tierFactors)) {
    for (const key of Object.keys(entry.tierFactors)) {
      if (!TIER_FACTOR_KEYS.includes(key)) bad(`tierFactors has an unknown key "${key}"`);
    }
    let shapeOk = true;
    for (const key of TIER_FACTOR_KEYS) {
      const value = entry.tierFactors[key];
      const wanted = TIER_FACTOR_TYPES[key];
      const ok = wanted === 'bool' ? isBool(value) : isCount(value);
      if (!ok) {
        shapeOk = false;
        bad(`tierFactors.${key} must be ${wanted === 'bool' ? 'a boolean' : 'a non-negative integer'}`);
      }
    }
    if (shapeOk && entry.tierFactors.containers < 1) {
      bad('tierFactors.containers must be at least 1 — every project runs something');
    }
    if (shapeOk) {
      tier = deriveTier(entry.tierFactors);
      const band = tierBand(tier);
      const minutes = entry.timeToRunningMin;
      if (isPosInt(minutes)) {
        const tooLow = minutes < band.minMinutes;
        const tooHigh = band.maxMinutes !== null && minutes > band.maxMinutes;
        if (tooLow || tooHigh) {
          const ceiling = band.maxMinutes === null ? '∞' : band.maxMinutes;
          bad(
            `timeToRunningMin ${minutes} is outside the ${TIERS[tier]} band ` +
              `(${band.minMinutes}–${ceiling} min). Either the minutes are wrong or the tierFactors are.`
          );
        }
      }
    }
  }

  // --- license ---
  if (isStr(entry.license) && !SPDX_ALLOWLIST.includes(entry.license)) {
    bad(`license "${entry.license}" is not in the SPDX allowlist in src/lib/rubric.js`);
  }
  if (SOURCE_AVAILABLE_LICENSES.includes(entry.license)) {
    const said = (entry.whatYouSignUpFor ?? []).some((line) =>
      /source-available|not open source|licen[cs]e/i.test(line)
    );
    if (!said) {
      bad(
        `license ${entry.license} is source-available, so whatYouSignUpFor needs the honest line about it`
      );
    }
  }

  // --- officialCompose ---
  // Claiming upstream publishes a compose file obliges you to link it. The link
  // may live in "officialComposeUrl" (preferred: it is a distinct fact from
  // "the page we authored ours from") or in sources.compose, which is where
  // CONTRIBUTING.md tells contributors to put it. Either satisfies the rule.
  if (!(entry.officialCompose in OFFICIAL_COMPOSE)) {
    bad(`officialCompose "${entry.officialCompose}" is not one of ${Object.keys(OFFICIAL_COMPOSE).join(' | ')}`);
  } else if (entry.officialCompose !== 'none') {
    if (!isHttpUrl(entry.officialComposeUrl) && !isHttpUrl(entry.sources?.compose)) {
      bad(`officialCompose "${entry.officialCompose}" needs the upstream URL, in "officialComposeUrl" or "sources.compose"`);
    }
  } else if (entry.officialComposeUrl != null) {
    bad('officialCompose is "none", so there is no officialComposeUrl to give');
  }

  // --- resources ---
  if (isObj(entry.resources)) {
    const r = entry.resources;
    if (!isPosInt(r.ramMinMB)) bad('resources.ramMinMB must be a positive integer (MB)');
    if (!(r.ramMeasuredMB === null || isPosInt(r.ramMeasuredMB))) {
      bad('resources.ramMeasuredMB must be a positive integer or null until the harness has measured it');
    }
    if (!isPosInt(r.diskGB)) bad('resources.diskGB must be a positive integer (GB)');
    if (!isBool(r.arm64)) bad('resources.arm64 must be a boolean');
    if (!(r.measuredOn === null || isIsoDate(r.measuredOn))) {
      bad('resources.measuredOn must be YYYY-MM-DD or null');
    }
    if (r.ramMeasuredMB !== null && r.measuredOn === null) {
      bad('resources.ramMeasuredMB is set but measuredOn is null — a measurement without a date is a guess');
    }
  }

  // --- replaces → data/saas ---
  if (Array.isArray(entry.replaces)) {
    entry.replaces.forEach((ref, i) => {
      if (!isObj(ref) || !isStr(ref.saas) || !isStr(ref.plan)) {
        return bad(`replaces[${i}] needs a "saas" slug and a "plan" name`);
      }
      if (!isPosInt(ref.seatsAssumed)) bad(`replaces[${i}] needs "seatsAssumed" (a positive integer)`);
      const entity = saasBySlug.get(ref.saas);
      if (!entity) return bad(`replaces[${i}] points at data/saas/${ref.saas}.json, which does not exist`);
      const plan = (entity.plans ?? []).find((p) => p.name === ref.plan);
      if (!plan) {
        bad(
          `replaces[${i}] names plan "${ref.plan}", which is not in data/saas/${ref.saas}.json ` +
            `(has: ${(entity.plans ?? []).map((p) => p.name).join(', ') || 'none'})`
        );
      } else if (plan.unit !== 'per-seat' && ref.seatsAssumed !== 1) {
        bad(`replaces[${i}] assumes ${ref.seatsAssumed} seats but the "${plan.name}" plan is billed ${plan.unit}`);
      }
    });
  }

  // --- quote + citations (the GEO gate inputs, PRD §10.2) ---
  if (isObj(entry.quote)) {
    const q = entry.quote;
    if (!isStr(q.text)) bad('quote.text is required');
    if (!isStr(q.source)) bad('quote.source is required — who said it');
    if (!isHttpUrl(q.url)) bad('quote.url must be the https page we read it on');
    if (!isIsoDate(q.checkedOn)) bad('quote.checkedOn must be YYYY-MM-DD');
    if (isStr(q.text) && q.text.split(/\s+/).length > 40) {
      bad('quote.text is long enough to be a copyright problem — quote a sentence, not a section');
    }
  }
  if (Array.isArray(entry.citations)) {
    if (entry.citations.length < 2) {
      bad('citations needs at least 2 entries — the publish gate wants two inline outbound citations');
    }
    entry.citations.forEach((c, i) => {
      if (!isObj(c) || !isStr(c.claim) || !isHttpUrl(c.url)) {
        bad(`citations[${i}] needs a "claim" and an https "url"`);
      }
    });
  }

  // --- provenance (PRD §4.3: every artifact authored from a named upstream doc) ---
  if (isObj(entry.sources)) {
    if (!isHttpUrl(entry.sources.compose)) bad('sources.compose must be the upstream doc URL the compose file came from');
    if (!isHttpUrl(entry.sources.caddy)) bad('sources.caddy must be the upstream doc URL the Caddyfile came from');
  }

  // --- related ---
  if (Array.isArray(entry.related)) {
    if (entry.related.includes(entry.slug)) bad('related lists the project itself');
    if (new Set(entry.related).size !== entry.related.length) bad('related has duplicates');
  }

  // --- security scan over everything a reader is invited to run ---
  const scanFiles = [...REQUIRED_FILES.filter((f) => f !== 'index.json'), 'prompt-local.md'];
  for (const file of scanFiles) {
    const full = path.join(abs, file);
    if (!existsSync(full)) continue;
    scanSecurity(readFileSync(full, 'utf8'), file.endsWith('.md'), (msg) =>
      problems.push(`${rel}/${file}: ${msg}`)
    );
  }

  // --- content hash ---
  const digests = {};
  for (const file of CONTENT_HASH_FILES) {
    const full = path.join(abs, file);
    if (existsSync(full)) digests[file] = sha256(readFileSync(full));
  }
  const expected = sha256(contentHashInput(entry, digests));
  if (entry.contentHash !== expected) {
    if (FIX) {
      entry.contentHash = expected;
      entry.contentUpdatedAt = TODAY;
      writeFileSync(path.join(abs, 'index.json'), `${JSON.stringify(entry, null, 2)}\n`);
      fixed.push(`${rel}/index.json → contentHash ${expected.slice(0, 12)}…, contentUpdatedAt ${TODAY}`);
    } else {
      bad(
        `contentHash is stale. The content changed but contentUpdatedAt did not move with it, ` +
          `so dateModified and the sitemap lastmod would lie. Expected ${expected} — run ` +
          `\`npm run validate:fix\`.`
      );
    }
  }
}

/* ------------------------------------------------------------------ *
 * Cross-file checks
 * ------------------------------------------------------------------ */

function checkCrossReferences() {
  for (const dir of projectSlugs) {
    const entry = JSON.parse(readFileSync(path.join(PROJECTS_DIR, dir, 'index.json'), 'utf8'));
    for (const slug of entry.related ?? []) {
      if (!projectSlugs.has(slug)) {
        problems.push(`data/projects/${dir}: related "${slug}" has no directory in data/projects/`);
      }
    }
  }
  for (const [slug, entity] of saasBySlug) {
    for (const r of entity.ranked ?? []) {
      if (r?.project && !projectSlugs.has(r.project)) {
        problems.push(`data/saas/${slug}.json: ranked project "${r.project}" has no directory in data/projects/`);
      }
    }
  }

  // §5.2: an /alternatives/<saas>/ page may only exist with three genuinely
  // evaluated options. Reported, not enforced — the pages are Phase 1, and a
  // SaaS entity that is not yet page-worthy is not an error.
  for (const [slug, entity] of saasBySlug) {
    const options = (entity.ranked?.length ?? 0) + (entity.evaluatedNotTested?.length ?? 0);
    if (options < 3) {
      notes.push(
        `data/saas/${slug}.json has ${options} evaluated option(s) — under the §5.2 rule of 3, ` +
          `no /alternatives/${slug}/ page yet; the project page takes the query.`
      );
    }
  }
}

/* ------------------------------------------------------------------ *
 * Run
 * ------------------------------------------------------------------ */

loadSaas();
const dirs = projectDirs();
for (const dir of dirs) checkProject(dir);
checkCrossReferences();

/* public/_redirects must match what the data implies — a re-ranked or renamed
 * slug with a stale 301 silently sends readers to the wrong page, which is the
 * exact failure a redirect exists to prevent. Rule lines only; comments free. */
{
  const { execFileSync } = await import('node:child_process');
  const ruleLines = (text) =>
    text
      .split('\n')
      .filter((l) => l.trim() && !l.trim().startsWith('#'))
      .map((l) => l.trim().replace(/\s+/g, ' '))
      .sort();
  try {
    const generated = execFileSync('node', ['scripts/generate-redirects.mjs', '.'], {
      encoding: 'utf8',
    });
    const current = readFileSync('public/_redirects', 'utf8');
    const want = ruleLines(generated);
    const have = ruleLines(current);
    if (JSON.stringify(want) !== JSON.stringify(have)) {
      problems.push(
        `public/_redirects is out of sync with data/ — run: node scripts/generate-redirects.mjs . (rules differ: expected ${want.length}, found ${have.length})`
      );
    }
  } catch (err) {
    problems.push(`redirect drift check failed to run: ${err.message}`);
  }
}

if (fixed.length) {
  console.log(`↻ rewrote ${fixed.length} file(s):`);
  fixed.forEach((f) => console.log(`  ${f}`));
}
if (notes.length) {
  console.log(`\nNotes (not failures):`);
  notes.forEach((n) => console.log(`  ${n}`));
}
if (problems.length) {
  console.error(
    `\n✗ ${problems.length} problem(s) across ${dirs.length} project(s) and ${saasBySlug.size} SaaS entit${saasBySlug.size === 1 ? 'y' : 'ies'}:\n`
  );
  problems.forEach((p) => console.error(`  ${p}`));
  process.exit(1);
}

console.log(
  `\n✓ ${dirs.length} project(s) and ${saasBySlug.size} SaaS entit${saasBySlug.size === 1 ? 'y' : 'ies'} pass`
);
