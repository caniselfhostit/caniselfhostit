# Can I Self-Host It?

**[caniselfhostit.com](https://caniselfhostit.com)** — for every SaaS you pay for: a mature
open-source replacement, and the exact AI-agent prompts that install it on your own server.

Most directories hand you a list and wish you luck. This one is built around the verb. For each
paid product there is an open-source project that already does the job, the measured cost of
running it yourself (RAM floor, disk, minutes to first screen), and prompts that a coding agent
executes end to end. Honestly framed, it is **two prompts, not one**:
[Prompt Zero](https://caniselfhostit.com/prompt-zero/) takes a machine with nothing installed to
a machine that can deploy — terminal, git, agent, VPS, SSH key, hardening baseline — and then one
prompt per app does the install. Every published prompt ran on a clean server before it earned
its date stamp; the ones that haven't are labeled, not hidden.

## The verdict

The setup tier is derived mechanically from a project's `tierFactors` (containers, external
database, SMTP, OAuth, DNS, GPU, secrets to generate). Nobody hand-writes a verdict.

| Tier | Verdict | What you're in for |
| --- | --- | --- |
| **ONE COMMAND** | YES | Under 10 minutes. Paste, wait, open the URL. |
| **ONE EVENING** | YES | One to three hours, including DNS propagation. |
| **ONE WEEKEND** | YES, BUT | Plan a weekend. Multiple services, real configuration. |
| **ONGOING OPS** | YES, IF | You will actually run operations: upgrades, backups, breakage. |
| **NOT WORTH IT (yet)** | — | Editorial stay-on-SaaS call. Mailcow-class. Reasons on [/methodology](https://caniselfhostit.com/methodology/). |

## Add a project

Projects are directories in [`data/projects/`](data/projects) — one per project, holding
`index.json` plus the real reviewable files (`compose.yml`, `Caddyfile`, `install.sh`) and the
prompts. Added by PR. No web form, no account: the repo is the admin panel.

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
