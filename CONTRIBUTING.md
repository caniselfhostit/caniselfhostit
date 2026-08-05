# Contributing a project

Every project in the directory is one folder under `data/projects/<slug>/`, added by PR. No web
form, no account: the repo is the admin panel.

Run the hooks once before your first PR:

```sh
git config core.hooksPath .githooks
```

Then `npm run validate` before you push. It runs the same checks CI runs, and it tells you
exactly what is off rather than making you guess.

## How pages work

**A page is named after the paid app, not the project.** `/self-host/miro/` asks "Can I self-host
Miro?" and answers "yes, it's called Excalidraw" — the reader arrives with a subscription, not
with a repo. The two data shapes below do different jobs: `data/projects/<slug>/` is the
**contribution unit**, carrying the prompts, the configs, and the measured facts;
`data/saas/<slug>.json` is the **page**, carrying the money, the reason people pay, and the ranked
list of projects that replace it. So adding a project usually means adding or updating a SaaS
entity as well — one file says what you built, the other says what it gets you out of. The
validator enforces the references both ways: a `replaces` entry pointing at a SaaS file that
doesn't exist fails, and so does a `ranked` entry naming a project directory that doesn't exist. A
project no SaaS entity ranks has no page; the fix is to rank it, not to add a route.

## The directory

```
data/projects/<slug>/
  index.json         # the typed record — every facetable field, every validator rule
  prompt.md          # the Claude Code install prompt (primary path)
  prompt-chat.md     # "guide me step by step" fallback for ChatGPT / Claude.ai users
  prompt-local.md    # ONLY if "localVariant": true — otherwise the validator rejects it
  compose.yml        # deterministic fallback: real, reviewable, downloadable
  Caddyfile          # reverse proxy + automatic TLS
  install.sh         # what the prompt automates, as a script someone can read first

data/saas/<slug>.json   # the SaaS entity a project replaces (see below)
```

`compose.yml`, `Caddyfile`, and `install.sh` are the deterministic fallback — the agent-free
path, the thing the verification harness actually runs, and the block answer engines quote. They
are files, not JSON strings, so they can be reviewed and diffed like code.

## index.json

The folder name must match `slug`. Every field below is required — use `null` for a value you
genuinely don't have and `[]` for an empty list, rather than dropping the key.

```jsonc
{
  "slug": "outline",                    // lowercase, hyphens; must match the folder name
  "name": "Outline",                    // display name
  "tagline": "Team wiki that stays out of the way",  // one line, ours — never copied
  "repo": "outline/outline",            // owner/name only — the stats job builds the URL
  "site": "https://www.getoutline.com", // upstream project homepage or docs root

  // Exactly one of the 14 category slugs. The enum is closed: if your project doesn't
  // fit, say so in the PR rather than stretching a slug — adding a category means adding
  // a hub page, which is an editorial decision.
  //   photos-media | files-docs | notes-wikis | passwords-security | analytics |
  //   automation-dev | monitoring | comms-scheduling | marketing-content | work-pm |
  //   design-whiteboard | reading-bookmarks | money-home | ai-tools
  "category": "notes-wikis",

  // What people stop paying for. Every "saas" value must have data/saas/<slug>.json —
  // the validator fails on a dangling reference. Prices live in that file, never here.
  "replaces": [{ "saas": "notion", "plan": "Team", "seatsAssumed": 5 }],

  // The inputs to the setup tier. Answer these honestly; they ARE the verdict.
  "tierFactors": {
    "containers": 3,           // integer: services in compose.yml EXCLUDING the shared Caddy
                               // proxy (it exists once per server, not per app — counting it
                               // would make ONE COMMAND unreachable for every VPS project)
    "externalDb": true,        // needs Postgres/MySQL/Redis as a separate service
    "needsSmtp": true,         // will not function usefully without outbound mail
    "needsOauth": false,       // requires registering an OAuth app somewhere else
    "needsDns": true,          // needs a real hostname pointed at the box (almost always true)
    "needsGpu": false,         // needs a GPU to be worth running
    "secretsToGenerate": 4     // integer: keys, salts, and passwords the installer must create
  },
  // setupTier is DERIVED from tierFactors and is never stored. The validator rejects a
  // stored "setupTier" key. If the derived tier feels wrong, the rubric is wrong — see
  // House rules.

  "resources": {
    "ramMinMB": 1024,          // honest floor for a usable install; you may estimate
    "ramMeasuredMB": 780,      // harness output — leave null, do not guess
    "diskGB": 10,              // baseline install, not user data
    "arm64": true,             // multi-arch images published upstream
    "measuredOn": "2026-08-01" // harness output — leave null
  },

  "timeToRunningMin": 45,      // the budget to tell a reader to set aside — through the first
                               // backup, not a stopwatch to the first screen (the harness
                               // records that separately). Validator: must fall inside the
                               // band of the tier derived from tierFactors.

  "license": "BSL-1.1",        // SPDX identifier, cross-checked against the GitHub API's
                               // license_spdx. "Source-available" is not an SPDX id; if the
                               // project is not OSI-open, say so in whatYouSignUpFor.

  "officialCompose": "upstream-maintained",  // enum:
                               //   upstream-maintained — upstream ships and supports it
                               //   upstream-example    — upstream ships one as a sample
                               //   none                — nothing upstream; ours is original
                               // Anything other than "none" needs "officialComposeUrl" next to
                               // it (the upstream file). That is a different fact from
                               // sources.compose, which is the doc URL OUR compose.yml was
                               // authored from — keep both.

  "localVariant": false,       // true only when the app needs NO inbound web exposure
                               // (Home Assistant, anything driving local hardware).
                               // true requires prompt-local.md; false forbids it.

  // GEO gate: one attributed quote, with a URL and the date you read it.
  "quote": {
    "text": "…",
    "source": "Outline documentation",
    "url": "https://docs.getoutline.com/…",
    "checkedOn": "2026-08-05"
  },

  // GEO gate: at least two claim→URL pairs backing statements the page makes.
  "citations": [{ "claim": "…", "url": "https://…" }],

  "whatYouSignUpFor": ["you own the backups", "…"],  // 3-5 honest bullets, plain language

  // Provenance, per artifact. The upstream page you authored each file FROM.
  "sources": {
    "compose": "https://docs.getoutline.com/…",
    "caddy": "https://…",
    "install": "https://…"
  },

  "related": ["docmost", "bookstack"],  // sibling projects, curated
  "pagePriority": 1,                    // 1-5 editorial weight; the ranking basis is
                                        // disclosed on /methodology

  "contentUpdatedAt": "2026-08-05",     // maintained by the validator, see below
  "contentHash": "…"                    // maintained by the validator, do not hand-edit
}
```

