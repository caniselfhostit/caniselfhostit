# PRD — Can I Self-Host It? (caniselfhostit.com)

**One line:** The directory that gets open source running *for* you. For every SaaS you pay for: a mature open-source replacement, and the exact AI-agent prompts that install it on your own server — designed for someone starting with nothing installed.

**Status:** v3 FINAL · 2026-08-05 · survived a 3-reviewer adversarial pass (requirements / technical / SEO); all open product questions resolved
**Owner:** Jashanpreet Singh (byline: "Reviewed by Jashanpreet Singh" + author page) · Built with Claude Code (Fable planning + verification, Opus execution)

---

## 0. Domain & brand — DECIDED

**Canonical: `caniselfhostit.com`.** `dontvibecodeit.com` 301-redirects as the campaign domain (keeps the viral-thread origin story alive; never two live twins). All brand strings live in `src/lib/site.js`.

**Protagonist: the PAID app — DECIDED 2026-08-05 (owner).** The question is asked about the thing that sends an invoice; the open-source project is the *answer*, not the subject. The directory row is Miro; Excalidraw is what the row resolves to. Canonical pages are keyed by the SaaS slug (§5.1), and the sentence is built in exactly one place — `pageTitle(saasName, tier, replacementName)` in `src/lib/site.js`. Nothing about the rubric changed: the verdict word still comes from the setup tier, now the tier of the top-ranked replacement.

The question-brand does real work:

- **Title formula, derived from the setup tier — never hand-written:** "Can I self-host Miro? **YES** — it's called Excalidraw (2026)". Tier→verdict-word mapping: one-command / one-evening → **YES** · one-weekend → **YES, BUT** plan a weekend · ongoing-ops → **YES, IF** you'll run real ops · editorial stay-on-SaaS calls (Mailcow-class) → **NOT WORTH IT (yet)**. The domain asks; every page answers — question-shaped pages are exactly what AI assistants extract, and the entity they extract is now the one the reader is already paying.
- Hero: "Can I self-host ___?" with the promise line beneath: **"One prompt to get ready. One prompt per app. Every prompt assumes nothing is installed."**
- Mirrors the proven canivibecodeit formula while our design system (§11) keeps the sites visually distinct.

## 1. Thesis & positioning

