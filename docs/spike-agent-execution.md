# Spike — agent execution model

**Phase 0 · PRD §4.5 · operator-run · one afternoon per platform**
Status: not started · Owner: Jashanpreet Singh · Target: 2026-08-06 (macOS) / 2026-08-07 (Windows 11)

---

## 1. Purpose

The whole site is a bet on one mechanic: **the agent runs on the reader's laptop, reaches a
disposable VPS over SSH, and installs the app.** Prompt Zero teaches it, all ~50 install
prompts assume it, and the compatibility tier (`Claude Code — verified <date>`) claims it
works.

Nobody has measured it end-to-end on a machine with nothing on it.

This spike measures it **before the ~50 prompts are written against it**. If the model is
wrong — 40 permission prompts, an agent that stalls every third command, a deeplink that
silently truncates — the cost of finding out now is one afternoon. The cost of finding out
in Phase 2 is the whole prompt corpus.

### What the numbers are for

| Result | Feeds |
|---|---|
| Permission-approval count, with and without an allowlist | Prompt Zero §4.1.4 copy + the honest permission framing |
| Wall clock, clean machine → running app | `timeToRunningMin` tier bands (§8); Prompt Zero's "what an evening looks like" |
| Human-intervention points | The style guide's mandatory checkpoints; "what this prompt will do" outline |
| Unattended-after-approvals: yes/no | Whether prompts can be one block or must be checkpointed segments |
| Deeplink round-trip + truncation threshold | The deeplink payload format (§4.5) — short instruction vs full prompt |
| Claude Code install friction + real monthly cost | Prompt Zero step 2 (the honest bill) |
| Hetzner console friction | Prompt Zero step 3 (VPS signup, KYC realities) |
| Idle RAM after install | Calibrates `ramMeasuredMB` expectations before the harness exists |

### What this spike does NOT do

It does **not** earn a `TESTED ON A CLEAN MACHINE` stamp for Vaultwarden or Immich. Stamps
come from the harness (§9): scripted create → deterministic fallback → assert → screenshot →
destroy. This is a hand-run reconnaissance pass using **draft** prompts. Nothing published
here can carry a verified date.

---

## 2. Budget

- **Time:** ~4 h per platform. Vaultwarden ~1 h · Immich ~2 h · setup/teardown/notes ~1 h.
- **Money:** ~$1 of Hetzner CX22 hours across both platforms + the Anthropic plan (which
  you are buying for the project anyway — see `docs/phase0-todos.md` item F).
- **Prerequisite:** a Hetzner account that can create servers (todo A) and an Anthropic
  account on a plan (todo F). Nothing else.

---

## 3. What "clean" means

A **fresh user account on your existing machine is acceptable** as clean, with the caveats
below. A fresh VM is better if you have one.

**May be present:** the OS as it ships, and a browser.

**Must NOT be present (check each, note if you cannot remove it):**

- git, node, npm, Homebrew, winget-installed dev tools, any package manager you added
- an existing `~/.ssh/` directory — no keys, no `config`, no `known_hosts`
- Claude Code, or any `~/.claude/` directory, config, or allowlist
- a terminal profile, shell aliases, dotfiles you have edited
- a password manager logged in and autofilling Hetzner/Anthropic
- an existing Hetzner project with servers in it (use a **new, empty project**)

**Known leaks the fresh-user trick cannot plug — record these instead of pretending:**

| Platform | Leak | What to record |
|---|---|---|
| macOS | Xcode Command Line Tools are installed **system-wide**, so a new user inherits git | Whether the CLT install prompt appeared. If it did not, you inherited git — note it, and treat "does a truly clean Mac need an Xcode CLT download?" as an open question Prompt Zero must answer |
| macOS | Homebrew at `/opt/homebrew` is world-readable; a new user may still find `brew` on PATH | Run `which brew git node` first thing. Paste the output into the log |
| Windows 11 | WSL2 and the virtualization BIOS flag are **machine-wide**, not per-user | Whether WSL2 was already enabled, whether a BIOS change was needed, and **how many reboots** the flow cost. This is Prompt Zero's single biggest Windows honesty item |
| Windows 11 | Windows Terminal / PowerShell 7 may be preinstalled or not, by build | Record the Windows build number and what shell you actually got |

