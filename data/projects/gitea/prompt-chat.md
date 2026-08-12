This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Gitea 1.27.1 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read these before step 1. The hostname becomes `GITEA__server__DOMAIN` and
`GITEA__server__ROOT_URL`; clone links and redirects are wrong if they disagree with the browser.
The first account created in the install wizard is the admin (first claimant), so open the URL
and finish that before anyone else can. This install does not publish git over SSH; pushes and
pulls use HTTPS with a personal access token. After the first account, you will set
`GITEA__service__DISABLE_REGISTRATION=true` and prove the signup form is gone.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP. If dig is empty, add the A record and wait. Caddy cannot certify a name that does
not resolve, and ROOT_URL would point at nothing useful.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/gitea /srv/gitea/backups /srv/gitea/data
ls -la /srv/gitea
```

You should see `backups` and `data` under `/srv/gitea`. `data` is the whole product: git repos,
SQLite, attachments, avatars, LFS objects and `app.ini`. The container runs as UID/GID 1000.

## 3. Secrets

No secret is generated and there is no `.env` file. The wizard creates the administrator password
in the browser. What matters is speed: anyone who reaches https://<DOMAIN>/ before you finish the
wizard can claim the instance. Complete step 7 as soon as the stack answers.

## 4. compose.yml

Paste the whole block, then substitute the hostname.

```bash
cat > /srv/gitea/compose.yml <<'EOF'
# Gitea · the compose file for this service. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker ............. https://docs.gitea.com/installation/install-with-docker
#   config cheat sheet . https://docs.gitea.com/administration/config-cheat-sheet
#   reverse proxy ...... https://docs.gitea.com/administration/reverse-proxies
#
# One service. SQLite lives under /data (no separate database container).
# ROOT_URL and DOMAIN must match the public hostname or clone links and
# redirects will be wrong. SSH is not published on this host: git over HTTPS
# with a personal access token is the path this install documents. After the
# first account is created, set GITEA__service__DISABLE_REGISTRATION=true and
# restart so the open signup door closes. Digest read from Docker Hub on
# 2026-08-07 for tag 1.27.1.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  gitea:
    image: gitea/gitea:1.27.1@sha256:34e3f6b75f5cbb6aebce588037fc5a53c84213e4d4b00da0a8d73e031a558e52
    container_name: gitea
    restart: unless-stopped
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      GITEA__database__DB_TYPE: sqlite3
      GITEA__server__DOMAIN: <DOMAIN>
      GITEA__server__ROOT_URL: https://<DOMAIN>/
      GITEA__server__DISABLE_SSH: "true"
      GITEA__server__START_SSH_SERVER: "false"
      # Flip to "true" after the first account claims the instance (step 7).
      GITEA__service__DISABLE_REGISTRATION: "false"
    volumes:
      # Repos, SQLite, attachments, avatars, app.ini.
      - /srv/gitea/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8208.
      # No SSH port is published.
      - "127.0.0.1:8208:3000"
EOF
DOMAIN_HOST=<DOMAIN>
sed -i "s|<DOMAIN>|${DOMAIN_HOST}|g" /srv/gitea/compose.yml
cd /srv/gitea && docker compose config >/dev/null && echo "compose OK"
```

Set `DOMAIN_HOST` to your real hostname before sed. You should see `compose OK`. One service, no
SSH port, no database container. Do not add a Caddy service here.

## 5. Caddy and TLS

```bash
cat > /srv/gitea/Caddyfile <<'EOF'
# Gitea · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.gitea.com/administration/reverse-proxies and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8208 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Git over HTTPS uses
	# this same reverse_proxy; no SSH port is published by this install.
	reverse_proxy 127.0.0.1:8208
}
EOF
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-gitea
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" /srv/gitea/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

`caddy validate` and reload must both exit 0. If validate fails, restore
`/etc/caddy/Caddyfile.before-gitea`, reload, and fix the syntax. Caddy obtains and renews the
certificate on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see Status active, 80 and 443 open, nothing for 8208 or 3000. Do not open a Gitea SSH
port. HTTPS is how git travels on this install.

## 7. Start and verify

```bash
cd /srv/gitea
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sSL https://<DOMAIN>/ | grep -ciE 'gitea|install|register|sign'
docker compose ps
```

You should see a 2xx/3xx loop end and a body that looks like Gitea or its install surface. If
you get 502, re-check step 5. If the container restarts, read
`docker compose logs --tail 40 gitea` and check that `data/` is usable for UID 1000.

STOP: open https://<DOMAIN>/ now, finish the install wizard if it appears, create the first
administrator account, and confirm you are signed in as that admin. Do not continue until that is done.

Close registration after that account exists:

```bash
cd /srv/gitea
sed -i 's/GITEA__service__DISABLE_REGISTRATION: "false"/GITEA__service__DISABLE_REGISTRATION: "true"/' compose.yml
docker compose up -d
sleep 8
echo -n 'disable_flag_count='; grep -c 'DISABLE_REGISTRATION: "true"' /srv/gitea/compose.yml
curl -sS -o /tmp/gitea-signup.html -w 'signup_status=%{http_code}\n' https://<DOMAIN>/user/sign_up
curl -sSL https://<DOMAIN>/user/sign_up -o /tmp/gitea-signup-followed.html
echo -n 'open_form_markers='; grep -ciE 'name="user_name"|id="user_name"' /tmp/gitea-signup-followed.html
```

`disable_flag_count` must be `1`. `open_form_markers` must be `0` (no open registration form for
anonymous visitors). If the form is still open, stop and fix before the handoff.

First clone/push handoff (core loop). Create an empty repository in the UI. Create a personal
access token under Settings with repository write scope. On your laptop:

