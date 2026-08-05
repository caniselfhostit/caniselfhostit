<!--
  One project per PR. If you're fixing a typo or a link, delete the checklist and
  just say what you changed — the boxes below are for project and prompt changes.
-->

## What this changes

<!-- Project slug, or the page/file you touched. One line is fine. -->

## Where the facts came from

<!--
  For a new or updated project: the upstream docs URL you authored compose.yml, the
  Caddyfile, and install.sh FROM. For a price change: the vendor pricing page you read.
  This is the provenance rule (CONTRIBUTING.md) — it's the whole reason the dataset can
  stay MIT.
-->

## Checklist

- [ ] `npm run validate` passes locally
- [ ] `npm run validate:fix` run and its `contentHash` / `contentUpdatedAt` changes committed
- [ ] **One project per PR** — no unrelated changes riding along
- [ ] Every config file was **authored from upstream docs**, not pasted from a repo, and each
      source URL is recorded in `sources`
- [ ] Every price, quote, and cited claim has a source URL and a `checkedOn` date I set today
- [ ] **No `:latest`** and no floating tags — image digests are pinned
- [ ] **No `curl … | bash`** of an unpinned script
- [ ] **No secrets anywhere** — not in the prompt text, not in `compose.yml`, not in the diff.
      Secrets are generated on the server at install time
- [ ] No standing default credentials (`admin/admin` with a "change me" comment counts)
- [ ] Hardening baseline present: non-root service user, explicit firewall ports, Caddy with
      automatic TLS
- [ ] The install ends with a **first backup**, and a restore of it
- [ ] The prompt carries a **DRAFT** marker unless I ran it end to end on a clean server myself
- [ ] `tierFactors` are honest — I didn't round a two-hour install down to "one command"
- [ ] No `setupTier` or `verified` key in `index.json` (both are derived elsewhere, on purpose)

## Anything you want a second pair of eyes on

<!-- Where you were unsure, what you couldn't test, what you guessed at. Saying so is faster than us finding it. -->
