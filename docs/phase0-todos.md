# Phase 0 — operator to-dos

**Things only a human with a credit card and an inbox can do.** No code here. Every item
below blocks something downstream, and three of them have lead times measured in days, not
minutes — which is why they are Phase 0 work even though nothing on the site depends on them
until Phase 1 or 3.

Owner: Jashanpreet Singh · Day 1 = **2026-08-05** · Launch target: **before 2026-09-15**
(Cloudflare AI-crawler flag day, PRD §16).

**Ordered by lead time, longest first.** That is deliberately *not* the order of urgency —
see the critical path below.

---

## Do these three today, whatever else happens

| # | Why today |
|---|---|
| **A** — Hetzner account + SMTP unblock request | Multi-day approval. Every day you wait is a day added to Phase 2's `needsSmtp` projects |
| **F** — Anthropic account/plan on the spike machine | Blocks the agent-execution spike (`docs/spike-agent-execution.md`), which blocks the prompt style guide, which blocks all ~50 prompts |
| **C** — GitHub org + public repo | Two minutes of work that unblocks CI, contributions, and a hardcoded-string fix in `src/lib/site.js` |

---

## Status board

| # | Item | Lead time | Blocks | Phase | Done |
|---|---|---|---|---|---|
| A | Hetzner account + ports 25/465/587 unblock | **1–5 business days** | `needsSmtp` verification | 2 | ☐ |
| B | Harness test domain + Cloudflare DNS token | **1–2 days** (up to 15 for registrar email verification) | TLS at CI, all harness runs | 1 | ☐ |
| G | Cloudflare account ready for the zone move | account: minutes · **NS propagation 24–48 h** | Launch, AI-crawler opt-out | 3 | ☐ |
| C | GitHub org + public repo | minutes | CI, PRs, `repoUrl` | 0 | ☐ |
| E | Supabase project + region | minutes | Nightly cron, outcome API | 1 | ☐ |
| F | Anthropic account/plan (spike machine) | minutes | **The spike** | 0 | ☐ |
| D | DataFast account + website id | minutes | Analytics only | 3 | ☐ |

**Never put a token, key, or password in the repo.** Everything secret from this list lives in
a password manager and, where CI needs it, in GitHub Actions repository secrets. Record only
non-secret identifiers (project refs, org names, region names, website ids) in the notes
column of this file.

---

## A — Hetzner account + outbound SMTP unblock

**Lead time: 1–5 business days.** Longest item on the list. Start it before you read the rest.

**WHY.** Hetzner blocks outbound ports 25, 465 and 587 on new Cloud accounts by default, as
anti-abuse. The verification harness (PRD §9) has to prove that projects with
`needsSmtp: true` — Listmonk, Ghost, Chatwoot, anything that sends a signup or password-reset
mail — actually deliver mail, not just return HTTP 200. Without the unblock, either those
projects ship with a **published carve-out** ("we could not test mail delivery") or they don't
ship a stamp at all. The carve-out is the sanctioned fallback, but it is a worse page.

**WHAT IT BLOCKS.** `needsSmtp` verification in Phase 2. Also the harness account itself, which
is the same account — so this gates the entire verification pipeline, not just mail.

**DO.**

1. Create the Hetzner Cloud account. Expect email verification, a payment method, and
   possibly an ID check — **note how long each step took and what it asked for**. Prompt Zero
   tells readers to do this exact thing (PRD §4.1 step 3), and your own friction is the
   honest copy. The same notes serve `docs/spike-agent-execution.md` step S3.
2. Create two projects: `caniselfhostit-harness` (CI) and `caniselfhostit-spike` (throwaway,
   for the spike). Keeping them separate means the harness sweeper can safely force-delete
   everything in its own project without touching a manual test.
3. Request the port unblock through the Cloud Console support / mail-port request flow.
   Template below.
4. **Record what the actual request flow was** — form, ticket, waiting period, whether they
   asked for account age or spend. Prompt Zero has to warn readers that their fresh account
   hits the same wall (PRD §9), and a vague warning is useless.

**Request template** (keep it short, specific, and true — vague requests get refused):