If you cannot get clean, **say so in the log**. A spike that quietly ran on a loaded machine
produces reader-facing copy that is a lie.

---

## 4. Test subjects

Two, deliberately at opposite ends. Draft prompts live in `data/projects/<slug>/prompt.md`.

### Subject 1 — Vaultwarden (the easy case)

Why: single container, no external DB, no SMTP required for first run, no OAuth, tiny image,
first screen is an unmistakable string. If **this** costs 20 approvals and two stalls, the
model is broken and nothing else matters.

Prompt: `data/projects/vaultwarden/prompt.md` (draft exists).
Expected shape: ONE COMMAND / ONE EVENING band.

### Subject 2 — Immich (the hard case)

Why: multi-container (server, ML, Redis, Postgres), downloads machine-learning models on
first run, long and mostly-idle first boot, and a first screen that only appears after the
admin-registration step. It is the realistic worst case in the launch catalog and the one
most likely to expose:

- an agent that gives up waiting on a slow pull,
- a context window that runs out mid-install,
- a plan that hits its usage limit halfway,
- the difference between "compose up returned 0" and "the app actually works".

Prompt: `data/projects/immich/prompt.md` — **does not exist yet. Draft it during the spike**
from `docs/prompt-style-guide.md` before the run starts (30–40 min, budgeted above). Drafting
it against the style guide *is* part of the test: if the guide cannot express a four-container
install with a model download, the guide has a hole, and finding that hole is worth the
afternoon on its own.

Record every place the style guide forced an awkward phrasing. Those notes go back to the
guide's author as spike output.

---

## 5. Step script

Run identically on both platforms. Keep a screen recording going for the whole session, plus
a running plaintext log. Timestamp every step — wall clock is a deliverable, not a vibe.

Log file: `docs/spike-logs/<platform>-<date>.md` (untracked scratch is fine; the numbers land
in the table in §7).

### S0 — Prepare the tally sheet (5 min)

Before you touch anything, open the §7 table and the §6 counting rules. You will not
reconstruct an approval count from memory afterwards.

### S1 — Prove the machine is clean (5 min)

Run and paste the output:

```
# macOS
which git node npm brew docker ssh; ls -la ~/.ssh ~/.claude 2>&1; sw_vers

# Windows 11 (PowerShell)
Get-Command git,node,npm,ssh,wsl -ErrorAction SilentlyContinue
Get-ChildItem $HOME\.ssh, $HOME\.claude -ErrorAction SilentlyContinue
wsl --status; [System.Environment]::OSVersion.Version
```

**Record:** what was already there.

### S2 — Install Claude Code (start clock)

Follow the official install path as a beginner would — from a search, not from memory.

**Record:**
- account required? which plan, and did you have to enter payment before first use?
- exact minutes, install start → first working prompt
- every dialog, permission, or trust prompt the OS showed (macOS Gatekeeper, Windows
  SmartScreen, WSL install, terminal full-disk-access)
- reboots required
- whether the installer needed a package manager it then had to install first (the recursive
  dependency Prompt Zero has to unwind)
- **the real bill:** plan name + monthly price, and — at the end of the spike — the actual
  usage consumed by the two installs. This number is Prompt Zero's honest-cost table.

### S3 — Create the VPS (Hetzner CX22, console, by hand)

Deliberately by hand, in the web console — this is exactly what a reader does. New empty
project. Ubuntu 24.04. Nearest region. No cloud-init, no snapshot, no extras.

**Record, in a beginner's voice:**
- signup friction: email verification, ID/KYC check, card or PayPal, any hold or delay
- how long from "create account" to "server has an IP"
- how many screens/decisions the create flow asked for, and which ones a non-developer
  cannot answer without help (server type, image, location, **SSH key**, firewall, backups,
  placement group)