```bash
git clone https://<DOMAIN>/<username>/<repo>.git
cd <repo>
echo '# hello' > README.md
git add README.md
git commit -m "first commit"
git push -u origin main
```

When git asks for a password, paste the token, not the account password. Username is your Gitea
username. Ignore SSH remotes the UI may show; SSH is not published here.

STOP: confirm a successful push, or explicitly defer the push until a repo is ready. Do not continue until that is done.

## 8. First backup and restore

Archive `data/` (the real state), `compose.yml`, and the live Caddyfile.

```bash
cd /srv/gitea
docker compose stop
sudo tar -czf /srv/gitea/backups/gitea-$(date +%F).tar.gz \
  -C /srv/gitea data compose.yml \
  -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/gitea/backups/
```

The archive must exist and be non-empty; print its size. Do not append `|| true` to tar. From
your laptop:

```bash
mkdir -p ~/backups/gitea
scp vps:/srv/gitea/backups/*.tar.gz ~/backups/gitea/
```

To restore: `cd /srv/gitea`, `docker compose down`, move aside `data`, untar into `/srv/gitea`
(restore Caddy if needed), `docker compose up -d`. Losing `data/` loses every repository and the
account database. Take another backup after the first real projects land.

## 9. Updating later

Releases: https://github.com/go-gitea/gitea/releases. Read notes before jumping versions. Backup
first, edit the image line in `/srv/gitea/compose.yml` to the new tag and digest:

```bash
cd /srv/gitea
docker compose pull
docker compose up -d
docker compose logs --tail 40 gitea
```

Confirm you can sign in and that `DISABLE_REGISTRATION` is still `"true"`. Re-check
`/user/sign_up` still does not present an open form.

When you pin a new digest, record it next to the release tag. If an upgrade crash-loops, roll the
image line back, bring the stack up, then read migration logs. Do not run two Gitea containers
against the same `data/` directory.

## 10. What will probably go wrong

You will clone with an SSH remote out of habit, get connection refused on port 22, and assume
Gitea is down. It is not. This install never published SSH. Switch to HTTPS, use a personal
access token as the password, and the push works. Second: forgetting to flip
`DISABLE_REGISTRATION` after the first account leaves a public signup form. Third: wrong
`ROOT_URL` after a rename breaks clone links until you fix compose and recreate. Fourth: disk
full under `/srv/gitea/data` fails every push; watch free space before large binaries.

## 11. Out of scope

- Do not add a Caddy container to compose. Caddy already runs under systemd on this host.
- Do not publish 8208 on `0.0.0.0` or open it in the firewall.
- Do not publish git over SSH or open port 22 for Gitea unless you explicitly decide later.
- Do not add PostgreSQL, Actions runners, or a second forge in this install.
- Do not skip closing registration or the signup assert after the first account.

Hostname discipline: DOMAIN, ROOT_URL, the Caddy site name and the browser URL must match.
Security discipline: claim the admin account immediately, then disable registration and prove it.
State discipline: `/srv/gitea/data` is the product; backups that skip it are not backups of the
forge. Transport discipline: HTTPS + token is the supported git path on this pin.

NOT YET VERIFIED: no harness run has been recorded against this install path.

If a step's assert fails, name the earlier step that most likely caused it before changing
anything else. Preflight failures are step 1. Wrong ROOT_URL or DOMAIN after a rename is step 4.
Certificate or 502 problems are step 5. Open ports that should be closed are step 6. An open
signup form after the first account is step 7 incomplete. Empty backups are step 8.

Claim race detail: between `docker compose up -d` and the moment you submit the admin form, the
instance is first-come-first-served. On a public hostname that window is the real risk. Do not
leave the browser tab open "for later" while DNS propagates to friends.

Token discipline: treat personal access tokens like passwords. Store them in a password manager.
Revoke tokens you no longer use. Never put a token in a shell history you will paste into chat.
For CI machines, prefer deploy keys or limited tokens over the admin password.

Backup cadence: empty-initialized backup after install, second backup after the first real
repositories, then on a schedule you will actually keep. Off-box copies matter more than clever
retention scripts you never run.

Upgrade discipline: read release notes when crossing minor versions. SQLite migrations usually
run on start; watch logs until they settle. If you later outgrow SQLite, that is a planned
migration to Postgres with its own backup story, not a silent compose tweak mid-week.

Forgejo note for context only: a community hard fork of Gitea exists (Codeberg e.V., hard fork
from early 2024, active 2026 releases, license shift toward GPL for new work). This page installs
Gitea. Do not swap the image for Forgejo in this prompt without a separate plan.

This path is NOT YET VERIFIED on a clean harness machine; treat the asserts as the contract and
stop when they fail.

Git credential helpers on the laptop can store the token after the first push so you are not
pasting it every time. That is fine on a personal machine; on a shared computer, prefer one-shot
auth and clear the helper after. Submodules and LFS both need working HTTPS credentials too; if
LFS objects fail to push, check free disk on the server under /srv/gitea/data before blaming the
token.

Webhooks and Actions runners are out of scope for this install. If you enable Actions later, that
is a second service with its own secrets and network surface. Packages (container or language
registries) also grow disk quickly; budget them separately from source history.

Email for registration and notifications is not configured here. Password reset by email will not
work until you add SMTP yourself. Keep the admin password somewhere recoverable without email.

Time and timezone: the container uses the image default. If commit timestamps look wrong, set TZ
deliberately later rather than guessing. Mirror and migration tools from GitHub/GitLab can import
history; run them after registration is closed so imported users do not land on an open instance.

When something fails, collect four facts before changing config: `docker compose ps`, the last
forty log lines, `curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/`, and free disk on
/srv. Most "Gitea is broken" reports are one of those four.

Keep the off-box backup current before every upgrade.