> Subject: Request to unblock outbound SMTP ports (25, 465, 587)
>
> Customer number: `<number>` · Project: `caniselfhostit-harness`
>
> I run caniselfhostit.com, an open-source directory that publishes and verifies installation
> instructions for self-hosted software. This project is used only by an automated test
> harness: it creates a server, installs one application, checks that the application works,
> and destroys the server. Servers live for minutes.
>
> Several of the applications I test send transactional email on first run (signup
> confirmation, password reset). Without outbound SMTP I cannot verify that those
> installations actually work, only that a web page loads.
>
> I am requesting outbound 25/465/587 for servers in this project. Mail is sent only to a
> catch-all inbox on a domain I own (`<harness domain>`). No third-party recipients, no bulk
> or marketing mail, no mailing lists, no forwarding. Volume is a handful of messages per
> verification run.
>
> Happy to provide anything else you need. Thank you.

**IF REFUSED** (or deferred pending account age): note the reason, re-request after the account
has spend history, and in the meantime publish the carve-out per PRD §9. Do not route around
it with a third-party relay before Phase 2 — a relay tests the relay, not the install, and the
page would be claiming something it didn't check.

**DONE WHEN.** A reply confirming the ports are open, and a test send from a harness server
reaches the catch-all inbox at item B's domain.

**Notes:** customer number `____` · requested on `____` · granted on `____`

---

## B — Harness test domain + Cloudflare DNS API token

**Lead time: 1–2 days** for registration + zone activation. Up to 15 days if the registrar's
ICANN verification email goes unclicked — click it immediately.

**WHY.** Let's Encrypt rate-limits certificates to roughly 50 per registered domain per week.
Authoring ~50 install prompts means many dozens of iterations; production issuance would blow
the cap by the second day and then every subsequent harness run fails on TLS for a week.
PRD §9 solves this with a **dedicated test domain**, per-run DNS records via the Cloudflare
API, and **Let's Encrypt staging** for routine runs — production issuance reserved for
screenshot passes and manual verification.

**WHAT IT BLOCKS.** TLS at CI scale — which means every harness run, which means every
verified stamp, which means the Phase 1 pilot. This is the second-most-blocking item on the
list after A.

**DO.**

1. Buy a cheap throwaway domain. `.dev` or `.net`, whatever is $10–15/yr. **Do not use a
   caniselfhostit.com subdomain** and do not pick a brand-adjacent name — a half-broken test
   host should never render a URL that looks like the product. Something anonymous
   (`<something>-harness.dev`) is right.
2. Add it to Cloudflare as its **own zone**, separate from the production zone (item G).
3. Create a Cloudflare API token scoped as narrowly as it goes:
   - Permissions: **Zone → DNS → Edit**, and **Zone → Zone → Read**
   - Zone Resources: **Include → Specific zone → this zone only**
   - No account-level permissions. No "All zones".
   The blast radius of a leaked CI token then stops at a throwaway domain. A token that can
   also edit `caniselfhostit.com` is a takeover of the live site.
4. Store the token in the password manager now; it goes into GitHub Actions secrets (item C)
   as `CLOUDFLARE_DNS_TOKEN` when CI is built.
5. Set up the **catch-all inbox** on this domain for item A's SMTP assertion (any cheap mail
   forwarding, or Cloudflare Email Routing catch-all → your inbox). Record the address.
6. Decide the per-run hostname convention and write it down so the harness author uses the
   same one: `<run-id>.h.<domain>`.

**DONE WHEN.** The zone is active in Cloudflare, the scoped token creates and deletes a TXT
record on `h.<domain>`, and mail to `anything@<domain>` lands in your inbox.

**Notes:** domain `____` · zone id `____` · token stored in `____` · catch-all `____`

---

## G — Cloudflare account ready for the zone move (settings listed now)

**Lead time: account minutes; nameserver propagation 24–48 h.** The move itself is Phase 3
work, but the settings list belongs here so nothing gets forgotten under launch pressure.

**WHY.** Two Cloudflare defaults will silently kill the site's whole distribution strategy:

- **The AI-crawler default block starting 2026-09-15.** Every AI crawler gets blocked at the
  edge unless the zone opts out. PRD §10.4 deliberately *allows* GPTBot, ClaudeBot,
  PerplexityBot and friends — corpus presence is distribution for a free directory. A default
  block undoes the entire AEO plan without a single error message.
