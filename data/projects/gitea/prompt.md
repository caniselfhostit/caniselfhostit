You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Gitea 1.27.1 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say three things when you ask. One: that
hostname becomes `GITEA__server__DOMAIN` and `GITEA__server__ROOT_URL`, and clone URLs and
redirects are wrong if they disagree with the browser. Two: the first account created in the
install wizard is the admin (first claimant), so the user must open the URL and finish that
before anyone else can. Three: this install does not publish git over SSH; pushes and pulls go
over HTTPS with a personal access token unless they later ask to open SSH on purpose.

Gitea needs 1024 MB of RAM available and 10 GB free on /srv. The 1.27.1 image publishes amd64
and arm64. Measure:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a hostname that does not resolve, and ROOT_URL would point at a name that does not answer.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/gitea /srv/gitea/backups /srv/gitea/data
ls -la /srv/gitea
```

Assert: `ls -la` shows `backups` and `data` owned by the login user. `data` is the whole product
state: git repositories, the SQLite file, attachments, avatars, LFS objects and `app.ini`. The
image runs as USER_UID/GID 1000 and will chown what it needs under `/data` on first start.

## 3. Secrets

No secret is generated for this install and there is no `.env` file. That is not an oversight.
Gitea's install wizard creates the administrator account on first visit; the password is chosen
in the browser and never passes through this prompt. `secretsToGenerate` is zero. Step 7 is
where the open registration door closes after that first account exists.

What replaces a generated credential here is speed: anyone who can reach https://<DOMAIN>/ before
the user finishes the wizard can claim the instance. Say that plainly, then move to compose so
the window stays short.

## 4. compose.yml

Write the file, then substitute the real hostname into `DOMAIN` and `ROOT_URL`.

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

Set `DOMAIN_HOST` to the real hostname from step 1 before `sed`. Assert: that prints
`compose OK`. One service, one published port, no database container, no SSH port. Do not add a
Caddy service to this file.

## 5. Caddy and TLS

Write the site block under `/srv/gitea/Caddyfile`, then append it to the live Caddyfile with
`<DOMAIN>` replaced. Copy the live file first: a syntax error here takes down every other site
on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
`/etc/caddy/Caddyfile.before-gitea`, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in for both
the web UI and git over HTTPS, and 443/udp is HTTP/3. 8208 stays closed because compose binds it
to 127.0.0.1. Do not open 22 for Gitea and do not publish container port 22: SSH git is out of
scope for this install. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp
and 443/udp, and no rule mentioning 8208 or 3000.

## 7. Start and verify

```bash
cd /srv/gitea
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sSL https://<DOMAIN>/ | grep -ciE 'gitea|install|register|sign'
docker compose ps
```

Assert: the loop ends with a 2xx or 3xx status, and the body mentions Gitea or the install /
sign-in surface (count greater than `0`). If Caddy returns 502 with a running container, step 5
is the likely cause. If the container restarts, check
`docker compose logs --tail 40 gitea` and that `data/` is writable for UID 1000. A running
container is not success.

STOP: tell the user to open https://<DOMAIN>/ now, finish the install wizard if it appears, and
create the first administrator account with a password they will keep. They must confirm back to
you that they are signed in as that admin before you continue. Do not continue until they confirm.

After they confirm, close registration and assert it is closed:

```bash
cd /srv/gitea
sed -i 's/GITEA__service__DISABLE_REGISTRATION: "false"/GITEA__service__DISABLE_REGISTRATION: "true"/' compose.yml
docker compose up -d
sleep 8
echo -n 'disable_flag_count='; grep -c 'DISABLE_REGISTRATION: "true"' /srv/gitea/compose.yml
curl -sS -o /tmp/gitea-signup.html -w 'signup_status=%{http_code}\n' https://<DOMAIN>/user/sign_up
# Body without following redirects (shows 302/303 away from an open form when closed).
# Body following redirects (should not be a filled registration form).
curl -sSL https://<DOMAIN>/user/sign_up -o /tmp/gitea-signup-followed.html
echo -n 'open_form_markers='; grep -ciE 'name="user_name"|id="user_name"' /tmp/gitea-signup-followed.html
echo -n 'disabled_or_login_markers='; grep -ciE 'registration is disabled|Forbidden|sign.in|Sign In|log.in|Log In' /tmp/gitea-signup-followed.html
```

Assert: `disable_flag_count` is `1`. Print `signup_status` and both marker counts. An open
registration form after disable is a failure: `open_form_markers` must be `0` (no username field
on an anonymous signup page). If `open_form_markers` is greater than `0`, stop and fix before
the handoff. If you cannot show evidence signup is closed, do not proceed.

Then show the first clone/push handoff (the product's core loop). Tell the user to create an
empty repository in the UI, open Settings → Applications → Generate New Token with `write:repository`
scope (or the current equivalent for HTTPS git), then on their laptop:

```bash
git clone https://<DOMAIN>/<username>/<repo>.git
cd <repo>
echo '# hello' > README.md
git add README.md
git commit -m "first commit"
git push -u origin main
```

When git asks for a password, they paste the token, not the account password. Username is their
Gitea username. SSH clone URLs are not configured on this host; if the UI shows an SSH remote,
tell them to use the HTTPS remote instead.

STOP: do not continue until they confirm a successful push (or an explicit decision to skip the
push until they have a repo ready). Do not continue until they confirm.

## 8. First backup and restore

One archive: the data volume (repos, SQLite, attachments), the compose file, and the live Caddy
site block. There is no `.env`. Take a backup now and again after the first real repositories
land.

```bash
cd /srv/gitea
docker compose stop
sudo tar -czf /srv/gitea/backups/gitea-$(date +%F).tar.gz \
  -C /srv/gitea data compose.yml \
  -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/gitea/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped on purpose
so SQLite and loose objects are not half-written. Never append `|| true` to this tar.

A backup on the same disk as the data is not a backup. From the user's machine:

```bash
mkdir -p ~/backups/gitea
scp vps:/srv/gitea/backups/*.tar.gz ~/backups/gitea/
```

To restore: `cd /srv/gitea`, `docker compose down`, move aside `data`, untar into `/srv/gitea`
(and restore `/etc/caddy/Caddyfile` if needed), then `docker compose up -d`. Tell the user:
`data/` is every repository and the account database. Losing it costs the forge.

## 9. Updating later

New versions are listed at https://github.com/go-gitea/gitea/releases. Read the release notes for
breaking changes before jumping versions. Take a backup first, then edit the image line in
`/srv/gitea/compose.yml` to the new tag and digest:

```bash
cd /srv/gitea
docker compose pull
docker compose up -d
docker compose logs --tail 40 gitea
```

Confirm you can sign in and that `DISABLE_REGISTRATION` is still `"true"` after the upgrade.
Re-check https://<DOMAIN>/user/sign_up still does not present an open form.

## 10. What will probably go wrong

You will clone with an SSH remote out of habit, get "connection refused" on port 22, and
assume Gitea is down. It is not. This install never published SSH. Switch the remote to HTTPS,
use a personal access token as the password, and the push works. The second failure mode is
forgetting to flip `DISABLE_REGISTRATION` after the first account: the forge stays a public
signup form until you do. The third is `ROOT_URL` wrong after a rename: clone links and OAuth
callbacks point at the old name until you fix compose and recreate the container.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy already runs under systemd on this box.
- Do not publish 8208 on `0.0.0.0` or open it in the firewall.
- Do not publish git over SSH or open port 22 for Gitea unless the user explicitly asks later.
- Do not add PostgreSQL, Actions runners, or a second forge container in this install.
- Do not skip closing registration or the signup assert after the first account.
