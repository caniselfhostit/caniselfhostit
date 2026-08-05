# Install prompt · style guide

How to write `data/projects/<slug>/prompt.md`, the file a reader pastes into Claude Code to
get a pinned, TLS-terminated, backed-up service running on their own VPS. Also how to write
`prompt-chat.md`, the slower fallback for people who only have a chat window.

This guide is written before any prompt is. All 50 launch prompts are drafted against it and
reviewed against it. A prompt that fails the checklist in the last section does not go to the
harness, and a prompt the harness has not passed does not get a verified stamp (PRD §9).

Two things this guide is not. It is not documentation: the reader never reads prompt.md as
prose, an agent executes it. It is not a template to fill in: the ~94 template-generated
prompts on the sibling site are the failure this project exists to avoid.

## What ports from the sibling guide, and what inverts

We adapt `canivibecodeit/scripts/prompt-style-guide.md` (MIT, credited on `/about` and
`/methodology`). Same discipline, different job.

Ports unchanged: one opinionated path, concrete acceptance criteria over adjectives, banned
marketing words, out-of-scope phrased as instructions, honest warnings kept in the prompt, no
em dashes.

Inverts:

| Their rule | Ours |
|---|---|
| No Docker at personal scale | Docker Compose is the only supported runtime |
| SQLite or flat files, no Postgres | Whatever the upstream image expects, pinned, in one compose file |
| Secrets in `.env` on the reader's laptop | Secrets generated **on the server**, never in the prompt |
| Flat `- ` bullets, no headings, 15-30 lines | Numbered `##` step blocks, 150-260 lines |
| Builds new software | Installs existing software at a stated version |
| "Include a README" | "Take a backup and prove you can restore it" |

The last row is the real difference. Their prompt produces a toy that can be thrown away. Ours
produces a system holding the reader's passwords, photos or invoices on a machine they have
never administered. Every rule below follows from that.

## Why install prompts fail

Condensed from the Phase-0 agent spike (§4.5) and from reading what the sibling's
template-generated prompts actually do.

- **Unpinned versions.** The prompt worked in March and installs different software in June.
  A prompt without a pin is not a prompt, it is a wish with a code fence.
- **A menu instead of a decision.** "Nginx, Caddy or Traefik, whichever you prefer" makes the
  agent choose, and it chooses differently on different runs. To a reader who has never
  administered a server, nondeterminism is indistinguishable from a bug.
- **No verification string.** The agent sees three containers in `docker ps`, declares success,
  and the reader gets a 502. The agent was not lying, it was never told what success looks like.
- **Secrets in the prompt text.** A secret written into prompt.md is in the page HTML, in the
  `.md` mirror, in the reader's clipboard history, in their agent's transcript, and identical
  for every reader who ever pasted it.
- **"Follow the upstream docs."** That hands a root shell to whatever a web page says today.
  It is the prompt-injection hole, and it is the one a security researcher will find first.
- **No backup.** The first mistake is permanent, the reader concludes self-hosting is a trap,
  and they are right to.
- **No stated resource floor.** The agent installs a 4 GB service on a 1 GB box, the OOM killer
  arrives during the third import, and the failure looks random. It was decided at checkout.

## Required shape

`prompt.md` has exactly this shape. The order is fixed. A reviewer checks the order first
because it is the cheapest check.

### (a) The frame line, verbatim

Every prompt opens with this paragraph, byte-identical across all 50. Do not reword it, do not
localise it, do not add to it. CI greps for it.

```
You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.
```

Immediately after it, one line stating the command convention, also verbatim:

```
Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.
```

### (b) The goal line

One sentence. Names the software, the pinned version, the hostname it will answer on, and
nothing else.

```
Install Vaultwarden 1.34.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.
```

Placeholder vocabulary is closed. `<DOMAIN>` is the full hostname the reader has already
pointed at the VPS. `<ADMIN_EMAIL>` is allowed only where the app's first account requires an
email address. Nothing else. No `<VPS_IP>` (the alias is `vps`), no `<PASSWORD>`, no `<TOKEN>`.
Step 1 tells the agent to stop and ask once if a placeholder is still literal.

### (c) The step blocks

Eleven `## N. Title` blocks, in this order, with these contents. Blocks are never merged,
reordered or dropped. A block that genuinely does not apply says so in one line and keeps its
number.