- **Bot Fight Mode / managed challenges on HTML paths.** A JS challenge served to a crawler
  that doesn't execute JS is a second silent kill switch (PRD §10.5).

Both are **zone settings**, and a zone can't be configured before it exists — which is why the
zone move must land with real time before the flag day, not on launch eve.

**WHAT IT BLOCKS.** Launch (Phase 3). And, if forgotten, the site's entire AEO thesis.

**DO NOW.** Create the Cloudflare account, add the Workers Paid plan ($5/mo, PRD §12), and
confirm you can reach `caniselfhostit.com`'s registrar to change nameservers.

**DO AT PHASE 3 — the checklist, so it isn't reconstructed from memory:**

- [ ] Add `caniselfhostit.com` as a zone; change nameservers at the registrar; wait for active
- [ ] Add `dontvibecodeit.com` as a zone; 301 redirect rule → `https://caniselfhostit.com`
      (campaign domain, PRD §0 — never two live twins)
- [ ] **AI crawler control: opt OUT of the default block.** Allow GPTBot, OAI-SearchBot,
      ChatGPT-User, ClaudeBot, Claude-SearchBot, Claude-User, PerplexityBot, Perplexity-User,
      Google-Extended, Applebot-Extended, Bingbot, CCBot
- [ ] **Bot Fight Mode: OFF.** Confirm no managed challenge or WAF rule fires on HTML paths
- [ ] Leave Rocket Loader and any HTML-rewriting feature (email obfuscation, auto-minify) OFF
      — anything that injects or rewrites JS puts content behind execution, and no AI crawler
      executes JS (PRD §10.3)
- [ ] Always Use HTTPS on; canonical trailing-slash 301s handled in the app, not at the edge
- [ ] Verify: after launch, pull the edge logs weekly and confirm AI crawler user-agents are
      getting **200s**, not 403s or challenges (PRD §16)

**DONE WHEN (Phase 3).** Zone active, both opt-outs confirmed in the dashboard, and one week
of logs showing 200s for at least three AI crawler user-agents.

**Notes:** account email `____` · Workers Paid active `____`

---

## C — GitHub org + public repo

**Lead time: minutes.** Near the bottom by lead time, near the top by consequence.

**WHY.** Three separate things are waiting on a name that hasn't been confirmed: the nightly
GitHub Actions cron that keeps every number on the site ≤24 h stale (PRD §12), the PR-based
contribution kit, and `repoUrl` in `src/lib/site.js` — which today reads
`https://github.com/caniselfhostit/caniselfhostit` with a `// org name pending final
confirmation` comment. That comment is a hardcoded guess in the one file whose entire purpose
is to not be guessed at. PRD §17 lists this as open item 1.

**WHAT IT BLOCKS.** CI, PR contributions, `repoUrl`, and the contribution kit's links.

**DO.**

1. Check whether the org name `caniselfhostit` is available on GitHub. If it is, take it. If
   it isn't, pick the fallback now and say so out loud — every doc that references the repo
   URL has to change together.
2. Create the org. Create the **public** repo `caniselfhostit/caniselfhostit`. MIT license
   (PRD §3 — fully open source).
3. Confirm or correct `SITE.repoUrl` in `src/lib/site.js` and delete the pending comment.
4. Enable Actions. Note for later: the nightly cron **auto-disables after 60 days of repo
   inactivity** — PRD §12 flags this as monitored, so put a calendar reminder in now rather
   than discovering a month of stale numbers later.
5. Repository secrets will be needed as later phases land — create them as they arrive, not
   before: `HETZNER_TOKEN` (A), `CLOUDFLARE_DNS_TOKEN` (B), `SUPABASE_SERVICE_KEY` (E),
   Cloudflare Pages/Workers deploy hook (G).

**DONE WHEN.** The public repo exists, `site.js` matches reality, and Actions is enabled.

**Notes:** org `____` · repo `____` · created `____`

---

## E — Supabase project + region

**Lead time: minutes.** PRD §17 open item 2.