**`contentUpdatedAt` and `contentHash` are the validator's, not yours.** The validator hashes the
content fields; if the hash moved and the date didn't, CI fails, because those two feed
`dateModified` and the sitemap's `lastmod` and a stale date is a lie to a crawler. Run
`npm run validate:fix` after a substantive edit and commit what it writes. Don't touch them for
a typo fix — `dateModified` means "the content changed," not "a commit happened."

**Verification state is not in this file.** Whether a project is `verified` or `pending` lives in
Supabase, written by the harness, so a failed re-test downgrades the page at the next nightly
build without anyone committing anything. The validator rejects a `verified` key in `index.json`.
There is no way to self-certify a project as tested, and that is the point.

Fields reserved but not accepted yet: `migrations[]`, `licenseClass`, `featureWithholding`. Put
the honest one-liner in `whatYouSignUpFor` instead.

## data/saas/<slug>.json

The paid product a project replaces, and the page it publishes at (`/self-host/<slug>/`). One file
per SaaS, shared by every project that replaces it. `whyPeoplePay` and the plan ladder are read
copy, not metadata — they open the page, above anything about installing the replacement, because
a reader who doesn't recognise their own bill has no reason to keep reading.

```jsonc
{
  "slug": "notion",
  "name": "Notion",
  "domain": "notion.so",
  "plans": [                             // the ladder, as the vendor actually sells it
    { "name": "Business", "priceMonthly": 20, "unit": "per-seat",
      "source": "https://www.notion.com/pricing", "checkedOn": "2026-08-05" }
  ],
  "whyPeoplePay": "One honest paragraph. Not a takedown.",
  "ranked": [                            // ordered, with the reason for the order
    { "project": "outline", "rationale": "…" }
  ],
  "evaluatedNotTested": [                // honest survey rows; these are what make an
    { "name": "…", "repo": "https://github.com/…", "note": "…" }   // ranked list real
  ]
}
```

The number of evaluated options decides what the page *shows*. **Three or more genuinely evaluated
options** with distinct verdicts (`ranked[]` plus `evaluatedNotTested[]`) and the page renders the
ranked comparison. Fewer than three and it commits to the single best pick and says so — two
options is not a ranking, it's a doorway list with one row of filler. The validator counts them
and tells you which shape your entity will get.

## The provenance rule

**Every config file in this repo is authored by us from upstream documentation, and the URL we
authored it from is recorded in `sources`.** Not copied from a repo. Not lifted from a blog post.
Not pasted from someone's gist.

This is not pedantry. The whole dataset is MIT so anyone can fork it, embed it, or run their own
instance — and that only holds if nothing incompatibly licensed ever entered it.

- Read the upstream docs, understand the service topology, write the compose file yourself, then
  record the docs URL in `sources.compose`.