| # | Block | Must contain | Acceptance criterion the block ends on |
|---|---|---|---|
| 1 | Preflight | RAM floor in MB, disk floor in GB, arch support, the commands that measure them, the stop rule | Measured values printed; agent stops if under floor |
| 2 | Layout | `/srv/<app>/` and its subdirectories, ownership, modes | `ls -la /srv/<app>` shows the tree |
| 3 | Secrets | `openssl rand` generation on the server, target `.env`, mode 600, the do-not-print instruction | `.env` exists, mode 600, agent has printed no value |
| 4 | compose.yml | The full file by heredoc, image pinned tag + digest, ports bound to `127.0.0.1` | `docker compose config` exits 0 |
| 5 | Caddy and TLS | The site block, `reverse_proxy` target, the reload command, one clause on auto-renewal | `caddy validate` passes, reload exits 0 |
| 6 | Firewall | Exactly which ports open and which stay closed, the `ufw` commands, one clause of justification each | `ufw status` output matches the stated set |
| 7 | Start and verify | The exact URL and the exact first-screen string, the assert, the stop-on-mismatch instruction, any `STOP:` line | Both asserts pass and are printed |
| 8 | First backup and restore | Backup command, destination path, non-empty proof, off-box copy, restore steps | Archive exists, size printed, restore steps stated |
| 9 | Updating later | Where the next digest comes from, the three commands, back-up-first reminder | Nothing to run now; the block is the deliverable |
| 10 | What will probably go wrong | Exactly one honest warning, first person, from the verification run | Nothing to run; one paragraph |
| 11 | Out of scope | 2-4 imperatives to the agent | Nothing to run; a bullet list |

Blocks 9, 10 and 11 run no commands. They are still numbered blocks because the reader scrolls
the rendered prompt on the page, and because a reviewer greps for `## 10.` to confirm the
honest warning exists.

### (d) Length and formatting

- **Size: 10,000 to 15,000 bytes** (`wc -c`), which lands near the 3,400-token target in
  PRD §5.3. Under 10,000 you have underspecified something, most often preflight or restore.
  Over 15,000 you are writing documentation, move it to the page body. Hard ceiling 16,500.
- **150-260 lines.** Wrap prose at 90 columns. Never wrap a command.
- No YAML front matter, no H1. The whole file is the payload: anything in it that is not
  addressed to the agent is a bug. The page supplies the H1, the metadata and the citations.
