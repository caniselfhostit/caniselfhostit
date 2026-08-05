<!--
  One project per PR. If you're fixing a typo or a link, delete the checklist and
  just say what you changed — the boxes below are for project and prompt changes.

  Some boxes cover things CI already checks — the local-path parity items, the pins,
  the content hash. Ticking them is not redundant. CI can prove two files match byte
  for byte; only you can say you read what they say and meant it.
-->

## What this changes

<!-- Project slug, or the page/file you touched. One line is fine. -->

## Where the facts came from

<!--
  For a new or updated project: the upstream docs URL you authored compose.yml,
  compose.local.yml, the Caddyfile, and install.sh FROM. For a price change: the vendor
  pricing page you read.
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
- [ ] **No secrets anywhere** — not in any prompt text, not in either compose file, not in the
      diff. Secrets are generated at install time, on whichever machine is running the install
- [ ] No standing default credentials (`admin/admin` with a "change me" comment counts)
- [ ] **Cloud path** — hardening baseline present: non-root service user, explicit firewall ports,
      Caddy with automatic TLS
- [ ] **Local path** — `prompt-local.md` and `compose.local.yml` both exist, and `prompt-local.md`
      opens with the two local frame lines byte-identical to the style guide (no `<DOMAIN>`, no
      ssh, block 6 states the loopback-only posture)
- [ ] **Local path** — the compose block inside `prompt-local.md` is byte-identical to
      `compose.local.yml`, and `compose.local.yml` carries the same image pins and the same host
      port as `compose.yml`
- [ ] **Local path** — `index.json` has `local.fit` (`good` / `caveat`) and a one-sentence
      `local.note`, and a `caveat` fit is said to the user in block 1 before anything installs
- [ ] The install ends with a **first backup**, and a restore of it — off-box on the cloud path,
      off-machine on the local one
- [ ] The prompt carries a **DRAFT** marker unless I ran it end to end myself — on a clean server
      for the cloud path, on a clean machine for the local one
- [ ] `tierFactors` are honest — I didn't round a two-hour install down to "one command"
- [ ] No `setupTier` or `verified` key in `index.json` (both are derived elsewhere, on purpose)

## Anything you want a second pair of eyes on

<!-- Where you were unsure, what you couldn't test, what you guessed at. Saying so is faster than us finding it. -->