**WHY.** Supabase holds everything that moves: `github_stats`, `github_stars_daily`,
`verification_runs`, `outcome_reports`, `rate_limits` (PRD §6.2). Verification state lives
there rather than in repo JSON specifically so a failed re-test downgrades a page to `pending`
at the next nightly build **without a human commit**. Nothing in Phase 1 can be built against
a project that doesn't exist.

**WHAT IT BLOCKS.** The nightly cron and the outcome API (Phase 1). Not Phase 0.

**DO.**

1. Create the project. **Region:** it only affects build-time reads (PRD §17), and builds run
   in GitHub Actions — so pick a US East region unless you have a reason not to. Write the
   choice down here; it closes PRD open item 2.
2. Record the project ref and the anon key (public by design — it is not a secret, and PRD
   §6.2 is explicit that "we only call it server-side" is not access control). Put the
   **service key** in the password manager only; it becomes a GitHub Actions secret at
   Phase 1.
3. **Free-tier pause:** a free project pauses after roughly 7 days of inactivity. Between now
   and the nightly cron existing, that will happen. Two consequences worth knowing before it
   surprises you mid-build: unpause it manually when it does, and understand that once the
   cron ships it doubles as the keep-alive (PRD §12). Also PRD §16: `github_stars_daily` is
   the one table that cannot be rebuilt from an API — it gets exported to the repo nightly.
4. Schema, RLS posture (non-exposed schema + RLS on with zero policies, CI-asserted
   `rowsecurity = true`) is engineering work, not yours. You only need the project.

**DONE WHEN.** Project exists, region recorded, service key in the password manager.

**Notes:** project ref `____` · region `____` · created `____`

---

## F — Anthropic account + plan on the spike machine

**Lead time: minutes.** Blocks the very next thing on the schedule.

**WHY.** `docs/spike-agent-execution.md` validates the whole local-agent → SSH → VPS model
before ~50 prompts get written against it. It cannot start without a working Claude Code
install on a paid plan.

**WHAT IT BLOCKS.** The spike → the prompt style guide's final rules → every install prompt.
The tightest dependency chain in Phase 0.

**DO.**

1. Create the account and pick a plan. **Choose it the way a reader would** — cheapest plan
   that plausibly does the job — because Prompt Zero has to quote a floor price next to the
   ~$5 VPS, and a figure produced on a plan you'd never recommend is not honest (PRD §4.1
   step 2).
2. During the spike, record: the plan name, its monthly price, and **the actual usage the two
   installs consumed**. If the plan hits a usage limit mid-install, that is not a spike
   failure — it is a finding, and it belongs in Prompt Zero as a warning. Immich is the run
   most likely to trigger it.
3. The honest monthly cost table for Prompt Zero is: agent plan + ~$5 VPS + domain. Fill the
   first number from this item.

**DONE WHEN.** Claude Code runs on the spike machine, and the plan + price are recorded for
Prompt Zero.

**Notes:** plan `____` · $/mo `____` · usage consumed by spike `____`

---

## D — DataFast account + website id

**Lead time: minutes.** Genuinely not urgent — listed so it isn't forgotten at launch.

**WHY.** PRD §3 picks DataFast for analytics. Phase 3 needs a website id to put in the
snippet, and `/privacy/` has to name what the site actually loads.

**WHAT IT BLOCKS.** Analytics at Phase 3. **Nothing before that** — do not let this pull
attention from A, B, or F.

**DO.**

1. Create the account, add `caniselfhostit.com`, record the website id.
2. Two constraints for whoever wires it up: the snippet must not gate any content behind JS
   (PRD §10.3 — everything in the initial HTML), and `/privacy/` must name DataFast, what it
   collects, and that there is no cookie banner because there is nothing to consent to. If
   that stops being true, the privacy page changes first.

**DONE WHEN.** Website id recorded, and `/privacy/` copy names the tool.

**Notes:** website id `____`

---

## Not on this list, tracked elsewhere

- **Author page bio + photo** — needed at Phase 3 for the "Reviewed by Jashanpreet Singh"
  byline (PRD §17 open item 3). Human work, but no lead time and no dependencies.
- **Maintainer outreach for the README badge** — Phase 3, opt-in only (PRD §10.10).
- **Friendly outreach to Rob Hallam** — Phase 3 launch channel (PRD §1). Worth a heads-up
  before launch day rather than on it.