- Steps are `## N. Title`. No H3. No nested lists deeper than one level.
- Fenced code blocks carry a language (` ```bash `, ` ```yaml `, ` ```caddyfile `). One command
  per line. No `$` or `#` prompt prefixes, the reader copies these.
- Files are written on the server with a **quoted** heredoc delimiter, `<<'EOF'`, so that `$`
  in a compose file or Caddyfile does not expand. There is exactly one exception in the whole
  prompt: the `.env` heredoc in block 3 is unquoted, because `$(openssl rand ...)` has to run.
  That file therefore contains no other `$`, and the block sets `umask 077` before writing so
  the file is never briefly world-readable. Any other unquoted heredoc is a defect.
- Prompt Zero leaves the login user in the `docker` group, so `docker` commands carry no
  `sudo`. Anything touching `/etc` does. Prompt Zero states plainly that docker-group
  membership is root-equivalent; do not re-argue it here.
- ASCII only, plus `·`. No em dashes: use a comma, a period, or `·`.
- The compose block and the Caddy block are **byte-identical** to the project's `compose.yml`
  and `Caddyfile` between the fence markers. CI diffs them. The deterministic fallback (§4.3)
  and the prompt must never drift, and the prompt must never tell the agent to download either
  file from our site.

## Rules

Apply all thirteen. Reviewers cite them by number.

**1. Pin the image, and state the update path.** Every image reference carries a human tag and
a digest: `vaultwarden/server:1.34.2@sha256:<64 hex>`. Never `:latest`, never a bare major, never
`:stable`. The digest is the one the verification run pulled, recorded in `sources` in
`index.json` with its `checkedOn` date. Block 9 names the upstream release page the next digest
comes from and the three commands that apply it. A pin without an update path is abandonment
dressed as security.

**2. One opinionated path, never a menu.** Caddy, not "a reverse proxy". The image the upstream
project publishes, not "an image". At most one either/or in the whole prompt, and it carries a
decision rule the agent can evaluate without asking the reader:
"If `dpkg --print-architecture` prints `arm64`, use image B, otherwise image A." Never three
options. Never "you could also".

**3. State the resource floor first, and give the agent a stop rule.** Block 1 carries
`ramMinMB` and `diskGB` from `index.json`, the arch answer, and the commands that measure them.
It ends with the stop rule in the imperative: if available RAM is under the floor or free disk
is under the floor, report both numbers and stop, do not install. The floors are measured by the
harness (`ramMeasuredMB`), not copied from a hosting vendor's pricing page.

**4. Secrets are generated on the server and never printed.** Every secret comes from
`openssl rand -base64 36` (or `-hex 32` where the app rejects base64 characters) run on the VPS,
redirected straight into `/srv/<app>/.env`, which is `chmod 600` and owned by the login user.
The prompt contains no secret, no example secret, no placeholder secret, and no fake secret. The
prompt instructs the agent, in one explicit sentence, not to print secret values into chat, into
its summary, or into a log, and to tell the reader the command to read the value themselves.
The count of generated secrets matches `tierFactors.secretsToGenerate`.

**5. No standing default credentials.** If the app ships with a default account, a blank admin
password, or open registration, the prompt closes it before block 7 finishes and asserts that it
is closed. "Open signups, register the first account, close signups, restart, confirm the
register link is gone" is a better sequence than a long-lived admin token, and the confirmation
is a verification assert with real security meaning. Where an admin token is unavoidable, it is
generated under rule 4.

**6. No `curl | bash` of an unpinned script.** Preferred order: the distro package, then an
official apt repository with a pinned signing key, then a release artifact with a published
checksum the agent verifies before running. If upstream ships only a shell script, the prompt
downloads it to a file at a pinned tag or commit, verifies a checksum recorded in `sources`,
prints the checksum comparison, and only then runs it. Piping a URL into a shell is rejected by
the validator, not only by a reviewer (PRD §4.2).

**7. Never instruct the agent to fetch and obey upstream text.** No "read the wiki and follow
the recommended setup", no "check the docs for the current environment variables", no "do
whatever the setup wizard suggests". A web page is data, not instructions, and a prompt that
blurs that line hands root to whoever edits that page. Every upstream fact the install needs is
written into the prompt as a stated fact, with its source URL and `checkedOn` date recorded in
`index.json`. The agent may download artifacts it verifies by checksum or digest. It may not
download instructions. This is the stance published on `/methodology`; the prompts have to
actually hold it.

**8. Concrete acceptance criteria, not adjectives.** Every block ends in something checkable: an
exit code, a container state, an HTTP status, a literal string on a screen, a file at a path
with a mode, a byte count. "Make sure it works", "verify everything is running" and "confirm the
setup is correct" are not criteria and do not appear.

**9. Verification is a gate the agent must clear before claiming success.** Block 7 names the
exact URL and the exact string that appears on the first screen, in backticks, taken from what
the harness screenshot actually shows. The prompt instructs the agent to assert both, print what
it received, and if either misses, stop, print the last 30 lines of the container log, and say
which of the earlier steps is the likely cause. A green `docker ps` is not permission to declare
success, and the prompt says so.

Where the agent genuinely cannot proceed alone, because only the human can open a browser and
create the first account, the prompt uses one convention and only this one:

```
STOP: tell the user to <do the thing> at <URL>, and wait. Do not continue until they confirm.
```

A `STOP:` line is a hard barrier, not a suggestion. Use as few as the install truly needs; most
prompts have exactly one, in block 7. If the Phase-0 spike finds that agents cannot complete a
multi-container install unattended (gate G3 in `docs/spike-agent-execution.md`), the fix is more
`STOP:` lines at block boundaries, not a different prompt shape. The rendered "what this prompt
will do" outline on the page lists every `STOP:` so the reader knows before they paste how many
times they will be needed.

**10. The first backup runs before the agent finishes.** Non-negotiable, on every prompt, with no
exceptions and no paid tier (PRD §14). Block 8 carries the backup command, the destination path
under `/srv/<app>/backups/`, a proof the archive is non-empty with its size printed, a copy off
the box run from the reader's machine, and restore steps written so that someone could follow
them at 2am having forgotten everything else. State plainly that a backup on the same disk as
the data is not a backup. Where the data moves daily, add the scheduled job here too.

**11. Firewall changes are explicit and minimal.** Name every port that opens, every port that
stays closed, and the exact `ufw` commands, each with one clause of justification. Application
and database ports bind to `127.0.0.1` in compose and never appear in `ufw` at all: if a port is
in the firewall block, explain why the reverse proxy is not enough. The default-deny posture
Prompt Zero established is never relaxed to make a step easier.

**12. Scope discipline.** Block 11 carries 2-4 items, phrased as instructions to the agent, not
as apologies to the reader. "Do not configure SMTP." "Do not switch the database to PostgreSQL."
"Do not enable push notifications." Choose the things this agent would otherwise attempt, which
is usually whatever the upstream README mentions in passing. The reader-facing version of the
same information lives in `whatYouSignUpFor` on the page, written differently.

**13. Voice: direct, technical, imperative.** You are a competent operator who has done this
install, telling an agent to do it again. Two registers, never mixed:

- **Agent-directed text is imperative and calls the reader "the user".** "Generate the token on
  the server." "Ask the user once, then stop." Never "my server", never "we".
- **The honest warning in block 10 is first person**, because it is first-hand experience from
  the verification run and that is exactly what makes it worth reading. "I watched this look
  like a broken install for five minutes." One paragraph, then back to the imperative.

The sibling's blanket first person ("my calendar", "my timezone") does not port: their prompt is
written by the reader for themselves, ours is written by us and shipped to strangers.

## Banned words

Inherited from the sibling, absolute: **seamless · powerful · beautiful · delightful · robust ·
blazing · intuitive · production-ready**.

Added for this project: **enterprise-grade · battle-tested · simply · just**.

`enterprise-grade` and `battle-tested` are claims about someone else's operational history that
we have not verified and cannot. `simply` and `just` are worse. They are minimisers, and the
reader who hits them is by definition the reader who is stuck: "simply run the install script"
is what a person reads at the exact moment the install script has failed. Delete them; the
sentence is always shorter and truer without them.

If a word could appear on a landing page, cut it. The apps we install have marketing sites
already.

Separately banned, for a different reason: **template leftovers**. Their presence proves the
prompt was generated, not written. From the sibling's generator: `Core loop:`, `Needs: X.`,
`Honest scope: this covers the core loop only. You will not get:`. From ours, kill on sight:
"It should now be working", "You may need to", "or similar", "the necessary ports", "the
appropriate directory", "follow the prompts".

## The chat fallback · `prompt-chat.md`

For readers who have ChatGPT or Claude.ai and no agent. Same facts, restructured so a human
executes them. It renders as a tab on the project page, never its own URL (PRD §4.4), so it
carries no H1 and repeats no page prose.

**It opens honest, in two sentences.** This path is slower, you paste every command yourself,
and there is nobody watching the output but you. If you can run Claude Code, use the other tab.
No apology beyond that, and no hedging about how it is "still a great option".

**Shape.** Same eleven blocks, same order, same numbers, so a reader can move between tabs
without losing their place. Inside each block the unit changes from an instruction to a triplet:

1. One command block to paste, short enough to read before running.
2. `You should see:` and the literal output, or the shape of it.
3. `If you do not:` and the one most likely cause, with the fix.

The third line is the whole reason this file is longer than prompt.md. Expect 1.2 to 1.6 times
the byte count. That is correct, not bloat.

**One added rule, chat only.** State explicitly, in block 3, that the reader must not paste
`.env` contents, tokens, or any command output containing a secret back into the chat window.
The agent path never sees those values; the chat path will hand them to a third party unless the
file says not to. Put it where the secret is generated, not in a preamble nobody reads.

**No new facts.** `prompt-chat.md` is derived from `prompt.md` and must agree with it on the
version string, the digest, the published ports, the verification URL and string, the backup
path, and the out-of-scope list. The reviewer diffs those. Same banned words, same honest
warning, same backup step, and the backup step is not softened because a human is running it.

`prompt-local.md`, where `localVariant` is true, follows the same rules with the Caddy, TLS,
firewall and DNS blocks replaced by a `127.0.0.1` binding and one line explaining that nothing
is reachable from the internet. It keeps blocks 8, 9, 10 and 11 unchanged.

## Worked example · Vaultwarden

The digests, versions and timings in this section are illustrative. Never copy a digest out of
this guide. Every real prompt carries the digest its own verification run pulled.

### Before

Template output. It has the shape of a prompt and none of the properties. Failure modes, in
order of appearance: marketing adjectives and two banned words; `curl | bash` of an unpinned
script; `:latest`; a default credential written into the prompt text; a three-way menu; a
firewall instruction that names no ports; fetch-and-obey; no verification string; no backup; no
resource floor; and a scope note that apologises to the reader instead of instructing the agent.

````
Install Vaultwarden on my server so I can stop paying for 1Password. It should be
production-ready and battle-tested.

- Set up Docker on the VPS if it isn't there, then simply run the official install
  script: curl -sL https://get.example.dev/vaultwarden | bash
- Use the vaultwarden/server:latest image so it stays up to date automatically.
- Set ADMIN_TOKEN=changeme123 in the environment so I can reach the admin page.
- Put it behind a reverse proxy. Nginx, Caddy or Traefik are all fine, use whichever
  you prefer.
- Open the necessary ports on the firewall.
- Read the Vaultwarden wiki and follow their recommended production setup.
- Check that it's working when you're done.

Honest scope: this covers the basics only. You will not get: mobile push
notifications; SMTP; enterprise SSO.
````

### After

Abridged to the load-bearing lines. A real prompt.md carries every block at full length and
lands between 10,000 and 15,000 bytes.

````
You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Vaultwarden 1.34.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
The A record for it must already point at this server.

Vaultwarden needs 512 MB of RAM available and 2 GB free on /srv. It runs on amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
docker compose version
```

If available RAM is under 512 MB or free disk is under 2 GB, print both numbers and stop. Do not
install and hope.

## 2. Layout

```bash
install -d -m 750 /srv/vaultwarden /srv/vaultwarden/data /srv/vaultwarden/backups
```

Everything for this service lives under /srv/vaultwarden and nothing is written outside it.

## 3. Secrets

Generate the admin token on the server. Do not print it, do not repeat it in your summary, and
do not include it in any log line.

```bash
umask 077
cat > /srv/vaultwarden/.env <<EOF
DOMAIN=https://<DOMAIN>
SIGNUPS_ALLOWED=true
ADMIN_TOKEN=$(openssl rand -base64 36)
EOF
chmod 600 /srv/vaultwarden/.env
```

Tell the user: their admin token is in /srv/vaultwarden/.env, they can read it with
`grep ADMIN_TOKEN /srv/vaultwarden/.env`, and they should put it in their password manager now.
SIGNUPS_ALLOWED is true only until step 7 closes it.

## 4. compose.yml

```bash
cat > /srv/vaultwarden/compose.yml <<'EOF'
services:
  vaultwarden:
    image: vaultwarden/server:1.34.2@sha256:3f9c1a7e0b5d42c8ae61f0d7b2c4e98a15d3e6f70b8c9a2d4e1f6b3c8a705d29
    container_name: vaultwarden
    restart: unless-stopped
    env_file: /srv/vaultwarden/.env
    volumes:
      - /srv/vaultwarden/data:/data
    ports:
      # Loopback only. Caddy is the only thing that reaches this port.
      - "127.0.0.1:8222:80"
EOF
cd /srv/vaultwarden && docker compose config >/dev/null && echo "compose OK"
```

WebSocket notifications ride the same port on 1.29 and later, so there is no second route.

## 5. Caddy and TLS

```bash
cat >> /etc/caddy/Caddyfile <<'EOF'

<DOMAIN> {
  encode zstd gzip
  reverse_proxy 127.0.0.1:8222
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy requests the certificate on first request and renews it on its own. Nothing to schedule.

## 6. Firewall

No firewall change is needed. 80 and 443 are already open from Prompt Zero, and 8222 is bound to
loopback, so it must not be opened. Confirm the current state and print it:

```bash
sudo ufw status verbose
```

If 8222 appears in that output, remove it: `sudo ufw delete allow 8222`.

## 7. Start and verify

```bash
cd /srv/vaultwarden && docker compose up -d
sleep 10
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

Assert: that command prints `200`. If it prints anything else, stop, run
`docker compose logs --tail 30 vaultwarden`, and say which earlier step is the likely cause.
The most common one is DNS: if the A record was created minutes ago, Caddy's first certificate
attempt fails and retries.

The first screen at https://<DOMAIN> shows the heading `Log in` and a `Create account` link.

STOP: tell the user to open https://<DOMAIN> and create their account, and wait. Do not continue
until they confirm.

Once they confirm, close registration and restart:

```bash
sed -i 's/^SIGNUPS_ALLOWED=true$/SIGNUPS_ALLOWED=false/' /srv/vaultwarden/.env
cd /srv/vaultwarden && docker compose up -d --force-recreate
sleep 10
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

Assert: `200` again, and the user reloads the page and confirms the `Create account` link is
gone. Both asserts must pass before you report success. A running container is not success.

## 8. First backup and restore

Take the backup now, before the user puts a single password in.

```bash
cd /srv/vaultwarden
docker compose stop
tar -C /srv/vaultwarden -czf /srv/vaultwarden/backups/vaultwarden-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/vaultwarden/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/vaultwarden
scp vps:/srv/vaultwarden/backups/*.tar.gz ~/backups/vaultwarden/
```

To restore: `docker compose down`, `rm -rf /srv/vaultwarden/data`, untar the archive back into
/srv/vaultwarden, then `docker compose up -d`. The vault is in `data/db.sqlite3`; the token is
in `.env`. Tell the user these five commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/dani-garcia/vaultwarden/releases. Take a backup
first, then edit the image line in /srv/vaultwarden/compose.yml to the new tag and digest, then:

```bash
cd /srv/vaultwarden
docker compose pull
docker compose up -d
docker compose logs --tail 20 vaultwarden
```

## 10. What will probably go wrong

DNS. Caddy cannot issue a certificate until `<DOMAIN>` resolves publicly, and if the A record
was created a few minutes ago the first attempt fails and quietly retries. I watched that look
like a completely broken install for five minutes before the certificate appeared. If step 7
returns anything other than 200, run `dig +short <DOMAIN>` before touching anything else.

## 11. Out of scope

- Do not configure SMTP. Vaultwarden works without it; password hint email is not worth the
  port-25 fight on a fresh VPS.
- Do not switch the database to PostgreSQL. SQLite is the choice here.
- Do not enable Bitwarden push notifications. They need keys issued by Bitwarden, which is a
  separate signup.
- Do not install fail2ban or any other add-on. This prompt installs one service.
````

### What changed, mechanically

1. "production-ready and battle-tested" deleted: two banned words in one clause, and neither
   is a claim we verified (banned words, rule 13).
2. `curl -sL ... | bash` deleted entirely. Docker is already present from Prompt Zero, so the step
   was not only unsafe, it was unnecessary (rule 6).
3. `:latest` became `1.34.2@sha256:...`, and block 9 now names the release page the next digest
   comes from plus the three commands that apply it (rule 1).
4. `ADMIN_TOKEN=changeme123` became `openssl rand -base64 36` redirected into a 600 `.env` on the
   server, with an explicit instruction not to print it and a command the user runs themselves to
   read it. The prompt now contains no secret at all (rule 4).
5. Open registration, which the draft never mentioned, is now opened deliberately for one step
   and closed with an assert that the register link is gone (rule 5).
6. The Nginx/Caddy/Traefik menu became one Caddy site block, because Prompt Zero installed Caddy
   and a second reverse proxy on the same box is a bug, not a preference (rule 2).
7. "Open the necessary ports" became a block that opens nothing, states why 8222 is on loopback,
   and tells the agent to remove the rule if a previous run left one (rule 11).
8. "Read the Vaultwarden wiki and follow their recommended production setup" is gone. The two
   facts it was standing in for, the WebSocket port behaviour and the `/alive` endpoint, are now
   written into the prompt as stated facts with sources recorded in `index.json` (rule 7).
9. "Check that it's working" became two asserts on a named URL, a named status code, a named
   first-screen string, a stop-on-mismatch instruction with a log command, a `STOP:` barrier at
   the one point only the human can clear, and an explicit "a running container is not success"
   (rules 8 and 9).
10. A backup block appeared where there was none: local archive, size assert, off-box copy run
    from the reader's machine, and a five-command restore (rule 10).
11. A preflight block appeared: 512 MB, 2 GB, both architectures, the measuring commands, and a
    stop rule (rule 3).
12. The apology paragraph became four imperatives to the agent, each naming something this agent
    would otherwise try because the upstream README mentions it (rule 12).
13. The one thing the draft was missing that no rule forces: block 10. The DNS timing warning is
    first-hand, it cost real minutes in the verification run, and it is the single most useful
    paragraph in the file for a reader whose install is not working (rule 13).

## Verification checklist

Ten checks. A reviewer runs all of them before a prompt is eligible for a harness run. Any miss
sends the prompt back; there is no partial pass.

1. **Shape.** Frame line and command-convention line byte-identical to this guide. Goal line
   names the software, the pinned version and `<DOMAIN>`. All eleven blocks present, in order,
   correctly numbered. `wc -c` between 10,000 and 15,000.
2. **Pins.** Every image carries a tag and a digest. No `:latest`, no bare major, no `:stable`.
   Block 9 names a real upstream release URL. The version string is identical in `prompt.md`,
   `compose.yml`, `prompt-chat.md` and `index.json`.
3. **Secrets.** No secret, token, password or example value anywhere in `prompt.md` or
   `prompt-chat.md`. Every secret generated on the server by `openssl rand`. `.env` is written
   with `chmod 600`. The do-not-print instruction is present and explicit. The number of secrets
   matches `tierFactors.secretsToGenerate`. No standing default credential survives block 7.
4. **Network.** Only 80 and 443 published. Application and database ports bound to `127.0.0.1`
   in the compose block. Every `ufw` change is explicit and justified in a clause. The Caddy
   block is present, uses automatic TLS, and hardcodes no certificate paths.
5. **Fetch discipline.** No pipe from a URL into a shell. Every downloaded artifact is pinned and
   checksum-verified with the comparison printed. Nowhere is the agent told to read upstream text
   and act on it. Every upstream fact in the prompt has a `sources` entry with a `checkedOn` date.
6. **Verification gate.** Exact URL and exact first-screen string, in backticks, matching what
   the harness screenshot shows. The agent is told to assert, print what it got, stop on
   mismatch, and pull logs. The "a running container is not success" instruction is present.
   Every human-in-the-loop pause uses the `STOP:` convention, and the count of `STOP:` lines
   matches the count shown in the page's "what this prompt will do" outline.
7. **Backup.** A backup runs before the prompt ends. Destination path stated, non-empty proof
   with size printed, off-box copy explicitly run from the reader's machine, restore steps
   complete enough to follow cold. The same-disk warning is present.
8. **Candor and scope.** Exactly one honest warning, in block 10, first person, naming a real
   step from the run rather than a generic caution. Block 11 has 2-4 items, all phrased as
   imperatives to the agent, none of them an apology to the reader.
9. **Language.** No banned word. No em dash. No template leftover. No unresolved placeholder
   outside `<DOMAIN>` and `<ADMIN_EMAIL>`. Every heredoc uses a quoted delimiter except the
   block-3 `.env` heredoc, which is unquoted, preceded by `umask 077`, and contains no `$`
   beyond its `openssl rand` substitutions. Every numeric claim matches `index.json`
   (`ramMinMB`, `diskGB`, `timeToRunningMin`, the version).
10. **Fallback parity.** `prompt-chat.md` agrees with `prompt.md` on version, digest, ports,
    verification URL and string, backup path, warning and out-of-scope list; carries the
    `You should see:` / `If you do not:` triplets; and carries the do-not-paste-secrets line in
    block 3. The embedded compose and Caddy blocks are byte-identical to `compose.yml` and
    `Caddyfile`.

## After the checklist: where "verified" lives

Passing the checklist does not publish anything. It makes the prompt eligible for a harness run.

**Do not add a verified flag to `index.json`.** Verification state lives in Supabase
`verification_runs` (status `verified` or `pending`, date, version, host, screenshot reference),
per PRD §6.2. The sequence is:

1. Reviewer passes the checklist above.
2. The harness creates a clean box, runs the deterministic fallback, asserts the health endpoint
   and the first-screen string, takes the Playwright screenshot, and destroys the box (PRD §9).
3. The harness writes the `verification_runs` row.
4. The nightly build reads that row and renders the "TESTED ON A CLEAN MACHINE" stamp.

The point of keeping it out of the repo is the downgrade path: when a re-test fails, the page
goes to `pending` at the next nightly build, with no human commit and no chance of a stale
`true` sitting in JSON for a month. It is the same reason `setupTier` is derived from
`tierFactors` and the validator rejects a stored key. The sibling's cautionary number is
`verifiedOneShot: false` in all 976 of its entries. Ours is earned or absent.

Two more things happen at the same time:

- `contentUpdatedAt` moves when `prompt.md` changes substantively. The validator hashes the
  content fields; a moved hash with an unchanged date fails CI.
- A pinned release that ships a new version opens a re-test task. A prompt is a claim about a
  specific version on a specific date, and it expires.