canivibecodeit.com (Rob Hallam's site — **a different operator; we are an independent, credited sibling, not a network**) asks "can AI build you a replacement?" For a large share of its 976 apps the honest answer is neither *vibe code it* nor *keep paying*: ~950 entries already point at an open-source prior-art repo, and its Plausible entry literally concludes the paid value is hosting, not software. **We are that third verdict, given its own site:** the open source world already built it better — here is exactly how to run it.

Every competitor is a *list* (awesome-selfhosted: 1,341 entries, zero install instructions; selfh.st: the traffic leader, client-rendered with no indexable per-app pages; OpenAlternative: stats theater, zero action; selfhosted.directory: explicitly refuses the install lane). We are the site built around the **verb** — and honestly framed as two prompts, not one ("one prompt from nothing" is the over-claim r/selfhosted would dismantle in an afternoon).

**Credit & outreach:** "Inspired by canivibecodeit.com" on `/about` and `/methodology` with descriptive anchors (no sitewide footer reciprocals). Friendly outreach to Rob Hallam; his thread is the launch channel, and his NOT-REALLY verdicts are our front door.

**Dogfooding, honestly framed:** this deployment runs on Cloudflare + Supabase, so we never claim "this site is self-hosted." The site is **entry #1 in its own directory** — `/self-host/caniselfhostit` carries the prompt to run your own instance on a VPS — plus `/colophon`, the how-this-site-was-built page (the sibling's `/vibecode-this-site` proved it's link-bait that works).

## 2. Users

| Persona | Situation | What they need |
|---|---|---|
| **Subscription-cutter** (primary) | Indie hacker paying $200–600/mo across SaaS; copy-paste comfortable, never administered a server | Savings math, one honest difficulty rating, prompts that work end-to-end |
| **De-Googler** (primary) | Privacy-motivated non-developer; wants photos/notes/files off big platforms | Zero-jargon Prompt Zero, candor sections |
| **Ops-lite agency owner** | 5-person team; per-seat pricing hurts | Per-seat cost math, honest "what you're signing up for" |
| **Homelab hobbyist** (secondary) | Runs Docker already; wants a better catalog | Health data, RAM floors, local variants. Also our credibility jury on r/selfhosted |

## 3. Decisions locked

| Decision | Choice |
|---|---|
| Domain | **caniselfhostit.com** canonical; dontvibecodeit.com 301 |
| Prompt target | **Claude Code first**; tool-agnostic chat fallback secondary |
| Page model | **One canonical page per paid app**, keyed by the SaaS slug; project-keyed URLs 301 into it; the alternatives archetype is absorbed (§5.1–5.2) |
| Launch catalog | **~50 flagship projects, every published prompt verified** |
| Launch features | GitHub stats + charts · outcome reports · PR contributions |
| Stack | **Astro on Cloudflare + Supabase** — prerendered content, nightly rebuilds (§12) |
| Code | **Fully open source, MIT** |
| Prompt environment | **VPS-first** (Hetzner default, DigitalOcean runner-up); `localVariant` projects get a local path |
| Monetization | **None at launch**; free prompts forever. Paid day-2-ops skills later (§14) |
| Byline | **"Reviewed by Jashanpreet Singh"** + author page; harness work machine-attributed |
| Content axes | Migration guides + license/withholding grades **deferred post-launch** — launch is prompts + health + savings |
| Brand | Light-default dual theme, opinionated; DataFast analytics |

## 4. The prompt system (the product)

### 4.1 Prompt Zero — from nothing to ready

One flagship page; every canonical page links it as step 0. Delivers the real end-to-end promise:

1. **Per-OS branches** — Windows (WSL2: BIOS virtualization + reboots, stated honestly), macOS Apple Silicon (arm64 caveats), macOS Intel, Linux. Installs the basics: git, package manager, a terminal the user can find again.
2. **Install Claude Code — with the honest bill.** Anthropic account + paid plan/API billing, floor price stated next to the VPS price: "what this hobby costs per month" is one honest table (agent plan + ~$5 VPS + domain).
3. **Get a VPS — Hetzner default, DigitalOcean runner-up** (signup-friction criterion; KYC/card realities stated; no affiliate links at launch — provable neutrality, and we say so). Sizes mapped to our measured RAM floors.
4. **Credential architecture** — agent runs on the **user's machine**, reaches the VPS over SSH with a fresh keypair. **Honest permission framing:** approving `ssh vps` gives the agent full control *of that server* — we don't pretend that's granular. The real boundary: the agent never controls your laptop, and the server is disposable.
5. **Hardening baseline** in every install: non-root service user, key-only SSH, default-deny firewall, unattended security upgrades, automatic TLS.

### 4.2 The install prompt (per project, Claude Code, primary)

Port the *discipline* of the sibling's `scripts/prompt-style-guide.md` (mechanical shape, numbered rules, worked before/after, verification checklist, curated flag), rewritten for install-and-self-host (their "no Docker at personal scale" rule is our opposite). Our `docs/prompt-style-guide.md` (written **before any prompts**) requires: assumed starting state ("Prompt Zero complete, `ssh vps` works") · pinned image digests + stated update path · one layout (`/srv/<app>/`) · secrets generated on the server, never in prompt/chat · Caddy + auto-TLS · explicit firewall ports · concrete verification URL + expected first-screen string · **first backup before day one ends** (safety is never paywalled) · one honest warning line · explicit out-of-scope. Inherited verbatim: one opinionated path, concrete acceptance criteria, banned marketing words, first person.

**Security standard, validator-enforced:** no `curl | bash` of unpinned scripts, no `:latest`, no standing default credentials, no secrets in prompt text; prompts never instruct the agent to fetch-and-obey arbitrary upstream text (prompt-injection stance on `/methodology`).

### 4.3 Deterministic fallback (per project)

Real reviewable files (§6): `compose.yml`, `Caddyfile`, `install.sh` — downloadable, agent-free. The no-agent path, the thing the harness verifies, the most quotable block for answer engines, insurance against agent nondeterminism. **Provenance rule:** every config authored by us from upstream docs (source URL recorded per artifact), never pasted from a repo — keeps the MIT dataset clean (awesome-selfhosted's CC-BY-SA data = lead list + uncopyrightable facts only, credited as inspiration).

### 4.4 Chat fallback (per project)

"Guide me step by step" for ChatGPT/Claude.ai-only users. Honest about being slower. A tab on the same URL — never its own page.

### 4.5 Agent compatibility: tested, tiered, honest

Per project: `Claude Code — verified <date>` / `works, degraded` / `copy-paste only` — no four-equal-buttons theater. **Deeplink size fix:** 3,400-token prompts break custom-scheme URL limits (silent truncation → half-installed system); deeplinks carry a short instruction pointing at the page's `.md` mirror, not the payload. **Phase-0 spike:** Vaultwarden (easy) + Immich (hard) from clean macOS + Windows via Claude Code — permission-prompt count, wall clock, breakpoints, deeplink round-trip on both OSes. Results feed Prompt Zero and the style guide.

## 5. Information architecture

### 5.1 Routes

| Route | Archetype | Launch? |
|---|---|---|
| `/` | Directory ("The Rack") — one row per paid app | ✅ |
| `/self-host/[saas]/` | **The canonical page.** "Can I self-host Miro?" — the money case, then the ranked replacement(s), all paths as sections on ONE URL | ✅ |
| `/self-host/[project]/` | Legacy project-keyed URL — **301 to the SaaS page that ranks it** | ✅ (redirect only) |
| `/alternatives/[saas]/` | **Absorbed into the canonical page** — no separate archetype (§5.2) | ❌ |
| `/category/[category]/` | Hubs (12) | ✅ |
| `/prompt-zero/` | Zero-setup primer | ✅ |
| `/methodology/` | Rubrics, provenance, AI-authorship policy, verification semantics | ✅ |
| `/weekly/[date]/` | Manual weekly digest (freshness engine) | ✅ wk 1 |
| `/contribute/` | Contribution kit entry | ✅ |
| `/about/`, `/colophon/`, `/terms/`, `/privacy/`, `/security/` | Trust & legal (launch-blocking) | ✅ |
| `/self-host/caniselfhostit/` | Entry #1: this site (excluded from counts/health aggregation). Named exception to the SaaS keying — nobody sells this, so the project keeps the slug | ✅ |
| `/compare/[a]-vs-[b]/`, `/stack/[use-case]/`, `/migrate/[saas]-to-[project]/` | Post-launch, promotion-gated | ❌ |

Trailing-slash canonical, 301 enforced — including every project-keyed URL, which redirects to the SaaS page whose `ranked[]` names it (a project no entity ranks has no URL; the fix is to rank it, not to mint a route). Both keys share the `/self-host/` namespace, so **project slugs and SaaS slugs must stay disjoint** — a collision is a build error, not a redirect. **No per-path sub-routes** (`/self-host/notion/vps` would cannibalize its parent and fail the overlap gate; paths are server-rendered tabs — the whole prompt corpus on one URL is also better AEO). Variant-URL promotion rule: distinct GSC query cluster + ≥400 unique words + ≥3 unique numeric facts not on the parent (plausible future: `/raspberry-pi`, not `/vps`).

### 5.2 The ≥3 rule — now about what a page *shows*, not whether it exists

The rule survived the inversion; its object changed. There is one page per paid app either way, so ≥3 no longer gates a URL into existence — it gates the **ranked list**. ~30 of 50 pairs are 1:1, and a one-item "ranked list" is doorway furniture whether it sits on its own URL or halfway down someone else's.

- **≥3 genuinely evaluated options + comparison table + distinct verdicts** → the page renders the ranked list. Options 2–3 may be honest "evaluated, not yet tested by us" rows (`evaluatedNotTested[]`); that survey content is what makes the section non-thin and unserved.
- **One or two options** → the page **commits to a single pick** and says so in a sentence, rather than dressing one row up as a ranking. The reader gets an answer, not a shortlist of one.

Launch shape: **~12–20** canonical pages carry the ranked list; the rest commit to one pick. Rendering is generic — the template reads `options[]` and branches on its length, so a second option arriving in `data/saas/` changes the page without touching the template.

### 5.3 Canonical page anatomy — SaaS first, then the install

The order is the argument: establish the bill before proposing the work. As built:

breadcrumbs → head (H1 "Can I self-host Miro?", big tier badge answering it, direct answer naming the replacement) → **The Swap band** (pay → run) → **why people pay** (`whyPeoplePay` — one honest paragraph, not a takedown) → **the plan ladder** (`plans[]` as the vendor actually sells it, each row with `checkedOn` + source) → **the answer**: ranked options table (§5.2) or the single pick, each option carrying its rationale → *then the replacement's install content* → **Before You Start strip** (RAM · disk · domain? · ~minutes) → paths as tabs (VPS default · local if `localVariant` · chat) → **Prompt box** (`~3,400 tokens · verified <date> · Claude Code`; copy · open in Claude Code · download install.md; collapsed **"What this prompt will do"** 8-step outline — the top AEO block, and why a beginner isn't pasting blind) → deterministic fallback files → **first-screen screenshot from the verification run** → health card → day-2 (backup/restore/TLS-renewal + basic upgrade command — free forever) → **what you're signing up for** (candor; includes a one-line honest note where enterprise editions withhold features — the formal grading system is deferred) → sibling SaaS pages 3-up → FAQ.

Install content belongs to the **primary** option. Where a page ranks several, the runners-up get their row, their rationale, and a link — not a second prompt box; one page, one recommended path.

**Direct answer under every H1, generated from JSON at build — never hand-written.** One archetype now, two templates: single-pick pages emit running facts about the replacement; ranked pages emit the ranking sentence first. Validator: no two pages emit the same first sentence for the same entity pair.

**Internal linking as data:** hub ↔ children; SaaS page ↔ sibling SaaS pages (`relatedSaasPages()` — "3 preferred, 1 minimum"); ≤40 template links/page; descriptive anchors; orphan check scoped to published pages (`pending` pages keep inbound links, are noindexed + unsitemapped, exempt from the check).

**The trade-off we accepted.** "How to self-host Excalidraw" queries now land on `/self-host/miro/` — through the 301 and through the page's own content, which names Excalidraw in the title, the direct answer, the answer block, and every install section. We are betting that one page carrying both the money case and the install beats two pages splitting them, and that the paid-app query has the higher commercial intent and the larger volume. The cost is real and worth stating: a reader who searched the project by name arrives at a page framed around a product they may not pay for, and the project's own name is no longer carrying a URL. That is reversible. Projects remain first-class entities in the data (§6), so dedicated project pages can come back later **if GSC shows the split earning it** — a distinct query cluster on the project name, judged by the same variant-URL promotion rule in §5.1. Until that evidence exists, adding them back would be two thin pages on a hunch.

## 6. Data model

### 6.1 Repo data (the admin panel)

**Which entity owns a page.** Pages are keyed by the **SaaS entity** (`data/saas/<slug>.json`) — that is the URL, the H1, and the row in the directory. Projects remain the **contribution unit**: a `data/projects/<slug>/` directory is what a PR adds, and it carries the prompts, the deterministic fallback files, the tier factors, and the measured resources. Neither shape changed in the inversion; only which one is the subject of a page did. `getAllSaasPages()` in `src/lib/projects.js` is the join: it hydrates each entity's `ranked[]` into full project objects, takes the top-ranked one as `primary`, resolves the priced `swap` for that pairing, and inherits the page's verdict, tier, category, and `contentUpdatedAt` from `primary`. An entity with an empty `ranked[]` has no page; a project no entity ranks has no page either — the fix is to rank it.

Per-project **directory** (compose files as real reviewable files, not JSON strings):

```
data/projects/<slug>/
  index.json · prompt.md · prompt-chat.md · prompt-local.md (if localVariant)
  compose.yml · Caddyfile · install.sh
data/saas/<slug>.json    # SaaS entity: name, domain, plan ladder + checkedOn + source,
                         # "why people pay" prose, ranked[{project, rationale}],
                         # evaluatedNotTested[{name, repo, note}]
```

`index.json` — every facetable field a validated enum, every field shipped with its validator rule and a process that fills it (the sibling's drift lesson):

```jsonc
{
  "slug": "outline", "name": "Outline", "repo": "outline/outline", "site": "https://…",
  "category": "notes-wikis",   // closed enum, 14 slugs — src/lib/rubric.js CATEGORIES is the
                               // source of truth: photos-media | files-docs | notes-wikis |
                               // passwords-security | analytics | automation-dev | monitoring |
                               // comms-scheduling | marketing-content | work-pm |
                               // design-whiteboard | reading-bookmarks | money-home | ai-tools
  "replaces": [{ "saas": "notion", "plan": "Team", "seatsAssumed": 5 }],  // prices in data/saas
  "tierFactors": { "containers": 3, "externalDb": true, "needsSmtp": true, "needsOauth": false,
                   "needsDns": true, "needsGpu": false, "secretsToGenerate": 4 },
  // setupTier is DERIVED from tierFactors — never stored; validator rejects a stored key
  "resources": { "ramMinMB": 1024, "ramMeasuredMB": 780, "diskGB": 10,
                 "arm64": true, "measuredOn": "2026-08-01" },   // measured by the harness
  "timeToRunningMin": 45,      // validator: must fall inside the derived tier's band
  "license": "BSL-1.1",        // validated SPDX id, cross-checked vs github_stats.license_spdx
  "officialCompose": "upstream-maintained",  // enum: upstream-maintained | upstream-example | none (+url)
  "localVariant": false,       // rule: true when no inbound web exposure needed
  "quote": { "text": "…", "source": "Outline docs", "url": "…", "checkedOn": "…" },
  "citations": [{ "claim": "…", "url": "…" }],   // GEO gate inputs (§10.2)
  "whatYouSignUpFor": ["you own the backups", "…"],
  "sources": { "compose": "https://docs…", "caddy": "…" },     // provenance per artifact
  "related": ["docmost", "bookstack"], "pagePriority": 1,       // rank basis, disclosed on /methodology
  "contentUpdatedAt": "2026-08-05"  // validator hashes content fields; hash moved + date
                                    // unchanged = CI fail; feeds dateModified + sitemap lastmod
}
```

**Deferred fields (post-launch, schema reserved):** `migrations[]` (per-SaaS export/import/what-breaks), `licenseClass` + `featureWithholding` + `withholdingNotes` (the formal openness grades). Both deferred by decision — launch carries the honest one-liner in `whatYouSignUpFor` instead.

### 6.2 Supabase (runtime)

**Access model:** tables in a **non-exposed schema** *and* RLS enabled with zero policies; service-key access only from build/Worker; CI asserts `rowsecurity = true`. (The anon key is public by design; "we only call it server-side" is not an access control.)

Tables: `github_stats` — stars, forks, open issues via GraphQL (REST's count includes PRs), watchers = `subscribers_count` (never `watchers_count`, a verified star-count alias), license_spdx, pushed_at, latest release, contributor count (Link-header trick), `contributors_top_json` (one weekly `/contributors?per_page=100` page — funds the Bus Factor bar; median-issue-close is cut), `commit_weeks_json`, Docker Hub pulls (deploy intent beats bookmarks), `health` enum (derivation rubric published), ETags, `tracked_since`, non-destructive failure columns · `github_stars_daily` — nightly snapshots, history built **forward** (API caps at 40k stars; star-history.com measured hard-down); one-time sampled backfill for the launch cohort; deltas labeled with their **actual** window + "tracked since <date>" · `verification_runs` — status (`verified | pending` only), date, version, host, screenshot ref; **state lives here, not in repo JSON**, so a failed re-test downgrades at the next nightly build without a human commit · `outcome_reports` — worked/partly/failed + agent + OS + note + optional 1–5 rating (future review-markup unlock) · `rate_limits`.

## 7. Deferred axis: migration (post-launch)

Nobody switches because a wiki is running; they switch when their pages are in it. Deferred by decision (verification needs populated source data — real hours). Post-launch: `migrations[]` field + page section + directory filter first; `/migrate/[saas]-to-[project]` pages only on GSC evidence + ≥400 unique words. First candidates: Google Photos→Immich, Notion→Outline, 1Password→Vaultwarden, Drive→Nextcloud.

## 8. Scoring & health

**Setup tier** (the verdict, and the brand's answer): **ONE COMMAND** (<10 min) · **ONE EVENING** (1–3h) · **ONE WEEKEND** · **ONGOING OPS** — mapped to title verdict words per §0; sometimes the honest answer is "NOT WORTH IT (yet)" (Mailcow-class, deferred with reasons on `/methodology`). Derived mechanically from `tierFactors`; rubric public — that's what stops the AI-slop verdict. Outlined badges + 4-dot meter (survives grayscale/color-blindness/OG). Copper never a verdict color.

**Health card** (inline SVG only — 24 sparklines ≈ 743 B gzipped, measured; every chart's numbers also in visible text + `aria-label`): **The Pulse** (52-week commit sparkbar; "commit data unavailable" fallback for cold-stats repos) · **The Ledger** (stars + honest-window delta, forks, contributors, open issues) · **The Bus Factor** (top-contributor concentration — the will-this-exist-in-3-years signal no directory shows). Health colors ≠ tier colors.

**Two verified concepts, named distinctly:** **"Tested by us"** (harness: date, version, host, screenshot) vs **"Reported working by readers"** (outcome counts). `/methodology` defines both.

**Outcome reports:** Worked/Partly/Failed + agent + OS + note + optional rating; CF rate-limit binding + honeypot; counts never faked. Paste-back codes are labeled **"self-reported installs"** — no ceremony pretending they're cryptographic proof; "first 25" is a milestone, not an OKR.

## 9. Verification — earning the stamp

The sibling's cautionary number: `verifiedOneShot` false in all 976 entries. Ours is earned or absent:

- **Harness:** scripted Hetzner API create → run deterministic fallback → assert HTTP health + first-screen string → **Playwright screenshot** (feeds the page's E-E-A-T slot) → destroy. **Labeled sweeper** force-deletes anything older than N hours.
- **TLS at CI scale:** Let's Encrypt caps ~50 certs/domain/week — authoring iterations would blow it by day two. Dedicated test domain + Cloudflare DNS API per-run records + **LE staging**; production issuance reserved for screenshot/manual passes.
- **SMTP:** Hetzner port-25/465/587 unblock requested **day one** (multi-day lead). `needsSmtp: true` verification either asserts real delivery to a catch-all inbox or carries a published carve-out. Prompt Zero notes readers' fresh accounts hit the same block.
- **Honest cost:** VPS-hours ≈ $5 total; the real cost is **~150–500 agent runs and ~2 weeks wall clock**. That's the moat — priced, not hidden.
- **Exception list, published:** GPU-bound (Ollama), meeting-media (Jitsi: two-browsers-hear-each-other, not HTTP 200), mesh-VPN (Headscale: joined client). No stamp the test didn't earn.
- **Stamp:** "TESTED ON A CLEAN MACHINE · <date> · <version> · Ubuntu 24.04 · Claude Code". Failed re-test → `pending` at next nightly build (noindex, unsitemapped, visibly "re-verification in progress", inbound links retained). **Pinning policy:** pinned digests + release-watch that opens a re-test task.
- **Free byproduct:** the run measures idle RAM → `ramMeasuredMB`. Floors are measured, not copied from hosting-vendor pricing.

## 10. SEO & AEO

The per-page defensible asset — tested prompt + verified date + measured RAM + real savings math — survives 2026 scaled-content enforcement *and* gets cited (Princeton GEO: statistics, quotations, cited sources — all three gated below; honest caveat: measured lift was biggest for pages already near position 5, so this compounds ranking, it doesn't replace it).

1. **Phased publishing:** ~50 canonical pages + 12 hubs + core. The ~12–20 ranked-list pages are no longer separate URLs (§5.2), so the launch count lands nearer **70** than the **80–90** planned before the inversion — fewer URLs, each denser. Long tail waits for >80% cohort indexing.
2. **Publish gate v2 (validator-defined):** `uniqueProse` (prompts/code/template chrome stripped) ≥600 words, ≤25% sibling overlap · `promptDelta` ≥N substantive project-specific lines (mandated scaffolding ignored) · ≥4 numeric facts **from typed JSON fields** · ≥1 attributed quote with URL · ≥2 inline outbound citations · ≥1 harness screenshot · first-party tested-on block. Fail → `pending` (unsitemapped, labeled), CI fails only on *silent* inclusion.
3. **Everything in initial HTML** — no AI crawler executes JS (GPTBot at 500M-fetch scale; cross-engine per Vercel/MERJ; Googlebot *does* render JS, so SSR is the AEO requirement and SEO rides along). Prerendering makes this trivially true.
4. **robots.txt:** explicit Allow for GPTBot, OAI-SearchBot, ChatGPT-User, ClaudeBot, Claude-SearchBot, Claude-User, PerplexityBot, Perplexity-User, Google-Extended, Applebot-Extended, Bingbot, CCBot; Disallow `/api/` + param patterns; `Sitemap:` + llms.txt refs. Training crawlers allowed on purpose: corpus presence is distribution for a free directory.
5. **Cloudflare traps, both:** (a) AI-crawler default block from **2026-09-15** — launch before it; opt out at the zone; weekly log verification that AI crawlers get 200s; (b) **Bot Fight Mode / managed challenges off on HTML paths** — a JS challenge is a second silent kill switch.
6. **Structured data, 2026-honest:** BreadcrumbList (earns features) · Article + `dateModified` from `contentUpdatedAt` (substantive changes only) · SoftwareApplication + ItemList + FAQPage + HowTo as **pure AEO plumbing** (SoftwareApplication can't earn its rich result without rating/review; FAQ rich results ended 2026-05; HowTo died 2023) · **no aggregateRating** until real crawlable on-page reviews exist (July 2026 enforcement = domain-level risk); the outcome form's optional rating is that future unlock.
7. **Facet policy:** filters mint **no crawlable URLs** (client state / `#fragment`); 2–4 evidenced combos promoted to real pages ("self-hosted apps that run in 1 GB of RAM"); param patterns Disallowed; never `noindex` + `Disallow` together.
8. **Sitemap index by archetype** with real `lastmod` (GSC coverage per archetype = which template Google rejects, as a chart) · llms.txt + per-page `.md` mirrors (also the deeplink payload) · IndexNow for Bing/Copilot · rolling year in titles · refresh cadence in CI, now two clocks on one page (the money half — plans, prices, `checkedOn` — monthly; the install half quarterly or on upstream major release).
9. **E-E-A-T, honestly attributed:** **"Verified by the caniselfhostit harness · <date> · <host>"** (machine work, linked to methodology) + **"Reviewed by Jashanpreet Singh"** (human, real author page). `/methodology` states the AI policy plainly: drafts are AI-assisted; every published prompt ran end-to-end on a clean machine before the stamp; unverified pages are labeled. The candor *is* the strategy.
10. **Flywheel** (selfh.st's three legs — directory + newsletter + embeddable giveaway): **manual `/weekly/` from week 1** (an hour a week; the legitimate freshness engine) + **README badge at launch** (SVG endpoint + snippet; **opt-in maintainer outreach only** — trademark-safe; every embed is a backlink). Distribution: Rob's thread → Show HN → r/selfhosted + r/homelab (open data, open repo, methodology, no ads) → IndieHackers → Product Hunt. Reddit ≈40% of multi-engine AI citations — genuine answers linking specific pages are the AEO channel.
11. **Sibling relationship:** different operators — not a doorway network. Residual template-similarity risk: materially different page structure (§11), credit links on `/about`/`/methodology` only, never duplicate title/H1 patterns for the same entity, never share screenshots/body copy. Our two own domains: one canonical, one 301. **The inversion tightens this rule rather than relaxing it:** keying pages to the paid app points our H1 at the same entity the sibling's entries are named for, so the separation now rests entirely on the other differentiators — a different question, the tier-derived verdict vocabulary (§0), a materially different page structure (§5.3), and the ≥600-word unique-prose gate (§10.2). Worth re-checking against live sibling pages at Phase 3, not assumed.

## 11. Design — "The Rack"

Light-first **warm paper + copper**, deliberate inverse of canivibecodeit's dark phosphor terminal; dry, imperative voice ("Run it yourself." "You own the backups.").

**From trustmrr (explicitly):** trust through *provenance and freshness*, not color — plain-text provenance lines under data ("GitHub data: public API · pulled 2026-08-05 06:00 UTC · cached 24h"), freshness stamps, attribution on every claim, audience-scale honesty. Its palette is the anti-lesson (stock shadcn achromatic = no identity); its layout grammar we deliberately don't copy.

**From canivibecodeit:** candor as trust, data-dense flex rows on hairlines, two-theme token structure, the grid-collapse mobile pattern.

**Ours:** light `#FBFAF7` paper / `#1A1917` ink / `#A8420B` copper (≈6:1, link-safe) / `#0D4F4C` teal; dark "rack room at night" (`#121110` / `#F2955A`). Copper never a verdict color. **Mono is semantic**: Newsreader serif headings (no directory has a serif), Inter prose 16px/1.7, IBM Plex Mono *only for pasteable literals*. Squarer geometry (2/4/6/10 radius), 1px hairlines, 2px copper rule on machine content, 8px blueprint dot grid, calm easing. Signatures: **The Swap** (pay → run, four scales incl. OG), **Rack Rail** (LED-dot progress gutter; anchor list with JS off), **ports diagram** (browser → :443 caddy → :8080 app → :5432 db → /data — teaches what you're about to run), **TESTED ON A CLEAN MACHINE stamp** (only where earned). Directory columns, paid app first: **#** (editorial `pagePriority`, disclosed) · **App** (the product with the invoice — the row is Miro) · **Replaced by** (the top-ranked project; text names, favicons only where brand policy permits) · **You'd stop paying** (seat assumption inline) · **Setup** (badge + dots). Health sparkbar + ★ moved to the page — they describe the replacement, and a row that leads with the paid app shouldn't rank it on the project's GitHub stars. Filters (no URLs): tier, category, license, official compose, **RAM slider on `ramMinMB`** — all read from the row's top-ranked replacement, which is what the row would install. Accessibility build-checked: AA both themes, focus states, keyboard paths, chart text alternatives, reduced-motion.

## 12. Architecture — prerender + nightly rebuild

The sibling needed SSR for per-second vote counts; our data moves **once a night on a schedule we control**. SSR-on-Workers would have bought 400–700 ms cross-region TTFB, hand-rolled per-colo caching, CPU-limit risk, and a bundle-size cliff — all dissolved by prerendering:

- **Content routes prerendered at build** (canonical SaaS pages/hubs/sitemaps/`.md` mirrors/llms.txt). Build reads `data/saas/` and `data/projects/` via `import.meta.glob` and joins them in `src/lib/projects.js` (no fs on Workers — the sibling's `readdirSync` data layer is a Phase-0 rewrite), plus Supabase at build time.
- **Nightly GitHub Actions cron** (03:15 UTC; drift tolerated; **auto-disables after 60 idle days — monitored**): refresh `github_stats` (GraphQL batched 50/query for scalars; REST only for commit-activity with prime-then-collect 202 handling + contributor tricks; authed ETags; deps.dev fallback + OpenSSF; Docker Hub weekly), snapshot stars, then `repository_dispatch` → Cloudflare deploy hook → fresh build. Numbers ≤24h stale, in plain HTML, provenance line says so.
- **Workers handle only the live:** `/api/outcome` + vote POST, rate-limited via **Cloudflare's rate-limiting binding** (in-colo, atomic — the sibling's SELECT-then-UPDATE limiter is racy over PostgREST). Displayed counts build-baked (crawlers see real numbers); progressive-enhancement fetch freshens client-side.
- **Infra floor stated:** Workers Paid $5/mo + Supabase Free (nightly export of `github_stars_daily` to repo — the one unrebuildable table; the cron doubles as the free-tier keep-alive; Pro $25 later) + domains + DataFast.
- **OG images:** satori/resvg at build (sibling pipeline) — but its content-hash cache is gitignored and inverts on ephemeral CI: commit `public/og/` + `actions/cache` keyed on template hash.
- **Build checklist:** `nodejs_compat` + current `compatibility_date` · env via `astro:env`, no module-scope `process.env` · `sharp`/`resvg` devDependencies only · **delete the sibling's `checkOrigin: false`** (its proxy rationale doesn't exist on Workers; verbatim copy = CSRF hole) · drop `clientIp()`'s `x-forwarded-for` fallback (attacker-controlled; `cf-connecting-ip` is authoritative) · Astro major pinned at scaffold after confirming `@astrojs/cloudflare` compatibility.
- **Reused (MIT, credited):** Base.astro head/JSON-LD/canonical/noindex skeleton (+BreadcrumbList +dateModified it lacks) · OG pipeline (CI-cache fix) · validator/CI/pre-commit patterns · copy/deeplink block (short-instruction payloads) · grid-collapse CSS · theme tokens structure. **Dropped:** sponsor system, PostHog stack, SQLite driver, digest automation. **Day 1:** all brand strings in `src/lib/site.js` (sibling hardcodes its domain across ~22 files — fork tax paid once).

## 13. Launch catalog (~50)

Seeded from the sibling's priorArt graph (~950/976 SaaS→OSS pairs — self-authored, no CC-BY-SA taint), honesty- and verifiability-corrected.

**The table stays project-organized; the presentation inverts.** A project is what gets authored, verified, and maintained, so the build plan counts projects. What ships is the other side of each arrow: the pair "Excalidraw (→ Miro)" below is published as `/self-host/miro/`, titled "Can I self-host Miro?", answered with Excalidraw. Read every row right-to-left to see the URL list. Entries with no paid product to name keep the project as the subject and say why — Navidrome ("for music you own", null savings), Open WebUI + Ollama (editorial, no savings figure), and this site's own entry #1.

| Category | Entries |
|---|---|
| Photos & media | Immich (→ Google Photos) · Jellyfin (→ **Plex Pass**, *not* Netflix — a media server doesn't replace a streaming catalog) · Navidrome (→ null savings, stated: "for music you own") · Audiobookshelf (honest Audible-adjacent framing) |
| Files & docs | Nextcloud (→ Dropbox/Drive) · Paperless-ngx · Stirling PDF (→ Acrobat) · Docuseal (→ DocuSign) |
| Notes & wikis | Outline (→ Notion) · Docmost (→ Notion/Confluence) · BookStack (→ Confluence) · Joplin Server (→ Evernote) |
| Passwords & security | Vaultwarden (→ 1Password/LastPass) · AdGuard Home (→ NextDNS; honest ~$20/yr) · **Authentik (→ Auth0/Okta — ONGOING OPS flagship)** |
| Analytics | Plausible CE · Umami · Matomo |
| Automation & dev | n8n (→ Zapier) · Forgejo (→ GitHub) · Coolify (→ Heroku/Vercel) · Appsmith (→ Retool) · PocketBase (→ Firebase) · Meilisearch (→ Algolia) · **Hoppscotch (→ Postman)** · MinIO (→ S3) |
| Design & whiteboard | **Penpot (→ Figma)** · **Excalidraw (→ Miro — ONE COMMAND showcase)** |
| Monitoring | Uptime Kuma (→ UptimeRobot/Pingdom) · Healthchecks (→ Cronitor) · GlitchTip (→ Sentry) · Gatus (→ Statuspage) · **SigNoz (→ Datadog)** |
| Comms & scheduling | Cal.com (→ Calendly) · Chatwoot (→ Intercom) · Mattermost (→ Slack; Rocket.Chat cut) · Jitsi Meet (→ Zoom — second cohort unless a real two-client assert ships) |
| Marketing & content | Ghost (→ Substack/Medium) · Listmonk (→ Mailchimp) · Postiz (→ Buffer) · Shlink (→ Bitly) · Formbricks (→ Typeform) · Directus (→ Contentful) |
| Work & PM | NocoDB · Baserow (→ Airtable) · Planka · Vikunja (→ Trello/Todoist) · Plane (→ Jira/Linear; enterprise-withholding noted in candor section) · Kimai (→ Toggl) · Invoice Ninja (→ the tweet that started this) · **EspoCRM (→ HubSpot/Salesforce)** |
| Money & home | Actual Budget (→ YNAB) · Firefly III (→ Mint) · Home Assistant (**localVariant-only** — device discovery and USB dongles don't exist on a VPS) · FreshRSS (→ Feedly) · Linkwarden (→ Raindrop) · Wallabag (→ Pocket) |
| AI | **Open WebUI + Ollama as an editorial page** ("when self-hosted LLMs make sense" — no prompt, no savings figure; the one entry where the math inverts, and saying so is the stronger page) · LanguageTool (→ Grammarly) |

Deferred with reasons on `/methodology`: Mailcow (email = the #1 self-hosting failure; "NOT WORTH IT (yet)" until written carefully), Headscale (needs joined-client assert; savings column empty — Tailscale free to 100 devices).

## 14. Build plan

Fable plans and verifies every phase; Opus fleets execute. **Target launch: before 2026-09-15** (Cloudflare AI-crawler flag day).

- **Phase 0 — Foundation (~days 1–2):** scaffold (Astro + `@astrojs/cloudflare` + Supabase + wrangler per §12 checklist) · `site.js` (caniselfhostit brand + dontvibecodeit 301) · tokens + Base + core components · schema + validator + CI + **contribution kit** (CONTRIBUTING, PR/issue templates, `/contribute`) · prompt style guide · **agent execution spike** (§4.5) · **Hetzner SMTP unblock request + harness test-domain DNS** (multi-day lead times — start now).
- **Phase 1 — Product core (~days 3–6):** directory + canonical SaaS pages + hubs (prerendered) · nightly cron + Supabase schema (RLS posture CI-asserted) · health SVGs · OG pipeline with CI cache · Prompt Zero + methodology · outcome API on the rate-limit binding · **10-project pilot end-to-end** (data → prompt → harness → screenshot → gate). Pilot calibrates hours-per-project and hard-gates cohort size.
- **Phase 2 — Content at scale (~days 7–12):** remaining ~40 projects via Opus fleet (research → draft per style guide → validator → harness → Fable review) · SaaS entities + ranked lists where the field is real (§5.2) · project-keyed 301s · gates live · sitemaps, llms.txt, `.md` mirrors, robots.
- **Phase 3 — Launch (~days 13–14):** **add caniselfhostit.com zone to Cloudflare + move nameservers; dontvibecodeit.com 301** (opt-outs are zone settings — they can't precede the zone) · AI-crawler opt-out + **Bot Fight Mode off** + log verification · legal pages · Search Console + DataFast · `/colophon` + `/self-host/caniselfhostit` · first `/weekly/` · badge endpoint + first maintainer outreach · launch (Rob Hallam thread → Show HN → r/selfhosted).
- **Post-launch:** verification-cron automation · migration axis (§7) · openness grades · compare/stack/migrate pages (GSC-gated) · digest automation · paid skills tier, gated on outcome-report data. **Free/paid line:** backup, restore, TLS renewal, basic upgrade command — free forever; paid = guided major-version upgrades with pre-flight checks, host-to-host migrations, troubleshooting. (No "freshness subscription" — it would cannibalize the public trust engine.)

**Explicitly not at launch:** sponsors, affiliates, ads, aggregateRating, compare/stack/migrate URLs, migration fields, openness grades, digest automation (manual page ships), i18n (English-only stated; USD with a note), Jitsi/Headscale/Mailcow stamps.

## 15. Success metrics (leading indicators over vanity targets)

| Ladder | Metric | 90-day | 12-month |
|---|---|---|---|
| Reach | Cohort indexing rate (per archetype, GSC) | >80% | — |
| Reach | Queries with ≥1 impression / avg position on a fixed 100-query panel | 300 · pos <30 | 1,000 · pos <12 |
| Reach | Organic sessions/mo | **300–500** (calibrated: OpenAlternative does ~133 visits/project/mo *at maturity*) | 3,000–6,000 |
| AEO | **Citation panel:** 25 fixed queries monthly vs ChatGPT/Perplexity/Claude — are we named/linked? | ≥3 | ≥12 |
| Growth | Referring domains | 30 | 150 |
| Engagement | Prompt copies + deeplink opens / canonical pageview | >12% | >15% |
| Engagement | Outcome reports | 15–30 | 500 |
| Milestone | Self-reported installs (funnel instrumented per step) | first 10 | 100 |
| Ops | **Hours per verified project** (the survival metric) | trending ↓ | — |
| Trust | Show HN ≥50 pts · no top-3 r/selfhosted "AI slop" comment · /methodology cited by ≥3 third parties | all three | — |

## 16. Risks

| Risk | Mitigation |
|---|---|
| Cloudflare AI-crawler default block (2026-09-15) + Bot Fight Mode | Launch before flag day; both opt-outs at zone setup; weekly log checks |
| Agent capability commoditizes install prompts (12–18 mo) | Moat = verification record + measured floors + outcome corpus, not prompt text; if generic prompts "just work," we're already the verification/day-2 layer (where the paid tier points) |
| Fast follow (selfh.st adds a prompt field) | Harness + outcome data is expensive to copy; a text field isn't. Ship the moat first |
| Security incident traced to a prompt | Validator security standard; pinned digests; hardening baseline; `/security` contact; honest §4.1 framing |
| Trademark complaints | Text names default; logos per brand policy; "not affiliated" line; claims cite vendor pages with dates; takedown path |
| Sibling-template similarity | §10.11 |
| Solo-operator content debt | Pilot-priced cohort; `pending` pages visibly labeled + unsitemapped — debt visible, never silent |
| Supabase free-tier pause / data loss | Cron = keep-alive; `github_stars_daily` exported to repo nightly |

## 17. Remaining open items (non-blocking)

1. GitHub org/repo name (suggestion: `caniselfhostit/caniselfhostit`).
2. Supabase region (nearest audience; affects build reads only).
3. Author-page bio copy + photo (needed at Phase 3, not before).