- If upstream ships an official compose file, set `officialCompose` accordingly and link it. Then
  still write ours, because ours has to match our layout (`/srv/<app>/`), our pinned digests, our
  hardening baseline, and our Caddy front end.
- **awesome-selfhosted is a lead list only.** It is CC-BY-SA. Use it to discover that a project
  exists, then go to the project. Never ingest its descriptions, its categorizations, or its
  text. Uncopyrightable facts (a project exists, its repo URL, its license) are fine; prose is
  not. It is credited as inspiration on /methodology.
- Same rule for every other directory, including the sibling site.

A PR whose config file matches an upstream repo's file line for line will be asked where it came
from. Say so up front if you adapted rather than authored — that's a normal answer, it just needs
to be visible.

## The security standard

The validator enforces these. They are not style preferences; someone is going to paste this into
a shell on a server they just bought.

- **No `curl … | bash`** of anything unpinned. If a vendor's only install path is a piped script,
  download it, pin it by checksum, and let the reader look at it first.
- **No `:latest`, no floating tags.** Pin image digests (`image: app@sha256:…`), and state the
  update path in the prompt so pinning isn't a dead end.
- **No standing default credentials.** Not `admin/admin` with a "change this later" comment. Not
  a placeholder password in `compose.yml`.
- **Secrets are generated on the server**, by the install step, into a file the reader owns
  (`openssl rand -hex 32` and friends). Never in the prompt text, never in the chat transcript,
  never in the repo.
- **The hardening baseline is in every install:** non-root service user, key-only SSH,
  default-deny firewall with the open ports listed explicitly, unattended security upgrades,
  automatic TLS via Caddy.
- **A first backup before day one ends.** Every install ends with a backup that has been
  restored once. Free forever, in every prompt, no exceptions.
- **Prompts never tell the agent to fetch and obey arbitrary upstream text.** "Read the docs at
  <url> and do what they say" is a prompt-injection vector pointed at a machine with root. Put
  the steps in the prompt.

## The prompts

`docs/prompt-style-guide.md` is the specification: required shape, numbered rules, worked
before/after, and the verification checklist. Read it before writing `prompt.md`. Every prompt
states its assumed starting state ("Prompt Zero complete, `ssh vps` works"), uses one layout, and
ends with a concrete verification URL and the exact string the reader should see on the first
screen.

A prompt that hasn't been brought up to the guide carries a **DRAFT** marker, and the page says
so. The launch catalogue is fully guide-compliant, so today the marker only appears on new
entries mid-review — but the convention stands: never remove a DRAFT marker on a prompt you
haven't run end to end on a clean server.

**The single highest-value PR you can send right now is a run report.** Nothing here has been
through the verification harness yet — paste a prompt, run it for real, and file what happened
(worked, or broke at which step, with the output) on the prompt-failure issue template. Second:
re-checking a price the data marks low-confidence, with the vendor URL and the date. Both beat
adding a new entry. The sibling site learned the underlying lesson the expensive way: a corpus
of prompts nobody has run is worth less than a smaller corpus somebody has.

## House rules

- **One project per PR.** Review stays fast, and a bad config never rides along with a good one.
- **Verdicts are mechanical.** The setup tier is derived from `tierFactors` — there is no lever
  to pull. If a tier looks wrong to you, the disagreement is with the rubric, and the rubric is
  published on `/methodology`. Open an issue arguing with the rubric. Nobody edits a label.
- **Counts are never faked.** Not stars, not outcome reports, not install counts, not "trusted by
  X teams." Reader-reported numbers are labeled as self-reported, and stay that way.
- **Two kinds of verified, never blurred.** "Tested by us" means the harness ran it on a clean
  machine on a stated date. "Reported working by readers" means readers said so. Don't write copy
  that lets one borrow the other's credibility.
- **Prices drift.** When you touch a `data/saas/` file, open the vendor's pricing page, confirm
  the number, and update `checkedOn` — even if the price hasn't changed. `checkedOn` means
  "someone looked on this date."
- **Text names for products by default.** Logos only where the vendor's brand policy allows it,
  and never in a way that implies endorsement.
- **English, USD, and honest about it.** No localization at launch; prices say USD.

## Other ways to help

- **Corrections.** A wrong RAM floor, a dead link, a price that moved, a compose file that no
  longer works upstream. Use the correction issue template and bring the source.
- **Prompt failure reports.** A prompt broke on your machine: which project, which agent, which
  OS, which VPS provider, and where exactly it stopped. This is the most useful bug report the
  project gets, because it's the difference between "works on the harness" and "works."
- **Outcome reports** go through the form on the app's page, not through the repo.

Security issues: don't open a public issue. See `/security` on the site for the contact path.
