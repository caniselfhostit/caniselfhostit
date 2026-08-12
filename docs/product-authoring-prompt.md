# Prompt: authoring and repairing product entries for caniselfhostit

You are an authoring agent for this catalog. You have two jobs, in order:

1. **Repair the 10-product batch currently sitting uncommitted in the working tree** (adguard-home, changedetection, filebrowser, gitea, gotify, it-tools, jellyfin, meilisearch, netdata, ntfy). Every one of them failed independent audit. Part 2 lists the confirmed defects per product.
2. **Author future products with the process in Part 1** so they do not fail the same way.

Work product-by-product. Never declare a product done until it has passed the verification pass described in section 1.7.

---

## Part 0 — Why the previous batch failed (read this first, it is the whole lesson)

The previous process passed `npm run validate` on all 10 entries and still failed audit 10 out of 10, each with at least one install-breaking or security-critical defect. Three patterns caused everything:

1. **It optimized to the validator.** `npm run validate` checks schemas, compose parity, credential scanning, and tier math. It cannot check whether the install works, whether the security actually closes, whether the backup archives the right directory, or whether a claim is true. Passing it is a floor, not a bar.
2. **It never traced the actual software.** It reused template text ("finish first-run setup or sign-in", "anyone who can reach the hostname may finish setup first", a secrets step) on products where that text is fiction — products with no login, no wizard, no secrets. It invented an env var (`PASSWORD` for changedetection) that upstream does not have. It never checked which directories the container writes, so backups tar an empty `data/` dir that nothing mounts.
3. **It stamped `checkedOn` dates on facts it never checked.** Three entries carry quotes or prices that a live read on the stamped day would have disproven (a retired tagline, pre-2025 Plex pricing, an EOL banner at the top of the README). This is the worst defect class in this catalog: fabricated provenance.

The fix is not a better template. It is (a) a research step that reads the upstream reality at the pinned version, and (b) an **independent verification pass** on every entry before it ships. Every defect listed in Part 2 was caught by a verifier running the battery in section 1.6 — none were caught by the validator.

---

## Part 1 — The correct process for one product

### 1.0 Read the gold standard before writing anything

Read these committed entries in full; they are the canon your files must match in structure, tone, and depth:

- `data/projects/shlink/` — the canonical Docker block, frame lines, tar form.
- `data/projects/gatus/` — lean single-container entry; public-by-design consent framing.
- `data/projects/miniflux/` — recent entry with a no-registration security model done right.
- `data/projects/kener/` — image-identity audit, admin-closure asserts.
- `docs/prompt-style-guide.md` — the 11-point checklist. Every rule in it is enforced.

### 1.1 Pre-flight gates — kill a bad slot before writing 9 files

Run all of these before authoring. Any failure means bail and say why; do not "make it work".