- whether it let you create a server **without** adding an SSH key, and what it did instead
  (root password by email — note it, that is a Prompt Zero warning)
- price shown vs price you expected

### S4 — SSH key + config (still by hand)

```
ssh-keygen -t ed25519 -C "spike-<platform>-<date>"
# add the public key to the Hetzner server (console or ssh-copy-id)
# then write ~/.ssh/config:
#   Host vps
#     HostName <ip>
#     User root
#     IdentityFile ~/.ssh/id_ed25519
ssh vps 'echo ok'
```

`ssh vps` returning `ok` is the assumed starting state for every install prompt on the site.

**Record:**
- minutes for this whole step
- every place a beginner would stall: passphrase prompt, `known_hosts` fingerprint
  confirmation, file permissions, where the config file even goes, Windows path differences
  (`C:\Users\<you>\.ssh\config`), whether `ssh` exists on Windows without extra install
- whether you ended up inside WSL or in native Windows PowerShell — and **which one Claude
  Code actually runs in**. If they differ, the key you generated may not be the key the agent
  uses. This is a top candidate for a Prompt Zero landmine.

### S5 — Vaultwarden run (defaults, no allowlist)

Paste `data/projects/vaultwarden/prompt.md` into Claude Code. **Change no settings.** Do not
pre-approve anything. This run measures the reader's out-of-the-box experience.

Then: approve what the agent asks for, answer nothing it does not ask, and **do not help it**.
If it is stuck, wait 60 s before intervening, and log the intervention (§6).

**Record:** every metric in §7 for the Vaultwarden/`<platform>` column.

Stop the clock when the verification URL returns the expected first-screen string from the
prompt — not when the agent says it is done.

### S6 — Idle RAM reading (2 min)

```
ssh vps 'free -m; docker stats --no-stream --format "{{.Name}} {{.MemUsage}}"'
```

Take it ~5 min after the app is up. **Record** total used MB. Free byproduct; calibrates
`ramMinMB` / `ramMeasuredMB` expectations (§9 of the PRD).

### S7 — Allowlist probe, then Immich (the second half of the approval question)

The decision gate in §8 is about approvals **with and without an allowlist path**, so:

1. Before starting Immich, spend up to 10 min finding out whether Claude Code offers a
   durable pre-approval — a settings file, an "always allow" that persists across sessions, a
   permission mode, a project-scoped allow rule. **Record whether one exists, exactly what it
   is called, and how a non-developer would find it.** If none exists, write "none found" and
   run Immich with defaults.
2. Apply the narrowest rule that would cover the install (ideally: `ssh vps` and writes under
   `/srv/`), and **record the exact configuration you used** — Prompt Zero will ship it.
3. Run Immich on a **fresh server** (destroy the Vaultwarden one first, §9). Same rules as
   S5: no helping, 60-second stall rule, log everything.

**Record** the Immich column, plus the delta: approvals with allowlist vs without.

Immich-specific things to watch and note:
- how long the ML model download actually takes, and whether the agent waited or bailed
- whether the agent correctly distinguished "containers started" from "app reachable"
- whether the session ran out of context, or the plan hit a usage limit — and what the agent
  did when it did
- whether it needed the admin-registration step explained, or found it

### S8 — Deeplink round-trip test (§4.5) — 20 min

The PRD asserts deeplink payloads must be **short instructions pointing at a `.md` URL**, not
the 3,400-token prompt. Confirm or falsify it. The scheme (from the reference implementation)
is:

```
claude-cli://open?q=<URI-encoded text>
```

**Method — a truncation ladder with a canary.** Build test payloads of exact character
lengths, each **ending** in a unique canary so truncation is visible:

