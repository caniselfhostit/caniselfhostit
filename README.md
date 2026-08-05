# Can I Self-Host It?

**[caniselfhostit.com](https://caniselfhostit.com)** — for every app you pay for: the open-source
replacement, and the prompts that install it on your own server or your own computer.

Most directories hand you a list and wish you luck. This one is built around the verb, and around
the invoice. The page is named after the thing you're paying for — "Can I self-host Miro?" — and
the answer names the project: yes, it's called Excalidraw. Under it: why people pay, the plan
ladder with the price we checked and when, the measured cost of running the replacement yourself
(RAM floor, disk, minutes to first screen), and prompts that a coding agent executes end to end.
Every page offers two paths, and the toggle on the page picks one. **On a server, it is honestly
two prompts, not one**: [Prompt Zero](https://caniselfhostit.com/prompt-zero/) takes a machine
with nothing installed to a machine that can deploy — terminal, git, agent, VPS, SSH key,
hardening baseline — and then one prompt per app does the install, on a domain, behind automatic
TLS. **On your own computer, it is one prompt.** Docker Desktop, `http://localhost:<port>`, no
server to rent, no domain to buy, no Prompt Zero, nothing reachable from outside the machine —
and the page says in one sentence what that costs you for that particular app, because for a
monitor or a password manager it costs something real. Every published prompt ran on a clean
server before it earned its date stamp; the ones that haven't are labeled, not hidden.

## The verdict

Every page asks about a paid app and answers with one word. The word is not written by hand: it
comes from the setup tier of the replacement, derived mechanically from that project's
`tierFactors` (containers, external database, SMTP, OAuth, DNS, GPU, secrets to generate). "Can I
self-host Miro?" is answered **YES** because Excalidraw is one command — not because we like
Excalidraw.

| Tier | Verdict | What you're in for |
| --- | --- | --- |
| **ONE COMMAND** | YES | Under 10 minutes. Paste, wait, open the URL. |
| **ONE EVENING** | YES | One to three hours, including DNS propagation. |
| **ONE WEEKEND** | YES, BUT | Plan a weekend. Multiple services, real configuration. |
| **ONGOING OPS** | YES, IF | You will actually run operations: upgrades, backups, breakage. |
| **NOT WORTH IT (yet)** | — | Editorial stay-on-SaaS call. Mailcow-class. Reasons on [/methodology](https://caniselfhostit.com/methodology/). |

## Add a project

Projects are directories in [`data/projects/`](data/projects) — one per project, holding
`index.json`, the real reviewable files (`compose.yml`, `compose.local.yml`, `Caddyfile`,
`install.sh`), and three prompts (`prompt.md` for the server, `prompt-local.md` for your own
computer, `prompt-chat.md` for people with only a chat window). All eight files are required, and
the validator checks that the local path and the server path agree on pins and ports rather than
drifting apart. Added by PR. No web form, no account: the repo is the admin panel.

**Two shapes, one join.** The project is the *contribution unit* — it carries the prompts, the
configs, the tier factors, and the measured resources. The SaaS entity in
[`data/saas/`](data/saas) is the *page* — name, plan ladder with the date each price was checked,
why people pay, and `ranked[]` naming the projects that replace it, best first. `getAllSaasPages()`
in [`src/lib/projects.js`](src/lib/projects.js) joins the two, which is why adding a project
usually means touching a SaaS file as well. The validator fails a dangling reference in either
direction.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the schema, the provenance rule, and the security
standard the validator enforces.

## Run it locally

```sh
npm install
npm run dev        # http://localhost:4321
```

```sh
npm run validate       # schema + security + publish gates, the same check CI runs
npm run validate:fix   # rewrites contentHash / contentUpdatedAt for what you changed
```

No environment variables are required for local development. `.env.example` documents the ones
Phase 1 adds (Supabase, GitHub token, analytics).

If you're sending a PR, turn on the repo's hooks once: `git config core.hooksPath .githooks`.

## Stack

- [Astro](https://astro.build) with `@astrojs/cloudflare`, static output — content routes are
  prerendered, so every fact, prompt, and chart number ships in the initial HTML. No client
  framework, no runtime data fetching for anything a crawler needs to see.
- Supabase holds the data that moves: GitHub stats, star history, verification runs, reader
  outcome reports. Read at build time; only `/api/*` runs live on the Worker.
- A nightly GitHub Actions cron refreshes the stats and triggers a rebuild, so displayed numbers
  are at most 24 hours stale and every page says when they were pulled.

## Credit

Inspired by **[canivibecodeit.com](https://canivibecodeit.com)** — Rob Hallam's directory of
subscriptions an AI agent can rebuild. Different site, different operator, and where its honest
answer is "not really, the value is the hosting," this one picks up the thread. Patterns adapted
from its MIT-licensed codebase are credited on [/about](https://caniselfhostit.com/about/) and
[/methodology](https://caniselfhostit.com/methodology/) — the only places on the site that
carry the credit, because a sitewide reciprocal footer between two sibling directories is a
link scheme, not an acknowledgment.

## License

[MIT](LICENSE). Data and prompts included.

**The prompts are free forever.** Backup, restore, TLS renewal, and the basic upgrade command
stay free too — safety is never paywalled.