1. **License**: `gh api repos/<org>/<repo> --jq .license.spdx_id`. If it returns `NOASSERTION`, **read the LICENSE file(s) at the pinned tag** — NOASSERTION usually means an ee/ or premium/ carve-out (record the core license, disclose the carve-out in `whatYouSignUpFor`, chatwoot-style). If the license is BUSL-1.1, Elastic-2.0, or FSL-1.1-ALv2 (source-available list), the candor line in `whatYouSignUpFor` is mandatory ("Source-available, not open source…"). If the license is not on the allowlist in `src/lib/rubric.js`, bail.
2. **Upstream health**: `gh api repos/<org>/<repo> --jq '{archived, pushed_at}'`. `archived: true` is disqualifying, full stop (precedent: Astuto, File Browser). Also open the README in a browser or raw-fetch it and look for EOL/maintenance banners — File Browser's formal archive announcement sat at the top of its README and the previous process missed it on the day it claimed to have checked.
3. **Image pinnability**: every image in the stack must have a version-identity tag (semver, calver, or documented release-identity like `RELEASE.`/datestamps) whose digest you fetch yourself from the registry (token + manifest API against `registry-1.docker.io` or `ghcr.io`, manifest-list Accept headers). `latest`-only or `sha-<commit>`-only images are disqualifying. Pin the **newest stable**; if you deliberately pin an older line (LTS), record the reasoning in block 9 of every prompt.
4. **Repo-slug correctness**: confirm you are reading the repo the image is actually built from (renames and squatted orgs have poisoned past reads: `ente-io/ente`→`ente/ente`, `haiwen/seafile` is the desktop client, GlitchTip's real mirror is `burke-software/GlitchTip`).
5. **Port**: allocate from the ledger. Committed catalog occupies 8083–8181, 8228, 8268, 8977; the repair batch occupies 8200–8209 (keep those). Next free for NEW products: 8182–8199, then 8210+. Grep the tree for your port before using it.

### 1.2 Research protocol — every claim from a source you actually read

- Read upstream's install docs, configuration reference, and Docker packaging **at the pinned tag**, not master.
- **Verify every env var you set exists** in the configuration reference. If you cannot find it documented or in source, it does not go in the compose file.
- **Trace first-boot behavior**: what port does the app serve *after* setup (AdGuard Home moves from 3000 to 80)? Does it print a generated password to the container logs (File Browser)? Is there a wizard, a first-registered-user-becomes-admin rule, open registration, or no accounts at all? Your blocks 3 and 7 must describe *this product's* reality, not the template's.
- **Trace state**: which container paths does the app write? Your volume mounts, your backup, and your restore must agree with that list. If the image declares `VOLUME` dirs, mount them explicitly or state why not.
- **Quotes**: `index.json.quote` must appear verbatim (≤40 words) on the cited page. Fetch the page and grep it.
- **Pricing**: read the SaaS pricing page live. If it is JS-rendered and you cannot read it, record what secondary sources agree on, set `pricing.confidence` to medium or low, and say exactly what you could not read in `pricing.note`. Never record remembered prices at high confidence.
- **`checkedOn` / `contentUpdatedAt` integrity**: stamp the real date (`date +%F`) only on facts you fetched that day. A stamped date on an unfetched fact is fabrication and fails the entry outright.

### 1.3 The 9-file contract

`data/saas/<anchor>.json` plus `data/projects/<slug>/` containing exactly: `index.json`, `prompt.md`, `prompt-chat.md`, `prompt-local.md`, `compose.yml`, `compose.local.yml`, `Caddyfile`, `install.sh`.

- `index.json`: never store `setupTier`, `verified`, or `priceMonthly` (forbidden keys). Tier is derived from `tierFactors` — compute it with `node` against `src/lib/rubric.js` and record `timeToRunningMin` inside the band (one-command 1–10, one-evening 60–180, one-weekend 180–1440, ongoing-ops 180+). `tierFactors.containers` must equal the number of services in `compose.yml`. ≥2 citations, `whatYouSignUpFor` 3–5 bullets, `officialCompose` labeled honestly (`upstream-maintained` vs `upstream-example` — a docs snippet is an example).
- Every config carries the `NOT YET VERIFIED` line — no harness has run these.

### 1.4 The three prompts — structure and style (all hard rules)

- **Byte bands**: `prompt.md` 10,000–15,000 bytes (hard ceiling 16,500). `prompt-chat.md` 1.1–1.6× of prompt.md. `prompt-local.md` 9,000–15,000. The previous batch shipped at ~6.5k / 0.30× / ~6.8k — half depth with a vestigial chat path. The bands are not padding targets: fill them with product-specific substance (failure modes, upgrade path, the product's central handoff).
- **Eleven `## N.` blocks in every path**, chat included.
- **Each path is standalone.** The chat path embeds the full compose and Caddy heredocs **byte-identical** to the standalone files. It must never say "copy the file from the repository path…" or "follow the secrets step in prompt.md" — the chat reader has no repo and no other file.
- **Frame lines**: the opening frame lines of each path are byte-identical to the shipped corpus (diff against shlink). The local path's canonical Docker-install block is copied byte-identical from a shipped entry (diff against gatus), never paraphrased.
- **STOP grammar**: every STOP carries the barrier sentence **"Do not continue until they confirm."** (extended forms like "…until they confirm they see X." are fine; "Wait until they confirm" is not). One unbroken line — never split across a wrap.
- **Banned words**: seamless, powerful, beautiful, delightful, robust, blazing, intuitive, production-ready, enterprise-grade, battle-tested, simply, just. No em dashes anywhere.
- Block 10 is the first-person failure-modes warning block (house voice), not a single sentence.
- Local path: no `<DOMAIN>`, no ssh (beyond the frame's own line), block 11 opens with the three fixed imperatives, block 6 includes the loopback self-assert `grep -c '"127.0.0.1:'` (the quoted published-port form, so healthcheck IPs don't inflate the count).

### 1.5 Correctness rules — the ones the previous batch broke

- **Substitution commands must run.** The house form for domain substitution is what `install.sh` in shipped entries uses. Never emit `sed "s|<DOMAIN>|'"$VAR"'|g"` — it writes literal quotes into the Caddyfile and `caddy validate` fails. Every variable a command uses must be set by an earlier step. Execute your own commands mentally line by line; better, in a scratch shell.
- **Asserts print their evidence and stop.** Never `grep -c … || true` — an assert that cannot fail is not an assert. On mismatch: print received value, name the likely cause, stop.
- **Security closure is mandatory (the first-claimant rule).** Whatever the product's auth reality is — wizard, first-signup, env-seeded admin, CLI-created users, or no auth at all — the entry must (a) state it truthfully, (b) close the open door (disable registration, set deny-all, rotate defaults, or add Caddy `basic_auth` / gatus-style public-by-design consent framing), and (c) **assert the closure with printed evidence** (a 401/403/404, a grep count of the signup marker, a settings read). Generated credentials go to mode-600 `.env`, are never printed, and the reader is told where to read them at a STOP.
- **Backups archive the real state.** Tar exactly: the directories your compose actually mounts, `.env`, `compose.yml`, and the **live** `/etc/caddy/Caddyfile` via the two-`-C` form: `tar -czf <archive> -C /srv/<app> compose.yml .env <data-dirs> -C /etc/caddy Caddyfile`. Local path omits the Caddy part. Never `|| true` on a backup. **Restore steps are mandatory on every path** and must work cold (ordering vs healthchecks; `.env` restored before first start).
- **Secrets**: `openssl rand` count in every path equals `tierFactors.secretsToGenerate`. Products with zero secrets get zero secret steps — delete the template block, don't leave it lying.
- **compose.local.yml is not compose.yml with a renamed port**: base URLs, hostnames, and healthchecks must match each path's reality (the previous batch shipped `NTFY_BASE_URL: http://localhost:8200` in the VPS compose).

### 1.6 Self-check battery — run all of it before calling a product done

```bash
wc -c data/projects/<slug>/prompt*.md                     # bands: 10–15k / 1.1–1.6x / 9–15k
grep -c '^## ' data/projects/<slug>/prompt*.md             # 11 / 11 / 11
# heredoc parity: extract each compose/Caddy heredoc and diff against the standalone file — byte-identical
grep -rn 'seamless\|powerful\|beautiful\|delightful\|robust\|blazing\|intuitive\|production-ready\|enterprise-grade\|battle-tested' data/projects/<slug>/ data/saas/<anchor>.json
grep -rn '—' data/projects/<slug>/                         # no em dashes
grep -rn ':latest' data/projects/<slug>/                   # zero
grep -c 'Do not continue until they confirm' data/projects/<slug>/prompt.md data/projects/<slug>/prompt-local.md   # every STOP barriered
grep -rn '|| true' data/projects/<slug>/                   # zero in asserts and backups
grep -rn 'repository path\|in prompt.md' data/projects/<slug>/prompt-chat.md   # zero — chat is standalone
grep -c 'openssl rand' data/projects/<slug>/prompt.md      # == secretsToGenerate, same in all paths + install.sh
bash -n data/projects/<slug>/install.sh
npm run validate                                           # green, but remember: floor, not bar
```

Plus, by hand: re-fetch each image digest from the registry and compare to the pin; re-open each cited URL and confirm the quoted/claimed text is on it; recompute the tier with rubric.js.

### 1.7 Independent verification — non-negotiable

After authoring, a **different agent (or you, in a fresh context, with the author's claims treated as hostile)** re-runs the entire 1.6 battery and additionally adjudicates the product-specific claims: does the auth model in the prompts match upstream source? Does the backup match the mounts? Does every env var exist? Does the install survive being executed step by step? The verifier fixes mechanical defects and FAILs the entry on any fabricated claim. Nothing ships without this pass. This single step is the difference between the batch that needed 3 trivial fixes in 10 products and the batch that failed 10 out of 10.

### 1.8 Close-out (once all products in a batch pass verification)

1. Reword survey rows on older pages when a surveyed project earns its own page ("It has since earned its own page in this catalog as the X answer… On this page Y keeps the top spot for…"). Grep all of `data/saas/` for each new project's name.
2. `node scripts/generate-redirects.mjs . > public/_redirects` — zero COLLISION warnings; a project may be rank-0 on exactly one page; no pre-existing redirect may change target.
3. `npm run validate:fix` → `npm run validate` → `npm run build` (the build generates `public/og/*.png` and `.og-cache.json` — both are tracked and must be committed).
4. Commit `data/projects data/saas public/og public/_redirects .og-cache.json` with an honest message (what shipped, what bailed and why, what was fixed in verification), then push.

---

## Part 2 — Repair worklist for the current uncommitted batch

General instructions: keep the ports (8200–8209, collision-free), keep the good research (pins and digests were verified correct in audit — do not re-pin unless noted), keep the honest editorial lines the audit praised. Rewrite all three prompts of every entry to the Part 1 contract — they are all at ~40% depth with a stub chat path, so this is a rewrite, not a patch. Fix `install.sh` where noted. After each product, run the 1.6 battery and a 1.7 verification pass.

### Defects shared by ALL entries (fix everywhere)

1. The broken `sed "s|<DOMAIN>|'"$REAL_DOMAIN"'|g"` line in prompt.md block 5 (install.sh has the correct form — mirror it), plus `$REAL_DOMAIN` never being set.
2. Template residue: stray ```` ```bash true ```` blocks, duplicated assert paragraphs, "(or a JSON health payload for API-only tools)" boilerplate, "the deterministic fallback" compose-header text, local-path text saying "on the server".
3. Chat paths: 2KB stubs with 7 blocks that reference repo files. Rewrite standalone with embedded heredocs, 11 blocks, 1.1–1.6×.
4. STOP grammar: replace every "Wait until they confirm" with the canonical barrier.
5. Neutered asserts (`|| true`) and silent-failure backups.
6. Backups tarring an unmounted `data/` directory: retarget to the real mounted state per product below; add restore steps to every path.
7. Byte floors: bring prompt.md and prompt-local.md into band with product substance.

### Per-product defects (all audit-confirmed)

**filebrowser — DROP THE ENTRY.** Upstream is formally archived 2026-09-01 (README banner: no further releases or security fixes; wontfix security classes; "do not expose without your own auth"). Archived upstream is disqualifying (Astuto precedent). Delete `data/projects/filebrowser/`, remove the filebrowser row from `data/saas/dropbox.json` `ranked[1]` (optionally re-add it under `evaluatedNotTested` with the archive facts stated). The batch ships with 9 products.

**adguard-home**: after the setup wizard the UI moves to port 80, which is never published — the entry ships only `127.0.0.1:8201:3000`. Either instruct the reader to keep the UI on 3000 in the wizard (and say why) or publish the post-setup port. Port 53 is never published anywhere, so the resolver cannot resolve: decide the honest posture (publish 53 with the open-resolver risk stated and mitigated — client allowlist / VPN-only — or reframe the page local-first where LAN DNS is the real use, and write that step). Backup must archive `work/` and `conf/` (the real state, including the admin credential in AdGuardHome.yaml), not `data/`. Add a post-wizard closure assert.

**changedetection**: the `PASSWORD` env var is fiction — upstream uses `SALTED_PASS` (a pre-salted hash) or a UI-set password. Implement a real auth path (UI password set at a STOP, or correctly-generated `SALTED_PASS`), then assert closure (unauthenticated request refused, evidence printed). Surface the JS-rendering limitation (no Playwright/sockpuppetbrowser container shipped) in the prompts, not just the SaaS page, with the upgrade path named. Fix the non-verbatim quote.

**gitea**: set `GITEA__service__DISABLE_REGISTRATION=true` after the first account (STOP), and assert it (signup page gone, evidence printed). Set `GITEA__server__ROOT_URL=https://<DOMAIN>` — the entry cites its necessity and never sets it. Address git-over-SSH honestly: either publish an SSH port with the trade-offs stated or state plainly that this install pushes over HTTPS with a token, and show the reader their first clone/push (the product's core loop). Replace the never-on-page quote. Read GitLab pricing live. Give the Forgejo row real facts (fork history, license, activity).

**gotify**: keep the sound secrets design. Add `.env` to every backup (it holds the admin credential; a restore without it is a lockout) and tell the reader where the password lives in the install.sh summary. Record a version decision: v3.0.0 has been on Docker Hub since 2026-07-18 — pin it or record why 2.9.1 stays (block 9). Fix the fabricated quote (use text actually on the cited page). State the iOS truth plainly: no first-party iOS app at all. Add the application-token handoff (create an app, curl a test message) — the product's core loop. Tar the live Caddyfile, not the template.

**it-tools**: remove the fictional first-run-setup/sign-in STOPs and claim-race warnings — it-tools has no accounts. Write the real posture: public-by-design, every tool usable by anyone who reaches the URL (gatus-style consent framing), with Caddy `basic_auth` as the documented opt-in. Be honest about statelessness: no state means the backup block covers compose + Caddyfile only, and says so. Fix `officialCompose` to reflect reality (upstream publishes `docker run` lines). Date the 21-month-old release in the cadence disclosure.

**jellyfin**: retarget the backup to `config/` (database, users, watch state) — currently it tars an empty dir and loses everything; add restore steps. Fix the media-library flow: the compose hardcodes a fresh root-owned `media/` dir while block 1 promises to mount an existing library — write the real mapping step with ownership handling. Re-read Plex pricing live (post-April-2025: Pass $6.99/mo, $69.99/yr, $249.99 lifetime) and stamp only what you read. Add a wizard-completion closure assert (`/Startup` endpoints). Add the home-box-first framing the media siblings use, and a bandwidth/egress honesty line.

**meilisearch**: correct the license record to the truth at the tag — `MIT AND BUSL-1.1` with the EE carve-out disclosed chatwoot-style, plus the mandatory source-available candor line for the BUSL part; fix citation 3 (it currently claims EE is a separate product — false). Assert master-key enforcement (unauthenticated request → 401, evidence printed). Set and disclose `MEILI_NO_ANALYTICS`. Remove sign-in language (headless API, no UI). Add the API-key handoff: create a search key via `/keys`, never ship the master key to a browser. Replace the banned word "powerful" in the quote. Fix `related[]` (currently analytics/monitoring filler).

**netdata**: disclose the license split — agent GPL-3.0-or-later, **dashboard UI closed-source under NCUL1** (upstream's own README table); this is mandatory. Decide the exposure posture: Caddy `basic_auth` in front (recommended) or explicit gatus-style consent framing — currently an unauthenticated map of the whole box ships public while the entry itself names the danger. Retarget backups to `config`/`lib`/`cache` (the real mounts). Remove setup/sign-in fiction (no auth exists). State per-capability risk for `SYS_ADMIN` + `apparmor:unconfined`. Fix the quote (old tagline, not on the cited page) and the 404ing nginx citation. Fix datadog.json's `"unit": "per-seat"` → per-host.

**ntfy**: close the instance: `auth-default-access: deny-all` in the config, create the reader's user via `ntfy user add` at a STOP (or token flow), then **assert anonymous publish is denied** (curl → 403, evidence printed) — currently anyone who guesses a topic can publish. Fix `NTFY_BASE_URL` in the VPS compose to `https://<DOMAIN>`. Remove browser-setup fiction (users are CLI-created). Write the iOS truth with substance: instant delivery on iOS routes through upstream's APNS bridge (`upstream-base-url`) or arrives delayed — load-bearing candor for a Pushover page. Add the publish handoff (curl a message, subscribe on a phone). Align install.sh's backup with prompt.md's. Fix the quote's citation (README, not docs).

### Batch close-out (after all 9 repaired entries pass verification)

1. Reword the 4 stale survey rows: Jellyfin rows on `audible.json`, `spotify.json`, `vimeo.json`; Netdata row on `grafana-cloud.json`. Optional nicety: `raindrop.json`'s linkwarden note can now link the meilisearch page.
2. Regenerate `public/_redirects`; expect the filebrowser lines to disappear; zero collisions; no pre-existing target changes.
3. `npm run validate:fix` → `npm run validate` → `npm run build`; commit everything including `public/og/*.png` and `.og-cache.json`; push.
4. Note in the commit message: filebrowser dropped (archived upstream), ports 8182–8199 remain free for future batches.