| # | Raw payload length | Content |
|---|---|---|
| L1 | ~200 chars | The real short-instruction payload (below) + ` #END-L1` |
| L2 | 1,000 chars | Filler + ` #END-L2` |
| L3 | 2,000 chars | Filler + ` #END-L3` |
| L4 | 4,000 chars | Filler + ` #END-L4` |
| L5 | 8,000 chars | Filler + ` #END-L5` |
| L6 | ~14,000 chars | The **full** Vaultwarden prompt + ` #END-L6` |

The real L1 payload to test (this is the format the site would ship):

```
Read https://caniselfhostit.com/self-host/vaultwarden.md and follow it exactly.
Ask me before each command that runs on the remote server.
```

Note that URI-encoding roughly doubles the length of prompt text (newlines, quotes, slashes),
so **record both raw and encoded lengths** — the limit that bites is on the encoded URL.

Serve the links from a local HTML file with plain `<a href="claude-cli://…">` links, and
click them from the browser. For each payload × browser:

**Record:**
- Did the OS/browser show a "open this application?" confirmation? (yes/no, and its wording —
  a scary dialog is a conversion problem)
- Did Claude Code open at all? (if the scheme is not registered on this OS, say so — that is
  a finding, not a failure of the test)
- Did the text **prefill** without auto-sending?
- **Is the canary present at the end?** Missing canary = silent truncation.
- If truncated: at roughly what encoded character count?

Browsers to cover per platform: macOS → Safari + Chrome. Windows → Edge + Chrome. Firefox if
there is time. Also test **one paste of the link into the terminal** (`open '<url>'` /
`start "" "<url>"`) to separate "the browser truncates" from "the handler truncates".

Finally: with L1 open in Claude Code, **actually press enter** once and confirm the agent
fetches the `.md` and starts. A deeplink that opens but leads nowhere is not a round trip.

### S9 — Wrap the log

Fill the §7 table for this platform while it is fresh. Note every sentence you would want to
appear on Prompt Zero verbatim — a beginner's confusion in your own words is better copy than
anything written afterwards.

---

## 6. Counting rules (be pedantic; the numbers are published)

**A permission approval** = any prompt from the agent that halts execution until a human
presses a key, including: bash/command execution, file writes, file reads outside the
project, web fetch, and any "allow once / allow always / reject" choice. Count **each halt**,
not each distinct tool. If the agent asks for the same command shape three times, that is
three approvals — that repetition is the whole point of the allowlist question.

**Not counted as an approval:** OS-level dialogs (Gatekeeper, SmartScreen), the SSH
`known_hosts` fingerprint prompt, browser download confirmations. Count these separately as
**OS friction** — they matter for Prompt Zero but they are a different problem.

**A human intervention** = anything you had to do beyond approving: answering a question,
correcting a wrong path, pasting a value, restarting the agent, fixing something by hand,
looking something up for it, or nudging a stalled session after the 60-second rule. Log each
one as one line: `HH:MM · what happened · what I did · would a non-developer have known this?`
That last clause is the field that changes the product.

**Unattended after approvals** = yes only if, once approvals were granted, the agent went from
prompt to running app with **zero** interventions by the definition above.

**Wall clock to running app** = S5/S7 start → verification URL returns the expected string.
Exclude the Claude Code install (S2) and VPS creation (S3); those are recorded separately as
one-time Prompt Zero costs.

---

## 7. Output template

Fill both platforms. This table is the spike's deliverable — its numbers go into Prompt Zero
copy and the agent-compatibility matrix.

### 7.1 One-time setup cost (per platform, Prompt Zero's real subject)

| Metric | macOS <version> | Windows 11 <build> |
|---|---|---|
| Machine was genuinely clean (Y / N + what leaked) | | |
| Claude Code install — minutes | | |
| Claude Code install — account/plan required | | |
| Claude Code install — OS dialogs shown (count + which) | | |
| Reboots required | | |
| Shell the agent actually runs in | | |
| Hetzner signup → server IP — minutes | | |
| Hetzner KYC / card / verification friction (1 line) | | |
| Decisions in the create flow a beginner can't answer (count + which) | | |
| ssh-keygen + ssh config → `ssh vps` works — minutes | | |
| **Total: nothing installed → `ssh vps` works — minutes** | | |
| Agent-plan usage consumed by the whole spike (and $) | | |

### 7.2 Install runs (platform × subject)

| Metric | Vaultwarden / macOS | Vaultwarden / Win11 | Immich / macOS | Immich / Win11 |
|---|---|---|---|---|
| Allowlist in effect (none / describe) | none | none | | |
| **Permission approvals requested** | | | | |
| — of those, distinct command shapes | | | | |
| OS-friction dialogs (separate count) | | | | |
| **Wall clock, prompt → running app (min)** | | | | |
| Tier band this implies | | | | |
| **Human interventions (count)** | | | | |
| Intervention list (see log) | | | | |
| **Completed unattended after approvals? (Y/N)** | | | | |
| Agent stalls ≥60 s (count + longest) | | | | |
| Context exhausted / plan limit hit? | | | | |
| Agent claimed done while app was NOT reachable? (Y/N) | | | | |
| Verification string matched on first check? (Y/N) | | | | |
| Idle RAM after 5 min (MB) | | | | |
| Disk used (GB) | | | | |
| Anything the prompt should have said and didn't | | | | |

### 7.3 Deeplink round-trip (`claude-cli://open?q=`)

| Payload | Encoded length | macOS / Safari | macOS / Chrome | Win11 / Edge | Win11 / Chrome |
|---|---|---|---|---|---|
| L1 ~200 (real short instruction) | | | | | |
| L2 1,000 | | | | | |
| L3 2,000 | | | | | |
| L4 4,000 | | | | | |
| L5 8,000 | | | | | |
| L6 full prompt ~14,000 | | | | | |

Cell values: `open+prefill+canary` / `open+prefill+TRUNCATED` / `opened, empty` /
`no handler` / `blocked by browser`.

| Deeplink summary | macOS | Windows 11 |
|---|---|---|
| Scheme registered by the installer? | | |
| Confirmation dialog wording (verbatim) | | |
| **Truncation threshold (encoded chars)** | | |
| Auto-sent without pressing enter? (must be N) | | |
| L1 end-to-end: opened → enter → agent fetched the `.md` and started (Y/N) | | |

### 7.4 Verdicts

| Gate (§8) | Result | Consequence |
|---|---|---|
| G1 approvals | | |
| G2 deeplink | | |
| G3 unattended | | |
| G4 Windows path | | |
| G5 hard case | | |
| G6 false-done | | |

---

## 8. Decision gates

Evaluate each after both platforms are done. A tripped gate is not a delay — it is the spike
paying for itself.

**G1 — Approval volume.**
PASS: ≤15 approvals for Vaultwarden with defaults, **or** a durable allowlist exists that a
non-developer can apply in under 5 minutes and it cuts the count below 15.
TRIP: >15 approvals **and** no allowlist path → rethink the execution model. Options, in order
of preference: (a) Prompt Zero ships an explicit permission-configuration step as a
first-class part of setup, and the site states the count honestly per project; (b) prompts get
restructured to batch remote work into fewer, larger, *reviewable* commands; (c) the primary
path becomes the deterministic fallback (`install.sh` over SSH), with the agent demoted to a
guide. (c) is a product change — it would move the promise line and half of Prompt Zero.

**G2 — Deeplink payload.**
PASS-AS-DESIGNED: L1 round-trips and something above it truncates → **confirmed
short-instruction-only**; ship `claude-cli://open?q=<short instruction pointing at the .md>`,
and never the payload. This is the expected outcome; record the threshold anyway, because the
threshold is what stops someone "optimizing" it back later.
TRIP A: L1 itself truncates or does not prefill → the deeplink button is theater. Replace it
with copy-to-clipboard + a one-line "paste this" instruction, and drop the "open in Claude
Code" affordance on that OS.
TRIP B: the scheme is not registered on Windows → the compatibility matrix must state
per-OS deeplink support, and the Windows path is copy-only. Do not ship a button that does
nothing.
TRIP C: it **auto-sends** without the human pressing enter → remove the button entirely until
that changes. Shipping a link that makes a stranger's agent start executing is not acceptable
at any conversion rate.

**G3 — Unattended completion.**
PASS: Vaultwarden completes with zero interventions after approvals.
TRIP: it does not → prompts must be written as **checkpointed segments** with explicit
human-verifiable stopping points, and the style guide gets a mandatory "checkpoint" rule
before any prompt is written. Also changes the page: "what this prompt will do" becomes a
checklist the reader tracks, not an outline they skim.

**G4 — Windows viability.**
PASS: total nothing-installed → `ssh vps` is under ~45 min with at most one reboot.
TRIP: a BIOS change is required, or it takes >90 min, or the WSL/native shell split breaks the
SSH key → Prompt Zero needs a separate, honest Windows pre-flight page, and the homepage
promise line gets a Windows caveat. Consider stating plainly that Windows readers should
budget an evening for setup alone. Do not smooth this over; r/selfhosted will find it.

**G5 — Hard-case survivability.**
PASS: Immich reaches a working first screen within the ONE EVENING band (≤3 h) with the agent
still coherent.
TRIP: context exhaustion, plan limits, or a bailed model download → multi-container projects
need either a segmented prompt shape or a tier demotion (ONE WEEKEND), and the tier-band
validator (`timeToRunningMin` inside the derived tier's band) gets calibrated from this number
rather than from a guess.

**G6 — False-done.**
TRIP (any occurrence): the agent declared success while the app was not reachable → **every**
prompt must end with a machine-checkable assertion the agent has to run and show output for
(HTTP status + expected first-screen string), and the style guide's verification checklist
becomes non-optional. One occurrence is enough to make this a rule; this is the single most
damaging failure mode for the site's credibility.

---

## 9. Teardown (do not skip)

Per server, immediately after its run:

1. Delete the server in the Hetzner console. Confirm it disappears from the project list.
2. Check for **orphans that keep billing**: volumes, snapshots, backups, floating IPs, primary
   IPs, load balancers, images. Delete them. Hetzner bills a reserved primary IP after the
   server is gone — this is exactly the trap the harness sweeper exists to prevent (§9), and
   experiencing it by hand is useful.
3. Confirm the project shows **zero resources**. Screenshot it into the log.
4. Check the account's usage/billing page and confirm the running cost went to zero. Note the
   total spent — it belongs in Prompt Zero's cost table.
5. Remove the spike key: delete it from the Hetzner project's SSH keys, and delete
   `~/.ssh/id_ed25519*` and the `Host vps` block from the test account.
6. Any secrets the agent generated on the server died with the server. Confirm none were
   echoed into your log or the chat transcript — if any were, scrub them, and note it as a
   style-guide finding (secrets must be generated on the server and never surfaced).

---

## 10. Where the output goes

When both platforms are done, the filled §7 table is the source of record. Route it:

- **Prompt Zero** (`/prompt-zero/`) — §7.1 numbers verbatim; the honest bill; the Windows
  reboot truth; the permission framing sentence from §6's "would a non-developer have known
  this?" column.
- **Agent compatibility matrix** (§4.5) — the per-OS deeplink support row and the tier claim.
- **`docs/prompt-style-guide.md`** — every "anything the prompt should have said and didn't"
  cell, plus any G3/G6 rules the gates turned on. Send these to the guide's owner; do not
  edit the guide from here.
- **`data/projects/immich/`** — the draft prompt written during the spike, with its findings
  as review notes. Still a draft. No verified date.
- **Tier bands (§8) and `timeToRunningMin` validator** — the two wall-clock numbers are the
  first real calibration points.
- **`/methodology/`** — one line that this spike happened, when, and that it is
  reconnaissance, not verification.

Nothing from this spike gets published as a verified result. It sets expectations; the harness
earns stamps.
